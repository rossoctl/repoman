---
name: doc-drift-scanner
description: >-
  Scan enrolled repos for documentation drift against a pinned git boundary:
  missing paths, flag/subcommand parity, configured enumerations, retired names,
  version strings, absence claims, and changelog-vs-GitHub-release dates. Creates
  one rollup issue per repo and writes structured JSON reports. Use when docs
  may no longer match the code, or when drafting release notes from merged PRs.
license: Complete terms in LICENSE.txt
---

# Doc Drift Scanner

Scan enrolled repositories for documentation that disagrees with the code at a
pinned git ref. Creates or updates one rollup `[doc-drift]` issue per repo and
writes `latest.json` / `history.json`.

**Run scripts with `--help` first** to see full usage and options. The engine
lives in the RepoMan plugin scripts dir — do not copy it into this skill.

## Prerequisites

- `bash` 3.2+ (works with the macOS system default; no bash-4 features used)
- `python3` 3.8+ (stdlib only; no PyYAML)
- `gh` (GitHub CLI, authenticated with repo access)
- `jq` (JSON processor)
- RepoMan config at `~/.repoman/config.json` with enrolled clones under `repos_dir`

### Requirements (machine-readable)

- pat_scopes: [repo]
- labels_required: []
- labels_applied: [doc-drift]
- programs: [scanner]

## Before Running

### 1. Verify authentication

```bash
gh auth status
```

### 2. Ensure clones are current

Prefer `repoman run repo-sync` (or enable `repo-sync`) so scanners read fresh
trees. The run orchestrator refreshes clones for this program automatically.

### 3. Confirm report location

Reports default to `$HOME/reports/doc-drift`. Override with `REPORTS_DIR`.

## Running the Scanner

Always dry-run first:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/doc-drift-scanner.sh" --dry-run
```

Live run (creates/updates/closes rollup issues):

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/doc-drift-scanner.sh" --issue-limit 5
```

Or via the orchestrator:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/repoman-run.sh" doc-drift --dry-run
```

## Optional per-repo config

Repos may commit `.repoman/doc-drift.yaml` at the boundary ref to opt into
enumeration parity, retired-name denylists, and a custom changelog path. Without
it, only generic checks run (paths, flags, versions, absence claims, release
date/draft when GitHub metadata is supplied).

## Precheck (DAM schedules)

```bash
bash "${CLAUDE_PLUGIN_ROOT}/skills/repoman/scripts/doc-drift-precheck.sh"
```

Exit `1` when the worklist is empty (skip the model turn). Exit `0` and print
`worklist: <path>` when there is work. Any other exit is fail-open.

## Related

- Fixer skill: `doc-drift-fixer`
- Friendly name: **Doc-Drift-Manager** (`doc-drift`)
