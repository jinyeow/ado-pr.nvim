-- ado-pr.nvim — review Azure DevOps pull requests from Neovim.
-- MVP scope: pick/checkout/diff active PRs, set a vote, and post inline comment
-- threads via the `az` CLI, reusing diffview.nvim for the diff UI.
local M = {}

M.config = require('ado-pr.config')

function M.setup(opts)
  M.config.setup(opts)
end

-- Lazy accessors so `require('ado-pr')` stays cheap at startup.
function M.pick()
  return require('ado-pr.picker').pick()
end

function M.review(id)
  return require('ado-pr.review').open(id)
end

function M.vote(id, v)
  return require('ado-pr.az').set_vote(id, v)
end

function M.comment(text)
  return require('ado-pr.review').comment(text)
end

function M.browse_iterations()
  return require('ado-pr.review').browse_iterations()
end

return M
