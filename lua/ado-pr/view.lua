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

-- Matches prototypes/threads_ui_prototype.lua's variant B height, the number the
-- prototype's verdict weighed against ("Variant B costs you 14 lines of height
-- permanently").
local HEIGHT = 14

M.EMPTY_LINES = { '(no thread on this line)' }

local WRAP_WIDTH = 76

-- Character-aware wrap (vim.fn.strcharpart / strchars, not #/sub): comment text
-- routinely carries multi-byte characters (em dashes, smart quotes -- see
-- fixtures_threads.lua), and a byte-offset cut can land mid-character.
local function wrap(text)
  local out = {}
  for _, line in ipairs(vim.split(text, '\n')) do
    while vim.fn.strchars(line) > WRAP_WIDTH do
      local head = vim.fn.strcharpart(line, 0, WRAP_WIDTH)
      local cut = head:match('.*%s')
      local cut_chars = cut and vim.fn.strchars(cut) or WRAP_WIDTH
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

local pane = { win = nil, buf = nil }

function M.is_open()
  return pane.win ~= nil and vim.api.nvim_win_is_valid(pane.win)
end

-- Read whichever thread(s) cover the cursor in diffview's right-side window and
-- render the narrowest one, or the empty-state lines when the cursor is on none.
-- Never touches the diff windows -- only reads their cursor position.
function M.refresh()
  if not M.is_open() then
    return
  end
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
  vim.bo[pane.buf].modifiable = true
  vim.api.nvim_buf_set_lines(pane.buf, 0, -1, false, lines)
  vim.bo[pane.buf].modifiable = false
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
function M.open()
  if M.is_open() then
    return
  end
  local views = snapshot_views()
  local prev = vim.api.nvim_get_current_win()
  vim.cmd(('botright %dsplit'):format(HEIGHT))
  pane.win = vim.api.nvim_get_current_win()
  pane.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(pane.win, pane.buf)
  vim.wo[pane.win].number = false
  vim.wo[pane.win].relativenumber = false
  vim.wo[pane.win].signcolumn = 'no'
  vim.bo[pane.buf].buftype = 'nofile'
  vim.bo[pane.buf].bufhidden = 'wipe'
  vim.bo[pane.buf].swapfile = false
  vim.api.nvim_set_current_win(prev)
  restore_views(views)
  M.refresh()
end

function M.close()
  if not M.is_open() then
    return
  end
  local views = snapshot_views()
  vim.api.nvim_win_close(pane.win, true)
  pane.win, pane.buf = nil, nil
  restore_views(views)
end

function M.toggle()
  if M.is_open() then
    M.close()
  else
    M.open()
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

local group

-- Wire diffview's events (buffer-enter for file switches, view-closed for
-- teardown) and open the pane. Mirrors signs.attach()'s event set.
function M.attach()
  group = vim.api.nvim_create_augroup('AdoPrThreadView', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = { 'DiffviewDiffBufWinEnter', 'DiffviewViewOpened' },
    callback = vim.schedule_wrap(function()
      setup_keymaps()
      M.refresh()
    end),
  })
  vim.api.nvim_create_autocmd({ 'CursorMoved', 'WinEnter' }, {
    group = group,
    callback = M.refresh,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DiffviewViewClosed',
    -- Deferred a tick for the same reason signs.lua defers its teardown:
    -- deleting the augroup from inside its own callback errors.
    callback = vim.schedule_wrap(function()
      M.close()
      vim.api.nvim_del_augroup_by_id(group)
      group = nil
    end),
  })
  setup_keymaps()
  M.open()
end

return M
