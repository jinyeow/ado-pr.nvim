# Spec — optional diff-base override

Covers [#13](https://github.com/jinyeow/ado-pr.nvim/issues/13), split out of
[#12](https://github.com/jinyeow/ado-pr.nvim/issues/12) (which made the diff base always
resolve from the PR's real ADO target instead of a stale/wrong local ref). Domain vocabulary
(**diff base**, **PR target**, **iteration**) is defined in [CONTEXT.md](../../CONTEXT.md).

## Problem Statement

`:AdoPr` / `:AdoPrReview` always diff a PR against its resolved ADO target — correct by
default, but there's no way to diff against anything else. Two real scenarios hit this:

1. A PR targets a branch that's stale or unsuitable for review purposes (e.g. targets
   `release/1.2`, but I also want to see the diff against `main`).
2. Stacked PRs — PR B targets PR A's branch in ADO, so B's real diff is only "what A added on
   top of," but I want to see B's cumulative change against `main`.

In both cases I currently have to leave the plugin (diff manually in a terminal, or use the
browser) to answer a question the review tool should be able to answer directly.

## Solution

A per-PR, session-only override on the Full-PR-view diff base, accepting any git ref (branch,
tag, or commit SHA). It never touches the PR's real record in ADO — this is a local
visualization only, distinct from actually changing the PR's target branch (tracked separately,
[#50](https://github.com/jinyeow/ado-pr.nvim/issues/50)).

Three single-purpose commands, mirroring the existing `AdoPr*` convention:

- `:AdoPrSetDiffBase <ref>` — validate and resolve `<ref>` to a commit, then re-diff the active
  PR's Full-PR view against it.
- `:AdoPrShowDiffBase` — echo the currently effective diff base and whether it's an override or
  the ADO-resolved default.
- `:AdoPrResetDiffBase` — clear the override, returning to the ADO-resolved target.

## User Stories

1. As a reviewer, I want to diff a PR against a branch other than its ADO target, so that I can
   compare it to `main` when the real target is a stale or unsuitable base for review.
2. As a reviewer working through a stack of PRs, I want to diff one PR against `main` instead of
   its immediate ADO target, so that I can see the cumulative change instead of just that PR's
   slice.
3. As a reviewer, I want to check what diff base is currently active, so that I don't
   misinterpret an overridden diff as the PR's real ADO-target diff.
4. As a reviewer, I want to clear an override and return to the ADO-resolved target, so that I'm
   not stuck comparing against the wrong thing for the rest of the session.
5. As a reviewer, I want the override to apply only to the Full-PR view, so that iteration
   browsing (`:AdoPrIterations`, "what did this one push change") keeps meaning what it already
   means, unaffected by an unrelated override.
6. As a reviewer, I want setting an override to return me from iteration browsing to the Full-PR
   view, so that the override I just set is what I actually see.
7. As a reviewer, I want `:AdoPrReview <id>` to always start clean, so that an override from a
   previous PR never silently carries into a new one.
8. As a reviewer, I want an invalid or unfetchable ref to fail loudly and leave my current diff
   untouched, so that a typo never silently breaks my review session.
9. As a reviewer, I want to keep commenting on the current (right/new) side of the diff while an
   override is active, so that a routine review isn't interrupted by an unrelated feature.
10. As a reviewer, I want commenting blocked on the old (left) side while an override is active,
    so that I never post a thread anchored to a line ADO's real diff wouldn't show it on.

## Implementation Decisions

- **State shape (`state.lua`)**: add `override_base string|nil`. `pr_base` remains untouched —
  always the true ADO-resolved base, "immutable for the session" per its existing doc comment.
  The effective Full-PR-view base is `override_base or pr_base`, computed in one place and used
  everywhere a Full-PR-view diff is (re)opened.
- **Full-PR-view reopen becomes unconditional (`review.lua`)**: the existing `reset_window`
  no-ops when `ctx.window == nil` (already in Full-PR view), which doesn't work for this
  feature — setting or clearing an override is the common case of *already being* in Full-PR
  view and needing an actual re-render. Refactor into a shared "(re)open Full-PR view against
  the effective base" function, used by `M.open`'s initial diff, the existing
  iteration-window-reset path, and all three new commands.
- **`:AdoPrSetDiffBase <ref>`**: validate/resolve `<ref>` to a commit using the same
  retry-then-abort pattern as `resolve_base` (`review.lua:145-181` — `FETCH_RETRIES` attempts,
  `vim.notify` WARN on intermediate failures). On success: set `override_base` to the resolved
  commit, clear `window`/`head` (return to Full-PR view), reopen the diff, reload plain-view
  threads. On failure after all retries: `vim.notify` ERROR, leave state and the active diff
  untouched.
- **`:AdoPrShowDiffBase`**: `vim.notify` INFO with the effective base and whether it's the
  ADO-resolved default or an active override.
- **`:AdoPrResetDiffBase`**: set `override_base = nil`, reopen Full-PR view against `pr_base`
  (reusing the same reopen path as `set`), reload plain-view threads.
- **`:AdoPrReview <id>`**: always builds a fresh context with `override_base = nil` — a clean
  slate regardless of what PR or override was active before.
- **Iteration-browsing interaction**: an active override never affects iteration diffs — browsing
  an iteration keeps diffing against its normal per-push base (`window_for`'s existing logic,
  unchanged). Setting an override while browsing an iteration exits the iteration window back to
  Full-PR view. Returning to "Full PR (all iterations)" from the picker uses the effective base
  (override if set, else `pr_base`).
- **Commenting (`M.comment`, `review.lua:362`)**: gains a check alongside the existing
  `ctx.window` iteration-browsing block — while `override_base` is set, reject comments where
  `anchor.current()` resolved `side == 'left'`, with an actionable error (reset the override,
  then comment). Right-side comments are unaffected and remain allowed: the right side is always
  the current checked-out worktree content (`head = nil` → HEAD), independent of the diff base,
  so its line numbers stay valid regardless of any override. No exception for deleted files
  (left-side only, per `anchor.lua`'s `status == 'A'` check) — they become uncommentable while an
  override is active, same as any other left-side line; this is a fail-closed choice, not a gap.
- **Commands/accessors**: three new `vim.api.nvim_create_user_command` entries in
  `plugin/ado-pr.lua`, matching the existing `AdoPr*` registration style exactly, plus matching
  lazy accessors on `M` in `init.lua` (`set_diff_base`, `show_diff_base`, `reset_diff_base`),
  mirroring `M.browse_iterations`'s shape.

## Testing Decisions

- Headless tests in the existing `tests/*_spec.lua` style (stub `vim.system` to capture argv,
  stub `vim.cmd`/`vim.notify`), following `post_thread_spec.lua` and the pattern described in
  #12's test plan for `resolve_base`.
- `state.lua`: pure assertions on `override_base`/`pr_base`/effective-base computation — no I/O,
  same style as `M.range()`'s existing tests (if any) or straightforward table-shape assertions.
- `review.lua`:
  - `set_diff_base`: asserts the `git fetch`/resolve argv, that a successful resolve updates
    `override_base` and reopens the diff, and that a failed resolve after retries leaves state
    and the active diff untouched (mirrors #12's "abort never issues DiffviewOpen" test).
  - `reset_diff_base`: asserts `override_base` clears and the diff reopens against `pr_base`.
  - The unconditional Full-PR reopen path: asserts it fires even when `ctx.window == nil`
    (the case `reset_window` currently skips).
  - Iteration-browsing interaction: asserts setting an override while `ctx.window` is set clears
    the window and reopens Full-PR view; asserts an iteration diff's base is unaffected by an
    active `override_base`.
  - `M.comment`: asserts a left-side anchor is rejected with `override_base` set and posts
    normally without it; asserts a right-side anchor still posts with `override_base` set.
- Cannot be covered headlessly: that ADO's real diff for the PR actually differs from what the
  override shows, or that a posted right-side comment renders correctly in ADO's web UI. Those
  need a live smoke check, same caveat as #12.

## Out of Scope

- Changing the PR's actual `targetRefName` in ADO — tracked separately as
  [#50](https://github.com/jinyeow/ado-pr.nvim/issues/50), not scoped, needs its own grilling.
- Persisting an override across `:AdoPrReview` calls, same PR or different — always resets.
- Any UI beyond `vim.notify` for `:AdoPrShowDiffBase` (no picker, no statusline integration).
- Overriding the diff base for iteration browsing — iterations always diff their normal per-push
  commit pair, regardless of any Full-PR-view override.
- Validating that an override's resolved commit is even reachable/sensible relative to the PR's
  actual history (e.g. no ancestry check) — any resolvable ref is accepted as-is.

## Further Notes

- An override changing a file's git-status classification (added/deleted/renamed) relative to
  what ADO's real target-based diff would show is a known edge case, surfaced during grilling but
  intentionally not addressed here — right-side comments are treated as safe based on content
  provenance (always HEAD) without cross-checking status classification against the ADO-canonical
  diff. Revisit if it causes a real issue in practice.
- Command naming deliberately avoids "TargetBranch" (considered and rejected during grilling) —
  that phrasing implies mutating what ADO considers the PR's target, which is the separate,
  heavier feature tracked in #50. "DiffBase" was chosen to match the vocabulary now fixed in
  CONTEXT.md.
