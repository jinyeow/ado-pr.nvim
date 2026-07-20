# ado-pr.nvim

Review **Azure DevOps** pull requests from Neovim — the gap `octo.nvim` leaves (it's GitHub-only).

> **Status: MVP.** Pick / checkout / diff active PRs, set a vote, and post inline comment threads
> through the `az` CLI. Not yet smoke-tested against a live PR; not published.

## Why

Azure DevOps has no Neovim PR plugin. `octo.nvim` is GitHub-only; `diffview.nvim` shows any diff but
knows nothing about PRs (threads, votes, reviewers). This is the thin ADO layer on top of diffview.

## Requirements

- Neovim 0.10+ (`vim.system`)
- [`az` CLI](https://learn.microsoft.com/cli/azure/) + `az extension add --name azure-devops`, logged in via `az login`
- [`fzf-lua`](https://github.com/ibhagwan/fzf-lua) — PR picker
- [`diffview.nvim`](https://github.com/sindrets/diffview.nvim) — diff UI (falls back to vim-fugitive `Git difftool`)

Auth reuses `az login`. **No PAT or secret is stored by this plugin.**

## Setup

```lua
require('ado-pr').setup({
  organization = 'https://dev.azure.com/YourOrg',
  project = 'Your Project',
  repository = 'Your.Repo',
  base_branch = 'origin/main',
})
```

## Commands

| Command | Does |
| --- | --- |
| `:AdoPr` | Pick an active PR (fzf-lua) → checkout + diff |
| `:AdoPrReview <id>` | Checkout PR `<id>` into the current worktree and open its diff |
| `:AdoPrVote <id> <vote>` | `approve` / `approve-with-suggestions` / `wait-for-author` / `reject` / `reset` |
| `:AdoPrComment` | Comment on the diff line under the cursor (right/left side from the focused pane) |

Run these from a **dedicated detached `review` worktree** — `az repos pr checkout` needs a clean tree
and fails if the PR's branch already has a worktree. See the review-worktree workflow.

## Architecture

```
lua/ado-pr/
  init.lua     setup() + lazy accessors
  config.lua   user config (org/project/repo/base_branch)
  az.lua       az CLI + `az devops invoke` glue (reads, checkout, vote, post thread)
  anchor.lua   diffview cursor → (filePath, line, side) ADO thread anchor (pure + adapter)
  state.lua    active-PR context (id/repoId/project) for the review session
  review.lua   checkout → DiffviewOpen base...HEAD; post inline comments
  picker.lua   fzf-lua active-PR picker
plugin/ado-pr.lua  user commands
tests/         headless assert specs (`nvim --headless -l tests/<name>_spec.lua`)
```

## Roadmap (MVP → parity)

1. **[done] Read/checkout/diff/vote** via `az`.
2. **[done] Inline comment threads** — `az devops invoke --resource pullRequestThreads` POST; the
   diffview cursor maps to `(filePath, line, side)` in `anchor.lua`. Needs a live-PR smoke test.
3. **[next]** Show existing threads as virtual text / signs in the diff buffers.
4. Live refresh, reviewers, status checks.

The hard part is step 2/3: anchoring threads onto diffview buffers. Side is taken from the **focused
diff pane** (right = new, left = old), and the path from diffview's `cur_entry` — the *displayed* diff
file, never the file-tree cursor (the **cobalt** gotcha: "the cursor's file and the displayed file are
different things"). See `E:\Personal Projects\cobalt`, a vim-flavored ADO TUI whose tested client the
thread-body shape here mirrors.

## Related

- [cobalt](https://github.com/jinyeow/cobalt) — vim-flavored ADO TUI (work items + PRs) — sibling project, same domain.
