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

## Before Running

### 1. Ensure program reports exist

The dashboard reads from report files produced by other programs. At minimum one of:
- `$REPORTS_DIR/link-scan/latest.json` (from link-health scanner)
- `$REPORTS_DIR/dep-bump/latest.json` (from dep-bump scanner)

### 2. Set environment variables

```bash
export REPORTS_DIR=~/reports          # base dir containing link-scan/ and dep-bump/ subdirs
export KAGENTI_DIR=~/my-org/main-repo # path to org's main repo clone (for live mode)
```

## Running the Dashboard

**Always run with `--dry-run` first:**

```bash
bash scripts/automation-health-dashboard.sh --dry-run
```

This generates the dashboard markdown and prints it to stdout without pushing.

**Live run (commits and pushes to fork PR):**

```bash
bash scripts/automation-health-dashboard.sh --live --org <org>
```

## Dashboard Sections

- **Executive Summary** — total issues created/resolved, PRs opened, estimated hours saved
- **Link Health** — broken links by type, trend table, cumulative issues
- **Dependency Bumps** — stale PRs by tier, SLA compliance, median TTM, coverage
- **PR Review Bot** — clawgenti reviews (cumulative), queue depth, and median time-to-merge (hours) before vs. after each repo's own activation; reviewed-vs-unreviewed shown as secondary context
- **Cross-Program Coverage** — which repos are under which programs
- **Cron Health** — job schedules and last run status

## Graceful Degradation

If only one program's reports are available, the dashboard generates with partial data. Missing sections show placeholder values.

## Known Limitations (v1)

1. Report directory layout is hardcoded (expects `link-scan/` and `dep-bump/` subdirs)
2. Fork owner and target repo default to clawgenti/kagenti (configurable via CLI)
3. Cron health table has static entries (does not read from jobs.json)
4. Three programs assumed (link-health, dep-bump, pr-review); no dynamic discovery
5. Hours-saved heuristic is fixed at 15 min/issue
6. PR-review impact uses a marker-based reviewed flag (`<!-- reviewed: -->` in the review body); the before/after split is per repo, derived from the earliest reviewed PR in that repo (no hardcoded date)
7. TTM is reported in median hours (PRs here merge in hours, so days would round to 0); reviewed-vs-unreviewed is selection-biased (`ready-for-ai-review` marks substantive PRs), so before/after-activation is the headline impact measure
8. Review counts are cumulative from fixer-history.json; the live queue is from latest.json

A future iteration will introduce plugin-style program discovery.

## Safety

- The dashboard is read-only — it does not modify program reports or create issues
- `--dry-run` is the default mode
- Live mode only writes to `docs/automation-health.md` via a standing fork-based PR
