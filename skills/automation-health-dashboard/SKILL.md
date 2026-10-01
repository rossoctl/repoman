---
name: automation-health-dashboard
description: >-
  Generate an executive-facing automation health dashboard combining metrics
  from all automation programs (link-health, dep-bump). Produces a markdown
  report showing cumulative impact, trends, coverage, and cron health.
license: Complete terms in LICENSE.txt
---

# Automation Health Dashboard

Generate a unified executive-facing dashboard combining link-health and dep-bump program metrics into `docs/automation-health.md`. Answers "what did automation save us?" with cumulative numbers and trend data.

**Run scripts with `--help` first** to see full usage and options.

## Prerequisites

- `bash` 4+ (macOS ships 3.2; use `brew install bash` for 4+)
- `gh` (GitHub CLI, authenticated with org access)
- `jq` (JSON processor)

### Requirements (machine-readable)

- pat_scopes: [repo]
- labels_required: []
- labels_applied: []
- programs: [dashboard]

## Before Running

### 1. Ensure program reports exist

The dashboard reads from report files produced by other programs. At minimum one of:
- `$REPORTS_DIR/link-health/latest.json` (from link-health scanner)
- `$REPORTS_DIR/dep-bump/latest.json` (from dep-bump scanner)

### 2. Set environment variables

```bash
export REPORTS_DIR=~/reports            # base dir containing link-health/ and dep-bump/ subdirs
export MAIN_REPO_DIR=~/my-org/main-repo # path to the report-target repo clone (overrides the REPOS_DIR-derived default; for live mode)
```

**Note:** the dashboard script calls `repoman_config` unconditionally, so
`~/.repoman/config.json` (with `repos_dir` and `fork_owner` set) is required
even for `--dry-run` runs. This script is no longer standalone the way earlier
versions were.

### 3. Program discovery (how the dashboard knows which sections to render)

The dashboard discovers which programs to render from a `_index.json` program
registry rather than a hardcoded program list. Each scanner registers itself in
the registry after writing its reports, recording its `display_name`,
`report_path`, and `last_run`.

- By default the registry is read from `<reports-dir>/_index.json`. Override it
  with `--index PATH` or the `REPOMAN_INDEX_FILE` environment variable.
- Each registered program's `display_name` becomes its section heading, so the
  heading follows the registry rather than a constant in the script.
- **Disk-derived fallback:** when no registry file exists, the dashboard falls
  back to probing the known report subdirs (`link-health/`, `dep-bump/`)
  directly, so setups that predate the registry keep working unchanged.

## Running the Dashboard

**Always run with `--dry-run` first:**

```bash
bash scripts/automation-health-dashboard.sh --dry-run
```

This generates the dashboard markdown and prints it to stdout without pushing.

To point at a specific registry (otherwise `<reports-dir>/_index.json`):

```bash
bash scripts/automation-health-dashboard.sh --dry-run --index /path/to/_index.json
```

**Live run (commits and pushes to fork PR):**

```bash
bash scripts/automation-health-dashboard.sh --live --main-repo-dir /path/to/automation
```

## Dashboard Sections

- **Executive Summary** — total issues created/resolved, PRs opened, estimated hours saved
- **Link Health** — broken links by type, trend table, cumulative issues
- **Dependency Bumps** — stale PRs by tier, SLA compliance, median TTM, coverage
- **Cross-Program Coverage** — which repos are under which programs
- **Cron Health** — job schedules and last run status

## Graceful Degradation

If only one program's reports are available, the dashboard generates with partial data. A registered program whose `report_path` is missing its `latest.json`/`history.json` is skipped with a note rather than failing the whole run; if no program is renderable at all, the dashboard exits with an error naming the reports it expected.

## Known Limitations (v1)

1. Which programs render is discovered from the `_index.json` registry (with a disk-derived fallback); a program only has a dashboard section if the script also carries an extraction block for it (link-health, dep-bump), so a registry entry for any other id is skipped with a note rather than rendered
2. The report-target repo is hardcoded (`REPORT_TARGET_REPO="rossoctl/automation"`); the fork owner comes from `repoman_config` (`~/.repoman/config.json`), not from a CLI flag — there is no `--org`/`--fork-owner` option
3. Cron health table has static entries (does not read from jobs.json)
4. Hours-saved heuristic is fixed at 15 min/issue

## Safety

- The dashboard is read-only — it does not modify program reports or create issues
- `--dry-run` is the default mode
- Live mode only writes to `docs/automation-health.md` via a standing fork-based PR
