-- Hunk-table line mapping for left-side (old-file) threads in single-window diffview
-- layouts (diff1_inline, diff1_plain, diff1_raw). Pure: no Neovim API, no diffview, no
-- git -- same split threads.lua uses for its resolver (docs/specs/left-side-thread-
-- anchoring.md).
--
-- Hunk shape: { old_start, old_count, new_start, new_count }, one-based, sorted by
-- old_start. This is diffview.scene.inline_diff.get_hunks()'s own shape (cached at
-- diffview_state.current().hunks for diff1_inline*) and, separately, what
-- parse_unified_hunks below extracts from `git diff` output for diff1_plain/diff1_raw,
-- which attach no diffview diff renderer to read a hunk table from at all.
local M = {}

-- Map an old-side line number through `hunks` to the row diffview renders it at in the
-- new-side buffer every single-window layout shows.
--
-- Returns row, exact:
--   exact == true   old_line sits in an unchanged region (outside every hunk) -- `row` is
--                   that line's real content row in the new buffer.
--   exact == false  old_line falls inside a hunk's old range. A hunk table carries no
--                   per-line correspondence within a hunk (`@@ -10,5 +10,2 @@` says old
--                   10-14 became new 10-11 as a block, not that old 10 IS new 10), so no
--                   row inside the hunk can be claimed as old_line's real content --
--                   including a hunk that is a pure deletion. `row` is the row diffview's
--                   own virtual deletion lines hang from, and the honest anchor for any
--                   in-hunk line: the row directly above the hunk (new_start - 1; may be
--                   0 at file start -- callers clamp).
function M.old_line_to_row(hunks, old_line)
  local shift = 0
  for _, h in ipairs(hunks or {}) do
    if old_line < h.old_start + (h.old_count == 0 and 1 or 0) then
      return old_line + shift, true
    end
    if old_line < h.old_start + h.old_count then
      return h.new_start - 1, false
    end
    shift = shift + (h.new_count - h.old_count)
  end
  return old_line + shift, true
end

-- Parse `@@ -old_start,old_count +new_start,new_count @@` hunk headers out of unified
-- diff text (a `git diff` invocation's stdout) into the same hunk-table shape
-- old_line_to_row consumes. A unified diff omits the count when it is 1 (`@@ -5 +5 @@`
-- means count 1 on that side); an explicit `,0` (pure insertion/deletion hunk) is kept
-- as 0, not confused with an omitted count.
function M.parse_unified_hunks(diff_text)
  local result = {}
  for old_start, old_count, new_start, new_count in (diff_text or ''):gmatch('@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@') do
    table.insert(result, {
      old_start = tonumber(old_start),
      old_count = old_count ~= '' and tonumber(old_count) or 1,
      new_start = tonumber(new_start),
      new_count = new_count ~= '' and tonumber(new_count) or 1,
    })
  end
  return result
end

return M
