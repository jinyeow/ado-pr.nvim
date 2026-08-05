-- Tests for ado-pr.resolved_threads: the shared resolved-thread collection both
-- signs.lua and view.lua depend on. Run headless: `nvim --headless -l tests/resolved_threads_spec.lua`.
-- No test framework: a tiny assert harness (plenary is not a dependency), same shape as
-- tests/threads_spec.lua / tests/signs_spec.lua.
--
-- Pure module: no vim.api, vim.system or diffview state, so it is exercised directly
-- with hand-built thread tables (same fixture shape signs_spec.lua's make_thread used
-- before this extraction).
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local resolved_threads = require('ado-pr.resolved_threads')

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

local function make_thread(path, side, line_start, line_end, status)
  local pos = function(l)
    return { line = l }
  end
  local tc
  if path then
    tc = { filePath = '/' .. path }
    if side == 'right' then
      tc.rightFileStart = pos(line_start)
      tc.rightFileEnd = pos(line_end or line_start)
    else
      tc.leftFileStart = pos(line_start)
      tc.leftFileEnd = pos(line_end or line_start)
    end
  end
  return {
    status = status or 'active',
    threadContext = tc,
    comments = { { author = 'A', publishedDate = '2026-01-01', commentType = 'text', content = 'hi' } },
  }
end

local function system_thread()
  return {
    status = 'active',
    threadContext = nil,
    comments = { { author = 'A', publishedDate = '2026-01-01', commentType = 'system', content = 'sys' } },
  }
end

-- Renderable filtering: a system-only thread (threads_mod.is_renderable == false) is
-- excluded from the collection entirely.
do
  resolved_threads.set_threads({ system_thread(), make_thread('f.lua', 'right', 1, 1) })
  eq(#resolved_threads.all(), 1, 'renderable filtering: system-only thread excluded')
  eq(resolved_threads.pr_level_count(), 0, 'renderable filtering: system-only thread not counted as PR-level')
end

-- A thread with no path (no threadContext) routes to pr_level_count() instead of being
-- stored in the collection.
do
  resolved_threads.set_threads({ make_thread(nil), make_thread('f.lua', 'right', 2, 2) })
  eq(resolved_threads.pr_level_count(), 1, 'path-less thread: counted as PR-level')
  eq(#resolved_threads.all(), 1, 'path-less thread: not stored in the collection')
end

-- A thread whose threads_mod.resolve() returns nil (no left/right position for this
-- window) is dropped rather than stored with a nil range.
do
  local no_position_thread = {
    status = 'active',
    threadContext = { filePath = '/f.lua' }, -- has a path, but no rightFileStart/leftFileStart
    comments = { { author = 'A', publishedDate = '2026-01-01', commentType = 'text', content = 'hi' } },
  }
  resolved_threads.set_threads({ no_position_thread })
  eq(resolved_threads.all(), {}, 'unresolvable range: thread dropped, not stored with a nil range')
end

-- items_for(path) returns only entries matching that normalized path.
do
  resolved_threads.set_threads({
    make_thread('a.lua', 'right', 1, 1),
    make_thread('b.lua', 'right', 2, 2),
    make_thread('a.lua', 'left', 3, 3),
  })
  local a_items = resolved_threads.items_for('a.lua')
  eq(#a_items, 2, 'items_for: matches only entries for the requested path')
  for _, item in ipairs(a_items) do
    eq(item.path, 'a.lua', 'items_for: every returned item has the requested path')
  end
  eq(#resolved_threads.items_for('missing.lua'), 0, 'items_for: unknown path returns empty')
end

-- all() returns the full unfiltered collection regardless of path.
do
  resolved_threads.set_threads({
    make_thread('a.lua', 'right', 1, 1),
    make_thread('b.lua', 'right', 2, 2),
  })
  eq(#resolved_threads.all(), 2, 'all: returns every stored item regardless of path')
end

-- set_threads() resets both the collection and the PR-level count on each call.
do
  resolved_threads.set_threads({ make_thread(nil), make_thread('a.lua', 'right', 1, 1) })
  eq(#resolved_threads.all(), 1, 'reset: first call has one item')
  eq(resolved_threads.pr_level_count(), 1, 'reset: first call has PR-level count 1')

  resolved_threads.set_threads({ make_thread('b.lua', 'right', 2, 2) })
  eq(#resolved_threads.all(), 1, 'reset: second call replaces the collection')
  eq(resolved_threads.all()[1].path, 'b.lua', 'reset: second call collection has only the new item')
  eq(resolved_threads.pr_level_count(), 0, 'reset: second call resets PR-level count to 0')

  resolved_threads.set_threads({})
  eq(resolved_threads.all(), {}, 'reset: empty call clears the collection')
  eq(resolved_threads.pr_level_count(), 0, 'reset: empty call keeps PR-level count 0')
end

-- set_threads() always allocates a fresh table for the collection, even given identical
-- input -- signs.lua relies on this identity change to detect "new data landed" (see
-- resolved_threads.lua's doc comment and signs.lua's M.refresh).
do
  local threads = { make_thread('a.lua', 'right', 1, 1) }
  resolved_threads.set_threads(threads)
  local first = resolved_threads.all()
  resolved_threads.set_threads(threads)
  local second = resolved_threads.all()
  ok(first ~= second, 'fresh identity: repeated set_threads() with identical input yields a new table')
  eq(first, second, 'fresh identity: contents are still equal')
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
