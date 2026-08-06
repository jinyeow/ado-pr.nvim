if vim.g.loaded_ado_pr then
  return
end
vim.g.loaded_ado_pr = true

vim.api.nvim_create_user_command('AdoPr', function()
  require('ado-pr').pick()
end, { desc = 'ado-pr: pick an active PR to review' })

vim.api.nvim_create_user_command('AdoPrReview', function(o)
  require('ado-pr').review(tonumber(o.args))
end, { nargs = 1, desc = 'ado-pr: checkout + diff a PR by id' })

vim.api.nvim_create_user_command('AdoPrVote', function(o)
  local id, vote = o.fargs[1], o.fargs[2]
  local ok, err = require('ado-pr').vote(tonumber(id), vote)
  vim.notify(
    ok and ('ado-pr: vote "' .. vote .. '" set on !' .. id) or ('ado-pr: ' .. (err or 'vote failed')),
    ok and vim.log.levels.INFO or vim.log.levels.ERROR
  )
end, { nargs = '+', desc = 'ado-pr: AdoPrVote <id> approve|wait-for-author|reject|reset' })

vim.api.nvim_create_user_command('AdoPrComment', function(o)
  require('ado-pr').comment(o.args ~= '' and o.args or nil)
end, { nargs = '*', desc = 'ado-pr: comment on the diff line under the cursor (inline text or prompted)' })

vim.api.nvim_create_user_command('AdoPrIterations', function()
  require('ado-pr').browse_iterations()
end, { desc = 'ado-pr: browse the active PR iterations, one push at a time' })
