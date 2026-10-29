#!/usr/bin/env bash
# doc-drift-fixer — re-verify and mechanically fix doc-drift findings.
#
# Defaults to dry-run. Pass --live to open fork PRs. Never edits code to match
# docs, never merges, never pushes the default branch, never publishes a release.
#
# Usage:
#   bash doc-drift-fixer.sh --dry-run --issue-limit 5
#   bash doc-drift-fixer.sh --live
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/program-lib.sh
. "$SCRIPT_DIR/program-lib.sh"

DRY_RUN=true
ISSUE_LIMIT=5

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true; shift ;;
    --live) DRY_RUN=false; shift ;;
    --issue-limit) ISSUE_LIMIT="${2:-5}"; shift 2 ;;
    --help|-h)
      cat <<'EOF'
Usage: doc-drift-fixer.sh [--dry-run|--live] [--issue-limit N]

Re-verify scanner findings. Mechanical corrections open their own docs: fix
PR; mechanical additions fold into one rolling update/doc-drift PR per repo.
Non-mechanical findings stay on the rollup issue checklist.
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
[ -f "$REPORTS_DIR/latest.json" ] || {
  echo "ERROR: no $REPORTS_DIR/latest.json — run the scanner first" >&2
  exit 1
}

SKILL_FOOTER=$(skill_attribution "doc-drift-fixer" 2>/dev/null || true)
FIX_DATE=$(date -u +"%Y-%m-%d")
setup_workspace "doc-drift-fixer"

echo "=== Doc Drift Fixer $FIX_DATE ==="
if [ "$DRY_RUN" = true ]; then echo "Mode: DRY RUN (no PRs)"; else echo "Mode: LIVE"; fi

# Re-verify each finding against the current boundary
jq -c '.findings[]?' "$REPORTS_DIR/latest.json" > "$PROGRAM_TMPDIR/prev_findings.jsonl"
: > "$PROGRAM_TMPDIR/still.jsonl"
PROCESSED=0

while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  if [ "$ISSUE_LIMIT" -gt 0 ] && [ "$PROCESSED" -ge "$ISSUE_LIMIT" ]; then
    break
  fi
  repo=$(printf '%s' "$finding" | jq -r '.repo')
  repo_dir="$REPOS_DIR/$repo"
  if [ ! -d "$repo_dir/.git" ]; then
    echo "  WARN: missing clone $repo"
    continue
  fi
  # Re-run checker for this repo alone (empty release meta → release findings drop)
  safe="${repo//\//_}"
  echo "[]" > "$PROGRAM_TMPDIR/rel_${safe}.json"
  echo "[]" > "$PROGRAM_TMPDIR/prs_${safe}.json"
  # Prefer stored release draft/date findings: re-fetch for those checks
  check=$(printf '%s' "$finding" | jq -r '.check')
  if [ "$check" = "release_date" ] || [ "$check" = "release_draft" ] || [ "$check" = "release_coverage" ]; then
    tag=$(printf '%s' "$finding" | jq -r '.code_path' | sed 's/^release://')
    if [ -n "$tag" ] && [ "$tag" != "merged-prs" ]; then
      gh release view "$tag" --repo "$repo" \
        --json tagName,publishedAt,createdAt,name,body 2>/dev/null \
        | jq -s '.' > "$PROGRAM_TMPDIR/rel_${safe}.json" 2>/dev/null \
        || echo "[]" > "$PROGRAM_TMPDIR/rel_${safe}.json"
    fi
    gh pr list --repo "$repo" --state merged --limit 100 \
      --json number,title,url,labels,mergedAt 2>/dev/null \
      | jq '[.[] | . + {unreleased: true}]' > "$PROGRAM_TMPDIR/prs_${safe}.json" 2>/dev/null \
      || echo "[]" > "$PROGRAM_TMPDIR/prs_${safe}.json"
  fi

  if ! out=$(python3 "$CHECK_PY" --clone "$repo_dir" --repo "$repo" \
      --releases-json "$PROGRAM_TMPDIR/rel_${safe}.json" \
      --prs-json "$PROGRAM_TMPDIR/prs_${safe}.json"); then
    echo "  WARN: re-verify failed for $repo"
    continue
  fi
  key=$(printf '%s' "$finding" | jq -r '.key // empty')
  if [ -z "$key" ]; then
    key=$(printf '%s' "$finding" | jq -r '[.repo, .check, .doc_path, .claim, .code_path] | join("|")')
  fi
  if printf '%s' "$out" | jq -e --arg k "$key" \
      '[.findings[] | (.key // ([.repo,.check,.doc_path,.claim,.code_path]|join("|")))] | index($k)' \
      >/dev/null; then
    # Prefer the freshly computed finding (may have updated draft/replace_with)
    fresh=$(printf '%s' "$out" | jq -c --arg k "$key" \
      '.findings[] | select((.key // ([.repo,.check,.doc_path,.claim,.code_path]|join("|"))) == $k)' | head -1)
    if [ -n "$fresh" ]; then
      echo "$fresh" >> "$PROGRAM_TMPDIR/still.jsonl"
    else
      echo "$finding" >> "$PROGRAM_TMPDIR/still.jsonl"
    fi
    PROCESSED=$((PROCESSED + 1))
  else
    echo "  Obsolete: $key"
  fi
