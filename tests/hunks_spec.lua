-- Pure-logic tests for ado-pr.hunks — mapping an old-side (left) line number through a
-- hunk table to the corresponding new-buffer row, plus parsing that hunk table out of a
-- unified diff. Run headless: `nvim --headless -l tests/hunks_spec.lua`.
-- No test framework: a tiny assert harness (plenary is not a dependency), same shape as
-- tests/threads_spec.lua.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local hunks = require('ado-pr.hunks')

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
-- old_line_to_row
-- ---------------------------------------------------------------------------

-- No hunks at all: every old line is the same row in the new buffer.
do
  local row, exact = hunks.old_line_to_row({}, 42)
  ok(row == 42 and exact == true, 'no hunks: identity mapping', tostring(row) .. ' ' .. tostring(exact))
end

-- A line before any hunk is unshifted.
do
  local h = { { old_start = 10, old_count = 1, new_start = 10, new_count = 3 } }
  local row, exact = hunks.old_line_to_row(h, 5)
  ok(row == 5 and exact == true, 'before first hunk: unshifted')
end

-- A line after a hunk that added lines (new_count > old_count) shifts forward.
do
  local h = { { old_start = 10, old_count = 1, new_start = 10, new_count = 3 } }
  local row, exact = hunks.old_line_to_row(h, 20)
  ok(row == 22 and exact == true, 'after growing hunk: shifted forward by +2', tostring(row))
end

-- A line after a hunk that removed lines (old_count > new_count) shifts backward.
do
  local h = { { old_start = 10, old_count = 5, new_start = 10, new_count = 1 } }
  local row, exact = hunks.old_line_to_row(h, 20)
  ok(row == 16 and exact == true, 'after shrinking hunk: shifted backward by -4', tostring(row))
end

-- A pure modification (old_count == new_count): the hunk table gives no per-line
-- correspondence within the hunk, so even a 1:1-shaped change is not exact -- it anchors
-- to the row above the hunk, same as any other in-hunk line.
do
  local h = { { old_start = 10, old_count = 3, new_start = 10, new_count = 3 } }
  local row, exact = hunks.old_line_to_row(h, 11)
  ok(row == 9 and exact == false, 'in-hunk modification: anchors above the hunk, not exact', tostring(row) .. ' ' .. tostring(exact))
end

-- Every line inside a shrinking hunk's old range anchors to the same row above the hunk,
-- regardless of whether it is within new_count or beyond it -- the hunk carries no
-- per-line correspondence to tell them apart.
do
  local h = { { old_start = 10, old_count = 5, new_start = 10, new_count = 2 } }
  local row, exact = hunks.old_line_to_row(h, 11)
  ok(row == 9 and exact == false, 'in-hunk line within new_count: still not exact', tostring(row) .. ' ' .. tostring(exact))
end

-- A pure deletion beyond new_count anchors to the same row above the hunk.
do
  local h = { { old_start = 10, old_count = 5, new_start = 10, new_count = 2 } }
  local row, exact = hunks.old_line_to_row(h, 13)
  ok(row == 9 and exact == false, 'excess deletion: anchors above the hunk', tostring(row) .. ' ' .. tostring(exact))
end

-- A whole-hunk deletion (new_count == 0) anchors to the row before the hunk.
do
  local h = { { old_start = 10, old_count = 3, new_start = 10, new_count = 0 } }
  local row, exact = hunks.old_line_to_row(h, 11)
  ok(row == 9 and exact == false, 'whole-hunk deletion: anchors to row before hunk', tostring(row) .. ' ' .. tostring(exact))
end

-- A whole-hunk deletion at the very top of the file anchors to row 0 (caller clamps).
do
  local h = { { old_start = 1, old_count = 2, new_start = 1, new_count = 0 } }
  local row, exact = hunks.old_line_to_row(h, 1)
  ok(row == 0 and exact == false, 'whole-hunk deletion at file start: row 0', tostring(row))
end

