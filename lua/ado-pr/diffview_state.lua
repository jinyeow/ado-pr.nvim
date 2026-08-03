-- Single place answering "what is the user looking at in diffview right
-- now". The write path (anchor.lua), the sign renderer and the follower
-- pane (future tickets) all need the same answers.
--
-- Reads view.cur_layout, not the file entry's template layout: diffview
-- clones the entry's layout into the view (standard_view.lua:
-- `self.cur_layout = layout:clone()`), and the template's window ids are
-- never the displayed ones (live smoke test 2026-07-23: every comment
-- errored 'cursor is not in a diff window', fixed in commit 4c411db).
local M = {}

local function get_view()
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    return nil, 'diffview.nvim is not available'
  end
  local view = lib.get_current_view()
  if not view or not view.cur_entry then
    return nil, 'no active diffview file under the cursor'
  end
  return view
end

-- Snapshot of the active diffview view. Returns nil, err when there is no
-- active diffview file under the cursor.
--
-- Returns:
--   entry   { path, oldpath, status } for the file under the cursor
--   layout  layout kind, e.g. 'diff1_plain' | 'diff1_inline' | 'diff2_horizontal'
--   windows per-side { winid, bufnr } for the sides the current layout has a
--           real window for (diff1_* layouts have only `b`; diff2_* layouts
--           have `a` and `b`; merge layouts have more)
--   hunks   the hunk table diffview has already computed, only set for an
--           inline layout ({ old_start, old_count, new_start, new_count }[])
function M.current()
  local view, err = get_view()
  if not view then
    return nil, err
  end

  local entry = view.cur_entry
  local cur_layout = view.cur_layout

  local windows = {}
  for _, sym in ipairs(cur_layout.symbols) do
    local win = cur_layout[sym]
    if win and win.id then
      windows[sym] = { winid = win.id, bufnr = win.file and win.file.bufnr }
    end
  end

  local hunks
  if
    (cur_layout.name == 'diff1_inline' or cur_layout.name == 'diff1_inline_pinned')
    and windows.b
    and windows.b.bufnr
  then
    local ok, inline_diff = pcall(require, 'diffview.scene.inline_diff')
    if ok then
      hunks = inline_diff.get_hunks(windows.b.bufnr)
    end
  end

  return {
    entry = { path = entry.path, oldpath = entry.oldpath, status = entry.status },
    layout = cur_layout.name,
    windows = windows,
    hunks = hunks,
  }
end

return M
