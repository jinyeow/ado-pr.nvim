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
--   oldpath  old-side repo-relative path (FileEntry.oldpath; set ONLY on renames)
--   status   git status letter (FileEntry.status: 'A' added, 'D' deleted, …)
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

  -- Which sides exist is a STATUS question, not an oldpath one: diffview only
  -- sets oldpath on renames, so a plain modified file's left side is `path`.
  local raw
  if side == 'left' then
    if opts.status == 'A' then
      return nil, 'no left (old) side on an added file'
    end
    raw = opts.oldpath or opts.path
  else
    if opts.status == 'D' then
      return nil, 'no right (new) side on a deleted file'
    end
    raw = opts.path
  end
  if not raw or raw == '' or raw == 'null' then
    return nil, 'no file on the ' .. side .. ' side to anchor to'
  end

  local filePath = '/' .. raw:gsub('\\', '/'):gsub('^/', '')
  return { filePath = filePath, line = opts.cur_line, side = side }
end

-- Adapter: read the active diffview view (via ado-pr.diffview_state) and
-- resolve the cursor. Untested (thin glue over diffview internals); validated
-- by smoke test. Keep logic in `resolve`, above.
function M.current()
  local diffview_state = require('ado-pr.diffview_state')
  local state, err = diffview_state.current()
  if not state then
    return nil, err
  end
  local windows = state.windows
  return M.resolve({
    path = state.entry.path,
    oldpath = state.entry.oldpath,
    status = state.entry.status,
    winid_a = windows.a and windows.a.winid,
    winid_b = windows.b and windows.b.winid,
    cur_win = vim.api.nvim_get_current_win(),
    cur_line = vim.api.nvim_win_get_cursor(0)[1],
  })
end

return M
