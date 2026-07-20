# ado-pr.nvim

Review **Azure DevOps** pull requests from Neovim — the gap `octo.nvim` leaves (it's GitHub-only).

> **Status: MVP scaffold.** Pick / checkout / diff active PRs and set a vote work through the `az`
> CLI; inline comment threads are stubbed. Not published.

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

Run these from a **dedicated detached `review` worktree** — `az repos pr checkout` needs a clean tree
and fails if the PR's branch already has a worktree. See the review-worktree workflow.

## Architecture

```
lua/ado-pr/
  init.lua     setup() + lazy accessors
  config.lua   user config (org/project/repo/base_branch)
  az.lua       az CLI + `az devops invoke` glue (reads, checkout, vote; threads = TODO)
  review.lua   checkout → DiffviewOpen base...HEAD
  picker.lua   fzf-lua active-PR picker
plugin/ado-pr.lua  user commands
```

## Roadmap (MVP → parity)

1. **[done] Read/checkout/diff/vote** via `az`.
2. **[next] Inline comment threads** — `az devops invoke --resource pullRequestThreads` POST; map the
   diffview cursor to `(filePath, line, side)`. See `az.lua` `post_thread` TODO.
3. Show existing threads as virtual text / signs in the diff buffers.
4. Live refresh, reviewers, status checks.

The hard part is step 2/3: anchoring threads onto diffview buffers. See the **cobalt** project
(`E:\Personal Projects\cobalt`, a vim-flavored ADO TUI that already does client-side PR review) and its
"the cursor's file and the displayed file are different things" gotcha before implementing — anchor on
the *displayed* diff path, never the file-tree cursor.

## Related

- [cobalt](https://github.com/jinyeow/cobalt) — vim-flavored ADO TUI (work items + PRs) — sibling project, same domain.
