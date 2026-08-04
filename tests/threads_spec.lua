-- Pure-logic tests for ado-pr.threads — filtering and the read resolver over
-- Azure DevOps PR comment threads. Run headless: `nvim --headless -l tests/threads_spec.lua`.
-- No test framework: a tiny assert harness (plenary is not a dependency), mirroring
-- tests/anchor_spec.lua.
--
-- Note: prototypes/spike_*.json (real captured API responses) are gitignored and were
-- never committed to this worktree, so they could not be read while writing this spec.
-- Fixtures here are built from prototypes/fixtures_threads.lua plus the field-level facts
-- recorded in docs/adr/0002-read-path-and-original-side-content.md (lines 21-36) and the
-- envelope shape proven at prototypes/spike_read_path.lua:209 (`json.count` / `json.value`).
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local threads = require('ado-pr.threads')

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

local function comment(commentType, content)
  return { author = 'Someone', publishedDate = '2026-07-01', commentType = commentType, content = content }
end

-- ---------------------------------------------------------------------------
-- is_renderable
-- ---------------------------------------------------------------------------

-- A thread whose comments are all system-generated is dropped.
do
  local t = {
    threadContext = nil,
    comments = { comment('system', 'The reference refs/heads/x was updated.') },
  }
  ok(threads.is_renderable(t) == false, 'system-only thread: dropped')
end

-- A thread mixing system and human comments is kept.
do
  local t = {
    threadContext = { filePath = '/lua/ado-pr/az.lua', rightFileStart = { line = 19, offset = 1 } },
    comments = {
      comment('system', 'Justin Puah set auto-complete'),
      comment('text', 'Is this comment still accurate?'),
    },
  }
  ok(threads.is_renderable(t) == true, 'mixed system+human thread: kept')
end

-- A human PR-level thread (no threadContext) is still renderable -- resolve() is what
-- reports it has no anchor, is_renderable is only about comment provenance.
do
  local t = {
    threadContext = nil,
    comments = { comment('text', 'Overall looks good, one nit inline.') },
  }
  ok(threads.is_renderable(t) == true, 'human PR-level thread: kept')
end

-- ---------------------------------------------------------------------------
-- resolve
-- ---------------------------------------------------------------------------

-- Plain fetch: rightFileStart populated -> right side, single-line range degenerates
-- to start == end.
do
  local t = {
    threadContext = { filePath = '/lua/ado-pr/az.lua', rightFileStart = { line = 19, offset = 1 }, rightFileEnd = { line = 19, offset = 60 } },
  }
  local r, err = threads.resolve(t, nil)
  ok(r and not err, 'plain right: no error', err)
  eq(r, { side = 'right', line_start = 19, line_end = 19 }, 'plain right: single-line range')
end

-- Multi-line span: start and end differ.
do
  local t = {
    threadContext = { filePath = '/lua/ado-pr/az.lua', rightFileStart = { line = 62, offset = 1 }, rightFileEnd = { line = 84, offset = 20 } },
  }
  local r = threads.resolve(t, nil)
  eq(r, { side = 'right', line_start = 62, line_end = 84 }, 'plain right: multi-line range')
end

-- Tracked fetch, same thread: the response populates leftFileStart instead of
-- rightFileStart for this window -- side flips. This is the load-bearing case slices 3
-- and 4 depend on (ADR-0002 lines 25-28); no existing fixture carries it, built by hand.
do
  local t = {
    threadContext = { filePath = '/lua/ado-pr/az.lua', leftFileStart = { line = 19, offset = 1 }, leftFileEnd = { line = 19, offset = 60 } },
    pullRequestThreadContext = {
      trackingCriteria = { firstComparingIteration = 1, secondComparingIteration = 2, origFilePath = '/lua/ado-pr/az.lua' },
    },
  }
  local r, err = threads.resolve(t, { iteration = 2, base_iteration = 1 })
  ok(r and not err, 'tracked left: no error', err)
  eq(r, { side = 'left', line_start = 19, line_end = 19 }, 'tracked left: side flips to left')
end

