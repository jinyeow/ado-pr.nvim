-- Active-PR context for the current review session.
--
-- One PR is under review at a time (the detached `review` worktree workflow), so
-- a single module-level record is enough. `review.open` sets it from `show_pr`;
-- `:AdoPrComment` reads it to know which PR/repo a thread belongs to. The repo is
-- carried as its GUID (from the PR payload), not its name — the threads route
-- wants the id.
local M = {}

---@class AdoPrContext
---@field id integer          pull request id
---@field repositoryId string repository GUID
---@field project string      project name (for the invoke route)

---@type AdoPrContext|nil
local current = nil

---@param ctx AdoPrContext
function M.set(ctx)
  current = ctx
end

---@return AdoPrContext|nil
function M.get()
  return current
end

function M.clear()
  current = nil
end

return M
