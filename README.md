# ado-pr.nvim

[![CI](https://github.com/jinyeow/ado-pr.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/jinyeow/ado-pr.nvim/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/jinyeow/ado-pr.nvim)](https://github.com/jinyeow/ado-pr.nvim/releases)

Review **Azure DevOps** pull requests from Neovim — the gap `octo.nvim` leaves (it's GitHub-only).

> **Status: MVP, pre-1.0.** Pick / checkout / diff active PRs, set a vote, and post/show inline
> comment threads through the `az` CLI — smoke-tested live against a real org. See
> [CHANGELOG.md](CHANGELOG.md) for release notes; not on a plugin manager registry yet, install
> straight from this repo (see below).

## Why

Azure DevOps has no Neovim PR plugin. `octo.nvim` is GitHub-only; `diffview.nvim` shows any diff but
knows nothing about PRs (threads, votes, reviewers). This is the thin ADO layer on top of diffview.

## Requirements

- Neovim 0.10+ (`vim.system`)
- [`az` CLI](https://learn.microsoft.com/cli/azure/) + `az extension add --name azure-devops`, logged in via `az login`
- [`fzf-lua`](https://github.com/ibhagwan/fzf-lua) — PR picker
- [`diffview-plus.nvim`](https://github.com/dlyongemallo/diffview-plus.nvim) — diff UI (falls back to
  vim-fugitive `Git difftool`). The maintained fork of `sindrets/diffview.nvim`, which has had no
  commits since 2024-06. Same `diffview.*` module namespace, so upstream works too — but the fork is
  what this plugin is developed against.

Auth reuses `az login`. **No PAT or secret is stored by this plugin.**

## Setup

`organization`/`project`/`repository` are optional — when unset, they're auto-detected from
the current repo's ADO git remote (`origin` first, falling back to the repo's other remotes;
a zero- or multiple-match repo fails loud with a `vim.notify` ERROR rather than guessing). Set
any of the three explicitly to skip detection for that field, e.g. when the remote doesn't
reflect where PRs actually live. To override detection for the current session only, without
touching your config, use `:AdoPrSetScope` (see Commands):

```lua
require('ado-pr').setup({
  -- organization/project/repository: omit to auto-detect from the git remote, or set
  -- explicitly to override detection --
  -- organization = 'https://dev.azure.com/YourOrg',
  -- project = 'Your Project',
  -- repository = 'Your.Repo',
  keymaps = {
    toggle_thread_pane = '<F8>', -- buffer-local to the diff, single-key by default
    next_thread = ']t',
    prev_thread = '[t',
    show_thread = '<F6>', -- shows the narrowest thread here; pressed again on the same line, cycles
    pick_thread = '<F7>', -- picks a specific thread from every one covering the line (fzf-lua)
  },
})
```

## Commands

| Command | Does |
| --- | --- |
| `:AdoPr` | Pick an active PR (fzf-lua) → checkout + diff |
| `:AdoPrReview <id>` | Checkout PR `<id>` into the current worktree and open its diff |
| `:AdoPrVote <id> <vote>` | `approve` / `approve-with-suggestions` / `wait-for-author` / `reject` / `reset` |
| `:AdoPrComment` | Comment on the diff line under the cursor (right/left side from the focused pane) |
| `:AdoPrIterations` | Browse the PR's iterations (one push at a time), or return to the full-PR view |
| `:AdoPrSetScope <field>=<value>…` | Override the auto-detected `organization`/`project`/`repository` for this Neovim session only (never written to disk); an explicit `setup()` value for a field still wins |
| `:AdoPrShowScope` | Show the effective `organization`/`project`/`repository` and whether each came from `setup()`, the session override, or auto-detection |
| `:AdoPrResetScope [field…]` | Clear the session scope override for the named fields (bare names, e.g. `project repository`), or for all three when given none |
| `:AdoPrSetDiffBase <ref>` | Override the Full-PR-view diff base to any git ref (branch/tag/SHA) — local visualization only, never touches the PR's real ADO target |
| `:AdoPrShowDiffBase` | Show the currently effective diff base, and whether it's an override or the ADO-resolved default |
| `:AdoPrResetDiffBase` | Clear the diff-base override, returning to the ADO-resolved target |

Run these from a **dedicated detached `review` worktree** — `az repos pr checkout` needs a clean tree
and fails if the PR's branch already has a worktree. See the review-worktree workflow.

## Architecture

```
lua/ado-pr/
  init.lua     setup() + lazy accessors
  config.lua   user config (org/project/repo, explicit or auto-detected)
  remote.lua   git remote URL -> org/project/repo (pure parse + detection order; adapter reads `git remote -v`)
  az.lua       az CLI + `az devops invoke` glue (reads, checkout, vote, post thread)
  anchor.lua   diffview cursor → (filePath, line, side) ADO thread anchor (pure + adapter)
  threads.lua  filter + read-resolve ADO PR comment threads (pure: no Neovim API, no network)
  resolved_threads.lua  per-PR resolved-thread collection (path, range) shared by signs.lua + view.lua
  signs.lua    thread markers in diffview's diff buffers, both sides (adapter over resolved_threads.lua + hunks.lua + diffview_state)
  hunks.lua    map an old-side line through a hunk table to its new-buffer row (pure: no Neovim API, no diffview, no git)
  view.lua     thread follower pane: split below the diff, tracks the cursor, ]t/[t (adapter over resolved_threads.lua)
  diffview_state.lua  active diffview view: entry, layout kind, per-side win/buf, inline hunks
  state.lua    active-PR context (id/repoId/project/base) for the review session
  review.lua   checkout → fetch PR target ref → DiffviewOpen target...HEAD; post/sign comment threads
  picker.lua   fzf-lua active-PR picker
plugin/ado-pr.lua  user commands
tests/         headless assert specs (`nvim --headless -l tests/<name>_spec.lua`)
```

## Roadmap (MVP → parity)

1. **[done] Read/checkout/diff/vote** via `az`.
2. **[done] Inline comment threads** — `az devops invoke --resource pullRequestThreads` POST; the
   diffview cursor maps to `(filePath, line, side)` in `anchor.lua`. Needs a live-PR smoke test.
3. **[done] Show existing threads as signs in the diff buffers**, both sides — `●` active / `○`
   resolved, re-applied on diffview's buffer-enter event. Two-window layouts sign the old-side
   window directly; the single-window layouts (`diff1_inline`/`diff1_plain`/`diff1_raw`) map an
   old-side line through a hunk table (`hunks.lua`) to its real row, or count it as not showable
   when the layout has none. Needs a live-PR smoke test.
4. **[done] Thread follower pane** — a split below the diff shows the thread under the cursor;
   `<F8>` toggles it, `]t`/`[t` jump between threads, all buffer-local to the diff and
   user-configurable via `keymaps`. Overlapping threads show the narrowest covering one with a
   visible count; `<F6>` cycles through every thread covering the line (wrapping), `<F7>` picks
   one directly (fzf-lua). Needs a live-PR smoke test.
5. **[done] Iteration browsing** — `:AdoPrIterations` steps through the PR one push at a time
   (diffed against the previous iteration's source commit), or back to the full-PR view.
6. **[done] Diff-base override** — `:AdoPrSetDiffBase <ref>` / `:AdoPrShowDiffBase` /
   `:AdoPrResetDiffBase`, a local-only override of what the full-PR diff is computed against
   (any git ref), independent of iteration browsing.
7. Live refresh, reviewers, status checks.

The hard part is step 2/3: anchoring threads onto diffview buffers. Side is taken from the **focused
diff pane** (right = new, left = old), and the path from diffview's `cur_entry` — the *displayed* diff
file, never the file-tree cursor (the **cobalt** gotcha: "the cursor's file and the displayed file are
different things"). See `E:\Personal Projects\cobalt`, a vim-flavored ADO TUI whose tested client the
thread-body shape here mirrors.

## Releasing

Versioned with [SemVer](https://semver.org/); pre-1.0 (`0.y.z`) means breaking changes can land in a
minor bump. `CHANGELOG.md` is generated from [conventional commit](https://www.conventionalcommits.org/)
messages via [`git-cliff`](https://git-cliff.org/) (config: `cliff.toml`) — write commits normally,
nothing else to maintain day to day.

Cutting a release:

```sh
git-cliff --tag vX.Y.Z -o CHANGELOG.md   # regenerate, review the new section
git add CHANGELOG.md
git commit -m "chore(release): vX.Y.Z"
git tag vX.Y.Z
git push origin main vX.Y.Z
```

Pushing the tag triggers `.github/workflows/release.yml`, which extracts that version's
`CHANGELOG.md` section and publishes it as a GitHub Release. The commit must land before the tag —
the release workflow fails loudly if it can't find a matching `## [X.Y.Z]` section.

## Related

- [cobalt](https://github.com/jinyeow/cobalt) — vim-flavored ADO TUI (work items + PRs) — sibling project, same domain.
