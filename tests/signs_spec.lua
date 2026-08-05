-- Tests for ado-pr.signs: the pure placement-plan function (M.plan) and the
-- M.refresh() wiring around it (diffview snapshot -> plan -> extmark placement).
-- Run headless: `nvim --headless -l tests/signs_spec.lua`.
-- No test framework: a tiny assert harness (plenary is not a dependency), same shape as
-- tests/hunks_spec.lua / tests/review_base_spec.lua.
--
-- M.plan is pure (table-in/table-out, no vim.api/vim.system/diffview state) so it is
-- tested directly with hand-built inputs. M.refresh() is thin wiring over diffview_state,
-- vim.system (for the diff1_plain/diff1_raw self-computed hunk table) and real Neovim
-- buffers/extmarks -- stubbed the same way tests/review_base_spec.lua stubs review.lua's
-- boundary, except here vim.api is left real (headless nvim has a real buffer/extmark API,
-- no seam worth mocking there -- see diffview_state_spec.lua's precedent of leaving
-- untouched APIs real).
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local current_snapshot
package.loaded['ado-pr.diffview_state'] = {
  current = function()
    return current_snapshot
  end,
}

local state = require('ado-pr.state')
local signs = require('ado-pr.signs')

local failures, count = {}, 0
local function ok(cond, name, detail)
  count = count + 1
  if not cond then
    table.insert(failures, name .. (detail and ('  (' .. detail .. ')') or ''))
  end
end
local function eq(a, b, name)
  ok(vim.deep_equal(a, b), name, vim.inspect(a) .. ' ~= ' .. vim.inspect(b))
end

-- ---------------------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------------------

local function make_thread(path, side, line_start, line_end, status)
  local pos = function(l)
    return { line = l }
  end
  local tc = { filePath = '/' .. path }
  if side == 'right' then
    tc.rightFileStart = pos(line_start)
    tc.rightFileEnd = pos(line_end or line_start)
  else
    tc.leftFileStart = pos(line_start)
    tc.leftFileEnd = pos(line_end or line_start)
  end
  return {
    status = status or 'active',
    threadContext = tc,
    comments = { { author = 'A', publishedDate = '2026-01-01', commentType = 'text', content = 'hi' } },
  }
end

local function make_buf(n)
  local buf = vim.api.nvim_create_buf(false, true)
  local lines = {}
  for i = 1, n do
    lines[i] = 'l' .. i
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  return buf
end

local ns = vim.api.nvim_create_namespace('ado_pr_threads')
local function marked_rows(buf)
  local out = {}
  for _, m in ipairs(vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {})) do
    table.insert(out, m[2] + 1)
  end
  table.sort(out)
  return out
end

local function find_placement(placements, target)
  for _, p in ipairs(placements) do
    if p.target == target then
      return p
    end
  end
end

local real_system = vim.system
local system_calls
local system_result
local function stub_system()
  system_calls = {}
  vim.system = function(cmd, opts)
    table.insert(system_calls, { cmd = cmd, opts = opts })
    return {
      wait = function()
        return system_result
      end,
    }
  end
end
local function restore_system()
  vim.system = real_system
end

local real_notify = vim.notify
local notifications
local function stub_notify()
  notifications = {}
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
end
local function restore_notify()
  vim.notify = real_notify
end

-- ---------------------------------------------------------------------------
-- M.plan -- pure placement plan
-- ---------------------------------------------------------------------------

