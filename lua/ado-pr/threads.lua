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

-- 'active' and 'pending' are ADO's non-terminal CommentThreadStatus values -- a thread
-- awaiting a response is still open for discussion. Everything else (fixed, wontFix, closed,
-- byDesign) is terminal. The sign only distinguishes "still open" from "not", so this checks
-- against the terminal set rather than special-casing 'active' alone.
local UNRESOLVED_STATUSES = { active = true, pending = true }

function M.is_resolved(thread)
  return not UNRESOLVED_STATUSES[thread.status]
end

-- Normalise a diffview repo-relative path (which can carry backslashes on Windows, e.g.
-- FileEntry.oldpath -- see anchor.lua) to the same forward-slash, no-leading-slash form
-- to_repo_path/path() already produce, so callers can compare the two directly. Idempotent
-- on input already in that form.
function M.norm_repo_path(path)
  return (path or ''):gsub('\\', '/'):gsub('^/', '')
end

local function shallow_copy(items)
  local out = {}
  for i, v in ipairs(items) do
    out[i] = v
  end
  return out
end

-- Threads covering `line`, narrowest first (thread id as a stable tiebreak).
-- `items` is resolved_threads.lua's { thread, range } shape for one file. Overlapping
-- threads are the normal case: the follower pane shows only the
-- first result, so this ordering IS the selection rule, not just a sort.
function M.covering(items, line)
  local hits = {}
  for _, item in ipairs(items) do
    if line >= item.range.line_start and line <= item.range.line_end then
      table.insert(hits, item)
    end
  end
  table.sort(hits, function(a, b)
    local aw = a.range.line_end - a.range.line_start
    local bw = b.range.line_end - b.range.line_start
    if aw ~= bw then
      return aw < bw
    end
    return (a.thread.id or 0) < (b.thread.id or 0)
  end)
  return hits
end

-- Every thread for one file (same { thread, range } shape), in the order
-- `]t` / `[t` should visit them: by start line, then widest (outermost)
-- first when two threads share a start, then id for stability. This is what
-- keeps a jump landing on a containing thread before the ones nested in it.
function M.ordered(items)
  local out = shallow_copy(items)
  table.sort(out, function(a, b)
    if a.range.line_start ~= b.range.line_start then
      return a.range.line_start < b.range.line_start
    end
    local aw = a.range.line_end - a.range.line_start
    local bw = b.range.line_end - b.range.line_start
    if aw ~= bw then
      return aw > bw
    end
    return (a.thread.id or 0) < (b.thread.id or 0)
  end)
  return out
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
