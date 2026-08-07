-- Tests for the session-only diff-base override (docs/specs/diff-base-override.md):
-- :AdoPrSetDiffBase / :AdoPrShowDiffBase / :AdoPrResetDiffBase, and the unconditional
-- Full-PR-view reopen path they and the existing iteration-window-reset call site share.
-- Same stubbing style as tests/review_base_spec.lua and tests/review_iterations_spec.lua
-- (stub vim.system/vim.cmd/vim.notify at review.lua's module boundary).
-- Run headless: `nvim --headless -l tests/review_diff_base_spec.lua`.
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

local fzf_exec_calls
package.loaded['fzf-lua'] = {
  fzf_exec = function(lines, opts)
    table.insert(fzf_exec_calls, { lines = lines, opts = opts })
  end,
}

-- M.comment's only diffview dependency: which pane the cursor sits in. Stubbed so the
-- comment blocks below can drive the resolved side directly -- `anchor.resolve`'s own
-- side/status logic is covered in tests/anchor_spec.lua, not re-tested here.
local anchor_side
package.loaded['ado-pr.anchor'] = {
  current = function()
    return { filePath = '/src/foo.lua', line = 9, side = anchor_side }
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

local iterations = {
  { id = 1, sourceRefCommit = { commitId = 'c1' }, targetRefCommit = { commitId = 'base0' } },
  { id = 2, sourceRefCommit = { commitId = 'c2' }, targetRefCommit = { commitId = 'base0' } },
  { id = 3, sourceRefCommit = { commitId = 'c3' }, targetRefCommit = { commitId = 'base0' } },
}

local calls, post_calls
local checkout_result, show_result, fetch_result, revparse_result, threads_result
local override_fetch_result

local real_system = vim.system
local function stub_system()
  vim.system = function(cmd, opts)
    table.insert(calls, { kind = 'system', cmd = cmd, opts = opts })
    if cmd[1] == 'git' then
      if cmd[2] == 'fetch' and cmd[4] == 'refs/heads/main' then
        return {
          wait = function()
            return fetch_result
          end,
        }
      elseif cmd[2] == 'fetch' then -- the override ref fetch
        return {
          wait = function()
            return override_fetch_result
          end,
        }
      elseif cmd[2] == 'rev-parse' then
        -- One mutable slot, reused sequentially: this suite is synchronous and each
        -- do-block sets `revparse_result` to whatever the very next rev-parse call
        -- (PR-open resolve or an override resolve) should return, same pattern
        -- review_base_spec.lua uses for its single-flow tests.
        return {
          wait = function()
            return revparse_result
          end,
        }
      elseif cmd[2] == 'cat-file' then -- ensure_commit's local-object check, select_iteration path
        return {
          wait = function()
            return { code = 0, stdout = '', stderr = '' }
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
    elseif vim.tbl_contains(cmd, 'pullRequestThreads') and vim.tbl_contains(cmd, 'POST') then
      -- Ordered BEFORE the list branch below: az.post_thread and az.list_threads invoke the
      -- same `pullRequestThreads` resource and differ only by --http-method.
      table.insert(post_calls, { cmd = cmd })
      return {
        wait = function()
          return { code = 0, stdout = vim.json.encode({ id = 999 }), stderr = '' }
        end,
      }
    elseif vim.tbl_contains(cmd, 'pullRequestThreads') then
      return {
        wait = function()
          return threads_result
        end,
      }
    elseif vim.tbl_contains(cmd, 'pullRequestIterations') then
      return {
        wait = function()
          return { code = 0, stdout = vim.json.encode({ count = #iterations, value = iterations }), stderr = '' }
        end,
      }
    end
    error('unexpected vim.system call: ' .. vim.inspect(cmd))
  end
end

-- Substring of the ex-command the stub below should throw on, or nil for "none throws".
-- Same mutable-slot idiom as `revparse_result`: set it in a do-block to simulate an
-- operational Diffview failure (a DiffviewOpen that errors even though diffview.nvim IS
-- installed), which is a different failure mode from the ensure_diffview() guard's.
local cmd_error_on

local real_cmd = vim.cmd
local function stub_cmd()
  vim.cmd = function(c)
    table.insert(calls, { kind = 'cmd', cmd = c })
    if cmd_error_on and c:find(cmd_error_on, 1, true) then
      error('Diffview: ' .. c .. ' failed')
    end
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

local function reset()
  calls = {}
  post_calls = {}
  anchor_side = 'right'
  signs_calls = {}
  view_calls = {}
  set_threads_calls = {}
  fzf_exec_calls = {}
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
  fetch_result = { code = 0, stdout = '', stderr = '' }
  revparse_result = { code = 0, stdout = 'deadbeef\n', stderr = '' }
  threads_result = { code = 0, stdout = vim.json.encode({ count = 0, value = {} }), stderr = '' }
  override_fetch_result = { code = 0, stdout = '', stderr = '' }
  cmd_error_on = nil
end

-- Arms `revparse_result` for the next rev-parse call (the override resolve that follows
-- an already-open PR) -- see the mutable-slot comment on the stub above.
local function arm_override_revparse()
  revparse_result = { code = 0, stdout = 'cafef00d\n', stderr = '' }
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

local function open_pr(id)
  review.open(id or 21121)
end

-- ---------------------------------------------------------------------------
-- :AdoPrSetDiffBase -- success
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr()
  local expected_cwd = state.get().repo_root
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  arm_override_revparse()
  review.set_diff_base('release/1.2')

  local fetch_idx
  for i, c in ipairs(calls) do
    if c.kind == 'system' and c.cmd[1] == 'git' and c.cmd[2] == 'fetch' then
      fetch_idx = i
    end
  end
  ok(fetch_idx ~= nil, 'set_diff_base success: git fetch issued')
  if fetch_idx then
    ok(
      vim.deep_equal(calls[fetch_idx].cmd, { 'git', 'fetch', 'origin', 'release/1.2' }),
      'set_diff_base success: fetch argv resolves the given ref',
      vim.inspect(calls[fetch_idx].cmd)
    )
    ok(calls[fetch_idx].opts and calls[fetch_idx].opts.cwd == expected_cwd, 'set_diff_base success: fetch cwd is the review worktree')
  end

  eq(state.get().override_base, 'cafef00d', 'set_diff_base success: override_base set to the resolved commit')
  ok(state.get().window == nil, 'set_diff_base success: window cleared')
  ok(state.get().head == nil, 'set_diff_base success: head cleared')

  local diff_open
  for _, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewOpen cafef00d...HEAD' then
      diff_open = true
    end
  end
  ok(diff_open, 'set_diff_base success: diff reopened against the resolved override', vim.inspect(cmd_calls()))

  ok(set_threads_calls[1] and set_threads_calls[1].window == nil, 'set_diff_base success: plain-view threads reloaded')
end

-- ---------------------------------------------------------------------------
-- :AdoPrSetDiffBase -- failure after retries leaves state/diff untouched
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr()
  override_fetch_result = { code = 1, stdout = '', stderr = 'no route to host' }
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  review.set_diff_base('bad-ref')

  local fetch_attempts = 0
  for _, c in ipairs(calls) do
    if c.kind == 'system' and c.cmd[1] == 'git' and c.cmd[2] == 'fetch' and c.cmd[4] == 'bad-ref' then
      fetch_attempts = fetch_attempts + 1
    end
  end
  ok(fetch_attempts > 1, 'set_diff_base failure: retried more than once', fetch_attempts)

  local warn_count, error_count = 0, 0
  for _, n in ipairs(notifications) do
    if n.level == vim.log.levels.WARN then
      warn_count = warn_count + 1
    end
    if n.level == vim.log.levels.ERROR then
      error_count = error_count + 1
    end
  end
  ok(warn_count == fetch_attempts - 1, 'set_diff_base failure: WARN per failed attempt except the last', warn_count .. ' vs ' .. (fetch_attempts - 1))
  ok(error_count > 0, 'set_diff_base failure: raises ERROR after the final attempt')

  ok(state.get().override_base == nil, 'set_diff_base failure: override_base left untouched')
  ok(#cmd_calls() == 0, 'set_diff_base failure: no DiffviewOpen/DiffviewClose issued')
  ok(#set_threads_calls == 0, 'set_diff_base failure: threads not reloaded')
end

-- ---------------------------------------------------------------------------
-- :AdoPrShowDiffBase
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr()
  notifications = {}

  review.show_diff_base()
  ok(has_level(vim.log.levels.INFO), 'show_diff_base default: notifies INFO')
  local msg = notifications[1] and notifications[1].msg or ''
  ok(msg:find('deadbeef', 1, true) ~= nil, 'show_diff_base default: reports the ADO-resolved base', msg)
  ok(not msg:lower():find('override'), 'show_diff_base default: does not claim an override is active', msg)
end

do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  notifications = {}

  review.show_diff_base()
  ok(has_level(vim.log.levels.INFO), 'show_diff_base override: notifies INFO')
  local msg = notifications[1] and notifications[1].msg or ''
  ok(msg:find('cafef00d', 1, true) ~= nil, 'show_diff_base override: reports the override base', msg)
  ok(msg:lower():find('override') ~= nil, 'show_diff_base override: reports it as an override', msg)
end

-- ---------------------------------------------------------------------------
-- :AdoPrResetDiffBase
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr()
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  review.reset_diff_base()

  ok(state.get().override_base == nil, 'reset_diff_base: override_base cleared')
  local diff_open
  for _, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewOpen deadbeef...HEAD' then
      diff_open = true
    end
  end
  ok(diff_open, 'reset_diff_base: reopens against pr_base', vim.inspect(cmd_calls()))
  ok(set_threads_calls[1] and set_threads_calls[1].window == nil, 'reset_diff_base: plain-view threads reloaded')
end

-- ---------------------------------------------------------------------------
-- Unconditional reopen: fires even when already in the Full-PR view
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  -- Already in the Full-PR view (ctx.window == nil), yet reset_diff_base must still reopen.
  ok(state.get().window == nil, 'precondition: already in the full-PR view')
  review.reset_diff_base()

  local diff_open
  for _, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewOpen deadbeef...HEAD' then
      diff_open = true
    end
  end
  ok(diff_open, 'unconditional reopen: DiffviewOpen fires even when ctx.window was already nil', vim.inspect(cmd_calls()))
end

do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  review.reset_window()

  local diff_open
  for _, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewOpen deadbeef...HEAD' then
      diff_open = true
    end
  end
  ok(diff_open, 'unconditional reopen: reset_window fires even when ctx.window was already nil', vim.inspect(cmd_calls()))
end

-- ---------------------------------------------------------------------------
-- Diffview unavailable: set_diff_base / reset_diff_base must not desync state from the
-- visible diff -- ensure_diffview() must be checked BEFORE any state mutation, not after
-- (see reopen_full_view's own internal ensure_diffview guard, which is too late for these
-- two entry points). Same package.loaded['diffview'] = nil stubbing as tests/
-- review_base_spec.lua's "Diffview unavailable" block.
-- ---------------------------------------------------------------------------
do
  local saved_diffview = package.loaded['diffview']
  reset()
  open_pr()
  package.loaded['diffview'] = nil
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  review.set_diff_base('release/1.2')
  package.loaded['diffview'] = saved_diffview

  ok(state.get().override_base == nil, 'set_diff_base, diffview unavailable: override_base left unset')
  ok(state.get().window == nil, 'set_diff_base, diffview unavailable: window untouched')
  eq(state.get().base, 'deadbeef', 'set_diff_base, diffview unavailable: base untouched')
  ok(#cmd_calls() == 0, 'set_diff_base, diffview unavailable: no DiffviewOpen/DiffviewClose issued', vim.inspect(cmd_calls()))
  ok(#set_threads_calls == 0, 'set_diff_base, diffview unavailable: threads not reloaded')
  local fetch_issued = false
  for _, c in ipairs(calls) do
    if c.kind == 'system' and c.cmd[1] == 'git' and c.cmd[2] == 'fetch' then
      fetch_issued = true
    end
  end
  ok(not fetch_issued, 'set_diff_base, diffview unavailable: no git fetch issued')
  ok(
    notifications[1] and notifications[1].msg == 'ado-pr: iteration browsing needs diffview.nvim' and notifications[1].level == vim.log.levels.ERROR,
    'set_diff_base, diffview unavailable: notifies the same ERROR ensure_diffview() always produces',
    vim.inspect(notifications)
  )
end

do
  local saved_diffview = package.loaded['diffview']
  reset()
  open_pr()
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  package.loaded['diffview'] = nil
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  review.reset_diff_base()
  package.loaded['diffview'] = saved_diffview

  eq(state.get().override_base, 'cafef00d', 'reset_diff_base, diffview unavailable: override_base left untouched')
  ok(#cmd_calls() == 0, 'reset_diff_base, diffview unavailable: no DiffviewOpen/DiffviewClose issued', vim.inspect(cmd_calls()))
  ok(#set_threads_calls == 0, 'reset_diff_base, diffview unavailable: threads not reloaded')
  ok(
    notifications[1] and notifications[1].msg == 'ado-pr: iteration browsing needs diffview.nvim' and notifications[1].level == vim.log.levels.ERROR,
    'reset_diff_base, diffview unavailable: notifies the same ERROR ensure_diffview() always produces',
    vim.inspect(notifications)
  )
end

-- ---------------------------------------------------------------------------
-- DiffviewOpen itself throws: the override must not be committed to state while the
-- visible diff never changed. Distinct from the ensure_diffview() blocks above --
-- diffview.nvim IS installed here, the open just fails operationally (malformed revspec,
-- an internal diffview error). The call under test is pcall'd because pre-fix the error
-- propagates all the way out; post-fix it must be swallowed and reported (call_ok true).
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}
  arm_override_revparse()
  cmd_error_on = 'DiffviewOpen'

  local call_ok = pcall(review.set_diff_base, 'release/1.2')
  cmd_error_on = nil

  ok(call_ok, 'set_diff_base, DiffviewOpen throws: error is handled, not propagated to the caller')
  ok(state.get().override_base == nil, 'set_diff_base, DiffviewOpen throws: override_base left unset')
  eq(state.get().base, 'deadbeef', 'set_diff_base, DiffviewOpen throws: base left at the PR base')
  ok(state.get().window == nil, 'set_diff_base, DiffviewOpen throws: window untouched')
  ok(state.get().head == nil, 'set_diff_base, DiffviewOpen throws: head untouched')
  ok(#set_threads_calls == 0, 'set_diff_base, DiffviewOpen throws: threads not reloaded')
  ok(#view_calls == 0, 'set_diff_base, DiffviewOpen throws: follower pane not re-attached')
  ok(has_level(vim.log.levels.ERROR), 'set_diff_base, DiffviewOpen throws: notifies ERROR', vim.inspect(notifications))
end

do
  reset()
  open_pr()
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}
  cmd_error_on = 'DiffviewOpen'

  local call_ok = pcall(review.reset_diff_base)
  cmd_error_on = nil

  ok(call_ok, 'reset_diff_base, DiffviewOpen throws: error is handled, not propagated to the caller')
  eq(state.get().override_base, 'cafef00d', 'reset_diff_base, DiffviewOpen throws: override_base left in place')
  eq(state.get().base, 'cafef00d', 'reset_diff_base, DiffviewOpen throws: base left at the override')
  ok(#set_threads_calls == 0, 'reset_diff_base, DiffviewOpen throws: threads not reloaded')
  ok(has_level(vim.log.levels.ERROR), 'reset_diff_base, DiffviewOpen throws: notifies ERROR', vim.inspect(notifications))
end

-- select_iteration opens a diff range too, so it needs the same guard reopen_full_view
-- has: an operational DiffviewOpen failure must not commit an iteration window whose diff
-- never actually opened.
do
  reset()
  open_pr()
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}
  cmd_error_on = 'DiffviewOpen'

  local call_ok = pcall(review.select_iteration, iterations, 3)
  cmd_error_on = nil

  ok(call_ok, 'select_iteration, DiffviewOpen throws: error is handled, not propagated to the caller')
  ok(state.get().window == nil, 'select_iteration, DiffviewOpen throws: window left unset')
  eq(state.get().base, 'deadbeef', 'select_iteration, DiffviewOpen throws: base left at the PR base')
  ok(state.get().head == nil, 'select_iteration, DiffviewOpen throws: head left unset')
  ok(#set_threads_calls == 0, 'select_iteration, DiffviewOpen throws: threads not reloaded')
  ok(#view_calls == 0, 'select_iteration, DiffviewOpen throws: follower pane not re-attached')
  ok(has_level(vim.log.levels.ERROR), 'select_iteration, DiffviewOpen throws: notifies ERROR', vim.inspect(notifications))
end

-- ---------------------------------------------------------------------------
-- Setting an override while browsing an iteration window exits back to Full-PR view
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr()
  review.select_iteration(iterations, 3)
  ok(state.get().window ~= nil, 'precondition: browsing an iteration window')
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  arm_override_revparse()
  review.set_diff_base('release/1.2')

  ok(state.get().window == nil, 'set_diff_base while browsing: window cleared, back to Full-PR view')
  local diff_open
  for _, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewOpen cafef00d...HEAD' then
      diff_open = true
    end
  end
  ok(diff_open, 'set_diff_base while browsing: reopens Full-PR view against the override', vim.inspect(cmd_calls()))
end

-- An iteration diff's base is unaffected by an active override -- iterations always diff
-- their own per-push commit pair.
do
  reset()
  open_pr()
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  review.select_iteration(iterations, 3)

  local diff_open
  for _, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewOpen c2...c3' then
      diff_open = true
    end
  end
  ok(diff_open, 'select_iteration: unaffected by an active override', vim.inspect(cmd_calls()))
  -- Not a restatement of the DiffviewOpen assertion above: signs.lua diffs state.range()
  -- (base...head) itself, so the committed commit pair is its own claim -- the override must
  -- not leak into it either.
  eq(state.get().base, 'c2', 'select_iteration: state.base is the windows own base, not the override')
  eq(state.get().head, 'c3', 'select_iteration: state.head is the windows own head under an active override')
  -- The override survives the iteration window rather than being cleared by it -- returning to
  -- the Full-PR view picking the override back up (the block below) depends on this.
  eq(state.get().override_base, 'cafef00d', 'select_iteration: override_base survives an iteration window')
end

-- Returning to "Full PR (all iterations)" from the :AdoPrIterations picker reopens against the
-- effective base -- the override when one is active, not pr_base. Driven through
-- browse_iterations' own picker callback (the AC's wording), not review.reset_window directly,
-- the same way tests/review_iterations_spec.lua drives its stale-selection case.
do
  reset()
  open_pr()
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  review.select_iteration(iterations, 3)
  ok(state.get().window ~= nil, 'precondition: browsing an iteration window with an override active')

  review.browse_iterations()
  ok(#fzf_exec_calls == 1, 'browse_iterations: opens the fzf picker')
  local full_view_line = fzf_exec_calls[1].lines[1]
  local default_action = fzf_exec_calls[1].opts.actions['default']
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  default_action({ full_view_line })
  vim.wait(10) -- the picker callback is vim.schedule'd

  local diff_open
  for _, c in ipairs(cmd_calls()) do
    if c.cmd == 'DiffviewOpen cafef00d...HEAD' then
      diff_open = true
    end
  end
  ok(diff_open, 'full-view row: reopens against the override, not pr_base', vim.inspect(cmd_calls()))
  ok(state.get().window == nil, 'full-view row: window cleared')
  eq(state.get().base, 'cafef00d', 'full-view row: state.base is the effective base')
  ok(state.get().head == nil, 'full-view row: head cleared (defaults back to HEAD)')
  eq(state.get().override_base, 'cafef00d', 'full-view row: override_base still active')
  ok(set_threads_calls[1] and set_threads_calls[1].window == nil, 'full-view row: plain-view threads reloaded')
end

-- ---------------------------------------------------------------------------
-- :AdoPrReview always starts with override_base unset
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr(1)
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  eq(state.get().override_base, 'cafef00d', 'precondition: override_base set on the first PR')
  calls, signs_calls, view_calls, set_threads_calls, notifications = {}, {}, {}, {}, {}

  open_pr(2)

  ok(state.get().override_base == nil, 'AdoPrReview: fresh context has override_base unset, not carried over')
end

-- ---------------------------------------------------------------------------
-- Commenting while an override is active: the left (old) side's line numbers come from the
-- overridden base commit's content, not the target-based diff ADO renders, so a left-side
-- thread could anchor to the wrong line in ADO's UI (issue #54). The right side is always
-- the checked-out worktree (HEAD), independent of the diff base, so it stays postable.
-- ---------------------------------------------------------------------------
do
  reset()
  open_pr()
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  notifications, post_calls = {}, {}
  anchor_side = 'left'

  ok(state.get().window == nil, 'precondition: not browsing an iteration window')
  review.comment('should not post')

  local msg = notifications[1] and notifications[1].msg or ''
  ok(notifications[1] and notifications[1].level == vim.log.levels.ERROR, 'comment left + override: refused with an ERROR', vim.inspect(notifications))
  ok(msg:find(':AdoPrResetDiffBase', 1, true) ~= nil, 'comment left + override: names the remedy command', msg)
  ok(#post_calls == 0, 'comment left + override: no thread posted')
  -- A deleted file is left-side only (anchor.resolve rejects its right side, and yields
  -- side = 'left' from the left pane -- tests/anchor_spec.lua), so it takes this same
  -- rejection path with no special case of its own.
end

do
  reset()
  open_pr()
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  notifications, post_calls = {}, {}
  anchor_side = 'right'

  review.comment('ship it')

  ok(#post_calls == 1, 'comment right + override: thread still posted', #post_calls)
  ok(not has_level(vim.log.levels.ERROR), 'comment right + override: no ERROR', vim.inspect(notifications))
end

-- An iteration window and an override can both be active at once. M.comment checks the
-- window first, so that rejection wins -- the override guard never runs, and the user is
-- told the reason that actually applies (leave the window, not reset the override).
do
  reset()
  open_pr()
  arm_override_revparse()
  review.set_diff_base('release/1.2')
  review.select_iteration(iterations, 3)
  notifications, post_calls = {}, {}
  anchor_side = 'left'

  ok(state.get().window ~= nil, 'precondition: browsing an iteration window')
  eq(state.get().override_base, 'cafef00d', 'precondition: override still active')
  review.comment('should not post')

  local msg = notifications[1] and notifications[1].msg or ''
  ok(notifications[1] and notifications[1].level == vim.log.levels.ERROR, 'comment left + window + override: refused with an ERROR', vim.inspect(notifications))
  ok(msg:find(':AdoPrIterations', 1, true) ~= nil, 'comment left + window + override: the window rejection wins', msg)
  ok(msg:find(':AdoPrResetDiffBase', 1, true) == nil, 'comment left + window + override: not the override rejection', msg)
  ok(#post_calls == 0, 'comment left + window + override: no thread posted')
end

-- The discriminating case: the left side is only blocked BECAUSE an override is active.
do
  reset()
  open_pr()
  notifications, post_calls = {}, {}
  anchor_side = 'left'

  ok(state.get().override_base == nil, 'precondition: no override active')
  review.comment('nit')

  ok(#post_calls == 1, 'comment left + no override: thread posted normally', #post_calls)
  ok(not has_level(vim.log.levels.ERROR), 'comment left + no override: no ERROR', vim.inspect(notifications))
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
