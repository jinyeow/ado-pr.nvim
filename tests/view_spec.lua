-- Pure-logic tests for ado-pr.view.format_thread -- the follower pane's display
-- lines. Run headless: `nvim --headless -l tests/view_spec.lua`.
-- No test framework: a tiny assert harness (plenary is not a dependency), same
-- shape as tests/threads_spec.lua.
--
-- The window/buffer management in view.lua (open/close/refresh) is untested
-- adapter code over diffview internals and Neovim's window API, same split as
-- signs.lua -- see docs/specs/pr-comment-threads.md "What is not unit-tested".
-- M.jump's out-of-bounds clamping (issue #25) IS covered below via a
-- diffview.lib stub, since a real nvim_win_set_cursor error is the bug.
package.path = './lua/?.lua;./lua/?/init.lua;' .. package.path

-- Stub for the cross-tab event-bleed and M.jump tests below: diffview_state.current()
-- requires 'diffview.lib' lazily inside its body, so a package.loaded stub
-- installed before require is picked up on every call (same technique
-- tests/diffview_state_spec.lua and issue #25's clamp tests use). Keyed by
-- the *actual* current tabpage, same as diffview.lib's real
-- get_current_view() would be -- there is exactly one "current" view at a
-- time, no matter how many sessions are attached.
local views_by_tab = {}
package.loaded['diffview.lib'] = {
  get_current_view = function()
    return views_by_tab[vim.api.nvim_get_current_tabpage()]
  end,
}

local view = require('ado-pr.view')
local signs = require('ado-pr.signs')

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
  -- on DiffviewDiffBufWinEnter/DiffviewViewOpened). Each session only reacts
  -- to an event fired while its OWN tab is focused (the tab-focus guard --
  -- see the cross-tab bleed test below for why), so each needs its own
  -- firing with that tab focused.
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewOpened', modeline = false })
  vim.wait(20)
  ok(pcall(vim.api.nvim_get_autocmds, { group = 'AdoPrThreadViewCursor' .. tostring(tab2) }), 'DiffviewViewOpened: session 2 cursor augroup created')

  vim.api.nvim_set_current_tabpage(tab1)
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewOpened', modeline = false })
  vim.wait(20)
  ok(pcall(vim.api.nvim_get_autocmds, { group = 'AdoPrThreadViewCursor' .. tostring(tab1) }), 'DiffviewViewOpened: session 1 cursor augroup created')

  -- Closing session 2's pane must close only session 2's, not session 1's.
  view.close(tab2)
  ok(not view.is_open(tab2), 'close(tab2): session 2 pane closed')
  ok(view.is_open(tab1), 'close(tab2): session 1 pane left open')

  -- Simulate Diffview's real teardown: it closes the view's own tabpage
  -- *before* firing the global `DiffviewViewClosed` User event (verified
  -- against diffview.nvim's source -- the event carries no per-view data).
  -- Both sessions' handlers run off the same global event; only the one
  -- whose own captured tab just went invalid should tear itself down.
  vim.api.nvim_set_current_tabpage(tab2)
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

-- ---------------------------------------------------------------------------
-- Cross-tab event bleed: DiffviewDiffBufWinEnter/DiffviewViewOpened are
-- global User events with no per-view payload, so *every* attached session's
-- handler runs on *any* tab's event -- including a session whose own tab
-- isn't the one that changed. Before the tab-focus guard, a stale session's
-- handler read diffview_state.current() (whichever tab is actually focused
-- when the deferred callback runs, not its own captured tab) and re-pointed
-- its cursor-follower augroup at the *other* tab's buffer -- so session 1's
-- pane silently started following session 2's cursor instead of its own.
-- ---------------------------------------------------------------------------
do
  local function cursor_group_buffer(tab)
    local autocmds = vim.api.nvim_get_autocmds({ group = 'AdoPrThreadViewCursor' .. tostring(tab), event = 'CursorMoved' })
    return autocmds[1] and autocmds[1].buffer
  end

  local tab1 = vim.api.nvim_get_current_tabpage()
  local win1 = vim.api.nvim_get_current_win()
  local buf1 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win1, buf1)
  views_by_tab[tab1] = {
    cur_entry = { path = 'f1.lua', oldpath = nil, status = 'M' },
    cur_layout = { name = 'diff1_plain', symbols = { 'b' }, b = { id = win1, file = { bufnr = buf1 } } },
  }
  view.attach()
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewOpened', modeline = false })
  vim.wait(20)
  eq(cursor_group_buffer(tab1), buf1, 'cross-tab bleed: session 1 cursor group starts bound to its own buffer')

  vim.cmd('tabnew')
  local tab2 = vim.api.nvim_get_current_tabpage()
  local win2 = vim.api.nvim_get_current_win()
  local buf2 = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win2, buf2)
  views_by_tab[tab2] = {
    cur_entry = { path = 'f2.lua', oldpath = nil, status = 'M' },
    cur_layout = { name = 'diff1_plain', symbols = { 'b' }, b = { id = win2, file = { bufnr = buf2 } } },
  }
  view.attach()

  -- Fire the event while tab2 is focused: this is the moment a stale
  -- session's handler used to misread diffview_state.current() as tab2's
  -- view instead of its own tab1's.
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewOpened', modeline = false })
  vim.wait(20)
  eq(cursor_group_buffer(tab1), buf1, 'cross-tab bleed: session 1 cursor group still bound to its own buffer, not session 2 buffer')
  eq(cursor_group_buffer(tab2), buf2, 'cross-tab bleed: session 2 cursor group bound to its own buffer')

  -- Clean up: close both sessions/tabs so later tests start from a clean tab state.
  view.close(tab2)
  vim.cmd('tabclose')
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewClosed', modeline = false })
  vim.wait(20)
  view.close(tab1)
  vim.api.nvim_exec_autocmds('User', { pattern = 'DiffviewViewClosed', modeline = false })
  vim.wait(20)
