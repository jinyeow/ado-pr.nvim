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
local resolved_threads = require('ado-pr.resolved_threads')
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

local not_showable = 0
-- Every buffer M.refresh() marked extmarks in last call, so a layout switch clears them
-- even when the new layout no longer signs into that buffer/window at all.
local marked_bufs = {}
-- Self-computed diff1_plain/diff1_raw hunk table, keyed by path -- git-diff is only
-- re-run when the file under the cursor changes, not on every WinEnter refresh.
local plain_hunks_cache
-- Last (path, error) a git-diff-failure notify fired for -- nil once the failure clears
-- or hasn't happened yet. Failures are deliberately never cached (so a retry is always
-- attempted), but M.refresh runs on every WinEnter, so without this the same failure would
-- warn on every window switch. Reset whenever resolved_threads.all() hands back a
-- different collection than the one last refresh saw (a fresh resolved_threads.set_threads()
-- call always does, since it replaces the collection with a new table) and by attach(), so
-- a new review session (or a re-fetch of threads) re-notifies rather than staying silent
-- from a prior session.
local last_notified_hunks_err
-- Last (path, count) a not_showable notify fired for -- nil until the first refresh, so
-- that refresh re-notifies on every count *change* (including the very first nonzero
-- count) rather than once per PR review (issue #30). Keyed by path like
-- last_notified_hunks_err above, so navigating to a different file whose count happens
-- to match the previous file's does not wrongly stay silent. Reset the same way
-- last_notified_hunks_err is (see above) and by attach(), so a new review session starts
-- fresh.
local last_notified_count
-- The resolved_threads.all() table identity M.refresh() last saw -- table identity, not
-- contents, because resolved_threads.set_threads() always allocates a fresh table (see
-- resolved_threads.lua), so a plain `~=` check is enough to notice "new data landed since
-- the last refresh" without resolved_threads.lua needing to know signs.lua's trackers exist.
local last_seen_collection

-- Count of left-side threads with at least one unpairable line in the current
-- single-window layout (diff1_plain/diff1_raw, a line inside a genuine deletion with no
-- new-side counterpart) -- surfaced as a count, never a guessed position. A thread can
-- both contribute here and still get a placement: a range spanning a shrink hunk pairs
-- its in-range lines and counts the excess unpairable ones, so it's neither fully placed
-- nor fully hidden. Reset on every M.refresh() call, so it reflects the file/layout under
-- the cursor now.
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
-- renderer to read one from. `git diff state_mod.range() -- <path>` (`<base>...<head>`,
-- `head` defaulting to `HEAD`) is the exact range review.lua already opened diffview
-- against -- the SAME range whether that's the full PR (`base...HEAD`) or an iteration
-- window (`base...HEAD` overwritten to that iteration's own commit pair by
-- review.select_iteration) -- run against the review root captured at open (never
-- `vim.fn.getcwd()`, which can differ by refresh time). `-U0` keeps every hunk a single
-- contiguous change run with no surrounding context lines folded in -- without it, git's
-- default ~3 lines of context on each side can merge separate nearby changes into one hunk
-- whose old_count/new_count then span unrelated context, which breaks paired_row's offset
-- math below (it assumes old_count/new_count only cover genuinely changed lines).
--
-- Returns hunks, err. Only a `code == 0` result -- including a legitimately empty parse
-- for an unchanged file -- is cached and returned as a table; no ctx, no range (no
-- `ctx.base`), no `ctx.repo_root` (guarded here rather than letting `vim.system` silently
-- fall back to the process cwd), or a non-zero exit all return `nil` and write nothing to
-- the cache, so the failure is neither mistaken for "no changes" (identity mapping) nor
-- remembered past this refresh -- the next refresh naturally retries.
local function plain_hunks_for(entry_path)
  if plain_hunks_cache and plain_hunks_cache.path == entry_path then
    return plain_hunks_cache.hunks
  end
  local ctx = state_mod.get()
  local range = state_mod.range()
  if not (ctx and range and ctx.repo_root) then
    return nil
  end
  local res = vim.system({ 'git', 'diff', '-U0', range, '--', entry_path }, { text = true, cwd = ctx.repo_root }):wait()
  if res.code ~= 0 then
    local detail = res.stderr ~= '' and res.stderr or ('exit ' .. res.code)
    return nil, detail
  end
  local result_hunks = hunks_mod.parse_unified_hunks(res.stdout or '')
  plain_hunks_cache = { path = entry_path, hunks = result_hunks }
  return result_hunks
end

-- Find the hunk `old_line` falls inside, if any. old_line_to_row already does this walk
-- internally but only reports the anchor row, not the hunk itself -- pairing needs the
-- hunk's own old_start/new_start/new_count to compute a per-line offset.
local function hunk_containing(hunks, old_line)
  for _, h in ipairs(hunks or {}) do
    if old_line >= h.old_start and old_line < h.old_start + h.old_count then
      return h
    end
  end
  return nil
end

-- A 1:1 replacement pairing for an in-hunk old line: offset i = old_line - old_start maps
-- to new row new_start + i, same row diffview's own renderer shows the replacement on --
-- but only while i is still within the hunk's new range. An old line at offset >= new_count
-- has no new-side counterpart at all (genuinely deleted), so it is not paired.
local function paired_row(h, old_line)
  local i = old_line - h.old_start
  if i < h.new_count then
    return h.new_start + i
  end
  return nil
end

-- Map a left-side thread's range through the hunk table for single-window layouts.
-- diff1_inline always has a real row to sign (the row a pure deletion's virtual lines
-- hang from), so every in-hunk line anchors there regardless of pairing. diff1_plain/
-- diff1_raw have no such anchor: an in-hunk old line is placed at its paired row when one
-- exists, and only falls back to unshowable when it doesn't (a genuine deletion).
--
-- `hunks == nil` means the hunk table is unresolved (git-diff failed or was never
-- attempted), not "no hunks in this file" -- treated as fully unshowable rather than
-- falling through to identity mapping (an empty table `{}` is the legitimate "no
-- changes" case and still maps identically).
local function left_single_window_lines(layout, hunks, range)
  if hunks == nil then
    return {}, true
  end
  local lines = {}
  local any_unshowable = false
  for line = range.line_start, range.line_end do
    local row, exact = hunks_mod.old_line_to_row(hunks, line)
    if exact or INLINE_LAYOUTS[layout] then
      table.insert(lines, row)
    else
      local h = hunk_containing(hunks, line)
      local paired = h and paired_row(h, line)
      if paired then
        table.insert(lines, paired)
      else
        any_unshowable = true
      end
    end
  end
  return lines, any_unshowable
end

-- Pure placement plan: no vim.api, vim.system or diffview state -- deterministic
-- table-in/table-out, so layout branch selection and the hunk mapping are testable
-- without a live diffview view. `line_counts` is `{ a = <int|nil>, b = <int> }`: `a` set
-- only for two-window layouts, `b` always (mirrors diffview_state.current().windows).
--
-- `signed_items` is `resolved_threads.all()`'s own shape: `{ { thread, path, range }, ... }`,
-- not yet filtered to `entry_path` -- M.plan does that filtering itself, same as M.refresh
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

  -- A resolved_threads collection this refresh hasn't seen before (a fresh
  -- resolved_threads.set_threads() call since the last refresh) means a new review
  -- session/re-fetch landed -- reset the same trackers set_threads() used to reset
  -- directly back when it lived in this module (see last_notified_hunks_err/
  -- last_notified_count/last_seen_collection above).
  local items = resolved_threads.all()
  if items ~= last_seen_collection then
    plain_hunks_cache = nil
    last_notified_hunks_err = nil
    last_notified_count = nil
    last_seen_collection = items
  end

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
  -- computes from git. A `nil` result (no ctx/base, or a failed `git diff`) stays `nil`
  -- here too -- M.plan treats that as unresolved and counts affected threads toward
  -- not_showable, never identity-mapping a left-side line by omission.
  local hunks, hunks_err
  if not two_window then
    hunks = state.hunks
    if not hunks then
      hunks, hunks_err = plain_hunks_for(entry_path)
    end
  end

  local result = M.plan(state.layout, hunks, items, entry_path, line_counts)
  not_showable = result.not_showable
  for _, p in ipairs(result.placements) do
    local win = p.target == 'a' and win_a or win_b
    place(win.bufnr, p.lines, p.kind)
  end

  -- Only a real git failure (stderr present, or an exit code when stderr is empty -- see
  -- plain_hunks_for) is worth interrupting the user for -- no ctx/base is an ordinary "not
  -- reviewing a PR yet" state, not a failure. Deduped against the last-notified (path,
  -- error) pair: failures are never cached (so retry keeps happening on every WinEnter),
  -- but the warning itself should only repeat when the failure is new or has changed.
  if hunks_err then
    local key = entry_path .. '\0' .. hunks_err
    if key ~= last_notified_hunks_err then
      vim.notify(('ado-pr: git diff failed for %s: %s'):format(entry_path, hunks_err), vim.log.levels.WARN)
      last_notified_hunks_err = key
    end
  else
    last_notified_hunks_err = nil
  end

  -- Re-notify whenever the count changes -- on the initial open (review.lua's own
  -- notify only fired once, on open) and on every later file/layout navigation
  -- (issue #30). A drop to zero updates the tracker but stays silent by default. Skipped
  -- entirely when hunks are unresolved (no ctx/base/repo_root, or a failed git diff): an
  -- unresolved hunk table makes every single-window left-side thread count toward
  -- not_showable regardless of whether it's genuinely unshowable, so that count is not
  -- meaningful here -- a real git failure already got its own WARN above, and "no PR
  -- context yet" isn't a failure worth announcing at all. last_notified_count is left
  -- untouched so a later resolved refresh still compares against the last real count.
  local hunks_resolved = two_window or hunks ~= nil
  if hunks_resolved then
    local count_key = entry_path .. '\0' .. not_showable
    if count_key ~= last_notified_count then
      if not_showable > 0 then
        vim.notify(('ado-pr: %d left-side thread%s not showable in this layout'):format(not_showable, not_showable == 1 and '' or 's'), vim.log.levels.INFO)
      end
      last_notified_count = count_key
    end
  end
end

local group
-- Hook diffview's buffer-enter event so signs re-apply as the user moves between files --
-- diffview swaps content into an existing buffer rather than running placement once at
-- open. Torn down on DiffviewViewClosed so a closed review doesn't leave a WinEnter
-- autocmd firing forever. Safe to call repeatedly (each review re-creates the group).
function M.attach()
  last_notified_hunks_err = nil
  last_notified_count = nil
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
