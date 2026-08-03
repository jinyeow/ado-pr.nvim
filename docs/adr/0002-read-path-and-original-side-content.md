# ADR-0002 — Reading threads: side is per-query, and the original side comes from REST

- Status: Accepted
- Date: 2026-07-31
- Scope: ado-pr-nvim
- Supersedes: none (extends ADR-0001, which covers the **write** path)

## Context

ADR-0001 maps a cursor to an ADO thread anchor for **posting**. Displaying existing
threads is the inverse, and a live spike against PR !21121 (`prototypes/spike_read_path.lua`,
21 threads, 11 iterations) showed the inverse is not symmetric.

Facts established by that spike, all against the real `az` transport
(`cmd.exe /d /c az.cmd`, the path `az.lua:22` uses):

- `GET` works through `az devops invoke` on `pullRequestThreads` at api-version `7.1` —
  the version `config.lua` already pins. `7.2-preview` also works; `7.2-preview.1` does
  **not**, because the az devops extension strips `-preview` and calls `float()` on the
  remainder (`"7.2.1"` throws). Two-dot preview revisions are unusable through `invoke`.
- `$`-prefixed query parameters survive the `cmd.exe` spawn: passing
  `--query-parameters '$iteration=2' '$baseIteration=1'` changed the response.
- **Without those parameters, no thread carries `trackingCriteria`** (0 of 21). With them,
  3 of 21 do. Tracked positions are opt-in, per call.
- **The side a thread sits on is a function of the queried iteration window.** In the
  plain list all 5 anchored threads had `rightFileStart` and none had `leftFileStart`.
  Queried with `$iteration=2&$baseIteration=1`, the same threads returned `leftFileStart`
  set and `rightFileStart` empty.
- Multi-line spans are common, not exotic: 2 of 5 anchored threads had
  `rightFileEnd.line != rightFileStart.line`.
- System noise dominates: 16 of 21 threads were `commentType: "system"` only.
- `items?path=…&versionDescriptor.version=<sha>&versionDescriptor.versionType=commit&includeContent=true`
  returns the file as JSON with the body in `.content` (13.5 KB confirmed). Adding
  `$format=text` breaks it — `az devops invoke` refuses a non-JSON response without
  `--out-file`.

## Decision

- **The read resolver takes the iteration window as input.** Its signature is
  `(thread, iteration_window) -> { side, line_start, line_end }`, not `(thread) -> line`.
  Side is read from whichever of `leftFileStart` / `rightFileStart` the response populated
  for that window, never assumed. This is the contract the iteration stepper and the
  original-vs-current view are built on.
- **Ranges, not lines.** The resolver returns a start and an end; a single-line thread is
  the degenerate case where they are equal. Sign placement covers the span.
- **Two fetch functions, not one with a mode.** `list_threads(ctx)` for the plain list and
  `list_threads_tracked(ctx, iteration, base_iteration)` for the tracked one, over one
  shared decoder. Flagged deliberately under the "no mode parameters" convention: the two
  calls return materially different data (tracking present or absent) and are used by
  different features, so one function taking a switch would hide that from every caller.
- **api-version stays `7.1`.** It is proven for every call the read path makes. `7.2-preview`
  buys nothing here and preview versions are deprecated 12 weeks after the GA release of the
  same API.
- **System threads are dropped unconditionally** — a thread whose comments are all
  `commentType: "system"` never reaches the renderer.
- **The original-side content comes from the `items` REST endpoint at the iteration's
  commit, never from local git.** The team force-pushes PR branches, so old iteration
  commits are not reliably present in, or fetchable into, the local clone. ADO serves them
  regardless.

## Consequences

- **Two diff renderers in one plugin.** The current diff stays diffview's — that is the
  plugin's whole leverage (ADR-0001). The original-vs-current view cannot be: its left side
  is content that exists only as a REST response. It is a scratch buffer plus `diffthis`.
  A reader who assumes diffview owns both diffs will be wrong; that is the cost of surviving
  force-pushes, accepted deliberately.
- The read path cannot reuse `anchor.resolve`. That function derives side from the focused
  window, which is correct for writing and meaningless for reading.
- Fetching tracked positions costs a second API call when the user opens the archaeology
  view. Accepted: it keeps the common case (render signs on the current diff) to one call.
- `trackingCriteria.origFilePath` is authoritative for the original side of a renamed file,
  so renames need no client-side reconstruction.

## Alternatives considered

- **Reuse `anchor.resolve` inverted** — rejected: side-by-focused-window has no meaning when
  placing a thread that already knows its own side.
- **`git fetch` the iteration commits and diff locally** — rejected: force-pushed branches
  make those commits unreachable, and the fallback would be the REST path anyway. One path,
  always REST.
- **A single `list_threads(ctx, opts)` with optional iteration fields** — rejected under the
  no-mode-parameters convention; see Decision.
- **Pin `7.2-preview`** — rejected: works, but buys no field the read path uses, and preview
  versions carry a deprecation clock.
