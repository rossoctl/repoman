#!/usr/bin/env bash
# doc-drift-precheck — deterministic gate before a model turn.
#
# Exit 1: nothing to do (empty worklist). Exit 0: prints "worklist: <path>".
# Any other exit is fail-open for the caller (DAM schedule precheck).
#
# Usage:
#   bash doc-drift-precheck.sh [--repo owner/name] [--worklist /path]
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/program-lib.sh
. "$SCRIPT_DIR/program-lib.sh"

REPO_FILTER=""
WORKLIST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --repo) REPO_FILTER="${2:-}"; shift 2 ;;
    --worklist) WORKLIST="${2:-}"; shift 2 ;;
    --help|-h)
      cat <<'EOF'
Usage: doc-drift-precheck.sh [--repo owner/name] [--worklist /path]

Run the deterministic doc-drift checker. Exit 1 when the worklist is empty;
exit 0 and print "worklist: <path>" when it is not. Fetch failures are
fail-open (exit 2) so a broken gate does not block the run.
EOF
      exit 0
      ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done

repoman_config || exit 2
CHECK_PY="$SCRIPT_DIR/doc-drift-check.py"
if [ ! -f "$CHECK_PY" ]; then
  echo "ERROR: missing $CHECK_PY" >&2
  exit 2
fi

setup_workspace "doc-drift-precheck"
if [ -z "$WORKLIST" ]; then
  WORKLIST="$PROGRAM_TMPDIR/worklist.json"
fi

ENROLLED=$(repoman_load_enrolled) || exit 2
CLONES=$(enrolled_clone_dirs "$ENROLLED")
: > "$PROGRAM_TMPDIR/all_findings.jsonl"

while IFS= read -r full_repo; do
  [ -n "$full_repo" ] || continue
  if [ -n "$REPO_FILTER" ] && [ "$full_repo" != "$REPO_FILTER" ]; then
    continue
  fi
  repo_dir="$REPOS_DIR/$full_repo"
  rel_json="$PROGRAM_TMPDIR/releases_${full_repo//\//_}.json"
  prs_json="$PROGRAM_TMPDIR/prs_${full_repo//\//_}.json"
  # Best-effort fetch; empty arrays on failure keep the checker offline-clean.
  if ! gh release list --repo "$full_repo" --limit 20 --json tagName \
      >/dev/null 2>&1; then
    echo "[]" > "$rel_json"
    echo "[]" > "$prs_json"
  else
    # Expand each tag into the fields the checker needs.
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
    # The checker classifies unreleased PRs from mergedAt vs publishedAt.
    gh pr list --repo "$full_repo" --state merged --limit 100 \
      --json number,title,url,labels,mergedAt > "$prs_json" 2>/dev/null \
      || echo "[]" > "$prs_json"
  fi

  if ! out=$(python3 "$CHECK_PY" --clone "$repo_dir" --repo "$full_repo" \
      --releases-json "$rel_json" --prs-json "$prs_json" 2>/dev/null); then
    exit 2
  fi
  printf '%s' "$out" | jq -c '.findings[]? // empty' >> "$PROGRAM_TMPDIR/all_findings.jsonl" \
    || exit 2
done <<< "$CLONES"

count=$(wc -l < "$PROGRAM_TMPDIR/all_findings.jsonl" | tr -d ' ')
if [ "${count:-0}" -eq 0 ]; then
  exit 1
fi

jq -s '{findings: ., count: length}' "$PROGRAM_TMPDIR/all_findings.jsonl" > "$WORKLIST" \
  || exit 2
echo "worklist: $WORKLIST"
exit 0
