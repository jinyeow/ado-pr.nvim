# ADR-0003 — Posting: anchor is always a range, and columns need a byte→codepoint conversion

- Status: Accepted
- Date: 2026-08-08
- Scope: ado-pr-nvim
- Supersedes: none (extends ADR-0001, the single-line write path)

## Context

Grilling [#51](https://github.com/jinyeow/ado-pr.nvim/issues/51) (comment on a
visual-selection range, not just the cursor line) surfaced two live spikes against a
real ADO PR (`HollardInsuranceRetail/TSC Cloud Platform Engineering/Hollard.Deployment`
PR 19705, `az devops invoke --resource pullRequestThreads`), recorded in full in the
project brain (`research/2026-08-08-ado-offset-semantics.md`). Facts established:

- ADO's `CommentPosition.offset` is **1-based**. `offset: 0` is rejected outright by
  the REST API (`RightFileStart.Offset ... outside of allowed range`) — the .NET SDK
  doc claiming "starts at 0" is wrong; the JS extension API doc ("starts at 1") is
  correct.
- `fileEnd`'s offset is **inclusive** of the last character — confirmed with an
  unambiguous visual discriminator (`offset 11→12` on `artifactName` highlighted
  **both** characters, "ar"; an exclusive end would show only "a"). A zero-width
  point (`offset 11→11`) rendered no highlight at all in ADO's UI — that is a
  rendering fact about zero-width spans, not evidence for either reading; don't
  reuse it as a discriminator.
- The API does **not validate offset against real line content** — an offset far past
  a line's length is accepted without error. ADO trusts the caller entirely; a wrong
  offset fails silently, not loudly.
- `offset` is **not a UTF-8 byte index** — confirmed by posting two threads against a
  line containing multi-byte UTF-8 (`café — offset test`) and visually inspecting
  which one landed on the em dash. The "byte offset" thread landed three characters
  later than intended, exactly where character-indexing (not byte-indexing) predicts.
  **Scope limit**: both test characters (`é`, `—`) are in the Basic Multilingual
  Plane, where codepoint count and UTF-16 code-unit count are identical — this spike
  cannot tell those two apart. Given ADO's backend (.NET) and editor (JS/web) are
  both UTF-16 internally, UTF-16 code units is the likelier reading, but that is
  inference from platform convention, not an executed, confirmed fact. A character
  outside the BMP (e.g. an emoji) would be needed to close this gap.