-- Multiple hunks: mapping accumulates shift across all hunks before the target line.
do
  local h = {
    { old_start = 5, old_count = 1, new_start = 5, new_count = 3 }, -- +2
    { old_start = 20, old_count = 4, new_start = 22, new_count = 1 }, -- -3
  }
  -- Line 30 is after both hunks: shift = +2 - 3 = -1.
  local row, exact = hunks.old_line_to_row(h, 30)
  ok(row == 29 and exact == true, 'multiple hunks: cumulative shift', tostring(row))

  -- Line 12 sits between the two hunks: only the first hunk's shift applies.
  row, exact = hunks.old_line_to_row(h, 12)
  ok(row == 14 and exact == true, 'multiple hunks: between hunks uses only prior shift', tostring(row))
end

-- Fixture-shaped set mirroring the mapping fixture: a modification hunk, a shrinking hunk
-- whose whole old range anchors to one row, and unchanged lines throughout.
do
  local h = {
    { old_start = 3, old_count = 1, new_start = 3, new_count = 1 }, -- modification
    { old_start = 10, old_count = 4, new_start = 10, new_count = 2 }, -- shrink: old 10-13 -> new 10-11
  }
  eq({ hunks.old_line_to_row(h, 1) }, { 1, true }, 'fixture: before all hunks')
  eq({ hunks.old_line_to_row(h, 3) }, { 2, false }, 'fixture: modification line anchors above the hunk')
  eq({ hunks.old_line_to_row(h, 9) }, { 9, true }, 'fixture: unchanged between hunks')
  eq({ hunks.old_line_to_row(h, 10) }, { 9, false }, 'fixture: shrink hunk, first old line anchors above the hunk')
  eq({ hunks.old_line_to_row(h, 11) }, { 9, false }, 'fixture: shrink hunk, second old line anchors to same row')
  eq({ hunks.old_line_to_row(h, 12) }, { 9, false }, 'fixture: shrink hunk, deleted line 1 anchors to same row')
  eq({ hunks.old_line_to_row(h, 13) }, { 9, false }, 'fixture: shrink hunk, deleted line 2 anchors to same row')
  eq({ hunks.old_line_to_row(h, 14) }, { 12, true }, 'fixture: after shrink hunk, shifted by -2')
end

-- ---------------------------------------------------------------------------
-- parse_unified_hunks
-- ---------------------------------------------------------------------------

-- A single hunk with explicit counts on both sides.
do
  local h = hunks.parse_unified_hunks('@@ -10,5 +10,2 @@ some context\n-a\n-b\n+c\n')
  eq(h, { { old_start = 10, old_count = 5, new_start = 10, new_count = 2 } }, 'parse: explicit counts')
end

-- A one-line hunk on either side omits the count (defaults to 1).
do
  local h = hunks.parse_unified_hunks('@@ -5 +5 @@\n-x\n+y\n')
  eq(h, { { old_start = 5, old_count = 1, new_start = 5, new_count = 1 } }, 'parse: omitted counts default to 1')
end

-- An explicit zero count (pure insertion / pure deletion hunk) is not confused with an
-- omitted count.
do
  local h = hunks.parse_unified_hunks('@@ -8,0 +9,3 @@\n+a\n+b\n+c\n')
  eq(h, { { old_start = 8, old_count = 0, new_start = 9, new_count = 3 } }, 'parse: explicit zero count')
end

-- Multiple hunks in one diff, in order.
do
  local diff = table.concat({
    'diff --git a/f b/f',
    'index 111..222 100644',
    '--- a/f',
    '+++ b/f',
    '@@ -1,2 +1,3 @@',
    ' a',
    '+b',
    ' c',
    '@@ -10,3 +11,1 @@',
    '-x',
    '-y',
    ' z',
  }, '\n')
  local h = hunks.parse_unified_hunks(diff)
  eq(h, {
    { old_start = 1, old_count = 2, new_start = 1, new_count = 3 },
    { old_start = 10, old_count = 3, new_start = 11, new_count = 1 },
  }, 'parse: multiple hunks in order')
end

-- No hunk headers at all (e.g. empty diff, file unchanged): empty table, not nil.
do
  local h = hunks.parse_unified_hunks('')
  eq(h, {}, 'parse: empty diff yields empty table')
end

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do io.stderr:write('  - ' .. f .. '\n') end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
