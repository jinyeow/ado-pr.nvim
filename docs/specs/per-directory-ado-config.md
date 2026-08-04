## Problem Statement

`ado-pr.nvim` requires `organization`/`project`/`repository` to be set explicitly in `setup()`. For a
reviewer who works across multiple ADO repos from the same Neovim session (opening different
directories over time, or via `:cd`), that single global config can't point at more than one repo at
once — it has to be hand-edited every time the reviewer switches which repo they're reviewing.

## Solution

When `organization`/`project`/`repository` aren't set for the current repo, the plugin auto-detects
them from the current repo's ADO git remote URL instead of requiring them in `setup()`. A session-only
command override is available for the rare case auto-detection is wrong or ambiguous.

## User Stories

1. As a reviewer working across several ADO repos in one Neovim session, I want the org/project/repo
   to be picked up automatically from whichever repo I'm in, so that I don't maintain per-repo config
   by hand.
2. As a reviewer in a repo with an unparsable or non-ADO `origin` remote, I want a clear error telling
   me detection failed and how to override it, rather than a confusing downstream `az` failure.
3. As a reviewer in a repo with multiple remotes where more than one looks ADO-shaped, I want the
   plugin to refuse to guess and tell me it's ambiguous, so that I never post a comment to the wrong
   project by accident.
4. As a reviewer who needs to point at a different ADO project than the one auto-detected (e.g. a
   fork, or a repo whose remote doesn't reflect where PRs actually live), I want a command to override
   the detected values for the current session, so that I'm not blocked waiting on a config change.

## Implementation Decisions

- **Auto-detection is the default**, replacing the requirement to set `organization`/`project`/
  `repository` in `setup()`. It runs lazily — on the first PR-related command in a session for that
  repo — rather than eagerly at directory-open, so a repo the user never runs `:AdoPr` in never pays
  the cost or risks a spurious error.
- **Detection order**: parse the `origin` remote's URL first. If `origin` doesn't parse as an ADO URL
  (or doesn't exist), scan the repo's other remotes for ADO-shaped URLs. Exactly one match is used.
  Zero matches or more than one match is treated as detection failure — the plugin does not guess
  between multiple candidates.
- **Remote URL parsing** is a pure function covering both the HTTPS form
  (`https://dev.azure.com/<org>/<project>/_git/<repo>`, and the legacy `<org>.visualstudio.com` host)
  and the SSH form (`git@ssh.dev.azure.com:v3/<org>/<project>/<repo>`), returning
  `organization, project, repository` or `nil` plus a reason on no match.
- **Explicit config still wins**: any of `organization`/`project`/`repository` set via `setup()`
  is used as-is and skips auto-detection for that field — `setup()` config is the top of the
  precedence order, ahead of both the command override and auto-detection, since it's the most
  deliberate/explicit source.
- **Session-only command override**: a new command sets org/project/repository for the current
  Neovim session only (in-memory), taking precedence over auto-detection but not over an explicit
  `setup()` value for the same field. It does not persist to disk — no config file is written.
  Precedence, most-explicit-and-most-recent wins: `setup()` explicit value > command override >
  auto-detection.
- **No new config file format is introduced.** A per-repo persistent override, if ever needed, is a
  `setup()`-style table keyed by path or remote pattern (kept in the user's own Lua config) or a
  `vim.json.decode`-backed JSON file — not YAML, since Neovim has no builtin YAML parser and the
  ecosystem convention (fugitive, gitlab.nvim, octo.nvim) is to derive context from git remotes
  rather than invent a bespoke per-repo config file. This spec does not build that file-based path;
  it's noted here only to close off YAML as a future direction.
- **Detection failure surfaces a `vim.notify` ERROR** naming what was tried (which remotes were
  checked, and why each was rejected — not ADO-shaped, or ambiguous) and how to override via the new
  command, matching this codebase's fail-loud convention rather than silently falling through to a
  downstream `az` error.

## Testing Decisions

- The remote-URL parser is a pure function and is fully unit-tested against both URL forms, the
  legacy `.visualstudio.com` host, malformed/non-ADO URLs, and the SSH form — no git invocation
  needed for these cases.
- The detection-order function (given a list of `(remote name, url)` pairs, return the detected
  triple or a structured failure reason) is pure and unit-tested: `origin` matches, `origin` fails but
  exactly one other remote matches, zero matches, and multiple matches (ambiguous).
- The precedence-resolution function (`setup()` value, session override, detected value → effective
  value) is pure and unit-tested for all combinations.
- Reading actual git remotes (`git remote -v` or equivalent) is a thin adapter, smoke-tested only,
  consistent with how this codebase treats other git/`az` shell-outs.

## Out of Scope

- A persistent per-repo config file (YAML, JSON, or otherwise) — deferred until the session-only
  command override proves insufficient in practice.
- Auto-detecting or switching config based on anything other than git remotes (e.g. directory-name
  heuristics).
- Multi-remote repos where more than one remote is ADO-shaped and genuinely both valid — handled as
  a hard "ambiguous" failure requiring the override command, not a preference/priority list between
  candidate remotes.

## Further Notes

- This spec is independent of the checkout-routing work in `pr-checkout-robustness.md` — different
  module (`config.lua` plus a new remote-parsing function) and no shared code path, so the two can be
  ticketed and implemented in either order or in parallel.
