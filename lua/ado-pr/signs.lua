-- Bespoke sign adapter placing Azure DevOps PR comment thread markers in diffview's
-- diff buffers. Extmarks in a plugin-owned namespace, never `vim.diagnostic` -- PR
-- comments must stay out of diagnostic counts, the quickfix list, and diagnostic-counting
-- statuslines.
--
-- Right-side placement is the one rule that holds across every diffview layout: buffer row
-- == new-file line, true in the two-window layouts and equally in diff1_plain/diff1_raw/
-- diff1_inline (the inline renderer never mutates the new-side buffer).
--
-- Left-side placement (docs/specs/left-side-thread-anchoring.md) has no such shortcut:
-- two-window layouts sign the old-side window directly, but the single-window layouts have
-- no old-side buffer at all. diff1_inline maps an old line through its hunk table to either
-- a real unchanged-region row or the row its virtual deletion lines hang from; diff1_plain/
-- diff1_raw do the same offset mapping but have no anchor for a genuine deletion, so those
-- threads count toward M.not_showable_count() instead of guessing a row.
--
-- M.plan is the pure placement plan (layout branch selection, hunk mapping, not_showable
-- accounting) -- tested directly in signs_spec.lua. M.refresh() itself stays thin,
-- untested glue over diffview internals, git and Neovim's window/buffer API with no seam
-- worth mocking beyond M.plan (same call as anchor.lua's M.current / diffview_state.lua),
-- validated by smoke test against a live PR. Filtering and range math live in
-- threads.lua / hunks.lua, tested there.
local M = {}

local threads_mod = require('ado-pr.threads')
local diffview_state = require('ado-pr.diffview_state')
local hunks_mod = require('ado-pr.hunks')
local state_mod = require('ado-pr.state')

local ns = vim.api.nvim_create_namespace('ado_pr_threads')

local START_SIGN = { active = '●', resolved = '○' }
local HL = { active = 'DiagnosticSignInfo', resolved = 'Comment' }
local RANGE_SIGN = '│'

-- diff1_inline always has a real buffer row to sign, even for a pure deletion (the row
-- its virtual deletion lines hang from). diff1_plain/diff1_raw do not.
local INLINE_LAYOUTS = { diff1_inline = true, diff1_inline_pinned = true }

-- { { thread = <thread>, path = <repo-relative, forward-slash>, range = { side, line_start, line_end } } }
local signed = {}
local pr_level = 0
local not_showable = 0
-- Every buffer M.refresh() marked extmarks in last call, so a layout switch clears them
-- even when the new layout no longer signs into that buffer/window at all.
local marked_bufs = {}
-- Self-computed diff1_plain/diff1_raw hunk table, keyed by path -- git-diff is only
-- re-run when the file under the cursor changes, not on every WinEnter refresh.
local plain_hunks_cache

-- Store the renderable threads for the active PR (a plain fetch -- no iteration window).
-- Both left- and right-anchored threads are kept for signing; PR-level (no threadContext)
-- human threads are counted, not signed.
function M.set_threads(threads)
  signed, pr_level = {}, 0
  plain_hunks_cache = nil
  for _, t in ipairs(threads or {}) do
    if threads_mod.is_renderable(t) then
      local path = threads_mod.path(t)
      if not path then
        pr_level = pr_level + 1
      else
        local range = threads_mod.resolve(t, nil)
        if range then
          table.insert(signed, { thread = t, path = threads_mod.norm_repo_path(path), range = range })
        end
      end
    end
  end
end

-- Human PR-level threads (no threadContext) -- surfaced as a count on open, not an
-- invented inline home.
function M.pr_level_count()
  return pr_level
end

-- Left-side threads whose position has no real row in the current single-window layout
-- (diff1_plain/diff1_raw, a line inside a genuine deletion) -- surfaced as a count, never
-- a guessed position. Reset on every M.refresh() call, so it reflects the file/layout
-- under the cursor now.
function M.not_showable_count()
  return not_showable
end

-- Mark `lines` (explicit buffer rows, already clamped and de-duplicated by M.plan) in
-- `buf`. The first row gets the start glyph, the rest the range glyph.
local function place(buf, lines, kind)
  local hl = HL[kind]
  for i, line in ipairs(lines) do
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
      sign_text = i == 1 and START_SIGN[kind] or RANGE_SIGN,
      sign_hl_group = hl,
    })
  end
  if #lines > 0 then
    marked_bufs[buf] = true
  end
