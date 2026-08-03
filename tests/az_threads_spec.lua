-- Tests for ado-pr.az.list_threads / list_threads_tracked -- the two thread-fetch
-- functions over the shared decoder. Per the ticket's acceptance criteria, these
-- assert on the DECODED RETURN VALUE, not on which `az` arguments were built or
-- whether `vim.system` was invoked with particular flags -- the behaviour is visible
-- in the return. (tests/post_thread_spec.lua asserts on argv/body because that is
-- the ONLY observable surface for a POST with no meaningful return; a GET's meaningful
-- surface is its decoded body, so that is what these check.)
--
-- Both functions go through the SAME `az_json` / `az devops invoke` transport
-- `post_thread` already uses -- no new token, no stored secret, no different `az`
-- entry point. That is a code fact (see lua/ado-pr/az.lua), not something re-proven
-- by stubbing argv here.
--
-- Envelope shape (`{ count, value = { ...threads... } }`) is the shape
-- `az devops invoke` returns for a list resource, proven live at
-- prototypes/spike_read_path.lua:209 (`res.json.count or #res.json.value`).
-- prototypes/spike_*.json themselves are gitignored and were never committed to this
-- worktree, so the envelope could not be read directly while writing this spec.
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
local function eq(a, b, name)
  ok(vim.deep_equal(a, b), name, vim.inspect(a) .. ' ~= ' .. vim.inspect(b))
end

local real_system = vim.system
local function stub_response(body_json)
  vim.system = function(_cmd, _opts)
    return {
      wait = function()
        return {
          code = 0,
          stdout = 'Please wait a couple of seconds while we fetch all required information.\n' .. vim.json.encode(body_json),
          stderr = '',
        }
      end,
    }
  end
end

local ctx = { id = 21121, repositoryId = 'repo-guid', project = 'My Project' }

-- Plain fetch: decodes the `value` array, no trackingCriteria on any thread.
do
  stub_response({
    count = 2,
    value = {
      { id = 1, threadContext = { filePath = '/a.lua', rightFileStart = { line = 1 } }, comments = {} },
      { id = 2, threadContext = nil, comments = {} },
    },
  })
  local decoded, err = az.list_threads(ctx)
  ok(decoded and not err, 'list_threads: no error', err)
  eq(decoded, {
    { id = 1, threadContext = { filePath = '/a.lua', rightFileStart = { line = 1 } }, comments = {} },
    { id = 2, threadContext = nil, comments = {} },
  }, 'list_threads: decoded array')
end

-- Tracked fetch: decodes the `value` array; threads may carry trackingCriteria.
do
  stub_response({
    count = 1,
    value = {
      {
        id = 3,
        threadContext = { filePath = '/a.lua', leftFileStart = { line = 1 } },
        pullRequestThreadContext = { trackingCriteria = { origFilePath = '/a.lua', origRightFileStart = { line = 1 } } },
        comments = {},
      },
    },
  })
  local decoded, err = az.list_threads_tracked(ctx, 2, 1)
  ok(decoded and not err, 'list_threads_tracked: no error', err)
  eq(decoded, {
    {
      id = 3,
      threadContext = { filePath = '/a.lua', leftFileStart = { line = 1 } },
      pullRequestThreadContext = { trackingCriteria = { origFilePath = '/a.lua', origRightFileStart = { line = 1 } } },
      comments = {},
    },
  }, 'list_threads_tracked: decoded array')
end

-- az failure propagates as (nil, err), same convention as every other az.lua function.
do
  vim.system = function(_cmd, _opts)
    return {
      wait = function()
        return { code = 1, stdout = '', stderr = 'boom' }
      end,
    }
  end
  local decoded, err = az.list_threads(ctx)
  ok(decoded == nil and err == 'boom', 'list_threads: az failure propagates', tostring(err))
end

vim.system = real_system

if #failures > 0 then
  io.stderr:write(('FAIL %d/%d\n'):format(#failures, count))
  for _, f in ipairs(failures) do io.stderr:write('  - ' .. f .. '\n') end
  os.exit(1)
end
io.write(('ok  %d assertions\n'):format(count))
os.exit(0)
