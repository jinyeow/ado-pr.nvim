-- Checkout a PR into the current (review) worktree and open its diff.
local M = {}

local az = require('ado-pr.az')
local config = require('ado-pr.config')

function M.open(id)
  local ok, err = az.checkout(id)
  if not ok then
    vim.notify('ado-pr: checkout failed: ' .. err, vim.log.levels.ERROR)
    return
  end
  local base = config.get().base_branch
  if pcall(require, 'diffview') then
    vim.cmd('DiffviewOpen ' .. base .. '...HEAD')
  else
    vim.cmd('Git difftool ' .. base .. '...HEAD') -- vim-fugitive fallback
  end
end

return M
