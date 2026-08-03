-- PROTOTYPE — THROWAWAY. Not part of the plugin. Delete once it has answered its question.
--
-- QUESTION: how should Azure DevOps PR comment threads read inside a diff, and how should
-- the "diff as it was when the comment was made" view read next to the current diff?
--
-- Three structurally different ways to READ a thread, switchable with <F8>:
--   A  signs + float on demand   — gutter marks, body in a float you summon (octo.nvim's shape)
--   B  signs + follower pane     — gutter marks, body in a bottom split that tracks the cursor
--   C  thread list drives diff   — a left panel of all threads; picking one moves the diff
--
-- Plus the comment-archaeology view, <F9> on a signed line, in every variant:
--   a new tab, two splits, ORIGINAL iteration content on the left and CURRENT on the right,
--   with the thread signed in BOTH — current anchor from threadContext, original anchor from
--   pullRequestThreadContext.trackingCriteria. [i / ]i step iterations.
--
-- Fixtures (prototypes/fixtures_threads.lua) mirror the STRUCTURE of a real PR pulled by
-- prototypes/spike_read_path.lua: 16 of 21 threads are system noise, all human threads sit in
-- one file, threads run 2-4 comments deep, and one 23-line thread contains two others.
-- Authors and comment text are invented. No `az`, no network.
--
-- RUN (from the repo root):
--   nvim -c "luafile prototypes/threads_ui_prototype.lua"

local M = {}

local ns = vim.api.nvim_create_namespace('adopr_prototype')
local ns_orig = vim.api.nvim_create_namespace('adopr_prototype_orig')

local here = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':h')
local FIX = dofile(here .. '/fixtures_threads.lua')

local THREADS, ITERATIONS = FIX.threads, FIX.iterations

-- ---------------------------------------------------------------------------
-- Fixture helpers
-- ---------------------------------------------------------------------------

local function is_system(thread)
  for _, c in ipairs(thread.comments) do
    if c.commentType ~= 'system' then
      return false
    end
  end
  return true
end

local function anchored_threads()
  local out = {}
  for _, t in ipairs(THREADS) do
    if not is_system(t) and t.threadContext and t.threadContext.rightFileStart then
      table.insert(out, t)
    end
  end
  return out
end

local function pr_level_threads()
  local out = {}
  for _, t in ipairs(THREADS) do
    if not is_system(t) and not t.threadContext then
      table.insert(out, t)
    end
  end
  return out
end

local function system_count()
  local n = 0
  for _, t in ipairs(THREADS) do
    if is_system(t) then
      n = n + 1
    end
  end
  return n
end

local function norm(path)
  return '/' .. (path or ''):gsub('\\', '/'):gsub('^/', '')
end

local function threads_for(path)
  local want, out = norm(path), {}
  for _, t in ipairs(anchored_threads()) do
    if t.threadContext.filePath == want then
      table.insert(out, t)
    end
  end
  return out
end

-- Every anchored thread is a RANGE. Single-line threads are the degenerate case.
local function span(thread)
  local tc = thread.threadContext
  local s = tc.rightFileStart.line
  local e = (tc.rightFileEnd and tc.rightFileEnd.line) or s
  return s, math.max(s, e)
end

local function original_span(thread)
  local tk = thread.pullRequestThreadContext and thread.pullRequestThreadContext.trackingCriteria
  if not (tk and tk.origRightFileStart) then
    return nil
  end
  local s = tk.origRightFileStart.line
  local e = (tk.origRightFileEnd and tk.origRightFileEnd.line) or s
  return s, math.max(s, e), tk.origFilePath
end

local function made_on_iteration(thread)
  local ic = thread.pullRequestThreadContext and thread.pullRequestThreadContext.iterationContext
  return ic and ic.secondComparingIteration or nil
end

