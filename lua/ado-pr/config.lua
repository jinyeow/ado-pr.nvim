-- User-facing configuration for ado-pr.nvim.
-- Auth reuses `az login`; this plugin stores NO PAT or secret.
local M = {}

local defaults = {
  organization = nil, -- e.g. 'https://dev.azure.com/HollardInsuranceRetail'
  project = nil, -- e.g. 'TSC Cloud Platform Engineering'
  repository = nil, -- e.g. 'T2.ServiceCatalogue'
  api_version = '7.1', -- ADO REST api-version for `az devops invoke`
}

local current = vim.deepcopy(defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

function M.get()
  return current
end

return M
