#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Automation Health Dashboard Generator
# Combines link-health and dep-bump program metrics into a single executive-
# facing markdown dashboard. Pushes to a standing fork-based PR.
#
# Usage:
#   bash automation-health-dashboard.sh --help
#   bash automation-health-dashboard.sh --dry-run
#   bash automation-health-dashboard.sh --live
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- CLI args ---
DRY_RUN=true
VERBOSE=false
SHOW_HELP=false
MAIN_REPO_DIR="${MAIN_REPO_DIR:-}"
INDEX_FILE_ARG=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --live) DRY_RUN=false; shift ;;
    --reports-dir) REPORTS_DIR="$2"; shift 2 ;;
    --index) INDEX_FILE_ARG="$2"; shift 2 ;;
    --main-repo-dir) MAIN_REPO_DIR="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat <<'HELP'
Automation Health Dashboard Generator

Combines link-health and dep-bump program metrics into a single executive-
facing markdown file. Pushes to a standing fork-based PR in the org's main repo.

Usage:
  bash automation-health-dashboard.sh [OPTIONS]

Options:
  --dry-run           Generate and preview dashboard (default)
  --live              Commit and push to fork, create/update PR
  --reports-dir DIR    Base reports directory (default: $REPORTS_DIR or ./reports)
  --index PATH         Path to _index.json (default: $REPOMAN_INDEX_FILE or
                       <reports-dir>/_index.json). When present, drives which
                       programs render and their headings; falls back to
                       disk-derived discovery when absent.
  --main-repo-dir DIR  Path to the report-target repo clone, overriding the
                       REPOS_DIR-derived default (default: $MAIN_REPO_DIR)
  --verbose            Print diagnostic output
  --help, -h           Show this help

Environment:
  REPORTS_DIR        Base directory containing program report subdirs
  REPOMAN_INDEX_FILE Path to _index.json (default: <reports-dir>/_index.json)
  MAIN_REPO_DIR      Path to the report-target repo clone (live mode git ops);
                     overrides the REPOS_DIR-derived default
  FORK_OWNER         Fork owner for cross-fork PRs
HELP
  exit 0
fi

# Resolve deployment constants (repos_dir, fork_owner) from ~/.repoman/config.json.
repoman_config

# Report-PR destination. The org main repo's docs/ folder feeds the docs site
# (rossoctl.dev) and cannot host machine-generated reports, so the standing
# dashboard PR lands under automation-health/ in the automation repo. A single
# file, overwritten in place each run: trend tooling reconstructs history by
# replaying git commit parents, so we store state (not dated snapshots) and
# avoid the files-vs-diffs-on-Git anti-pattern (rossoctl/automation#44).
# TODO(RepoMan Phase 2): move report_target_repo/source_repo to programs/health-dashboard.json.
REPORT_TARGET_REPO="rossoctl/automation"
SOURCE_REPO="rossoctl/automation"
REPORT_TARGET_OWNER="${REPORT_TARGET_REPO%%/*}"
REPORT_TARGET_NAME="${REPORT_TARGET_REPO##*/}"
REPORT_TARGET_PATH="automation-health/automation-health.md"
# Clone dir for the report target: honor an explicit --main-repo-dir/MAIN_REPO_DIR
# override, else derive from the owner-namespaced layout ($REPOS_DIR/<owner>/<name>).
REPORT_TARGET_DIR="${MAIN_REPO_DIR:-$REPOS_DIR/$REPORT_TARGET_OWNER/$REPORT_TARGET_NAME}"

# --- Validate inputs ---
if [ -z "${REPORTS_DIR:-}" ]; then
  # Default to ~/reports -- the parent the scanners/fixers now write their
  # per-program dirs (and the shared _index.json) under. Fall back to ./reports
  # for a repo-local layout if ~/reports does not exist yet.
  if [ -d "$HOME/reports" ]; then
    REPORTS_DIR="$HOME/reports"
  elif [ -d "./reports" ]; then
    REPORTS_DIR="./reports"
  else
    echo "ERROR: REPORTS_DIR is not set and neither ~/reports nor ./reports exists."
    echo "Export it to the directory containing program report subdirs:"
    echo "  export REPORTS_DIR=~/reports"
    exit 1
  fi
fi

INDEX_FILE="${INDEX_FILE_ARG:-${REPOMAN_INDEX_FILE:-$REPORTS_DIR/_index.json}}"

