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

-- Run an az command; return (decoded_json|nil, err|nil).
local function az_json(args)
  local res = vim.system(vim.list_extend({ 'az' }, args), { text = true }):wait()
  if res.code ~= 0 then
    return nil, (res.stderr ~= '' and res.stderr or ('az exited ' .. res.code))
  end
  local ok, decoded = pcall(vim.json.decode, res.stdout)
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
  local res = vim.system({ 'az', 'repos', 'pr', 'checkout', '--id', tostring(id) }, { text = true }):wait()
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
  local res = vim.system(vim.list_extend({ 'az' }, args), { text = true }):wait()
  return res.code == 0, (res.code ~= 0 and (res.stderr ~= '' and res.stderr or 'set-vote failed') or nil)
end

-- TODO(mvp): post an inline comment thread via `az devops invoke`:
--   az devops invoke --area git --resource pullRequestThreads --http-method POST
--     --route-parameters project={p} repositoryId={r} pullRequestId={id}
--     --in-file <thread.json> --api-version {config.api_version}
-- thread.json shape:
--   { "comments": [{ "content": "...", "commentType": 1 }],
--     "status": 1,
--     "threadContext": { "filePath": "/path",
--       "rightFileStart": { "line": L, "offset": 1 },
--       "rightFileEnd":   { "line": L, "offset": 1 } } }
-- The hard part is mapping the diffview buffer's cursor to (filePath, line) on
-- the correct side — see the cobalt initiative's "cursor file != displayed file"
-- gotcha before implementing.
function M.post_thread(id, thread) -- luacheck: ignore 212
  return nil, 'not implemented: see TODO in az.lua (az devops invoke pullRequestThreads)'
end

return M
