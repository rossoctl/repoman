#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Dependency Bump Fixer — kagenti org
# Responds to scanner-created issues with severity-appropriate analysis comments
# on the Dependabot PRs. Does NOT auto-merge — provides actionable commentary.
#
# Usage:
#   bash dep-bump-fixer.sh --help
#   bash dep-bump-fixer.sh --dry-run
#   bash dep-bump-fixer.sh --live --issue-limit 3
# =============================================================================

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- CLI args ---
DRY_RUN=true  # Safe by default
ISSUE_LIMIT=15
VERBOSE=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --live) DRY_RUN=false; shift ;;
    --issue-limit) ISSUE_LIMIT="$2"; shift 2 ;;
    --verbose) VERBOSE=true; shift ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
dep-bump-fixer -- Analyze stale Dependabot PRs and post actionable comments

USAGE:
  dep-bump-fixer.sh [OPTIONS]

OPTIONS:
  --dry-run         Analyze and preview comments only (default)
  --live            Post comments on PRs and issues
  --issue-limit N   Process at most N issues (default: 5)
  --verbose         Print additional diagnostic output
  --help, -h        Show this help

ENVIRONMENT:
  REPOS_DIR         (required) Directory containing cloned org repos
  REPORTS_DIR       (optional) Where to write reports (default: ~/reports/dep-bump)

PREREQUISITES:
  bash 3.2+, gh (authenticated), jq
USAGE
  exit 0
fi

# Resolve deployment constants (repos_dir, fork_owner) from ~/.repoman/config.json.
repoman_config

# --- Configuration ---
validate_repos_dir "${REPOS_DIR:-}"

REPORTS_DIR="${REPORTS_DIR:-$HOME/reports/dep-bump}"
SCAN_DATE=$(date -u +"%Y-%m-%d")
SCAN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAX_HISTORY_ROWS=500
# Provenance footer appended to every fixer comment/issue. Resolved once at
# startup: the helper lazily writes _meta.<skill>.json beside this skill and returns the
# pinned-SHA attribution (linkless fallback when unresolved).
SKILL_FOOTER=$(skill_attribution "dep-bump-fixer")
# Stable dedup key: a regex (jq `test`, below) anchored to the footer so it
# matches a fixer comment but not a human comment that merely mentions the tool.
# It matches all three footer forms, regardless of the per-run SHA: the resolved
# footer ("...by repoman [dep-bump-fixer@<sha>](...)"), the linkless fallback
# ("...by repoman dep-bump-fixer."), and the legacy "...by RepoMan dep-bump-fixer@"
# form (so comments posted before the format flip keep deduping). A bare mention
# like "dep-bump-fixer skipped this one" or a link to skills/dep-bump-fixer/ is
# NOT anchored to "by (repoman|RepoMan)", so it never false-positives into
# suppressing analysis.
FIXER_SIGNATURE="by (repoman \[?|RepoMan )dep-bump-fixer"

# --- Workspace setup ---
setup_workspace "dep-bump-fixer"
TMPDIR="$PROGRAM_TMPDIR"
mkdir -p "$REPORTS_DIR"

# --- Scan ID ---
SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "$SCAN_DATE")

echo "=== Dep Bump Fixer $SCAN_ID ==="
echo "Repos dir: $REPOS_DIR"
echo "Reports dir: $REPORTS_DIR"
if [ "$DRY_RUN" = true ]; then echo "Mode: DRY RUN (no comments posted)"; else echo "Mode: LIVE"; fi
echo "Issue limit: $ISSUE_LIMIT"

