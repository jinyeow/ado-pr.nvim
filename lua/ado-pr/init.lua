-- ado-pr.nvim — review Azure DevOps pull requests from Neovim.
-- MVP scope: pick/checkout/diff active PRs, set a vote, and post inline comment
-- threads via the `az` CLI, reusing diffview.nvim for the diff UI.
local M = {}

M.config = require('ado-pr.config')

function M.setup(opts)
  M.config.setup(opts)
end

function M.set_scope(fargs)
  return M.config.set_scope(fargs)
end

function M.show_scope()
  return M.config.show_scope()
end

function M.reset_scope(fargs)
  return M.config.reset_scope(fargs)
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

function M.set_diff_base(ref)
  return require('ado-pr.review').set_diff_base(ref)
end

function M.show_diff_base()
  return require('ado-pr.review').show_diff_base()
end

function M.reset_diff_base()
  return require('ado-pr.review').reset_diff_base()
end

return M
