## Problem Statement

`:AdoPr` / `:AdoPrReview` checkout the target PR's branch into the current worktree. This breaks in
three related ways:

1. If the PR's branch is already checked out in another worktree (a common state for anyone
   reviewing more than one PR, or switching between review and normal dev work), the checkout
   silently no-ops instead of opening the review — git's exclusivity lock blocks a second
   non-detached checkout of the same branch, and the plugin surfaces nothing.
2. If the PR's branch is not yet local, checkout can fail mid-way with an error like
   `Could not access submodule 'T2.ServiceCatalogue'`, even though the preceding fetch succeeded —
   the checkout is auto-triggering submodule init/update for a submodule the review doesn't need
   and that isn't reachable in this environment.
3. In a repo with no other worktrees (a plain clone), today's plain branch-switch behavior is fine
   and should keep working exactly as it does now — any fix for (1) must not regress this case.

The reviewer's actual need is to see the PR's diff and comment on it. Submodule working-tree content
and "which worktree the branch happens to already be checked out in" are incidental obstacles to
that, not things the reviewer is trying to manage.

## Solution

`:AdoPr` / `:AdoPrReview` route the checkout based on the repo's current worktree topology instead
of always checking out into the invoking worktree:

- **Plain repo** (no other worktrees exist for this repo): behave exactly as today — checkout the
  branch directly in the current worktree.
- **Repo with other worktrees**: check out the PR's branch into a dedicated **detached** review
  worktree (default name `prreview`, created if it doesn't exist, reused if it does) instead of the
  invoking worktree. `git worktree add --detach` succeeds even when the branch is already checked
  out non-detached elsewhere, because git's exclusivity lock only blocks a second *non-detached*
  checkout — routing through a detached worktree structurally removes the conflict rather than
  working around it.

Independently, the checkout step no longer auto-initializes submodules. If the branch's diff touches
a submodule pointer, the plugin surfaces a one-line notice naming the submodule and the pointer
change instead of trying to make its contents diffable — reviewing a submodule's own commit history
is a distinct, larger feature and out of scope here.

## User Stories

1. As a reviewer already working on another PR's branch in a second worktree, I want `:AdoPr` on a
   new PR to still open cleanly, so that I don't have to manually stash or juggle worktrees before
   reviewing.
2. As a reviewer, I want `:AdoPr` on a not-yet-local branch to succeed even when the repo has a
   submodule that's unreachable in my environment, so that a submodule I don't need doesn't block a
   review I do need.
3. As a reviewer working in a plain single-worktree clone, I want `:AdoPr` to keep behaving exactly
   as it does today, so that the routing fix for multi-worktree setups doesn't change my normal
   workflow.
4. As a reviewer, I want to be told when a PR changes a submodule pointer, so that I know a change
   exists that this diff view isn't showing me, rather than silently missing it.
5. As a reviewer, I want the dedicated review worktree's location/name to be configurable, so that it
   fits alongside my own worktree layout conventions.

## Implementation Decisions

- **Worktree-count detection**: repo-wide worktree topology is read via `git worktree list`. More
  than 1 entry (the current worktree is always entry 1) means at least one other worktree exists for
  this repo, and the checkout routes through the detached review worktree. Exactly 1 entry keeps
  today's plain-checkout behavior.
- **New routing module** with a pure decision function: given the current worktree count (and
  review-worktree config), return which route to take (`plain` vs `detached-review`) and the target
  path for the detached case. The actual `git worktree add --detach` / `git worktree list` /
  checkout invocations are a thin adapter around this pure function, mirroring the existing
  `anchor.lua` split (pure `resolve` is unit-tested; the diffview/git adapter is smoke-only).
- **Detached review worktree**: created on first use if absent, reused on subsequent calls (checked
  out to a different branch each time via `git worktree` machinery, not recreated). Default name
  `prreview`, sibling to the other worktrees; name/location configurable via `setup()`.
- **Checkout no longer goes through `az repos pr checkout`** for the fetch+checkout step — that
  command is opaque about both its target worktree and its submodule behavior. It's replaced with
  explicit `git fetch` of the PR's source branch (already the direction PR #14 took for diff-base
  resolution) followed by an explicit checkout/`worktree add`, invoked with submodule recursion
  disabled (e.g. `-c submodule.recurse=false`) so a broken/unreachable submodule can never block a
  review checkout.
- **Submodule pointer-change notice**: after checkout, the plugin inspects the PR diff for changed
  submodule pointer entries (git reports these distinctly from regular file changes). If any are
  found, a single `vim.notify` INFO message lists the submodule path(s) with old→new short SHAs.
  This is detection only — no submodule content is fetched, initialized, or made diffable.
- **Out-of-scope submodule content**: actually reviewing a submodule's own change (its internal
  commit diff) requires resolving the submodule's own git objects and opening a second diff view
  rooted in the submodule — a distinct feature, tracked separately, not built here.
- **Error surfacing**: any failure in the routing/checkout/fetch path (worktree creation fails,
  fetch fails, checkout fails) aborts with a `vim.notify` ERROR describing the failed step, matching
  the fail-loud convention PR #14 established for diff-base resolution — no silent no-ops.

## Testing Decisions

- The routing decision function (worktree count/config → route + target path) is pure and fully
  unit-tested: single-worktree repo, multi-worktree repo with the review worktree absent, multi-worktree
  repo with it already present, and configured-name variants — following the existing pattern of
  testing `anchor.resolve` and `diffview_state`'s accessor as pure functions.
- The submodule pointer-change detector is a pure function over diff/status output (given parsed
  submodule-change entries, produce the notice text) and is unit-tested directly, without invoking
  git.
- The git/`az` adapter calls (`git worktree add`, `git fetch`, checkout, `git worktree list`) are
  smoke-tested only, consistent with how `az.lua`'s CLI-shelling functions are treated elsewhere in
  this codebase — real command execution isn't covered by the headless suite.

## Out of Scope

- Reviewing a submodule's own internal commit history/diff (a distinct future feature).
- Any change to how comments are anchored or posted — this spec only touches the checkout/routing
  step ahead of `diffview` opening.
- Configuring more than one named review worktree, or per-PR worktree naming — one default detached
  worktree, reused across PRs, is sufficient for now.

## Further Notes

- This spec's routing logic is the natural home for eventually solving F2/B1 together with the
  already-landed PR #14 diff-base fix and PR #15's thread-fetching work — all three now sit on the
  same "make `:AdoPr` checkout robust" line of work, but each ships as its own ticket/PR.
- The `--no-recurse-submodules`-equivalent behavior should be verified against whichever git version
  is in CI/dev environments, since submodule flag support has changed across git versions
  historically; if `-c submodule.recurse=false` proves insufficient in practice, `--no-recurse-submodules`
  on the specific `git checkout`/`worktree add` invocation is the fallback.
