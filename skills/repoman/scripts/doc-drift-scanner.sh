#!/usr/bin/env bash
# doc-drift-scanner — scan enrolled repos for documentation drift.
#
# Runs the deterministic checker, diffs against the previous report, keeps one
# rollup issue per repo, and writes latest.json / history.json.
#
# Usage:
#   bash doc-drift-scanner.sh --dry-run
#   bash doc-drift-scanner.sh --issue-limit 3
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/program-lib.sh
. "$SCRIPT_DIR/program-lib.sh"

DRY_RUN=false
ISSUE_LIMIT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --issue-limit)
      ISSUE_LIMIT="${2:-0}"
      shift 2
      ;;
    --help|-h)
      cat <<'EOF'
Usage: doc-drift-scanner.sh [--dry-run] [--issue-limit N]

Scan enrolled clones for documentation drift. Creates/updates one rollup
issue per repo ([doc-drift] owner/name). --dry-run prints actions and does
not write latest.json (so the next live run still sees findings as new).
EOF
      exit 0
      ;;
    *) echo "ERROR: unknown option: $1" >&2; exit 1 ;;
  esac
done

repoman_config || exit 1
REPORTS_DIR="${REPORTS_DIR:-$HOME/reports/doc-drift}"
CHECK_PY="$SCRIPT_DIR/doc-drift-check.py"
[ -f "$CHECK_PY" ] || { echo "ERROR: missing $CHECK_PY" >&2; exit 1; }

SKILL_FOOTER=$(skill_attribution "doc-drift-scanner" 2>/dev/null || true)
SCAN_DATE=$(date -u +"%Y-%m-%d")
SCAN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAX_HISTORY_ROWS=500

setup_workspace "doc-drift-scanner"
mkdir -p "$REPORTS_DIR"
SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "$SCAN_DATE")

echo "=== Doc Drift Scan $SCAN_ID ==="
echo "Repos dir: $REPOS_DIR"
echo "Reports dir: $REPORTS_DIR"
if [ "$DRY_RUN" = true ]; then echo "Mode: DRY RUN"; fi
if [ "$ISSUE_LIMIT" -gt 0 ]; then echo "Issue limit: $ISSUE_LIMIT"; fi

ENROLLED=$(repoman_load_enrolled) || exit 1
CLONES=$(enrolled_clone_dirs "$ENROLLED")
: > "$PROGRAM_TMPDIR/current.jsonl"
REPOS_SCANNED=0
REPOS_FAILED=0
REPOS_TOUCHED=0

fetch_release_meta() {
  local full_repo="$1" rel_json="$2" prs_json="$3"
  echo "[]" > "$rel_json"
  echo "[]" > "$prs_json"
  if ! gh release list --repo "$full_repo" --limit 20 --json tagName >/dev/null 2>&1; then
    return 0
  fi
  {
    echo "["
    first=1
    while IFS= read -r tag; do
      [ -n "$tag" ] || continue
      body=$(gh release view "$tag" --repo "$full_repo" \
        --json tagName,publishedAt,createdAt,name,body 2>/dev/null || echo "")
      [ -n "$body" ] || continue
      if [ "$first" -eq 1 ]; then first=0; else echo ","; fi
      printf '%s' "$body"
    done < <(gh release list --repo "$full_repo" --limit 20 --json tagName \
      --jq '.[].tagName' 2>/dev/null || true)
    echo "]"
  } > "$rel_json" 2>/dev/null || echo "[]" > "$rel_json"

  gh pr list --repo "$full_repo" --state merged --limit 100 \
    --json number,title,url,labels,mergedAt 2>/dev/null \
    | jq '[.[] | . + {unreleased: true}]' > "$prs_json" 2>/dev/null \
    || echo "[]" > "$prs_json"
}

while IFS= read -r full_repo; do
  [ -n "$full_repo" ] || continue
  repo_dir="$REPOS_DIR/$full_repo"
  echo "Scanning $full_repo..."
  safe="${full_repo//\//_}"
  rel_json="$PROGRAM_TMPDIR/rel_${safe}.json"
  prs_json="$PROGRAM_TMPDIR/prs_${safe}.json"
  fetch_release_meta "$full_repo" "$rel_json" "$prs_json"

  if ! out=$(python3 "$CHECK_PY" --clone "$repo_dir" --repo "$full_repo" \
      --releases-json "$rel_json" --prs-json "$prs_json"); then
    echo "  WARN: checker failed for $full_repo"
    REPOS_FAILED=$((REPOS_FAILED + 1))
    continue
  fi
  REPOS_SCANNED=$((REPOS_SCANNED + 1))
  ref=$(printf '%s' "$out" | jq -r '.ref // ""')
  printf '%s' "$out" | jq -c --arg ref "$ref" \
    '.findings[]? | . + {ref: $ref, first_detected: (now | todateiso8601)}' \
    >> "$PROGRAM_TMPDIR/current.jsonl" 2>/dev/null || true
  n=$(printf '%s' "$out" | jq '.counts.total // 0')
  echo "  Findings: $n (ref ${ref:0:12})"
