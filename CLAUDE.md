# ado-pr.nvim — repo instructions

## Agent skills

Configuration for the spec → design → tickets → implement workflow. Read by
`to-spec`, `to-hld`, `to-tickets`, `triage`, and `wayfinder`.

### Output locations

| Artifact | Location |
| --- | --- |
| Specs | `docs/specs/` |
| High-level designs | `docs/design/` |
| Tickets | GitHub Issues (see below) |

### Issue tracker

GitHub Issues on `jinyeow/ado-pr.nvim`. Create and query with the `gh` CLI
(`gh issue create`, `gh issue list`). External pull requests are a triage
surface: `triage` may assess incoming PRs alongside issues.

### Label vocabulary

| Canonical state | Label |
| --- | --- |
| Spec complete, ready to break into tickets | `spec-ready` |
| HLD complete/approved | `design-ready` |
| Ticket assessed & scoped | `triaged` |
| AFK ticket — an agent may grab & implement | `ready` |
| Blocked awaiting clarification | `needs-info` |
| Will not be actioned | `wontfix` |

All exist on the repo. `wontfix` is GitHub's default label, reused as-is.

### Domain-doc layout

Single-context. Architecture decisions live in `docs/adr/` **in this repo** —
that is the canonical home; the project brain
(`E:\Personal Projects\brain\initiatives\ado-pr-nvim\`) keeps volatile status
and cross-repo context only and links to these ADRs rather than restating them.

`CONTEXT.md` is not written yet; until it is, `README.md` carries the
architecture map and the domain vocabulary (PR, thread, anchor, side, vote).

### Wayfinding operations

`wayfinder` charts investigation maps as GitHub Issues:

- **Map issue** — labelled `wayfinder:map`; its tickets are its **sub-issues**.
  Attach one with `gh issue edit <ticket> --parent <map>` (or
  `gh issue edit <map> --add-sub-issue <ticket>`).
- **Ticket types** — `wayfinder:research` / `wayfinder:prototype` /
  `wayfinder:grilling` / `wayfinder:task`.
- **Blocking** — GitHub's native issue dependency link:
  `gh issue edit <ticket> --add-blocked-by <other>`. Needs `gh` 2.96+.
- **Frontier query** — the open, unblocked, unclaimed tickets:

  ```
  gh issue list --state open --label ready \
    --json number,title,assignees,labels,blockedBy \
    --jq '.[] | select(.assignees|length==0) | select(any(.labels[]; .name=="needs-info")|not) | select(any(.blockedBy.nodes[]; .state=="OPEN")|not) | "\(.number)\t\(.title)"'
  ```

  Filtering in `--jq` rather than `--search` is deliberate: `--search` goes
  through GitHub's search index, which lags a few seconds behind a label or
  assignee edit and will show a just-claimed ticket as still takeable.
- **Claim** — `gh issue edit <n> --add-assignee @me` before any work starts.

The `wayfinder:*` labels are **not created yet** — create them on first use.
