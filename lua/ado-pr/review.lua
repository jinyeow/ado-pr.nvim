-- Checkout a PR into the current (review) worktree, open its diff, and post
-- inline comments against the diff.
local M = {}

local az = require('ado-pr.az')
local anchor = require('ado-pr.anchor')
local config = require('ado-pr.config')
local state = require('ado-pr.state')

-- Record the active-PR context so :AdoPrComment knows which PR/repo to post to.
-- The threads route wants the repository GUID, taken from the PR payload.
local function capture_context(id)
  local pr, err = az.show_pr(id)
  if not pr then
    vim.notify('ado-pr: could not load PR !' .. id .. ' details (commenting disabled): ' .. err, vim.log.levels.WARN)
    state.clear()
    return
  end
  local repo = pr.repository or {}
  state.set({
    id = id,
    repositoryId = repo.id,
    project = (repo.project and repo.project.name) or config.get().project,
  })
end

function M.open(id)
  local ok, err = az.checkout(id)
  if not ok then
    vim.notify('ado-pr: checkout failed: ' .. err, vim.log.levels.ERROR)
    return
  end
  capture_context(id)
  local base = config.get().base_branch
  if pcall(require, 'diffview') then
    vim.cmd('DiffviewOpen ' .. base .. '...HEAD')
  else
    vim.cmd('Git difftool ' .. base .. '...HEAD') -- vim-fugitive fallback
  end
end

-- Post an inline comment thread on the line under the cursor in the diff.
function M.comment()
  local ctx = state.get()
  if not ctx or not ctx.repositoryId then
    vim.notify('ado-pr: no active PR — run :AdoPr / :AdoPrReview first', vim.log.levels.ERROR)
    return
  end
  local a, err = anchor.current()
  if not a then
    vim.notify('ado-pr: ' .. err, vim.log.levels.ERROR)
    return
  end
  vim.ui.input({
    prompt = ('PR comment @ %s:%d (%s): '):format(a.filePath, a.line, a.side),
  }, function(content)
    if not content or content == '' then
      return
    end
    local thread_id, perr = az.post_thread(ctx, a, content)
    vim.notify(
      thread_id and ('ado-pr: thread posted on !' .. ctx.id) or ('ado-pr: ' .. (perr or 'post failed')),
      thread_id and vim.log.levels.INFO or vim.log.levels.ERROR
    )
  end)
end

return M