local function thread_lines(thread)
  local s, e = span(thread)
  local head = ('Thread #%d  [%s]  %s:%s'):format(
    thread.id, thread.status, thread.threadContext.filePath, s == e and tostring(s) or (s .. '-' .. e))
  local it = made_on_iteration(thread)
  if it then
    head = head .. ('   (made on iteration %d)'):format(it)
  end
  local lines = { head, '' }
  for i, c in ipairs(thread.comments) do
    table.insert(lines, ('%s  ·  %s'):format(c.author, c.publishedDate))
    for _, l in ipairs(vim.split(c.content, '\n')) do
      -- wrap long comments so the float/pane stays readable
      while #l > 76 do
        local cut = l:sub(1, 76):match('.*%s') or l:sub(1, 76)
        table.insert(lines, '  ' .. cut)
        l = l:sub(#cut + 1):gsub('^%s+', '')
      end
      table.insert(lines, '  ' .. l)
    end
    if i < #thread.comments then
      table.insert(lines, '')
    end
  end
  return lines
end

-- ---------------------------------------------------------------------------
-- Signs in the live diffview buffers
-- ---------------------------------------------------------------------------

local START_SIGN = { active = '●', fixed = '○' }
local RANGE_SIGN = '│'
local HL = { active = 'DiagnosticSignInfo', fixed = 'Comment' }

local function mark(buf, namespace, line, text, hl, label)
  local last = vim.api.nvim_buf_line_count(buf)
  local row = math.max(0, math.min(line, last) - 1) -- clamp: threads outlive their lines
  pcall(vim.api.nvim_buf_set_extmark, buf, namespace, row, 0, {
    sign_text = text,
    sign_hl_group = hl,
    virt_text = label and { { label, 'Comment' } } or nil,
    virt_text_pos = label and 'eol' or nil,
  })
end

local function sign_thread(buf, namespace, s, e, thread, label)
  mark(buf, namespace, s, START_SIGN[thread.status] or '●', HL[thread.status] or 'DiagnosticSignInfo', label)
  for line = s + 1, e do
    mark(buf, namespace, line, RANGE_SIGN, HL[thread.status] or 'DiagnosticSignInfo', nil)
  end
end

local function current_view()
  local ok, lib = pcall(require, 'diffview.lib')
  if not ok then
    return nil
  end
  local view = lib.get_current_view()
  if not (view and view.cur_entry and view.cur_layout) then
    return nil
  end
  return view
end

local function right_win_buf()
  local view = current_view()
  if not view then
    return nil
  end
  local win = view.cur_layout.b and view.cur_layout.b.id
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return nil
  end
  return win, vim.api.nvim_win_get_buf(win), view.cur_entry.path
end

function M.refresh_signs()
  local _, buf, path = right_win_buf()
  if not buf then
    return
  end
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  for _, t in ipairs(threads_for(path)) do
    local s, e = span(t)
    sign_thread(buf, ns, s, e, t, ('  %d comment%s'):format(#t.comments, #t.comments == 1 and '' or 's'))
  end
end

-- Threads covering the cursor line, narrowest first — overlapping threads are normal.
local function threads_under_cursor()
  local win, _, path = right_win_buf()
  if not win then
    return {}
  end
  local line = vim.api.nvim_win_get_cursor(win)[1]
  local hits = {}
  for _, t in ipairs(threads_for(path)) do
    local s, e = span(t)
    if line >= s and line <= e then
      table.insert(hits, t)
    end
  end
  table.sort(hits, function(a, b)
    local as, ae = span(a)
    local bs, be = span(b)
    return (ae - as) < (be - bs)
  end)
  return hits
end

-- ONE thread shows at a time. When several cover the cursor line the narrowest wins, and
-- <leader>ct pressed again cycles to the next; <leader>cT opens a picker instead.
local cycle = { line = nil, idx = 1 }

local function selected(advance)
  local hits = threads_under_cursor()
  if #hits == 0 then
    return nil, 0, 0
  end
  local win = right_win_buf()
  local line = win and vim.api.nvim_win_get_cursor(win)[1] or nil
  if cycle.line ~= line then
    cycle.line, cycle.idx = line, 1
  elseif advance then
    cycle.idx = (cycle.idx % #hits) + 1
  end
  return hits[cycle.idx], cycle.idx, #hits
end

-- ---------------------------------------------------------------------------
-- Variant A — signs + float on demand
-- ---------------------------------------------------------------------------

local float = { win = nil, buf = nil }

local function close_float()
  if float.win and vim.api.nvim_win_is_valid(float.win) then
    vim.api.nvim_win_close(float.win, true)
  end
  float.win, float.buf = nil, nil
end

local function open_float(thread, idx, total)
  close_float()
  local lines = thread_lines(thread)
  local width = 0
  for _, l in ipairs(lines) do
    width = math.max(width, vim.fn.strdisplaywidth(l))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  float.buf = buf
  float.win = vim.api.nvim_open_win(buf, false, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = math.min(math.max(width + 2, 40), 84),
    height = math.min(#lines, 22),
    style = 'minimal',
    border = 'rounded',
    title = total > 1
        and (' thread %d/%d here — <leader>ct cycles '):format(idx, total)
      or ' PR thread ',
  })
end

local VariantA = {
  name = 'A — signs + float on demand',
  help = '<leader>ct thread (again = next overlapping)   <leader>cT pick   ]t/[t   <F9> original',
}

-- show() is what <leader>ct calls; every variant implements it.
function VariantA.show(advance)
  local t, idx, total = selected(advance)
  if not t then
    vim.notify('no thread on this line', vim.log.levels.WARN)
    return
  end
  open_float(t, idx, total)
end

function VariantA.attach()
  vim.api.nvim_create_autocmd('CursorMoved', { group = M.group, callback = close_float })
end

function VariantA.detach()
  close_float()
end

-- ---------------------------------------------------------------------------
-- Variant B — signs + follower pane tracking the cursor
-- ---------------------------------------------------------------------------

local follower = { win = nil, buf = nil }

-- Forward declaration: follower_open's `q` mapping calls VariantB.detach, which is defined
-- further down. Without this the name resolves to a global and is nil at call time.
local VariantB

local function follower_open()
  if follower.win and vim.api.nvim_win_is_valid(follower.win) then
    return false
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd('botright 14split')
  follower.win = vim.api.nvim_get_current_win()
  follower.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(follower.win, follower.buf)
  vim.wo[follower.win].number = false
  vim.wo[follower.win].signcolumn = 'no'
  -- q closes the pane; <leader>ct brings it back.
  vim.keymap.set('n', 'q', function()
    VariantB.detach()
  end, { buffer = follower.buf, desc = 'prototype: close thread pane' })
  vim.api.nvim_set_current_win(prev)
  return true
end

local function follower_update(advance)
  if not (follower.win and vim.api.nvim_win_is_valid(follower.win)) then
    return
  end
  local t, idx, total = selected(advance)
  local lines = t and thread_lines(t) or { '', '  (no thread on this line)' }
  vim.bo[follower.buf].modifiable = true
  vim.api.nvim_buf_set_lines(follower.buf, 0, -1, false, lines)
  vim.bo[follower.buf].modifiable = false
  vim.wo[follower.win].winbar = (total or 0) > 1
      and ('%%#Title# PR THREAD %d/%d here — <leader>ct cycles · q closes %%*'):format(idx, total)
    or '%#Title# PR THREAD — q closes %*'
end

VariantB = {
  name = 'B — signs + follower pane',
  help = 'pane follows the cursor   <leader>ct reopen/cycle   q close   <F9> original',
}

-- Reopen the pane if it was closed; otherwise cycle overlapping threads.
function VariantB.show(advance)
  local reopened = follower_open()
  follower_update(advance and not reopened)
end

function VariantB.attach()
  follower_open()
  follower_update(false)
  vim.api.nvim_create_autocmd('CursorMoved', {
    group = M.group,
    callback = function()
      follower_update(false)
    end,
  })
end

function VariantB.detach()
  if follower.win and vim.api.nvim_win_is_valid(follower.win) then
    vim.api.nvim_win_close(follower.win, true)
  end
  follower.win, follower.buf = nil, nil
end

-- ---------------------------------------------------------------------------
-- Variant C — a thread list that drives the diff
-- ---------------------------------------------------------------------------

local panel = { win = nil, buf = nil, index = {} }

local function panel_render()
  local lines, index = {}, {}
  local ts = anchored_threads()
  table.insert(lines, (' THREADS (%d shown, %d system hidden)'):format(#ts + #pr_level_threads(), system_count()))
  table.insert(lines, '')

  local by_file = {}
  for _, t in ipairs(ts) do
    local f = t.threadContext.filePath
    by_file[f] = by_file[f] or {}
    table.insert(by_file[f], t)
  end
  for file, list in pairs(by_file) do
    table.insert(lines, ' ' .. file)
    table.sort(list, function(a, b)
      return (span(a)) < (span(b))
    end)
    for _, t in ipairs(list) do
      local s, e = span(t)
      local snippet = vim.split(t.comments[1].content, '\n')[1]
      if #snippet > 36 then
        snippet = snippet:sub(1, 35) .. '…'
      end
      table.insert(lines, ('  %s %-7s %s (%d)'):format(
        START_SIGN[t.status] or '●',
        s == e and tostring(s) or (s .. '-' .. e),
        t.comments[1].author,
        #t.comments))
      index[#lines] = t
      table.insert(lines, ('       %s'):format(snippet))
      index[#lines] = t
    end
    table.insert(lines, '')
  end

  local prl = pr_level_threads()
  if #prl > 0 then
    table.insert(lines, ' (PR-level, no anchor)')
    for _, t in ipairs(prl) do
      table.insert(lines, ('  ● %s (%d)'):format(t.comments[1].author, #t.comments))
      index[#lines] = t
    end
  end

  panel.index = index
  vim.bo[panel.buf].modifiable = true
  vim.api.nvim_buf_set_lines(panel.buf, 0, -1, false, lines)
  vim.bo[panel.buf].modifiable = false
end

local VariantC = {
  name = 'C — thread list drives the diff',
  help = '<CR> in the list jumps the diff   <leader>ct focus list   <F9> original vs current',
}

function VariantC.show()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_set_current_win(panel.win)
  else
    VariantC.attach()
  end
end

function VariantC.attach()
  local prev = vim.api.nvim_get_current_win()
  vim.cmd('topleft 52vsplit')
  panel.win = vim.api.nvim_get_current_win()
  panel.buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(panel.win, panel.buf)
  vim.wo[panel.win].winbar = '%#Title# COMMENT THREADS %*'
  vim.wo[panel.win].number = false
  vim.wo[panel.win].signcolumn = 'no'
  panel_render()
  vim.keymap.set('n', '<CR>', function()
    local t = panel.index[vim.api.nvim_win_get_cursor(0)[1]]
    if not t then
      return
    end
    if not t.threadContext then
      vim.notify('PR-level comment — no line to jump to', vim.log.levels.WARN)
      return
    end
    local win = right_win_buf()
    if win then
      vim.api.nvim_set_current_win(win)
      pcall(vim.api.nvim_win_set_cursor, win, { (span(t)), 0 })
    end
  end, { buffer = panel.buf, desc = 'prototype: jump to thread' })
  vim.api.nvim_set_current_win(prev)
end

function VariantC.detach()
  if panel.win and vim.api.nvim_win_is_valid(panel.win) then
    vim.api.nvim_win_close(panel.win, true)
  end
  panel.win, panel.buf, panel.index = nil, nil, {}
end

-- ---------------------------------------------------------------------------
-- Comment archaeology — ORIGINAL iteration vs CURRENT, signed in both
-- ---------------------------------------------------------------------------

local arch = { thread = nil, iteration = nil, left = nil, right = nil }

local function iteration_label(id)
  for _, it in ipairs(ITERATIONS) do
    if it.id == id then
      return ('%s  (%s)'):format(it.label, it.when)
    end
  end
  return ('Iteration %d'):format(id)
end

local function arch_render()
  local t, iter = arch.thread, arch.iteration
  local path = t.threadContext.filePath
  local content = (FIX.original_content[path] or {})[iter]

  local lbuf = vim.api.nvim_win_get_buf(arch.left)
  vim.bo[lbuf].modifiable = true
  vim.api.nvim_buf_set_lines(lbuf, 0, -1, false,
    content and vim.split(content, '\n')
      or { ('(no fixture content for %s at iteration %d)'):format(path, iter),
        '',
        'In the real plugin this pane is filled from ADO:',
        '  items?path=' .. path,
        '       &versionDescriptor.version=<that iteration\'s commit>',
        '       &versionDescriptor.versionType=commit&includeContent=true',
        '',
        'Fixtures only exist for iterations 1 and 2 — step back with [i.' })
  vim.bo[lbuf].modifiable = false
  vim.wo[arch.left].winbar = '%#DiffDelete# ORIGINAL %* ' .. iteration_label(iter)

  vim.api.nvim_buf_clear_namespace(lbuf, ns_orig, 0, -1)
  local os_, oe = original_span(t)
  if os_ and content then
    sign_thread(lbuf, ns_orig, os_, oe, t, '  ← where it was written')
  end

  local rbuf = vim.api.nvim_win_get_buf(arch.right)
  vim.api.nvim_buf_clear_namespace(rbuf, ns_orig, 0, -1)
  local s, e = span(t)
  sign_thread(rbuf, ns_orig, s, e, t, '  ← where it is now')
  vim.wo[arch.right].winbar = '%#DiffAdd# CURRENT %* ' .. iteration_label(ITERATIONS[#ITERATIONS].id)

  pcall(vim.api.nvim_win_set_cursor, arch.right, { math.min(s, vim.api.nvim_buf_line_count(rbuf)), 0 })
  if os_ and content then
    pcall(vim.api.nvim_win_set_cursor, arch.left, { math.min(os_, vim.api.nvim_buf_line_count(lbuf)), 0 })
  end
end

local function arch_open(thread)
  local path = thread.threadContext.filePath:gsub('^/', '')
  vim.cmd('tabnew')
  arch.thread = thread
  arch.iteration = math.max(1, (made_on_iteration(thread) or 2) - 1)

  local lbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, lbuf)
  arch.left = vim.api.nvim_get_current_win()
  vim.bo[lbuf].filetype = 'lua'

  vim.cmd('vsplit ' .. vim.fn.fnameescape(path))
  arch.right = vim.api.nvim_get_current_win()

  for _, w in ipairs({ arch.left, arch.right }) do
    vim.api.nvim_win_call(w, function()
      vim.cmd('diffthis')
    end)
  end

  arch_render()

  local function step(delta)
    return function()
      arch.iteration = math.max(1, math.min(#ITERATIONS, arch.iteration + delta))
      arch_render()
      vim.notify(('iteration %d/%d — %s'):format(arch.iteration, #ITERATIONS, iteration_label(arch.iteration)))
    end
  end
  for _, w in ipairs({ arch.left, arch.right }) do
    local buf = vim.api.nvim_win_get_buf(w)
    vim.keymap.set('n', ']i', step(1), { buffer = buf, desc = 'prototype: next iteration' })
    vim.keymap.set('n', '[i', step(-1), { buffer = buf, desc = 'prototype: prev iteration' })
    vim.keymap.set('n', 'q', '<cmd>tabclose<cr>', { buffer = buf, desc = 'prototype: close' })
  end

  vim.notify('[i / ]i step iterations   ·   q closes')
end

-- ---------------------------------------------------------------------------
-- Variant switcher
-- ---------------------------------------------------------------------------

local VARIANTS = { VariantA, VariantB, VariantC }
local current = 1

local function announce()
  local v = VARIANTS[current]
  vim.notify(('PROTOTYPE  %s\n%s\n<F8> next variant'):format(v.name, v.help))
end

local function switch(to)
  VARIANTS[current].detach()
  current = ((to - 1) % #VARIANTS) + 1
  VARIANTS[current].attach()
  M.refresh_signs()
  announce()
end

-- ---------------------------------------------------------------------------
-- Bootstrap
-- ---------------------------------------------------------------------------

function M.start()
  if not pcall(require, 'diffview') then
    vim.notify('prototype needs diffview (or diffview-plus) on the runtimepath', vim.log.levels.ERROR)
    return
  end

  M.group = vim.api.nvim_create_augroup('AdoPrPrototype', { clear = true })

  vim.cmd('DiffviewOpen HEAD~3...HEAD')

  vim.api.nvim_create_autocmd('User', {
    group = M.group,
    pattern = { 'DiffviewDiffBufWinEnter', 'DiffviewViewOpened' },
    callback = vim.schedule_wrap(M.refresh_signs),
  })
  vim.api.nvim_create_autocmd('WinEnter', { group = M.group, callback = vim.schedule_wrap(M.refresh_signs) })

  vim.keymap.set('n', '<F8>', function()
    switch(current + 1)
  end, { desc = 'prototype: next variant' })

  -- One key, every variant: show the thread here. Pressed again on the same line it
  -- cycles through overlapping threads instead of stacking them.
  vim.keymap.set('n', '<leader>ct', function()
    VARIANTS[current].show(true)
  end, { desc = 'prototype: show / cycle thread' })

  -- The picker alternative, for when cycling is the wrong shape.
  vim.keymap.set('n', '<leader>cT', function()
    local hits = threads_under_cursor()
    if #hits == 0 then
      vim.notify('no thread on this line', vim.log.levels.WARN)
      return
    end
    if #hits == 1 then
      VARIANTS[current].show(false)
      return
    end
    vim.ui.select(hits, {
      prompt = ('%d threads on this line'):format(#hits),
      format_item = function(t)
        local s, e = span(t)
        return ('%s %-7s %s (%d comments)'):format(
          START_SIGN[t.status] or '●',
          s == e and tostring(s) or (s .. '-' .. e),
          t.comments[1].author,
          #t.comments)
      end,
    }, function(choice)
      if not choice then
        return
      end
      for i, t in ipairs(hits) do
        if t == choice then
          cycle.idx = i
        end
      end
      VARIANTS[current].show(false)
    end)
  end, { desc = 'prototype: pick thread' })

  vim.keymap.set('n', '<F9>', function()
    local hits = threads_under_cursor()
    if #hits == 0 then
      vim.notify('no thread on this line — put the cursor on a signed line', vim.log.levels.WARN)
      return
    end
    local tracked
    for _, t in ipairs(hits) do
      if original_span(t) then
        tracked = t
        break
      end
    end
    if not tracked then
      vim.notify(('thread #%d has no trackingCriteria — ADO only returns it when the fetch passes $iteration/$baseIteration')
        :format(hits[1].id), vim.log.levels.WARN)
      return
    end
    arch_open(tracked)
  end, { desc = 'prototype: original vs current' })

  local jump = function(delta)
    return function()
      local win, _, path = right_win_buf()
      if not win then
        return
      end
      local ts = threads_for(path)
      table.sort(ts, function(a, b)
        return (span(a)) < (span(b))
      end)
      if #ts == 0 then
        return
      end
      local line = vim.api.nvim_win_get_cursor(win)[1]
      local target
      if delta > 0 then
        for _, t in ipairs(ts) do
          if (span(t)) > line then
            target = t
            break
          end
        end
        target = target or ts[1]
      else
        for i = #ts, 1, -1 do
          if (span(ts[i])) < line then
            target = ts[i]
            break
          end
        end
        target = target or ts[#ts]
      end
      pcall(vim.api.nvim_win_set_cursor, win, { (span(target)), 0 })
    end
  end
  vim.keymap.set('n', ']t', jump(1), { desc = 'prototype: next thread' })
  vim.keymap.set('n', '[t', jump(-1), { desc = 'prototype: prev thread' })

  vim.schedule(function()
    VARIANTS[current].attach()
    M.refresh_signs()
    local prl = pr_level_threads()
    vim.notify(('%d threads fetched · %d system dropped · %d anchored%s')
      :format(#THREADS, system_count(), #anchored_threads(),
        #prl > 0 and (' · %d PR-level not shown inline'):format(#prl) or ''))
    announce()
  end)
end

M.start()

return M
