# ADR-0001 — Anchor inline PR threads by the focused diff pane

- Status: Accepted
- Date: 2026-07-21
- Updated: 2026-07-31 (live-verified behaviour folded in; moved from the project brain)
- Scope: ado-pr-nvim
- Supersedes: none

## Context

Posting an inline comment thread to Azure DevOps needs a `threadContext`:
`filePath` plus a one-based `line`/`offset` on either the **right** (new) or
**left** (old) side. The riskiest part is mapping the editor cursor to that
anchor without the "cursor file != displayed file" bug — the sibling project
[cobalt](https://github.com/jinyeow/cobalt) shipped three wrong-file bugs from
reading the file-tree cursor instead of the displayed diff.

Unlike cobalt, ado-pr.nvim does **not** compute the diff; it delegates to
`diffview.nvim`. So the anchor must come out of diffview's own state, and the
side signal is available that cobalt didn't have: diffview shows old and new in
two separate windows, so the user's focused window *is* the side.

## Decision

- **Side = the focused diff window.** `diffview.lib.get_current_view()` gives
  the view; `cur_entry` is the displayed `FileEntry` and `cur_layout` holds the
  two on-screen diff windows — `cur_layout.a.id` (old) and `cur_layout.b.id`
  (new). The window ids must come from `cur_layout`, not `entry.layout`:
  diffview renders through a *clone* of the entry's layout, so the entry's own
  window ids are never the displayed ones. Cursor in `b` → right/new; cursor in
  `a` → left/old; anywhere else (e.g. the file panel) is a hard error, never a
  guess.
- **Path from `cur_entry`, never a panel selection** — this is the cobalt gotcha,
  neutralised by construction. Which paths exist is a **status** question, not an
  `oldpath` one: diffview sets `oldpath` only on renames, so the left side of a
  plain modified file is `path`. An added file (`A`) has no left side and a
  deleted file (`D`) no right side; both error rather than mis-anchor.
- **The mapping is a pure function** `anchor.resolve{path, oldpath, status,
  winid_a, winid_b, cur_win, cur_line}` — primitives in, `{filePath, line, side}`
  out — unit-tested headless. The diffview lookup (`anchor.current()`) is a thin,
  untested adapter over diffview internals, validated by smoke test.
- **Body shape mirrors cobalt's tested client**: `status:1` active,
  `commentType:1` text, `line/offset` one-based, right-xor-left set. Posted via
  `az devops invoke --area git --resource pullRequestThreads --http-method POST
  --in-file <tmp> --route-parameters project/repositoryId/pullRequestId`. The
  `git/pullRequestThreads` resource was confirmed in the live `az devops invoke`
  api map (versions 3.0–7.2).

## Consequences

- Side detection is one window-id compare — simpler and more robust than
  cobalt's line-type inference, because the user physically picks the pane.
- Per-side buffer line numbers map straight to the ADO `line`, so no diff-hunk
  translation is needed while diffview shows real file buffers.
- The adapter is coupled to diffview internals (`cur_entry`, `cur_layout.a|b.id`)
  — a diffview refactor could break it silently; it is out of the tested core on
  purpose and needs a smoke test after diffview upgrades.
- Renames use the side-appropriate path (`path` vs `oldpath`); added/deleted
  files error on the absent side rather than mis-anchoring.
- **Verified live** (2026-07-23): threads post from both the right and the left
  pane against a real PR.

## Alternatives considered

- **Infer side from line type (cobalt's way)** — rejected: diffview already
  separates the sides into windows, so reading the focused window is a cleaner,
  bug-resistant signal than classifying the line under the cursor.
- **Compute the diff client-side like cobalt** — rejected: the whole point of
  this plugin is to be a thin ADO layer over diffview; re-deriving the diff
  throws away that leverage.
- **Repository by name in the route** — rejected: took `repository.id` (GUID)
  from the PR payload; the threads route wants the id and the GUID is
  unambiguous across renamed repos.
