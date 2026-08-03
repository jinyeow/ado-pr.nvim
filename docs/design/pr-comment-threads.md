# Design — reading PR comment threads in the diff

Covers README roadmap step 3 and what grew out of it: showing existing Azure DevOps PR
comment threads in the diff, and reading a comment against the diff it was written on.

Decisions and the evidence behind them are in [ADR-0002](../adr/0002-read-path-and-original-side-content.md);
the write path is [ADR-0001](../adr/0001-thread-anchoring-by-focused-pane.md). This document
is the slicing, not the rationale.

## Shape

```
az.lua        list_threads(ctx)                        -> threads (plain)
              list_threads_tracked(ctx, iter, base)    -> threads (with trackingCriteria)
              list_iterations(ctx)                     -> iterations
              item_content(ctx, path, commit)          -> string

threads.lua   NEW. Pure. Filtering + the read resolver:
                is_renderable(thread)                  -> bool     (drops system-only)
                resolve(thread, window)                -> { side, line_start, line_end }
                original(thread)                       -> { path, line_start, line_end } | nil

signs.lua     NEW. Thin adapter. Places extmarks in diffview's buffers from resolve();
              re-applies on DiffviewDiffBufWinEnter.

view.lua      NEW. The follower pane (thread body) + the archaeology tab.
```

`threads.lua` is the tested core, in the same split `anchor.lua` already uses: primitives in,
primitives out, headless unit tests. `signs.lua` and `view.lua` are untested adapters over
diffview internals and Neovim UI, validated by smoke test.

### The contract everything else depends on

```
resolve(thread, window) -> { side = 'left'|'right', line_start, line_end }
```

`window` is the iteration window the threads were fetched under (`nil` for the plain list,
`{ iteration, base_iteration }` for a tracked fetch). Side comes from whichever of
`leftFileStart` / `rightFileStart` the response populated for that window — it is not a
property of the thread. Getting this signature right up front is what keeps slices 3 and 4
from forcing a rewrite of slice 1.

## Slices

Each is independently usable and independently shippable. Nothing is blocked — the spike
cleared every API question (`prototypes/spike_read_path.lua`, all five probes PASS).

### Slice 1 — threads on the current diff

Fetch, filter, resolve, sign.

- `az.list_threads` + a decoder over the real response shape.
- `threads.is_renderable` drops system-only threads (76% of a real PR's payload).
- `threads.resolve` handles: right/left side per the queried window, multi-line spans
  (40% of real anchored threads), path normalisation (`/`-prefixed, forward slashes) against
  diffview's repo-relative `entry.path`, renames via `oldpath`, missing sides on added and
  deleted files, and a line past end-of-buffer (clamp, never error).
- Bespoke signs — a plugin-owned sign group, **not** `vim.diagnostic`, so PR comments never
  land in LSP diagnostic counts. Resolved threads render distinctly from active ones.
- Human PR-level threads (`threadContext: null`) get a count on open, not an inline home.

Done when: unit tests cover every case above; signs appear against a live PR.

### Slice 2 — the thread body

A **follower pane**: a split below the diff showing the thread under the cursor, updating as
the cursor moves, closed and reopened on a key. Chosen over an on-demand float and over a
persistent thread-list panel (`prototypes/NOTES.md` records why). The float is deliberately
not shipped — one way to show a thread, not two.

Overlapping threads are the normal case (one real thread spanned 23 lines and contained two
others), so exactly one thread shows at a time: the narrowest covering the cursor, with the
count visible (`thread 1/2 here`). Pressing the key again cycles; a separate key opens a
picker. Both affordances ship.

`]t` / `[t` move between threads. Default maps are single-key and buffer-local to the diff —
two-key `<leader>` sequences read as sluggish under a short `timeoutlen` — and all of them
are user-configurable.

Done when: every comment in a thread is readable — author, date, replies, status — reading
one does not disturb the diff, and no overlapping thread is ever silently hidden.

### Slice 3 — iteration browsing

`az.list_iterations` plus a stepper, mirroring ADO's Updates dropdown. Selecting a window
re-fetches with `list_threads_tracked` and re-signs, which is when threads may change side.

Done when: stepping through iterations updates both the diff scope and the signs coherently.

### Slice 4 — original vs current

The archaeology view: a tab that takes over the two diff splits, original iteration content
on the left, current on the right, the thread signed in **both** — current anchor from
`threadContext`, original anchor from `trackingCriteria.origRightFileStart` /
`origLeftFileStart`, original path from `origFilePath`.

Left-hand content comes from `az.item_content` at that iteration's commit. This pane is
scratch buffers plus `diffthis`, not diffview — see ADR-0002.

Done when: opening the view on a tracked thread shows both anchors, and `[i` / `]i` step
iterations without losing the thread.

## Out of scope

Replying to a thread, resolving a thread, and live refresh. v1 is read-only. Reply and
resolve become their own tickets once anchoring is proven against a live PR.

## Open

Nothing. The prototype settled the last two (`prototypes/NOTES.md`): the follower pane wins
slice 2, and resolved threads stay visible — `○` versus `●` carries enough signal that hiding
them by default would lose more than it saves.
