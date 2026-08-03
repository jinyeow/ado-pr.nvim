# Spec — reading PR comment threads in the diff

Covers README roadmap step 3. The slicing and the module shape live in
[the design](../design/pr-comment-threads.md); the evidence behind the decisions is in
[ADR-0002](../adr/0002-read-path-and-original-side-content.md). This document owns the
problem, the user stories, and the testing and scope boundaries.

## Problem Statement

I review Azure DevOps pull requests from Neovim. `ado-pr.nvim` already gets me the diff and
lets me post a comment on the line under my cursor — but it shows me nothing that is already
there. Every existing comment thread is invisible.

So a review that involves any conversation forces me back into the browser: to see what a
reviewer asked, to check whether a point I raised was addressed, to see whether a thread is
still active or has been resolved. And once I am in the browser I stay there, because the web
UI is where the whole conversation is. The plugin only wins on the first pass of a PR nobody
has commented on yet.

The browser also answers a question the plugin cannot even ask: **what did the code look like
when this comment was written?** A comment on line 77 of iteration 1 may sit on line 92 of
iteration 4, against code that has since been rewritten. Reading the remark without the code
it was aimed at is guesswork, and ADO's overview tab exists precisely because that guesswork
is unacceptable.

## Solution

Comment threads become part of the diff.

Opening a PR fetches its threads and marks them in the gutter with the plugin's own signs —
quiet enough that the code still reads normally, distinct enough that I notice them, and
visibly different for active versus resolved. System-generated noise (branch pushes, votes,
policy results, reviewer changes) never appears; on a real PR that is three quarters of the
payload.

A pane below the diff follows my cursor and shows the thread I am on — every comment, author,
date and status — and closes on a key when I want the height back. Where threads overlap, one
shows at a time with the count visible, so nothing is ever silently hidden. `]t` and `[t` walk
me between threads.

Stepping through iterations mirrors ADO's Updates dropdown: pick a window and the diff and the
signs both move to it.

And for a thread that carries tracking data, one key opens the archaeology view — the file as
it was when the comment was written on the left, the current file on the right, and the thread
anchored in **both**. That is the browser's last remaining advantage, and it closes it.

Read-only. Replying and resolving are the next step, not this one.

## User Stories

1. As a reviewer, I want existing comment threads marked in the diff I am reading, so that I
   know a line has been discussed without leaving Neovim.
2. As a reviewer, I want those marks in a plugin-owned sign group rather than as LSP
   diagnostics, so that PR comments never pollute my diagnostic counts or my quickfix list.
3. As a reviewer, I want system-generated threads hidden, so that ten "branch was updated"
   entries do not bury the four remarks a human actually made.
4. As a reviewer, I want a thread that spans several lines marked across its whole span, so
   that I can see what the comment is actually about and not just where it starts.
5. As a reviewer, I want active and resolved threads to look different at a glance, so that I
   can skip settled conversations and focus on the open ones.
6. As a reviewer, I want resolved threads visible rather than hidden by default, so that I can
   still see that a line was discussed and what the outcome was.
7. As a reviewer, I want to read the full thread under my cursor — every comment, its author,
   its date, and the thread's status — so that I can follow the argument without opening the
   browser.
8. As a reviewer, I want the thread to follow my cursor as I move through the diff, so that
   reading conversation costs me no keystrokes while I am scanning.
9. As a reviewer, I want to dismiss the thread pane and bring it back on a key, so that I can
   reclaim the height when I want to read code uninterrupted.
10. As a reviewer, I want exactly one thread shown when several overlap, so that the display
    stays legible where a broad thread contains narrower ones.
11. As a reviewer, I want to see how many threads cover the line I am on, so that I know a
    second conversation exists even though only one is displayed.
12. As a reviewer, I want to cycle through the overlapping threads on a line, so that reading
    all of them is a repeated keypress and not a detour.
13. As a reviewer, I want to pick from a list when several threads overlap, so that I can jump
    straight to the one I mean instead of cycling past the others.
14. As a reviewer, I want to jump to the next and previous thread in the file, so that I can
    work through the review comment by comment rather than by scrolling.
15. As a reviewer, I want the default keymaps to be single-key and scoped to the diff buffers,
    so that reading a review does not feel sluggish behind a leader-key timeout and my normal
    mappings are untouched elsewhere.
16. As a reviewer, I want every keymap configurable, so that the plugin's defaults do not
    collide with the ones I already have.
