-- Checkout a PR into the current (review) worktree, open its diff, and post
-- inline comments against the diff.
local M = {}

local az = require('ado-pr.az')
local anchor = require('ado-pr.anchor')
local config = require('ado-pr.config')
local signs = require('ado-pr.signs')
local resolved_threads = require('ado-pr.resolved_threads')
local view = require('ado-pr.view')
local state = require('ado-pr.state')

-- Record the active-PR context so :AdoPrComment knows which PR/repo to post to.
-- The threads route wants the repository GUID, taken from the PR payload. `base` is the
-- commit diffview was opened against -- signs.lua needs it to self-compute a hunk table
-- for diff1_plain/diff1_raw (docs/specs/left-side-thread-anchoring.md). `repo_root` is the
-- review worktree's cwd captured once here, so signs.lua never re-reads `vim.fn.getcwd()`
-- at refresh time. `pr_base` mirrors `base` at open time -- the PR's original resolved base,
-- kept immutable for the session so M.reset_window can restore the full-PR view after
-- M.select_iteration has overwritten `base`/`head` with an iteration window's commits.
local function capture_context(id, pr, base, repo_root)
  local repo = pr.repository or {}
  state.set({
    id = id,
    repositoryId = repo.id,
    project = (repo.project and repo.project.name) or config.get().project,
    base = base,
    pr_base = base,
    repo_root = repo_root,
  })
end

-- Overwrite the diff scope (base/head/window) on the existing active-PR context, leaving
-- id/repositoryId/project/pr_base/repo_root untouched -- used when browsing iterations,
-- where the PR identity doesn't change, only which commit range the diff and thread fetch
-- are scoped to. A plain `vim.tbl_extend('force', ctx, diff)` would not do here: a Lua
-- table literal with an explicit `head = nil` field stores no key at all, so `head`/
-- `window` must be assigned directly to actually clear them back to the full-PR view
-- (M.reset_window), not merged.
local function set_diff(diff)
  local ctx = state.get()
  ctx.base = diff.base
  ctx.head = diff.head
  ctx.window = diff.window
  state.set(ctx)
end

-- Fetch the renderable thread list for `window` (nil for the plain list, `{ iteration,
-- base_iteration }` for a tracked fetch), resolve it, and re-wire signs against it. Shared
-- by M.open, M.select_iteration and M.reset_window so "signs re-placed", "stale signs
-- cleared" (resolved_threads.set_threads always replaces the collection with a fresh
-- table -- see resolved_threads.lua) and "follower pane follows" all come from the one
-- code path rather than three ad-hoc ones.
local function wire_threads(ctx, window)
  local list, terr
  if window then
    list, terr = az.list_threads_tracked(ctx, window.iteration, window.base_iteration)
  else
    list, terr = az.list_threads(ctx)
  end
  if not list then
    vim.notify('ado-pr: could not load PR comment threads: ' .. (terr or 'unknown error'), vim.log.levels.WARN)
    list = {}
  end
  resolved_threads.set_threads(list, window)
  signs.attach()
  signs.refresh()
end

-- Verify `sha` exists in the local object store before diffing against it, attempting an
-- explicit `git fetch origin <sha>` first when it doesn't -- an older iteration's source
-- commit is not guaranteed reachable from the checked-out branch tip (a force-push is one
-- of the most common reasons a new iteration exists at all), and both diffview and
-- signs.lua's self-computed `git diff` need the object locally. No silent fallback to the
-- full view on failure -- the caller surfaces this as an actionable ERROR naming the
-- iteration and sha (AGENTS.md: no silent fallback). Returns (true|nil, err|nil).
local function ensure_commit(cwd, sha, label)
  local check = vim.system({ 'git', 'cat-file', '-e', sha .. '^{commit}' }, { text = true, cwd = cwd }):wait()
  if check.code == 0 then
    return true
  end
  local fetch = vim.system({ 'git', 'fetch', 'origin', sha }, { text = true, cwd = cwd }):wait()
  if fetch.code ~= 0 then
    local detail = fetch.stderr ~= '' and fetch.stderr or ('exit ' .. fetch.code)
    return nil, ('commit %s for %s not found locally and could not be fetched: %s'):format(sha:sub(1, 8), label, detail)
  end
  return true
end

