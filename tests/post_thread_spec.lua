-- Request-shape tests for ado-pr.az.post_thread. The live POST cannot run
-- without a real PR, so this stubs `vim.system` to capture the argv and the
-- `--in-file` body, pinning the threadContext shape (mirrored from cobalt's
-- tested client) and the `az devops invoke` route parameters.
-- Run headless: `nvim --headless -l tests/post_thread_spec.lua`.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local config = require('ado-pr.config')
local az = require('ado-pr.az')

config.setup({ organization = 'https://dev.azure.com/Org', api_version = '7.1' })

local failures, count = {}, 0
local function ok(cond, name, detail)
  count = count + 1
  if not cond then
    table.insert(failures, name .. (detail and ('  (' .. detail .. ')') or ''))
  end
end

-- Capture the last az invocation and the JSON body it pointed `--in-file` at.
local captured
local real_system = vim.system
vim.system = function(cmd, _opts)
  local argv = {}
  for _, v in ipairs(cmd) do
    table.insert(argv, v)
  end
  local in_file
  for i, v in ipairs(argv) do
    if v == '--in-file' then
      in_file = argv[i + 1]
    end
  end
  local body
  if in_file then
    local f = io.open(in_file, 'r')
    body = f:read('*a')
    f:close()
  end
  captured = { argv = argv, body = vim.json.decode(body) }
  return {
    wait = function()
      -- `az devops invoke` prepends this human preamble to *stdout* before the
      -- JSON (unlike `az repos ...`), so az_json must tolerate leading noise.
      return {
        code = 0,
        stdout = 'Please wait a couple of seconds while we fetch all required information.\n{"id": 4242}',
        stderr = '',
      }
    end,
  }
end

local function arg_after(flag)
  for i, v in ipairs(captured.argv) do
    if v == flag then
      return captured.argv[i + 1]
    end
  end
end
local function has_arg(val)
  for _, v in ipairs(captured.argv) do
    if v == val then
      return true
    end
  end
  return false
end

-- Right-side comment: rightFile* set, leftFile* absent.
do
  local ctx = { id = 77, repositoryId = 'repo-guid', project = 'My Project' }
  local anchor = { filePath = '/src/foo.lua', line = 12, side = 'right' }
  local thread_id, err = az.post_thread(ctx, anchor, 'looks good')
  ok(thread_id == 4242 and not err, 'right: returns thread id', tostring(err or thread_id))

  ok(has_arg('devops') and has_arg('invoke'), 'right: az devops invoke')
  ok(arg_after('--resource') == 'pullRequestThreads', 'right: resource', arg_after('--resource'))
  ok(arg_after('--area') == 'git', 'right: area')
  ok(arg_after('--http-method') == 'POST', 'right: method')
  ok(arg_after('--api-version') == '7.1', 'right: api-version')
  ok(has_arg('project=My Project'), 'right: project route param')
  ok(has_arg('repositoryId=repo-guid'), 'right: repositoryId route param')
  ok(has_arg('pullRequestId=77'), 'right: pullRequestId route param')
  ok(has_arg('--organization') and has_arg('https://dev.azure.com/Org'), 'right: --organization only')
  ok(not has_arg('--project'), 'right: no --project flag (goes via route)')

  local tc = captured.body.threadContext
  ok(captured.body.status == 1, 'right: status active')
  ok(captured.body.comments[1].content == 'looks good', 'right: content')
  ok(captured.body.comments[1].commentType == 1, 'right: commentType text')
  ok(tc.filePath == '/src/foo.lua', 'right: filePath')
  ok(tc.rightFileStart.line == 12 and tc.rightFileStart.offset == 1, 'right: rightFileStart')
  ok(tc.rightFileEnd.line == 12, 'right: rightFileEnd')
  ok(tc.leftFileStart == nil and tc.leftFileEnd == nil, 'right: no leftFile*')
end

-- Left-side comment: leftFile* set, rightFile* absent.
do
  local ctx = { id = 5, repositoryId = 'g', project = 'P' }
  local anchor = { filePath = '/a.lua', line = 3, side = 'left' }
  az.post_thread(ctx, anchor, 'why removed?')
  local tc = captured.body.threadContext
  ok(tc.leftFileStart.line == 3 and tc.leftFileStart.offset == 1, 'left: leftFileStart')
  ok(tc.leftFileEnd.line == 3, 'left: leftFileEnd')
  ok(tc.rightFileStart == nil and tc.rightFileEnd == nil, 'left: no rightFile*')
end

vim.system = real_system

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do
    io.stderr:write('  - ' .. f .. '\n')
  end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
