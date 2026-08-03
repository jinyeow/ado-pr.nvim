-- PROTOTYPE FIXTURES — THROWAWAY.
--
-- Structure taken from a real PR (!21121, 21 threads) via prototypes/spike_read_path.lua;
-- authors and comment text are invented, so no work content lives in this repo. What is
-- preserved is everything that makes the UI hard:
--
--   * 16 of 21 threads are system-only noise  (RefUpdate x10, VoteUpdate x2,
--     AutoCompleteUpdate x2, PolicyStatusUpdate x1, ReviewersUpdate x1)
--   * all 5 human threads sit in ONE file — real reviews cluster, they don't spread
--   * threads run 2-4 comments deep, 15-400 characters each, with up to 3 participants
--   * spans: one 23-line thread (62-84) CONTAINS two others (77, 82-83). Overlapping
--     threads are the normal case, not an edge case.
--   * 3 of 5 carry tracking data when fetched with $iteration/$baseIteration, and flip
--     from rightFileStart to leftFileStart when they do
--
-- Anchored onto lua/ado-pr/az.lua (163 lines) so the line numbers land on real code.

local FILE = '/lua/ado-pr/az.lua'

local function comment(author, date, content)
  return { author = author, publishedDate = date, commentType = 'text', content = content }
end

local threads = {
  {
    id = 96940,
    status = 'fixed',
    threadContext = { filePath = FILE, rightFileStart = { line = 19, offset = 1 }, rightFileEnd = { line = 19, offset = 60 } },
    pullRequestThreadContext = {
      iterationContext = { firstComparingIteration = 1, secondComparingIteration = 1 },
      trackingCriteria = {
        firstComparingIteration = 1,
        secondComparingIteration = 2,
        origFilePath = FILE,
        origRightFileStart = { line = 19, offset = 1 },
        origRightFileEnd = { line = 19, offset = 60 },
      },
    },
    comments = {
      comment('Priya Raman', '2026-07-21', 'Is this comment still accurate?'),
      comment('Justin Puah', '2026-07-21', 'Yes — and it is load-bearing. libuv wraps batch files in cmd.exe itself and mangles the command line when an argument contains a space while az.cmd is also on a PATH containing spaces. Naming az.cmd directly is not enough, which is why the argv starts with cmd.exe.'),
      comment('Priya Raman', '2026-07-22', 'Understood, leaving it.'),
    },
  },
  {
    -- The wide one: spans 23 lines and swallows the two threads below it.
    id = 97122,
    status = 'active',
    threadContext = { filePath = FILE, rightFileStart = { line = 62, offset = 1 }, rightFileEnd = { line = 84, offset = 20 } },
    pullRequestThreadContext = { iterationContext = { firstComparingIteration = 2, secondComparingIteration = 2 } },
    comments = {
      comment('Mei Lin', '2026-07-27', 'This whole block repeats the same scope-args dance four times.'),
      comment('Justin Puah', '2026-07-27', 'It is three lines each and the argument order differs per verb. Factoring it out would need a table of verb shapes, which reads worse than the repetition does.'),
      comment('Dan Okonkwo', '2026-07-28', 'Agree with Justin, leave it.'),
      comment('Mei Lin', '2026-07-28', 'Fine — not blocking.'),
    },
  },
  {
    id = 96937,
    status = 'fixed',
    threadContext = { filePath = FILE, rightFileStart = { line = 77, offset = 1 }, rightFileEnd = { line = 77, offset = 40 } },
    pullRequestThreadContext = {
      iterationContext = { firstComparingIteration = 1, secondComparingIteration = 1 },
      trackingCriteria = {
        firstComparingIteration = 1,
        secondComparingIteration = 2,
        origFilePath = FILE,
        origRightFileStart = { line = 77, offset = 1 },
        origRightFileEnd = { line = 77, offset = 40 },
      },
    },
    comments = {
      comment('Priya Raman', '2026-07-23', 'list_prs hardcodes --status active. That is right for the picker, but this is the only list function we have, so anything wanting abandoned or completed PRs has to bypass it entirely.'),
      comment('Justin Puah', '2026-07-24', 'True. I would rather add a second function when something actually needs it than add a status parameter now that every caller has to think about. Leaving as is for the MVP.'),
      comment('Priya Raman', '2026-07-24', 'Works for me.'),
    },
  },
  {
    id = 96938,
    status = 'active',
    threadContext = { filePath = FILE, rightFileStart = { line = 82, offset = 1 }, rightFileEnd = { line = 83, offset = 30 } },
    pullRequestThreadContext = {
      iterationContext = { firstComparingIteration = 1, secondComparingIteration = 1 },
      trackingCriteria = {
        firstComparingIteration = 1,
        secondComparingIteration = 2,
        origFilePath = FILE,
        origRightFileStart = { line = 82, offset = 1 },
        origRightFileEnd = { line = 83, offset = 30 },
      },
    },
    comments = {
      comment('Dan Okonkwo', '2026-07-25', 'az_json swallows the distinction between "az failed" and "az succeeded but printed something that is not JSON". Both come back as a string error, so a caller cannot retry the first and give up on the second.'),
      comment('Justin Puah', '2026-07-26', 'Fair. The decode failure message does include the raw output so it is debuggable, but you are right that it is not machine-distinguishable. Worth a follow-up rather than a change here.'),
    },
  },
  {
    id = 97128,
    status = 'fixed',
    threadContext = { filePath = FILE, rightFileStart = { line = 109, offset = 1 }, rightFileEnd = { line = 109, offset = 45 } },
    pullRequestThreadContext = { iterationContext = { firstComparingIteration = 2, secondComparingIteration = 2 } },
    comments = {
      comment('Mei Lin', '2026-07-28', 'set_vote returns a bare boolean plus an error string, but every other function in this module returns (value, err). The asymmetry means callers have to remember which convention applies where, and the one place it is called already gets it slightly wrong by checking truthiness of the first return rather than comparing it explicitly. Worth making it consistent.'),
      comment('Justin Puah', '2026-07-29', 'Agreed, that is a real inconsistency. Changed it to return the vote payload so it matches the rest, and updated the caller. Good catch.'),
      comment('Mei Lin', '2026-07-29', 'Thanks — resolving.'),
    },
  },
}