-- Close the previous diff view, if this session has one open, before opening a new commit
-- range -- diffview opens every view in its own new tabpage (view.lua's own comment), so
-- without this a window switch would pile up a second tab/session on top of the first
-- instead of replacing it. Only ever called after a successful diffview-backed M.open, so
-- a view is always there to close.
local function open_diff_range(base_commit, head_commit)
  pcall(vim.cmd, 'DiffviewClose')
  vim.cmd(('DiffviewOpen %s...%s'):format(base_commit, head_commit))
end

-- Pure: iteration id -> the { iteration, base_iteration } window plus the commit pair to
-- diff, given `az.list_iterations`' own shape. "One push at a time" (the issue's framing)
-- means base_iteration = id - 1 -- an iteration diffs against the PREVIOUS iteration's own
-- source commit, not the whole PR base, so browsing iteration N shows just what that push
-- changed. ADO's iteration ids are zero-based: "iteration 0" is the merge-base commit
-- between source and target branches, and "iteration 1" is the head of the source branch at
-- PR creation (confirmed via Microsoft's PR iteration model docs) -- so iteration 1's base
-- is iteration 0, not itself. Iteration 0 is never returned by `az.list_iterations` (it
-- starts numbering at 1), so that base falls back to iteration 1's own targetRefCommit (the
-- target branch tip it was compared against) instead of an `by_id` lookup. Returns
-- ({ window = { iteration, base_iteration }, base_commit, head_commit }|nil, err|nil).
function M.window_for(iterations, id)
  local by_id = {}
  for _, it in ipairs(iterations or {}) do
    by_id[it.id] = it
  end
  local selected = by_id[id]
  if not selected then
    return nil, 'no iteration ' .. tostring(id) .. ' in this PR'
  end
  local head_commit = selected.sourceRefCommit and selected.sourceRefCommit.commitId
  if not head_commit then
    return nil, 'iteration ' .. tostring(id) .. ' has no sourceRefCommit'
  end
  local base_id = id > 1 and (id - 1) or 0
  local base_commit
  if id == 1 then
    base_commit = selected.targetRefCommit and selected.targetRefCommit.commitId
  else
    local base_iter = by_id[base_id]
    base_commit = base_iter and base_iter.sourceRefCommit and base_iter.sourceRefCommit.commitId
  end
  if not base_commit then
    return nil, 'iteration ' .. tostring(base_id) .. ' has no source/target commit'
  end
  return { window = { iteration = id, base_iteration = base_id }, base_commit = base_commit, head_commit = head_commit }
end

-- Number of git-fetch attempts before giving up (retry-with-warning, then
-- raise the last error — see AGENTS.md "External API or service calls").
local FETCH_RETRIES = 3

-- Run `git fetch origin <target_ref>` in cwd, retrying on failure (and
-- guarding against vim.system itself erroring on a spawn failure). Warns on
-- every failed attempt but the last; returns the final result either way.
local function fetch_target_ref(target_ref, cwd)
  local fetch
  for attempt = 1, FETCH_RETRIES do
    local call_ok, result = pcall(function()
      return vim.system({ 'git', 'fetch', 'origin', target_ref }, { text = true, cwd = cwd }):wait()
    end)
    fetch = call_ok and result or { code = -1, stdout = '', stderr = tostring(result) }
    if fetch.code == 0 then
      return fetch
    end
    local detail = fetch.stderr ~= '' and fetch.stderr or ('exit ' .. fetch.code)
    if attempt < FETCH_RETRIES then
      vim.notify(('ado-pr: git fetch %s failed (attempt %d/%d): %s, retrying'):format(target_ref, attempt, FETCH_RETRIES, detail), vim.log.levels.WARN)
    end
  end
  return fetch
end

-- Fetch the PR's real target ref and resolve it to a commit, so the review
-- diffs against what ADO actually targeted (not a possibly-stale, possibly-
-- wrong local ref). Runs with the review worktree as cwd. Returns
-- (commit|nil, err|nil).
local function resolve_base(pr, cwd)
  local target_ref = pr.targetRefName
  if not target_ref or target_ref == '' then
    return nil, 'PR payload missing targetRefName'
  end
  local fetch = fetch_target_ref(target_ref, cwd)
  if fetch.code ~= 0 then
    local detail = fetch.stderr ~= '' and fetch.stderr or ('exit ' .. fetch.code)
    return nil, 'git fetch ' .. target_ref .. ' failed after ' .. FETCH_RETRIES .. ' attempts: ' .. detail
  end
  local revparse = vim.system({ 'git', 'rev-parse', 'FETCH_HEAD' }, { text = true, cwd = cwd }):wait()
  if revparse.code ~= 0 then
    return nil, 'git rev-parse FETCH_HEAD failed: ' .. (revparse.stderr ~= '' and revparse.stderr or ('exit ' .. revparse.code))
  end
  return vim.trim(revparse.stdout or ''), nil
