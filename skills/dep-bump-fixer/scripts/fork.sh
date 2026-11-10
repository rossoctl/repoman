#!/usr/bin/env bash
# Fork/PR workflow helpers: fork creation, cross-fork PR creation, issue-field
# validation, and link-fix candidate scoring.
#
# ## Portability
# Targets bash 3.2+ (macOS default) through modern bash.
#
# No intra-library deps: every function here invokes gh/git/jq directly, so this
# module sources no sibling module. Self-contained for vendoring — copy it alone.
# If a function later calls a core.sh/github-api.sh helper, add a self-source
# block after the guard (resolved via ${BASH_SOURCE[0]}), per the design doc.
[ -n "${_FORK_SH_LOADED:-}" ] && return
_FORK_SH_LOADED=1

# =============================================================================
# ISSUE BODY VALIDATION
# =============================================================================

# Validate fields extracted from a scanner-created issue body.
# Returns 0 if all fields pass validation, 1 if any field is malformed.
# This prevents injection via crafted issue bodies.
#
# Usage:
#   if ! validate_issue_fields "$issue_repo" "$issue_file" "$broken_url" "$http_status" "$category"; then
#     echo "WARN: Skipping issue with malformed fields"
#     continue
#   fi
#
# Args:
#   $1 - repo field (expected: org/repo format)
#   $2 - file field (expected: relative path, no ..)
#   $3 - url field (expected: http:// or https://)
#   $4 - status field (expected: numeric or known text)
#   $5 - category field (expected: internal, external, or relative)
# Returns: 0 if valid, 1 if any field fails (prints warning to stderr)
validate_issue_fields() {
  local repo="$1"
  local file="$2"
  local url="$3"
  local status="$4"
  local category="$5"

  # Repo must match org/repo pattern
  if ! echo "$repo" | grep -qE '^[a-zA-Z0-9._-]+/[a-zA-Z0-9._-]+$'; then
    echo "  WARN: Invalid repo field: '$repo'" >&2
    return 1
  fi

  # File must not contain path traversal or shell metacharacters
  if echo "$file" | grep -qE '(\.\./|[;$`|&<>])'; then
    echo "  WARN: Invalid file field (contains unsafe characters): '$file'" >&2
    return 1
  fi

  # URL must start with http:// or https://
  if ! echo "$url" | grep -qE '^https?://'; then
    echo "  WARN: Invalid URL field (not http/https): '$url'" >&2
    return 1
  fi

  # Status must be numeric or a known enum token
  if ! echo "$status" | grep -qE '^([0-9]{3}|unknown|timeout|dns|unreachable|error)$'; then
    echo "  WARN: Invalid status field: '$status'" >&2
    return 1
  fi

  # Category must be a known value
  if ! echo "$category" | grep -qE '^(internal|external|relative)$'; then
    echo "  WARN: Invalid category field: '$category'" >&2
    return 1
  fi

  return 0
}

# =============================================================================
# PATH-SUFFIX SCORING
# =============================================================================

