-- Map a diffview diff cursor to an Azure DevOps thread anchor.
--
-- ADO line comments carry a `threadContext` of `filePath` + a one-based
-- `line`/`offset` on either the right (new) or left (old) side. Which side is
-- decided by *which diff window the cursor is in* — the user physically picks
-- the pane, so this is a cleaner signal than inferring side from the line type.
--
-- The cobalt gotcha applies: the file-tree cursor's file is NOT the displayed
-- file. `resolve` is fed the FileEntry's own paths (the displayed diff), never a
-- panel selection; `current()` reads those from diffview's `cur_entry`.
local M = {}

-- Pure resolver. opts:
--   path     new-side repo-relative path (diffview FileEntry.path)
--   oldpath  old-side repo-relative path (FileEntry.oldpath; may be nil)
--   winid_a  left/old diff window id
--   winid_b  right/new diff window id
--   cur_win  the currently focused window id
--   cur_line one-based cursor line
-- Returns { filePath = '/rel/path', line, side = 'right'|'left' }, or nil, err.
function M.resolve(opts)
  local side
  if opts.cur_win == opts.winid_b then
    side = 'right'
  elseif opts.cur_win == opts.winid_a then
    side = 'left'
  else
    return nil, 'cursor is not in a diff window (comment from the diff, not the file panel)'
  end

  local raw = opts.path
  if side == 'left' then
    raw = opts.oldpath
  end
  if not raw or raw == '' or raw == 'null' then
    return nil, 'no file on the ' .. side .. ' side to anchor to'
  end

  local filePath = '/' .. raw:gsub('\\', '/'):gsub('^/', '')
  return { filePath = filePath, line = opts.cur_line, side = side }
end

-- Adapter: read the active diffview view and resolve the cursor. Untested (thin
-- glue over diffview internals — `cur_entry`/`layout.a|b.id`); validated by smoke
-- test. Keep logic in `resolve`, above.
function M.current()
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    return nil, 'diffview.nvim is not available'
  end
  local view = lib.get_current_view()
  if not view or not view.cur_entry then
    return nil, 'no active diffview file under the cursor'
  end
  local entry = view.cur_entry
  local layout = entry.layout
  return M.resolve({
    path = entry.path,
    oldpath = entry.oldpath,
    winid_a = layout.a and layout.a.id,
    winid_b = layout.b and layout.b.id,
    cur_win = vim.api.nvim_get_current_win(),
    cur_line = vim.api.nvim_win_get_cursor(0)[1],
  })
end

return M
