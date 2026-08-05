## Problem Statement

`signs.lua` and `view.lua` both depend on the same resolved-thread collection — the
per-PR list of `{ thread, path, range }` entries produced by filtering a fetched
thread list down to the renderable ones and resolving each to a placement range. That
collection currently lives inline in `signs.lua` (module-local `signed` table, plus
`M.set_threads` / `M.items_for` / `M.pr_level_count`), so `view.lua`'s follower pane
reaches into `signs.lua`'s internals (`signs.items_for(path)`) rather than depending on
a module that owns this data on its own terms. This was flagged as a MEDIUM finding
during PR #21's review (`signs.lua:32`) and deliberately deferred: its right shape
depended on what #29 settled about what counts as a "showable" left-side thread, and
filing it before that risked designing against a definition still in flux. #29 merged
(PR #37) and the surrounding fix stack (#23/#24/#28/#29/#30, PRs #33–#38) is now closed,
so that definition is settled and this extraction is unblocked.

## Solution

Extract the resolved-thread collection into its own module, `resolved_threads.lua`,
that both `signs.lua` and `view.lua` depend on as peers. `signs.lua` keeps everything
that is genuinely sign-placement-specific (the placement plan, the not-showable count,
the extmark rendering); `resolved_threads.lua` owns storing and querying the resolved
collection itself. This is a pure structural extraction — no behavior changes for either
module's callers.

## User Stories

1. As a maintainer, I want the resolved-thread collection to live in its own module, so
   that `view.lua` depends on a module that owns that data rather than reaching into
   `signs.lua`'s internals.
2. As a maintainer, I want `signs.lua` to depend on the same `resolved_threads.lua`
   module for its own placement work, so that `signs.lua` and `view.lua` are peers over
   shared data instead of one depending on the other.
3. As a maintainer, I want the extraction to change no runtime behavior, so that the
   existing `signs_spec.lua` and `view_spec.lua` assertions continue to pass unchanged
   as proof the move was purely structural.
4. As a maintainer, I want `resolved_threads.lua`'s own behavior (renderable filtering,
   path presence routing to a PR-level count, range resolution, per-path lookup) unit
   tested directly, so that this behavior has a home of its own instead of only being
   exercised incidentally through `signs_spec.lua`/`view_spec.lua` fixture setup.

## Implementation Decisions

- **New module `resolved_threads.lua`.** Named after the ticket's own phrase ("the
  resolved-thread collection"), paralleling `threads.lua` (pure per-thread helpers:
  `is_renderable`, `resolve`, `norm_repo_path`) as the resolved/aggregated view built
  from those helpers — same naming relationship `diffview_state.lua` has to raw diffview
  state.
- **What moves from `signs.lua` to `resolved_threads.lua`:**
  - The module-local `signed` collection (`{ { thread, path, range }, ... }`).
  - `M.set_threads(threads)` — filters to `threads_mod.is_renderable`, routes
    no-`threadContext` PR-level threads to a count, resolves the rest via
    `threads_mod.resolve` and normalizes the path via `threads_mod.norm_repo_path`.
  - `M.items_for(path)` — per-path lookup, used by `view.lua`'s follower pane.
  - `M.pr_level_count()` — computed in the same `set_threads` loop as the collection
    itself; moves with it rather than being split across two modules.
  - A new `M.all()` accessor returning the full unfiltered collection, added because
    `signs.lua`'s `M.plan` needs the whole collection (it does its own per-`entry_path`
    filtering internally) rather than a single path's items.
- **What stays in `signs.lua`:** `not_showable` / `M.not_showable_count()`, and `M.plan`
  itself. Both are derived per-refresh from the placement pass (layout branch selection,
  hunk mapping), not part of the stored collection, and have no `view.lua` consumer.
  `M.plan`'s signature and tested contract are unchanged — it now reads its input via
  `resolved_threads.all()` instead of the local `signed` table.
- **No backward-compatibility shims.** `signs.lua` no longer exposes `set_threads`,
  `items_for`, or `pr_level_count`. `review.lua` and `view.lua` `require` and call
  `resolved_threads.lua` directly for those; `signs.lua` also requires it internally
  for `M.refresh()`'s call into `M.plan`.

## Testing Decisions

- Pure extraction: existing `signs_spec.lua` and `view_spec.lua` assertions must pass
  unchanged after the move (proof of no behavior change), with their fixture setup calls
  updated from `signs.set_threads(...)` to `resolved_threads.set_threads(...)`.
- New `resolved_threads_spec.lua` covers `set_threads`/`items_for`/`pr_level_count`
  directly, since that behavior currently has no dedicated test file of its own:
  - Renderable filtering (`threads_mod.is_renderable`) excluding non-renderable threads
    from the collection.
  - A thread with no path routing to `pr_level_count()` instead of the collection.
  - A thread whose `threads_mod.resolve` returns nil being dropped rather than stored
    with a nil range.
  - `items_for(path)` returning only entries matching that normalized path.
  - `all()` returning the full unfiltered collection regardless of path.
  - `set_threads()` resetting the collection and `pr_level_count()` on each call (same
    reset behavior `signs.lua`'s tracker-reset tests already rely on today).
- Prior art: `threads_spec.lua`'s style for pure-function/collection tests over
  fabricated thread tables; `signs_spec.lua`'s existing `set_threads`/`not_showable`
  fixture pattern for what moves out of it.

## Out of Scope

- Any change to what counts as "showable" or how left-side threads are mapped to rows
  (`docs/specs/left-side-thread-anchoring.md`) — that definition is settled input to
  this extraction, not something this spec revisits.
- Any change to `signs.lua`'s placement/rendering behavior (`M.plan`, `M.refresh`,
  extmark placement, not-showable notification) beyond swapping its data source from
  the local `signed` table to `resolved_threads.all()`.
- Any change to `view.lua`'s follower-pane rendering or navigation behavior — only its
  dependency target for `items_for` changes.

## Further Notes

This spec was reached via `/grilling` on ticket #43, which itself was filed only once
#29 (left-side "showable" semantics) settled — see the ticket body for the full
deferral history back to PR #21.
