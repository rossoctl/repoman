#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Link Health Scanner
# Scans all repos for broken links, creates/closes GitHub issues, writes reports.
#
# Usage:
#   bash link-health-scanner.sh                  # full run
#   bash link-health-scanner.sh --dry-run        # scan + report, no issues/PRs
#   bash link-health-scanner.sh --issue-limit 3  # create at most 3 issues
#   bash link-health-scanner.sh --dry-run --issue-limit 3  # combined
# =============================================================================

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- CLI args ---
DRY_RUN=false
ISSUE_LIMIT=0  # 0 = unlimited

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --issue-limit) ISSUE_LIMIT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# LINK_CHECKER selects the link checker. Default python ([repoman#3](https://github.com/rossoctl/repoman/issues/3)): the
# stdlib checker needs only python3, so the program runs on a basic agent
# image; lychee stays available as an opt-in fallback.
LINK_CHECKER="${LINK_CHECKER:-python}"
case "$LINK_CHECKER" in
  python|lychee) ;;
  *)
    echo "ERROR: LINK_CHECKER must be 'python' or 'lychee' (got: $LINK_CHECKER)" >&2
    exit 2
    ;;
esac

# Shadow mode: write the same report document to LINK_HEALTH_SHADOW_OUT and
# force dry-run mutation behavior so a python side-by-side run cannot poison
# the production baseline or file issues.
if [ -n "${LINK_HEALTH_SHADOW_OUT:-}" ]; then
  DRY_RUN=true
fi

# Resolve deployment constants (repos_dir, fork_owner) from ~/.repoman/config.json.
repoman_config

# --- Configuration ---
REPORTS_DIR="${REPORTS_DIR:-$HOME/reports/link-health}"

# Report-PR destination. The org main repo's docs/ folder feeds the docs site
# (rossoctl.dev) and cannot host machine-generated reports, so the standing
# report PR lands under automation-health/ in the automation repo. A single
# file, overwritten in place each run: trend tooling reconstructs history by
# replaying git commit parents, so we store state (not dated snapshots) and
# avoid the files-vs-diffs-on-Git anti-pattern (rossoctl/automation#44).
# TODO(RepoMan Phase 2): move report_target_repo to programs/link-health.json.
REPORT_TARGET_REPO="rossoctl/automation"
REPORT_TARGET_OWNER="${REPORT_TARGET_REPO%%/*}"
REPORT_TARGET_NAME="${REPORT_TARGET_REPO##*/}"
REPORT_TARGET_PATH="automation-health/link-health.md"

# Provenance footer for the report-PR body. Resolved once at startup: the
# helper lazily writes _meta.<skill>.json beside this skill and returns the pinned-SHA
# RepoMan attribution (linkless footer when the SHA cannot be resolved).
SKILL_FOOTER=$(skill_attribution "link-health-scanner")

# Clone dir for the report target: honor an explicit MAIN_REPO_DIR override,
# else derive from the owner-namespaced layout ($REPOS_DIR/<owner>/<name>).
REPORT_TARGET_DIR="${MAIN_REPO_DIR:-$REPOS_DIR/$REPORT_TARGET_OWNER/$REPORT_TARGET_NAME}"

# Fork remote name for the report-target push. Derived from the profile so it
# carries no org literal; a stale remote of this name is corrected below.
FORK_REMOTE="$FORK_OWNER-automation-fork"
SCAN_DATE=$(date -u +"%Y-%m-%d")
SCAN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAX_HISTORY_ROWS=500
ESCALATION_THRESHOLD=20

# --- Workspace setup ---
setup_workspace "link-scanner"
TMPDIR="$PROGRAM_TMPDIR"
mkdir -p "$REPORTS_DIR"

# --- Scan ID ---
SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "$SCAN_DATE")

echo "=== Link Health Scan $SCAN_ID ==="
echo "Repos dir: $REPOS_DIR"
echo "Reports dir: $REPORTS_DIR"
echo "Link checker: $LINK_CHECKER"
if [ "$DRY_RUN" = true ]; then echo "Mode: DRY RUN (no issues, no PRs)"; fi
if [ -n "${LINK_HEALTH_SHADOW_OUT:-}" ]; then echo "Shadow out: $LINK_HEALTH_SHADOW_OUT"; fi
if [ "$ISSUE_LIMIT" -gt 0 ]; then echo "Issue limit: $ISSUE_LIMIT"; fi

# --- Scan all repos ---
TOTAL_LINKS=0
TOTAL_ERRORS=0
REPOS_SCANNED=0
REPOS_FAILED=0