-- 16 system threads: the noise a real PR buries the above in.
local SYSTEM_TYPES = {
  { type = 'RefUpdate', n = 10, text = 'The reference refs/heads/feature/psresource-feed was updated.' },
  { type = 'VoteUpdate', n = 2, text = 'Priya Raman voted 10' },
  { type = 'AutoCompleteUpdate', n = 2, text = 'Justin Puah set auto-complete' },
  { type = 'PolicyStatusUpdate', n = 1, text = 'Build succeeded' },
  { type = 'ReviewersUpdate', n = 1, text = 'Justin Puah added Mei Lin as a reviewer' },
}

local next_id = 96900
for _, spec in ipairs(SYSTEM_TYPES) do
  for _ = 1, spec.n do
    next_id = next_id + 1
    table.insert(threads, {
      id = next_id,
      status = 'closed',
      threadContext = nil,
      properties = { CodeReviewThreadType = spec.type },
      comments = {
        { author = 'Project Collection Service Accounts', publishedDate = '2026-07-30', commentType = 'system', content = spec.text },
      },
    })
  end
end

return {
  file = FILE,
  threads = threads,
  -- Iterations, as the real PR had (11). Labels invented.
  iterations = {
    { id = 1, label = 'Iteration 1 - initial push', when = '2026-07-20' },
    { id = 2, label = 'Iteration 2 - review feedback', when = '2026-07-23' },
    { id = 3, label = 'Iteration 3 - rebase onto main', when = '2026-07-26' },
    { id = 4, label = 'Iteration 4 - latest', when = '2026-07-29' },
  },
  -- Stand-in for `items?...includeContent=true` at an older iteration's commit.
  -- Real plugin fetches this from ADO; the prototype fakes it.
  original_content = {
    [FILE] = {
      [1] = table.concat({
        '-- Azure DevOps glue for ado-pr.nvim.',
        'local M = {}',
        '',
        "local config = require('ado-pr.config')",
        '',
        "local az_argv = { 'az' }  -- no cmd.exe wrapper yet",
        '',
        'local function az_json(args)',
        '  local res = vim.system(az_cmdline(args), { text = true }):wait()',
        '  if res.code ~= 0 then',
        "    return nil, 'az failed'",
        '  end',
        '  return vim.json.decode(res.stdout), nil',
        'end',
        '',
        'function M.list_prs()',
        "  local args = { 'repos', 'pr', 'list', '--output', 'json' }",
        '  return az_json(args)',
        'end',
        '',
        'return M',
      }, '\n'),
      [2] = table.concat({
        '-- Azure DevOps glue for ado-pr.nvim.',
        'local M = {}',
        '',
        "local config = require('ado-pr.config')",
        '',
        "-- On Windows the CLI entry point is `az.cmd`; libuv does no PATHEXT search.",
        "local az_argv = vim.fn.has('win32') == 1 and { 'az.cmd' } or { 'az' }",
        '',
        'local function az_json(args)',
        '  local res = vim.system(az_cmdline(args), { text = true }):wait()',
        '  if res.code ~= 0 then',
        "    return nil, (res.stderr ~= '' and res.stderr or 'az failed')",
        '  end',
        '  local ok, decoded = pcall(vim.json.decode, res.stdout)',
        '  if not ok then',
        "    return nil, 'failed to decode az output'",
        '  end',
        '  return decoded, nil',
        'end',
        '',
        'function M.list_prs()',
        "  local args = { 'repos', 'pr', 'list', '--status', 'active', '--output', 'json' }",
        '  vim.list_extend(args, scope_args())',
        '  return az_json(args)',
        'end',
        '',
        'return M',
      }, '\n'),
    },
  },
}
