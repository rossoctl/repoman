#!/usr/bin/env bash
set -euo pipefail

# PR Review Scanner — Discovery Script (scanner/fixer pattern)
# Finds PRs labeled "ready-for-ai-review" that need review.
# Writes reports (latest.json, history.json) and manages state (state.json).
# Outputs a JSON array of eligible PRs to stdout (backward compatible).

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/pr-review-lib.sh"

# --- CLI args ---
VERBOSE=false
DRY_RUN=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose) VERBOSE=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --reports-dir) REPORTS_DIR="$2"; shift 2 ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Short-circuit --help before resolving the enrolled repo set, so usage works
# even in a checkout with a missing/malformed ~/.repoman/repos.json.
if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
pr-review-scanner -- Discover PRs needing AI review

USAGE:
  pr-review-scanner.sh [OPTIONS]

OPTIONS:
  --verbose           Print diagnostic output to stderr
  --dry-run           Query GitHub but do not write reports (stdout output still produced)
  --reports-dir DIR   Where to write reports (default: $REPORTS_DIR or ~/reports/pr-review)
  --help, -h          Show this help

OUTPUT:
  JSON array of eligible PRs to stdout:
  [{"repo": "rossoctl/rossoctl", "number": 123, "head_sha": "abc123"}]

REPORTS:
  latest.json   Current scan results (overwritten each run)
  history.json  Scan history (appended, capped at 500 rows)
  state.json    Coordination state (in_progress, reviewed entries)

PREREQUISITES:
  gh (authenticated as clawgenti), jq
USAGE
  exit 0
fi

# Pin provenance on startup: write _meta only after the SHA resolves, and never
# overwrite a valid file. Resolution failure must not fail the scan.
skill_attribution "github-pr-review" >/dev/null

# Resolve the enrolled repo set from ~/.repoman/repos.json (owner/name tuples).
# repoman_config is not needed here -- the scanner queries GitHub directly and
# writes no fork, so it needs no REPOS_DIR/FORK_OWNER.

# --- Configuration ---
BOT_USER="clawgenti"

# Repo coverage comes from the RepoMan enrolled set (~/.repoman/repos.json) via
# repoman_get_repos, which emits "owner/name" per line. Build the array with a
# portable while-read loop (mapfile is bash 4+, unavailable on macOS's bash
# 3.2). Fail loud rather than silently scanning an empty set.
REPOS=()
while IFS= read -r repo_line; do
  [ -n "$repo_line" ] && REPOS+=("$repo_line")
done < <(repoman_get_repos)

if [ "${#REPOS[@]}" -eq 0 ]; then
  echo "ERROR: RepoMan enrolled set is empty or could not be loaded" >&2
  exit 1
fi

LABEL="ready-for-ai-review"
REVIEW_MARKER="<!-- reviewed:"
STALE_THRESHOLD_MIN=30
# Single source of truth: the lib stamps acted_on.ttl_days with this same value,
# so the scanner's eviction and the persisted TTL cannot drift (sourced above).
TTL_DAYS="$PR_REVIEW_TTL_DAYS"
MAX_HISTORY_ROWS=500

# --- Workspace and reports setup ---
setup_workspace "pr-review-scanner"
TMPDIR="$PROGRAM_TMPDIR"
REPORTS_DIR="${REPORTS_DIR:-$HOME/reports/pr-review}"
mkdir -p "$REPORTS_DIR"

SCAN_DATE=$(date -u +%Y-%m-%d)
SCAN_TIME=$(date -u +%Y-%m-%dT%H:%M:%SZ)
SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "$SCAN_DATE")

[ "$VERBOSE" = true ] && echo "Scan ID: $SCAN_ID | Reports: $REPORTS_DIR" >&2

# --- Load state (envelope-aware; migrates legacy in memory) ---
STATE_FILE="$REPORTS_DIR/state.json"
pr_review_state_load "$STATE_FILE" > "$TMPDIR/state.json"