# --- Step 2: Capture baseline (first run only) ---
if [ ! -f "$REPORTS_DIR/baseline.json" ]; then
  echo ""
  echo "--- Capturing baseline (first run) ---"

  # Query merged Dependabot PRs across all repos (last 90 days)
  : > "$TMPDIR/merged_prs.jsonl"
  # Drive the loop from the enrolled set (authoritative), statting each clone,
  # rather than globbing "$REPOS_DIR"/*/ and filtering -- a "*/" glob silently
  # drops a ".github" repo. The here-string keeps the body in the current shell.
  ENROLLED=$(repoman_load_enrolled) || exit 1
  CLONES=$(enrolled_clone_dirs "$ENROLLED")
  while IFS= read -r full_repo; do
    [ -n "$full_repo" ] || continue

    gh pr list --repo "$full_repo" \
      --author "app/dependabot" \
      --state merged \
      --json number,createdAt,mergedAt \
      --limit 50 2>/dev/null | jq -c --arg repo "$full_repo" \
      '.[] | . + {repo: $repo}' >> "$TMPDIR/merged_prs.jsonl" 2>/dev/null || true

    sleep 0.5
  done <<< "$CLONES"

  # Compute baseline metrics
  total_merged=$(wc -l < "$TMPDIR/merged_prs.jsonl" | tr -d ' ')

  # Median time-to-merge (days) using jq epoch arithmetic
  median_ttm=$(jq -s '
    [.[] |
      ((.mergedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
       (.createdAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) / 86400 | floor
    ] | sort | if length == 0 then 0
    elif length % 2 == 1 then .[length / 2 | floor]
    else (.[length / 2 - 1] + .[length / 2]) / 2
    end
  ' "$TMPDIR/merged_prs.jsonl" 2>/dev/null || echo "0")

  # Current stale count from scanner
  stale_count=0
  if [ -f "$REPORTS_DIR/latest.json" ]; then
    stale_count=$(jq '.stale_prs | length' "$REPORTS_DIR/latest.json" 2>/dev/null || echo "0")
  fi

  jq -nc \
    --arg date "$SCAN_TIME" \
    --argjson total_merged "$total_merged" \
    --argjson median_ttm "$median_ttm" \
    --argjson stale_count "$stale_count" \
    '{captured_at: $date, total_merged_90d: $total_merged,
      median_time_to_merge_days: $median_ttm, stale_count_at_baseline: $stale_count}' \
    > "$REPORTS_DIR/baseline.json"

  echo "Baseline captured: $total_merged merged PRs (90d), median TTM ${median_ttm}d, $stale_count stale"
fi

# --- Step 3: Discover scanner-created issues ---
echo ""
echo "--- Discovering scanner issues ---"

: > "$TMPDIR/issues.jsonl"
REPOS_CHECKED=0

# Drive the loop from the enrolled set (authoritative), statting each clone,
# rather than globbing "$REPOS_DIR"/*/ and filtering -- a "*/" glob silently
# drops a ".github" repo. enrolled_clone_dirs emits each enrolled owner/name
# whose clone exists; the here-string keeps the body in the current shell so
# counters accumulate.
ENROLLED=$(repoman_load_enrolled) || exit 1
CLONES=$(enrolled_clone_dirs "$ENROLLED")

while IFS= read -r full_repo; do
  [ -n "$full_repo" ] || continue

  REPOS_CHECKED=$((REPOS_CHECKED + 1))

  issues_json=$(gh issue list --repo "$full_repo" \
    --search "[dep-bump] in:title" \
    --state open --limit 100 \
    --json number,title,body 2>/dev/null || echo "[]")

  issue_count=$(echo "$issues_json" | jq 'length')
  if [ "$issue_count" -gt 0 ]; then
    echo "$issues_json" | jq -c --arg repo "$full_repo" '.[] | . + {repo: $repo}' \
      >> "$TMPDIR/issues.jsonl"
  fi

  sleep 0.3
done <<< "$CLONES"

TOTAL_ISSUES=$(wc -l < "$TMPDIR/issues.jsonl" | tr -d ' ')
echo "Found $TOTAL_ISSUES open scanner issues across $REPOS_CHECKED repos"

# --- Step 4-7: Process each issue ---
echo ""
echo "--- Processing issues ---"

ISSUES_PROCESSED=0
COMMENTS_POSTED=0
ISSUES_CLOSED=0
SECURITY_COUNT=0
ROUTINE_COUNT=0
MAJOR_COUNT=0
SKIPPED_ALREADY_COMMENTED=0
SKIPPED_PR_CLOSED=0

while IFS= read -r issue_record; do
  # Check issue limit
  if [ "$ISSUES_PROCESSED" -ge "$ISSUE_LIMIT" ]; then
    echo "  Issue limit ($ISSUE_LIMIT) reached, stopping"
    break
  fi

  issue_number=$(echo "$issue_record" | jq -r '.number')
  issue_repo=$(echo "$issue_record" | jq -r '.repo')
  body=$(echo "$issue_record" | jq -r '.body')

  # --- Parse issue body ---
  pr_number=$(echo "$body" | sed -nE 's/^\*\*PR:\*\*[[:space:]]*#([0-9]+)/\1/p' | head -1)
  package=$(echo "$body" | sed -nE 's/^\*\*Package:\*\*[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
  severity=$(echo "$body" | sed -nE 's/^\*\*Severity:\*\*[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
  sla_days=$(echo "$body" | sed -nE 's/^\*\*SLA:\*\*[[:space:]]*([0-9]+).*/\1/p' | head -1)
  age_days=$(echo "$body" | sed -nE 's/^\*\*Age:\*\*[[:space:]]*([0-9]+).*/\1/p' | head -1)
  ecosystem=$(echo "$body" | sed -nE 's/^\*\*Ecosystem:\*\*[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
  category=$(echo "$body" | sed -nE 's/^Category:[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
  version_str=$(echo "$body" | sed -nE 's/^\*\*Version:\*\*[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')

  # Validate required fields
  if [ -z "$pr_number" ] || [ -z "$package" ] || [ -z "$severity" ]; then
    if [ "$VERBOSE" = true ]; then
      echo "  SKIP #$issue_number: missing required fields (pr=$pr_number, pkg=$package, sev=$severity)"
    fi
    continue
  fi

  # Validate pr_number is numeric
  if ! echo "$pr_number" | grep -qE '^[0-9]+$'; then
    if [ "$VERBOSE" = true ]; then
      echo "  SKIP #$issue_number: pr_number not numeric ($pr_number)"
    fi
    continue
  fi

  echo "  Processing #$issue_number: $package in $issue_repo (PR #$pr_number, $severity)"

  # --- Step 5: Check PR state ---
  pr_state=$(gh_with_backoff pr view "$pr_number" --repo "$issue_repo" --json state --jq '.state' 2>/dev/null || echo "UNKNOWN")

  if [ "$pr_state" = "MERGED" ] || [ "$pr_state" = "CLOSED" ]; then
    echo "    PR #$pr_number is $pr_state — closing issue"
    SKIPPED_PR_CLOSED=$((SKIPPED_PR_CLOSED + 1))
    if [ "$DRY_RUN" = true ]; then
      echo "    [DRY RUN] Would close issue #$issue_number"
    else
      close_issue_if_valid "$issue_repo" "$issue_number" \
        "Dependabot PR #$pr_number has been ${pr_state}. Auto-closing." || true
    fi
    ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
    continue
  fi

  # Check if fixer already commented on this PR. The signature is a regex bound
  # via a real jq --arg inside the helper — `gh pr view --jq` cannot take --arg.
  # The helper returns -1 (UNKNOWN) when the fetch fails; skip on anything but a
  # hard 0 so a transient error never re-posts a duplicate comment.
  already_commented=$(fixer_comment_count "$issue_repo" "$pr_number" "$FIXER_SIGNATURE")

  if [ "$already_commented" != "0" ]; then
    if [ "$VERBOSE" = true ]; then
      if [ "$already_commented" = "-1" ]; then
        echo "    Comment-status check failed, skipping to avoid a duplicate"
      else
        echo "    Already commented, skipping"
      fi
    fi
    SKIPPED_ALREADY_COMMENTED=$((SKIPPED_ALREADY_COMMENTED + 1))
    continue
  fi

  ISSUES_PROCESSED=$((ISSUES_PROCESSED + 1))

  # Re-check CI status from live PR
  live_ci="unknown"
  ci_checks=$(gh_with_backoff pr checks "$pr_number" --repo "$issue_repo" 2>/dev/null || echo "")
  if [ -n "$ci_checks" ]; then
    if echo "$ci_checks" | grep -qiF "fail"; then
      live_ci="failing"
    elif echo "$ci_checks" | grep -qiF "pass"; then
      live_ci="passing"
    elif echo "$ci_checks" | grep -qiF "pending"; then
      live_ci="pending"
    fi
  fi

  # Get PR body for changelog extraction
  pr_body=$(gh_with_backoff pr view "$pr_number" --repo "$issue_repo" --json body --jq '.body' 2>/dev/null || echo "")

  # Extract changelog/release notes section from PR body
  changelog_summary=""
  if [ -n "$pr_body" ]; then
    # Dependabot PR bodies have sections like "Release notes" or "Changelog" or "Commits"
    changelog_summary=$(echo "$pr_body" | sed -n '/Release notes/,/^<\/details>/p' | head -30 || true)
    if [ -z "$changelog_summary" ]; then
      changelog_summary=$(echo "$pr_body" | sed -n '/Changelog/,/^<\/details>/p' | head -30 || true)
    fi
    if [ -z "$changelog_summary" ]; then
      changelog_summary="(No changelog section found in PR body)"
    fi
    # Truncate if too long
    if [ ${#changelog_summary} -gt 1500 ]; then
      changelog_summary="${changelog_summary:0:1500}..."
    fi
  fi

  # Extract CVE/GHSA references
  cve_refs=""
  if [ -n "$pr_body" ]; then
    cve_refs=$(echo "$pr_body" | grep -oE '(CVE-[0-9]{4}-[0-9]+|GHSA-[a-z0-9]{4}-[a-z0-9]{4}-[a-z0-9]{4})' | sort -u | head -5 | tr '\n' ', ' | sed 's/,$//' || true)
  fi

  # Compute overdue days
  overdue=0
  if [ -n "$age_days" ] && [ -n "$sla_days" ]; then
    overdue=$((age_days - sla_days))
  fi

  # --- Step 6: Generate analysis comment ---
  comment=""

  case "$category" in
    security)
      SECURITY_COUNT=$((SECURITY_COUNT + 1))
      comment="## Security Bump Escalation

**Package:** $package ($version_str)
**Severity:** $severity | **SLA:** ${sla_days} days | **Overdue:** ${overdue} days
**CI Status:** $live_ci

### Advisory Context
"
      if [ -n "$cve_refs" ]; then
        comment="${comment}Vulnerability references: $cve_refs
"
      fi
      comment="${comment}
$changelog_summary

### Action Required
This PR has exceeded the ${sla_days}-day SLA for ${severity}-severity patches. Please review and merge, or document a deferral reason.

---
_${SKILL_FOOTER} (scan $SCAN_ID)_"
      ;;

    major)
      MAJOR_COUNT=$((MAJOR_COUNT + 1))
      comment="## Major Version Bump Analysis

**Package:** $package ($version_str)
**Ecosystem:** $ecosystem | **Age:** ${age_days} days

### Migration Notes
$changelog_summary

### Recommendation
Major version bumps require manual review. Consider:
- Bundling with related dependency updates
- Scheduling migration work if breaking changes affect multiple files
- Deferring with documented justification if migration is non-trivial

---
_${SKILL_FOOTER} (scan $SCAN_ID)_"
      ;;

    *)
      ROUTINE_COUNT=$((ROUTINE_COUNT + 1))
      # Detect breaking change indicators in changelog
      breaking_changes="None detected"
      if [ -n "$changelog_summary" ]; then
        if echo "$changelog_summary" | grep -qiE 'breaking|BREAKING|deprecat'; then
          breaking_changes="Possible breaking changes detected in changelog — review recommended"
        fi
      fi

      recommendation="Safe to merge (minor/patch, CI $live_ci, no breaking changes detected)"
      if [ "$live_ci" = "failing" ]; then
        recommendation="Review needed — CI is failing. Check if failure is pre-existing on main or caused by this bump."
      elif [ "$breaking_changes" != "None detected" ]; then
        recommendation="Review recommended — possible breaking changes in changelog"
      fi

      comment="## Dependency Update Analysis

**Package:** $package ($version_str)
**Ecosystem:** $ecosystem | **Age:** ${age_days} days (SLA: ${sla_days} days)
**CI Status:** $live_ci

### Changelog Summary
$changelog_summary

### Risk Assessment
- Breaking changes: $breaking_changes
- Recommendation: $recommendation

---
_${SKILL_FOOTER} (scan $SCAN_ID)_"
      ;;
  esac

  # --- Step 7: Post comment ---
  if [ "$DRY_RUN" = true ]; then
    echo "    [DRY RUN] Would post comment on PR #$pr_number ($category)"
    if [ "$VERBOSE" = true ]; then
      echo "    --- Comment preview ---"
      echo "$comment" | head -20
      echo "    --- (truncated) ---"
    fi
  else
    if gh_with_backoff pr comment "$pr_number" --repo "$issue_repo" --body "$comment" 2>/dev/null; then
      COMMENTS_POSTED=$((COMMENTS_POSTED + 1))
      echo "    Posted analysis on PR #$pr_number"

      # Also comment on the scanner issue
      gh_with_backoff issue comment "$issue_number" --repo "$issue_repo" \
        --body "Analysis posted on PR #$pr_number. Awaiting human action.

_${SKILL_FOOTER} (scan $SCAN_ID)_" 2>/dev/null || true
    else
      echo "    WARN: Failed to post comment on PR #$pr_number"
    fi
  fi

  sleep 1
done < "$TMPDIR/issues.jsonl"

# --- Step 8: Handle repos missing Dependabot config ---
CONFIG_PRS_CREATED=0

if [ -f "$REPORTS_DIR/latest.json" ]; then
  coverage_gaps=$(jq -c '.coverage_gaps[]? | select(.has_config == false)' "$REPORTS_DIR/latest.json" 2>/dev/null || true)

  if [ -n "$coverage_gaps" ]; then
    echo ""
    echo "--- Repos missing Dependabot config ---"

    while IFS= read -r gap; do
      [ -z "$gap" ] && continue

      # Respect issue limit for config PRs too
      if [ "$ISSUES_PROCESSED" -ge "$ISSUE_LIMIT" ]; then
        break
      fi

      gap_repo=$(echo "$gap" | jq -r '.repo')
      gap_ecosystems=$(echo "$gap" | jq -r '.ecosystems | join(",")')

      echo "  $gap_repo: missing config (ecosystems: $gap_ecosystems)"

      # Generate dependabot.yml content
      dependabot_yml="version: 2\nupdates:"
      IFS=',' read -ra eco_arr <<< "$gap_ecosystems"
      for eco in "${eco_arr[@]}"; do
        [ -z "$eco" ] && continue
        dependabot_yml="${dependabot_yml}\n  - package-ecosystem: \"$eco\"\n    directory: \"/\"\n    schedule:\n      interval: \"weekly\"\n    groups:\n      minor-and-patch:\n        update-types:\n          - \"minor\"\n          - \"patch\""
      done

      if [ "$DRY_RUN" = true ]; then
        echo "    [DRY RUN] Would create dependabot.yml PR for $gap_repo"
        if [ "$VERBOSE" = true ]; then
          printf "    Config:\n%b\n" "$dependabot_yml" | head -20
        fi
      else
        # Create config via fork-based PR
        repo_dir="$REPOS_DIR/$gap_repo"
        if [ -d "$repo_dir/.git" ]; then
          branch_name="chore/add-dependabot-config"

          # Check if PR already exists
          existing_pr=$(gh pr list --repo "$gap_repo" --state open \
            --search "dependabot.yml in:title" --json number --jq '.[0].number' 2>/dev/null || echo "")

          if [ -n "$existing_pr" ] && [ "$existing_pr" != "null" ]; then
            echo "    PR #$existing_pr already exists for dependabot config"
            continue
          fi

          # Write config file
          config_dir="$repo_dir/.github"
          mkdir -p "$config_dir"
          printf '%b\n' "$dependabot_yml" > "$config_dir/dependabot.yml"

          # Use fork-based PR workflow
          pr_created=$(
            cd "$repo_dir" || exit 1
            git checkout -B "$branch_name" origin/main 2>/dev/null || git checkout -B "$branch_name" main 2>/dev/null || true
            git add .github/dependabot.yml
            if git diff --cached --quiet; then
              echo "no"
            else
              ensure_fork "${gap_repo%%/*}" "${gap_repo#*/}" "$FORK_OWNER"
              if create_fork_pr "${gap_repo%%/*}" "${gap_repo#*/}" "$FORK_OWNER" "$branch_name" \
                "chore: Add Dependabot configuration" \
                "chore: Add Dependabot configuration for $gap_repo" \
                "Enable automated dependency updates with weekly schedule and grouped minor/patch updates.

Ecosystems: $gap_ecosystems

---
_${SKILL_FOOTER} (scan $SCAN_ID)_"; then
                echo "yes"
              else
                echo "no"
              fi
            fi
          ) 2>/dev/null || echo "no"
          if [ "$pr_created" = "yes" ]; then
            CONFIG_PRS_CREATED=$((CONFIG_PRS_CREATED + 1))
          fi
        fi
      fi

      ISSUES_PROCESSED=$((ISSUES_PROCESSED + 1))
      sleep 1
    done <<< "$coverage_gaps"
  fi
fi

# --- Step 9: Compute metrics ---
echo ""
echo "--- Computing metrics ---"

# Query recently merged Dependabot PRs (last 30 days) for TTM
: > "$TMPDIR/recent_merged.jsonl"
# Drive the loop from the enrolled set (authoritative), statting each clone,
# rather than globbing "$REPOS_DIR"/*/ and filtering -- a "*/" glob silently
# drops a ".github" repo. The here-string keeps the body in the current shell.
ENROLLED=$(repoman_load_enrolled) || exit 1
CLONES=$(enrolled_clone_dirs "$ENROLLED")
while IFS= read -r full_repo; do
  [ -n "$full_repo" ] || continue

  gh pr list --repo "$full_repo" \
    --author "app/dependabot" \
    --state merged \
    --json number,createdAt,mergedAt \
    --limit 20 2>/dev/null | jq -c --arg repo "$full_repo" \
    '.[] | . + {repo: $repo}' >> "$TMPDIR/recent_merged.jsonl" 2>/dev/null || true

  sleep 0.3
done <<< "$CLONES"

# Compute median time-to-merge
MERGED_SINCE_LAST=0
MEDIAN_TTM=0

if [ -s "$TMPDIR/recent_merged.jsonl" ]; then
  MERGED_SINCE_LAST=$(wc -l < "$TMPDIR/recent_merged.jsonl" | tr -d ' ')
  MEDIAN_TTM=$(jq -s '
    [.[] |
      ((.mergedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
       (.createdAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) / 86400 | floor
    ] | sort | if length == 0 then 0
    elif length % 2 == 1 then .[length / 2 | floor]
    else (.[length / 2 - 1] + .[length / 2]) / 2
    end
  ' "$TMPDIR/recent_merged.jsonl" 2>/dev/null || echo "0")
fi

# Current stale count
CURRENT_STALE=0
if [ -f "$REPORTS_DIR/latest.json" ]; then
  CURRENT_STALE=$(jq '.stale_prs | length' "$REPORTS_DIR/latest.json" 2>/dev/null || echo "0")
fi

# Previous fixer run metrics for delta
PREV_STALE=0
if [ -f "$REPORTS_DIR/fixer-latest.json" ]; then
  PREV_STALE=$(jq '.metrics.stale_count // 0' "$REPORTS_DIR/fixer-latest.json" 2>/dev/null || echo "0")
fi

# Baseline metrics
BASELINE_TTM=0
BASELINE_STALE=0
if [ -f "$REPORTS_DIR/baseline.json" ]; then
  BASELINE_TTM=$(jq '.median_time_to_merge_days // 0' "$REPORTS_DIR/baseline.json" 2>/dev/null || echo "0")
  BASELINE_STALE=$(jq '.stale_count_at_baseline // 0' "$REPORTS_DIR/baseline.json" 2>/dev/null || echo "0")
fi

STALE_DELTA=$((CURRENT_STALE - PREV_STALE))

# --- Write reports ---
FIXER_LATEST=$(jq -nc \
  --arg scan_id "$SCAN_ID" \
  --arg date "$SCAN_TIME" \
  --argjson duration "$SECONDS" \
  --argjson issues_processed "$ISSUES_PROCESSED" \
  --argjson comments_posted "$COMMENTS_POSTED" \
  --argjson issues_closed "$ISSUES_CLOSED" \
  --argjson config_prs "$CONFIG_PRS_CREATED" \
  --argjson security "$SECURITY_COUNT" \
  --argjson routine "$ROUTINE_COUNT" \
  --argjson major "$MAJOR_COUNT" \
  --argjson skipped_commented "$SKIPPED_ALREADY_COMMENTED" \
  --argjson skipped_closed "$SKIPPED_PR_CLOSED" \
  --argjson merged_recent "$MERGED_SINCE_LAST" \
  --argjson median_ttm "$MEDIAN_TTM" \
  --argjson stale_count "$CURRENT_STALE" \
  --argjson baseline_ttm "$BASELINE_TTM" \
  --argjson baseline_stale "$BASELINE_STALE" \
  '{scan_id: $scan_id, date: $date, duration_seconds: $duration,
    issues_processed: $issues_processed, comments_posted: $comments_posted,
    issues_closed: $issues_closed, config_prs_created: $config_prs,
    breakdown: {security: $security, routine: $routine, major: $major},
    skipped: {already_commented: $skipped_commented, pr_closed: $skipped_closed},
    metrics: {merged_recent: $merged_recent, median_time_to_merge: $median_ttm,
      stale_count: $stale_count, baseline_ttm: $baseline_ttm, baseline_stale: $baseline_stale}}')

write_report_latest "$REPORTS_DIR" "$FIXER_LATEST" "fixer-latest.json"

HISTORY_ROW=$(jq -nc \
  --arg scan_id "$SCAN_ID" \
  --arg date "$SCAN_TIME" \
  --argjson issues_processed "$ISSUES_PROCESSED" \
  --argjson comments_posted "$COMMENTS_POSTED" \
  --argjson issues_closed "$ISSUES_CLOSED" \
  --argjson median_ttm "$MEDIAN_TTM" \
  --argjson stale_count "$CURRENT_STALE" \
  '{scan_id: $scan_id, date: $date, issues_processed: $issues_processed,
    comments_posted: $comments_posted, issues_closed: $issues_closed,
    median_ttm: $median_ttm, stale_count: $stale_count}')

append_history_row "$REPORTS_DIR" "$HISTORY_ROW" "$MAX_HISTORY_ROWS" "fixer-history.json"

echo "Wrote $REPORTS_DIR/fixer-latest.json"
echo "Appended to $REPORTS_DIR/fixer-history.json"

# --- Summary ---
echo ""
echo "=== Dep Bump Fixer $SCAN_ID Summary ==="
echo "Issues processed: $ISSUES_PROCESSED"
echo "  Security escalations: $SECURITY_COUNT"
echo "  Routine analyses: $ROUTINE_COUNT"
echo "  Major bump analyses: $MAJOR_COUNT"
if [ "$DRY_RUN" = true ]; then
  echo "Comments posted: 0 (DRY RUN)"
else
  echo "Comments posted: $COMMENTS_POSTED"
fi
echo "Issues closed (PR merged/closed): $ISSUES_CLOSED"
echo "Config PRs created: $CONFIG_PRS_CREATED"
echo "Skipped: $SKIPPED_ALREADY_COMMENTED already commented, $SKIPPED_PR_CLOSED PR closed"
echo "Metrics: median TTM ${MEDIAN_TTM}d (baseline: ${BASELINE_TTM}d), stale $CURRENT_STALE (delta: ${STALE_DELTA})"
echo "Duration: ${SECONDS}s"
