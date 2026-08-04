-- Pure-logic tests for ado-pr.diffview_state.current() — the "what is the
-- user looking at in diffview right now" snapshot. Run headless:
-- `nvim --headless -l tests/diffview_state_spec.lua`.
-- No test framework: a tiny assert harness (plenary is not a dependency).
--
-- Stubbing: diffview_state.current() requires 'diffview.lib' and
-- 'diffview.scene.inline_diff' lazily inside its body (both wrapped in
-- pcall), so a package.loaded stub for 'diffview.lib' installed before
-- require('ado-pr.diffview_state') is picked up on every call — mutating
-- the closure-captured `current_view` upvalue between test blocks is
-- enough, no need to re-stub per test.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local current_view = nil
package.loaded['diffview.lib'] = {
  get_current_view = function()
    return current_view
  end,
}

local diffview_state = require('ado-pr.diffview_state')

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

local function set_view(entry, cur_layout)
  current_view = { cur_entry = entry, cur_layout = cur_layout }
end

-- Stub for diffview.scene.inline_diff.get_hunks, with a call log so tests
-- can assert it was (or was not) invoked, and with what bufnr.
local get_hunks_calls
local function stub_inline_diff(result)
  get_hunks_calls = {}
  package.loaded['diffview.scene.inline_diff'] = {
    get_hunks = function(bufnr)
      table.insert(get_hunks_calls, bufnr)
      return result
    end,
  }
end
local function clear_inline_diff()
  package.loaded['diffview.scene.inline_diff'] = nil
end

-- 1: no active view (get_current_view returns nil) -> nil, error.
do
  current_view = nil
  local snap, err = diffview_state.current()
  ok(snap == nil, 'case1: nil snapshot')
  eq(err, 'no active diffview file under the cursor', 'case1: error')
end

-- 2: view present but missing cur_entry -> same error.
do
  current_view = { cur_entry = nil, cur_layout = { name = 'diff1_plain', symbols = {} } }
  local snap, err = diffview_state.current()
  ok(snap == nil, 'case2: nil snapshot')
  eq(err, 'no active diffview file under the cursor', 'case2: error')
end

-- 3: diff1_plain-shaped layout, symbols = {'b'} only.
do
  set_view({ path = 'src/foo.lua', oldpath = nil, status = 'M' }, { name = 'diff1_plain', symbols = { 'b' }, b = { id = 2001, file = { bufnr = 10 } } })
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case3: no error', err)
  eq(snap.windows, { b = { winid = 2001, bufnr = 10 } }, 'case3: windows')
  ok(snap.windows.a == nil, 'case3: no a window')
  ok(snap.hunks == nil, 'case3: no hunks')
  eq(snap.entry, { path = 'src/foo.lua', oldpath = nil, status = 'M' }, 'case3: entry passthrough')
end

-- 4: diff2_horizontal-shaped layout, both a and b present.
do
  set_view({ path = 'src/bar.lua', oldpath = 'src/old_bar.lua', status = 'R' }, {
    name = 'diff2_horizontal',
    symbols = { 'a', 'b' },
    a = { id = 3001, file = { bufnr = 20 } },
    b = { id = 3002, file = { bufnr = 21 } },
  })
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case4: no error', err)
  eq(snap.windows, {
    a = { winid = 3001, bufnr = 20 },
    b = { winid = 3002, bufnr = 21 },
  }, 'case4: windows')
  ok(snap.hunks == nil, 'case4: no hunks')
end

-- 5: a symbol whose window table is nil, or lacks .id, is skipped -- not an
-- error -- while remaining valid windows still populate.
do
  set_view({ path = 'src/baz.lua', oldpath = nil, status = 'M' }, {
    name = 'diff2_horizontal',
    symbols = { 'a', 'b' },
    a = nil,
    b = { id = 4001, file = { bufnr = 30 } },
  })
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case5a: no error', err)
  ok(snap.windows.a == nil, 'case5a: a skipped (nil window)')
  eq(snap.windows.b, { winid = 4001, bufnr = 30 }, 'case5a: b still populated')

  set_view({ path = 'src/baz.lua', oldpath = nil, status = 'M' }, {
    name = 'diff2_horizontal',
    symbols = { 'a', 'b' },
    a = { file = { bufnr = 31 } }, -- no .id
    b = { id = 4002, file = { bufnr = 32 } },
  })
  snap, err = diffview_state.current()
  ok(snap and not err, 'case5b: no error', err)
  ok(snap.windows.a == nil, 'case5b: a skipped (no id)')
  eq(snap.windows.b, { winid = 4002, bufnr = 32 }, 'case5b: b still populated')