# --- Step 1: List labeled PRs across target repos ---
QUEUE_FILE="$TMPDIR/queue.json"
echo "[]" > "$QUEUE_FILE"
touch "$TMPDIR/open_labeled.jsonl"
touch "$TMPDIR/candidates.jsonl"

REPOS_SCANNED=0
CANDIDATES_FOUND=0

for repo in "${REPOS[@]}"; do
  [ "$VERBOSE" = true ] && echo "Checking $repo..." >&2
  REPOS_SCANNED=$((REPOS_SCANNED + 1))

  prs_json=$(gh pr list --repo "$repo" \
    --label "$LABEL" \
    --state open \
    --json number,author,headRefOid,isDraft,reviewDecision \
    2>/dev/null || echo "[]")

  # Store raw results for eviction comparison
  echo "$prs_json" | jq -c \
    --arg repo "$repo" \
    '.[] | {repo: $repo, number: .number}' \
    >> "$TMPDIR/open_labeled.jsonl"

  # Filter out bot's own PRs, drafts, and already-approved PRs
  filtered=$(echo "$prs_json" | jq -c \
    --arg bot "$BOT_USER" \
    '[.[] | select(.author.login != $bot) | select(.isDraft == false) | select(.reviewDecision != "APPROVED")]')

  count=$(echo "$filtered" | jq 'length')
  CANDIDATES_FOUND=$((CANDIDATES_FOUND + count))
  [ "$VERBOSE" = true ] && echo "  Found $count candidate PR(s) (after filtering)" >&2

  echo "$filtered" | jq -c \
    --arg repo "$repo" \
    '.[] | {repo: $repo, number: .number, head_sha: .headRefOid}' \
    >> "$TMPDIR/candidates.jsonl"
done

# --- Step 2: Eviction pass ---
# Uses a temp file for eviction keys instead of incrementing a counter in a
# subshell. The eviction count is derived from the file at the end.
NOW_EPOCH=$(date +%s)

# Build a lookup of currently open+labeled PRs: "repo:number"
jq -r '"\(.repo):\(.number)"' "$TMPDIR/open_labeled.jsonl" 2>/dev/null \
  | sort -u > "$TMPDIR/open_keys.txt"

touch "$TMPDIR/evict_keys.txt"

# Subset-run guard (see docs/specs run-path, "Subset-aware stateful scanners"):
# on a narrowed run, open_keys.txt only covers the SCANNED repos, so an entry
# from an UNSCANNED repo would wrongly look "no longer open/labeled" and be
# evicted — discarding another repo's in-progress/reviewed claim. Scope the
# open/labeled eviction to scanned repos; an unscanned entry is carried forward.
# (TTL/stale checks below are time-based and still apply to all entries.)
SCANNED_REPOS_FILE="$TMPDIR/scanned_repos.txt"
if [ -n "${REPOMAN_SUBSET_REPOS:-}" ]; then
  printf '%s\n' "$REPOMAN_SUBSET_REPOS" | grep . > "$SCANNED_REPOS_FILE" || true
else
  : > "$SCANNED_REPOS_FILE"   # empty => whole-set run => all repos are "scanned"
fi
# _repo_scanned <owner/name> -> 0 if this run scanned that repo (whole-set runs
# scan every repo, so an empty scanned file means "yes").
_repo_scanned() {
  [ -s "$SCANNED_REPOS_FILE" ] || return 0
  grep -qxF "$1" "$SCANNED_REPOS_FILE"
}

# Write state entries to temp files so we can iterate without piping into while
jq -c '.reviewed[]?' "$TMPDIR/state.json" > "$TMPDIR/reviewed_entries.jsonl" 2>/dev/null || true
jq -c '.in_progress[]?' "$TMPDIR/state.json" > "$TMPDIR/in_progress_entries.jsonl" 2>/dev/null || true

