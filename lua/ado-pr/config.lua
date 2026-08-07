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

local SCOPE_FIELDS = { organization = true, project = true, repository = true }

-- Pure. Parse `:AdoPrSetScope` arguments -- `field=value` tokens where a value runs until the
-- next recognised `field=` token. Values are taken from raw fargs because ADO project names
-- routinely contain spaces (e.g. 'TSC Cloud Platform Engineering') and Neovim's command line
-- does no quote handling of its own. Returns ({ field = value, ... }, nil) or (nil, reason).
function M.parse_scope_args(fargs)
  local fields, field = {}, nil
  for _, token in ipairs(fargs or {}) do
    local key, value = token:match('^([%a_]+)=(.*)$')
    if key and SCOPE_FIELDS[key] then
      field = key
      fields[field] = value
    elseif key then
      return nil, ('unknown scope field "%s" -- expected organization, project or repository'):format(key)
    elseif field then
      fields[field] = fields[field] .. ' ' .. token
    else
      return nil, ('expected field=value arguments, got "%s"'):format(token)
    end
  end
  if not next(fields) then
    return nil, 'expected at least one of organization=<url>, project=<name>, repository=<name>'
  end
  for name, value in pairs(fields) do
    if value == '' then
      return nil, ('%s was given an empty value'):format(name)
    end
  end
  return fields, nil
end

-- Pure. Fold the three sources of one scope field into its effective value, most-explicit-and-
-- most-recent first (docs/specs/per-directory-ado-config.md): an explicit setup() value beats a
-- session override, which beats the auto-detected value.
function M.effective_scope_value(explicit, override, detected)
  return explicit or override or detected
end

-- Session-only scope override (`:AdoPrSetScope`), for when auto-detection is wrong or
-- ambiguous. In memory for this Neovim session only -- deliberately kept out of `current` so
-- it never leaks through M.get() and can never be mistaken for an explicit setup() value,
-- which is what makes the setup()-wins half of the precedence order work.
local session_override = {}

-- Merge `fields` (as returned by M.parse_scope_args) into the session override. Only the
-- fields named are touched; nothing is persisted to disk.
function M.set_session_scope(fields)
  for field, value in pairs(fields) do
    session_override[field] = value
  end
end

-- `:AdoPrSetScope` entry point: parse, apply, and report. Adapter over the two pure functions
-- above -- it exists only to own the user-facing notify, the same split review.lua uses for its
-- own commands.
function M.set_scope(fargs)
  local fields, err = M.parse_scope_args(fargs)
  if not fields then
    vim.notify('ado-pr: ' .. err, vim.log.levels.ERROR)
    return
  end
  M.set_session_scope(fields)
  local parts = {}
  for _, field in ipairs({ 'organization', 'project', 'repository' }) do
    if fields[field] then
      table.insert(parts, field .. '=' .. fields[field])
    end
  end
  vim.notify('ado-pr: session scope override — ' .. table.concat(parts, ', '), vim.log.levels.INFO)
end

-- Resolve one scope field: an explicit setup() value or a session override is used as-is (no
-- detection attempted at all -- other fields being unset doesn't force a git shell-out to
-- resolve this one). Otherwise, auto-detect from the current cwd's git remotes and return that
-- field, or (nil, reason) when detection failed -- callers surface this as a `vim.notify` ERROR
-- and abort rather than falling through to a downstream `az` error (fail-loud convention).
local function resolve_field(field)
  local explicit, override = current[field], session_override[field]
  if explicit or override then
    return M.effective_scope_value(explicit, override, nil), nil
  end
  local triple, err = detect_for_cwd(vim.fn.getcwd())
  if not triple then
    return nil, ('could not auto-detect %s: %s -- set it explicitly via setup(), or for this session only via :AdoPrSetScope'):format(field, err)
  end
  return M.effective_scope_value(explicit, override, triple[field]), nil
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
