-- Tests for ado-pr.az.list_iterations -- enumerates a PR's iterations (the pushes that
-- created it), same `az devops invoke` / `{ count, value }` envelope transport as
-- list_threads (see tests/az_threads_spec.lua's header for why these assert on the
-- DECODED RETURN VALUE rather than argv).
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

-- Decodes the `value` array of iterations.
do
  stub_response({
    count = 2,
    value = {
      {
        id = 1,
        description = 'initial push',
        author = { displayName = 'Justin Puah' },
        createdDate = '2026-07-20T10:00:00Z',
        sourceRefCommit = { commitId = 'aaa111' },
        targetRefCommit = { commitId = 'base000' },
      },
      {
        id = 2,
        description = 'review feedback',
        author = { displayName = 'Priya Raman' },
        createdDate = '2026-07-23T10:00:00Z',
        sourceRefCommit = { commitId = 'bbb222' },
        targetRefCommit = { commitId = 'base000' },
      },
    },
  })
  local decoded, err = az.list_iterations(ctx)
  ok(decoded and not err, 'list_iterations: no error', err)
  eq(#decoded, 2, 'list_iterations: decoded array length')
  eq(decoded[2].sourceRefCommit.commitId, 'bbb222', 'list_iterations: decoded fields readable')
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
  local decoded, err = az.list_iterations(ctx)
  ok(decoded == nil and err == 'boom', 'list_iterations: az failure propagates', tostring(err))
end

-- A genuinely empty result (count = 0, value = {}) is a valid response, not malformed.
do
  stub_response({ count = 0, value = {} })
  local decoded, err = az.list_iterations(ctx)
  ok(decoded and not err, 'list_iterations: empty value decodes without error', err)
  eq(decoded, {}, 'list_iterations: empty value decodes to {}')
end

-- Malformed response: missing `value` field entirely must raise, not silently default.
do
  stub_response({ count = 0 })
  local decoded, err = az.list_iterations(ctx)
  ok(decoded == nil and err ~= nil, 'list_iterations: missing value field errors', tostring(err))
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