17. As a reviewer, I want to step through a PR's iterations the way ADO's Updates dropdown
    does, so that I can review one push at a time instead of the whole PR at once.
18. As a reviewer, I want the signs to re-anchor when I change iteration window, so that the
    threads I see always belong to the diff I am looking at.
19. As a reviewer, I want to open the diff a comment was written against next to the current
    diff, so that I can judge a remark about code that has since changed.
20. As a reviewer, I want the thread anchored in both the original and the current side of that
    view, so that I can see where the comment landed then and where it lives now.
21. As a reviewer, I want that view to take over my diff splits or open in its own tab, so that
    my review layout is not fragmented across panes I did not ask for.
22. As a reviewer, I want to step iterations inside that view without losing the thread, so
    that I can watch the code evolve around one specific remark.
23. As a reviewer, I want a plain explanation when a thread carries no tracking data, so that I
    understand the view is unavailable rather than broken.
24. As a reviewer, I want PR-level comments (those attached to no file) surfaced as a count
    when I open the PR, so that I know general discussion exists even though it has no line to
    live on.
25. As a reviewer, I want threads on renamed files to land correctly, so that a rename does not
    silently drop the review conversation about that file.
26. As a reviewer, I want a thread whose line no longer exists to be clamped into the buffer
    rather than throwing, so that one stale anchor cannot break the whole display.
27. As a reviewer, I want the whole feature to reuse my `az login` session, so that reading a
    review needs no new token and stores no secret.

## Implementation Decisions

The module shape and the resolver contract below were settled during the design grilling and
are recorded in ADR-0002; this section restates the decisions, not the file layout.

- **The Azure DevOps transport gains four read calls**: list a PR's threads plainly; list them
  under a given iteration window; enumerate the PR's iterations; and fetch a file's content at
  an arbitrary commit. All go through the existing `az devops invoke` path and the existing
  `az login` session.

- **Two thread-fetch operations, not one with a mode switch.** The plain list and the
  iteration-tracked list return materially different data and serve different features, so a
  single call taking a switch would hide that from every caller. Deliberately flagged against
  the repo's no-mode-parameters convention and accepted (ADR-0002); both share one decoder.

- **A new pure module owns filtering and the read resolver.** It takes primitives in and
  returns primitives out: no Neovim API, no network, no diffview. It is the tested core, in
  the same split the existing anchoring module already uses.

- **The read resolver takes the iteration window as an input.** The side a thread sits on is a
  property of the query, not of the thread — the same threads that report a right-side anchor
  in the plain list report a left-side anchor when fetched with an iteration window. Its
  shape, taken from the design and confirmed by the live spike:

  ```
  resolve(thread, window) -> { side = 'left'|'right', line_start, line_end }
  ```

  `window` is `nil` for the plain list, or an iteration and base iteration for a tracked
  fetch. Getting this signature right at the start is what stops iteration stepping and the
  archaeology view from forcing a rewrite of the sign renderer.

- **Ranges, never single lines.** The resolver always returns a start and an end; a one-line
  thread is the degenerate case where they are equal. Multi-line spans were common on the PR
  the spike measured, so this is not an edge case.

- **The read path does not reuse the existing write-path anchor resolver.** That one derives
  the side from which pane has focus, which is correct for posting and meaningless for
  displaying a thread that already knows its own side.

- **System threads are dropped unconditionally.** A thread whose comments are all
  system-generated never reaches the renderer. On the PR the spike measured, that removed 16
  of 21 threads.

- **Bespoke signs, not `vim.diagnostic`.** A plugin-owned sign group, so PR comments stay out
  of diagnostic counts, out of the quickfix list, and out of every statusline that counts
  diagnostics. Resolved and active threads render with distinct markers.

- **The thread body is a follower pane, and only a follower pane.** A split below the diff that
  tracks the cursor, closes on a key, and reopens on the same key. The on-demand float that
  the prototype also built is deliberately deferred: it read fine, but two ways to show one
  thread is two things to maintain and configure.

- **Overlapping threads resolve to exactly one, with the count always visible.** The prototype
  proved stacking illegible. The rule, taken from the prototype:

  ```
  narrowest thread covering the cursor wins
  same key pressed again on the same line -> advance to the next covering thread
  a second key -> pick from the covering threads instead of cycling
  the display always states which of how many is shown
  ```

  Both affordances ship; cycling is the default path and picking is the escape hatch.

- **Resolved threads are shown, not hidden.** Distinct markers carry enough signal on their
  own; hiding them would lose the fact that a line was discussed at all.

