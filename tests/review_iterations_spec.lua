-- Tests for iteration browsing (docs/design/pr-comment-threads.md slice 3): enumerating a
-- PR's iterations and switching the diff scope + thread signs to one of them.
--
-- `review.window_for` is pure (table-in/table-out, no vim.api/vim.system) -- tested directly
-- with hand-built iteration lists, same split as signs.lua's M.plan. `select_iteration` /
-- `reset_window` are thin wiring, stubbed at the same module boundaries
-- tests/review_base_spec.lua uses (diffview, signs, resolved_threads, view) so the WIRING
-- (close old diff -> open new range -> capture context -> fetch -> sign -> follow) is
-- assertable without a live PR -- the closest a live-PR smoke test gets in this environment.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local config = require('ado-pr.config')
config.setup({ organization = 'https://dev.azure.com/Org', project = 'My Project' })

package.loaded['diffview'] = {}

local signs_calls
package.loaded['ado-pr.signs'] = {
  attach = function()
    table.insert(signs_calls, { fn = 'attach' })
  end,
  refresh = function()
    table.insert(signs_calls, { fn = 'refresh' })
  end,
}

local set_threads_calls
package.loaded['ado-pr.resolved_threads'] = {
  set_threads = function(list, window)
    table.insert(set_threads_calls, { list = list, window = window })
  end,
  pr_level_count = function()
    return 0
  end,
}

local view_calls
package.loaded['ado-pr.view'] = {
  attach = function()
    table.insert(view_calls, { fn = 'attach' })
  end,
}

local review = require('ado-pr.review')
local state = require('ado-pr.state')

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

-- ---------------------------------------------------------------------------
-- review.window_for -- pure N -> { window, base_commit, head_commit } mapping
-- ---------------------------------------------------------------------------

local iterations = {
  { id = 1, sourceRefCommit = { commitId = 'c1' }, targetRefCommit = { commitId = 'base0' } },
  { id = 2, sourceRefCommit = { commitId = 'c2' }, targetRefCommit = { commitId = 'base0' } },
  { id = 3, sourceRefCommit = { commitId = 'c3' }, targetRefCommit = { commitId = 'base0' } },
}