# Evict from state.reviewed
while IFS= read -r entry; do
  repo=$(echo "$entry" | jq -r '.repo')
  number=$(echo "$entry" | jq -r '.number')
  reviewed_at=$(echo "$entry" | jq -r '.reviewed_at // empty')
  key="${repo}:${number}"

  evict=false
  reason=""

  # Not in open+labeled set (closed, merged, or label removed) — but only
  # meaningful for a repo this run actually scanned; an unscanned repo's entry
  # is carried forward, not evicted.
  if _repo_scanned "$repo" && ! grep -qF "$key" "$TMPDIR/open_keys.txt"; then
    evict=true
    reason="no longer open/labeled"
  fi

  # TTL check
  if [ "$evict" = false ] && [ -n "$reviewed_at" ]; then
    entry_epoch=$(iso_to_epoch "$reviewed_at")
    age_days=$(( (NOW_EPOCH - entry_epoch) / 86400 ))
    if [ "$age_days" -gt "$TTL_DAYS" ]; then
      evict=true
      reason="TTL expired (${age_days}d)"
    fi
  fi

  if [ "$evict" = true ]; then
    [ "$VERBOSE" = true ] && echo "  Evicting reviewed $key: $reason" >&2
    echo "$key" >> "$TMPDIR/evict_keys.txt"
  fi
done < "$TMPDIR/reviewed_entries.jsonl"

# Evict from state.in_progress
while IFS= read -r entry; do
  repo=$(echo "$entry" | jq -r '.repo')
  number=$(echo "$entry" | jq -r '.number')
  started_at=$(echo "$entry" | jq -r '.started_at // empty')
  key="${repo}:${number}"

  evict=false
  reason=""

  # Not in open+labeled set — scoped to scanned repos (see reviewed loop above).
  if _repo_scanned "$repo" && ! grep -qF "$key" "$TMPDIR/open_keys.txt"; then
    evict=true
    reason="no longer open/labeled"
  fi

  # Stale in_progress (> 30 min)
  if [ "$evict" = false ] && [ -n "$started_at" ]; then
    entry_epoch=$(iso_to_epoch "$started_at")
    age_min=$(( (NOW_EPOCH - entry_epoch) / 60 ))
    if [ "$age_min" -gt "$STALE_THRESHOLD_MIN" ]; then
      evict=true
      reason="stale in_progress (${age_min}min)"
    fi
  fi

  if [ "$evict" = true ]; then
    [ "$VERBOSE" = true ] && echo "  Evicting in_progress $key: $reason" >&2
    echo "$key" >> "$TMPDIR/evict_keys.txt"
  fi
done < "$TMPDIR/in_progress_entries.jsonl"

# Apply evictions to state
EVICTED=$(wc -l < "$TMPDIR/evict_keys.txt" | tr -d ' ')

if [ "$EVICTED" -gt 0 ]; then
  while IFS= read -r evict_key; do
    evict_repo="${evict_key%%:*}"
    evict_number="${evict_key##*:}"
    jq --arg repo "$evict_repo" --argjson num "$evict_number" \
      '.in_progress = [.in_progress[] | select(.repo != $repo or .number != $num)] |
       .reviewed = [.reviewed[] | select(.repo != $repo or .number != $num)]' \
      "$TMPDIR/state.json" > "$TMPDIR/state_tmp.json"
    mv "$TMPDIR/state_tmp.json" "$TMPDIR/state.json"
  done < "$TMPDIR/evict_keys.txt"
fi

[ "$VERBOSE" = true ] && echo "Eviction pass: removed $EVICTED entries" >&2

# --- Step 3: Check candidates against state and review API ---
CANDIDATES_FILE="$TMPDIR/candidates.jsonl"
SKIPPED_IN_PROGRESS=0
SKIPPED_REVIEWED=0

if [ ! -s "$CANDIDATES_FILE" ]; then
  [ "$VERBOSE" = true ] && echo "No candidates found." >&2
