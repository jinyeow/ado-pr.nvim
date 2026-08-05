-- The thread follower pane: a split below the diff that tracks the cursor and shows
-- the thread there -- every comment, author, date and the thread's status. Chosen
-- over an on-demand float and a persistent thread-list panel (prototypes/NOTES.md);
-- the float is deliberately not built here (docs/design/pr-comment-threads.md).
--
-- `format_thread` is pure and tested (tests/view_spec.lua). Everything else here is
-- a thin adapter over diffview internals and Neovim's window API, in the same
-- untested split signs.lua uses -- no seam worth mocking, validated by smoke test.
local M = {}

local threads_mod = require('ado-pr.threads')
local signs = require('ado-pr.signs')
local diffview_state = require('ado-pr.diffview_state')
local config = require('ado-pr.config')

-- Default matches prototypes/threads_ui_prototype.lua's variant B height, the
-- number the prototype's verdict weighed against ("Variant B costs you 14
-- lines of height permanently"). Configurable via config.pane_height.
local DEFAULT_HEIGHT = 14

M.EMPTY_LINES = { '(no thread on this line)' }

local DEFAULT_WRAP_WIDTH = 76

-- Character-aware wrap (vim.fn.strcharpart / strchars, not #/sub): comment text
-- routinely carries multi-byte characters (em dashes, smart quotes -- see
-- fixtures_threads.lua), and a byte-offset cut can land mid-character.
local function wrap(text)
  local wrap_width = config.get().wrap_width or DEFAULT_WRAP_WIDTH
  local out = {}
  for _, line in ipairs(vim.split(text, '\n')) do
    while vim.fn.strchars(line) > wrap_width do
      local head = vim.fn.strcharpart(line, 0, wrap_width)
      local cut = head:match('.*%s')
      local cut_chars = cut and vim.fn.strchars(cut) or wrap_width
      table.insert(out, cut or head)
      line = vim.fn.strcharpart(line, cut_chars):gsub('^%s+', '')
    end
    table.insert(out, line)
  end
  return out
end

-- Pure: the follower pane's display lines for one thread -- every comment with
-- its author, date and the thread's status. `position`, when given, is
-- { index, total } from threads.covering (1-based, narrowest first) -- states
-- which of how many overlapping threads this is, so a hidden one is never silent.
function M.format_thread(thread, position)
  local header = ('Thread #%s  [%s]'):format(thread.id, thread.status)
  if position and position.total > 1 then
    header = header .. ('   (%d of %d here)'):format(position.index, position.total)
  end
  local lines = { header, '' }
  for i, c in ipairs(thread.comments or {}) do
    table.insert(lines, ('%s  ·  %s'):format(c.author.displayName, c.publishedDate))
    vim.list_extend(lines, wrap(c.content))
    if i < #thread.comments then
      table.insert(lines, '')
    end
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Adapter: the pane window/buffer and diffview wiring
-- ---------------------------------------------------------------------------

-- Keyed by tabpage: Diffview opens every view in its own new tab (`tab split`
-- in diffview's View:open()), so the tabpage is each review session's stable,
-- natural key -- diffview exposes no other per-session id. A second concurrent
-- session (another tab) must never rewrite or close a first session's pane.
local sessions = {}

local function session_for(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  return sessions[tab]
end

function M.is_open(tab)
  local s = session_for(tab)
  return s ~= nil and s.win ~= nil and vim.api.nvim_win_is_valid(s.win)
end

-- Read whichever thread(s) cover the cursor in diffview's right-side window and
-- render the narrowest one, or the empty-state lines when the cursor is on none.
-- Never touches the diff windows -- only reads their cursor position.
function M.refresh(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  if not M.is_open(tab) then
    return
  end
  local s = sessions[tab]
  local lines = M.EMPTY_LINES
  local state = diffview_state.current()
  if state and state.windows.b and state.windows.b.bufnr then
    local line = vim.api.nvim_win_get_cursor(state.windows.b.winid)[1]
    local items = signs.items_for(threads_mod.norm_repo_path(state.entry.path))
    local covering = threads_mod.covering(items, line)
    if #covering > 0 then
      lines = M.format_thread(covering[1].thread, { index = 1, total = #covering })
    end
  end
  vim.bo[s.buf].modifiable = true
  vim.api.nvim_buf_set_lines(s.buf, 0, -1, false, lines)
  vim.bo[s.buf].modifiable = false
end

-- Snapshot/restore every window's scroll position (winsaveview) across a
-- resize -- opening or closing the pane shrinks/grows every other window in
-- the tabpage, and Neovim adjusts topline to keep each window's cursor
-- visible when it gets short. Restoring the view afterwards is what keeps
-- open/close from disturbing the diff windows' scroll position.
local function snapshot_views()
  local views = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    views[w] = vim.api.nvim_win_call(w, vim.fn.winsaveview)
  end
  return views
end

local function restore_views(views)
  for w, saved in pairs(views) do
    if vim.api.nvim_win_is_valid(w) then
      vim.api.nvim_win_call(w, function()
        vim.fn.winrestview(saved)
      end)
    end
  end
end

-- Open the pane below the diff without disturbing the diff windows or their
-- scroll position: the split briefly takes focus to configure it, then focus
-- and every window's view are restored. A no-op when already open.
function M.open(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  if M.is_open(tab) then
    return
  end
  local views = snapshot_views()
  local prev = vim.api.nvim_get_current_win()
  vim.cmd(('botright %dsplit'):format(config.get().pane_height or DEFAULT_HEIGHT))
  local s = sessions[tab] or {}
  sessions[tab] = s
  s.win = vim.api.nvim_get_current_win()
  s.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(s.win, s.buf)
  vim.wo[s.win].number = false
  vim.wo[s.win].relativenumber = false
  vim.wo[s.win].signcolumn = 'no'
  vim.bo[s.buf].buftype = 'nofile'
  vim.bo[s.buf].bufhidden = 'wipe'
  vim.bo[s.buf].swapfile = false
  vim.api.nvim_set_current_win(prev)
  restore_views(views)
  M.refresh(tab)
end

function M.close(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  if not M.is_open(tab) then
    return
  end
  local s = sessions[tab]
  local views = snapshot_views()
  vim.api.nvim_win_close(s.win, true)
  s.win, s.buf = nil, nil
  restore_views(views)
end

function M.toggle(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  if M.is_open(tab) then
    M.close(tab)
  else
    M.open(tab)
  end
end

-- Move the cursor in diffview's right-side window to the next/previous thread in
-- the file (threads_mod.ordered's file order), wrapping at either end.
function M.jump(delta)
  local state = diffview_state.current()
  if not (state and state.windows.b and state.windows.b.bufnr) then
    return
  end
  local win = state.windows.b.winid
  local ordered = threads_mod.ordered(signs.items_for(threads_mod.norm_repo_path(state.entry.path)))
  if #ordered == 0 then
    return
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local target
  if delta > 0 then
    for _, item in ipairs(ordered) do
      if item.range.line_start > line then
        target = item
        break
      end
    end
    target = target or ordered[1]
  else
    for i = #ordered, 1, -1 do
      if ordered[i].range.line_start < line then
        target = ordered[i]
        break
      end
    end
    target = target or ordered[#ordered]
  end
  vim.api.nvim_win_set_cursor(win, { target.range.line_start, 0 })
  vim.api.nvim_set_current_win(win)
end

-- Buffer-local, user-configurable maps on diffview's diff windows (both sides,
-- when both exist). Idempotent -- safe to call again on every file switch.
local function setup_keymaps()
  local state = diffview_state.current()
  if not state then
    return
  end
  local keymaps = config.get().keymaps
  for _, sym in ipairs({ 'a', 'b' }) do
    local win = state.windows[sym]
    if win and win.bufnr then
      local buf = win.bufnr
      vim.keymap.set('n', keymaps.toggle_thread_pane, M.toggle, { buffer = buf, desc = 'ado-pr: toggle thread pane' })
      vim.keymap.set('n', keymaps.next_thread, function()
        M.jump(1)
      end, { buffer = buf, desc = 'ado-pr: next thread' })
      vim.keymap.set('n', keymaps.prev_thread, function()
        M.jump(-1)
      end, { buffer = buf, desc = 'ado-pr: previous thread' })
    end
  end
end

-- Re-register the cursor-follower autocmds against this tab's *current* diff
-- buffers -- called on every DiffviewDiffBufWinEnter (i.e. every file switch),
-- since the buffers backing the diff windows change with the file. Scoped
-- with `buffer =` so a cursor move in another tab's diff windows (or in this
-- tab's pane buffer) never triggers this session's refresh. Uses its own
-- augroup, cleared on each call, so switching files repeatedly doesn't pile
-- up duplicate autocmds for buffers this session no longer shows.
local function register_cursor_autocmds(tab)
  local cursor_group = vim.api.nvim_create_augroup('AdoPrThreadViewCursor' .. tostring(tab), { clear = true })
  local state = diffview_state.current()
  if not state then
    return
  end
  for _, sym in ipairs({ 'a', 'b' }) do
    local win = state.windows[sym]
    if win and win.bufnr then
      vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinEnter' }, {
        group = cursor_group,
        buffer = win.bufnr,
        callback = function()
          M.refresh(tab)
        end,
      })
    end
  end
end

-- Wire diffview's events (buffer-enter for file switches, view-closed for
-- teardown) and open the pane. Mirrors signs.attach()'s event set.
--
-- One session per tabpage: `group` is suffixed by tab ID so a second
-- concurrent session's attach() (another tab) clears only its own augroup,
-- never a prior session's. DiffviewViewClosed is a global `User` event with
-- no per-view payload (verified against diffview.nvim's source: it is fired
-- via a bare `nvim_exec_autocmds("User", { pattern = ... })`), but diffview
-- closes the view's tabpage (`tabclose`) *before* emitting the event -- so by
-- the time every session's handler runs, only the session whose own tab just
-- disappeared sees its captured tab ID go invalid; every other session's
-- handler sees its own tab still valid and does nothing.
function M.attach()
  local tab = vim.api.nvim_get_current_tabpage()
  local group = vim.api.nvim_create_augroup('AdoPrThreadView' .. tostring(tab), { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = { 'DiffviewDiffBufWinEnter', 'DiffviewViewOpened' },
    callback = vim.schedule_wrap(function()
      -- These are global User events with no per-view payload, so *every*
      -- attached session's handler fires on *any* tab's event -- including
      -- one whose own tab isn't the tab that actually changed.
      -- diffview_state.current() always reflects the currently-focused tab,
      -- not this handler's captured `tab`, so without this guard a stale
      -- session would read the wrong tab's windows and re-point its own
      -- keymaps/cursor-follower autocmds/pane content at them.
      if vim.api.nvim_get_current_tabpage() ~= tab then
        return
      end
      setup_keymaps()
      register_cursor_autocmds(tab)
      M.refresh(tab)
    end),
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DiffviewViewClosed',
    -- Deferred a tick for the same reason signs.lua defers its teardown:
    -- deleting the augroup from inside its own callback errors.
    callback = vim.schedule_wrap(function()
      if vim.api.nvim_tabpage_is_valid(tab) then
        return -- a different session's view closed, not this tab's
      end
      sessions[tab] = nil
      pcall(vim.api.nvim_del_augroup_by_id, group)
      pcall(vim.api.nvim_del_augroup_by_name, 'AdoPrThreadViewCursor' .. tostring(tab))
    end),
  })
  setup_keymaps()
  M.open(tab)
end

return M