-- A thread with no file context is PR-level, not mis-anchored: a clear nil + error,
-- not a guessed position.
do
  local t = { threadContext = nil }
  local r, err = threads.resolve(t, nil)
  ok(r == nil, 'PR-level: nil range')
  eq(err, 'PR-level thread has no file anchor', 'PR-level: specific error')
end

-- Added file: only the right side exists. Asking for it succeeds; there is no left
-- side to report because the API never populated one.
do
  local t = {
    threadContext = { filePath = '/lua/ado-pr/added.lua', rightFileStart = { line = 5, offset = 1 } },
  }
  local r, err = threads.resolve(t, nil)
  ok(r and not err, 'added file: right side resolves', err)
  eq(r, { side = 'right', line_start = 5, line_end = 5 }, 'added file: right side range')
end

-- Deleted file: only the left side exists.
do
  local t = {
    threadContext = { filePath = '/lua/ado-pr/deleted.lua', leftFileStart = { line = 8, offset = 1 } },
  }
  local r, err = threads.resolve(t, nil)
  ok(r and not err, 'deleted file: left side resolves', err)
  eq(r, { side = 'left', line_start = 8, line_end = 8 }, 'deleted file: left side range')
end

-- threadContext present but neither side populated: not a guessed position.
do
  local t = { threadContext = { filePath = '/lua/ado-pr/az.lua' } }
  local r, err = threads.resolve(t, nil)
  ok(r == nil, 'no side populated: nil range')
  eq(err, 'thread has no left or right position for this window', 'no side populated: specific error')
end

-- ---------------------------------------------------------------------------
-- clamp
-- ---------------------------------------------------------------------------

-- A range fully inside the buffer passes through unchanged.
do
  local c = threads.clamp({ line_start = 5, line_end = 10 }, 200)
  eq(c, { line_start = 5, line_end = 10 }, 'clamp: inside buffer unchanged')
end

-- A line past end-of-buffer clamps to the last line, never errors.
do
  local c = threads.clamp({ line_start = 500, line_end = 520 }, 50)
  eq(c, { line_start = 50, line_end = 50 }, 'clamp: past end-of-buffer clamps')
end

-- A range starting inside but ending past the buffer clamps only the end.
do
  local c = threads.clamp({ line_start = 45, line_end = 520 }, 50)
  eq(c, { line_start = 45, line_end = 50 }, 'clamp: partial overrun clamps end only')
end

-- A zero-line buffer has no valid line at all: [1, 0] is empty, so clamping into it
-- must not return line 1 (outside that range). Both ends collapse to 0.
do
  local c = threads.clamp({ line_start = 5, line_end = 10 }, 0)
  eq(c, { line_start = 0, line_end = 0 }, 'clamp: zero-line buffer clamps to 0')
end

-- ---------------------------------------------------------------------------
-- path normalisation
-- ---------------------------------------------------------------------------

-- API leading-slash form -> diffview repo-relative form.
do
  local p = threads.to_repo_path('/lua/ado-pr/az.lua')
  ok(p == 'lua/ado-pr/az.lua', 'to_repo_path: strips leading slash', tostring(p))
end

-- diffview repo-relative form -> API leading-slash forward-slash form, including
-- Windows-style backslashes.
do
  local p = threads.to_api_path('lua\\ado-pr\\az.lua')
  ok(p == '/lua/ado-pr/az.lua', 'to_api_path: adds leading slash, forward slashes', tostring(p))
end

-- Already-API-shaped input to to_api_path is idempotent.
do
  local p = threads.to_api_path('/lua/ado-pr/az.lua')
  ok(p == '/lua/ado-pr/az.lua', 'to_api_path: idempotent on API form', tostring(p))
end

-- path(thread) reads the current (threadContext) path, normalised to repo-relative form.
do
  local t = { threadContext = { filePath = '/lua/ado-pr/az.lua', rightFileStart = { line = 1 } } }
  ok(threads.path(t) == 'lua/ado-pr/az.lua', 'path: repo-relative form', tostring(threads.path(t)))
end

-- path(thread) is nil for a PR-level thread.
do
  local t = { threadContext = nil }
  ok(threads.path(t) == nil, 'path: nil for PR-level thread')