else
  while IFS= read -r candidate; do
    repo=$(echo "$candidate" | jq -r '.repo')
    number=$(echo "$candidate" | jq -r '.number')
    head_sha=$(echo "$candidate" | jq -r '.head_sha')

    [ "$VERBOSE" = true ] && echo "  Checking $repo#$number (HEAD: ${head_sha:0:7})..." >&2

    # Check state.reviewed first (fast path, no API call)
    reviewed_sha=$(jq -r \
      --arg repo "$repo" --argjson num "$number" \
      '[.reviewed[] | select(.repo == $repo and .number == $num) | .head_sha] | first // empty' \
      "$TMPDIR/state.json")

    if [ -n "$reviewed_sha" ] && [ "$reviewed_sha" = "$head_sha" ]; then
      [ "$VERBOSE" = true ] && echo "    Skipping: reviewed in state (SHA match)" >&2
      SKIPPED_REVIEWED=$((SKIPPED_REVIEWED + 1))
      continue
    fi

    # Check state.in_progress (not stale — stale ones were already evicted)
    in_progress=$(jq -r \
      --arg repo "$repo" --argjson num "$number" \
      '[.in_progress[] | select(.repo == $repo and .number == $num) | .head_sha] | first // empty' \
      "$TMPDIR/state.json")

    if [ -n "$in_progress" ]; then
      [ "$VERBOSE" = true ] && echo "    Skipping: in_progress" >&2
      SKIPPED_IN_PROGRESS=$((SKIPPED_IN_PROGRESS + 1))
      continue
    fi

    # Fallback: check SHA marker via reviews API (for entries not yet in state)
    last_reviewed_sha=$(gh api \
      "repos/$repo/pulls/$number/reviews" \
      --paginate \
      --jq ".[] | select(.user.login == \"$BOT_USER\") | select(.body | contains(\"$REVIEW_MARKER\")) | .body" \
      2>/dev/null \
      | grep -oE '<!-- reviewed: [a-f0-9]+ -->' \
      | tail -1 \
      | sed -E 's/<!-- reviewed: ([a-f0-9]+) -->/\1/' \
      || true)

    if [ -n "$last_reviewed_sha" ] && [ "$last_reviewed_sha" = "$head_sha" ]; then
      [ "$VERBOSE" = true ] && echo "    Skipping: already reviewed at $head_sha (API check)" >&2
      # Backfill state so we skip faster next time
      jq --arg repo "$repo" --argjson num "$number" --arg sha "$head_sha" --arg ts "$SCAN_TIME" \
        '.reviewed += [{"repo": $repo, "number": $num, "head_sha": $sha, "reviewed_at": $ts}]' \
        "$TMPDIR/state.json" > "$TMPDIR/state_tmp.json"
      mv "$TMPDIR/state_tmp.json" "$TMPDIR/state.json"
      SKIPPED_REVIEWED=$((SKIPPED_REVIEWED + 1))
      continue
    fi

    [ "$VERBOSE" = true ] && echo "    Eligible for review" >&2
    jq --argjson pr "$candidate" '. += [$pr]' "$QUEUE_FILE" > "$TMPDIR/queue_tmp.json"
    mv "$TMPDIR/queue_tmp.json" "$QUEUE_FILE"

  done < "$CANDIDATES_FILE"
fi

ELIGIBLE=$(jq 'length' "$QUEUE_FILE")

# --- Step 4: Write reports (skipped in dry-run mode) ---

if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would write latest.json, state.json, history.json to $REPORTS_DIR" >&2
  echo "[DRY RUN] Summary: repos=$REPOS_SCANNED candidates=$CANDIDATES_FOUND eligible=$ELIGIBLE skipped_reviewed=$SKIPPED_REVIEWED skipped_in_progress=$SKIPPED_IN_PROGRESS evicted=$EVICTED" >&2
