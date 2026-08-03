-- SPIKE — THROWAWAY. Answers the questions the thread-reading plan is gated on.
--
-- Runs every probe through the SAME transport the plugin uses: vim.system spawning
-- `cmd.exe /d /c az.cmd` (see lua/ado-pr/az.lua:22). Running these from PowerShell would
-- prove the REST API works while proving nothing about argument quoting through cmd.exe —
-- which is the part that has already broken once.
--
-- RUN (from the repo root):
--   nvim --headless -l prototypes/spike_read_path.lua <pr-id>
--   nvim --headless -l prototypes/spike_read_path.lua <pr-id> <organization> <project>
--
-- Organization/project are read from your `az devops configure --defaults` when omitted.
-- Writes each raw response next to this file as spike_<probe>.json for inspection.

local pr_id = arg[1]
local org_arg, project_arg = arg[2], arg[3]

if not pr_id then
  io.stderr:write('usage: nvim --headless -l prototypes/spike_read_path.lua <pr-id> [org] [project]\n')
  vim.cmd('cquit 2')
end

local AZ = vim.fn.has('win32') == 1 and { 'cmd.exe', '/d', '/c', 'az.cmd' } or { 'az' }

local function run(args)
  local cmdline = vim.list_extend(vim.deepcopy(AZ), args)
  local res = vim.system(cmdline, { text = true }):wait()
  local out = res.stdout or ''
  local start = out:find('[%[{]') -- az devops invoke prints a "Please wait" preamble
  local body = start and out:sub(start) or out
  local ok, decoded = pcall(vim.json.decode, body)
  return {
    code = res.code,
    stderr = (res.stderr or ''):gsub('%s+$', ''),
    raw = body,
    json = ok and decoded or nil,
  }
end

-- ---------------------------------------------------------------------------
-- Context: org / project / repository GUID
-- ---------------------------------------------------------------------------

local org, project = org_arg, project_arg

-- Order: explicit arg, environment, `az devops configure --defaults`, the git remote of the
-- current worktree (works when run from a checkout of the ADO repo itself).
if not org then
  org = vim.env.ADO_ORG
end
if not org then
  local cfg = run({ 'devops', 'configure', '--list' })
  org = cfg.raw:match('organization%s*=%s*(%S+)')
end
if not org then
  local remote = vim.system({ 'git', 'remote', 'get-url', 'origin' }, { text = true }):wait()
  local url = (remote.stdout or ''):gsub('%s+$', '')
  -- https://org@dev.azure.com/org/Project/_git/Repo  |  https://org.visualstudio.com/Project/_git/Repo
  org = url:match('(https://dev%.azure%.com/[^/]+)') or url:match('(https://[^/@]+%.visualstudio%.com)')
  if org then
    org = org:gsub('^https://[^@]*@', 'https://')
  end
end
project = project or vim.env.ADO_PROJECT

if not org then
  print('No organization found. Pass it explicitly:')
  print('  nvim --headless -l prototypes/spike_read_path.lua <pr-id> https://dev.azure.com/YourOrg "Your Project"')
  print('or set a default once:')
  print('  az devops configure --defaults organization=https://dev.azure.com/YourOrg')
  print('or run this from a worktree of the ADO repo, where the git remote gives it away.')
  vim.cmd('cquit 2')
end

local show_args = { 'repos', 'pr', 'show', '--id', tostring(pr_id), '--output', 'json' }
if org then
  vim.list_extend(show_args, { '--organization', org })
end
local pr = run(show_args)
if not pr.json then
  print('FATAL: could not read PR ' .. pr_id)
  print('  exit ' .. pr.code .. '  ' .. pr.stderr)
  vim.cmd('cquit 1')
end

local repo = pr.json.repository or {}
local repo_id = repo.id
project = project_arg or (repo.project and repo.project.name)
org = org or (repo.project and repo.project.url and repo.project.url:match('^(https?://[^/]+/[^/]+)'))

local head_sha = pr.json.lastMergeSourceCommit and pr.json.lastMergeSourceCommit.commitId

print(('context: org=%s project=%s repositoryId=%s pr=%s'):format(
  tostring(org), tostring(project), tostring(repo_id), tostring(pr_id)))
print('')

local function route()
  return {
    'project=' .. project,
    'repositoryId=' .. repo_id,
    'pullRequestId=' .. tostring(pr_id),
  }
end