- ADR-0002 already established the **read** path is range-native
  (`threads.lua:M.resolve` → `{ side, line_start, line_end }`); `signs.lua` and
  `resolved_threads.lua` already render multi-line spans. Only the **write** path
  (`anchor.lua`, `az.lua:M.post_thread`, `:AdoPrComment`'s command definition) was
  single-line-only.
- Neovim's `-range` on a user command always resolves to whole-line boundaries
  (`o.line1`/`o.line2`) regardless of charwise/linewise/blockwise visual submode —
  column data isn't part of that mechanism. `'<`/`'>` marks persist independently of
  `-range` and still carry the columns.
- Neovim's cursor/mark column is a **byte** offset into the buffer line — it diverges
  from ADO's codepoint offset on any line with multi-byte UTF-8 content; ASCII-only
  lines need no conversion (byte offset == codepoint offset there).

## Decision

This decision covers the full anchor design, delivered across two tickets:
[#61](https://github.com/jinyeow/ado-pr.nvim/issues/61) ships the line-range write
path (shipped — `anchor.resolve` returns `{ filePath, side, line_start, line_end }`
and `az.lua` posts `offset = 1` on both ends); the column/character-offset work
below is accepted here but implemented separately as
[#62](https://github.com/jinyeow/ado-pr.nvim/issues/62) (open, not yet shipped).

- **`:AdoPrComment` takes `-range`.** `:AdoPrComment` (no range) stays single-line;
  `:'<,'>AdoPrComment` reads `o.line1`/`o.line2` for the line span. Neovim resolves
  `'<,'>` in buffer order always, so a "reversed range" can't reach `anchor.resolve`.
- **Anchor is always a range; single-line is the degenerate case.** `anchor.resolve`
  is widened to return `{ filePath, side, line_start, line_end, col_start, col_end }`
  rather than gaining a parallel range-only function (`col_start`/`col_end` arrive
  with #62; #61's shipped shape stops at `line_end`). A plain cursor comment sets
  `line_start == line_end` and the full-line column span. This matches the read
  path's existing `{ line_start, line_end }` shape (ADR-0002) instead of diverging
  from it.
- **Side is still decided once, by focused window.** A visual selection lives in
  exactly one diffview window (left or right), so the "cross-side selection" question
  raised in #51 does not arise through this trigger — there is no code path that could
  construct one.
- **Column offsets are decided here, implemented as #62 (not yet shipped)** — in
  scope for this ADR rather than deferred as an open question, now that their
  semantics are mostly confirmed rather than assumed (the one open gap — codepoint
  vs. UTF-16 code-unit counting, see Context — is carried forward as a documented
  assumption, not treated as settled). `anchor.lua` converts the buffer's byte column to a UTF-16 code-unit
  column via `vim.str_utfindex(line, 'utf-16', byte_col)` (not `vim.str_utf_pos`,
  which counts codepoints and would silently diverge on non-BMP characters) before it
  becomes ADO's `offset`. The conversion happens once, at the anchor boundary —
  `az.lua` never sees a byte offset.
- **`az.lua:M.post_thread` builds distinct `pos_start`/`pos_end` tables** (today it
  assigns the same zero-width `pos` table to both `Start` and `End`).
- **`'<`/`'>` marks are trusted for columns only when their lines match
  `o.line1`/`o.line2`.** `-range` fires on any range-form invocation, including
  `:1,5AdoPrComment` typed with no visual selection at all — in that case the marks
  are stale (left over from a previous selection in the buffer) or unset (`getpos`
  returns an all-zero position). `anchor.lua` checks the mark lines against the
  command's line range before using their columns; on a mismatch it falls back to the
  full-line span (`col_start = 1`, `col_end = end of line`), the same as a plain
  `-range` line comment with no column precision.
- **`col_end` is clamped to the line's actual byte length before conversion.** A
  linewise visual selection (`V`, not `v`) sets `getpos("'>")[3]` to `v:maxcol`
  (2147483647) — sent through unclamped, that becomes a nonsense `offset` that ADO's
  API accepts silently (no server-side validation, see Context). Clamping to the
  line's real length before the UTF-16 conversion avoids that class of anchor.

## Consequences

- Every existing single-line call site (`review.lua:M.comment`, tests) sees the
  anchor shape grow two fields (`line_end` in #61, then `col_start`/`col_end` in
  #62) — a breaking shape change to `anchor.resolve`'s return value, not additive.
- `signs.lua`, `threads.lua`, `resolved_threads.lua` need **no changes** — ADR-0002
  already built them range-native to handle threads created via the ADO web UI. They
  render per-line only; posted column precision has no visible effect there yet
  (sub-line highlighting in this plugin's own diff view is out of scope for #51).
- Because ADO does not validate offset against line content (see Context), a bug in
  the byte→codepoint conversion fails silently — a thread lands on the wrong
  character with no API error. The conversion needs its own test coverage; ADO will
  not catch it.
- Two throwaway commits were pushed to and reverted from a real PR's branch
  (`feature/758920-keyvault-post-deploy-job`, PR 19705) to run the visual spike; four
  scratch comment threads were posted and closed. No lasting change to that PR.

## Alternatives considered

- **Keep single-line `anchor.current()`, add a separate range function** — rejected:
  two anchor shapes for `az.lua`/`review.lua` to branch on, instead of one shape the
  read path already uses.
- **Whole-line ranges only, defer column/character offsets** — considered as the
  lower-risk default (no offset-semantics research needed), but rejected *as a scope
  decision* once the live spike confirmed offset semantics cheaply and conclusively;
  deferring indefinitely would have discarded a mostly-free capability out of
  untested caution. Rejecting it means columns are committed design, not that they
  ship with the line-range work — sequencing stays #61 first, #62 after.
- **Detect visual mode at call time instead of `-range`** — rejected: functionally
  identical to `-range` (both ultimately read the `'<`/`'>` marks), just implicit
  instead of declared in the command's opts table.
