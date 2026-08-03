-- Diff-base resolution tests for ado-pr.review.open. The live PR/checkout
-- cannot run without a real PR, so this stubs `vim.system` (az checkout/show,
-- git fetch, git rev-parse) and `vim.cmd` (DiffviewOpen), pinning: the target
-- ref is resolved from the PR payload (not config), fetched before the diff
-- opens, and a resolve/fetch failure aborts without ever opening a diff.
-- Run headless: `nvim --headless -l tests/review_base_spec.lua`.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local config = require('ado-pr.config')
config.setup({ organization = 'https://dev.azure.com/Org', project = 'My Project' })

-- diffview is not an installed runtime dependency in the test environment;
-- stub it present so `pcall(require, 'diffview')` in review.lua succeeds and
-- the DiffviewOpen path (not the vim-fugitive fallback) is exercised.
package.loaded['diffview'] = {}

local az = require('ado-pr.az')
local review = require('ado-pr.review')

local failures, count = {}, 0
local function ok(cond, name, detail)
  count = count + 1
  if not cond then
    table.insert(failures, name .. (detail and ('  (' .. detail .. ')') or ''))
  end
end

-- Sequenced log of every vim.system call and every vim.cmd call, so ordering
-- (fetch before diff) is assertable, not just presence.
local calls
local checkout_result, show_result, fetch_result, revparse_result

local real_system = vim.system
local function stub_system()
  vim.system = function(cmd, opts)
    table.insert(calls, { kind = 'system', cmd = cmd, opts = opts })
    if cmd[1] == 'git' then
      if cmd[2] == 'fetch' then
        return { wait = function() return fetch_result end }
      elseif cmd[2] == 'rev-parse' then
        return { wait = function() return revparse_result end }
      end
      error('unexpected git subcommand: ' .. vim.inspect(cmd))
    end
    -- az goes through cmd.exe /d /c az.cmd on win32, bare az elsewhere (az.lua);
    -- dispatch on subcommand token, not argv[1], so this test is platform-agnostic.
    if vim.tbl_contains(cmd, 'checkout') then
      return { wait = function() return checkout_result end }
    elseif vim.tbl_contains(cmd, 'show') then
      return { wait = function() return show_result end }
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
  stub_system()
  stub_cmd()
  stub_notify()
  checkout_result = { code = 0, stdout = '', stderr = '' }
  show_result = {
    code = 0,
    stdout = vim.json.encode({
      repository = { id = 'repo-guid', project = { name = 'My Project' } },
      targetRefName = (opts and opts.target_ref) or 'refs/heads/main',
    }),
    stderr = '',
  }
  fetch_result = (opts and opts.fetch_result) or { code = 0, stdout = '', stderr = '' }
  revparse_result = (opts and opts.revparse_result) or { code = 0, stdout = 'deadbeef\n', stderr = '' }
end

local function system_calls()
  local out = {}
  for _, c in ipairs(calls) do
    if c.kind == 'system' then table.insert(out, c) end
  end
  return out
end
local function cmd_calls()
  local out = {}
  for _, c in ipairs(calls) do
    if c.kind == 'cmd' then table.insert(out, c) end
  end
  return out
end
local function index_of(kind_filter)
  for i, c in ipairs(calls) do
    if kind_filter(c) then return i end
  end
end

-- Happy path: fetch runs (argv + cwd), before DiffviewOpen, with a revspec
-- built from the resolved target (rev-parsed FETCH_HEAD), not config.
do
  reset({ target_ref = 'refs/heads/develop' })
  review.open(99)

  local fetch_idx = index_of(function(c)
    return c.kind == 'system' and c.cmd[1] == 'git' and c.cmd[2] == 'fetch'
  end)
  local diff_idx = index_of(function(c) return c.kind == 'cmd' end)

  ok(fetch_idx ~= nil, 'happy: git fetch issued')
  if fetch_idx then
    local fetch_call = calls[fetch_idx]
    ok(vim.deep_equal(fetch_call.cmd, { 'git', 'fetch', 'origin', 'refs/heads/develop' }),
      'happy: fetch argv (remote + resolved target ref)', vim.inspect(fetch_call.cmd))
    -- cwd passed explicitly (not left ambient) — the ticket requires the
    -- fetch to run with the review worktree as cwd.
    ok(fetch_call.opts and fetch_call.opts.cwd ~= nil, 'happy: fetch cwd set explicitly')
  end

  ok(diff_idx ~= nil, 'happy: DiffviewOpen issued')
  ok(fetch_idx and diff_idx and fetch_idx < diff_idx, 'happy: fetch precedes diff')
  if diff_idx then
    ok(calls[diff_idx].cmd == 'DiffviewOpen deadbeef...HEAD',
      'happy: revspec from resolved target', calls[diff_idx].cmd)
  end
end

-- A show_pr failure aborts: no fetch, no diff, an ERROR notify.
do
  reset()
  show_result = { code = 1, stdout = '', stderr = 'boom' }
  review.open(1)

  -- checkout + the failing show_pr both ran; no fetch follows a failed show_pr.
  ok(#system_calls() == 2, 'show_pr failure: checkout + show_pr ran, no fetch', #system_calls())
  ok(#cmd_calls() == 0, 'show_pr failure: DiffviewOpen never called')
  local has_error = false
  for _, n in ipairs(notifications) do
    if n.level == vim.log.levels.ERROR then has_error = true end
  end
  ok(has_error, 'show_pr failure: notifies at ERROR')
end

-- A git fetch failure aborts: no diff, an ERROR notify.
do
  reset({ fetch_result = { code = 1, stdout = '', stderr = 'no route to host' } })
  review.open(2)

  ok(#cmd_calls() == 0, 'fetch failure: DiffviewOpen never called')
  local has_error = false
  for _, n in ipairs(notifications) do
    if n.level == vim.log.levels.ERROR then has_error = true end
  end
  ok(has_error, 'fetch failure: notifies at ERROR')
end

-- A missing targetRefName in the PR payload aborts before any fetch.
do
  reset({ target_ref = '' })
  review.open(3)

  local fetch_idx = index_of(function(c)
    return c.kind == 'system' and c.cmd[1] == 'git' and c.cmd[2] == 'fetch'
  end)
  ok(fetch_idx == nil, 'missing targetRefName: no fetch issued')
  ok(#cmd_calls() == 0, 'missing targetRefName: DiffviewOpen never called')
  local has_error = false
  for _, n in ipairs(notifications) do
    if n.level == vim.log.levels.ERROR then has_error = true end
  end
  ok(has_error, 'missing targetRefName: notifies at ERROR')
end

-- A rev-parse failure (fetch succeeded but FETCH_HEAD won't resolve) aborts.
do
  reset({ revparse_result = { code = 1, stdout = '', stderr = 'unknown revision' } })
  review.open(4)

  ok(#cmd_calls() == 0, 'rev-parse failure: DiffviewOpen never called')
  local has_error = false
  for _, n in ipairs(notifications) do
    if n.level == vim.log.levels.ERROR then has_error = true end
  end
  ok(has_error, 'rev-parse failure: notifies at ERROR')
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
