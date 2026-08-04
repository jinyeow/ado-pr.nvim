-- Pure-logic tests for ado-pr.view.format_thread -- the follower pane's display
-- lines. Run headless: `nvim --headless -l tests/view_spec.lua`.
-- No test framework: a tiny assert harness (plenary is not a dependency), same
-- shape as tests/threads_spec.lua.
--
-- The window/buffer management in view.lua (open/close/refresh/jump) is untested
-- adapter code over diffview internals and Neovim's window API, same split as
-- signs.lua -- see docs/specs/pr-comment-threads.md "What is not unit-tested".
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

local view = require('ado-pr.view')

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

local function comment(name, date, content)
  return { author = { displayName = name }, publishedDate = date, content = content }
end

-- One comment, no overlap: header carries id and status, no "N of M" suffix.
do
  local t = {
    id = 96940,
    status = 'active',
    comments = { comment('Priya Raman', '2026-07-21', 'Is this comment still accurate?') },
  }
  local lines = view.format_thread(t)
  eq(lines, {
    'Thread #96940  [active]',
    '',
    'Priya Raman  ·  2026-07-21',
    'Is this comment still accurate?',
  }, 'single comment: header, author/date, content')
end

-- Several comments: each gets its own author/date line, separated by a blank line.
do
  local t = {
    id = 96940,
    status = 'fixed',
    comments = {
      comment('Priya Raman', '2026-07-21', 'Is this comment still accurate?'),
      comment('Justin Puah', '2026-07-21', 'Yes.'),
    },
  }
  local lines = view.format_thread(t)
  eq(lines, {
    'Thread #96940  [fixed]',
    '',
    'Priya Raman  ·  2026-07-21',
    'Is this comment still accurate?',
    '',
    'Justin Puah  ·  2026-07-21',
    'Yes.',
  }, 'multiple comments: separated by a blank line')
end

-- position with total > 1: the header states which of how many -- a hidden
-- overlapping thread must never be silent.
do
  local t = { id = 96937, status = 'fixed', comments = { comment('Priya Raman', '2026-07-23', 'nit') } }
  local lines = view.format_thread(t, { index = 1, total = 2 })
  ok(lines[1] == 'Thread #96937  [fixed]   (1 of 2 here)', 'overlap: header states position', lines[1])
end

-- position with total == 1: no "N of M" suffix -- nothing hidden, nothing to say.
do
  local t = { id = 96937, status = 'fixed', comments = { comment('Priya Raman', '2026-07-23', 'nit') } }
  local lines = view.format_thread(t, { index = 1, total = 1 })
  ok(lines[1] == 'Thread #96937  [fixed]', 'no overlap: no position suffix', lines[1])
end