# Collect all findings (broken + unchecked) then split. Unchecked (egress
# refusals) never open or auto-close issues.
: > "$TMPDIR/all_findings.jsonl"
: > "$TMPDIR/broken.jsonl"
: > "$TMPDIR/unchecked.jsonl"
# Repos whose checker run failed this scan (crash, no output, bad JSON).
# They contribute no findings, which is not evidence their links were
# fixed; their prior findings are re-injected before the diff.
: > "$TMPDIR/failed_repos.txt"

# Drive the loop from the enrolled set (authoritative), statting each clone,
# rather than globbing "$REPOS_DIR"/*/ and filtering -- a "*/" glob silently
# drops a ".github" repo. enrolled_clone_dirs emits each enrolled owner/name
# whose clone exists; the here-string keeps the body in the current shell so
# counters accumulate.
ENROLLED=$(repoman_load_enrolled) || exit 1
CLONES=$(enrolled_clone_dirs "$ENROLLED")

while IFS= read -r full_repo; do
  [ -n "$full_repo" ] || continue
  repo_dir="$REPOS_DIR/$full_repo"

  echo "Scanning $full_repo..."

  # Key the temp file on the full owner/name (slash flattened to _), not the
  # bare name: rossoctl/cortex and alice/cortex share a bare name, and keying
  # on it would make the second scan overwrite the first (the [ ! -s ] guard
  # cannot catch it -- the file is non-empty). That same-name-different-owner
  # case is exactly what the owner-namespaced model exists to support.
  safe_repo="${full_repo//\//_}"
  CHECK_OUTPUT="$TMPDIR/linkcheck_${safe_repo}.json"

  # Scanner-level args applied to all repos. Shared by lychee and link-check.py.
  LINK_CHECKER_ARGS=(
    --format json
    --scheme http --scheme https
    --exclude 'localhost' --exclude '127\.0\.0\.1' --exclude 'localtest\.me'
    --exclude 'example\.com' --exclude 'example\.org'
    --exclude-all-private
    --exclude-path 'node_modules' --exclude-path 'vendor' --exclude-path '\.claude'
    --accept '200,204,206,403,429,502,503'
    --exclude 'console\.cloud\.google\.com'
    --timeout 10
    --max-retries 2
    --max-concurrency 8
  )

  CONFIG_ARGS=()
  if [ -f "$repo_dir/.lychee.toml" ]; then
    CONFIG_ARGS=(--config "$repo_dir/.lychee.toml")
  fi

  # Keep the checker's stderr (tracebacks, WARN lines) so failures are
  # diagnosable; it was previously discarded with 2>/dev/null.
  CHECK_STDERR="$TMPDIR/linkcheck_${safe_repo}.stderr"
  CHECKER_RC=0
  if [ "$LINK_CHECKER" = "python" ]; then
    python3 "$SCRIPT_DIR/link-check.py" "${LINK_CHECKER_ARGS[@]}" \
      ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"} "$repo_dir" \
      > "$CHECK_OUTPUT" 2> "$CHECK_STDERR" || CHECKER_RC=$?
  else
    # lychee exits 1 when it merely finds broken links; only the python
    # checker's exit code is fatal (it exits 0 unless it crashed).
    lychee "${LINK_CHECKER_ARGS[@]}" \
      ${CONFIG_ARGS[@]+"${CONFIG_ARGS[@]}"} "$repo_dir" \
      > "$CHECK_OUTPUT" 2> "$CHECK_STDERR" || CHECKER_RC=$?
  fi

  if [ "$LINK_CHECKER" = "python" ] && [ "$CHECKER_RC" -ne 0 ]; then
    echo "  WARN: link-check.py exited $CHECKER_RC for $full_repo; stderr:" >&2
    head -50 "$CHECK_STDERR" | sed 's/^/    /' >&2
    REPOS_FAILED=$((REPOS_FAILED + 1))
    printf '%s\n' "$full_repo" >> "$TMPDIR/failed_repos.txt"
    continue
  fi

  if [ ! -s "$CHECK_OUTPUT" ]; then
    echo "  WARN: $LINK_CHECKER produced no output for $full_repo; stderr:" >&2
    head -50 "$CHECK_STDERR" | sed 's/^/    /' >&2
    REPOS_FAILED=$((REPOS_FAILED + 1))
    printf '%s\n' "$full_repo" >> "$TMPDIR/failed_repos.txt"
    continue
  fi

  # Truncated output (a crash mid-write) must not kill the whole scanner via
  # set -e on the jq reads below; treat it as a failed repo instead.
  if ! jq empty "$CHECK_OUTPUT" >/dev/null 2>&1; then
    echo "  WARN: $LINK_CHECKER emitted invalid JSON for $full_repo; stderr:" >&2
    head -50 "$CHECK_STDERR" | sed 's/^/    /' >&2
    REPOS_FAILED=$((REPOS_FAILED + 1))
    printf '%s\n' "$full_repo" >> "$TMPDIR/failed_repos.txt"
    continue
  fi

  # Parse results
  repo_total=$(jq '.total // 0' "$CHECK_OUTPUT")
  repo_errors=$(jq '.errors // 0' "$CHECK_OUTPUT")
  TOTAL_LINKS=$((TOTAL_LINKS + repo_total))
  TOTAL_ERRORS=$((TOTAL_ERRORS + repo_errors))
  REPOS_SCANNED=$((REPOS_SCANNED + 1))

  # Surface checker warnings (unsupported .lychee.toml keys, bad regexes,
  # non-integer accepts) on a healthy run too; CHECK_STDERR was previously
  # only printed on failure, so config problems were invisible.
  if [ -s "$CHECK_STDERR" ]; then
    grep '^WARN' "$CHECK_STDERR" | head -10 | sed 's/^/    /' >&2 || true
  fi

  # Extract findings from the checker report. Parsing/suppression/status
  # normalization lives in extract-broken-links.sh (unit-tested).
  "$SCRIPT_DIR/extract-broken-links.sh" \
    "$CHECK_OUTPUT" "$full_repo" "$repo_dir" \
    >> "$TMPDIR/all_findings.jsonl" 2>/dev/null || true

  echo "  Links: $repo_total, Errors: $repo_errors"