# Score a candidate path against a broken path by counting shared leading
# path segments (case-insensitive prefix match). This prioritizes candidates
# that share the most directory context with the broken URL, which best
# identifies where a renamed/moved file ended up.
#
# Example:
#   score_path_suffix "authbridge/cmd/authbridge/README.md" "authbridge/cmd/README.md"
#   # prints: 2 (shared prefix: authbridge/cmd)
#
# Args:
#   $1 - broken path (the original path from the URL)
#   $2 - candidate path (a found file)
# Prints: integer score (number of shared leading segments, 0 if none match)
score_path_suffix() {
  local broken_path="$1"
  local candidate_path="$2"

  # Lowercase both for case-insensitive comparison
  local broken_lower candidate_lower
  broken_lower=$(printf '%s' "$broken_path" | tr '[:upper:]' '[:lower:]')
  candidate_lower=$(printf '%s' "$candidate_path" | tr '[:upper:]' '[:lower:]')

  # Split paths into arrays by "/"
  IFS='/' read -ra broken_parts <<< "$broken_lower"
  IFS='/' read -ra candidate_parts <<< "$candidate_lower"

  local broken_len=${#broken_parts[@]}
  local candidate_len=${#candidate_parts[@]}
  local max_compare=$((broken_len < candidate_len ? broken_len : candidate_len))
  local score=0

  # Count shared leading segments
  local i
  for ((i = 0; i < max_compare; i++)); do
    if [ "${broken_parts[$i]}" = "${candidate_parts[$i]}" ]; then
      score=$((score + 1))
    else
      break
    fi
  done

  echo "$score"
}

# Given a broken path and a newline-separated list of candidates, find the
# best match by path-prefix score. Prints the winning candidate if there's
# a unique top scorer with score >= min_score; prints nothing otherwise.
#
# Usage:
#   winner=$(pick_best_candidate "$target_path" "$candidates" 1)
#
# Args:
#   $1 - broken path (from URL)
#   $2 - newline-separated candidate paths
#   $3 - minimum score threshold (default: 1)
# Prints: best candidate path if unique winner, empty if tied or below threshold
# Returns: 0 if unique winner found, 1 otherwise
pick_best_candidate() {
  local broken_path="$1"
  local candidates="$2"
  local min_score="${3:-1}"

  local best_score=0
  local best_candidate=""
  local tied=false

  while IFS= read -r candidate; do
    [ -z "$candidate" ] && continue
    local score
    score=$(score_path_suffix "$broken_path" "$candidate")

    if [ "$score" -gt "$best_score" ]; then
      best_score=$score
      best_candidate="$candidate"
      tied=false
    elif [ "$score" -eq "$best_score" ] && [ "$score" -gt 0 ]; then
      tied=true
    fi
  done <<< "$candidates"

  if [ "$best_score" -ge "$min_score" ] && [ "$tied" = false ] && [ -n "$best_candidate" ]; then
    echo "$best_candidate"
    return 0
  fi

  return 1
}

# =============================================================================
# FORK / PR MANAGEMENT
# =============================================================================

# Ensure a fork of the target repo exists under the fork owner's account.
# If the fork doesn't exist, creates it and waits briefly for GitHub to
# propagate it (forks are not instantly available for push).
#
# Usage:
#   ensure_fork "kagenti" "adk" "clawgenti"
#
# Args:
#   $1 - org name (e.g., "kagenti")
#   $2 - repo name (e.g., "adk")
#   $3 - fork owner account (e.g., "clawgenti")
ensure_fork() {
  local org="$1"
  local repo_name="$2"
  local fork_owner="$3"

  # Check if fork already exists
  if gh repo view "$fork_owner/$repo_name" &>/dev/null 2>&1; then
    return 0
  fi

  # Create the fork
  gh repo fork "$org/$repo_name" --org "$fork_owner" --clone=false 2>/dev/null || true

  # Wait for GitHub to make the fork available for push
  sleep 5
}

# Create a cross-fork PR from a fix branch. This function handles:
#   1. Adding the fork as a git remote (idempotent)
#   2. Committing staged changes with DCO sign-off
#   3. Pushing the branch to the fork
#   4. Creating the PR against upstream main
#
# Prerequisites: caller must have already cd'd into the repo directory,
# created the branch, and staged the changes (git add).
#
# Usage:
#   pr_url=$(create_fork_pr "kagenti" "adk" "clawgenti" \
#     "fix/broken-links-2026-05-21" \
#     "docs: Fix broken link in README.md" \
#     "docs: Fix 1 broken internal link(s) in adk" \
#     "Automated fix by Kagenti Link Health Fixer.")
#
# Args:
#   $1 - org name
#   $2 - repo name
#   $3 - fork owner
#   $4 - branch name
#   $5 - commit message
#   $6 - PR title
#   $7 - PR body
# Prints: the PR URL on success
# Returns: 0 on success, 1 on failure
create_fork_pr() {
  local org="$1"
  local repo_name="$2"
  local fork_owner="$3"
  local branch="$4"
  local commit_msg="$5"
  local pr_title="$6"
  local pr_body="$7"

  local fork_remote="${fork_owner}-fork"

  # Add fork remote (idempotent -- silently skips if already exists)
  if ! git remote get-url "$fork_remote" &>/dev/null 2>&1; then
    git remote add "$fork_remote" \
      "https://github.com/$fork_owner/$repo_name.git" 2>/dev/null || true
  fi

  # Commit with DCO sign-off (-s adds Signed-off-by trailer)
  git commit -s -m "$commit_msg"

  # Push branch to the fork
  if ! git push "$fork_remote" "$branch" --force-with-lease 2>/dev/null; then
    echo "  WARN: Failed to push branch $branch to $fork_owner/$repo_name" >&2
    return 1
  fi

  # Create cross-fork PR against upstream main
  local pr_url
  pr_url=$(gh pr create \
    --repo "$org/$repo_name" \
    --head "$fork_owner:$branch" \
    --base main \
    --title "$pr_title" \
    --body "$pr_body" \
    2>/dev/null)

  if [ -z "$pr_url" ]; then
    echo "  WARN: Failed to create PR for $org/$repo_name" >&2
    return 1
  fi

  echo "$pr_url"
}