-- A long comment wraps rather than running off the pane's width.
do
  local long = ('word '):rep(30):sub(1, -2) -- 149 chars, well past the 76-char wrap width
  local t = { id = 1, status = 'active', comments = { comment('A', '2026-01-01', long) } }
  local lines = view.format_thread(t)
  ok(#lines > 4, 'long comment: wraps across more than one line', tostring(#lines))
  for i = 3, #lines do
    ok(#lines[i] <= 76, ('long comment: wrapped line %d stays within width'):format(i), tostring(#lines[i]))
  end
end

-- Real comment text carries multi-byte characters (fixtures_threads.lua's em
-- dashes and smart quotes). Wrapping must cut on character boundaries, not byte
-- offsets, or a cut mid-character corrupts the text.
do
  local long = ('word — “word” '):rep(12) -- multi-byte chars throughout, past the wrap width
  local t = { id = 1, status = 'active', comments = { comment('A', '2026-01-01', long) } }
  local lines = view.format_thread(t)
  local body = {}
  for i = 4, #lines do -- lines: header, blank, author/date, then the wrapped content
    table.insert(body, lines[i])
  end
  ok(#body > 1, 'multi-byte comment: wraps across more than one line', tostring(#body))
  for i, l in ipairs(body) do
    ok(vim.fn.strchars(l) <= 76, ('multi-byte comment: wrapped line %d stays within char width'):format(i), tostring(vim.fn.strchars(l)))
  end
  local recombined = table.concat(body, ' '):gsub('%s+', ' '):gsub('%s+$', '')
  local original = long:gsub('%s+', ' '):gsub('%s+$', '')
  ok(recombined == original, 'multi-byte comment: wrapped text round-trips with no corruption', recombined .. ' ~= ' .. original)
end

-- Empty-state lines are a fixed, recognisable placeholder -- "shows nothing
-- intrusive when the cursor is on no thread".
do
  eq(view.EMPTY_LINES, { '(no thread on this line)' }, 'EMPTY_LINES: placeholder text')
end

-- ---------------------------------------------------------------------------
-- open/close must not disturb other windows' scroll position -- the one
-- acceptance criterion in the pane's window management that IS mechanically
-- checkable without diffview: open/close resize every other window in the
-- tabpage, and Neovim moves topline to keep each cursor visible when a window
-- gets short. Without the snapshot/restore in view.lua this stays disturbed
-- after close, not just during -- exactly what this test catches.
-- ---------------------------------------------------------------------------
do
  local lines = {}
  for i = 1, 500 do
    lines[i] = 'line ' .. i
  end
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.cmd('vsplit')
  local wins = vim.api.nvim_tabpage_list_wins(0)
  for _, w in ipairs(wins) do
    vim.api.nvim_win_call(w, function()
      vim.cmd('normal! 300Gzz')
    end)
  end
  local before = {}
  for _, w in ipairs(wins) do
    before[w] = vim.api.nvim_win_call(w, vim.fn.winsaveview)
  end

  view.open()
  view.close()

  for _, w in ipairs(wins) do
    local after = vim.api.nvim_win_call(w, vim.fn.winsaveview)
    eq(
      { topline = after.topline, lnum = after.lnum },
      { topline = before[w].topline, lnum = before[w].lnum },
      ('open+close: window %d scroll position unchanged'):format(w)
    )
  end

  -- Clean up the extra split so it doesn't affect anything run after this block.
  vim.cmd('only')
end

-- ---------------------------------------------------------------------------
-- Two concurrent Diffview sessions (one per tabpage) must not clobber each
-- other's pane (issue #27): pane state used to be a single process-global
-- table, so a second tab's session rewrote or closed the first's pane, and
-- `M.attach()` cleared one shared augroup on every call, orphaning any prior
-- session. Panes are now keyed by tabpage -- Diffview opens every view in its
-- own new tab (`tab split` in diffview's `View:open()`), so the tabpage is
-- each session's stable, natural key. This is real tabpage/window/augroup
-- state, not a diffview mock -- same "no seam worth mocking" limit as the
-- rest of this adapter, exercised directly instead.
-- ---------------------------------------------------------------------------
do
  local tab1 = vim.api.nvim_get_current_tabpage()
  view.attach()
  ok(view.is_open(tab1), 'session 1: pane open in its own tab')
  ok(pcall(vim.api.nvim_get_autocmds, { group = 'AdoPrThreadView' .. tostring(tab1) }), 'session 1: augroup exists')

  vim.cmd('tabnew')
  local tab2 = vim.api.nvim_get_current_tabpage()
  view.attach()
  ok(tab1 ~= tab2, 'sessions: distinct tabpages')
  ok(view.is_open(tab2), 'session 2: pane open in its own tab')
  ok(view.is_open(tab1), 'session 2 attach: session 1 pane still open (not orphaned)')
  ok(
    pcall(vim.api.nvim_get_autocmds, { group = 'AdoPrThreadView' .. tostring(tab1) }),
    'session 2 attach: session 1 augroup still exists (not cleared by session 2)'
  )

  -- A cursor move inside session 2's tab must never rewrite or close session
  -- 1's pane.
  vim.cmd('normal! j')
  ok(view.is_open(tab1), 'cursor move in tab 2: session 1 pane untouched')
  ok(view.is_open(tab2), 'cursor move in tab 2: session 2 pane untouched')

  -- Register each session's per-file cursor-follower autocmds (normally done
  -- on DiffviewDiffBufWinEnter/DiffviewViewOpened) so the teardown check
  -- below observes a real augroup, not one that was never created.
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewOpened', modeline = false })
  vim.wait(20)
  ok(pcall(vim.api.nvim_get_autocmds, { group = 'AdoPrThreadViewCursor' .. tostring(tab1) }), 'DiffviewViewOpened: session 1 cursor augroup created')
  ok(pcall(vim.api.nvim_get_autocmds, { group = 'AdoPrThreadViewCursor' .. tostring(tab2) }), 'DiffviewViewOpened: session 2 cursor augroup created')

  -- Closing session 2's pane must close only session 2's, not session 1's.
  view.close(tab2)
  ok(not view.is_open(tab2), 'close(tab2): session 2 pane closed')
  ok(view.is_open(tab1), 'close(tab2): session 1 pane left open')

  -- Simulate Diffview's real teardown: it closes the view's own tabpage
  -- *before* firing the global `DiffviewViewClosed` User event (verified
  -- against diffview.nvim's source -- the event carries no per-view data).
  -- Both sessions' handlers run off the same global event; only the one
  -- whose own captured tab just went invalid should tear itself down.
  vim.cmd('tabclose') -- closes tab2, returns focus to tab1
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewClosed', modeline = false })
  vim.wait(20)
  ok(view.is_open(tab1), 'DiffviewViewClosed after tab2 closed: session 1 pane untouched')
  ok(pcall(vim.api.nvim_get_autocmds, { group = 'AdoPrThreadView' .. tostring(tab1) }), 'DiffviewViewClosed after tab2 closed: session 1 augroup untouched')
  ok(
    not pcall(vim.api.nvim_get_autocmds, { group = 'AdoPrThreadViewCursor' .. tostring(tab2) }),
    'DiffviewViewClosed after tab2 closed: session 2 cursor augroup torn down'
  )

  -- Re-attaching in a fresh tab must not orphan or leak session 1's pane.
  vim.cmd('tabnew')
  local tab3 = vim.api.nvim_get_current_tabpage()
  view.attach()
  ok(view.is_open(tab3), 'session 3 (new tab): pane open')
  ok(view.is_open(tab1), 'session 3 attach: session 1 pane still open (not leaked/orphaned)')
  view.close(tab3)
  vim.cmd('tabclose')
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewClosed', modeline = false })
  vim.wait(20)

  view.close(tab1)
  ok(not view.is_open(tab1), 'close(tab1): session 1 pane closed')
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewClosed', modeline = false })
  vim.wait(20)
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
