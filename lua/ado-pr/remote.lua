-- Auto-detect an ADO organization/project/repository from a repo's git remotes
-- (docs/specs/per-directory-ado-config.md). Two layers:
--   parse_url  pure -- one remote URL -> { organization, project, repository } | nil, reason
--   detect     pure -- a (name, url) remote list -> the same triple | nil, structured failure
-- `origin` is tried first; if it doesn't parse as ADO (or doesn't exist), every other remote
-- is scanned and exactly one match is required -- zero or multiple is a hard failure, never a
-- guess (spec: "the plugin does not guess between multiple candidates").
local M = {}

-- Lua patterns have no non-capturing group, so each form below is spelled out in full rather
-- than documented separately and translated. `host` is which host the pattern's captured org
-- resolves under, for reconstructing the full --organization URL `az` expects (config.lua's
-- `organization` field, e.g. 'https://dev.azure.com/HollardInsuranceRetail') -- paired with its
-- pattern in one table so the two can never drift out of index sync. Both SSH forms live under
-- dev.azure.com regardless of host used for the SSH transport itself.
local FORMS = {
  -- https://[org@]dev.azure.com/<org>/<project>/_git/<repo>[.git][/]
  { pattern = '^https://[^@/]*@?dev%.azure%.com/([^/]+)/([^/]+)/_git/([^/]+)$', host = 'dev.azure.com' },
  -- https://<org>.visualstudio.com/DefaultCollection/<project>/_git/<repo>[.git][/]
  { pattern = '^https://([^./@]+)%.visualstudio%.com/DefaultCollection/([^/]+)/_git/([^/]+)$', host = 'visualstudio.com' },
  -- https://<org>.visualstudio.com/<project>/_git/<repo>[.git][/]
  { pattern = '^https://([^./@]+)%.visualstudio%.com/([^/]+)/_git/([^/]+)$', host = 'visualstudio.com' },
  -- git@ssh.dev.azure.com:v3/<org>/<project>/<repo>
  { pattern = '^git@ssh%.dev%.azure%.com:v3/([^/]+)/([^/]+)/([^/]+)$', host = 'dev.azure.com' },
  -- <user>@vs-ssh.visualstudio.com:v3/<org>/<project>/<repo>
  { pattern = '^[^@]+@vs%-ssh%.visualstudio%.com:v3/([^/]+)/([^/]+)/([^/]+)$', host = 'dev.azure.com' },
}

local function strip_dot_git(s)
  return (s:gsub('%.git$', ''))
end

-- Pure. Parse one remote URL. Returns (organization_url, project, repository) on a match,
-- where organization_url is the full URL `az`'s --organization wants; or (nil, reason) when
-- the URL isn't one of the ADO-shaped forms above.
function M.parse_url(url)
  if type(url) ~= 'string' or url == '' then
    return nil, 'empty remote URL'
  end
  local trimmed = vim.trim(url):gsub('/+$', '')
  for _, form in ipairs(FORMS) do
    local org, project, repo = trimmed:match(form.pattern)
    if org then
      repo = vim.uri_decode(strip_dot_git(repo))
      project = vim.uri_decode(project)
      local org_url = form.host == 'dev.azure.com' and ('https://dev.azure.com/' .. org) or ('https://' .. org .. '.visualstudio.com')
      return org_url, project, repo
    end
  end
  return nil, 'not an ADO-shaped remote URL: ' .. trimmed
end

-- Pure. `remotes` is a list of { name, url }. Returns
-- ({ organization, project, repository }, nil) on exactly one match, or (nil, reason) on zero
-- or multiple ADO-shaped candidates. `origin` is tried first and, if it parses, wins outright
-- without considering other remotes at all (detection order per spec).
function M.detect(remotes)
  remotes = remotes or {}
  local origin
  local others = {}
  for _, r in ipairs(remotes) do
    if r.name == 'origin' then
      origin = r
    else
      table.insert(others, r)
    end
  end

  local tried = {}
  if origin then
    local org, project, repo = M.parse_url(origin.url)
    if org then
      return { organization = org, project = project, repository = repo }, nil
    end
    table.insert(tried, ('origin (%s): not ADO-shaped'):format(origin.url))
  end

  local matches = {}
  for _, r in ipairs(others) do
    local org, project, repo = M.parse_url(r.url)
    if org then
      table.insert(matches, { name = r.name, organization = org, project = project, repository = repo })
    else
      table.insert(tried, ('%s (%s): not ADO-shaped'):format(r.name, r.url))
    end
  end

  if #matches == 1 then
    local m = matches[1]
    return { organization = m.organization, project = m.project, repository = m.repository }, nil
  end

  if #matches > 1 then
    local names = {}
    for _, m in ipairs(matches) do
      table.insert(names, m.name)
    end
    return nil, 'ambiguous: multiple ADO-shaped remotes (' .. table.concat(names, ', ') .. ') -- refusing to guess'
  end

  if #tried == 0 then
    return nil, 'no git remotes configured'
  end
  return nil, 'no ADO-shaped remote found -- tried ' .. table.concat(tried, '; ')
end

-- Adapter: read this repo's remotes as { name, url } pairs, deduped (`git remote -v` prints
-- one line per remote per direction; only the first URL seen per name is kept). Thin,
-- smoke-tested only -- logic lives in parse_url/detect above.
function M.read_remotes(cwd)
  local res = vim.system({ 'git', 'remote', '-v' }, { text = true, cwd = cwd }):wait()
  if res.code ~= 0 then
    return nil, (res.stderr ~= '' and res.stderr or ('git remote -v exited ' .. res.code))
  end
  local seen, remotes = {}, {}
  for line in (res.stdout or ''):gmatch('[^\r\n]+') do
    local name, url = line:match('^(%S+)%s+(%S+)')
    if name and url and not seen[name] then
      seen[name] = true
      table.insert(remotes, { name = name, url = url })
    end
  end
  return remotes, nil
end

return M