end

local function range_lines(range)
  local lines = {}
  for line = range.line_start, range.line_end do
    table.insert(lines, line)
  end
  return lines
end

-- Clamp `lines` into [1, line_count] and drop duplicates/out-of-range zeros -- several old
-- lines can collapse onto the same anchor row, and a stale thread range can run past the
-- current buffer's end.
local function clamped_dedup_lines(lines, line_count)
  local out, seen = {}, {}
  for _, line in ipairs(lines) do
    local clamped = threads_mod.clamp({ line_start = line, line_end = line }, line_count)
    local l = clamped.line_start
    if l ~= 0 and not seen[l] then
      seen[l] = true
      table.insert(out, l)
    end
  end
  return out
end

-- Self-computed hunk table for diff1_plain/diff1_raw, which attach no diffview diff
-- renderer to read one from. `git diff <base>...HEAD -- <path>` is the exact range
-- review.lua already opened diffview against.
local function plain_hunks_for(entry_path)
  if plain_hunks_cache and plain_hunks_cache.path == entry_path then
    return plain_hunks_cache.hunks
  end
  local result_hunks = {}
  local ctx = state_mod.get()
  if ctx and ctx.base then
    local res = vim.system({ 'git', 'diff', ctx.base .. '...HEAD', '--', entry_path }, { text = true, cwd = vim.fn.getcwd() }):wait()
    if res.code == 0 then
      result_hunks = hunks_mod.parse_unified_hunks(res.stdout or '')
    end
  end
  plain_hunks_cache = { path = entry_path, hunks = result_hunks }
  return result_hunks
end

-- Map a left-side thread's range through the hunk table for single-window layouts.
-- diff1_inline always has a real row to sign (the row a pure deletion's virtual lines
-- hang from); diff1_plain/diff1_raw do not, and a range that maps to zero exact rows
-- is unshowable rather than being placed at a guessed row.
local function left_single_window_lines(layout, hunks, range)
  local lines = {}
  local any_unshowable = false
  for line = range.line_start, range.line_end do
    local row, exact = hunks_mod.old_line_to_row(hunks, line)
    if exact or INLINE_LAYOUTS[layout] then
      table.insert(lines, row)
    else
      any_unshowable = true
    end
  end
  return lines, any_unshowable
end

-- Pure placement plan: no vim.api, vim.system or diffview state -- deterministic
-- table-in/table-out, so layout branch selection and the hunk mapping are testable
-- without a live diffview view. `line_counts` is `{ a = <int|nil>, b = <int> }`: `a` set
-- only for two-window layouts, `b` always (mirrors diffview_state.current().windows).
--
-- `signed_items` is `M.set_threads`'s own shape: `{ { thread, path, range }, ... }`, not
-- yet filtered to `entry_path` -- M.plan does that filtering itself, same as M.refresh
-- did before this extraction.
--
-- Returns `{ placements, not_showable }`. Each placement is
-- `{ target = 'a'|'b', lines = <int[]>, kind = 'active'|'resolved' }` -- clamped,
-- de-duplicated buffer rows ready for direct extmark placement (see `place` above).
function M.plan(layout_kind, hunks, signed_items, entry_path, line_counts)
  local placements = {}
  local plan_not_showable = 0
  local two_window = line_counts.a ~= nil

  for _, item in ipairs(signed_items) do
    if item.path == entry_path then
      local kind = threads_mod.is_resolved(item.thread) and 'resolved' or 'active'
      if item.range.side == 'right' then
        local lines = clamped_dedup_lines(range_lines(item.range), line_counts.b)
        if #lines > 0 then
          table.insert(placements, { target = 'b', lines = lines, kind = kind })
        end
      elseif two_window then
        local lines = clamped_dedup_lines(range_lines(item.range), line_counts.a)
        if #lines > 0 then
          table.insert(placements, { target = 'a', lines = lines, kind = kind })
        end
      else
        local raw_lines, unshowable = left_single_window_lines(layout_kind, hunks, item.range)
        if unshowable then
          plan_not_showable = plan_not_showable + 1
        end
        local lines = clamped_dedup_lines(raw_lines, line_counts.b)
        if #lines > 0 then
          table.insert(placements, { target = 'b', lines = lines, kind = kind })
        end
      end
    end
  end

  return { placements = placements, not_showable = plan_not_showable }