done <<< "$CLONES"

echo ""
echo "=== Diff against previous ==="
PREV="$PROGRAM_TMPDIR/prev.jsonl"
if [ -f "$REPORTS_DIR/latest.json" ]; then
  jq -c '.findings[]?' "$REPORTS_DIR/latest.json" > "$PREV" 2>/dev/null || : > "$PREV"
else
  : > "$PREV"
fi

KEY_EXPR='.key // ([.repo, .check, .doc_path, .claim, .code_path] | join("|"))'
read -r NEW_COUNT FIXED_COUNT RECURRING_COUNT < <(diff_against_previous \
  "$PROGRAM_TMPDIR/current.jsonl" "$PREV" "$KEY_EXPR")
echo "New: $NEW_COUNT  Fixed: $FIXED_COUNT  Recurring: $RECURRING_COUNT"

# Enrich current findings with status
ENRICHED="$PROGRAM_TMPDIR/enriched.jsonl"
: > "$ENRICHED"
while IFS= read -r line; do
  [ -n "$line" ] || continue
  key=$(printf '%s' "$line" | jq -r "$KEY_EXPR")
  if grep -qxF "$key" "$PROGRAM_TMPDIR/new_keys.txt" 2>/dev/null; then
    printf '%s' "$line" | jq -c '.status="open" | .reason="new"'
  else
    printf '%s' "$line" | jq -c '.status="open" | .reason="recurring"'
  fi
done < "$PROGRAM_TMPDIR/current.jsonl" >> "$ENRICHED"

# --- Rollup issues (one per repo) ---
echo ""
echo "=== Rollup issues ==="
ISSUES_UPDATED=0
ISSUES_CLOSED=0
ISSUES_CREATED=0

repos_with_findings=$(jq -r '.repo' "$ENRICHED" 2>/dev/null | sort -u)
# Also repos that had findings before but none now (from fixed keys)
repos_prev=$(jq -r '.repo // empty' "$PREV" 2>/dev/null | sort -u)
repos_all=$(printf '%s\n%s\n' "$repos_with_findings" "$repos_prev" | awk 'NF && !seen[$0]++')

