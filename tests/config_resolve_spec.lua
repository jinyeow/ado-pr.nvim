-- Tests for ado-pr.config's resolve_organization/resolve_project/resolve_repository --
-- explicit setup() vs. auto-detected-from-git-remotes precedence, and per-cwd memoization
-- (docs/specs/per-directory-ado-config.md). Each case runs in its own real (scratch) cwd so
-- the detection cache -- keyed by vim.fn.getcwd() -- can't leak a stubbed result from one
-- case into the next; `vim.system` is stubbed throughout, so nothing actually shells out.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local config = require('ado-pr.config')

local failures, count = {}, 0
local function ok(cond, name, detail)
  count = count + 1
  if not cond then
    table.insert(failures, name .. (detail and ('  (' .. detail .. ')') or ''))
  end
end

-- The precedence-resolution function is pure -- all 8 combinations of (explicit setup() value,
-- session override, detected value), most-explicit-and-most-recent first (spec: `setup()`
-- explicit value > session override > auto-detection).
do
  local E, O, D = 'explicit', 'override', 'detected'
  ok(config.effective_scope_value(E, O, D) == E, 'precedence: explicit + override + detected -> explicit')
  ok(config.effective_scope_value(E, O, nil) == E, 'precedence: explicit + override -> explicit')
  ok(config.effective_scope_value(E, nil, D) == E, 'precedence: explicit + detected -> explicit')
  ok(config.effective_scope_value(E, nil, nil) == E, 'precedence: explicit only -> explicit')
  ok(config.effective_scope_value(nil, O, D) == O, 'precedence: override + detected -> override')
  ok(config.effective_scope_value(nil, O, nil) == O, 'precedence: override only -> override')
  ok(config.effective_scope_value(nil, nil, D) == D, 'precedence: detected only -> detected')
  ok(config.effective_scope_value(nil, nil, nil) == nil, 'precedence: nothing set -> nil')
end

-- The :AdoPrSetScope argument parser is pure. `field=value` tokens; a value runs until the next
-- recognised `field=` token, so a project name with spaces needs no quoting (Neovim's command
-- line strips none anyway).
do
  local fields, err = config.parse_scope_args({ 'organization=https://dev.azure.com/Org', 'project=TSC', 'Cloud', 'Platform', 'repository=Repo' })
  ok(err == nil, 'parse: multi-word value accepted', tostring(err))
  ok(fields and fields.organization == 'https://dev.azure.com/Org', 'parse: organization')
  ok(fields and fields.project == 'TSC Cloud Platform', 'parse: project keeps its spaces')
  ok(fields and fields.repository == 'Repo', 'parse: repository')

  local partial = config.parse_scope_args({ 'project=Only This' })
  ok(partial and partial.project == 'Only This' and partial.organization == nil, 'parse: only the fields given are returned')

  local none, nerr = config.parse_scope_args({})
  ok(none == nil and nerr ~= nil, 'parse: no arguments is an error')
  local bad, berr = config.parse_scope_args({ 'wat=1' })
  ok(bad == nil and berr ~= nil, 'parse: unknown field is an error', tostring(berr))
  local loose, lerr = config.parse_scope_args({ 'MyRepo' })
  ok(loose == nil and lerr ~= nil, 'parse: a value with no leading field= is an error')
  local blank, blerr = config.parse_scope_args({ 'project=' })
  ok(blank == nil and blerr ~= nil, 'parse: an empty value is an error')
end

local scratch_root = os.getenv('TEMP') and (os.getenv('TEMP') .. '/ado-pr-config-resolve-spec') or '/tmp/ado-pr-config-resolve-spec'
local function scratch_cwd(name)
  local dir = scratch_root .. '/' .. name
  vim.fn.mkdir(dir, 'p')
  return dir
end

local real_system = vim.system
local real_cwd = vim.fn.getcwd()
local function stub_git_remote(stdout, code)
  vim.system = function(cmd, _opts)
    return {
      wait = function()
        if cmd[1] == 'git' and cmd[2] == 'remote' then
          return { code = code or 0, stdout = stdout or '', stderr = code and code ~= 0 and 'boom' or '' }
        end
        error('unexpected vim.system call: ' .. vim.inspect(cmd))
      end,
    }
  end
end

-- Explicit setup() values are used as-is -- no `git remote -v` shell-out at all.
do
  vim.fn.chdir(scratch_cwd('explicit'))
  config.setup({ organization = 'https://dev.azure.com/ExplicitOrg', project = 'Explicit Project', repository = 'ExplicitRepo' })
  vim.system = function(cmd, _opts)
    error('vim.system should not run when every field is explicit: ' .. vim.inspect(cmd))
  end
  local org, oerr = config.resolve_organization()
  local project, perr = config.resolve_project()
  local repo, rerr = config.resolve_repository()
  ok(org == 'https://dev.azure.com/ExplicitOrg' and oerr == nil, 'explicit: organization used as-is')
  ok(project == 'Explicit Project' and perr == nil, 'explicit: project used as-is')
  ok(repo == 'ExplicitRepo' and rerr == nil, 'explicit: repository used as-is')
end

