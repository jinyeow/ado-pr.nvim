-- User-facing configuration for ado-pr.nvim.
-- Auth reuses `az login`; this plugin stores NO PAT or secret.
local M = {}

local remote = require('ado-pr.remote')

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
    -- Overlapping threads on the same line: show_thread opens the pane (or,
    -- pressed again without moving the cursor, cycles to the next covering
    -- thread, wrapping); pick_thread opens a picker over all of them.
    show_thread = '<F6>',
    pick_thread = '<F7>',
  },
}

local current = vim.deepcopy(defaults)

function M.setup(opts)
  current = vim.tbl_deep_extend('force', vim.deepcopy(defaults), opts or {})
end

function M.get()
  return current
end

-- Auto-detected organization/project/repository, memoized per cwd (docs/specs/
-- per-directory-ado-config.md: detection runs lazily on the first PR-related command in a
-- session for that repo, not eagerly, and is cached rather than re-run per command). Caches
-- failures too, not just successes -- a repo with an unparsable/missing origin should not
-- re-shell-out to `git remote -v` on every subsequent command.
-- cwd -> { triple = {organization,project,repository}|nil, err = string|nil }
local detected_by_cwd = {}

local function detect_for_cwd(cwd)
  local cached = detected_by_cwd[cwd]
  if cached then
    return cached.triple, cached.err
  end
  local remotes, rerr = remote.read_remotes(cwd)
  if not remotes then
    detected_by_cwd[cwd] = { err = rerr }
    return nil, rerr
  end
  local triple, derr = remote.detect(remotes)
  detected_by_cwd[cwd] = { triple = triple, err = derr }
  return triple, derr
end

-- Resolve one scope field: an explicit setup() value is used as-is (no detection attempted
-- at all -- other fields being unset doesn't force a git shell-out to resolve this one).
-- Otherwise, auto-detect from the current cwd's git remotes and return that field, or
-- (nil, reason) when detection failed -- callers surface this as a `vim.notify` ERROR and
-- abort rather than falling through to a downstream `az` error (fail-loud convention).
local function resolve_field(field)
  if current[field] then
    return current[field], nil
  end
  local triple, err = detect_for_cwd(vim.fn.getcwd())
  if not triple then
    return nil, ('could not auto-detect %s: %s -- set it explicitly via setup()'):format(field, err)
  end
  return triple[field], nil
end

function M.resolve_organization()
  return resolve_field('organization')
end

function M.resolve_project()
  return resolve_field('project')
end

function M.resolve_repository()
  return resolve_field('repository')
end

return M
