-- Azure DevOps glue for ado-pr.nvim.
--
-- Reads + checkout go through the `az` CLI (azure-devops extension); inline
-- comments go through `az devops invoke` (no first-class `az repos pr comment`
-- verb exists). Auth reuses the user's `az login` — this module stores no PAT.
--
-- REST reference for the write path (api-version 7.1):
--   threads:  POST git/repositories/{repo}/pullRequests/{id}/threads
--   vote:     handled by `az repos pr set-vote` (maps to PUT .../reviewers/{id})
local M = {}

local config = require('ado-pr.config')

-- On Windows the CLI entry point is `az.cmd`; libuv's spawn does no PATHEXT
-- search, so a bare `az` ENOENTs. Naming `az.cmd` is not enough either: libuv's
-- batch-file handling wraps the spawn in cmd.exe itself and mangles the command
-- line when an ARGUMENT contains a space while az.cmd's PATH also does
-- ("'C:\Program' is not recognized...") — hit live the moment a project name
-- with spaces went into --route-parameters. Spawning cmd.exe (a real .exe)
-- explicitly takes libuv's normal argv quoting, and cmd resolves az.cmd from
-- PATH (a space-free token).
local az_argv = vim.fn.has('win32') == 1 and { 'cmd.exe', '/d', '/c', 'az.cmd' } or { 'az' }
M.az_argv = az_argv

local function az_cmdline(args)
  return vim.list_extend(vim.deepcopy(az_argv), args)
end

-- Run an az command; return (decoded_json|nil, err|nil).
local function az_json(args)
  local res = vim.system(az_cmdline(args), { text = true }):wait()
  if res.code ~= 0 then
    return nil, (res.stderr ~= '' and res.stderr or ('az exited ' .. res.code))
  end
  -- `az devops invoke` prints a "Please wait ..." preamble to stdout before the
  -- JSON body; skip anything before the first `{`/`[` (a no-op for clean
  -- `az repos ...` output, which already starts at the brace).
  local out = res.stdout or ''
  local start = out:find('[%[{]')
  if start then
    out = out:sub(start)
  end
  local ok, decoded = pcall(vim.json.decode, out)
  if not ok then
    return nil, 'failed to decode az output: ' .. tostring(decoded)
  end
  return decoded, nil
end
M.az_json = az_json

-- Shared --organization/--project args from config.
local function scope_args()
  local a, c = {}, config.get()
  if c.organization then
    vim.list_extend(a, { '--organization', c.organization })
  end
  if c.project then
    vim.list_extend(a, { '--project', c.project })
  end
  return a
end

-- Just --organization. `az devops invoke` takes project via --route-parameters,
-- not --project, so it must not get the full scope_args.
local function org_args()
  local a, c = {}, config.get()
  if c.organization then
    vim.list_extend(a, { '--organization', c.organization })
  end
  return a
end

-- List active PRs for the configured repo.
function M.list_prs()
  local args = { 'repos', 'pr', 'list', '--status', 'active', '--output', 'json' }
  local c = config.get()
  if c.repository then
    vim.list_extend(args, { '--repository', c.repository })
  end
  vim.list_extend(args, scope_args())
  return az_json(args)
end

-- Show one PR by id.
function M.show_pr(id)
  local args = { 'repos', 'pr', 'show', '--id', tostring(id), '--output', 'json' }
  vim.list_extend(args, scope_args())
  return az_json(args)
end

-- Checkout a PR's source branch into the CURRENT worktree (needs a clean tree).
-- Intended to run from the user's dedicated detached `review` worktree.
function M.checkout(id)
  local res = vim.system(az_cmdline({ 'repos', 'pr', 'checkout', '--id', tostring(id) }), { text = true }):wait()
  if res.code ~= 0 then
    return false, (res.stderr ~= '' and res.stderr or ('az exited ' .. res.code))
  end
  return true, nil
end

-- Set the caller's vote.
-- vote: 'approve'|'approve-with-suggestions'|'wait-for-author'|'reject'|'reset'
function M.set_vote(id, vote)
  local args = { 'repos', 'pr', 'set-vote', '--id', tostring(id), '--vote', vote }
  vim.list_extend(args, scope_args())
  local res = vim.system(az_cmdline(args), { text = true }):wait()
  return res.code == 0, (res.code ~= 0 and (res.stderr ~= '' and res.stderr or 'set-vote failed') or nil)
end