done <<< "$CLONES"

# Split unchecked (egress refusals) out of the broken set. Unchecked never
# opens or auto-closes an issue; it is reported for the owner to widen egress.
if [ -s "$TMPDIR/all_findings.jsonl" ]; then
  jq -c 'select(.status != "unchecked")' "$TMPDIR/all_findings.jsonl" \
    > "$TMPDIR/broken.jsonl" 2>/dev/null || : > "$TMPDIR/broken.jsonl"
  jq -c 'select(.status == "unchecked")' "$TMPDIR/all_findings.jsonl" \
    > "$TMPDIR/unchecked.jsonl" 2>/dev/null || : > "$TMPDIR/unchecked.jsonl"
else
  : > "$TMPDIR/broken.jsonl"
  : > "$TMPDIR/unchecked.jsonl"
fi

UNCHECKED_COUNT=$(jq -s 'length' "$TMPDIR/unchecked.jsonl" 2>/dev/null || echo 0)
UNCHECKED_TOP_HOSTS_JSON=$(jq -s -c '
  [ .[] | .url | capture("//(?<h>[^/]+)") | .h ]
  | group_by(.)
  | map({host: .[0], count: length})
  | sort_by(-.count)
  | .[0:10]
' "$TMPDIR/unchecked.jsonl" 2>/dev/null || echo '[]')
UNCHECKED_TOP_HOSTS_TEXT=$(echo "$UNCHECKED_TOP_HOSTS_JSON" | jq -r '
  if length == 0 then "(none)"
  else map("\(.host) (\(.count))") | join(", ")
  end
' 2>/dev/null || echo "(none)")

echo ""
echo "=== Scan complete ==="
echo "Repos scanned: $REPOS_SCANNED (failed: $REPOS_FAILED)"
echo "Total links: $TOTAL_LINKS, Total errors: $TOTAL_ERRORS"
echo "Unchecked (egress refusals): $UNCHECKED_COUNT"
if [ "$UNCHECKED_COUNT" -gt 0 ]; then
  echo "Unchecked top hosts: $UNCHECKED_TOP_HOSTS_TEXT"
fi

# --- Load previous scan for diffing ---
# Subset-run carry-forward (see docs/specs run-path, "Subset-aware stateful
# scanners"): when REPOMAN_SUBSET_REPOS is set, this run scanned only those
# repos. The diff must compare like-for-like, so the previous report is split
# into the findings for SCANNED repos (which participate in the diff) and the
# findings for UNSCANNED repos (carried forward verbatim into latest.json,
# never diffed, so their issues are never mis-closed as "fixed").
ALL_PREV_BROKEN="$TMPDIR/all_prev_broken.jsonl"
PREV_BROKEN="$TMPDIR/prev_broken.jsonl"
CARRY_BROKEN="$TMPDIR/carry_broken.jsonl"
: > "$CARRY_BROKEN"
if [ -f "$REPORTS_DIR/latest.json" ]; then
  jq -c '.broken[]?' "$REPORTS_DIR/latest.json" > "$ALL_PREV_BROKEN" 2>/dev/null || true
else
  : > "$ALL_PREV_BROKEN"
fi
if [ -n "${REPOMAN_SUBSET_REPOS:-}" ]; then
  # Build a JSON array of the scanned owner/name slugs once, pass via --argjson.
  SCANNED_JSON=$(printf '%s\n' "$REPOMAN_SUBSET_REPOS" \
    | jq -R 'select(length>0)' | jq -s '.' 2>/dev/null || echo '[]')
  # prev findings whose .repo IS in the scanned set -> participate in the diff
  jq -c --argjson scanned "$SCANNED_JSON" \
    'select(.repo as $r | $scanned | index($r))' \
    "$ALL_PREV_BROKEN" > "$PREV_BROKEN" 2>/dev/null || : > "$PREV_BROKEN"
  # prev findings whose .repo is NOT in the scanned set -> carried forward
  jq -c --argjson scanned "$SCANNED_JSON" \
    'select(.repo as $r | ($scanned | index($r)) | not)' \
    "$ALL_PREV_BROKEN" > "$CARRY_BROKEN" 2>/dev/null || : > "$CARRY_BROKEN"
else
  cp "$ALL_PREV_BROKEN" "$PREV_BROKEN"
fi

# Do not auto-close a previously broken link that is unchecked this run
# (egress refusal is not evidence the link was fixed). Re-inject the prior
# broken record (old status) into the current broken set so the diff treats
# it as recurring. A later real HTTP success still closes it; a later real
# 404 stays open.
if [ -s "$TMPDIR/unchecked.jsonl" ] && [ -s "$PREV_BROKEN" ]; then
  UNCHECKED_ARR=$(jq -s '.' "$TMPDIR/unchecked.jsonl" 2>/dev/null || echo '[]')
  PREV_ARR=$(jq -s '.' "$PREV_BROKEN" 2>/dev/null || echo '[]')
  jq -n -c --argjson unchecked "$UNCHECKED_ARR" --argjson prev "$PREV_ARR" '
    ($unchecked | map([.repo, .file, .url] | join("|"))) as $keys |
    $prev[] |
    select(([.repo, .file, .url] | join("|")) as $k | ($keys | index($k)) != null)
  ' >> "$TMPDIR/broken.jsonl" 2>/dev/null || true
fi

# Same rule for repos whose checker run failed: they produced no findings,
# which is not evidence anything was fixed. Without this, every previously
# broken link in a failed repo diffs as "fixed" and its issue auto-closes
# while repos_failed merely ticks up.
if [ -s "$TMPDIR/failed_repos.txt" ] && [ -s "$PREV_BROKEN" ]; then
  FAILED_ARR=$(jq -Rsc 'split("\n") | map(select(length > 0))' "$TMPDIR/failed_repos.txt" 2>/dev/null || echo '[]')
  PREV_F_ARR=$(jq -s '.' "$PREV_BROKEN" 2>/dev/null || echo '[]')
  jq -n -c --argjson failed "$FAILED_ARR" --argjson prev "$PREV_F_ARR" '
    $prev[] | select(.repo as $r | ($failed | index($r)) != null)
  ' >> "$TMPDIR/broken.jsonl" 2>/dev/null || true
fi

# --- Compute diff using shared library ---
DIFF_KEY='[.repo, .file, .url] | join("|")'
read -r NEW_LINKS FIXED_LINKS RECURRING_LINKS < <(
  diff_against_previous "$TMPDIR/broken.jsonl" "$PREV_BROKEN" "$DIFF_KEY"
)

echo "Delta: +$NEW_LINKS new, -$FIXED_LINKS fixed, $RECURRING_LINKS recurring"

# --- Count by category ---
BROKEN_INTERNAL=$(jq -s '[.[] | select(.category == "internal")] | length' "$TMPDIR/broken.jsonl" 2>/dev/null || echo 0)
BROKEN_EXTERNAL=$(jq -s '[.[] | select(.category == "external")] | length' "$TMPDIR/broken.jsonl" 2>/dev/null || echo 0)

# --- Create GitHub issues for NEW broken links ---
ISSUES_CREATED=0

# new_keys.txt was already written by diff_against_previous

while IFS='|' read -r issue_repo issue_file issue_url; do
  [ -z "$issue_repo" ] && continue

  # Check issue limit
  if [ "$ISSUE_LIMIT" -gt 0 ] && [ "$ISSUES_CREATED" -ge "$ISSUE_LIMIT" ]; then
    echo "  SKIP (issue limit $ISSUE_LIMIT reached): $issue_file:$issue_url"
    continue
  fi

  # Get the full broken link record
  link_record=$(jq -c "select(.repo == \"$issue_repo\" and .file == \"$issue_file\" and .url == \"$issue_url\")" "$TMPDIR/broken.jsonl" | head -1)
  [ -z "$link_record" ] && continue

  link_status=$(echo "$link_record" | jq -r '.status')
  link_category=$(echo "$link_record" | jq -r '.category')
  if [ "$link_category" = "internal" ]; then
    category_label="broken-link/internal"
  else
    category_label="broken-link/external"
  fi

  # Deduplication: skip if an open issue already exists for this link
  existing=$(gh_issue_exists "$issue_repo" "Broken link in $issue_file: $issue_url" || true)

  if [ -n "$existing" ]; then
    echo "  Issue #$existing already exists for $issue_file:$issue_url"
    continue
  fi

  # Create issue
  issue_title=":bug: Broken link in $issue_file: $issue_url"
  # Truncate title if too long (GitHub limit is 256)
  if [ ${#issue_title} -gt 250 ]; then
    issue_title="${issue_title:0:247}..."
  fi

  # Build verification note for ambiguous status codes
  verify_note=""
  case "$link_status" in
    *403*) verify_note="
> **Note:** This URL returned 403 (Forbidden). Some sites block automated scanners. The link may be valid when accessed from a browser. Please verify manually before fixing." ;;
    *503*) verify_note="
> **Note:** This URL returned 503 (Service Unavailable), which may indicate a temporarily unavailable service rather than a permanently broken link. Please verify manually before fixing." ;;
    *429*) verify_note="
> **Note:** This URL returned 429 (Too Many Requests). The link may be valid but rate-limited. Please verify manually before fixing." ;;
  esac

  issue_body="## Describe the bug

Broken link detected by automated link health scan.

**Repo:** $issue_repo
**File:** $issue_file
**Broken URL:** $issue_url
**HTTP Status:** $link_status
**First detected:** $SCAN_DATE
**Scan ID:** $SCAN_ID
$verify_note
## Steps To Reproduce

1. Open https://github.com/$issue_repo/blob/main/$issue_file
2. Click or follow the link to \`$issue_url\`
3. Observe $link_status error

## Expected Behavior

The link should resolve to valid documentation.

## Additional Context

Category: $link_category
Detected by RepoMan Link Health Scanner (cron: link-health-scanner)"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would create issue on $issue_repo: $issue_file:$issue_url ($link_category)"
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
  elif gh issue create --repo "$issue_repo" \
    --title "$issue_title" \
    --label "kind/bug,$category_label" \
    --body "$issue_body" 2>/dev/null; then
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
    echo "  Created issue for $issue_file:$issue_url"
  else
    echo "  WARN: Failed to create issue for $issue_file:$issue_url"
  fi

  # Rate limit: small delay between issue creations
  sleep 1
done < "$TMPDIR/new_keys.txt"

echo "Issues created: $ISSUES_CREATED"

# --- Close issues for FIXED links ---
ISSUES_CLOSED=0

comm -13 "$TMPDIR/current_keys.txt" "$TMPDIR/prev_keys.txt" > "$TMPDIR/fixed_keys.txt"

while IFS='|' read -r fix_repo fix_file fix_url; do
  [ -z "$fix_repo" ] && continue

  # Get the category from the previous scan
  link_record=$(jq -c "select(.repo == \"$fix_repo\" and .file == \"$fix_file\" and .url == \"$fix_url\")" "$PREV_BROKEN" | head -1)
  link_category=$(echo "$link_record" | jq -r '.category // "internal"')

  if [ "$link_category" = "internal" ]; then
    category_label="broken-link/internal"
  else
    category_label="broken-link/external"
  fi

  # Find the open issue for this link (empty string if none exists)
  issue_number=$(gh_issue_exists "$fix_repo" "Broken link in $fix_file: $fix_url" || true)

  # Skip if no matching issue was found
  if [ -z "$issue_number" ]; then
    continue
  fi

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would close issue #$issue_number for $fix_file:$fix_url"
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
  elif close_issue_if_valid "$fix_repo" "$issue_number" \
    "Link verified as fixed in scan $SCAN_ID ($SCAN_DATE). Auto-closing."; then
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
    echo "  Closed issue #$issue_number for $fix_file:$fix_url"
  fi
done < "$TMPDIR/fixed_keys.txt"

echo "Issues closed: $ISSUES_CLOSED"

# --- Write latest.json ---
# Fresh findings for the scanned repos get the standard enrichment. On a subset
# run, the previous findings for UNSCANNED repos are carried forward verbatim
# (they already carry issue_number/first_detected from the prior report), so the
# baseline stays whole and the next full run diffs against a complete picture.
BROKEN_ARRAY=$(jq -s '
  [.[] | . + {
    issue_number: null,
    first_detected: "'"$SCAN_DATE"'",
    context: ""
  }]
' "$TMPDIR/broken.jsonl" 2>/dev/null || echo "[]")
if [ -s "$CARRY_BROKEN" ]; then
  CARRY_ARRAY=$(jq -s '.' "$CARRY_BROKEN" 2>/dev/null || echo "[]")
  BROKEN_ARRAY=$(jq -n --argjson a "$BROKEN_ARRAY" --argjson b "$CARRY_ARRAY" '$a + $b' 2>/dev/null || printf '%s' "$BROKEN_ARRAY")
fi

# On a subset run the broken[] list is whole-set (carried forward), so keep the
# prior report's whole-set scalar totals rather than the subset-only counts, or
# the dashboard would read a subset repos_scanned/total_links_checked beside a
# whole-set broken[]. Per-run delta (new/fixed/recurring) still reflects this run.
if [ -n "${REPOMAN_SUBSET_REPOS:-}" ] && [ -f "$REPORTS_DIR/latest.json" ]; then
  REPOS_SCANNED=$(jq -r '.repos_scanned // '"$REPOS_SCANNED" "$REPORTS_DIR/latest.json" 2>/dev/null || echo "$REPOS_SCANNED")
  TOTAL_LINKS=$(jq -r '.total_links_checked // '"$TOTAL_LINKS" "$REPORTS_DIR/latest.json" 2>/dev/null || echo "$TOTAL_LINKS")
fi

LATEST_JSON=$(cat << LATEST_EOF
{
  "scan_id": "$SCAN_ID",
  "date": "$SCAN_TIME",
  "duration_seconds": $SECONDS,
  "model": "script",
  "repos_scanned": $REPOS_SCANNED,
  "repos_failed": $REPOS_FAILED,
  "total_links_checked": $TOTAL_LINKS,
  "broken": $BROKEN_ARRAY,
  "unchecked_count": $UNCHECKED_COUNT,
  "unchecked_top_hosts": $UNCHECKED_TOP_HOSTS_JSON,
  "delta": {
    "new": $NEW_LINKS,
    "fixed": $FIXED_LINKS,
    "recurring": $RECURRING_LINKS
  }
}
LATEST_EOF
)

# Shadow side-report: write the same document without touching the baseline.
if [ -n "${LINK_HEALTH_SHADOW_OUT:-}" ]; then
  mkdir -p "$(dirname "$LINK_HEALTH_SHADOW_OUT")"
  printf '%s\n' "$LATEST_JSON" > "$LINK_HEALTH_SHADOW_OUT"
  echo "Wrote shadow report: $LINK_HEALTH_SHADOW_OUT"
fi

# A dry run must NOT write the baseline: overwriting latest.json would make the
# next real run see these findings as "recurring" (not "new") and skip filing
# them, and skip closing anything shown as fixed here. Preview only.
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would write latest.json (baseline left unchanged)"
else
  write_report_latest "$REPORTS_DIR" "$LATEST_JSON"
  echo "Wrote latest.json"
fi

# --- Append to history.json ---
HISTORY_ROW=$(cat << HIST_EOF
{
  "scan_id": "$SCAN_ID",
  "date": "$SCAN_TIME",
  "repos_scanned": $REPOS_SCANNED,
  "total_links_checked": $TOTAL_LINKS,
  "broken_internal": $BROKEN_INTERNAL,
  "broken_external": $BROKEN_EXTERNAL,
  "unchecked_count": $UNCHECKED_COUNT,
  "new": $NEW_LINKS,
  "fixed": $FIXED_LINKS,
  "issues_created": $ISSUES_CREATED,
  "issues_closed": $ISSUES_CLOSED
}
HIST_EOF
)

# history.json is a full-set trend series (consumed by the dashboard). A subset
# run is a rare manual recovery over part of the enrolled set; appending its
# partial counts would distort the trend, so we skip the history append on a
# subset run. (Trade-off: that run's issues-created/closed counts are not
# recorded to history — accepted; see docs/specs run-path, "Subset-aware
# stateful scanners".)
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would append history.json row (skipped)"
elif [ -n "${REPOMAN_SUBSET_REPOS:-}" ]; then
  echo "Subset run — skipping history.json append (trend series stays full-set)"
else
  append_history_row "$REPORTS_DIR" "$HISTORY_ROW" "$MAX_HISTORY_ROWS"
  echo "Appended to history.json"
fi

# Note: _index.json registration is performed by the run-path orchestrator
# (scripts/repoman-run.sh), the sole index writer — not here. Running this
# scanner directly no longer updates the registry; `repoman run link-health`
# is the blessed path for an indexed run. (Run path: issue #107, epic #72.)

# --- Update docs/link-health.md ---
# Build trend table from last 10 history entries (deduplicate same-day rows)
TREND_TABLE=$(jq -r '
  [group_by(.date | split("T")[0]) | .[] | last] | .[-10:] | reverse | .[] |
  "| \(.date | split("T")[0] | split("-")[1:] | join("-")) | \(.broken_internal) | \(.broken_external) | \(if .new > .fixed then "+\(.new - .fixed)" elif .new < .fixed then "\(.new - .fixed)" else "0" end) |"
' "$REPORTS_DIR/history.json" 2>/dev/null || echo "| - | - | - | - |")

# Build per-repo breakdown with issue counts
# Single org-wide query for all open scanner issues, then count client-side
issue_search=$(gh_with_backoff search issues "org:${REPORT_TARGET_REPO%%/*} in:title \"Broken link in\" state:open" --json repository --jq '.[].repository.nameWithOwner' 2>/dev/null || true)
# bash 3.2 (macOS default) has no associative arrays. Keep counts in a
# newline-delimited accumulator of "repo<TAB>count" rows; repo keys are
# owner/name (no whitespace), so tab-splitting is unambiguous.
ISSUE_COUNTS=""   # rows of "repo<TAB>count"

_lhs_ic_get() {   # $1=repo -> prints its count, or 0 if absent
  printf '%s\n' "$ISSUE_COUNTS" \
    | awk -F'\t' -v r="$1" '$1==r{c=$2; found=1} END{print (found ? c : 0)}'
}
_lhs_ic_incr() {  # $1=repo -> increment its count by 1
  local cur rest
  cur=$(_lhs_ic_get "$1")
  # Drop any existing row for this repo. Guard the empty case so we do not
  # feed awk a lone blank record (which would echo back an empty row).
  if [ -n "$ISSUE_COUNTS" ]; then
    rest=$(printf '%s\n' "$ISSUE_COUNTS" | awk -F'\t' -v r="$1" '$1!=r')
  else
    rest=""
  fi
  # Append the new count, keeping the accumulator free of leading blank rows.
  if [ -n "$rest" ]; then
    ISSUE_COUNTS="${rest}
$1	$(( cur + 1 ))"
  else
    ISSUE_COUNTS="$1	$(( cur + 1 ))"
  fi
}

if [ -n "$issue_search" ]; then
  while IFS= read -r r; do
    _lhs_ic_incr "$r"
  done <<< "$issue_search"
fi

# Single jq pass for per-repo internal/external counts
REPO_TABLE=""
repo_breakdown=$(jq -rs '
  group_by(.repo) | .[] |
  { repo: .[0].repo,
    internal: [.[] | select(.category == "internal")] | length,
    external: [.[] | select(.category == "external")] | length }
' "$TMPDIR/broken.jsonl" 2>/dev/null || true)
if [ -n "$repo_breakdown" ]; then
  while IFS= read -r row; do
    repo=$(echo "$row" | jq -r '.repo')
    short=$(echo "$repo" | cut -d/ -f2)
    int_count=$(echo "$row" | jq -r '.internal')
    ext_count=$(echo "$row" | jq -r '.external')
    issue_count=$(_lhs_ic_get "$repo")
    REPO_TABLE="${REPO_TABLE}| ${short} | ${int_count} | ${ext_count} | ${issue_count} |
"
  done < <(echo "$repo_breakdown" | jq -c '.')
else
  REPO_TABLE="| - | - | - | - |"
fi

SCAN_TIME_ET=$(TZ="America/New_York" date +"%Y-%m-%d %H:%M ET")

cat > "$TMPDIR/link-health.md" << DASHBOARD_EOF
# Link Health Report

> Last scan: $SCAN_TIME_ET | Scan ID: $SCAN_ID

## Summary

| Metric | Value |
|--------|-------|
| Repos scanned | $REPOS_SCANNED |
| Total links checked | $TOTAL_LINKS |
| Broken (internal) | $BROKEN_INTERNAL |
| Broken (external) | $BROKEN_EXTERNAL |
| Unchecked (egress refusals) | $UNCHECKED_COUNT |
| Unchecked top hosts | $UNCHECKED_TOP_HOSTS_TEXT |
| New since last scan | +$NEW_LINKS |
| Fixed since last scan | -$FIXED_LINKS |

## Trend (last 10 scans)

| Date | Internal | External | Delta |
|------|----------|----------|-------|
$TREND_TABLE

## Broken Links by Repo

| Repo | Internal | External | Issues |
|------|----------|----------|--------|
$REPO_TABLE

*Issues counts open GitHub issues filed by the scanner; a broken link may not yet have an issue (due to per-run limits) or may share an issue with another link in the same file.*

---
*Generated by RepoMan Link Health Scanner. Do not edit manually.*
DASHBOARD_EOF

# Commit and push dashboard
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would push $REPORT_TARGET_PATH to fork and create/update cross-fork PR against $REPORT_TARGET_REPO"
  echo "[DRY RUN] Dashboard preview:"
  cat "$TMPDIR/link-health.md"
else
  if [ ! -d "$REPORT_TARGET_DIR/.git" ]; then
    echo "ERROR: $REPORT_TARGET_DIR does not appear to be a git repository."
    echo "Export MAIN_REPO_DIR or set REPOS_DIR so $REPORT_TARGET_REPO can be found:"
    echo "  export MAIN_REPO_DIR=$REPOS_DIR/$REPORT_TARGET_OWNER/$REPORT_TARGET_NAME"
    exit 1
  fi

  cd "$REPORT_TARGET_DIR"

  # Ensure the fork remote exists AND points at the current target. set-url
  # corrects a stale remote (e.g. one left by a prior deployment pointing at the
  # old report repo); the || add branch handles the not-yet-registered case.
  fork_url="https://github.com/$FORK_OWNER/${REPORT_TARGET_NAME}.git"
  git remote set-url "$FORK_REMOTE" "$fork_url" 2>/dev/null \
    || git remote add "$FORK_REMOTE" "$fork_url"

  # Fetch fork's branch if it exists, otherwise create from main
  if git fetch "$FORK_REMOTE" link-health/reports 2>/dev/null; then
    git checkout -B link-health/reports "$FORK_REMOTE/link-health/reports"
  else
    git fetch "$FORK_REMOTE" main 2>/dev/null || true
    git checkout -B link-health/reports "$FORK_REMOTE/main" 2>/dev/null \
      || git checkout -B link-health/reports
  fi

  mkdir -p "$(dirname "$REPORT_TARGET_PATH")"
  cp "$TMPDIR/link-health.md" "$REPORT_TARGET_PATH"
  git add "$REPORT_TARGET_PATH"
  git commit -s -m "docs: Update link health dashboard ($SCAN_ID)" 2>/dev/null || echo "No changes to commit"
  git push "$FORK_REMOTE" link-health/reports 2>/dev/null || echo "WARN: Failed to push dashboard to fork"

  # Create or update standing cross-fork PR
  existing_pr=$(gh api "repos/$REPORT_TARGET_REPO/pulls?head=$FORK_OWNER:link-health/reports&state=open" \
    --jq '.[0].number' 2>/dev/null || echo "")

  pr_body="## Summary

Auto-updated by RepoMan Link Health Scanner. This PR is continuously updated with each scan. Merge when convenient.

| Metric | Value |
|--------|-------|
| Repos scanned | $REPOS_SCANNED |
| Broken (internal) | $BROKEN_INTERNAL |
| Broken (external) | $BROKEN_EXTERNAL |
| New since last scan | +$NEW_LINKS |
| Fixed since last scan | -$FIXED_LINKS |

## Related issue(s)

- $REPORT_TARGET_REPO#1178

## Automation program

$SKILL_FOOTER"

  if [ -z "$existing_pr" ] || [ "$existing_pr" = "null" ]; then
    gh pr create --repo "$REPORT_TARGET_REPO" \
      --head "$FORK_OWNER:link-health/reports" --base main \
      --title "docs: Link health report (auto-updated)" \
      --body "$pr_body" 2>/dev/null || echo "WARN: Failed to create dashboard PR"
  else
    gh pr edit "$existing_pr" --repo "$REPORT_TARGET_REPO" --body "$pr_body" 2>/dev/null || true
  fi
fi

echo "Dashboard updated"

# --- Escalation check ---
if [ "$NEW_LINKS" -gt "$ESCALATION_THRESHOLD" ]; then
  echo ""
  echo "ALERT: Link health scan found $NEW_LINKS new broken links (threshold: $ESCALATION_THRESHOLD)."
  echo "This may indicate a bulk documentation change or a widespread external service outage."
  echo "Review issues at https://github.com/$REPORT_TARGET_REPO/issues?q=label:broken-link"
fi

# --- Summary ---
echo ""
echo "=== Scan $SCAN_ID Summary ==="
echo "Repos: $REPOS_SCANNED scanned, $REPOS_FAILED failed"
echo "Links: $TOTAL_LINKS checked, $((BROKEN_INTERNAL + BROKEN_EXTERNAL)) broken ($BROKEN_INTERNAL internal, $BROKEN_EXTERNAL external)"
echo "Delta: +$NEW_LINKS new, -$FIXED_LINKS fixed, $RECURRING_LINKS recurring"
echo "Issues: $ISSUES_CREATED created, $ISSUES_CLOSED closed"
echo "Duration: ${SECONDS}s"