-- Two-window layout: a left-side item plans into buffer 'a', a right-side item into 'b'.
do
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 3, line_end = 4 } },
    { thread = { status = 'fixed' }, path = 'f.lua', range = { side = 'right', line_start = 10, line_end = 10 } },
  }
  local result = signs.plan('diff2_horizontal', nil, signed_items, 'f.lua', { a = 100, b = 100 })
  eq(result.not_showable, 0, 'two-window: not_showable stays 0')
  ok(#result.placements == 2, 'two-window: two placements', #result.placements)

  local pa = find_placement(result.placements, 'a')
  ok(pa ~= nil, 'two-window: left item planned into a')
  eq(pa and pa.lines, { 3, 4 }, 'two-window: left item rows')
  eq(pa and pa.kind, 'active', 'two-window: left item kind')

  local pb = find_placement(result.placements, 'b')
  ok(pb ~= nil, 'two-window: right item planned into b')
  eq(pb and pb.lines, { 10 }, 'two-window: right item rows')
  eq(pb and pb.kind, 'resolved', 'two-window: right item kind (fixed -> resolved)')
end

-- diff1_inline: a left thread inside a pure-deletion hunk maps through the hunk table to
-- the row its virtual deletion lines hang from (new_start - 1), not to zero rows.
do
  local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 0 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 11, line_end = 11 } },
  }
  local result = signs.plan('diff1_inline', hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 0, 'diff1_inline: deletion is showable, not_showable 0')
  ok(#result.placements == 1, 'diff1_inline: one placement')
  local p = result.placements[1]
  eq(p and p.target, 'b', 'diff1_inline: placed into b')
  eq(p and p.lines, { 9 }, 'diff1_inline: deletion anchored to hang row (new_start - 1)')
end

-- diff1_plain: a left thread outside any hunk maps to its exact row -- one placement.
do
  local hunks = { { old_start = 5, old_count = 1, new_start = 5, new_count = 1 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 20, line_end = 20 } },
  }
  local result = signs.plan('diff1_plain', hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 0, 'diff1_plain exact: not_showable 0')
  ok(#result.placements == 1, 'diff1_plain exact: one placement')
  eq(result.placements[1].lines, { 20 }, 'diff1_plain exact: exact row placed')
end

-- diff1_plain / diff1_raw: a left thread wholly inside a pure-deletion hunk has no real
-- anchor row in these layouts (no virtual deletion lines rendered) -- zero placements,
-- not_showable incremented instead of guessing a row.
for _, layout in ipairs({ 'diff1_plain', 'diff1_raw' }) do
  local hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 0 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 11, line_end = 11 } },
  }
  local result = signs.plan(layout, hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 1, layout .. ': pure deletion counts as not_showable')
  eq(result.placements, {}, layout .. ': pure deletion yields zero placements')
end

-- nil hunks in a single-window layout means "unresolved" (git-diff computation failed or
-- was never attempted), not "no hunks" -- every left-side item on entry_path is
-- not_showable, never identity-mapped onto the wrong row.
for _, layout in ipairs({ 'diff1_plain', 'diff1_raw', 'diff1_inline' }) do
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 5, line_end = 6 } },
  }
  local result = signs.plan(layout, nil, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 1, layout .. ': nil hunks counts as not_showable, not identity-mapped')
  eq(result.placements, {}, layout .. ': nil hunks yields zero placements')
end

