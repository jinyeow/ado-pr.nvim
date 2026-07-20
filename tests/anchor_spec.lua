-- Pure-logic tests for ado-pr.anchor.resolve — the diffview-cursor → ADO thread
-- anchor mapping. Run headless: `nvim --headless -l tests/anchor_spec.lua`.
-- No test framework: a tiny assert harness (plenary is not a dependency).
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local anchor = require('ado-pr.anchor')

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

-- Cursor in the RIGHT (new) window anchors on the new path, right side.
do
  local a, err = anchor.resolve({
    path = 'src/foo.lua', oldpath = 'src/foo.lua',
    winid_a = 1000, winid_b = 1001, cur_win = 1001, cur_line = 42,
  })
  ok(a and not err, 'right: no error', err)
  eq(a, { filePath = '/src/foo.lua', line = 42, side = 'right' }, 'right: anchor')
end

-- Cursor in the LEFT (old) window anchors on the old path, left side.
do
  local a = anchor.resolve({
    path = 'src/foo.lua', oldpath = 'src/foo.lua',
    winid_a = 1000, winid_b = 1001, cur_win = 1000, cur_line = 7,
  })
  eq(a, { filePath = '/src/foo.lua', line = 7, side = 'left' }, 'left: anchor')
end

-- A rename keeps each side on its own path.
do
  local a = anchor.resolve({
    path = 'src/new.lua', oldpath = 'src/old.lua',
    winid_a = 1000, winid_b = 1001, cur_win = 1000, cur_line = 3,
  })
  eq(a, { filePath = '/src/old.lua', line = 3, side = 'left' }, 'rename left uses oldpath')
end

-- Windows-style backslashes normalize to forward slashes; no double leading slash.
do
  local a = anchor.resolve({
    path = 'src\\a\\b.lua', oldpath = nil,
    winid_a = 1000, winid_b = 1001, cur_win = 1001, cur_line = 1,
  })
  eq(a, { filePath = '/src/a/b.lua', line = 1, side = 'right' }, 'backslash normalized')
end

-- Cursor outside both diff windows (e.g. the file panel) is an error, not a guess.
do
  local a, err = anchor.resolve({
    path = 'src/foo.lua', oldpath = 'src/foo.lua',
    winid_a = 1000, winid_b = 1001, cur_win = 1234, cur_line = 5,
  })
  ok(a == nil and err ~= nil, 'panel cursor: rejected', tostring(err))
end

-- Left side of an added file (no old path) is an error — nothing to anchor to.
do
  local a, err = anchor.resolve({
    path = 'src/added.lua', oldpath = nil,
    winid_a = 1000, winid_b = 1001, cur_win = 1000, cur_line = 5,
  })
  ok(a == nil and err ~= nil, 'added file left side: rejected', tostring(err))
end

-- A "null" path sentinel (diffview's deleted-side marker) is an error.
do
  local a, err = anchor.resolve({
    path = 'null', oldpath = 'src/deleted.lua',
    winid_a = 1000, winid_b = 1001, cur_win = 1001, cur_line = 5,
  })
  ok(a == nil and err ~= nil, 'null right path: rejected', tostring(err))
end

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do io.stderr:write('  - ' .. f .. '\n') end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