- **Default maps are single-key and buffer-local to the diff.** The prototype surfaced that
  two-key leader sequences read as sluggish under a short `timeoutlen`. Buffer-local scoping
  keeps single-key defaults from colliding with anything outside the diff. All are
  user-configurable.

- **The original side's content comes from the Azure DevOps REST API at the iteration's commit,
  never from local git.** PR branches get force-pushed on this team, so old iteration commits
  are not reliably present in or fetchable into the local clone. The API serves them
  regardless (ADR-0002).

- **This produces two diff renderers in one plugin, accepted deliberately.** The current diff
  stays diffview's — that is the plugin's whole leverage. The archaeology view cannot be,
  because its left side is content that exists only as an API response; it is scratch buffers
  plus `diffthis`. The cost of surviving force-pushes.

- **The API version stays where it is pinned.** Proven against every call the read path makes;
  preview versions buy nothing here. ADR-0002 records why.

- **Signs re-apply when diffview reuses a buffer.** Diffview swaps content into existing
  buffers as the user moves between files, so placement hooks onto its buffer-enter event
  rather than running once at open.

## Testing Decisions

**What a good test is here**: it calls the pure resolver or filter with a thread payload and a
window, and asserts on the table that comes back. It does not assert that an extmark was
placed, does not assert which API arguments were built, and does not reach into diffview. If
the behaviour is visible in a return value, the return value is the assertion — mock-invocation
checks are reserved for behaviour that has no return, which this core does not have.

**Prior art**: `tests/anchor_spec.lua` is the model, and the new tests should be a sibling in
exactly its shape — no test framework (plenary is not a dependency), a local `ok`/`eq` harness
over `vim.deep_equal`, `package.path` prefixed to reach `lua/`, run headless with
`nvim --headless -l tests/<name>_spec.lua`. `tests/post_thread_spec.lua` is the second example.

**What gets tested**: the pure module only — filtering and the resolver. Cases to cover, each
drawn from something the spike or the fixtures actually showed:

- right-side anchor from a plain fetch, left-side anchor from a tracked fetch of the same
  thread — the per-query-side rule, which is the contract everything depends on
- single-line and multi-line spans
- path normalisation between the API's leading-slash forward-slash form and diffview's
  repo-relative form
- renamed files, where the original path is authoritative for the old side
- added and deleted files, where one side is absent
- a line past the end of the buffer — clamped, never an error
- a thread with no file context at all — recognised as PR-level, not mis-anchored
- system-only threads filtered out; a thread mixing system and human comments retained
- the overlap-selection rule: narrowest covering thread first, and the cycle order

**What is not unit-tested, and why**: the sign adapter and the UI are thin wrappers over
diffview internals and Neovim's window API. They have no seam worth mocking — a test would
assert the mock. They are validated by smoke test against a live PR, and that limit is
accepted rather than papered over with tests that check their own doubles.

Fixture data for the tests should keep the shape the prototype fixtures established: threads
mostly system noise, human threads clustered in one file, spans that overlap, and only some
threads carrying tracking data.

## Out of Scope

- **Replying to a thread.** Read-only for this pass. It becomes its own ticket once anchoring
  is proven against live PRs.
- **Resolving or changing a thread's status.** Same reason.
- **Live refresh.** Threads are fetched when the PR opens and when the iteration window
  changes. No polling, no websocket, no background refresh.
- **The on-demand float.** Built in the prototype, read fine, deliberately not shipped — one
  way to show a thread rather than two. Revisit only if the follower pane's permanent height
  turns out to hurt in real use.
- **Hiding resolved threads.** The distinct markers were judged sufficient; a hide toggle is
  configuration nobody has asked for yet.
- **A persistent thread-list panel.** The prototype's third variant. Rejected on the reading
  experience — a permanent side panel is not how this should read.
- **Reactions, attachments, and comment editing.**
- **Threads on files outside the diff.** If a file is not in the current diff scope, its
  threads are not rendered.

## Further Notes

- The four slices in the design document are independently shippable and nothing is blocked —
  the spike cleared every API question before this spec was written.
- The prototype directory is throwaway. Its verdict is now folded into the design and this
  spec; it should be deleted once the first slice lands.
- The existing write-path anchor resolver assumes a two-window diff layout and would fail on
  diffview's single-window unified layouts. That is a pre-existing write-path defect, not part
  of this work — the read path does not use that resolver — but it is worth its own ticket.
