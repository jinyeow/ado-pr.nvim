-- User-facing configuration for ado-pr.nvim.
-- Auth reuses `az login`; this plugin stores NO PAT or secret.
local M = {}

local defaults = {
  organization = nil, -- e.g. 'https://dev.azure.com/HollardInsuranceRetail'
  project = nil, -- e.g. 'TSC Cloud Platform Engineering'
  repository = nil, -- e.g. 'T2.ServiceCatalogue'
  api_version = '7.1', -- ADO REST api-version for `az devops invoke`
  pane_height = 14, -- thread follower pane split height, in lines (view.lua)
  wrap_width = 76, -- thread follower pane comment wrap width, in characters (view.lua)
  keymaps = {
    -- Buffer-local to diffview's diff windows only (signs.lua / view.lua wire
    -- these), single-key by default -- prototypes/NOTES.md found two-key
    -- <leader> sequences read as sluggish under a short timeoutlen.
    toggle_thread_pane = '<F8>',
    next_thread = ']t',
    prev_thread = '[t',
  },
}

local current = vim.deepcopy(defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

function M.get()
  return current
end

return M