end

function M.open(id)
  local cwd = vim.fn.getcwd()
  local ok, err = az.checkout(id)
  if not ok then
    vim.notify('ado-pr: checkout failed: ' .. err, vim.log.levels.ERROR)
    return
  end
  local pr, perr = az.show_pr(id)
  if not pr then
    vim.notify('ado-pr: could not load PR !' .. id .. ' details: ' .. perr, vim.log.levels.ERROR)
    state.clear()
    return
  end
  local base, berr = resolve_base(pr, cwd)
  if not base then
    vim.notify('ado-pr: ' .. berr, vim.log.levels.ERROR)
    return
  end
  local has_diffview = pcall(require, 'diffview')
  if has_diffview then
    vim.cmd('DiffviewOpen ' .. base .. '...HEAD')
  else
    vim.cmd('Git difftool ' .. base .. '...HEAD') -- vim-fugitive fallback
  end
  -- Only now that the diff has actually opened does the active-PR state
  -- (which :AdoPrComment relies on) switch to this PR.
  capture_context(id, pr, base, cwd)

  wire_threads(state.get(), nil)
  -- The follower pane depends on Diffview window/scene APIs (and its teardown
  -- relies on DiffviewViewClosed, which never fires without Diffview), so it
  -- only attaches on the Diffview-success branch above.
  if has_diffview then
    view.attach()
  else
    vim.notify('ado-pr: thread follower pane needs diffview.nvim', vim.log.levels.INFO)
  end
  local pr_level = resolved_threads.pr_level_count()
  if pr_level > 0 then
    vim.notify(('ado-pr: %d PR-level thread%s'):format(pr_level, pr_level == 1 and '' or 's'), vim.log.levels.INFO)
  end
end

-- Enumerate the active PR's iterations and offer them for selection (fzf-lua, mirroring
-- picker.lua's PR-list picker) -- the "Updates dropdown" stepper (docs/design/
-- pr-comment-threads.md slice 3). "Full PR (all iterations)" is the first row, so
-- restoring the plain view is the same picker rather than a second command. Selecting a
-- row switches both the diff scope and the thread signs to it (M.select_iteration /
-- M.reset_window) -- diffview-only, since retargeting the vim-fugitive fallback's
-- `Git difftool` split cleanly isn't supported.
local FULL_VIEW_LABEL = 'Full PR (all iterations)'

-- Diffview-only feature -- retargeting the vim-fugitive fallback's `Git difftool` split
-- cleanly isn't supported (see M.browse_iterations' own comment above). Shared by
-- browse_iterations, select_iteration and reset_window, since all three call
-- DiffviewOpen/DiffviewClose. Returns true, or false after notifying the same ERROR
-- browse_iterations always has.
local function ensure_diffview()
  if pcall(require, 'diffview') then
    return true
  end
  vim.notify('ado-pr: iteration browsing needs diffview.nvim', vim.log.levels.ERROR)
  return false
end

function M.browse_iterations()
  local ctx = state.get()
  if not (ctx and ctx.repositoryId) then
    vim.notify('ado-pr: no active PR — run :AdoPr / :AdoPrReview first', vim.log.levels.ERROR)
    return
  end
  if not ensure_diffview() then
    return
  end
  local iterations, ierr = az.list_iterations(ctx)
  if not iterations then
    vim.notify('ado-pr: could not load PR iterations: ' .. (ierr or 'unknown error'), vim.log.levels.ERROR)
    return
  end
  local ok, fzf = pcall(require, 'fzf-lua')
  if not ok then
    vim.notify('ado-pr: fzf-lua not found', vim.log.levels.ERROR)
    return
  end
  local id_of, lines = {}, { FULL_VIEW_LABEL }
  for _, it in ipairs(iterations) do
    local author = (it.author and it.author.displayName) or '?'
    local when = (it.createdDate or ''):sub(1, 10)
    local line = ('#%d  %s  %s  %s'):format(it.id, author, when, it.description or '')
    id_of[line] = it.id
    table.insert(lines, line)
  end
  -- Captured now, not read again from state.get() inside the callback below -- if the user
  -- opens a different PR while this picker is still open, the callback must detect that its
  -- captured iterations/ctx are for a PR that's no longer active, rather than applying a
  -- stale selection against the new PR's state.
  local opened_for_id = ctx.id
  fzf.fzf_exec(lines, {
    prompt = 'PR Iterations> ',
    actions = {
      ['default'] = function(selected)
        local choice = selected and selected[1]
        if not choice then
          return
        end
        -- Deferred a tick: fzf-lua's picker float is still tearing down when this fires,
        -- and DiffviewClose/DiffviewOpen shouldn't run against that half-closed window.
        vim.schedule(function()
          local now = state.get()
          if not (now and now.id == opened_for_id) then
            return
          end
          if choice == FULL_VIEW_LABEL then
            M.reset_window()
          else
            M.select_iteration(iterations, id_of[choice])
          end
        end)
      end,
    },
  })