while IFS= read -r full_repo; do
  [ -n "$full_repo" ] || continue
  if [ "$ISSUE_LIMIT" -gt 0 ] && [ "$REPOS_TOUCHED" -ge "$ISSUE_LIMIT" ]; then
    echo "Issue limit reached ($ISSUE_LIMIT); skipping remaining repos"
    break
  fi

  repo_findings="$PROGRAM_TMPDIR/repo_${full_repo//\//_}.jsonl"
  jq -c --arg r "$full_repo" 'select(.repo == $r)' "$ENRICHED" > "$repo_findings" 2>/dev/null || : > "$repo_findings"
  corr=$(jq -s '[.[] | select(.kind=="correction")] | length' "$repo_findings")
  adds=$(jq -s '[.[] | select(.kind=="addition")] | length' "$repo_findings")
  title="[doc-drift] $full_repo"

  body_file="$PROGRAM_TMPDIR/body_${full_repo//\//_}.md"
  {
    echo "## Doc drift in \`$full_repo\`"
    echo ""
    echo "Boundary pinned at scan \`$SCAN_ID\`. Corrections first, then additions."
    echo ""
    echo "### Corrections"
    echo ""
    if [ "$corr" -eq 0 ]; then
      echo "_None open._"
    else
      jq -r -s '.[] | select(.kind=="correction") |
        "- [ ] **\(.check)**: \(.claim) — `\(.doc_path):\(.doc_line)` vs `\(.code_path):\(.code_line)` — \(.evidence)"' \
        "$repo_findings"
    fi
    echo ""
    echo "### Additions"
    echo ""
    if [ "$adds" -eq 0 ]; then
      echo "_None._"
    else
      jq -r -s '.[] | select(.kind=="addition") |
        "- [ ] **\(.check)**: \(.claim) — `\(.doc_path):\(.doc_line)` vs `\(.code_path):\(.code_line)`"' \
        "$repo_findings"
    fi
    echo ""
    echo "---"
    echo "$SKILL_FOOTER"
  } > "$body_file"

  existing=""
  if existing=$(gh_issue_exists "$full_repo" "$title"); then
    :
  else
    existing=""
  fi

  if [ "$corr" -eq 0 ] && [ "$adds" -eq 0 ]; then
    if [ -n "$existing" ]; then
      if [ "$DRY_RUN" = true ]; then
        echo "[DRY RUN] would close #$existing on $full_repo (no open corrections)"
      else
        if close_issue_if_valid "$full_repo" "$existing" \
            "Closed by doc-drift scan $SCAN_ID: no open corrections remain."; then
          ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
          echo "  Closed #$existing on $full_repo"
        fi
      fi
      REPOS_TOUCHED=$((REPOS_TOUCHED + 1))
    fi
    continue
  fi

  REPOS_TOUCHED=$((REPOS_TOUCHED + 1))
  if [ -n "$existing" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "[DRY RUN] would update #$existing on $full_repo ($corr corrections, $adds additions)"
    else
      if gh issue edit "$existing" --repo "$full_repo" --body-file "$body_file" >/dev/null 2>&1; then
        ISSUES_UPDATED=$((ISSUES_UPDATED + 1))
        echo "  Updated #$existing on $full_repo"
      else
        echo "  WARN: failed to update #$existing on $full_repo"
      fi
    fi
  else
    if [ "$DRY_RUN" = true ]; then
      echo "[DRY RUN] would create issue on $full_repo ($corr corrections, $adds additions)"
    else
      # Ensure label exists (best-effort)
      gh label create "doc-drift" --repo "$full_repo" --color "0052CC" \
        --description "Documentation drift tracked by RepoMan" 2>/dev/null || true
      if num=$(gh issue create --repo "$full_repo" --title "$title" \
          --body-file "$body_file" --label "doc-drift" \
          --jq '.number' 2>/dev/null); then
        ISSUES_CREATED=$((ISSUES_CREATED + 1))
        echo "  Created #$num on $full_repo"
      else
        # Fallback without jq filter (older gh)
        url=$(gh issue create --repo "$full_repo" --title "$title" \
          --body-file "$body_file" --label "doc-drift" 2>/dev/null || true)
        if [ -n "$url" ]; then
          ISSUES_CREATED=$((ISSUES_CREATED + 1))
          echo "  Created $url"
        else
          echo "  WARN: failed to create issue on $full_repo"
        fi
      fi
    fi
  fi
done <<< "$repos_all"

# Ledger
LEDGER="$REPORTS_DIR/triaged.log"
if [ "$DRY_RUN" = false ]; then
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$SCAN_TIME" "$key" "open" "new" >> "$LEDGER"
  done < "$PROGRAM_TMPDIR/new_keys.txt"
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$SCAN_TIME" "$key" "obsolete" "fixed" >> "$LEDGER"
  done < "$PROGRAM_TMPDIR/fixed_keys.txt"
fi

# --- Reports ---
CORRECTIONS=$(jq -s '[.[] | select(.kind=="correction")] | length' "$ENRICHED")
ADDITIONS=$(jq -s '[.[] | select(.kind=="addition")] | length' "$ENRICHED")
FINDINGS_JSON=$(jq -s '.' "$ENRICHED" 2>/dev/null || echo '[]')

LATEST=$(jq -n \
  --arg scan_id "$SCAN_ID" \
  --arg date "$SCAN_TIME" \
  --argjson repos_scanned "$REPOS_SCANNED" \
  --argjson repos_failed "$REPOS_FAILED" \
  --argjson corrections "$CORRECTIONS" \
  --argjson additions "$ADDITIONS" \
  --argjson findings "$FINDINGS_JSON" \
  --argjson new "$NEW_COUNT" \
  --argjson fixed "$FIXED_COUNT" \
  --argjson recurring "$RECURRING_COUNT" \
  '{
    scan_id: $scan_id,
    date: $date,
    repos_scanned: $repos_scanned,
    repos_failed: $repos_failed,
    corrections: $corrections,
    additions: $additions,
    findings: $findings,
    delta: {new: $new, fixed: $fixed, recurring: $recurring}
  }')

if [ "$DRY_RUN" = true ]; then
  echo ""
  echo "[DRY RUN] Skipping latest.json / history.json write"
  echo "$LATEST" | jq '{scan_id, date, repos_scanned, corrections, additions, delta}'
else
  write_report_latest "$REPORTS_DIR" "$LATEST"
  HISTORY_ROW=$(jq -n \
    --arg scan_id "$SCAN_ID" \
    --arg date "$SCAN_TIME" \
    --argjson repos_scanned "$REPOS_SCANNED" \
    --argjson corrections "$CORRECTIONS" \
    --argjson additions "$ADDITIONS" \
    --argjson new "$NEW_COUNT" \
    --argjson fixed "$FIXED_COUNT" \
    --argjson issues_created "$ISSUES_CREATED" \
    --argjson issues_updated "$ISSUES_UPDATED" \
    --argjson issues_closed "$ISSUES_CLOSED" \
    '{
      scan_id: $scan_id, date: $date, repos_scanned: $repos_scanned,
      corrections: $corrections, additions: $additions,
      new: $new, fixed: $fixed,
      issues_created: $issues_created, issues_updated: $issues_updated,
      issues_closed: $issues_closed
    }')
  append_history_row "$REPORTS_DIR" "$HISTORY_ROW" "$MAX_HISTORY_ROWS"
  echo "Wrote $REPORTS_DIR/latest.json and history.json"
fi

echo ""
echo "=== Doc Drift Scan $SCAN_ID Summary ==="
echo "Repos scanned: $REPOS_SCANNED (failed: $REPOS_FAILED)"
echo "Corrections: $CORRECTIONS  Additions: $ADDITIONS"
echo "Issues created: $ISSUES_CREATED  updated: $ISSUES_UPDATED  closed: $ISSUES_CLOSED"
