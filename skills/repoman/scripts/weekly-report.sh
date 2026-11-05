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
  REPORT_PY          Path to report.py (default: first of the bundled generator
                     beside this skill, then the $HOME/workspaces deploy path)

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

# Locate the generator. When REPORT_PY is unset, try candidates in order and use
# the first that exists, so both deployment layouts work with no per-host config:
#   1. bundled  — the plugin layout, where github-weekly-report sits beside the
#                 repoman skill (the self-contained install; the primary target).
#   2. deployed — the OpenClaw host layout under $HOME/workspaces. Transitional:
#                 the personal-path default is tracked for removal in #116, and
#                 falls away entirely if OpenClaw deployment is retired.
# If neither exists, keep the bundled path so the error names the expected location.
if [ -z "${REPORT_PY:-}" ]; then
  bundled="$SCRIPT_DIR/../../github-weekly-report/scripts/report.py"
  deployed="${HOME:-}/workspaces/shared/skills/github-weekly-report/scripts/report.py"
  for candidate in "$bundled" "$deployed"; do
    if [ -f "$candidate" ]; then REPORT_PY="$candidate"; break; fi
  done
  REPORT_PY="${REPORT_PY:-$bundled}"
fi
if [ ! -f "$REPORT_PY" ]; then
  echo "Error: report generator not found at: $REPORT_PY" >&2
  echo "Set REPORT_PY to the path of report.py." >&2
  exit 1
fi

# Pin provenance and append that exact line to the report that gets posted.
# Write _meta only after the SHA resolves; never overwrite a valid file.
SKILL_FOOTER=$(skill_attribution "github-weekly-report")

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

python3 "$REPORT_PY" "$@"

# --output: the posted artifact is the file. Otherwise the report is stdout.
if [ -n "$OUTPUT" ]; then
  printf '\n%s\n' "$SKILL_FOOTER" >> "$OUTPUT"
else
  printf '\n%s\n' "$SKILL_FOOTER"
fi
