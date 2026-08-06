-- Active-PR context for the current review session.
--
-- One PR is under review at a time (the detached `review` worktree workflow), so
-- a single module-level record is enough. `review.open` sets it from `show_pr`;
-- `:AdoPrComment` reads it to know which PR/repo a thread belongs to. The repo is
-- carried as its GUID (from the PR payload), not its name — the threads route
-- wants the id.
local M = {}

---@class AdoPrContext
---@field id integer          pull request id
---@field repositoryId string repository GUID
---@field project string      project name (for the invoke route)
---@field base string|nil     the resolved base commit review.lua opened diffview against
---                            (base...HEAD) -- signs.lua reads it to self-compute a hunk
---                            table for diff1_plain/diff1_raw (left-side-thread-
---                            anchoring.md), which have no diffview diff renderer to read
---                            one from.
---@field repo_root string|nil the review worktree's cwd, captured once by review.open --
---                            signs.lua's self-computed `git diff` must run against this,
---                            never `vim.fn.getcwd()` at refresh time (the cursor may have
---                            moved windows/tabs by then).
---@field head string|nil     the resolved commit the diff's right side is at -- nil means
---                            HEAD (the checked-out worktree), the case while reviewing the
---                            full PR. Set to an iteration's sourceRefCommit while browsing
---                            iterations (review.select_iteration), so signs.lua diffs the
---                            same range diffview was opened against.
---@field pr_base string|nil  the PR's original resolved base commit (review.open's `base`),
---                            immutable for the session -- review.reset_window reopens
---                            against this to restore the full-PR view after browsing
---                            iterations, since `base` itself gets overwritten per window.
---@field window table|nil    the active iteration window, `{ iteration, base_iteration }`,
---                            or nil for the plain full-PR view (docs/design/
---                            pr-comment-threads.md's `resolve(thread, window)` contract).

---@type AdoPrContext|nil
local current = nil

---@param ctx AdoPrContext
function M.set(ctx)
  current = ctx
end

---@return AdoPrContext|nil
function M.get()
  return current
end

-- The commit range signs.lua's self-computed `git diff` and review.lua's `DiffviewOpen`
-- both diff against, from one source of truth -- `base` alone (see `head`'s doc above), so
-- the two never independently drift on what "the current diff" means. nil when no PR is
-- under review or its base hasn't resolved yet.
function M.range()
  if not (current and current.base) then
    return nil
  end
  return current.base .. '...' .. (current.head or 'HEAD')
end

function M.clear()
  current = nil
end

return M