end

-- Switch the diff scope and thread signs to one push of the PR (M.window_for's commit
-- pair), re-fetching threads with az.list_threads_tracked so side (left/right) reflects
-- this window, not the plain list's.
function M.select_iteration(iterations, id)
  local ctx = state.get()
  if not (ctx and ctx.repo_root) then
    vim.notify('ado-pr: no active PR — run :AdoPr / :AdoPrReview first', vim.log.levels.ERROR)
    return
  end
  if not ensure_diffview() then
    return
  end
  local resolved, werr = M.window_for(iterations, id)
  if not resolved then
    vim.notify('ado-pr: ' .. werr, vim.log.levels.ERROR)
    return
  end
  local base_ok, base_err = ensure_commit(ctx.repo_root, resolved.base_commit, 'iteration ' .. resolved.window.base_iteration)
  if not base_ok then
    vim.notify('ado-pr: ' .. base_err, vim.log.levels.ERROR)
    return
  end
  local head_ok, head_err = ensure_commit(ctx.repo_root, resolved.head_commit, 'iteration ' .. id)
  if not head_ok then
    vim.notify('ado-pr: ' .. head_err, vim.log.levels.ERROR)
    return
  end
  open_diff_range(resolved.base_commit, resolved.head_commit)
  set_diff({ base = resolved.base_commit, head = resolved.head_commit, window = resolved.window })
  wire_threads(state.get(), resolved.window)
  view.attach()
end

-- Return to the full-PR view: the plain thread list and the diff base...HEAD review.open
-- originally opened. A no-op when already there.
function M.reset_window()
  local ctx = state.get()
  if not (ctx and ctx.pr_base) then
    vim.notify('ado-pr: no active PR — run :AdoPr / :AdoPrReview first', vim.log.levels.ERROR)
    return
  end
  if not ctx.window then
    return
  end
  if not ensure_diffview() then
    return
  end
  open_diff_range(ctx.pr_base, 'HEAD')
  set_diff({ base = ctx.pr_base, head = nil, window = nil })
  wire_threads(state.get(), nil)
  view.attach()
end

-- Post an inline comment thread on the line under the cursor in the diff.
-- text: optional comment content (`:AdoPrComment some text`); prompted when nil.
function M.comment(text)
  local ctx = state.get()
  if not ctx or not ctx.repositoryId then
    vim.notify('ado-pr: no active PR — run :AdoPr / :AdoPrReview first', vim.log.levels.ERROR)
    return
  end
  if ctx.window then
    vim.notify('ado-pr: cannot comment while browsing an iteration window -- return to the full PR view first (:AdoPrIterations)', vim.log.levels.ERROR)
    return
  end
  local a, err = anchor.current()
  if not a then
    vim.notify('ado-pr: ' .. err, vim.log.levels.ERROR)
    return
  end
  local function post(content)
    if not content or content == '' then
      return
    end
    local thread_id, perr = az.post_thread(ctx, a, content)
    vim.notify(
      thread_id and ('ado-pr: thread posted on !' .. ctx.id) or ('ado-pr: ' .. (perr or 'post failed')),
      thread_id and vim.log.levels.INFO or vim.log.levels.ERROR
    )
  end
  if text then
    return post(text)
  end
  vim.ui.input({
    prompt = ('PR comment @ %s:%d (%s): '):format(a.filePath, a.line, a.side),
  }, post)
end

return M
