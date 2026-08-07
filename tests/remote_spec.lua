-- Tests for ado-pr.remote -- pure URL parsing + detection-order (docs/specs/
-- per-directory-ado-config.md). Both PATTERNS-driven functions take no Neovim API beyond
-- vim.trim/vim.uri_decode, so these run against real inputs, no stubbing.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local remote = require('ado-pr.remote')

local failures, count = {}, 0
local function ok(cond, name, detail)
  count = count + 1
  if not cond then
    table.insert(failures, name .. (detail and ('  (' .. detail .. ')') or ''))
  end
end
local function eq(a, b, name)
  ok(vim.deep_equal(a, b), name, vim.inspect(a) .. ' ~= ' .. vim.inspect(b))
end

-- parse_url: HTTPS modern form.
do
  local org, project, repo = remote.parse_url('https://dev.azure.com/HollardInsuranceRetail/TSC%20Cloud%20Platform/_git/T2.ServiceCatalogue')
  eq(org, 'https://dev.azure.com/HollardInsuranceRetail', 'https modern: organization')
  eq(project, 'TSC Cloud Platform', 'https modern: project (decoded)')
  eq(repo, 'T2.ServiceCatalogue', 'https modern: repository')
end

-- parse_url: HTTPS modern form with the `<org>@` userinfo prefix ADO's own Clone button emits.
do
  local org, project, repo = remote.parse_url('https://HollardInsuranceRetail@dev.azure.com/HollardInsuranceRetail/MyProject/_git/MyRepo')
  eq(org, 'https://dev.azure.com/HollardInsuranceRetail', 'https userinfo: organization')
  eq(project, 'MyProject', 'https userinfo: project')
  eq(repo, 'MyRepo', 'https userinfo: repository')
end

-- parse_url: legacy visualstudio.com host, no DefaultCollection segment.
do
  local org, project, repo = remote.parse_url('https://myorg.visualstudio.com/MyProject/_git/MyRepo')
  eq(org, 'https://myorg.visualstudio.com', 'https legacy: organization')
  eq(project, 'MyProject', 'https legacy: project')
  eq(repo, 'MyRepo', 'https legacy: repository')
end

-- parse_url: legacy visualstudio.com host, WITH DefaultCollection segment.
do
  local org, project, repo = remote.parse_url('https://myorg.visualstudio.com/DefaultCollection/MyProject/_git/MyRepo')
  eq(org, 'https://myorg.visualstudio.com', 'https legacy DefaultCollection: organization')
  eq(project, 'MyProject', 'https legacy DefaultCollection: project')
  eq(repo, 'MyRepo', 'https legacy DefaultCollection: repository')
end

-- parse_url: SSH modern form.
do
  local org, project, repo = remote.parse_url('git@ssh.dev.azure.com:v3/HollardInsuranceRetail/MyProject/MyRepo')
  eq(org, 'https://dev.azure.com/HollardInsuranceRetail', 'ssh modern: organization')
  eq(project, 'MyProject', 'ssh modern: project')
  eq(repo, 'MyRepo', 'ssh modern: repository')
end

-- parse_url: legacy SSH host.
do
  local org, project, repo = remote.parse_url('myuser@vs-ssh.visualstudio.com:v3/myorg/MyProject/MyRepo')
  eq(org, 'https://dev.azure.com/myorg', 'ssh legacy: organization')
  eq(project, 'MyProject', 'ssh legacy: project')
  eq(repo, 'MyRepo', 'ssh legacy: repository')
end

-- parse_url: trailing slash (a valid clone-URL suffix) is tolerated.
do
  local org, project, repo = remote.parse_url('https://dev.azure.com/myorg/MyProject/_git/MyRepo/')
  eq(org, 'https://dev.azure.com/myorg', 'trailing slash: organization')
  eq(project, 'MyProject', 'trailing slash: project')
  eq(repo, 'MyRepo', 'trailing slash: repository')
end

-- parse_url: a URL-encoded repository name is decoded, same as project.
do
  local _org, _project, repo = remote.parse_url('https://dev.azure.com/myorg/MyProject/_git/My%20Repo')
  eq(repo, 'My Repo', 'encoded repository: decoded')
end

