-- Filtering and the read resolver over Azure DevOps PR comment threads. Pure: no
-- Neovim API, no network, no diffview. Same split `anchor.lua` uses for the write path.
--
-- ADR-0002 (docs/adr/0002-read-path-and-original-side-content.md) is the rationale:
-- the side a thread sits on is a property of the QUERY, not the thread -- the same
-- thread reports rightFileStart in a plain fetch and leftFileStart when fetched under
-- an iteration window. `resolve` reads whichever field the response populated, never
-- assumes; it does not branch on `window` itself, because the response already
-- reflects that window's answer.
local M = {}

-- API leading-slash, forward-slash path -> diffview repo-relative path.
function M.to_repo_path(path)
  return (path:gsub('^/', ''))
end

-- diffview repo-relative path (forward or back slashes) -> API leading-slash,
-- forward-slash path. Idempotent on input already in API form.
function M.to_api_path(path)
  return '/' .. path:gsub('\\', '/'):gsub('^/', '')
end

-- A thread whose comments are ALL system-generated (commentType == 'system') is
-- dropped unconditionally (ADR-0002). A thread mixing system and human comments, or
-- a human PR-level thread with no threadContext, is kept -- provenance of the
-- comments, not anchorability, decides this.
function M.is_renderable(thread)
  for _, c in ipairs(thread.comments or {}) do
    if c.commentType ~= 'system' then
      return true
    end
  end
  return false
end

-- The current-side repo-relative path this thread is anchored to, or nil for a
-- PR-level thread (no threadContext).
function M.path(thread)
  if not (thread.threadContext and thread.threadContext.filePath) then
    return nil
  end
  return M.to_repo_path(thread.threadContext.filePath)
end

-- Pure resolver. `window` is the iteration window the threads were fetched under
-- (nil for the plain list, { iteration, base_iteration } for a tracked fetch) --
-- accepted per the design contract but not branched on: the fields on
-- `thread.threadContext` already reflect that window's response.
-- Returns { side = 'left'|'right', line_start, line_end }, or nil, err.
function M.resolve(thread, _window)
  local tc = thread.threadContext
  if not tc then
    return nil, 'PR-level thread has no file anchor'
  end

  local side, start_pos, end_pos
  if tc.rightFileStart then
    side, start_pos, end_pos = 'right', tc.rightFileStart, tc.rightFileEnd
  elseif tc.leftFileStart then
    side, start_pos, end_pos = 'left', tc.leftFileStart, tc.leftFileEnd
  else
    return nil, 'thread has no left or right position for this window'
  end

  local line_start = start_pos.line
  local line_end = (end_pos and end_pos.line) or line_start
  return { side = side, line_start = line_start, line_end = math.max(line_start, line_end) }
end

-- The original position a thread was written at, from `trackingCriteria`
-- (ADR-0002: `origFilePath` is authoritative for the old side of a rename; no
-- client-side reconstruction). nil when the thread was not fetched with tracking.
function M.original(thread)
  local prtc = thread.pullRequestThreadContext
  local tk = prtc and prtc.trackingCriteria
  if not tk then
    return nil
  end
  -- origFilePath is authoritative for the old side (ADR-0002) and, per the spike and
  -- every real trackingCriteria payload, always accompanies a tracked position -- not
  -- defended further per this repo's no-error-handling-for-impossible-scenarios rule.

  local start_pos, end_pos
  if tk.origRightFileStart then
    start_pos, end_pos = tk.origRightFileStart, tk.origRightFileEnd
  elseif tk.origLeftFileStart then
    start_pos, end_pos = tk.origLeftFileStart, tk.origLeftFileEnd
  else
    return nil
  end

  local line_start = start_pos.line
  local line_end = (end_pos and end_pos.line) or line_start
  return {
    path = M.to_repo_path(tk.origFilePath),
    line_start = line_start,
    line_end = math.max(line_start, line_end),
  }
end

-- Clamp a { line_start, line_end } range into [1, line_count], never erroring on a
-- range that has outlived the buffer it was written against. A zero-line buffer has
-- no valid line in [1, 0]; both ends collapse to 0 rather than falsely reporting line 1.
function M.clamp(range, line_count)
  if line_count == 0 then
    return { line_start = 0, line_end = 0 }
  end
  local function clamp_line(l)
    return math.max(1, math.min(l, line_count))
  end
  return { line_start = clamp_line(range.line_start), line_end = clamp_line(range.line_end) }
end

return M