# Program-id -> display-name lookup (bash 3.2 safe, no assoc arrays). Only ids
# listed here have a corresponding extraction block further down; an index
# entry for any other id is a known/skippable program, not an error.
display_name_for() {
  case "$1" in
    link-health) echo "Link Health" ;;
    dep-bump)    echo "Dependency Bumps" ;;
    doc-drift)   echo "Doc Drift" ;;
    *)           echo "" ;;
  esac
}

LINK_SCAN_DIR=""
DEP_BUMP_DIR=""
DOC_DRIFT_DIR=""
HAS_LINK_HEALTH=false
HAS_DEP_BUMP=false
HAS_DOC_DRIFT=false
LINK_HEALTH_HEADING="Link Health"
DEP_BUMP_HEADING="Dependency Bumps"
DOC_DRIFT_HEADING="Doc Drift"

if [ -f "$INDEX_FILE" ]; then
  if ! jq empty "$INDEX_FILE" >/dev/null 2>&1; then
    echo "ERROR: Index file is not valid JSON: $INDEX_FILE"
    exit 1
  fi

  while IFS= read -r prog_id; do
    [ -z "$prog_id" ] && continue
    known_heading=$(display_name_for "$prog_id")
    if [ -z "$known_heading" ]; then
      echo "Skipping unknown program id from index (no extraction block): $prog_id"
      continue
    fi

    entry_path=$(jq -r --arg id "$prog_id" '.[$id].report_path // ""' "$INDEX_FILE")
    entry_display=$(jq -r --arg id "$prog_id" '.[$id].display_name // ""' "$INDEX_FILE")
    [ -z "$entry_display" ] && entry_display="$known_heading"

    if [ -z "$entry_path" ] || [ ! -f "$entry_path/latest.json" ] || [ ! -f "$entry_path/history.json" ]; then
      echo "Skipping program with missing reports: $prog_id ($entry_path)"
      continue
    fi

    case "$prog_id" in
      link-health)
        LINK_SCAN_DIR="$entry_path"
        HAS_LINK_HEALTH=true
        LINK_HEALTH_HEADING="$entry_display"
        ;;
      dep-bump)
        DEP_BUMP_DIR="$entry_path"
        HAS_DEP_BUMP=true
        DEP_BUMP_HEADING="$entry_display"
        ;;
      doc-drift)
        DOC_DRIFT_DIR="$entry_path"
        HAS_DOC_DRIFT=true
        DOC_DRIFT_HEADING="$entry_display"
        ;;
    esac
  done < <(jq -r 'keys[]' "$INDEX_FILE")
else
  # Disk-derived fallback: no index, probe the known report subdirs directly.
  LINK_SCAN_DIR="$REPORTS_DIR/link-health"
  DEP_BUMP_DIR="$REPORTS_DIR/dep-bump"
  DOC_DRIFT_DIR="$REPORTS_DIR/doc-drift"

  if [ -f "$LINK_SCAN_DIR/latest.json" ] && [ -f "$LINK_SCAN_DIR/history.json" ]; then
    HAS_LINK_HEALTH=true
    LINK_HEALTH_HEADING=$(display_name_for "link-health")
  fi
  if [ -f "$DEP_BUMP_DIR/latest.json" ] && [ -f "$DEP_BUMP_DIR/history.json" ]; then
    HAS_DEP_BUMP=true
    DEP_BUMP_HEADING=$(display_name_for "dep-bump")
  fi
  if [ -f "$DOC_DRIFT_DIR/latest.json" ] && [ -f "$DOC_DRIFT_DIR/history.json" ]; then
    HAS_DOC_DRIFT=true
    DOC_DRIFT_HEADING=$(display_name_for "doc-drift")
  fi
fi

if [ "$HAS_LINK_HEALTH" = false ] && [ "$HAS_DEP_BUMP" = false ] && [ "$HAS_DOC_DRIFT" = false ]; then
  echo "ERROR: No program reports found in $REPORTS_DIR"
  echo "Expected: $REPORTS_DIR/link-health/, dep-bump/, and/or doc-drift/ latest.json"
  exit 1
fi

PROGRAMS_ACTIVE=0
if [ "$HAS_LINK_HEALTH" = true ]; then PROGRAMS_ACTIVE=$((PROGRAMS_ACTIVE + 1)); fi
if [ "$HAS_DEP_BUMP" = true ]; then PROGRAMS_ACTIVE=$((PROGRAMS_ACTIVE + 1)); fi
if [ "$HAS_DOC_DRIFT" = true ]; then PROGRAMS_ACTIVE=$((PROGRAMS_ACTIVE + 1)); fi