-- parse_url: trailing `.git` stripped from the repository.
do
  local org, project, repo = remote.parse_url('https://dev.azure.com/myorg/MyProject/_git/MyRepo.git')
  eq(org, 'https://dev.azure.com/myorg', 'trailing .git: organization')
  eq(repo, 'MyRepo', 'trailing .git: repository has .git stripped')
end

-- parse_url: non-ADO / malformed URLs return nil + a reason.
do
  local org, _project, _repo, reason
  org, reason = remote.parse_url('git@github.com:jinyeow/ado-pr.nvim.git')
  ok(org == nil and reason ~= nil, 'github remote: no match', tostring(reason))

  org, reason = remote.parse_url('not a url at all')
  ok(org == nil and reason ~= nil, 'garbage input: no match', tostring(reason))

  org, reason = remote.parse_url('')
  ok(org == nil and reason ~= nil, 'empty string: no match', tostring(reason))
end

-- detect: origin parses -- wins outright, other remotes never even considered.
do
  local result, err = remote.detect({
    { name = 'origin', url = 'https://dev.azure.com/myorg/MyProject/_git/MyRepo' },
    { name = 'fork', url = 'https://dev.azure.com/otherorg/OtherProject/_git/OtherRepo' },
  })
  ok(result ~= nil and err == nil, 'detect: origin match succeeds', tostring(err))
  eq(result, { organization = 'https://dev.azure.com/myorg', project = 'MyProject', repository = 'MyRepo' }, 'detect: origin result')
end

-- detect: origin doesn't parse, exactly one other remote does -- that one is used.
do
  local result, err = remote.detect({
    { name = 'origin', url = 'git@github.com:jinyeow/ado-pr.nvim.git' },
    { name = 'upstream', url = 'https://dev.azure.com/myorg/MyProject/_git/MyRepo' },
  })
  ok(result ~= nil and err == nil, 'detect: fallback to sole ADO remote succeeds', tostring(err))
  eq(result.organization, 'https://dev.azure.com/myorg', 'detect: fallback organization')
end

-- detect: no origin at all, exactly one ADO-shaped remote among others.
do
  local result, err = remote.detect({
    { name = 'upstream', url = 'https://dev.azure.com/myorg/MyProject/_git/MyRepo' },
  })
  ok(result ~= nil and err == nil, 'detect: no origin, single match succeeds', tostring(err))
end

-- detect: zero matches -- hard failure, reason names what was tried.
do
  local result, err = remote.detect({
    { name = 'origin', url = 'git@github.com:jinyeow/ado-pr.nvim.git' },
  })
  ok(result == nil and err ~= nil, 'detect: zero matches fails')
  ok(err:find('origin', 1, true) ~= nil, 'detect: zero-match reason names origin', tostring(err))
end

-- detect: multiple ADO-shaped remotes (origin not ADO-shaped) -- ambiguous, hard failure.
do
  local result, err = remote.detect({
    { name = 'origin', url = 'git@github.com:jinyeow/ado-pr.nvim.git' },
    { name = 'a', url = 'https://dev.azure.com/orga/ProjA/_git/RepoA' },
    { name = 'b', url = 'https://dev.azure.com/orgb/ProjB/_git/RepoB' },
  })
  ok(result == nil and err ~= nil, 'detect: multiple matches fails')
  ok(err:find('ambiguous', 1, true) ~= nil, 'detect: ambiguous reason says so', tostring(err))
end

-- detect: no remotes at all.
do
  local result, err = remote.detect({})
  ok(result == nil and err ~= nil, 'detect: no remotes fails', tostring(err))
end

-- read_remotes: thin adapter smoke test against this repo's REAL remotes (no stubbing --
-- this repo lives on GitHub, so it also proves detect() correctly reports a zero-match
-- failure end to end, not just from a hand-built fixture).
do
  local remotes, err = remote.read_remotes('.')
  ok(remotes ~= nil and err == nil, 'read_remotes: succeeds in this repo', tostring(err))
  local has_origin = false
  for _, r in ipairs(remotes or {}) do
    if r.name == 'origin' then
      has_origin = true
    end
  end
  ok(has_origin, 'read_remotes: origin present')

  local result, derr = remote.detect(remotes)
  ok(result == nil and derr ~= nil, 'read_remotes + detect: this repo (GitHub origin) fails detection', tostring(derr))
end

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do
    io.stderr:write('  - ' .. f .. '\n')
  end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