end

-- ---------------------------------------------------------------------------
-- M.jump must clamp a stale iteration range into the buffer instead of
-- letting nvim_win_set_cursor error on an out-of-bounds row (issue #25) --
-- the same guard signs.lua's place() already applies when rendering signs.
-- ---------------------------------------------------------------------------

local function set_view(path, winid, bufnr)
  views_by_tab[vim.api.nvim_get_current_tabpage()] = {
    cur_entry = { path = path, oldpath = nil, status = 'M' },
    cur_layout = { name = 'diff1_plain', symbols = { 'b' }, b = { id = winid, file = { bufnr = bufnr } } },
  }
end

local function right_thread(id, start_line, end_line)
  return {
    id = id,
    status = 'active',
    threadContext = {
      filePath = '/jump.lua',
      rightFileStart = { line = start_line },
      rightFileEnd = { line = end_line },
    },
    comments = { { commentType = 'text', author = { displayName = 'A' }, publishedDate = '2026-01-01', content = 'x' } },
  }
end

-- In-range navigation is unchanged, and a thread anchored past the last line
-- lands on the last line instead of erroring.
do
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'l1', 'l2', 'l3', 'l4', 'l5' })
  set_view('jump.lua', win, buf)
  signs.set_threads({ right_thread(1, 2, 2), right_thread(2, 50, 52) })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  view.jump(1)
  eq(vim.api.nvim_win_get_cursor(win), { 2, 0 }, 'jump: in-range next lands on anchor line')

  local ok_call = pcall(view.jump, 1)
  ok(ok_call, 'jump: past-end target does not error')
  eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, 'jump: past-end target clamps to last line')

  view.jump(-1)
  eq(vim.api.nvim_win_get_cursor(win), { 2, 0 }, 'jump: prev from last line lands back on in-range anchor')

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  view.jump(-1)
  eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, 'jump: wrap to prev clamps the last thread to buffer end')
end

-- A thread anchored at line 0 or negative clamps to line 1 instead of erroring.
do
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'l1', 'l2', 'l3', 'l4', 'l5' })
  set_view('jump.lua', win, buf)
  signs.set_threads({ right_thread(1, -3, -1) })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  local ok_call = pcall(view.jump, 1)
  ok(ok_call, 'jump: negative anchor does not error')
  eq(vim.api.nvim_win_get_cursor(win), { 1, 0 }, 'jump: negative anchor clamps to line 1')
end

-- An empty (0-line) buffer: jump is a no-op, no error. Real Neovim buffers
-- always report at least one line, so nvim_buf_line_count is stubbed for
-- this one bufnr to exercise threads.clamp's zero-line-count branch.
do
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'l1', 'l2', 'l3' })
  set_view('jump.lua', win, buf)
  signs.set_threads({ right_thread(1, 2, 2) })
  vim.api.nvim_win_set_cursor(win, { 1, 0 })

  local orig_line_count = vim.api.nvim_buf_line_count
  vim.api.nvim_buf_line_count = function(b)
    if b == buf then
      return 0
    end
    return orig_line_count(b)
  end
  local ok_call = pcall(view.jump, 1)
  vim.api.nvim_buf_line_count = orig_line_count

  ok(ok_call, 'jump: zero-line buffer does not error')
  eq(vim.api.nvim_win_get_cursor(win), { 1, 0 }, 'jump: zero-line buffer is a no-op')
end

-- ---------------------------------------------------------------------------
-- Issue #42: repeated ]t/[t past a clamped thread must not get stuck
-- reselecting the same clamped row forever -- once landed on a stale
-- thread's clamped last-line, the next press must wrap to the next real
-- thread instead of re-matching the stale thread's unclamped line_start
-- against the cursor's already-clamped row.
-- ---------------------------------------------------------------------------
do
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'l1', 'l2', 'l3', 'l4', 'l5' })
  set_view('jump.lua', win, buf)
  signs.set_threads({ right_thread(1, 2, 2), right_thread(2, 50, 52) })

  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  view.jump(1)
  eq(vim.api.nvim_win_get_cursor(win), { 2, 0 }, 'issue 42: first ]t lands on in-range thread')

  view.jump(1)
  eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, 'issue 42: second ]t clamps to the stale thread at buffer end')

  -- Before the fix: this press re-matched the same stale thread (its unclamped
  -- line_start 50 still beats the clamped cursor row 5) and left the cursor
  -- stuck at row 5 forever.
  view.jump(1)
  eq(vim.api.nvim_win_get_cursor(win), { 2, 0 }, 'issue 42: third ]t wraps to the first thread instead of re-selecting the same clamped row')

  view.jump(1)
  eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, 'issue 42: fourth ]t reaches the stale thread again, the cycle keeps progressing')

  -- Same failure mode in the other direction, from the buffer's first line.
  vim.api.nvim_win_set_cursor(win, { 1, 0 })
  view.jump(-1)
  eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, 'issue 42: first [t wraps to the stale thread at buffer end')

  view.jump(-1)
  eq(vim.api.nvim_win_get_cursor(win), { 2, 0 }, 'issue 42: second [t lands on the in-range thread')

  view.jump(-1)
  eq(vim.api.nvim_win_get_cursor(win), { 5, 0 }, 'issue 42: third [t wraps to the stale thread again instead of getting stuck')
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
