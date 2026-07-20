-- fzf-lua PR picker: list active PRs, open the selected one for review.
local M = {}

local az = require('ado-pr.az')
local review = require('ado-pr.review')

function M.pick()
  local prs, err = az.list_prs()
  if not prs then
    vim.notify('ado-pr: ' .. err, vim.log.levels.ERROR)
    return
  end
  local ok, fzf = pcall(require, 'fzf-lua')
  if not ok then
    vim.notify('ado-pr: fzf-lua not found', vim.log.levels.ERROR)
    return
  end
  local id_of, lines = {}, {}
  for _, pr in ipairs(prs) do
    local line = string.format('!%d  %s  (%s)', pr.pullRequestId, pr.title, pr.createdBy.displayName)
    id_of[line] = pr.pullRequestId
    table.insert(lines, line)
  end
  fzf.fzf_exec(lines, {
    prompt = 'ADO PRs> ',
    actions = {
      ['default'] = function(selected)
        local id = selected and id_of[selected[1]]
        if id then
          review.open(id)
        end
      end,
    },
  })
end

return M
