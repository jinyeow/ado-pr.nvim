-- ado-pr.nvim — review Azure DevOps pull requests from Neovim.
-- MVP scope: pick/checkout/diff active PRs and set a vote via the `az` CLI,
-- reusing diffview.nvim for the diff UI. Inline comment threads are stubbed
-- (see az.post_thread TODO).
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

return M
