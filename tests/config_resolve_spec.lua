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
