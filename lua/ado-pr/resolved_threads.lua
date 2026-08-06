-- The resolved-thread collection shared by signs.lua and view.lua: the per-PR list of
-- { thread, path, range } entries produced by filtering a fetched thread list down to
-- the renderable ones and resolving each to a placement range. Both modules depend on
-- this as a peer instead of one reaching into the other's internals -- signs.lua for
-- M.plan's placement pass (via M.all()), view.lua's follower pane for per-file lookups
-- (via M.items_for). Named after the ticket's own phrase ("the resolved-thread
-- collection"), paralleling threads.lua (pure per-thread helpers: is_renderable,
-- resolve, norm_repo_path) as the resolved/aggregated view built from those helpers --
-- the same naming relationship diffview_state.lua has to raw diffview state.
local M = {}

local threads_mod = require('ado-pr.threads')

-- { { thread = <thread>, path = <repo-relative, forward-slash>, range = { side, line_start, line_end } } }
local resolved = {}
local pr_level = 0

-- Store the renderable threads for the active PR. `window` is the iteration window this
-- `threads` list was fetched under (nil for a plain fetch, `{ iteration, base_iteration }`
-- for a tracked fetch via az.list_threads_tracked) -- forwarded to threads_mod.resolve per
-- the design contract, though resolve() itself doesn't branch on it (the response already
-- reflects that window's side/position). Both left- and right-anchored threads are kept;
-- PR-level (no threadContext) human threads are counted, not stored. Every call replaces
-- the collection with a fresh table rather than mutating the old one in place -- signs.lua
-- relies on that fresh identity (M.all() returning a different table than a previous call
-- did) to notice a new review session's (or a new iteration window's) data has landed,
-- without this module needing to know anything about signs.lua's own trackers.
function M.set_threads(threads, window)
  resolved, pr_level = {}, 0
  for _, t in ipairs(threads or {}) do
    if threads_mod.is_renderable(t) then
      local path = threads_mod.path(t)
      if not path then
        pr_level = pr_level + 1
      else
        local range = threads_mod.resolve(t, window)
        if range then
          table.insert(resolved, { thread = t, path = threads_mod.norm_repo_path(path), range = range })
        end
      end
    end
  end
end

-- Human PR-level threads (no threadContext) -- surfaced as a count on open, not an
-- invented inline home.
function M.pr_level_count()
  return pr_level
end

-- Resolved items (thread + resolved range) for one repo-relative path, normalised.
-- The follower pane (view.lua) uses this to find the threads covering the cursor
-- and to walk between them with ]t / [t.
function M.items_for(path)
  local out = {}
  for _, item in ipairs(resolved) do
    if item.path == path then
      table.insert(out, item)
    end
  end
  return out
end

-- The full, unfiltered collection -- signs.lua's M.plan needs every item regardless of
-- path (it does its own per-entry_path filtering internally), unlike items_for's
-- single-path lookup. Returned by reference: treat it as read-only -- an in-place
-- mutation would corrupt shared state without signs.lua's identity-based cache-reset
-- noticing, since that only detects table replacement, not mutation.
function M.all()
  return resolved
end

return M