end

-- 6: a window with .id but no .file -> windows[sym] = { winid = ..., bufnr = nil }.
do
  set_view({ path = 'src/qux.lua', oldpath = nil, status = 'A' }, { name = 'diff1_plain', symbols = { 'b' }, b = { id = 5001 } })
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case6: no error', err)
  eq(snap.windows.b, { winid = 5001, bufnr = nil }, 'case6: bufnr nil, winid set')
end

-- 7: diff1_inline layout with windows.b.bufnr set -> hunks equals whatever
-- the stubbed get_hunks(bufnr) returns, correct bufnr passed through.
do
  stub_inline_diff({ { old_start = 1, old_count = 1, new_start = 1, new_count = 2 } })
  set_view({ path = 'src/inl.lua', oldpath = nil, status = 'M' }, { name = 'diff1_inline', symbols = { 'b' }, b = { id = 6001, file = { bufnr = 40 } } })
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case7: no error', err)
  eq(snap.hunks, { { old_start = 1, old_count = 1, new_start = 1, new_count = 2 } }, 'case7: hunks')
  eq(get_hunks_calls, { 40 }, 'case7: get_hunks called with bufnr')
  clear_inline_diff()
end

-- 8: diff1_inline_pinned layout -> same as case 7.
do
  stub_inline_diff({ { old_start = 5, old_count = 0, new_start = 5, new_count = 1 } })
  set_view({ path = 'src/pin.lua', oldpath = nil, status = 'M' }, { name = 'diff1_inline_pinned', symbols = { 'b' }, b = { id = 6002, file = { bufnr = 41 } } })
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case8: no error', err)
  eq(snap.hunks, { { old_start = 5, old_count = 0, new_start = 5, new_count = 1 } }, 'case8: hunks')
  eq(get_hunks_calls, { 41 }, 'case8: get_hunks called with bufnr')
  clear_inline_diff()
end

-- 9: diff1_inline layout but windows.b.bufnr is nil -> get_hunks must not
-- be called, hunks == nil.
do
  stub_inline_diff({ { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } })
  set_view(
    { path = 'src/nob.lua', oldpath = nil, status = 'M' },
    { name = 'diff1_inline', symbols = { 'b' }, b = { id = 6003 } } -- no .file
  )
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case9: no error', err)
  ok(snap.hunks == nil, 'case9: no hunks')
  eq(get_hunks_calls, {}, 'case9: get_hunks not called')
  clear_inline_diff()
end

-- 10: diff1_inline layout where require('diffview.scene.inline_diff')
-- itself fails -> hunks == nil, no error propagates out of M.current().
do
  clear_inline_diff()
  package.preload['diffview.scene.inline_diff'] = function()
    error('boom')
  end
  set_view({ path = 'src/failreq.lua', oldpath = nil, status = 'M' }, { name = 'diff1_inline', symbols = { 'b' }, b = { id = 6004, file = { bufnr = 42 } } })
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case10: no error propagates', err)
  ok(snap.hunks == nil, 'case10: no hunks')
  package.preload['diffview.scene.inline_diff'] = nil
end

-- 11: a non-inline layout (e.g. diff2_horizontal) even with a populated
-- bufnr -> hunks == nil always, get_hunks never invoked.
do
  stub_inline_diff({ { old_start = 1, old_count = 1, new_start = 1, new_count = 1 } })
  set_view({ path = 'src/horiz.lua', oldpath = nil, status = 'M' }, {
    name = 'diff2_horizontal',
    symbols = { 'a', 'b' },
    a = { id = 7001, file = { bufnr = 50 } },
    b = { id = 7002, file = { bufnr = 51 } },
  })
  local snap, err = diffview_state.current()
  ok(snap and not err, 'case11: no error', err)
  ok(snap.hunks == nil, 'case11: no hunks')
  eq(get_hunks_calls, {}, 'case11: get_hunks not called')
  clear_inline_diff()
end

-- 12: diffview.lib itself unavailable (require fails) -> nil, 'diffview.nvim is not available'.
do
  package.loaded['diffview.lib'] = nil
  package.preload['diffview.lib'] = function()
    error('boom')
  end
  local snap, err = diffview_state.current()
  ok(snap == nil, 'case12: nil snapshot')
  eq(err, 'diffview.nvim is not available', 'case12: error')
  package.preload['diffview.lib'] = nil
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