-- "One push at a time" (the issue's own framing): iteration N diffs against N-1's own
-- source commit, not the whole PR base.
do
  local resolved, err = review.window_for(iterations, 3)
  ok(resolved and not err, 'window_for: no error for a mid-range iteration', err)
  eq(resolved.window, { iteration = 3, base_iteration = 2 }, 'window_for: base_iteration is iteration - 1')
  eq(resolved.head_commit, 'c3', 'window_for: head_commit is the selected iterations sourceRefCommit')
  eq(resolved.base_commit, 'c2', 'window_for: base_commit is the previous iterations sourceRefCommit')
end

-- The first iteration has no iteration before it -- ADO's iteration ids are zero-based,
-- with iteration 0 being the merge-base commit between source and target, so iteration 1's
-- base is 0, not itself. Falls back to its own targetRefCommit (the target branch tip it
-- was compared against) for that base commit.
do
  local resolved, err = review.window_for(iterations, 1)
  ok(resolved and not err, 'window_for: no error for iteration 1', err)
  eq(resolved.window, { iteration = 1, base_iteration = 0 }, 'window_for: iteration 1 bases against iteration 0')
  eq(resolved.head_commit, 'c1', 'window_for: iteration 1 head_commit')
  eq(resolved.base_commit, 'base0', 'window_for: iteration 1 base_commit falls back to targetRefCommit')
end

-- An unknown iteration id errors rather than silently picking one.
do
  local resolved, err = review.window_for(iterations, 99)
  ok(resolved == nil and err ~= nil, 'window_for: unknown id errors', tostring(err))
end

-- A malformed iteration missing sourceRefCommit errors rather than diffing against nil.
do
  local broken = { { id = 1, targetRefCommit = { commitId = 'base0' } } }
  local resolved, err = review.window_for(broken, 1)
  ok(resolved == nil and err ~= nil, 'window_for: missing sourceRefCommit errors', tostring(err))
end

-- ---------------------------------------------------------------------------
-- review.select_iteration / review.reset_window -- wiring
-- ---------------------------------------------------------------------------

local calls
local checkout_result, show_result, fetch_result, revparse_result, threads_result
local cat_file_result, git_fetch_sha_result

local real_system = vim.system
local function stub_system()
  vim.system = function(cmd, opts)
    table.insert(calls, { kind = 'system', cmd = cmd, opts = opts })
    if cmd[1] == 'git' then
      if cmd[2] == 'fetch' and cmd[3] == 'origin' and cmd[4] == (fetch_result and fetch_result.target_ref) then
        return {
          wait = function()
            return fetch_result
          end,
        }
      elseif cmd[2] == 'rev-parse' then
        return {
          wait = function()
            return revparse_result
          end,
        }
      elseif cmd[2] == 'cat-file' then
        return {
          wait = function()
            return cat_file_result
          end,
        }
      elseif cmd[2] == 'fetch' then -- ensure_commit's `git fetch origin <sha>`
        return {
          wait = function()
            return git_fetch_sha_result
          end,
        }
      end
      error('unexpected git subcommand: ' .. vim.inspect(cmd))
    end
    if vim.tbl_contains(cmd, 'checkout') then
      return {
        wait = function()
          return checkout_result
        end,
      }
    elseif vim.tbl_contains(cmd, 'show') then
      return {
        wait = function()
          return show_result
        end,
      }
    elseif vim.tbl_contains(cmd, 'pullRequestThreads') then
      return {
        wait = function()
          return threads_result
        end,
      }
    end
    error('unexpected vim.system call: ' .. vim.inspect(cmd))
  end
end

local real_cmd = vim.cmd
local function stub_cmd()
  vim.cmd = function(c)
    table.insert(calls, { kind = 'cmd', cmd = c })
  end
end

local notifications
local real_notify = vim.notify
local function stub_notify()
  notifications = {}
  vim.notify = function(msg, level)
    table.insert(notifications, { msg = msg, level = level })
  end
end

local function reset(opts)
  calls = {}
  signs_calls = {}
  view_calls = {}
  set_threads_calls = {}
  stub_system()
  stub_cmd()
  stub_notify()
  checkout_result = { code = 0, stdout = '', stderr = '' }
  show_result = {
    code = 0,
    stdout = vim.json.encode({
      repository = { id = 'repo-guid', project = { name = 'My Project' } },
      targetRefName = 'refs/heads/main',
    }),
    stderr = '',
  }
  fetch_result = { code = 0, stdout = '', stderr = '', target_ref = 'refs/heads/main' }
  revparse_result = { code = 0, stdout = 'deadbeef\n', stderr = '' }
  threads_result = { code = 0, stdout = vim.json.encode({ count = 0, value = {} }), stderr = '' }
  cat_file_result = (opts and opts.cat_file_result) or { code = 0, stdout = '', stderr = '' }
  git_fetch_sha_result = (opts and opts.git_fetch_sha_result) or { code = 0, stdout = '', stderr = '' }
end

local function cmd_calls()
  local out = {}
  for _, c in ipairs(calls) do
    if c.kind == 'cmd' then
      table.insert(out, c)
    end
  end
  return out
end

local function has_level(level)
  for _, n in ipairs(notifications) do
    if n.level == level then
      return true
    end
  end
  return false
end

-- Bring a PR under review first, the same way review_base_spec.lua's happy path does --
-- select_iteration/reset_window depend on state.get() already having repo_root/pr_base.
local function open_pr()
  review.open(21121)
end

-- Selecting an iteration: closes the existing diff, opens the new commit range, captures
-- the window into state, fetches with list_threads_tracked (not list_threads), and
-- re-wires signs + the follower pane.
do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls = {}, {}, {}, {}

  review.select_iteration(iterations, 3)

  local diff_close_idx, diff_open_idx
  for i, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewClose' then
      diff_close_idx = i
    elseif c.cmd == 'DiffviewOpen c2...c3' then
      diff_open_idx = i
    end
  end
  ok(diff_close_idx ~= nil, 'select_iteration: closes the existing diff first')
  ok(diff_open_idx ~= nil, 'select_iteration: opens the new iterations commit range', vim.inspect(cmd_calls()))
  ok(diff_close_idx and diff_open_idx and diff_close_idx < diff_open_idx, 'select_iteration: close precedes open')

  local tracked_call
  for _, c in ipairs(calls) do
    if c.kind == 'system' and vim.tbl_contains(c.cmd, 'pullRequestThreads') then
      tracked_call = c
    end
  end
  ok(tracked_call ~= nil, 'select_iteration: fetched threads')
  if tracked_call then
    local qp_idx
    for i, a in ipairs(tracked_call.cmd) do
      if a == '--query-parameters' then
        qp_idx = i
      end
    end
    ok(qp_idx ~= nil, 'select_iteration: tracked fetch passes --query-parameters (list_threads_tracked, not list_threads)')
    if qp_idx then
      ok(tracked_call.cmd[qp_idx + 1] == '$iteration=3', 'select_iteration: $iteration query param', tracked_call.cmd[qp_idx + 1])
      ok(tracked_call.cmd[qp_idx + 2] == '$baseIteration=2', 'select_iteration: $baseIteration query param', tracked_call.cmd[qp_idx + 2])
    end
  end

  ok(
    set_threads_calls[1] and vim.deep_equal(set_threads_calls[1].window, { iteration = 3, base_iteration = 2 }),
    'select_iteration: resolved_threads.set_threads receives the window'
  )

  local sign_fns = {}
  for _, c in ipairs(signs_calls) do
    table.insert(sign_fns, c.fn)
  end
  eq(sign_fns, { 'attach', 'refresh' }, 'select_iteration: signs re-attached and refreshed')

  local view_fns = {}
  for _, c in ipairs(view_calls) do
    table.insert(view_fns, c.fn)
  end
  eq(view_fns, { 'attach' }, 'select_iteration: follower pane re-attached to the new window')

  ok(state.get().window and state.get().window.iteration == 3, 'select_iteration: state.window set to the selected iteration')
  eq(state.get().base, 'c2', 'select_iteration: state.base is the windows base commit')
  eq(state.get().head, 'c3', 'select_iteration: state.head is the windows head commit')
end

-- Both commits are checked locally before diffview opens against them -- an older
-- iteration's commit is not guaranteed reachable from the checked-out branch tip
-- (e.g. after a force-push).
do
  reset({ cat_file_result = { code = 1, stdout = '', stderr = 'not found' }, git_fetch_sha_result = { code = 1, stdout = '', stderr = 'no route to host' } })
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls = {}, {}, {}, {}

  review.select_iteration(iterations, 3)

  ok(#cmd_calls() == 0, 'select_iteration: missing commit aborts before DiffviewClose/Open', vim.inspect(cmd_calls()))
  ok(has_level(vim.log.levels.ERROR), 'select_iteration: missing commit notifies ERROR')
  ok(#set_threads_calls == 0, 'select_iteration: missing commit never fetches/wires threads')
end

-- A missing commit that DOES fetch successfully via `git fetch origin <sha>` proceeds.
do
  reset({ cat_file_result = { code = 1, stdout = '', stderr = 'not found' }, git_fetch_sha_result = { code = 0, stdout = '', stderr = '' } })
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls = {}, {}, {}, {}

  review.select_iteration(iterations, 3)

  ok(#cmd_calls() > 0, 'select_iteration: commit fetched on demand, diff still opens')
  ok(not has_level(vim.log.levels.ERROR), 'select_iteration: no ERROR once the commit is fetched')
end

-- An unknown iteration id is rejected before touching diffview at all.
do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls = {}, {}, {}, {}

  review.select_iteration(iterations, 99)

  ok(#cmd_calls() == 0, 'select_iteration: unknown id never opens a diff')
  ok(has_level(vim.log.levels.ERROR), 'select_iteration: unknown id notifies ERROR')
end

-- select_iteration/reset_window guard against diffview not being available, the same way
-- browse_iterations already does -- both call DiffviewOpen/DiffviewClose too.
do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls = {}, {}, {}, {}
  package.loaded['diffview'] = nil

  review.select_iteration(iterations, 3)

  ok(#cmd_calls() == 0, 'select_iteration: no diffview never opens a diff')
  ok(has_level(vim.log.levels.ERROR), 'select_iteration: no diffview notifies ERROR')
  ok(#set_threads_calls == 0, 'select_iteration: no diffview never fetches/wires threads')

  package.loaded['diffview'] = {}
end

do
  reset()
  open_pr()
  review.select_iteration(iterations, 3)
  calls, signs_calls, view_calls, set_threads_calls = {}, {}, {}, {}
  package.loaded['diffview'] = nil

  review.reset_window()

  ok(#cmd_calls() == 0, 'reset_window: no diffview never opens a diff')
  ok(has_level(vim.log.levels.ERROR), 'reset_window: no diffview notifies ERROR')
  ok(#set_threads_calls == 0, 'reset_window: no diffview never fetches/wires threads')
  ok(state.get().window ~= nil, 'reset_window: no diffview leaves state.window untouched')

  package.loaded['diffview'] = {}
end

-- reset_window restores the full-PR view: diffs pr_base...HEAD, fetches with
-- list_threads (untracked, no window), and clears state.window.
do
  reset()
  open_pr()
  review.select_iteration(iterations, 3)
  calls, signs_calls, view_calls, set_threads_calls = {}, {}, {}, {}

  review.reset_window()

  local diff_open_idx
  for _, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewOpen deadbeef...HEAD' then
      diff_open_idx = true
    end
  end
  ok(diff_open_idx, 'reset_window: reopens the diff against the original PR base and HEAD', vim.inspect(cmd_calls()))

  local plain_fetch
  for _, c in ipairs(calls) do
    if c.kind == 'system' and vim.tbl_contains(c.cmd, 'pullRequestThreads') then
      plain_fetch = c
    end
  end
  ok(plain_fetch ~= nil, 'reset_window: threads re-fetched')
  if plain_fetch then
    ok(not vim.tbl_contains(plain_fetch.cmd, '--query-parameters'), 'reset_window: plain fetch (list_threads), not tracked')
  end

  ok(set_threads_calls[1] and set_threads_calls[1].window == nil, 'reset_window: resolved_threads.set_threads receives a nil window')
  ok(state.get().window == nil, 'reset_window: state.window cleared')
  eq(state.get().base, 'deadbeef', 'reset_window: state.base restored to the PRs original base')
  ok(state.get().head == nil, 'reset_window: state.head cleared (defaults back to HEAD)')
end

-- reset_window on the already-full view is a no-op (nothing to restore).
do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls = {}, {}, {}, {}

  review.reset_window()

  ok(#cmd_calls() == 0, 'reset_window: no-op when already on the full view')
  ok(#set_threads_calls == 0, 'reset_window: no-op does not re-fetch')
end

-- Commenting while browsing an iteration window is refused -- the right-side lines in a
-- historical buffer don't line up with the PR's tip, so posting from there would land on
-- the wrong line of a live PR.
do
  reset()
  open_pr()
  review.select_iteration(iterations, 3)
  notifications = {}

  review.comment('should not post')

  ok(has_level(vim.log.levels.ERROR), 'comment: refused while an iteration window is active')
end

vim.system = real_system
vim.cmd = real_cmd
vim.notify = real_notify

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do
    io.stderr:write('  - ' .. f .. '\n')
  end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
