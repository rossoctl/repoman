---
name: doc-drift-fixer
description: >-
  Re-verify doc-drift scanner findings and open mechanical documentation fix
  PRs. Corrections get their own docs: fix PR; additions fold into one rolling
  update/doc-drift PR per repo. Never edits code to match docs, never merges,
  never publishes a GitHub release. Use after a doc-drift scan.
license: Complete terms in LICENSE.txt
---

# Doc Drift Fixer

Re-verify findings from the doc-drift scanner. Applies mechanical documentation
fixes on a fork and opens PRs. Non-mechanical findings stay on the rollup issue
checklist for a human.

**Run scripts with `--help` first.** Engine scripts live under the RepoMan
plugin scripts dir.

## Prerequisites

- `bash` 3.2+
- `python3` 3.8+
- `gh` (authenticated; needs fork create + PR create)
- `jq`
- A prior scanner run that wrote `$HOME/reports/doc-drift/latest.json`
- `fork_owner` set in `~/.repoman/config.json`

### Requirements (machine-readable)

- pat_scopes: [repo]
- labels_required: [doc-drift]
- labels_applied: []
- programs: [fixer]

## Running

Default is dry-run (preview only):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/doc-drift-fixer.sh" --dry-run --issue-limit 5
```

Live (opens PRs):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/doc-drift-fixer.sh" --live
```

## PR shapes

| Finding | Action |
|---------|--------|
| Mechanical correction (unique replacement) | Own PR: `docs: fix …` |
| Mechanical addition (enum gap, release draft) | Single rolling `update/doc-drift` PR per repo |
| Non-mechanical (absence-claim prose, retired name without replacement) | Rollup issue checklist only |
| Release date mismatch | Changelog heading PR only — does **not** edit the published GitHub release |
| Release draft | Rolling PR body includes paste-ready Keep a Changelog markdown |

## Related

- Scanner skill: `doc-drift-scanner`
- Friendly name: **Doc-Drift-Manager** (`doc-drift`)