-- Post an inline comment thread on a PR via `az devops invoke` (no first-class
-- `az repos pr comment` verb exists). Resource `git/pullRequestThreads` maps to
--   POST git/repositories/{repo}/pullRequests/{id}/threads
-- The threadContext body shape is mirrored from cobalt's tested client:
--   status 1 = active; commentType 1 = text; a one-based line/offset on the
--   right (new) side or the left (old) side, never both.
--   ctx:    { id, repositoryId, project } (see ado-pr.state)
--   anchor: { filePath = '/rel', line, side = 'right'|'left' } (see ado-pr.anchor)
-- Returns (thread_id|nil, err|nil).
function M.post_thread(ctx, anchor, content)
  local pos = { line = anchor.line, offset = 1 }
  local thread_context = { filePath = anchor.filePath }
  if anchor.side == 'left' then
    thread_context.leftFileStart, thread_context.leftFileEnd = pos, pos
  else
    thread_context.rightFileStart, thread_context.rightFileEnd = pos, pos
  end
  local thread = {
    comments = { { content = content, commentType = 1 } },
    status = 1,
    threadContext = thread_context,
  }

  local tmp = vim.fn.tempname()
  local f, ferr = io.open(tmp, 'w')
  if not f then
    return nil, 'could not write thread body to ' .. tmp .. ': ' .. tostring(ferr)
  end
  f:write(vim.json.encode(thread))
  f:close()

  local args = {
    'devops', 'invoke',
    '--area', 'git', '--resource', 'pullRequestThreads',
    '--http-method', 'POST',
    '--route-parameters',
    'project=' .. ctx.project,
    'repositoryId=' .. ctx.repositoryId,
    'pullRequestId=' .. tostring(ctx.id),
    '--in-file', tmp,
    '--api-version', config.get().api_version,
    '--output', 'json',
  }
  vim.list_extend(args, org_args())
  local decoded, err = az_json(args)
  os.remove(tmp)
  if not decoded then
    return nil, err
  end
  return decoded.id, nil
end

-- Shared decoder: `az devops invoke` on a list resource returns
-- { count, value = { ...items... } }; unwrap to the array. A response missing
-- `value` (or with `value` not an array/table) does not match that envelope --
-- raise rather than silently treating a real transport/schema failure as "no
-- comments". `{ count = 0, value = {} }` (a PR with zero threads) is a valid
-- envelope and still decodes to an empty list. Returns (threads|nil, err|nil).
local function decode_threads(decoded, err)
  if not decoded then
    return nil, err
  end
  if type(decoded) ~= 'table' or type(decoded.value) ~= 'table' then
    return nil, 'malformed thread response: expected { count, value = {...} } envelope, got ' .. vim.inspect(decoded)
  end
  return decoded.value, nil
end

-- Plain thread list: no trackingCriteria on any thread (ADR-0002). Same
-- `az devops invoke` transport and `az login` session as post_thread -- no new
-- token, no stored secret.
function M.list_threads(ctx)
  local args = {
    'devops', 'invoke',
    '--area', 'git', '--resource', 'pullRequestThreads',
    '--http-method', 'GET',
    '--route-parameters',
    'project=' .. ctx.project,
    'repositoryId=' .. ctx.repositoryId,
    'pullRequestId=' .. tostring(ctx.id),
    '--api-version', config.get().api_version,
    '--output', 'json',
  }
  vim.list_extend(args, org_args())
  return decode_threads(az_json(args))
end

-- Thread list fetched under an iteration window: `$iteration`/`$baseIteration`
-- query parameters make ADO include `trackingCriteria` on threads it can track
-- (ADR-0002) and re-anchor `threadContext` to that window's side. Deliberately a
-- separate function from list_threads, not a mode switch: the two calls return
-- materially different data and serve different features.
function M.list_threads_tracked(ctx, iteration, base_iteration)
  local args = {
    'devops', 'invoke',
    '--area', 'git', '--resource', 'pullRequestThreads',
    '--http-method', 'GET',
    '--route-parameters',
    'project=' .. ctx.project,
    'repositoryId=' .. ctx.repositoryId,
    'pullRequestId=' .. tostring(ctx.id),
    '--query-parameters',
    '$iteration=' .. tostring(iteration),
    '$baseIteration=' .. tostring(base_iteration),
    '--api-version', config.get().api_version,
    '--output', 'json',
  }
  vim.list_extend(args, org_args())
  return decode_threads(az_json(args))
end

return M