end

-- ---------------------------------------------------------------------------
-- original
-- ---------------------------------------------------------------------------

-- No trackingCriteria: no original position to report.
do
  local t = { threadContext = { filePath = '/lua/ado-pr/az.lua', rightFileStart = { line = 62 } } }
  local o = threads.original(t)
  ok(o == nil, 'original: nil without trackingCriteria')
end

-- Tracked thread: original position comes from trackingCriteria, right side.
do
  local t = {
    threadContext = { filePath = '/lua/ado-pr/az.lua', rightFileStart = { line = 19 } },
    pullRequestThreadContext = {
      trackingCriteria = {
        origFilePath = '/lua/ado-pr/az.lua',
        origRightFileStart = { line = 19, offset = 1 },
        origRightFileEnd = { line = 19, offset = 60 },
      },
    },
  }
  local o = threads.original(t)
  eq(o, { path = 'lua/ado-pr/az.lua', line_start = 19, line_end = 19 }, 'original: right side from trackingCriteria')
end

-- Tracked thread, left side.
do
  local t = {
    pullRequestThreadContext = {
      trackingCriteria = {
        origFilePath = '/lua/ado-pr/az.lua',
        origLeftFileStart = { line = 8, offset = 1 },
        origLeftFileEnd = { line = 12, offset = 1 },
      },
    },
  }
  local o = threads.original(t)
  eq(o, { path = 'lua/ado-pr/az.lua', line_start = 8, line_end = 12 }, 'original: left side from trackingCriteria')
end

-- Rename: original().path is the API's original path, authoritative for the old side --
-- and differs from the current side's path, which resolve()/path() report from
-- threadContext.filePath (the new-side path).
do
  local t = {
    threadContext = { filePath = '/lua/ado-pr/new_name.lua', rightFileStart = { line = 3 } },
    pullRequestThreadContext = {
      trackingCriteria = {
        origFilePath = '/lua/ado-pr/old_name.lua',
        origRightFileStart = { line = 3, offset = 1 },
      },
    },
  }
  ok(threads.path(t) == 'lua/ado-pr/new_name.lua', 'rename: current side path')
  local o = threads.original(t)
  eq(o, { path = 'lua/ado-pr/old_name.lua', line_start = 3, line_end = 3 }, 'rename: original side uses origFilePath')
end

-- ---------------------------------------------------------------------------
-- is_resolved
-- ---------------------------------------------------------------------------

-- 'active' and 'pending' are the unresolved statuses (a thread awaiting a response is
-- still open for discussion); every terminal ADO status (fixed, wontFix, closed, byDesign)
-- reads as resolved -- the sign only distinguishes "still open" from "not".
do
  ok(threads.is_resolved({ status = 'active' }) == false, 'is_resolved: active is not resolved')
  ok(threads.is_resolved({ status = 'pending' }) == false, 'is_resolved: pending is not resolved')
  ok(threads.is_resolved({ status = 'fixed' }) == true, 'is_resolved: fixed is resolved')
  ok(threads.is_resolved({ status = 'closed' }) == true, 'is_resolved: closed is resolved')
  ok(threads.is_resolved({ status = 'wontFix' }) == true, 'is_resolved: wontFix is resolved')
  ok(threads.is_resolved({ status = 'byDesign' }) == true, 'is_resolved: byDesign is resolved')
end

-- ---------------------------------------------------------------------------
-- norm_repo_path
-- ---------------------------------------------------------------------------

-- Normalises a diffview repo-relative path (which can carry backslashes on Windows) to the
-- same forward-slash, no-leading-slash form to_repo_path/path() already produce, so callers
-- can compare the two directly. Idempotent on input already in that form.
do
  ok(threads.norm_repo_path('lua\\ado-pr\\az.lua') == 'lua/ado-pr/az.lua', 'norm_repo_path: backslashes to forward')
  ok(threads.norm_repo_path('/lua/ado-pr/az.lua') == 'lua/ado-pr/az.lua', 'norm_repo_path: strips leading slash')
  ok(threads.norm_repo_path('lua/ado-pr/az.lua') == 'lua/ado-pr/az.lua', 'norm_repo_path: idempotent')
  ok(threads.norm_repo_path(nil) == '', 'norm_repo_path: nil is empty string')
