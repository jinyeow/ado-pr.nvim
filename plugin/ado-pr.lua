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
  require('ado-pr').comment(o.args ~= '' and o.args or nil, { line_start = o.line1, line_end = o.line2 })
end, {
  nargs = '*',
  range = true,
  desc = 'ado-pr: comment on the diff line under the cursor, or the line span of a visual selection (inline text or prompted)',
})

vim.api.nvim_create_user_command('AdoPrIterations', function()
  require('ado-pr').browse_iterations()
end, { desc = 'ado-pr: browse the active PR iterations, one push at a time' })

vim.api.nvim_create_user_command('AdoPrSetScope', function(o)
  require('ado-pr').set_scope(o.fargs)
end, {
  nargs = '+',
  desc = 'ado-pr: AdoPrSetScope organization=<url> project=<name> repository=<name> — session-only override of the auto-detected ADO scope',
})

vim.api.nvim_create_user_command('AdoPrShowScope', function()
  require('ado-pr').show_scope()
end, { desc = 'ado-pr: show the effective organization/project/repository and where each came from' })

vim.api.nvim_create_user_command('AdoPrResetScope', function(o)
  require('ado-pr').reset_scope(o.fargs)
end, {
  nargs = '*',
  desc = 'ado-pr: AdoPrResetScope [organization] [project] [repository] — clear the session scope override (all fields when given none)',
})

vim.api.nvim_create_user_command('AdoPrSetDiffBase', function(o)
  require('ado-pr').set_diff_base(o.args)
end, { nargs = 1, desc = 'ado-pr: set a session-only diff-base override for the Full-PR view' })

vim.api.nvim_create_user_command('AdoPrShowDiffBase', function()
  require('ado-pr').show_diff_base()
end, { desc = 'ado-pr: show the currently effective diff base' })

vim.api.nvim_create_user_command('AdoPrResetDiffBase', function()
  require('ado-pr').reset_diff_base()
end, { desc = 'ado-pr: clear the diff-base override, returning to the ADO-resolved target' })