-- diff1_plain / diff1_raw: a 1:1 replacement hunk pairs each old line with its direct
-- new-row counterpart (old_line - old_start == new_start + offset) instead of marking the
-- whole hunk unshowable.
for _, layout in ipairs({ 'diff1_plain', 'diff1_raw' }) do
  local hunks = { { old_start = 5, old_count = 2, new_start = 5, new_count = 2 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 5, line_end = 6 } },
  }
  local result = signs.plan(layout, hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 0, layout .. ': replacement hunk fully paired, not_showable 0')
  ok(#result.placements == 1, layout .. ': replacement hunk one placement')
  eq(result.placements[1].lines, { 5, 6 }, layout .. ': replacement hunk paired rows')
end

-- diff1_plain / diff1_raw: a shrinking hunk pairs old lines within new_count and marks the
-- excess old line (beyond new_count) unshowable.
for _, layout in ipairs({ 'diff1_plain', 'diff1_raw' }) do
  local hunks = { { old_start = 5, old_count = 3, new_start = 5, new_count = 2 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 5, line_end = 7 } },
  }
  local result = signs.plan(layout, hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 1, layout .. ': shrink hunk excess line unshowable')
  ok(#result.placements == 1, layout .. ': shrink hunk still places paired lines')
  eq(result.placements[1].lines, { 5, 6 }, layout .. ': shrink hunk paired rows only')
end

-- diff1_plain / diff1_raw: a growing hunk (new_count > old_count) pairs every old line
-- 1:1 -- offset i is always within new_count when new_count > old_count.
for _, layout in ipairs({ 'diff1_plain', 'diff1_raw' }) do
  local hunks = { { old_start = 5, old_count = 1, new_start = 5, new_count = 3 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 5, line_end = 5 } },
  }
  local result = signs.plan(layout, hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 0, layout .. ': growing hunk fully paired, not_showable 0')
  ok(#result.placements == 1, layout .. ': growing hunk one placement')
  eq(result.placements[1].lines, { 5 }, layout .. ': growing hunk paired row')
end

-- diff1_plain / diff1_raw: an earlier hunk in the same file has already shifted line
-- numbers, so this hunk's new_start differs from its old_start -- pairing must use the
-- hunk's own old_start/new_start, not assume they match.
for _, layout in ipairs({ 'diff1_plain', 'diff1_raw' }) do
  local hunks = { { old_start = 20, old_count = 2, new_start = 23, new_count = 2 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 20, line_end = 21 } },
  }
  local result = signs.plan(layout, hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 0, layout .. ': asymmetric hunk fully paired, not_showable 0')
  ok(#result.placements == 1, layout .. ': asymmetric hunk one placement')
  eq(result.placements[1].lines, { 23, 24 }, layout .. ': asymmetric hunk paired rows shifted by new_start - old_start')
end

-- diff1_plain / diff1_raw: a thread range straddling a hunk boundary mixes an exact
-- unchanged-region line (before the hunk) with paired in-hunk lines in one placement.
for _, layout in ipairs({ 'diff1_plain', 'diff1_raw' }) do
  local hunks = { { old_start = 5, old_count = 2, new_start = 5, new_count = 2 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 4, line_end = 6 } },
  }
  local result = signs.plan(layout, hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 0, layout .. ': straddling range fully placed, not_showable 0')
  ok(#result.placements == 1, layout .. ': straddling range one placement')
  eq(result.placements[1].lines, { 4, 5, 6 }, layout .. ': straddling range mixes exact + paired rows')
end

-- diff1_inline: pairing is a plain/raw-only concern -- inline keeps anchoring every in-hunk
-- line to the hang row regardless of pairing, unchanged by this fix.
do
  local hunks = { { old_start = 5, old_count = 2, new_start = 5, new_count = 2 } }
  local signed_items = {
    { thread = { status = 'active' }, path = 'f.lua', range = { side = 'left', line_start = 5, line_end = 6 } },
  }
  local result = signs.plan('diff1_inline', hunks, signed_items, 'f.lua', { b = 50 })
  eq(result.not_showable, 0, 'diff1_inline: replacement hunk not_showable 0')
  ok(#result.placements == 1, 'diff1_inline: replacement hunk one placement')
  eq(result.placements[1].lines, { 4 }, 'diff1_inline: replacement hunk still anchors to hang row')
end

-- Items on a different path than entry_path are ignored entirely.
do
  local signed_items = {
    { thread = { status = 'active' }, path = 'other.lua', range = { side = 'right', line_start = 1, line_end = 1 } },
  }
  local result = signs.plan('diff2_horizontal', nil, signed_items, 'f.lua', { a = 10, b = 10 })
  eq(result.placements, {}, 'path mismatch: no placements')
  eq(result.not_showable, 0, 'path mismatch: not_showable 0')
end

-- ---------------------------------------------------------------------------
-- M.refresh -- wiring: diffview snapshot -> plan -> extmark placement
-- ---------------------------------------------------------------------------

-- Two-window layout end to end: left thread marked in buffer a, right thread in buffer b.
do
  state.clear()
  local buf_a, buf_b = make_buf(50), make_buf(50)
  current_snapshot = {
    entry = { path = 'two.lua' },
    layout = 'diff2_horizontal',
    windows = { a = { bufnr = buf_a }, b = { bufnr = buf_b } },
    hunks = nil,
  }
  signs.set_threads({
    make_thread('two.lua', 'left', 3, 3, 'active'),
    make_thread('two.lua', 'right', 10, 10, 'active'),
  })
  signs.refresh()
  eq(marked_rows(buf_a), { 3 }, 'refresh two-window: left thread marked in buf a')
  eq(marked_rows(buf_b), { 10 }, 'refresh two-window: right thread marked in buf b')
  eq(signs.not_showable_count(), 0, 'refresh two-window: not_showable 0')
end

-- diff1_inline end to end: deletion-hunk thread anchors to the hang row diffview's own
-- hunk table (state.hunks) reports -- no git subprocess needed for this layout.
do
  state.clear()
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'inline.lua' },
    layout = 'diff1_inline',
    windows = { b = { bufnr = buf_b } },
    hunks = { { old_start = 10, old_count = 3, new_start = 10, new_count = 0 } },
  }
  signs.set_threads({ make_thread('inline.lua', 'left', 11, 11, 'active') })
  signs.refresh()
  eq(marked_rows(buf_b), { 9 }, 'refresh diff1_inline: deletion anchored to hang row')
  eq(signs.not_showable_count(), 0, 'refresh diff1_inline: not_showable 0')