end

-- ---------------------------------------------------------------------------
-- Fixture-shaped set: mirrors prototypes/fixtures_threads.lua's ratios --
-- 5 human threads clustered in ONE file, an overlapping span (62-84 contains 77 and
-- 82-83), 3 of 5 carrying trackingCriteria, and ~16 system-only threads dominating
-- the payload. Exercised as a SET, per the ticket's fixture-shape acceptance criterion.
-- ---------------------------------------------------------------------------

local FILE = '/lua/ado-pr/az.lua'

local function human(id, right_start, right_end, tracking)
  local t = {
    id = id,
    threadContext = { filePath = FILE, rightFileStart = { line = right_start, offset = 1 }, rightFileEnd = { line = right_end or right_start, offset = 1 } },
    comments = { comment('text', 'a human comment') },
  }
  if tracking then
    t.pullRequestThreadContext = {
      trackingCriteria = {
        origFilePath = FILE,
        origRightFileStart = { line = right_start, offset = 1 },
        origRightFileEnd = { line = right_end or right_start, offset = 1 },
      },
    }
  end
  return t
end

local human_threads = {
  human(96940, 19, 19, true),
  human(97122, 62, 84, false), -- the wide one, contains 96937 and 96938
  human(96937, 77, 77, true),
  human(96938, 82, 83, true),
  human(97128, 109, 109, false),
}

local fixture_threads = vim.deepcopy(human_threads)
local next_id = 96900
for _ = 1, 16 do
  next_id = next_id + 1
  table.insert(fixture_threads, {
    id = next_id,
    threadContext = nil,
    comments = { comment('system', 'The reference refs/heads/x was updated.') },
  })
end

-- System noise dominates (16 of 21) and is dropped; the 5 human threads are kept.
do
  local kept = {}
  for _, t in ipairs(fixture_threads) do
    if threads.is_renderable(t) then
      table.insert(kept, t)
    end
  end
  ok(#fixture_threads == 21, 'fixture set: 21 threads total', tostring(#fixture_threads))
  ok(#kept == 5, 'fixture set: 5 human threads kept', tostring(#kept))
end

-- All 5 human threads resolve to a range; the multi-line ones stay spans, not
-- collapsed to a single line.
do
  local ranges = {}
  for _, t in ipairs(human_threads) do
    local r, err = threads.resolve(t, nil)
    ok(r and not err, ('fixture set: thread %d resolves'):format(t.id), err)
    ranges[t.id] = r
  end
  eq(ranges[96940], { side = 'right', line_start = 19, line_end = 19 }, 'fixture set: 96940 single-line')
  eq(ranges[97122], { side = 'right', line_start = 62, line_end = 84 }, 'fixture set: 97122 spans 62-84 (the wide one)')
  eq(ranges[96937], { side = 'right', line_start = 77, line_end = 77 }, 'fixture set: 96937 sits inside the wide one')
  eq(ranges[96938], { side = 'right', line_start = 82, line_end = 83 }, 'fixture set: 96938 spans 82-83, inside the wide one')
  eq(ranges[97128], { side = 'right', line_start = 109, line_end = 109 }, 'fixture set: 97128 single-line')
end

-- All 5 human threads cluster in the same file (real reviews cluster, not spread).
do
  for _, t in ipairs(human_threads) do
    ok(threads.path(t) == 'lua/ado-pr/az.lua', ('fixture set: thread %d clusters in the same file'):format(t.id))
  end
end

-- Only 3 of the 5 human threads carry trackingCriteria -- tracking is opt-in, not
-- universal, even within one fetch.
do
  local tracked = 0
  for _, t in ipairs(human_threads) do
    if threads.original(t) then
      tracked = tracked + 1
    end
  end
  ok(tracked == 3, 'fixture set: 3 of 5 threads carry tracking', tostring(tracked))
end

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do io.stderr:write('  - ' .. f .. '\n') end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