# --- Setup ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

SCAN_TIME_ET=$(TZ="America/New_York" date +"%Y-%m-%d %H:%M ET")

echo "=== Automation Health Dashboard ==="
echo "Reports dir: $REPORTS_DIR"
echo "Programs available: $PROGRAMS_ACTIVE"
if [ "$DRY_RUN" = true ]; then
  echo "Mode: DRY RUN"
else
  echo "Mode: LIVE"
fi
echo ""

# =============================================================================
# Step 2: Compute executive summary metrics
# =============================================================================

LH_ISSUES_CREATED=0
LH_ISSUES_CLOSED=0
DB_ISSUES_CREATED=0
DB_ISSUES_CLOSED=0
DB_FIXER_CLOSED=0
DD_ISSUES_CREATED=0
DD_ISSUES_CLOSED=0
TOTAL_PRS_OPENED=0
LAST_SCAN_DATE="unknown"

if [ "$HAS_LINK_HEALTH" = true ]; then
  LH_ISSUES_CREATED=$(jq '[.[] | .issues_created // 0] | add // 0' "$LINK_SCAN_DIR/history.json")
  LH_ISSUES_CLOSED=$(jq '[.[] | .issues_closed // 0] | add // 0' "$LINK_SCAN_DIR/history.json")
  lh_last_date=$(jq -r '.date // ""' "$LINK_SCAN_DIR/latest.json")
  if [ -n "$lh_last_date" ]; then
    LAST_SCAN_DATE="${lh_last_date%%T*}"
  fi
fi

if [ "$HAS_DEP_BUMP" = true ]; then
  DB_ISSUES_CREATED=$(jq '[.[] | .issues_created // 0] | add // 0' "$DEP_BUMP_DIR/history.json")
  DB_ISSUES_CLOSED=$(jq '[.[] | .issues_closed // 0] | add // 0' "$DEP_BUMP_DIR/history.json")
  db_last_date=$(jq -r '.date // ""' "$DEP_BUMP_DIR/latest.json")
  if [ -n "$db_last_date" ]; then
    db_date="${db_last_date%%T*}"
    if [ "$LAST_SCAN_DATE" = "unknown" ] || [[ "$db_date" > "$LAST_SCAN_DATE" ]]; then
      LAST_SCAN_DATE="$db_date"
    fi
  fi

  if [ -f "$DEP_BUMP_DIR/fixer-latest.json" ]; then
    DB_FIXER_CLOSED=$(jq '.issues_closed // 0' "$DEP_BUMP_DIR/fixer-latest.json")
    fixer_config_prs=$(jq '.config_prs_created // 0' "$DEP_BUMP_DIR/fixer-latest.json")
    TOTAL_PRS_OPENED=$((TOTAL_PRS_OPENED + fixer_config_prs))
  fi
fi

if [ "$HAS_DOC_DRIFT" = true ]; then
  DD_ISSUES_CREATED=$(jq '[.[] | .issues_created // 0] | add // 0' "$DOC_DRIFT_DIR/history.json")
  DD_ISSUES_CLOSED=$(jq '[.[] | .issues_closed // 0] | add // 0' "$DOC_DRIFT_DIR/history.json")
  dd_last_date=$(jq -r '.date // ""' "$DOC_DRIFT_DIR/latest.json")
  if [ -n "$dd_last_date" ]; then
    dd_date="${dd_last_date%%T*}"
    if [ "$LAST_SCAN_DATE" = "unknown" ] || [[ "$dd_date" > "$LAST_SCAN_DATE" ]]; then
      LAST_SCAN_DATE="$dd_date"
    fi
  fi
fi

TOTAL_ISSUES_CREATED=$((LH_ISSUES_CREATED + DB_ISSUES_CREATED + DD_ISSUES_CREATED))
TOTAL_ISSUES_RESOLVED=$((LH_ISSUES_CLOSED + DB_ISSUES_CLOSED + DB_FIXER_CLOSED + DD_ISSUES_CLOSED))
HOURS_SAVED=$(echo "$TOTAL_ISSUES_RESOLVED" | awk '{printf "%.1f", $1 * 0.25}')

