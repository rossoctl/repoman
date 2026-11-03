#!/usr/bin/env bash
set -euo pipefail

# PR Review Fixer — State Transition Manager (scanner/fixer pattern)
# Manages the in_progress/reviewed state for the PR review bot.
# Called by the agent at the start (begin) and end (finalize) of a review cycle.

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/pr-review-lib.sh"

# --- Configuration ---
BOT_USER="clawgenti"
REVIEW_MARKER="<!-- reviewed:"
MAX_HISTORY_ROWS=500

# --- CLI args ---
VERBOSE=false
DRY_RUN=true
SHOW_HELP=false
COMMAND=""

while [[ $# -gt 0 ]]; do
  case $1 in
    begin|finalize|footer) COMMAND="$1"; shift ;;
    --reports-dir) REPORTS_DIR="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --live) DRY_RUN=false; shift ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
pr-review-fixer -- Manage state transitions for PR review bot

USAGE:
  pr-review-fixer.sh [OPTIONS] COMMAND

COMMANDS:
  begin       Read latest.json, mark eligible PRs as in_progress, output queue
  finalize    Check reviews API, move reviewed PRs to reviewed state
  footer      Print the pinned-SHA line for the review body and its Slack post

OPTIONS:
  --reports-dir DIR   Reports directory (default: $REPORTS_DIR or ~/reports/pr-review)
  --verbose           Print diagnostic output to stderr
  --dry-run           Preview only, do not write state (DEFAULT)
  --live              Write state transitions for real
  --help, -h          Show this help

OUTPUT (begin):
  JSON array of PRs to review, each with a diff_map for inline comment targeting:
  [{"repo": "...", "number": N, "head_sha": "...", "diff_map": [...]}]

OUTPUT (finalize):
  JSON summary: {"prs_processed": N, "prs_reviewed": M, "prs_failed": K}

PREREQUISITES:
  gh (authenticated as clawgenti), jq, awk
USAGE
  exit 0
fi

if [ -z "$COMMAND" ]; then
  echo "ERROR: command required (begin, finalize, or footer). Use --help for usage." >&2
  exit 1
fi

# Pin provenance: write _meta only after the SHA resolves, never overwrite a
# valid file, and fall back to blob/main when resolution fails. `footer` is the
# line for the review body and its Slack post. Inline comments do not get it.
SKILL_FOOTER=$(skill_attribution "github-pr-review")
if [ "$COMMAND" = "footer" ]; then
  printf '%s\n' "$SKILL_FOOTER"
  exit 0
fi

# --- Setup ---
setup_workspace "pr-review-fixer"
TMPDIR="$PROGRAM_TMPDIR"
REPORTS_DIR="${REPORTS_DIR:-$HOME/reports/pr-review}"

STATE_FILE="$REPORTS_DIR/state.json"
LATEST_FILE="$REPORTS_DIR/latest.json"

pr_review_state_load "$STATE_FILE" > "$TMPDIR/state.json"

