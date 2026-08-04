-- Bespoke sign adapter placing Azure DevOps PR comment thread markers in diffview's
-- right-side (new-file) buffer. Extmarks in a plugin-owned namespace, never
-- `vim.diagnostic` -- PR comments must stay out of diagnostic counts, the quickfix list,
-- and diagnostic-counting statuslines.
--
-- Right-side placement is the one rule that holds across every diffview layout: buffer row
-- == new-file line, true in the two-window layouts and equally in diff1_plain/diff1_raw/
-- diff1_inline (the inline renderer never mutates the new-side buffer). Left-side anchors
-- are out of scope for this slice (docs/design/pr-comment-threads.md).
--
-- Untested: thin glue over diffview internals and Neovim's window/buffer API with no seam
-- worth mocking (same call as anchor.lua's M.current / diffview_state.lua), validated by
-- smoke test against a live PR. Filtering and range math live in threads.lua, tested there.
local M = {}

local threads_mod = require('ado-pr.threads')
local diffview_state = require('ado-pr.diffview_state')

local ns = vim.api.nvim_create_namespace('ado_pr_threads')

local START_SIGN = { active = '●', resolved = '○' }
local HL = { active = 'DiagnosticSignInfo', resolved = 'Comment' }
local RANGE_SIGN = '│'

-- { { thread = <thread>, path = <repo-relative, forward-slash>, range = { side, line_start, line_end } } }
local signed = {}
local pr_level = 0

-- Store the renderable threads for the active PR (a plain fetch -- no iteration window).
-- Right-side anchored threads are kept for signing; PR-level (no threadContext) human
-- threads are counted, not signed. Left-side threads are dropped for this slice.
function M.set_threads(threads)
  signed, pr_level = {}, 0
  for _, t in ipairs(threads or {}) do
    if threads_mod.is_renderable(t) then
      local path = threads_mod.path(t)
      if not path then
        pr_level = pr_level + 1
      else
        local range = threads_mod.resolve(t, nil)
        if range and range.side == 'right' then
          table.insert(signed, { thread = t, path = threads_mod.norm_repo_path(path), range = range })
        end
      end
    end
  end
end

-- Human PR-level threads (no threadContext) -- surfaced as a count on open, not an
-- invented inline home.
function M.pr_level_count()
  return pr_level
end

local function place(buf, line_count, range, thread)
  local clamped = threads_mod.clamp(range, line_count)
  if clamped.line_start == 0 then
    return
  end
  local kind = threads_mod.is_resolved(thread) and 'resolved' or 'active'
  local hl = HL[kind]
  local function mark(line, text)
    vim.api.nvim_buf_set_extmark(buf, ns, line - 1, 0, {
      sign_text = text,
      sign_hl_group = hl,
    })
  end
  mark(clamped.line_start, START_SIGN[kind])
  for line = clamped.line_start + 1, clamped.line_end do
    mark(line, RANGE_SIGN)
  end
end

-- Re-render signs in diffview's current right-side buffer for the file under the cursor.
-- A multi-line thread is marked across its whole span, not only at its first line. Threads
-- on files outside the current diff scope are skipped by the path match below. Safe to call
-- with no active diffview view (no-op).
function M.refresh()
  local state = diffview_state.current()
  if not state then
    return
  end
  local win = state.windows.b
  if not (win and win.bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(win.bufnr, ns, 0, -1)

  local entry_path = threads_mod.norm_repo_path(state.entry.path)
  local line_count = vim.api.nvim_buf_line_count(win.bufnr)
  for _, item in ipairs(signed) do
    if item.path == entry_path then
      place(win.bufnr, line_count, item.range, item.thread)
    end
  end
end

local group
-- Hook diffview's buffer-enter event so signs re-apply as the user moves between files --
-- diffview swaps content into an existing buffer rather than running placement once at
-- open. Torn down on DiffviewViewClosed so a closed review doesn't leave a WinEnter
-- autocmd firing forever. Safe to call repeatedly (each review re-creates the group).
function M.attach()
  group = vim.api.nvim_create_augroup('AdoPrThreads', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = { 'DiffviewDiffBufWinEnter', 'DiffviewViewOpened' },
    callback = vim.schedule_wrap(M.refresh),
  })
  vim.api.nvim_create_autocmd('WinEnter', {
    group = group,
    callback = vim.schedule_wrap(M.refresh),
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'DiffviewViewClosed',
    -- Deleting the augroup from inside its own callback errors ("autocommands are
    -- locked"); defer to the next event-loop tick, same as diffview.nvim's own teardown.
    callback = vim.schedule_wrap(function()
      vim.api.nvim_del_augroup_by_id(group)
      group = nil
    end),
  })
end

return M