done < "$PROGRAM_TMPDIR/prev_findings.jsonl"

echo "Still open after re-verify: $(wc -l < "$PROGRAM_TMPDIR/still.jsonl" | tr -d ' ')"

# Partition
jq -c 'select(.mechanical == true and .kind == "correction")' \
  "$PROGRAM_TMPDIR/still.jsonl" > "$PROGRAM_TMPDIR/mech_corr.jsonl" || : > "$PROGRAM_TMPDIR/mech_corr.jsonl"
jq -c 'select(.mechanical == true and .kind == "addition")' \
  "$PROGRAM_TMPDIR/still.jsonl" > "$PROGRAM_TMPDIR/mech_add.jsonl" || : > "$PROGRAM_TMPDIR/mech_add.jsonl"
jq -c 'select(.mechanical != true)' \
  "$PROGRAM_TMPDIR/still.jsonl" > "$PROGRAM_TMPDIR/non_mech.jsonl" || : > "$PROGRAM_TMPDIR/non_mech.jsonl"

echo "Mechanical corrections: $(wc -l < "$PROGRAM_TMPDIR/mech_corr.jsonl" | tr -d ' ')"
echo "Mechanical additions:   $(wc -l < "$PROGRAM_TMPDIR/mech_add.jsonl" | tr -d ' ')"
echo "Non-mechanical:         $(wc -l < "$PROGRAM_TMPDIR/non_mech.jsonl" | tr -d ' ')"

apply_replace() {
  local file="$1" old="$2" new="$3"
  if [ ! -f "$file" ]; then
    echo "  WARN: missing $file"
    return 1
  fi
  # Prefer python for literal replace (no sed metachar surprises)
  python3 - "$file" "$old" "$new" <<'PY'
import sys
path, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()
if old not in text:
    # try case-insensitive for retired names
    import re
    text2, n = re.subn(re.escape(old), new, text, flags=re.I)
    if n == 0:
        sys.exit(2)
    open(path, "w", encoding="utf-8").write(text2)
else:
    open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

# --- Mechanical corrections: one PR each ---
echo ""
echo "=== Mechanical corrections ==="
while IFS= read -r finding; do
  [ -n "$finding" ] || continue
  repo=$(printf '%s' "$finding" | jq -r '.repo')
  repo_name="${repo#*/}"
  org="${repo%%/*}"
  repo_dir="$REPOS_DIR/$repo"
  check=$(printf '%s' "$finding" | jq -r '.check')
  doc_path=$(printf '%s' "$finding" | jq -r '.doc_path')
  claim=$(printf '%s' "$finding" | jq -r '.claim')
  replace=$(printf '%s' "$finding" | jq -r '.replace_with // empty')
  ref=$(printf '%s' "$finding" | jq -r '.ref // empty')
  branch="fix/doc-drift-${check}-$(date -u +%Y%m%d%H%M%S)"

  echo "--- $repo: $check ---"
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] PR docs: fix $claim"
    echo "  file: $doc_path  replace_with: ${replace:-<none>}"
    continue
  fi

  case "$check" in
    release_date)
      # Replace the heading date YYYY-MM-DD
      old_date=$(printf '%s' "$finding" | jq -r '.evidence' | sed -n 's/.*CHANGELOG has \([0-9-]*\).*/\1/p')
      new_date="$replace"
      if [ -z "$old_date" ] || [ -z "$new_date" ]; then
        echo "  WARN: cannot parse release dates; skipping"
        continue
      fi
      cd "$repo_dir" || continue
      ensure_fork "$org" "$repo_name" "$FORK_OWNER"
      FORK_REMOTE="${FORK_OWNER}-${repo_name}-fork"
      if ! git remote get-url "$FORK_REMOTE" >/dev/null 2>&1; then
        git remote add "$FORK_REMOTE" "https://github.com/$FORK_OWNER/${repo_name}.git"
      fi
      git fetch "$FORK_REMOTE" main 2>/dev/null || true
      git checkout -B "$branch" "$FORK_REMOTE/main" 2>/dev/null || git checkout -B "$branch"
      ver=$(printf '%s' "$claim" | sed -n 's/.*release \([^ ]*\) date.*/\1/p')
      if [ -f "$doc_path" ]; then
        python3 - "$doc_path" "$ver" "$old_date" "$new_date" <<'PY'