# =============================================================================
# BEGIN: Mark eligible PRs as in_progress, output queue with diff_map
# =============================================================================
if [ "$COMMAND" = "begin" ]; then
  if [ ! -f "$LATEST_FILE" ]; then
    [ "$VERBOSE" = true ] && echo "No latest.json found, nothing to do." >&2
    echo "[]"
    exit 0
  fi

  # Read eligible PRs from scanner output
  ELIGIBLE=$(jq -c '.eligible_prs // []' "$LATEST_FILE")
  COUNT=$(echo "$ELIGIBLE" | jq 'length')

  if [ "$COUNT" -eq 0 ]; then
    [ "$VERBOSE" = true ] && echo "No eligible PRs in latest.json." >&2
    echo "[]"
    exit 0
  fi

  [ "$VERBOSE" = true ] && echo "Found $COUNT eligible PR(s) to review." >&2

  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  # Write eligible PRs to a temp file for iteration (avoids subshell scoping)
  echo "$ELIGIBLE" | jq -c '.[]' > "$TMPDIR/eligible_prs.jsonl"

  # Build enriched queue with diff_map
  echo "[]" > "$TMPDIR/output_queue.json"

  while IFS= read -r pr; do
    repo=$(echo "$pr" | jq -r '.repo')
    number=$(echo "$pr" | jq -r '.number')
    head_sha=$(echo "$pr" | jq -r '.head_sha')

    [ "$VERBOSE" = true ] && echo "  Processing $repo#$number..." >&2

    # Mark as in_progress in state
    if [ "$DRY_RUN" = true ]; then
      echo "[DRY RUN] Would mark $repo#$number as in_progress" >&2
    else
      jq --arg repo "$repo" --argjson num "$number" --arg sha "$head_sha" --arg ts "$NOW" \
        '.in_progress = [.in_progress[] | select(.repo != $repo or .number != $num)] + [{"repo": $repo, "number": $num, "head_sha": $sha, "started_at": $ts}]' \
        "$TMPDIR/state.json" > "$TMPDIR/state_tmp.json"
      mv "$TMPDIR/state_tmp.json" "$TMPDIR/state.json"
    fi

    # Fetch diff
    [ "$VERBOSE" = true ] && echo "    Fetching diff..." >&2
    gh pr diff "$number" --repo "$repo" > "$TMPDIR/pr-${number}.diff" 2>/dev/null || true

    # Parse diff into structured map using the standalone parser
    DIFF_MAP="[]"
    if [ -s "$TMPDIR/pr-${number}.diff" ]; then
      DIFF_MAP=$("$SCRIPT_DIR/parse-diff-map.sh" "$TMPDIR/pr-${number}.diff")
      line_count=$(echo "$DIFF_MAP" | jq '[.[].hunks[].lines[]] | length')
      [ "$VERBOSE" = true ] && echo "    Parsed diff_map: $line_count lines across $(echo "$DIFF_MAP" | jq 'length') files" >&2
    fi

    # Build enriched PR entry
    enriched=$(jq -n \
      --arg repo "$repo" \
      --argjson number "$number" \
      --arg head_sha "$head_sha" \
      --argjson diff_map "$DIFF_MAP" \
      '{repo: $repo, number: $number, head_sha: $head_sha, diff_map: $diff_map}')

    # Append to output queue
    jq --argjson entry "$enriched" '. += [$entry]' "$TMPDIR/output_queue.json" > "$TMPDIR/output_tmp.json"
    mv "$TMPDIR/output_tmp.json" "$TMPDIR/output_queue.json"

  done < "$TMPDIR/eligible_prs.jsonl"

  # Write updated state (atomic, avoids argument-length limits)
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would write updated state.json to $REPORTS_DIR" >&2
  else
    pr_review_state_write "$TMPDIR/state.json" "$REPORTS_DIR/state.json" "pr-review-fixer"
  fi

  # Output enriched queue
  cat "$TMPDIR/output_queue.json"
  exit 0
fi