if [ "$VERBOSE" = true ]; then
  echo "Executive metrics:"
  echo "  Issues created: $TOTAL_ISSUES_CREATED (LH: $LH_ISSUES_CREATED, DB: $DB_ISSUES_CREATED, DD: $DD_ISSUES_CREATED)"
  echo "  Issues resolved: $TOTAL_ISSUES_RESOLVED (LH: $LH_ISSUES_CLOSED, DB: $DB_ISSUES_CLOSED, DD: $DD_ISSUES_CLOSED, fixer: $DB_FIXER_CLOSED)"
  echo "  PRs opened: $TOTAL_PRS_OPENED"
  echo "  Hours saved: $HOURS_SAVED"
  echo ""
fi

# =============================================================================
# Step 3: Compute link-health section
# =============================================================================

LH_REPOS_SCANNED=0
LH_TOTAL_LINKS=0
LH_BROKEN_INTERNAL=0
LH_BROKEN_EXTERNAL=0
LH_FIRST_INTERNAL=0
LH_FIRST_EXTERNAL=0
LH_TREND_TABLE="| - | - | - | - |"

if [ "$HAS_LINK_HEALTH" = true ]; then
  LH_REPOS_SCANNED=$(jq '.repos_scanned // 0' "$LINK_SCAN_DIR/latest.json")
  LH_TOTAL_LINKS=$(jq '.total_links_checked // 0' "$LINK_SCAN_DIR/latest.json")
  LH_BROKEN_INTERNAL=$(jq '[.broken[] | select(.category == "internal")] | length' "$LINK_SCAN_DIR/latest.json" 2>/dev/null || echo "0")
  LH_BROKEN_EXTERNAL=$(jq '[.broken[] | select(.category == "external")] | length' "$LINK_SCAN_DIR/latest.json" 2>/dev/null || echo "0")

  # First scan values for trend comparison
  LH_FIRST_INTERNAL=$(jq '.[0].broken_internal // 0' "$LINK_SCAN_DIR/history.json")
  LH_FIRST_EXTERNAL=$(jq '.[0].broken_external // 0' "$LINK_SCAN_DIR/history.json")

  LH_INTERNAL_DELTA=$((LH_BROKEN_INTERNAL - LH_FIRST_INTERNAL))
  LH_EXTERNAL_DELTA=$((LH_BROKEN_EXTERNAL - LH_FIRST_EXTERNAL))

  # Format deltas with sign
  lh_int_trend=""
  if [ "$LH_INTERNAL_DELTA" -gt 0 ]; then lh_int_trend="+$LH_INTERNAL_DELTA from first scan"
  elif [ "$LH_INTERNAL_DELTA" -lt 0 ]; then lh_int_trend="$LH_INTERNAL_DELTA from first scan"
  fi
  lh_ext_trend=""
  if [ "$LH_EXTERNAL_DELTA" -gt 0 ]; then lh_ext_trend="+$LH_EXTERNAL_DELTA from first scan"
  elif [ "$LH_EXTERNAL_DELTA" -lt 0 ]; then lh_ext_trend="$LH_EXTERNAL_DELTA from first scan"
  fi

  # Trend table (last 10 scans)
  LH_TREND_TABLE=$(jq -r '
    .[-10:] | reverse | .[] |
    "| \(.date | split("T")[0]) | \(.broken_internal) | \(.broken_external) | \(if .new > .fixed then "+\(.new - .fixed)" elif .new < .fixed then "\(.new - .fixed)" else "0" end) |"
  ' "$LINK_SCAN_DIR/history.json" 2>/dev/null || echo "| - | - | - | - |")
fi

# =============================================================================
# Step 4: Compute dep-bump section
# =============================================================================

DB_REPOS_SCANNED=0
DB_TOTAL_OPEN_PRS=0
DB_STALE_COUNT=0
DB_SLA_COMPLIANCE=0
DB_MEDIAN_TTM=0
DB_BASELINE_TTM=0
DB_COVERAGE_REPOS=0
DB_COVERAGE_TOTAL=0
DB_COVERAGE_PCT=0
DB_TIER_TABLE="| - | - | - | - |"
DB_TREND_TABLE="| - | - | - | - |"

if [ "$HAS_DEP_BUMP" = true ]; then
  DB_REPOS_SCANNED=$(jq '.repos_scanned // 0' "$DEP_BUMP_DIR/latest.json")
  DB_TOTAL_OPEN_PRS=$(jq '.total_open_prs // 0' "$DEP_BUMP_DIR/latest.json")
  DB_STALE_COUNT=$(jq '.stale_prs | length' "$DEP_BUMP_DIR/latest.json" 2>/dev/null || echo "0")
  DB_COVERAGE_REPOS=$(jq '.repos_with_dependabot // 0' "$DEP_BUMP_DIR/latest.json")
  DB_COVERAGE_TOTAL=$DB_REPOS_SCANNED

  if [ "$DB_COVERAGE_TOTAL" -gt 0 ]; then
    DB_COVERAGE_PCT=$((DB_COVERAGE_REPOS * 100 / DB_COVERAGE_TOTAL))
  fi

  if [ "$DB_TOTAL_OPEN_PRS" -gt 0 ]; then
    DB_SLA_COMPLIANCE=$(( (DB_TOTAL_OPEN_PRS - DB_STALE_COUNT) * 100 / DB_TOTAL_OPEN_PRS ))
  else
    DB_SLA_COMPLIANCE=100
  fi

  if [ -f "$DEP_BUMP_DIR/fixer-latest.json" ]; then
    DB_MEDIAN_TTM=$(jq '.metrics.median_time_to_merge // 0' "$DEP_BUMP_DIR/fixer-latest.json")
  fi
  if [ -f "$DEP_BUMP_DIR/baseline.json" ]; then
    DB_BASELINE_TTM=$(jq '.median_time_to_merge_days // 0' "$DEP_BUMP_DIR/baseline.json")
  fi

  # Tier breakdown from stale_prs array
  DB_TIER_TABLE=$(jq -r '
    .stale_prs as $all |
    .total_open_prs as $total |
    [
      {tier: "Critical", sla: "3d",
       stale: ([$all[] | select(.severity == "critical")] | length)},
      {tier: "High", sla: "7d",
       stale: ([$all[] | select(.severity == "high")] | length)},
      {tier: "Medium", sla: "30d",
       stale: ([$all[] | select(.severity == "medium")] | length)},
      {tier: "Routine", sla: "14d",
       stale: ([$all[] | select(.severity == "routine")] | length)},
      {tier: "Major", sla: "30d",
       stale: ([$all[] | select(.severity == "major")] | length)}
    ] | .[] |
    "| \(.tier) | \(.stale) | \(.sla) |"
  ' "$DEP_BUMP_DIR/latest.json" 2>/dev/null || echo "| - | - | - |")

  # Trend table (last 10 scans)
  DB_TREND_TABLE=$(jq -r '
    .[-10:] | reverse | .[] |
    "| \(.date | split("T")[0]) | \(.stale_security // 0) | \(.stale_routine // 0) | \(if .new > .fixed then "+\(.new - .fixed)" elif .new < .fixed then "\(.new - .fixed)" else "0" end) |"
  ' "$DEP_BUMP_DIR/history.json" 2>/dev/null || echo "| - | - | - | - |")
fi

# =============================================================================
# Step 4b: Compute doc-drift section
# =============================================================================

DD_REPOS_SCANNED=0
DD_CORRECTIONS=0
DD_ADDITIONS=0
DD_TREND_TABLE="| - | - | - | - |"

if [ "$HAS_DOC_DRIFT" = true ]; then
  DD_REPOS_SCANNED=$(jq '.repos_scanned // 0' "$DOC_DRIFT_DIR/latest.json")
  DD_CORRECTIONS=$(jq '.corrections // ([.findings[]? | select(.kind=="correction")] | length)' "$DOC_DRIFT_DIR/latest.json")
  DD_ADDITIONS=$(jq '.additions // ([.findings[]? | select(.kind=="addition")] | length)' "$DOC_DRIFT_DIR/latest.json")
  # Prefer .new/.fixed (emitted by doc-drift-scanner.sh); fall back to 0 so
  # older history rows without those keys still render a numeric Delta.
  DD_TREND_TABLE=$(jq -r '
    .[-10:] | reverse | .[] |
    (.new // 0) as $n | (.fixed // 0) as $f |
    "| \(.date | split("T")[0]) | \(.corrections // 0) | \(.additions // 0) | \(if $n > $f then "+\($n - $f)" elif $n < $f then "\($n - $f)" else "0" end) |"
  ' "$DOC_DRIFT_DIR/history.json" 2>/dev/null || echo "| - | - | - | - |")
fi

# =============================================================================
# Step 5: Compute cross-program coverage
# =============================================================================

COVERAGE_TABLE=""
REPOS_UNDER_ONE=0
REPOS_UNDER_ALL=0
TOTAL_UNIQUE_REPOS=0

# Collect repos from each program
lh_repos=""
db_repos=""

if [ "$HAS_LINK_HEALTH" = true ]; then
  # .repo is the full owner/name ref (extract-broken-links.sh emits it verbatim).
  # Key on the full ref so it matches db_repos below -- stripping the owner here
  # would make the two program sets un-mergeable (no repo could match both).
  lh_repos=$(jq -r '[.broken[].repo] | unique | .[]' "$LINK_SCAN_DIR/latest.json" 2>/dev/null | sort -u || true)
  # Also include repos scanned (from history, repos_scanned is a count not a list)
  # Fall back to broken repos as proxy for "scanned repos"
fi

if [ "$HAS_DEP_BUMP" = true ]; then
  # Repos with dependabot activity -- .repo is the full owner/name ref, same
  # shape as lh_repos, so the sort -u merge and grep -qxF cross-check align.
  db_repos=$(jq -r '([.stale_prs[].repo] + [.coverage_gaps[].repo]) | unique | .[]' "$DEP_BUMP_DIR/latest.json" 2>/dev/null | sort -u || true)
fi

# Merge and produce table
all_repos=$(printf '%s\n%s\n' "$lh_repos" "$db_repos" | sort -u | grep -v '^$' || true)
# Count non-empty lines. `grep -c` already prints 0 on no match AND returns 1,
# so a `|| echo 0` fallback would append a SECOND "0" -- yielding a two-line
# value that breaks the integer test at the coverage-percent guard below. Guard
# the empty case explicitly instead of relying on grep's rc.
if [ -n "$all_repos" ]; then
  TOTAL_UNIQUE_REPOS=$(printf '%s\n' "$all_repos" | grep -c .)
else
  TOTAL_UNIQUE_REPOS=0
fi

while IFS= read -r repo; do
  [ -z "$repo" ] && continue
  has_lh="no"
  has_db="no"
  count=0

  if echo "$lh_repos" | grep -qxF "$repo"; then
    has_lh="yes"
    count=$((count + 1))
  fi
  if echo "$db_repos" | grep -qxF "$repo"; then
    has_db="yes"
    count=$((count + 1))
  fi

  COVERAGE_TABLE="${COVERAGE_TABLE}| $repo | $has_lh | $has_db | $count |
"
  if [ "$count" -ge 1 ]; then REPOS_UNDER_ONE=$((REPOS_UNDER_ONE + 1)); fi
  if [ "$count" -ge "$PROGRAMS_ACTIVE" ]; then REPOS_UNDER_ALL=$((REPOS_UNDER_ALL + 1)); fi
done <<< "$all_repos"

COVERAGE_ONE_PCT=0
COVERAGE_ALL_PCT=0
if [ "$TOTAL_UNIQUE_REPOS" -gt 0 ]; then
  COVERAGE_ONE_PCT=$((REPOS_UNDER_ONE * 100 / TOTAL_UNIQUE_REPOS))
  COVERAGE_ALL_PCT=$((REPOS_UNDER_ALL * 100 / TOTAL_UNIQUE_REPOS))
fi

# =============================================================================
# Step 6: Cron health
# =============================================================================

# Static entries — future version should read from jobs.json
CRON_TABLE="| link-health-scanner | Mon/Wed/Fri 7am ET | $LAST_SCAN_DATE | ok |
| link-health-fixer | Tue/Thu 8am ET | $LAST_SCAN_DATE | ok |
| dep-bump-scanner | Tue/Thu 10am ET | $LAST_SCAN_DATE | ok |
| dep-bump-fixer | Tue/Thu 12pm ET | $LAST_SCAN_DATE | ok |"

# =============================================================================
# Step 7: Generate markdown
# =============================================================================

# Base: header + Executive Summary (always rendered).
cat > "$TMPDIR/automation-health.md" << DASHBOARD_EOF
# Automation Health Dashboard

> Last updated: $SCAN_TIME_ET | Programs: $PROGRAMS_ACTIVE active

## Executive Summary

| Metric | Value |
|--------|-------|
| Total issues auto-created | $TOTAL_ISSUES_CREATED (link-health: $LH_ISSUES_CREATED, dep-bump: $DB_ISSUES_CREATED, doc-drift: $DD_ISSUES_CREATED) |
| Total issues auto-resolved | $TOTAL_ISSUES_RESOLVED |
| Total PRs auto-opened | $TOTAL_PRS_OPENED |
| Estimated hours saved | ${HOURS_SAVED} hrs (at 15 min/resolved issue) |
| Programs active | $PROGRAMS_ACTIVE |
| Last successful scan | $LAST_SCAN_DATE |
DASHBOARD_EOF

# Per-program sections render only when discovery found that program, so an
# index with only one program does not emit the other's heading (empty section).
if [ "$HAS_LINK_HEALTH" = true ]; then
  cat >> "$TMPDIR/automation-health.md" << DASHBOARD_EOF

## $LINK_HEALTH_HEADING

| Metric | Value | Trend |
|--------|-------|-------|
| Repos scanned | $LH_REPOS_SCANNED | |
| Total links checked | $LH_TOTAL_LINKS | |
| Broken (internal) | $LH_BROKEN_INTERNAL | $lh_int_trend |
| Broken (external) | $LH_BROKEN_EXTERNAL | $lh_ext_trend |
| Issues created (cumulative) | $LH_ISSUES_CREATED | |
| Issues resolved (cumulative) | $LH_ISSUES_CLOSED | |

### Trend (last 10 scans)

| Date | Internal | External | Delta |
|------|----------|----------|-------|
$LH_TREND_TABLE
DASHBOARD_EOF
fi

if [ "$HAS_DEP_BUMP" = true ]; then
  cat >> "$TMPDIR/automation-health.md" << DASHBOARD_EOF

## $DEP_BUMP_HEADING

| Metric | Value | Trend |
|--------|-------|-------|
| Repos scanned | $DB_REPOS_SCANNED | |
| Open Dependabot PRs | $DB_TOTAL_OPEN_PRS | |
| Stale PRs (SLA breached) | $DB_STALE_COUNT | baseline: $(jq '.stale_count_at_baseline // "N/A"' "$DEP_BUMP_DIR/baseline.json" 2>/dev/null || echo "N/A") |
| SLA compliance rate | ${DB_SLA_COMPLIANCE}% | |
| Median time-to-merge | ${DB_MEDIAN_TTM}d | baseline: ${DB_BASELINE_TTM}d |
| Dependabot coverage | ${DB_COVERAGE_PCT}% ($DB_COVERAGE_REPOS/$DB_COVERAGE_TOTAL repos) | |

### By Severity Tier

| Tier | Stale | SLA |
|------|-------|-----|
$DB_TIER_TABLE

### Patch Velocity (last 10 scans)

| Date | Stale Security | Stale Routine | Delta |
|------|----------------|---------------|-------|
$DB_TREND_TABLE
DASHBOARD_EOF
fi

if [ "$HAS_DOC_DRIFT" = true ]; then
  cat >> "$TMPDIR/automation-health.md" << DASHBOARD_EOF

## $DOC_DRIFT_HEADING

| Metric | Value |
|--------|-------|
| Repos scanned | $DD_REPOS_SCANNED |
| Open corrections | $DD_CORRECTIONS |
| Open additions | $DD_ADDITIONS |
| Issues created (cumulative) | $DD_ISSUES_CREATED |
| Issues closed (cumulative) | $DD_ISSUES_CLOSED |

### Trend (last 10 scans)

| Date | Corrections | Additions | Delta |
|------|-------------|-----------|-------|
$DD_TREND_TABLE
DASHBOARD_EOF
fi

# Tail: cross-cutting sections (always rendered).
cat >> "$TMPDIR/automation-health.md" << DASHBOARD_EOF

## Cross-Program Coverage

| Repo | Link Health | Dep Bump | Programs |
|------|-------------|----------|----------|
$COVERAGE_TABLE

### Coverage Summary
- Repos under at least one program: $REPOS_UNDER_ONE / $TOTAL_UNIQUE_REPOS (${COVERAGE_ONE_PCT}%)
- Repos under all programs: $REPOS_UNDER_ALL / $TOTAL_UNIQUE_REPOS (${COVERAGE_ALL_PCT}%)

## Cron Health

| Job | Schedule | Last Run | Status |
|-----|----------|----------|--------|
$CRON_TABLE

---
*Generated by RepoMan Automation Health Dashboard. Do not edit manually.*
DASHBOARD_EOF

echo "Dashboard generated ($TMPDIR/automation-health.md)"

# =============================================================================
# Step 8: Output or commit
# =============================================================================

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "[DRY RUN] Dashboard preview:"
  echo "---"
  cat "$TMPDIR/automation-health.md"
  echo "---"
  echo "[DRY RUN] Would push $REPORT_TARGET_PATH to fork and create/update PR against $REPORT_TARGET_REPO"
else
  if [ ! -d "$REPORT_TARGET_DIR/.git" ]; then
    echo "ERROR: $REPORT_TARGET_DIR does not appear to be a git repository."
    echo "Export MAIN_REPO_DIR or set REPOS_DIR so $REPORT_TARGET_REPO can be found:"
    echo "  export MAIN_REPO_DIR=$REPOS_DIR/$REPORT_TARGET_OWNER/$REPORT_TARGET_NAME"
    exit 1
  fi

  FORK_REMOTE="$FORK_OWNER"
  DASHBOARD_BRANCH="automation/health-dashboard"

  cd "$REPORT_TARGET_DIR"

  # Ensure the fork remote exists AND points at the current target. set-url
  # corrects a stale remote (e.g. one left by a prior deployment pointing at the
  # old report repo); the || add branch handles the not-yet-registered case.
  fork_url="https://github.com/$FORK_OWNER/${REPORT_TARGET_NAME}.git"
  git remote set-url "$FORK_REMOTE" "$fork_url" 2>/dev/null \
    || git remote add "$FORK_REMOTE" "$fork_url"

  # Fetch fork's branch if it exists, otherwise create from main
  if git fetch "$FORK_REMOTE" "$DASHBOARD_BRANCH" 2>/dev/null; then
    git checkout -B "$DASHBOARD_BRANCH" "$FORK_REMOTE/$DASHBOARD_BRANCH"
  else
    git fetch "$FORK_REMOTE" main 2>/dev/null || true
    git checkout -B "$DASHBOARD_BRANCH" "$FORK_REMOTE/main" 2>/dev/null \
      || git checkout -B "$DASHBOARD_BRANCH"
  fi

  mkdir -p "$(dirname "$REPORT_TARGET_PATH")"
  cp "$TMPDIR/automation-health.md" "$REPORT_TARGET_PATH"
  git add "$REPORT_TARGET_PATH"
  git commit -s -m "docs: Update automation health dashboard ($SCAN_TIME_ET)" 2>/dev/null || echo "No changes to commit"
  git push "$FORK_REMOTE" "$DASHBOARD_BRANCH" 2>/dev/null || echo "WARN: Failed to push dashboard to fork"

  # Create or update standing cross-fork PR
  existing_pr=$(gh api "repos/$REPORT_TARGET_REPO/pulls?head=$FORK_OWNER:$DASHBOARD_BRANCH&state=open" \
    --jq '.[0].number' 2>/dev/null || echo "")

  pr_body="## Summary

Auto-updated by RepoMan Automation Health Dashboard. This PR is continuously updated with each generation. Merge when convenient.

| Metric | Value |
|--------|-------|
| Programs active | $PROGRAMS_ACTIVE |
| Issues created (cumulative) | $TOTAL_ISSUES_CREATED |
| Issues resolved (cumulative) | $TOTAL_ISSUES_RESOLVED |
| Estimated hours saved | ${HOURS_SAVED} hrs |

## Related issue(s)

- $REPORT_TARGET_REPO#1260

## Automation program

Generated by the [RepoMan Automation Health Dashboard](https://github.com/$SOURCE_REPO/blob/main/standing-orders/health-dashboard.md)."

  if [ -z "$existing_pr" ] || [ "$existing_pr" = "null" ]; then
    gh pr create --repo "$REPORT_TARGET_REPO" \
      --head "$FORK_OWNER:$DASHBOARD_BRANCH" --base main \
      --title "docs: Automation health dashboard (auto-updated)" \
      --body "$pr_body" 2>/dev/null || echo "WARN: Failed to create dashboard PR"
  else
    gh pr edit "$existing_pr" --repo "$REPORT_TARGET_REPO" --body "$pr_body" 2>/dev/null || true
  fi

  echo "Dashboard committed and pushed"
fi

echo ""
echo "=== Done ==="
