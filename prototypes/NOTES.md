# Prototype — PR comment threads in the diff

**Throwaway.** Delete this directory once the verdict below is filled in and folded into the
design (`docs/design/pr-comment-threads.md`).

## Question

How should Azure DevOps PR comment threads read inside a diff — and how should "the diff as it
was when the comment was made" read next to the current diff?

## Run

```
nvim -c "luafile prototypes/threads_ui_prototype.lua"
```

Opens `DiffviewOpen HEAD~3...HEAD` on this repo. **Select `lua/ado-pr/az.lua` in the file
panel** — that is where every fixture thread is anchored.

| Key | Does |
| --- | --- |
| `<F8>` | cycle variant A → B → C |
| `]t` / `[t` | next / previous thread |
| `<leader>ct` | show the thread here; pressed again on the same line, cycle to the next overlapping one. In variant B it also reopens the pane after `q` |
| `<leader>cT` | pick between overlapping threads (`vim.ui.select`) instead of cycling |
| `q` | (variant B) close the thread pane |
| `<F9>` | original-vs-current view for the thread under the cursor |
| `[i` / `]i` | step iterations inside that view |
| `q` | close the original-vs-current tab |

## Fixtures

`fixtures_threads.lua` mirrors the *structure* of a real PR (!21121) pulled by
`spike_read_path.lua`; authors and comment text are invented. What it preserves:

- 16 of 21 threads are system noise (RefUpdate ×10, VoteUpdate ×2, AutoCompleteUpdate ×2,
  PolicyStatusUpdate, ReviewersUpdate) — the renderer drops all of them
- all 5 human threads sit in one file; real reviews cluster
- threads are 2–4 comments deep, 15–400 characters each, up to 3 participants
- thread 97122 spans lines 62–84 and **contains** threads 96937 (77) and 96938 (82–83).
  Overlapping threads are normal, not an edge case.
- 3 of 5 carry `trackingCriteria`, so `<F9>` works on those and reports honestly on the rest

## Walkthrough

1. **Read the code with comments present.** Open `az.lua`, scroll the whole file in each
   variant. The question is not "can I find the threads" — it is whether the code is still
   readable while they are on screen. Variant B costs you 14 lines of height permanently;
   variant C costs 52 columns.
2. **Land on line 77.** Two threads overlap there (the 62–84 span plus the one anchored at
   77). Only the narrowest opens; `<leader>ct` again cycles, `<leader>cT` picks. Does
   cycling or picking feel right?
3. **Walk `]t` from the top of the file.** Five stops. Does the ordering feel right when one
   thread contains another?
4. **Compare a resolved thread (`○`, lines 19 and 109) with an active one (`●`, 62–84 and
   82–83).** Enough signal, or should resolved threads be hidden by default?
5. **Press `<F9>` on line 19, 77 or 82.** Original iteration on the left, current on the
   right, thread signed in both. `[i` / `]i` step iterations (fixtures exist for 1 and 2).
   Does taking over the two splits lose you context you needed?
6. **Press `<F9>` on line 62 or 109.** Those threads have no tracking data — the message
   explains why. Is that honest enough, or should untracked threads not offer the view at all?

## Decisions already made (not up for the prototype to relitigate)

See `docs/adr/0002-read-path-and-original-side-content.md`. In short: bespoke signs rather than
`vim.diagnostic`; read-only v1; system threads dropped unconditionally; human PR-level threads
get a count, not an inline home; original-side content comes from ADO's `items` endpoint at the
iteration's commit, never from local git.

## Verdict

**Variant B wins — the follower pane, and only the follower pane.** The on-demand float
(variant A) is deliberately left out of v1; it reads fine, but two ways to show the same
thread is two things to maintain and configure. Revisit only if the pane's permanent 14 lines
turn out to hurt in real use.

- **Variant C is out.** A permanent 52-column list panel is not how this should read.
- **Variant A is out for now** — see above; it stays in this prototype as the record of why.
- **Stacking overlapping threads was illegible.** Replaced with: one thread at a time,
  narrowest covering thread first, `<leader>ct` cycles and `<leader>cT` picks. The float and
  the pane both show `n/total` so a hidden overlapping thread is never silent.
- **Thread ordering** under `]t` / `[t` reads correctly even when one thread contains another.
- **Resolved vs active** (`○` vs `●`) carries enough signal — no need to hide resolved by default.
- **The original-vs-current view works**, and refusing to open it for untracked threads with an
  explanation is honest enough.

Both overlap affordances ship: cycling as the default, the picker alongside it.

One thing the prototype surfaced that is not about layout: two-key `<leader>` sequences feel
sluggish under a short `timeoutlen`. The plugin's default maps should be single-key and
buffer-local to the diff (octo.nvim's `]t` / `[t` shape), with everything user-configurable.