local function invoke(resource, opts)
  local args = { 'devops', 'invoke', '--area', 'git', '--resource', resource, '--http-method', 'GET' }
  vim.list_extend(args, { '--route-parameters' })
  vim.list_extend(args, opts.route or route())
  if opts.query then
    vim.list_extend(args, { '--query-parameters' })
    vim.list_extend(args, opts.query)
  end
  vim.list_extend(args, { '--api-version', opts.api, '--output', 'json' })
  if org then
    vim.list_extend(args, { '--organization', org })
  end
  return run(args)
end

-- ---------------------------------------------------------------------------
-- Probes
-- ---------------------------------------------------------------------------

local probes = {
  {
    name = 'threads-7.1',
    why = 'does GET work through `az devops invoke` at all, on the version config.lua pins?',
    fn = function()
      return invoke('pullRequestThreads', { api = '7.1' })
    end,
  },
  {
    -- `7.2-preview.1` is rejected by the az devops extension itself, not the service:
    -- it strips "-preview" and float()s the rest, so "7.2.1" blows up. One-dot preview
    -- versions like "7.2-preview" are what its own --help examples use.
    name = 'threads-7.2-preview',
    why = 'does the extension accept a one-dot preview version?',
    fn = function()
      return invoke('pullRequestThreads', { api = '7.2-preview' })
    end,
  },
  {
    name = 'threads-iteration-tracking',
    why = 'THE DISCRIMINATING PROBE: do $-prefixed query params survive cmd.exe quoting?',
    fn = function()
      return invoke('pullRequestThreads', {
        api = '7.1', -- the version already proven to work, so this isolates the quoting
        query = { '$iteration=2', '$baseIteration=1' },
      })
    end,
  },
  {
    name = 'iterations',
    why = 'can we enumerate iterations for the Updates-style stepper?',
    fn = function()
      return invoke('pullRequestIterations', { api = '7.1' })
    end,
  },
  {
    name = 'item-content-at-commit',
    why = 'can we fetch a file at an arbitrary commit (the original-diff content source)?',
    fn = function()
      if not head_sha then
        return { code = -1, stderr = 'no lastMergeSourceCommit on the PR payload', raw = '' }
      end
      -- Pick any file the PR touched so the path is guaranteed to exist at that commit.
      local changes = invoke('pullRequestIterationChanges', {
        api = '7.1',
        route = vim.list_extend(route(), { 'iterationId=1' }),
      })
      local path
      if changes.json and changes.json.changeEntries then
        for _, c in ipairs(changes.json.changeEntries) do
          if c.item and c.item.path and not c.item.isFolder then
            path = c.item.path
            break
          end
        end
      end
      if not path then
        return { code = -1, stderr = 'could not find a changed file path in iteration 1', raw = changes.raw }
      end
      print('    (using path ' .. path .. ' at ' .. head_sha:sub(1, 8) .. ')')
      return invoke('items', {
        api = '7.1',
        route = { 'project=' .. project, 'repositoryId=' .. repo_id },
        -- No `$format=text` here: that returns raw text, and `az devops invoke` refuses a
        -- non-JSON response unless given --out-file. includeContent=true alone returns the
        -- item as JSON with the file body in `.content`, which is what we want anyway.
        query = {
          'path=' .. path,
          'versionDescriptor.version=' .. head_sha,
          'versionDescriptor.versionType=commit',
          'includeContent=true',
        },
      })
    end,
  },
}

local results = {}
for _, p in ipairs(probes) do
  -- ASCII only: this runs in the Windows console, where box-drawing characters mojibake.
  print(('> %s -- %s'):format(p.name, p.why))
  local res = p.fn()
  local pass = res.code == 0
  results[#results + 1] = { name = p.name, pass = pass, code = res.code, stderr = res.stderr }
  if pass then
    local count = res.json and (res.json.count or (res.json.value and #res.json.value)) or nil
    print(('    PASS  exit 0%s'):format(count and ('  -  %d items'):format(count) or ''))
    local f = io.open('prototypes/spike_' .. p.name .. '.json', 'w')
    if f then
      f:write(res.raw)
      f:close()
    end
  else
    print(('    FAIL  exit %s'):format(tostring(res.code)))
    print('          ' .. (res.stderr ~= '' and res.stderr or '(no stderr)'):gsub('\n', '\n          '))
  end
  print('')
end

print('-- summary --')
for _, r in ipairs(results) do
  print(('%-32s %s'):format(r.name, r.pass and 'PASS' or ('FAIL (exit ' .. tostring(r.code) .. ')')))
end
print('')
print('Raw responses written to prototypes/spike_<probe>.json for the passing probes.')