# =============================================================================
# FINALIZE: Check which PRs were reviewed, update state
# =============================================================================
if [ "$COMMAND" = "finalize" ]; then
  IN_PROGRESS=$(jq -c '.in_progress // []' "$TMPDIR/state.json")
  COUNT=$(echo "$IN_PROGRESS" | jq 'length')

  if [ "$COUNT" -eq 0 ]; then
    [ "$VERBOSE" = true ] && echo "No in_progress entries to finalize." >&2
    jq -n '{"prs_processed": 0, "prs_reviewed": 0, "prs_failed": 0}'
    exit 0
  fi

  [ "$VERBOSE" = true ] && echo "Finalizing $COUNT in_progress PR(s)..." >&2

  # Write entries to temp file (avoids subshell scoping in piped while)
  echo "$IN_PROGRESS" | jq -c '.[]' > "$TMPDIR/in_progress_entries.jsonl"

  # Track results in temp files instead of subshell variables
  echo "0" > "$TMPDIR/reviewed_count.txt"
  echo "0" > "$TMPDIR/failed_count.txt"

  NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)

  while IFS= read -r entry; do
    repo=$(echo "$entry" | jq -r '.repo')
    number=$(echo "$entry" | jq -r '.number')
    head_sha=$(echo "$entry" | jq -r '.head_sha')

    [ "$VERBOSE" = true ] && echo "  Checking $repo#$number for review..." >&2

    # Check if bot posted a review with the SHA marker
    reviewed_sha=$(gh api \
      "repos/$repo/pulls/$number/reviews" \
      --paginate \
      --jq ".[] | select(.user.login == \"$BOT_USER\") | select(.body | contains(\"$REVIEW_MARKER\")) | .body" \
      2>/dev/null \
      | grep -oE '<!-- reviewed: [a-f0-9]+ -->' \
      | tail -1 \
      | sed -E 's/<!-- reviewed: ([a-f0-9]+) -->/\1/' \
      || true)

    if [ -n "$reviewed_sha" ] && [ "$reviewed_sha" = "$head_sha" ]; then
      [ "$VERBOSE" = true ] && echo "    Confirmed: reviewed at $head_sha" >&2

      # Increment reviewed counter
      count=$(cat "$TMPDIR/reviewed_count.txt")
      echo "$((count + 1))" > "$TMPDIR/reviewed_count.txt"

      # Move from in_progress to reviewed
      if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] Would move $repo#$number to reviewed" >&2
      else
        jq --arg repo "$repo" --argjson num "$number" --arg sha "$head_sha" --arg ts "$NOW" \
          '.in_progress = [.in_progress[] | select(.repo != $repo or .number != $num)] |
           .reviewed = [.reviewed[] | select(.repo != $repo or .number != $num)] + [{"repo": $repo, "number": $num, "head_sha": $sha, "reviewed_at": $ts}]' \
          "$TMPDIR/state.json" > "$TMPDIR/state_tmp.json"
        mv "$TMPDIR/state_tmp.json" "$TMPDIR/state.json"
      fi
    else
      [ "$VERBOSE" = true ] && echo "    Not yet reviewed (will retry next cycle)" >&2

      # Increment failed counter
      count=$(cat "$TMPDIR/failed_count.txt")
      echo "$((count + 1))" > "$TMPDIR/failed_count.txt"
    fi
  done < "$TMPDIR/in_progress_entries.jsonl"

  # Read final counters
  PRS_REVIEWED=$(cat "$TMPDIR/reviewed_count.txt")
  PRS_FAILED=$(cat "$TMPDIR/failed_count.txt")

  # Write updated state and history
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] Would write state.json and fixer-history.json to $REPORTS_DIR" >&2
  else
    pr_review_state_write "$TMPDIR/state.json" "$REPORTS_DIR/state.json" "pr-review-fixer"

    FIXER_ROW=$(jq -n \
      --arg date "$NOW" \
      --argjson prs_processed "$COUNT" \
      --argjson prs_reviewed "$PRS_REVIEWED" \
      --argjson prs_failed "$PRS_FAILED" \
      '{date: $date, prs_processed: $prs_processed, prs_reviewed: $prs_reviewed, prs_failed: $prs_failed}')

    append_history_row "$REPORTS_DIR" "$FIXER_ROW" "$MAX_HISTORY_ROWS" "fixer-history.json"
    [ "$VERBOSE" = true ] && echo "Appended to $REPORTS_DIR/fixer-history.json" >&2
  fi

  # Output summary
  jq -n \
    --argjson prs_processed "$COUNT" \
    --argjson prs_reviewed "$PRS_REVIEWED" \
    --argjson prs_failed "$PRS_FAILED" \
    '{prs_processed: $prs_processed, prs_reviewed: $prs_reviewed, prs_failed: $prs_failed}'
  exit 0
fi
