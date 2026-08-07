# ado-pr.nvim

Review Azure DevOps pull requests from Neovim. This glossary covers terms specific
to this plugin's domain; general architecture and setup live in `README.md`.

## Language

**Diff base**:
The commit a PR's Full-PR-view diff is computed against. Resolved by default from
the PR's real `targetRefName` in ADO (never a local/stale ref), but can be
overridden per-PR to any git ref (branch, tag, commit SHA) for local visualization
only — an override never touches the PR's actual record in ADO, and can desync
thread/comment positions from ADO's canonical diff while active.
_Avoid_: base branch, target (ambiguous with PR target, below)

**PR target**:
The branch a pull request is actually opened against in Azure DevOps
(`targetRefName` on the PR payload). Changing it is a write to the PR's real
record in ADO — a distinct, heavier operation from overriding the diff base (see
[#50](https://github.com/jinyeow/ado-pr.nvim/issues/50)).
_Avoid_: target branch (when meaning diff base instead)

**Iteration**:
One push to a PR's source branch, as ADO numbers it (1-based; "iteration 0" is the
merge-base commit between source and target, never returned by the API).
Browsing an iteration diffs it against the previous iteration's source commit —
"what did this one push change" — independent of the diff base, which applies to
the Full PR view only.
_Avoid_: push, revision
