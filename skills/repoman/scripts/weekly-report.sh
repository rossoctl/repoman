#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Weekly Report (enrolled-set-scoped)
# Resolves the RepoMan enrolled set (owner/name tuples) via the shared library,
# then invokes the Python report generator scoped to exactly those repos. The
# enrolled set can span multiple owners, so each repo is passed owner-qualified
# and there is no single --org.
#
# Usage:
#   bash weekly-report.sh --help
#   bash weekly-report.sh --output /tmp/report.md --json-output /tmp/report-data.json
#   bash weekly-report.sh --since 2026-08-10 --until 2026-08-17
# =============================================================================

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- CLI args ---
SINCE=""
UNTIL=""
OUTPUT=""
JSON_OUTPUT=""
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --since) SINCE="$2"; shift 2 ;;
    --until) UNTIL="$2"; shift 2 ;;
    --output) OUTPUT="$2"; shift 2 ;;
    --json-output) JSON_OUTPUT="$2"; shift 2 ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
weekly-report -- Generate the weekly report scoped to the enrolled repos

USAGE:
  weekly-report.sh [OPTIONS]

OPTIONS:
  --since DATE       Start of reporting window (YYYY-MM-DD; default: 7 days ago)
  --until DATE       End of reporting window (YYYY-MM-DD; default: today)
  --output FILE      Write the Markdown report to FILE (default: stdout)
  --json-output FILE Write structured JSON for AI synthesis to FILE
  --help, -h         Show this help

ENVIRONMENT:
  REPORT_PY          Path to report.py (default: the deployed report generator)

PREREQUISITES:
  python3, gh (authenticated). The repo list comes from the RepoMan enrolled set
  (~/.repoman/repos.json) via the shared library (repoman_get_repos); it can span
  multiple owners, so each repo is passed to the generator owner-qualified.
USAGE
  exit 0
fi

# The enrolled set, owner-qualified (e.g. rossoctl/operator), one per line.
# repoman_get_repos fails loud (non-zero) on a missing/empty/malformed set, so
# an unset or broken enrollment aborts here rather than producing an empty report.
if ! repos="$(repoman_get_repos)"; then
  echo "Error: could not resolve the RepoMan enrolled set" >&2
  exit 1
fi
if [ -z "$repos" ]; then
  echo "Error: RepoMan enrolled set is empty" >&2
  exit 1
fi

# Locate the generator. Default points at the deployed github-weekly-report skill
# (the upstream skill name in agent-skills); override with REPORT_PY in dev.
REPORT_PY="${REPORT_PY:-$HOME/workspaces/shared/skills/github-weekly-report/scripts/report.py}"
if [ ! -f "$REPORT_PY" ]; then
  echo "Error: report generator not found at: $REPORT_PY" >&2
  echo "Set REPORT_PY to the path of report.py." >&2
  exit 1
fi

# Build args. $repos is intentionally unquoted so each owner/name line becomes a
# separate --repos value; repo slugs never contain whitespace. No --org: the
# enrolled set can span owners, so each entry is owner-qualified and report.py
# derives the owner per repo.
# shellcheck disable=SC2086
set -- --repos $repos
[ -n "$SINCE" ] && set -- "$@" --since "$SINCE"
[ -n "$UNTIL" ] && set -- "$@" --until "$UNTIL"
[ -n "$OUTPUT" ] && set -- "$@" --output "$OUTPUT"
[ -n "$JSON_OUTPUT" ] && set -- "$@" --json-output "$JSON_OUTPUT"

exec python3 "$REPORT_PY" "$@"
