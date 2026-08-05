## Problem Statement

A comment thread anchored to the **old** (left) side of a diff is invisible today.
`signs.lua` signs only the right-side buffer and drops every left-side thread outright
("out of scope for this slice" — see PR #20/#5). A reviewer opening a file that has
left-side comments — deleted lines, or any thread ADO reports against the old side —
sees no mark at all, with no way to know a thread exists there short of the PR-level
count. This gets worse once iteration browsing (#9) ships, since that is where
`threadContext` starts reporting left-side positions routinely rather than as an edge
case.

Diffview's single-window layouts (`diff1_inline`, `diff1_plain`, `diff1_raw`) make this
harder than the two-window layouts: they have no old-side buffer at all, so "sign the
left-side buffer" isn't an option — a left-side thread's row has to be *derived* from
whatever the layout renders instead.

## Solution

Extend thread signing to place left-side threads correctly in every diffview layout the
plugin supports, using the honest home for that layout and never guessing:

- Two-window layouts (`diff2_horizontal`, `diff2_vertical`, …): sign the old-side window
  directly, keyed to the thread's own line number — no mapping needed, mirroring how the
  right side is already signed today.
- `diff1_inline`: map the old-side line to the real row it lands on — an unchanged
  region maps by hunk offset to a real row; a line inside a deletion maps to the row its
  virtual lines hang from (the same row diffview's own `]c`/`[c` navigation anchors to).
- `diff1_plain` / `diff1_raw`: same offset mapping for unchanged-region lines; a line
  inside a genuine deletion has no real row to sign, so it is reported as an
  "n threads not showable in this layout" count instead of placed anywhere.
- Switching layouts re-derives placement from scratch rather than leaving stale marks
  from the previous layout.

A spike against the installed diffview-plus.nvim confirmed the load-bearing assumption
behind this design: `diffview.scene.inline_diff.get_hunks(bufnr)` is a public function
already wired into this repo's `diffview_state.current().hunks` (added ahead of need in
PR #11), returning the exact `{ old_start, old_count, new_start, new_count }` shape the
ticket assumed, cached per-buffer whenever `diff1_inline` is active. `diff1_plain` and
`diff1_raw` attach no such renderer, so they have no diffview-computed hunk table at
all — confirming those two layouts need a self-computed one, not a diffview lookup.

## User Stories

1. As a reviewer using a two-window diff layout, I want a thread on a deleted or
   unchanged old-side line to show as a sign in the old-side window, so that I can see
   the comment without leaving the diff.
2. As a reviewer using `diff1_inline`, I want a thread on an old-side line in an
   unchanged region to sign on that line's real row, so that the sign lands on the same
   content the thread was actually written against.
3. As a reviewer using `diff1_inline`, I want a thread on a deleted old-side line to
   sign on the row its virtual deletion text hangs from, so that the mark sits next to
   the deleted content instead of on an unrelated line.
4. As a reviewer using `diff1_plain` or `diff1_raw`, I want a thread on an unchanged
   old-side line to sign on the corresponding row, so that the two layout families
   behave consistently wherever a real row exists.
5. As a reviewer using `diff1_plain` or `diff1_raw`, I want threads on genuinely deleted
   lines surfaced as a count rather than misplaced, so that I know they exist without
   being misled about where.
6. As a reviewer switching between diffview layouts mid-review, I want left-side signs
   to re-place themselves for the new layout, so that I never see a stale mark left over
   from the previous one.
7. As a maintainer, I want the old-line-to-new-row mapping to be a pure function tested
   against fabricated hunk tables, so that the placement logic for both single-window
   layout families is verified without a live diffview session.

## Implementation Decisions

- **One mapping function, two hunk-table sources.** `threads.lua` gains a pure function
  that maps an old-side line number to `{ row }` or `nil` (genuinely deleted, no real
  row) given a hunk table in the `{ old_start, old_count, new_start, new_count }` shape.
  `diff1_inline` supplies that table from `diffview_state.current().hunks` (already
  wired). `diff1_plain`/`diff1_raw` supply a self-computed table of the same shape —
  same function, same tests, two callers.
- **Self-computed hunks for `diff1_plain`/`diff1_raw`.** These layouts attach no
  diffview diff renderer, so `diffview_state` gains the ability to compute a hunk table
  itself: diff the old blob's content against the new-side buffer's content using
  `vim.diff` with `result_type = "indices"` (the same call diffview's own inline
  renderer uses internally), which yields the identical hunk shape. The old blob comes
  from a git read against the diff's base revision — reuse the base-revision resolution
  `review.lua` already does for diff-base fetching (PR #14/#12 fix), not a new
  ADO/`az` round trip.
- **`diffview_state.current()` extended, not replaced.** It already returns `hunks` for
  `diff1_inline`; it grows the same field for `diff1_plain`/`diff1_raw` via the
  self-computed path above, so `signs.lua` reads one field regardless of which layout
  family it came from.
- **`signs.lua` grows a left-side placement path.** `set_threads` currently discards any
  `range.side == 'left'` result from `threads.resolve`; it instead keeps left-side
  threads in a second bucket, parallel to the existing right-side one. `refresh()` gains
  a left-side branch: for two-window layouts it signs `state.windows.a` directly by line
  number (no mapping — this is the same shape as the existing right-side path, just on
  the other window); for single-window layouts it runs the new mapping function against
  `state.hunks` and either places the sign on the returned row in `state.windows.b`, or
  — when the mapping returns nil — adds the thread to an un-showable count exposed
  alongside the existing `pr_level_count()`.
- **Re-placement on layout switch is free.** `signs.lua` already clears and re-runs
  placement on `DiffviewDiffBufWinEnter`/`WinEnter` (existing `attach()`/`refresh()`);
  since layout switches fire through the same diffview autocmds, no new hook is needed —
  this falls out of the existing refresh path once left-side placement reads
  `state.layout`/`state.hunks` fresh each call.
- **No prototype or grilling session needed.** Ticket #6 already specifies the mapping
  algorithm precisely enough (per-layout acceptance criteria, hunk-table shape) that the
  only open question was whether diffview actually exposes what the ticket assumed for
  `diff1_inline`; the spike above settled that. The `diff1_plain`/`diff1_raw`
  self-computed-hunks decision is new information from the spike, not previously
  captured in the ticket.

## Testing Decisions

- The old-line-to-row mapping function is a pure function of a hunk table and a line
  number: unit-test it in `threads_spec`-style fashion against fabricated
  `{ old_start, old_count, new_start, new_count }` tables covering an unchanged-region
  hit, a mid-deletion hit, an edge-of-file deletion, and a line with no matching hunk at
  all (identical on both sides) — same shape as the existing `threads.resolve`/`clamp`
  tests, no live diffview needed.
- The self-computed-hunks path in `diffview_state` is tested the same way `threads.lua`
  is: feed it fabricated old/new content strings and assert the resulting hunk table
  shape matches what `vim.diff` would produce, without needing a real git blob.
- `signs.lua`'s left-side placement wiring stays untested per its existing convention
  (thin glue over diffview/Neovim APIs with no seam worth mocking) and is validated by a
  live smoke test against each of the three layout families, per the ticket's own
  acceptance criteria.

## Out of Scope

- Iteration-window browsing (#9) and original-vs-current toggling (#10) — this spec only
  makes whatever `threadContext` a plain or already-tracked fetch reports renderable in
  every layout; it does not change what threads.resolve/original report.
- The follower pane (#7) and overlapping-thread handling (#8) — unrelated to sign
  placement.
- Merge-tool layouts (`diff3_*`, `diff4_*`) — not in scope for #6 and not covered by this
  spec.
- Any UI beyond a sign and an un-showable count — no float, no virtual-text preview of
  left-side thread content.

## Further Notes

`diffview.scene.inline_diff.get_hunks` is an internal diffview-plus.nvim module path,
not a documented public API — `diffview_state.lua` already depends on it (guarded with
`pcall`, degrading to no hunks on failure) since PR #11, so this spec continues an
existing risk rather than introducing a new one. A diffview-plus.nvim upgrade that
renames or removes `inline_diff.get_hunks` degrades left-side signing in `diff1_inline`
back to "no signs, no crash" via the same `pcall` guard, not a hard failure.