end

-- Signed items (thread + resolved range) for one repo-relative path, normalised.
-- The follower pane (view.lua) uses this to find the threads covering the cursor
-- and to walk between them with ]t / [t.
function M.items_for(path)
  local out = {}
  for _, item in ipairs(signed) do
    if item.path == path then
      table.insert(out, item)
    end
  end
  return out
end

-- Re-render signs in diffview's current diff buffer(s) for the file under the cursor. A
-- multi-line thread is marked across its whole span, not only at its first line. Threads
-- on files outside the current diff scope are skipped (M.plan filters by entry_path).
-- Every buffer marked by a previous call is cleared first, so switching layouts re-derives
-- placement from scratch rather than leaving stale marks in a buffer the new layout no
-- longer signs into. Safe to call with no active diffview view (no-op).
function M.refresh()
  for buf in pairs(marked_bufs) do
    if vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
  end
  marked_bufs = {}
  not_showable = 0

  local state = diffview_state.current()
  if not state then
    return
  end
  local win_b = state.windows.b
  if not (win_b and win_b.bufnr) then
    return
  end
  local win_a = state.windows.a
  local two_window = win_a and win_a.bufnr

  local entry_path = threads_mod.norm_repo_path(state.entry.path)
  local line_counts = { b = vim.api.nvim_buf_line_count(win_b.bufnr) }
  if two_window then
    line_counts.a = vim.api.nvim_buf_line_count(win_a.bufnr)
  end

  -- diffview only computes a hunk table for inline layouts, and even there it can come
  -- back nil (no bufnr yet, or diffview.scene.inline_diff unavailable -- see
  -- diffview_state_spec.lua cases 9/10). Any single-window layout without one self-
  -- computes from git, so a left-side line is never identity-mapped by omission.
  local hunks
  if not two_window then
    hunks = state.hunks or plain_hunks_for(entry_path)
  end

  local result = M.plan(state.layout, hunks, signed, entry_path, line_counts)
  not_showable = result.not_showable
  for _, p in ipairs(result.placements) do
    local win = p.target == 'a' and win_a or win_b
    place(win.bufnr, p.lines, p.kind)
  end
end

local group
-- Hook diffview's buffer-enter event so signs re-apply as the user moves between files --
-- diffview swaps content into an existing buffer rather than running placement once at
-- open. Torn down on DiffviewViewClosed so a closed review doesn't leave a WinEnter
-- autocmd firing forever. Safe to call repeatedly (each review re-creates the group).
function M.attach()
  group = vim.api.nvim_create_augroup('AdoPrThreads', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = { 'DiffviewDiffBufWinEnter', 'DiffviewViewOpened' },
    callback = vim.schedule_wrap(M.refresh),
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = vim.schedule_wrap(M.refresh),
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DiffviewViewClosed',
    -- Deleting the augroup from inside its own callback errors ("autocommands are
    -- locked"); defer to the next event-loop tick, same as diffview.nvim's own teardown.
    callback = vim.schedule_wrap(function()
      vim.api.nvim_del_augroup_by_id(group)
      group = nil
    end),
  })
end

return M