-- No explicit config: all three auto-detected from the sole ADO-shaped `origin` remote.
do
  vim.fn.chdir(scratch_cwd('detect_ok'))
  config.setup({})
  stub_git_remote(
    'origin\thttps://dev.azure.com/DetectedOrg/Detected%20Project/_git/DetectedRepo (fetch)\n'
      .. 'origin\thttps://dev.azure.com/DetectedOrg/Detected%20Project/_git/DetectedRepo (push)\n'
  )
  local org, oerr = config.resolve_organization()
  local project, perr = config.resolve_project()
  local repo, rerr = config.resolve_repository()
  ok(org == 'https://dev.azure.com/DetectedOrg' and oerr == nil, 'detect: organization from origin', tostring(oerr))
  ok(project == 'Detected Project' and perr == nil, 'detect: project from origin', tostring(perr))
  ok(repo == 'DetectedRepo' and rerr == nil, 'detect: repository from origin', tostring(rerr))
end

-- An explicit field wins over the detected triple; unset fields still come from detection.
do
  vim.fn.chdir(scratch_cwd('partial_explicit'))
  config.setup({ project = 'My Own Project' })
  stub_git_remote('origin\thttps://dev.azure.com/DetectedOrg/Detected%20Project/_git/DetectedRepo (fetch)\n')
  local org, oerr = config.resolve_organization()
  local project, perr = config.resolve_project()
  local repo, rerr = config.resolve_repository()
  ok(org == 'https://dev.azure.com/DetectedOrg' and oerr == nil, 'partial: organization still auto-detected')
  ok(project == 'My Own Project' and perr == nil, 'partial: explicit project wins over detected')
  ok(repo == 'DetectedRepo' and rerr == nil, 'partial: repository still auto-detected')
end

-- Detection failure (no ADO-shaped remote): (nil, reason), never a guess.
do
  vim.fn.chdir(scratch_cwd('detect_fail'))
  config.setup({})
  stub_git_remote('origin\tgit@github.com:jinyeow/ado-pr.nvim.git (fetch)\n')
  local org, oerr = config.resolve_organization()
  ok(org == nil and oerr ~= nil, 'detect fail: organization unresolved', tostring(oerr))
  local project, perr = config.resolve_project()
  ok(project == nil and perr ~= nil, 'detect fail: project unresolved', tostring(perr))
end

-- Detection result (success or failure) is memoized per cwd: a second resolve call for a
-- field that was already detected must NOT shell out to `git remote -v` again.
do
  vim.fn.chdir(scratch_cwd('cache'))
  config.setup({})
  local git_remote_calls = 0
  vim.system = function(cmd, _opts)
    return {
      wait = function()
        if cmd[1] == 'git' and cmd[2] == 'remote' then
          git_remote_calls = git_remote_calls + 1
          return { code = 0, stdout = 'origin\thttps://dev.azure.com/CachedOrg/CachedProject/_git/CachedRepo (fetch)\n', stderr = '' }
        end
        error('unexpected vim.system call: ' .. vim.inspect(cmd))
      end,
    }
  end
  local org1 = config.resolve_organization()
  config.resolve_project()
  config.resolve_repository()
  ok(git_remote_calls == 1, 'cache: one `git remote -v` shell-out for the whole triple', tostring(git_remote_calls))
  local org2 = config.resolve_organization()
  ok(org1 == org2 and git_remote_calls == 1, 'cache: a second resolve for an already-detected cwd reuses the cache')
end

-- Session override (:AdoPrSetScope). Kept LAST in this file deliberately: unlike the detection
-- cache it is session-global with no cwd escape hatch, so setting it earlier would leak into
-- every later detection case.
do
  vim.fn.chdir(scratch_cwd('override'))
  config.setup({})
  vim.system = function(cmd, _opts)
    error('vim.system should not run when a session override covers every field: ' .. vim.inspect(cmd))
  end
  config.set_session_scope({ organization = 'https://dev.azure.com/OverrideOrg', project = 'Override Project', repository = 'OverrideRepo' })
  local org, oerr = config.resolve_organization()
  local project, perr = config.resolve_project()
  local repo, rerr = config.resolve_repository()
  ok(org == 'https://dev.azure.com/OverrideOrg' and oerr == nil, 'override: organization beats detection', tostring(oerr))
  ok(project == 'Override Project' and perr == nil, 'override: project beats detection')
  ok(repo == 'OverrideRepo' and rerr == nil, 'override: repository beats detection')

  -- A later call updates only the fields it names -- the rest of the override stands.
  config.set_session_scope({ repository = 'SecondRepo' })
  ok(config.resolve_repository() == 'SecondRepo', 'override: a later call replaces that field')
  ok(config.resolve_project() == 'Override Project', 'override: fields not named by a later call are kept')

  -- An explicit setup() value for a field is never overridden by the session command.
  config.setup({ project = 'Explicit Project' })
  ok(config.resolve_project() == 'Explicit Project', 'override: explicit setup() project still wins')
  ok(config.resolve_repository() == 'SecondRepo', 'override: unset setup() fields still come from the override')

  -- The override is in memory only -- it never reaches the setup() config table.
  ok(config.get().repository == nil, 'override: not written into the setup() config table')
end

vim.system = real_system
vim.fn.chdir(real_cwd)

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do
    io.stderr:write('  - ' .. f .. '\n')
  end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