else
  # latest.json
  LATEST_JSON=$(jq -n \
    --arg scan_id "$SCAN_ID" \
    --arg date "$SCAN_TIME" \
    --argjson repos_scanned "$REPOS_SCANNED" \
    --argjson candidates_found "$CANDIDATES_FOUND" \
    --argjson eligible_prs "$(cat "$QUEUE_FILE")" \
    '{scan_id: $scan_id, date: $date, repos_scanned: $repos_scanned, candidates_found: $candidates_found, eligible_prs: $eligible_prs}')

  # Subset carry-forward (steps 3/4 of the run-path spec's contract): on a
  # narrowed run, merge the prior latest.json's eligible_prs for UNSCANNED repos
  # back in, so the fixer's queue (which reads .eligible_prs) is not truncated to
  # just the scanned repos.
  #
  # BUT the carried set is a stale snapshot: a PR the fixer has since reviewed
  # (now in state.reviewed / in_progress, PR still open) would be re-listed as
  # eligible, and `pr-review-fixer.sh begin` re-queues every eligible entry
  # unconditionally -> a duplicate review of an unchanged PR. So filter the
  # carried set against the CURRENT state ($TMPDIR/state.json, already loaded and
  # evicted this run): drop any carried entry whose repo/number is in
  # reviewed/in_progress at the SAME head_sha (mirrors the per-candidate skip at
  # the review step). A head_sha change means the PR moved on and is legitimately
  # eligible again, so it is kept.
  if [ -n "${REPOMAN_SUBSET_REPOS:-}" ] && [ -f "$REPORTS_DIR/latest.json" ]; then
    SCANNED_JSON=$(printf '%s\n' "$REPOMAN_SUBSET_REPOS" \
      | jq -R 'select(length>0)' | jq -s '.' 2>/dev/null || echo '[]')
    # "handled" = {repo, number, head_sha} already reviewed/in_progress now.
    HANDLED_JSON=$(jq -c '[(.reviewed[]?, .in_progress[]?) | {repo, number, head_sha}]' \
      "$TMPDIR/state.json" 2>/dev/null || echo '[]')
    CARRY_ELIGIBLE=$(jq -c --argjson scanned "$SCANNED_JSON" --argjson handled "$HANDLED_JSON" '
      [ .eligible_prs[]?
        | select(.repo as $r | ($scanned | index($r)) | not)             # unscanned only
        | select( . as $e
            | ($handled | any(.repo == $e.repo and .number == $e.number
                               and .head_sha == $e.head_sha)) | not ) ]   # not already handled at this SHA
      ' "$REPORTS_DIR/latest.json" 2>/dev/null || echo '[]')
    LATEST_JSON=$(printf '%s' "$LATEST_JSON" \
      | jq -c --argjson carry "$CARRY_ELIGIBLE" '.eligible_prs += $carry' 2>/dev/null || printf '%s' "$LATEST_JSON")
  fi

  write_report_latest "$REPORTS_DIR" "$LATEST_JSON"
  [ "$VERBOSE" = true ] && echo "Wrote $REPORTS_DIR/latest.json" >&2

  # state.json (envelope v1, atomic write from file)
  pr_review_state_write "$TMPDIR/state.json" "$REPORTS_DIR/state.json" "pr-review-scanner"
  [ "$VERBOSE" = true ] && echo "Wrote $REPORTS_DIR/state.json" >&2

  # history.json — skip on a subset run (full-set trend series; see run-path spec).
  if [ -n "${REPOMAN_SUBSET_REPOS:-}" ]; then
    [ "$VERBOSE" = true ] && echo "Subset run — skipping history.json append" >&2
  else
    HISTORY_ROW=$(jq -n \
      --arg scan_id "$SCAN_ID" \
      --arg date "$SCAN_TIME" \
      --argjson repos_scanned "$REPOS_SCANNED" \
      --argjson eligible "$ELIGIBLE" \
      --argjson skipped_in_progress "$SKIPPED_IN_PROGRESS" \
      --argjson skipped_reviewed "$SKIPPED_REVIEWED" \
      --argjson evicted "$EVICTED" \
      '{scan_id: $scan_id, date: $date, repos_scanned: $repos_scanned, eligible: $eligible, skipped_in_progress: $skipped_in_progress, skipped_reviewed: $skipped_reviewed, evicted: $evicted}')

    append_history_row "$REPORTS_DIR" "$HISTORY_ROW" "$MAX_HISTORY_ROWS"
    [ "$VERBOSE" = true ] && echo "Appended to $REPORTS_DIR/history.json" >&2
  fi
fi

# --- Output (backward compatible) ---
cat "$QUEUE_FILE"
