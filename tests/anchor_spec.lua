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

-- Cursor in the RIGHT (new) window anchors on the new path, right side. A plain cursor
-- comment is the degenerate range where line_start == line_end (ADR-0003).
do
  local a, err = anchor.resolve({
    path = 'src/foo.lua',
    oldpath = 'src/foo.lua',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1001,
    line_start = 42,
    line_end = 42,
  })
  ok(a and not err, 'right: no error', err)
  eq(a, { filePath = '/src/foo.lua', side = 'right', line_start = 42, line_end = 42 }, 'right: anchor')
end

-- Cursor in the LEFT (old) window anchors on the old path, left side.
do
  local a = anchor.resolve({
    path = 'src/foo.lua',
    oldpath = 'src/foo.lua',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1000,
    line_start = 7,
    line_end = 7,
  })
  eq(a, { filePath = '/src/foo.lua', side = 'left', line_start = 7, line_end = 7 }, 'left: anchor')
end

-- A visual-selection range spanning lines posts one thread with the correct start/end,
-- not one thread per line (issue #61 acceptance criterion).
do
  local a = anchor.resolve({
    path = 'src/foo.lua',
    oldpath = 'src/foo.lua',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1001,
    line_start = 10,
    line_end = 15,
  })
  eq(a, { filePath = '/src/foo.lua', side = 'right', line_start = 10, line_end = 15 }, 'range: anchor spans the selection')
end

-- A rename keeps each side on its own path.
do
  local a = anchor.resolve({
    path = 'src/new.lua',
    oldpath = 'src/old.lua',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1000,
    line_start = 3,
    line_end = 3,
  })
  eq(a, { filePath = '/src/old.lua', side = 'left', line_start = 3, line_end = 3 }, 'rename left uses oldpath')
end

-- Windows-style backslashes normalize to forward slashes; no double leading slash.
do
  local a = anchor.resolve({
    path = 'src\\a\\b.lua',
    oldpath = nil,
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1001,
    line_start = 1,
    line_end = 1,
  })
  eq(a, { filePath = '/src/a/b.lua', side = 'right', line_start = 1, line_end = 1 }, 'backslash normalized')
end

-- Cursor outside both diff windows (e.g. the file panel) is an error, not a guess.
do
  local a, err = anchor.resolve({
    path = 'src/foo.lua',
    oldpath = 'src/foo.lua',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1234,
    line_start = 5,
    line_end = 5,
  })
  ok(a == nil and err ~= nil, 'panel cursor: rejected', tostring(err))
end

-- Left side of a plain MODIFIED file: diffview only sets oldpath on renames, so
-- nil oldpath falls back to path (found live: every left-pane comment on a
-- modified file errored 'no file on the left side').
do
  local a, err = anchor.resolve({
    path = 'src/foo.lua',
    oldpath = nil,
    status = 'M',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1000,
    line_start = 9,
    line_end = 9,
  })
  ok(a and not err, 'modified left: no error', err)
  eq(a, { filePath = '/src/foo.lua', side = 'left', line_start = 9, line_end = 9 }, 'modified left falls back to path')
end

-- Left side of an ADDED file is an error — added-ness is status, not nil oldpath.
do
  local a, err = anchor.resolve({
    path = 'src/added.lua',
    oldpath = nil,
    status = 'A',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1000,
    line_start = 5,
    line_end = 5,
  })
  ok(a == nil and err ~= nil, 'added file left side: rejected', tostring(err))
end

-- Right side of a DELETED file is an error — no new side exists.
do
  local a, err = anchor.resolve({
    path = 'src/deleted.lua',
    oldpath = nil,
    status = 'D',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1001,
    line_start = 5,
    line_end = 5,
  })
  ok(a == nil and err ~= nil, 'deleted file right side: rejected', tostring(err))
end

-- Left side of a DELETED file resolves normally — a deleted file is left-side ONLY, which
-- is why an active diff-base override makes it entirely uncommentable (issue #54).
do
  local a, err = anchor.resolve({
    path = 'src/deleted.lua',
    oldpath = nil,
    status = 'D',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1000,
    line_start = 4,
    line_end = 4,
  })
  ok(a and not err, 'deleted left: no error', err)
  eq(a, { filePath = '/src/deleted.lua', side = 'left', line_start = 4, line_end = 4 }, 'deleted file left side: side is left')
end

-- A "null" path sentinel (diffview's deleted-side marker) is an error.
do
  local a, err = anchor.resolve({
    path = 'null',
    oldpath = 'src/deleted.lua',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1001,
    line_start = 5,
    line_end = 5,
  })
  ok(a == nil and err ~= nil, 'null right path: rejected', tostring(err))
end

-- A reversed range (line_start > line_end) is an error, not a silently-posted reversed span.
do
  local a, err = anchor.resolve({
    path = 'src/foo.lua',
    oldpath = 'src/foo.lua',
    winid_a = 1000,
    winid_b = 1001,
    cur_win = 1001,
    line_start = 15,
    line_end = 10,
  })
  ok(a == nil and err ~= nil, 'reversed range: rejected', tostring(err))
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
