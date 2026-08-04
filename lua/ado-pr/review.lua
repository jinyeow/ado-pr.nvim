-- Checkout a PR into the current (review) worktree, open its diff, and post
-- inline comments against the diff.
local M = {}

local az = require('ado-pr.az')
local anchor = require('ado-pr.anchor')
local config = require('ado-pr.config')
local signs = require('ado-pr.signs')
local state = require('ado-pr.state')

-- Record the active-PR context so :AdoPrComment knows which PR/repo to post to.
-- The threads route wants the repository GUID, taken from the PR payload. `base` is the
-- commit diffview was opened against -- signs.lua needs it to self-compute a hunk table
-- for diff1_plain/diff1_raw (docs/specs/left-side-thread-anchoring.md).
local function capture_context(id, pr, base)
  local repo = pr.repository or {}
  state.set({
    id = id,
    repositoryId = repo.id,
    project = (repo.project and repo.project.name) or config.get().project,
    base = base,
  })
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
      vim.notify(
        ('ado-pr: git fetch %s failed (attempt %d/%d): %s, retrying'):format(target_ref, attempt, FETCH_RETRIES, detail),
        vim.log.levels.WARN
      )
    end
  end
  return fetch
end

-- Fetch the PR's real target ref and resolve it to a commit, so the review
-- diffs against what ADO actually targeted (not a possibly-stale, possibly-
-- wrong local ref). Runs with the review worktree as cwd. Returns
-- (commit|nil, err|nil).
local function resolve_base(pr)
  local target_ref = pr.targetRefName
  if not target_ref or target_ref == '' then
    return nil, 'PR payload missing targetRefName'
  end
  local cwd = vim.fn.getcwd()
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
  local base, berr = resolve_base(pr)
  if not base then
    vim.notify('ado-pr: ' .. berr, vim.log.levels.ERROR)
    return
  end
  if pcall(require, 'diffview') then
    vim.cmd('DiffviewOpen ' .. base .. '...HEAD')
  else
    vim.cmd('Git difftool ' .. base .. '...HEAD') -- vim-fugitive fallback
  end
  -- Only now that the diff has actually opened does the active-PR state
  -- (which :AdoPrComment relies on) switch to this PR.
  capture_context(id, pr, base)

  local list, terr = az.list_threads(state.get())
  if not list then
    vim.notify('ado-pr: could not load PR comment threads: ' .. (terr or 'unknown error'), vim.log.levels.WARN)
    list = {}
  end
  signs.set_threads(list)
  signs.attach()
  signs.refresh()
  local pr_level = signs.pr_level_count()
  if pr_level > 0 then
    vim.notify(
      ('ado-pr: %d PR-level thread%s'):format(pr_level, pr_level == 1 and '' or 's'),
      vim.log.levels.INFO
    )
  end
  local not_showable = signs.not_showable_count()
  if not_showable > 0 then
    vim.notify(
      ('ado-pr: %d left-side thread%s not showable in this layout'):format(
        not_showable,
        not_showable == 1 and '' or 's'
      ),
      vim.log.levels.INFO
    )
  end
end

-- Post an inline comment thread on the line under the cursor in the diff.
-- text: optional comment content (`:AdoPrComment some text`); prompted when nil.
function M.comment(text)
  local ctx = state.get()
  if not ctx or not ctx.repositoryId then
    vim.notify('ado-pr: no active PR — run :AdoPr / :AdoPrReview first', vim.log.levels.ERROR)
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
