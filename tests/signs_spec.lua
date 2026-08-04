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
  eq(call.cmd, { 'git', 'diff', 'deadbeef...HEAD', '--', 'plain.lua' }, 'refresh diff1_plain: git diff argv')
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

  -- A second refresh on the same failing path re-runs git (failure was never cached).
  signs.refresh()
  ok(#system_calls == 2, 'git failure: not cached, second refresh re-invokes git', #system_calls)
  ok(#notifications == 2, 'git failure: notified again on retry', #notifications)
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

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do
    io.stderr:write('  - ' .. f .. '\n')
  end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