import re, sys
path, ver, old, new = sys.argv[1:5]
text = open(path, encoding="utf-8").read()
text2, n = re.subn(
    rf"(## \[{re.escape(ver)}\] - ){re.escape(old)}",
    rf"\g<1>{new}",
    text,
    count=1,
)
if n == 0:
    sys.exit(2)
open(path, "w", encoding="utf-8").write(text2)
PY
        git add "$doc_path"
      fi
      ;;
    versions|retired_names)
      # Grep the claim token across the repo and replace
      cd "$repo_dir" || continue
      ensure_fork "$org" "$repo_name" "$FORK_OWNER"
      FORK_REMOTE="${FORK_OWNER}-${repo_name}-fork"
      if ! git remote get-url "$FORK_REMOTE" >/dev/null 2>&1; then
        git remote add "$FORK_REMOTE" "https://github.com/$FORK_OWNER/${repo_name}.git"
      fi
      git fetch "$FORK_REMOTE" main 2>/dev/null || true
      git checkout -B "$branch" "$FORK_REMOTE/main" 2>/dev/null || git checkout -B "$branch"
      if [ -z "$replace" ]; then
        echo "  WARN: no replace_with; leaving on rollup issue"
        git checkout main 2>/dev/null || true
        continue
      fi
      # Extract old token from evidence/claim
      old_tok=$(printf '%s' "$finding" | jq -r '.evidence' | sed -n 's/.*doc has \([0-9.]*\).*/\1/p')
      if [ -z "$old_tok" ]; then
        old_tok=$(printf '%s' "$claim" | sed -n 's/.*`\([^`]*\)`.*/\1/p')
      fi
      if [ -n "$old_tok" ]; then
        while IFS= read -r f; do
          [ -n "$f" ] || continue
          apply_replace "$f" "$old_tok" "$replace" && git add "$f" || true
        done < <(git grep -l -I "$old_tok" -- '*.md' '*.rst' '*.txt' 2>/dev/null || true)
      fi
      ;;
    enumerations|paths)
      echo "  INFO: $check correction needs a unique replacement; checklist only if ambiguous"
      # Enum/path mechanical only when replace_with or draft provides the token
      if [ -z "$replace" ] && [ -z "$(printf '%s' "$finding" | jq -r '.draft // empty')" ]; then
        continue
      fi
      cd "$repo_dir" || continue
      ensure_fork "$org" "$repo_name" "$FORK_OWNER"
      FORK_REMOTE="${FORK_OWNER}-${repo_name}-fork"
      if ! git remote get-url "$FORK_REMOTE" >/dev/null 2>&1; then
        git remote add "$FORK_REMOTE" "https://github.com/$FORK_OWNER/${repo_name}.git"
      fi
      git fetch "$FORK_REMOTE" main 2>/dev/null || true
      git checkout -B "$branch" "$FORK_REMOTE/main" 2>/dev/null || git checkout -B "$branch"
      ;;
    *)
      echo "  INFO: no mechanical edit path for check=$check"
      continue
      ;;
  esac

  if git diff --cached --quiet 2>/dev/null; then
    echo "  No staged changes"
    git checkout main 2>/dev/null || true
    continue
  fi

  pr_title="docs: fix ${claim}"
  if [ ${#pr_title} -gt 70 ]; then
    pr_title="docs: fix ${check} in ${doc_path}"
  fi
  pr_body="Mechanical doc-drift correction.

- Claim: $claim
- Boundary: ${ref:-HEAD}
- File: \`$doc_path\`

$SKILL_FOOTER"

  if pr_url=$(create_fork_pr "$org" "$repo_name" "$FORK_OWNER" "$branch" \
      "$pr_title

Automated fix by RepoMan Doc-Drift Fixer ($FIX_DATE)." \
      "$pr_title" "$pr_body"); then
    echo "  PR: $pr_url"
  else
    echo "  WARN: PR create failed"
  fi
  git checkout main 2>/dev/null || true
done < "$PROGRAM_TMPDIR/mech_corr.jsonl"

# --- Mechanical additions: one rolling PR per repo ---
echo ""
echo "=== Mechanical additions (rolling PR) ==="
repos_add=$(jq -r '.repo' "$PROGRAM_TMPDIR/mech_add.jsonl" 2>/dev/null | sort -u)
for repo in $repos_add; do
  [ -n "$repo" ] || continue
  repo_name="${repo#*/}"
  org="${repo%%/*}"
  repo_dir="$REPOS_DIR/$repo"
  branch="update/doc-drift"
  echo "--- $repo ---"

  drafts=$(jq -r --arg r "$repo" 'select(.repo==$r) | .draft // empty' \
    "$PROGRAM_TMPDIR/mech_add.jsonl")
  if [ "$DRY_RUN" = true ]; then
    echo "[DRY RUN] rolling PR $branch"
    printf '%s\n' "$drafts" | head -40
    continue
  fi

  cd "$repo_dir" || continue
  ensure_fork "$org" "$repo_name" "$FORK_OWNER"
  FORK_REMOTE="${FORK_OWNER}-${repo_name}-fork"
  if ! git remote get-url "$FORK_REMOTE" >/dev/null 2>&1; then
    git remote add "$FORK_REMOTE" "https://github.com/$FORK_OWNER/${repo_name}.git"
  fi
  git fetch "$FORK_REMOTE" 2>/dev/null || true
  # Rebase/extend existing rolling branch if present
  if git fetch "$FORK_REMOTE" "$branch" 2>/dev/null; then
    git checkout -B "$branch" "$FORK_REMOTE/$branch"
    git rebase "$FORK_REMOTE/main" 2>/dev/null || true
  else
    git checkout -B "$branch" "$FORK_REMOTE/main" 2>/dev/null || git checkout -B "$branch"
  fi

  # Append Unreleased / enum drafts into CHANGELOG or noted files
  while IFS= read -r finding; do
    [ -n "$finding" ] || continue
    check=$(printf '%s' "$finding" | jq -r '.check')
    draft=$(printf '%s' "$finding" | jq -r '.draft // empty')
    doc_path=$(printf '%s' "$finding" | jq -r '.doc_path')
    [ -n "$draft" ] || continue
    case "$check" in
      release_draft|release_coverage)
        cl="$doc_path"
        [ -f "$cl" ] || cl="CHANGELOG.md"
        if [ -f "$cl" ]; then
          if grep -q '^## \[Unreleased\]' "$cl"; then
            # Insert draft bullets after the Unreleased heading
            python3 - "$cl" "$draft" <<'PY'
import sys
path, draft = sys.argv[1], sys.argv[2]
text = open(path, encoding="utf-8").read()
# Drop the heading from draft if Unreleased already exists
body = "\n".join(line for line in draft.splitlines() if not line.startswith("## "))
if body.strip() and body.strip() not in text:
    text = text.replace("## [Unreleased]", "## [Unreleased]\n\n" + body.strip() + "\n", 1)
    open(path, "w", encoding="utf-8").write(text)
PY
          else
            printf '%s\n\n%s' "$draft" "$(cat "$cl")" > "$cl.tmp" && mv "$cl.tmp" "$cl"
          fi
          git add "$cl"
        fi
        ;;
      enumerations|flags)
        # Append a checklist note file rather than inventing prose placement
        note=".repoman/doc-drift-additions.md"
        mkdir -p .repoman
        {
          echo "## Pending doc additions ($FIX_DATE)"
          echo ""
          echo "- \`$draft\` — from finding on \`$doc_path\`"
        } >> "$note"
        git add "$note"
        ;;
    esac
  done < <(jq -c --arg r "$repo" 'select(.repo==$r)' "$PROGRAM_TMPDIR/mech_add.jsonl")

  if git diff --cached --quiet 2>/dev/null; then
    echo "  Nothing to commit on rolling PR"
    git checkout main 2>/dev/null || true
    continue
  fi

  pr_title="docs: doc-drift updates for $repo_name"
  pr_body="Rolling documentation updates from RepoMan doc-drift.

Includes mechanical additions (release drafts / enum gaps). Paste release
draft sections into GitHub Releases manually — this fixer does not publish.

$SKILL_FOOTER"

  # If an open PR already exists for this head, just push
  existing_pr=$(gh pr list --repo "$repo" --head "$FORK_OWNER:$branch" --state open \
    --json url --jq '.[0].url // empty' 2>/dev/null || true)
  git commit -s -m "docs: doc-drift updates

Automated update by RepoMan Doc-Drift Fixer ($FIX_DATE)." || true
  git push "$FORK_REMOTE" "$branch" 2>/dev/null || {
    echo "  WARN: push failed"
    git checkout main 2>/dev/null || true
    continue
  }
  if [ -n "$existing_pr" ]; then
    echo "  Updated existing PR: $existing_pr"
  else
    pr_url=$(gh pr create --repo "$repo" --head "$FORK_OWNER:$branch" --base main \
      --title "$pr_title" --body "$pr_body" 2>/dev/null || true)
    echo "  PR: ${pr_url:-create failed}"
  fi
  git checkout main 2>/dev/null || true
done

echo ""
echo "=== Doc Drift Fixer Summary ==="
echo "Non-mechanical findings left on rollup issues: $(wc -l < "$PROGRAM_TMPDIR/non_mech.jsonl" | tr -d ' ')"
if [ "$DRY_RUN" = true ]; then
  echo "Dry-run complete — no PRs opened."
fi
