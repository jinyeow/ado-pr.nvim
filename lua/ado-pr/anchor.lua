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
--   path       new-side repo-relative path (diffview FileEntry.path)
--   oldpath    old-side repo-relative path (FileEntry.oldpath; set ONLY on renames)
--   status     git status letter (FileEntry.status: 'A' added, 'D' deleted, …)
--   winid_a    left/old diff window id
--   winid_b    right/new diff window id
--   cur_win    the currently focused window id
--   line_start one-based first line of the anchor (the cursor line for a plain comment)
--   line_end   one-based last line of the anchor (equal to line_start for a plain comment)
-- Returns { filePath = '/rel/path', side = 'right'|'left', line_start, line_end }, or nil, err.
-- The anchor is always range-shaped (ADR-0003); a single-line comment is the degenerate
-- case where line_start == line_end, not a separate code path.
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
  if opts.line_start and opts.line_end and opts.line_start > opts.line_end then
    return nil, 'line_start (' .. opts.line_start .. ') is after line_end (' .. opts.line_end .. ')'
  end

  local filePath = '/' .. raw:gsub('\\', '/'):gsub('^/', '')
  return { filePath = filePath, side = side, line_start = opts.line_start, line_end = opts.line_end }
end

-- Adapter: read the active diffview view (via ado-pr.diffview_state) and
-- resolve the cursor/range. Untested (thin glue over diffview internals); validated
-- by smoke test. Keep logic in `resolve`, above.
-- line_start/line_end: the command's o.line1/o.line2 -- Neovim's `-range` on a user
-- command defaults these to the cursor line when no range was given, so a plain
-- `:AdoPrComment` and a `:'<,'>AdoPrComment` both flow through the same call shape
-- (ADR-0003).
function M.current(line_start, line_end)
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
    line_start = line_start,
    line_end = line_end,
  })
end

return M