end

-- diff1_plain end to end: no diffview hunk table (state.hunks is nil for this layout), so
-- refresh self-computes one via `git diff` -- and a thread wholly inside a pure-deletion
-- hunk increments not_showable_count() instead of being placed.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'plain.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  system_result = { code = 0, stdout = '@@ -10,3 +10,0 @@\n-a\n-b\n-c\n', stderr = '' }
  signs.set_threads({ make_thread('plain.lua', 'left', 11, 11, 'active') })
  signs.refresh()
  eq(marked_rows(buf_b), {}, 'refresh diff1_plain: pure-deletion thread not placed')
  eq(signs.not_showable_count(), 1, 'refresh diff1_plain: not_showable incremented')

  ok(#system_calls == 1, 'refresh diff1_plain: git diff invoked once', #system_calls)
  local call = system_calls[1]
  eq(call.cmd, { 'git', 'diff', '-U0', 'deadbeef...HEAD', '--', 'plain.lua' }, 'refresh diff1_plain: git diff argv')
  -- git runs against the stored review root, not vim.fn.getcwd() -- the review root
  -- ('/review-root') never matches the test process's real cwd.
  ok(call.opts and call.opts.cwd == '/review-root', 'refresh diff1_plain: git diff cwd is the stored repo_root', vim.inspect(call.opts))
  ok(call.opts and call.opts.cwd ~= vim.fn.getcwd(), 'refresh diff1_plain: git diff cwd differs from getcwd()')
  restore_system()
end

-- code == 0 with empty stdout is a legitimate "no changes" result: {} is cached and
-- identity mapping applies (a left-side line outside any hunk maps to its own row).
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'unchanged.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  system_result = { code = 0, stdout = '', stderr = '' }
  signs.set_threads({ make_thread('unchanged.lua', 'left', 5, 5, 'active') })
  signs.refresh()
  eq(marked_rows(buf_b), { 5 }, 'refresh diff1_plain empty stdout: identity-mapped to its own row')
  eq(signs.not_showable_count(), 0, 'refresh diff1_plain empty stdout: not_showable 0')
  restore_system()
end

-- -U0 keeps two nearby changes as separate, minimal hunks rather than letting git's
-- default ~3 lines of context merge them into one hunk spanning both -- the merge is
-- exactly what would break the offset-based pairing math in paired_row (a change run's
-- old_count/new_count would include unrelated context lines from the other change). Two
-- -U0 hunks a few lines apart pair independently and correctly.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'nearby.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  system_result = { code = 0, stdout = '@@ -10,1 +10,1 @@\n-old10\n+new10\n@@ -14,1 +14,1 @@\n-old14\n+new14\n', stderr = '' }
  signs.set_threads({
    make_thread('nearby.lua', 'left', 10, 10, 'active'),
    make_thread('nearby.lua', 'left', 14, 14, 'active'),
  })
  signs.refresh()
  eq(marked_rows(buf_b), { 10, 14 }, '-U0: two nearby changes pair independently, not merged by context')
  eq(signs.not_showable_count(), 0, '-U0: both nearby changes fully paired')
  restore_system()
end

-- Cache hit: a second refresh() on the same path performs no second git invocation --
-- the self-computed hunk table is cached per path, not re-derived on every WinEnter.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'cache.lua' },
    layout = 'diff1_raw',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  system_result = { code = 0, stdout = '', stderr = '' }
  signs.set_threads({ make_thread('cache.lua', 'left', 5, 5, 'active') })
  signs.refresh()
  signs.refresh()
  ok(#system_calls == 1, 'cache hit: git diff invoked only once across two refreshes', #system_calls)
  restore_system()
end

-- Git failure (non-zero exit): refresh does not crash, nothing is cached (so a nil result
-- is never mistaken for a legitimate empty hunk table / identity mapping), the thread is
-- not placed, not_showable is incremented, and the user is notified once with the
-- git stderr. A later refresh retries git rather than reusing a cached failure.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_fail = make_buf(50)
  current_snapshot = {
    entry = { path = 'fails.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_fail } },
    hunks = nil,
  }
  stub_system()
  stub_notify()
  system_result = { code = 1, stdout = '', stderr = 'boom' }
  signs.set_threads({ make_thread('fails.lua', 'left', 5, 5, 'active') })
  local call_ok, err = pcall(signs.refresh)
  ok(call_ok, 'git failure: refresh does not crash', err)
  eq(marked_rows(buf_fail), {}, 'git failure: thread not placed')
  eq(signs.not_showable_count(), 1, 'git failure: not_showable incremented')
  ok(#notifications == 1, 'git failure: notified exactly once', #notifications)
  local n = notifications[1]
  ok(n and n.level == vim.log.levels.WARN, 'git failure: notification is WARN')
  ok(n and n.msg:find('boom', 1, true) ~= nil, 'git failure: notification includes git stderr', n and n.msg)

  -- A second refresh on the same failing path re-runs git (failure was never cached), but
  -- the notification is deduped -- an unchanged failure does not warn again.
  signs.refresh()
  ok(#system_calls == 2, 'git failure: not cached, second refresh re-invokes git', #system_calls)
  ok(#notifications == 1, 'git failure: unchanged failure not re-notified', #notifications)

  -- A changed error message on the same path re-notifies.
  system_result = { code = 1, stdout = '', stderr = 'kaboom' }
  signs.refresh()
  ok(#notifications == 2, 'git failure: changed error message re-notifies', #notifications)
  local n2 = notifications[2]
  ok(n2 and n2.msg:find('kaboom', 1, true) ~= nil, 'git failure: new notification includes new stderr', n2 and n2.msg)
  restore_system()
  restore_notify()

  -- A subsequent refresh for a different layout/path is unaffected by the failure.
  local buf_a2, buf_b2 = make_buf(50), make_buf(50)
  current_snapshot = {
    entry = { path = 'other.lua' },
    layout = 'diff2_horizontal',
    windows = { a = { bufnr = buf_a2 }, b = { bufnr = buf_b2 } },
    hunks = nil,
  }
  signs.set_threads({ make_thread('other.lua', 'right', 7, 7, 'active') })
  signs.refresh()
  eq(marked_rows(buf_b2), { 7 }, 'git failure: unrelated later layout still places correctly')
  eq(signs.not_showable_count(), 0, 'git failure: not_showable reset for the unrelated refresh')
end

-- Git failure with empty stderr (non-zero exit, nothing written to stderr): the warning
-- falls back to the exit code instead of rendering a blank detail, mirroring review.lua's
-- `stderr ~= '' and stderr or ('exit ' .. code)` idiom.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_fail = make_buf(50)
  current_snapshot = {
    entry = { path = 'failsempty.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_fail } },
    hunks = nil,
  }
  stub_system()
  stub_notify()
  system_result = { code = 7, stdout = '', stderr = '' }
  signs.set_threads({ make_thread('failsempty.lua', 'left', 5, 5, 'active') })
  signs.refresh()
  ok(#notifications == 1, 'git failure empty stderr: notified once', #notifications)
  local n = notifications[1]
  ok(n and n.msg:find('exit 7', 1, true) ~= nil, 'git failure empty stderr: falls back to exit code', n and n.msg)
  restore_system()
  restore_notify()
end

-- Tracker reset: set_threads() and attach() both clear the last-notified git-diff-failure
-- key, so a fresh review session (or a re-fetch of threads) re-notifies an unchanged
-- failure rather than staying silent because of a previous session's suppression.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_fail = make_buf(50)
  current_snapshot = {
    entry = { path = 'reset.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_fail } },
    hunks = nil,
  }
  stub_system()
  stub_notify()
  system_result = { code = 1, stdout = '', stderr = 'boom' }
  signs.set_threads({ make_thread('reset.lua', 'left', 5, 5, 'active') })
  signs.refresh()
  signs.refresh()
  ok(#notifications == 1, 'tracker reset: unchanged failure only notified once before reset', #notifications)

  signs.set_threads({ make_thread('reset.lua', 'left', 5, 5, 'active') })
  signs.refresh()
  ok(#notifications == 2, 'tracker reset: set_threads() resets the tracker, same failure re-notifies', #notifications)

  signs.attach()
  signs.refresh()
  ok(#notifications == 3, 'tracker reset: attach() resets the tracker, same failure re-notifies', #notifications)
  -- attach() creates a real WinEnter/User autocmd group; tear it down so it doesn't
  -- fire against later tests' buffers/snapshots.
  vim.api.nvim_del_augroup_by_name('AdoPrThreads')

  restore_system()
  restore_notify()
end

-- No ctx / no ctx.base: plain_hunks_for cannot run git at all -- nil hunks, not_showable
-- incremented, no vim.system call, and (matching M.refresh's own notify guard) no
-- notification since there is no git stderr to report.
do
  state.clear() -- no active PR context
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'noctx.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  stub_notify()
  signs.set_threads({ make_thread('noctx.lua', 'left', 5, 5, 'active') })
  signs.refresh()
  eq(marked_rows(buf_b), {}, 'no ctx: thread not placed')
  eq(signs.not_showable_count(), 1, 'no ctx: not_showable incremented')
  eq(#system_calls, 0, 'no ctx: git never invoked')
  eq(#notifications, 0, 'no ctx: no notification (nothing failed, just unavailable)')
  restore_system()
  restore_notify()
end

do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p' }) -- no base
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'nobase.lua' },
    layout = 'diff1_raw',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  stub_notify()
  signs.set_threads({ make_thread('nobase.lua', 'left', 5, 5, 'active') })
  signs.refresh()
  eq(marked_rows(buf_b), {}, 'no base: thread not placed')
  eq(signs.not_showable_count(), 1, 'no base: not_showable incremented')
  eq(#system_calls, 0, 'no base: git never invoked')
  eq(#notifications, 0, 'no base: no notification')
  restore_system()
  restore_notify()
end

-- ctx.base set but ctx.repo_root missing: plain_hunks_for must not fall back to
-- vim.system's default cwd (the process cwd) -- the exact failure mode this module exists
-- to eliminate -- so it bails out the same way a missing ctx.base does.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef' }) -- no repo_root
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'norepo.lua' },
    layout = 'diff1_raw',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  stub_notify()
  signs.set_threads({ make_thread('norepo.lua', 'left', 5, 5, 'active') })
  signs.refresh()
  eq(marked_rows(buf_b), {}, 'no repo_root: thread not placed')
  eq(signs.not_showable_count(), 1, 'no repo_root: not_showable incremented')
  eq(#system_calls, 0, 'no repo_root: git never invoked')
  eq(#notifications, 0, 'no repo_root: no notification')
  restore_system()
  restore_notify()
end

-- Cleanup: refresh after a layout switch clears extmarks from buffers the previous layout
-- marked, even when the new layout no longer signs into that buffer at all.
do
  state.clear()
  local buf_a, buf_b = make_buf(50), make_buf(50)
  current_snapshot = {
    entry = { path = 'switch.lua' },
    layout = 'diff2_horizontal',
    windows = { a = { bufnr = buf_a }, b = { bufnr = buf_b } },
    hunks = nil,
  }
  signs.set_threads({ make_thread('switch.lua', 'left', 3, 3, 'active') })
  signs.refresh()
  ok(#marked_rows(buf_a) == 1, 'cleanup: initial mark present in buf a')

  local buf_c = make_buf(50)
  current_snapshot = {
    entry = { path = 'switch.lua' },
    layout = 'diff1_inline',
    windows = { b = { bufnr = buf_c } },
    hunks = {},
  }
  signs.refresh()
  eq(marked_rows(buf_a), {}, 'cleanup: stale buf a extmarks cleared after layout switch')
end

-- ---------------------------------------------------------------------------
-- M.refresh -- not_showable re-notify on every count change (issue #30: review.lua
-- used to notify once on open; later navigation silently left new counts unannounced)
-- ---------------------------------------------------------------------------

-- Two unshowable threads (pure-deletion hunk, diff1_plain) notify once with the count.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'notify.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  system_result = { code = 0, stdout = '@@ -10,3 +10,0 @@\n-a\n-b\n-c\n', stderr = '' }
  stub_notify()
  signs.set_threads({
    make_thread('notify.lua', 'left', 10, 11, 'active'),
    make_thread('notify.lua', 'left', 12, 12, 'active'),
  })
  signs.refresh()
  eq(signs.not_showable_count(), 2, 'notify: two unshowable threads counted')
  ok(#notifications == 1, 'notify: one notification on first refresh', #notifications)
  ok(
    notifications[1] and notifications[1].msg:match('2 left%-side threads not showable'),
    'notify: message reports the count',
    notifications[1] and notifications[1].msg
  )
  ok(notifications[1] and notifications[1].level == vim.log.levels.INFO, 'notify: level is INFO')

  -- A second refresh with the same file/threads (e.g. bouncing WinEnter between a
  -- file's two diff windows) does not repeat the notification.
  signs.refresh()
  ok(#notifications == 1, 'notify: unchanged count on later refresh does not repeat', #notifications)

  -- Navigating to a different unshowable count re-notifies.
  signs.set_threads({ make_thread('notify.lua', 'left', 10, 11, 'active') })
  signs.refresh()
  ok(#notifications == 2, 'notify: changed count notifies again', #notifications)
  ok(
    notifications[2] and notifications[2].msg:match('1 left%-side thread not showable'),
    'notify: singular wording for count 1',
    notifications[2] and notifications[2].msg
  )

  -- Dropping to zero updates the tracker but stays silent (default: no "all showable"
  -- notification per the ticket).
  signs.set_threads({})
  signs.refresh()
  eq(signs.not_showable_count(), 0, 'notify: count drops to 0')
  ok(#notifications == 2, 'notify: drop to 0 stays silent', #notifications)

  restore_system()
  restore_notify()
end

-- set_threads() resets the tracker, so a new review session (or a re-fetch of threads)
-- re-notifies even for a count it already notified about before.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'reset.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  system_result = { code = 0, stdout = '@@ -10,3 +10,0 @@\n-a\n-b\n-c\n', stderr = '' }
  stub_notify()
  local threads = { make_thread('reset.lua', 'left', 10, 11, 'active') }
  signs.set_threads(threads)
  signs.refresh()
  ok(#notifications == 1, 'reset: initial refresh notifies')

  signs.set_threads(threads)
  signs.refresh()
  ok(#notifications == 2, 'reset: set_threads resets tracker, same count re-notifies', #notifications)

  restore_system()
  restore_notify()
end

-- Navigating to a different file whose not_showable count happens to match the
-- previous file's count still re-notifies -- the dedup key must include the path, not
-- just the count, or two files with equal counts wrongly stay silent on navigation.
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'cross-a.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  system_result = { code = 0, stdout = '@@ -10,3 +10,0 @@\n-a\n-b\n-c\n', stderr = '' }
  stub_notify()
  signs.set_threads({
    make_thread('cross-a.lua', 'left', 10, 10, 'active'),
    make_thread('cross-b.lua', 'left', 10, 10, 'active'),
  })
  signs.refresh()
  eq(signs.not_showable_count(), 1, 'cross-file: file A not_showable count 1')
  ok(#notifications == 1, 'cross-file: first refresh notifies')

  -- Same threads retained (no set_threads() call) -- only the file under the cursor
  -- changes, to a different path with the same not_showable count as file A.
  current_snapshot.entry.path = 'cross-b.lua'
  signs.refresh()
  eq(signs.not_showable_count(), 1, 'cross-file: file B not_showable count 1 (same as A)')
  ok(#notifications == 2, 'cross-file: different file with same count notifies again', #notifications)

  restore_system()
  restore_notify()
end

-- attach() also resets the tracker (a fresh :AdoPrReview session should re-notify even
-- if the previous session already notified about the same count).
do
  state.clear()
  state.set({ id = 1, repositoryId = 'r', project = 'p', base = 'deadbeef', repo_root = '/review-root' })
  local buf_b = make_buf(50)
  current_snapshot = {
    entry = { path = 'attach.lua' },
    layout = 'diff1_plain',
    windows = { b = { bufnr = buf_b } },
    hunks = nil,
  }
  stub_system()
  system_result = { code = 0, stdout = '@@ -10,3 +10,0 @@\n-a\n-b\n-c\n', stderr = '' }
  stub_notify()
  signs.set_threads({ make_thread('attach.lua', 'left', 10, 11, 'active') })
  signs.refresh()
  ok(#notifications == 1, 'attach: initial refresh notifies')

  signs.attach()
  signs.refresh()
  ok(#notifications == 2, 'attach: attach() resets tracker, same count re-notifies', #notifications)

  restore_system()
  restore_notify()
end

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do
    io.stderr:write('  - ' .. f .. '\n')
  end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
