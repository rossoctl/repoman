#!/usr/bin/env bash
# GitHub API helpers: rate-limit-aware gh wrapper and issue read/close/PR-check
# operations.
#
# ## Portability
# Targets bash 3.2+ (macOS default) through modern bash.
#
# No intra-library deps: functions invoke gh/jq directly, so this module sources
# no sibling module. Self-contained for vendoring.
[ -n "${_GITHUB_API_SH_LOADED:-}" ] && return
_GITHUB_API_SH_LOADED=1

# =============================================================================
# GITHUB API
# =============================================================================

# Rate-limit-aware wrapper around the gh CLI.
# Retries up to 3 times with exponential backoff on 403/429/rate-limit errors.
#
# Usage:
#   gh_with_backoff issue list --repo kagenti/adk --state open --json number
#
# Global: increments RATE_LIMIT_BACKOFF counter (initialize to 0 before use)
RATE_LIMIT_BACKOFF=${RATE_LIMIT_BACKOFF:-0}

gh_with_backoff() {
  local attempt=0
  local max_attempts=3
  local wait=5
  while [ $attempt -lt $max_attempts ]; do
    if output=$(gh "$@" 2>&1); then
      RATE_LIMIT_BACKOFF=0
      printf '%s' "$output"
      return 0
    fi
    if echo "$output" | grep -qiE 'rate limit|403|429|secondary rate'; then
      attempt=$((attempt + 1))
      RATE_LIMIT_BACKOFF=$((RATE_LIMIT_BACKOFF + 1))
      if [ $attempt -lt $max_attempts ]; then
        echo "  WARN: Rate limited, backing off ${wait}s (attempt $attempt/$max_attempts)" >&2
        sleep $wait
        wait=$((wait * 2))
      fi
    else
      printf '%s' "$output" >&2
      return 1
    fi
  done
  echo "  ERROR: Rate limit persisted after $max_attempts attempts, stopping" >&2
  return 1
}

# =============================================================================
# GITHUB ISSUES
# =============================================================================

# Check if an open issue already exists that matches a search query.
# Used for deduplication before creating new issues.
#
# Usage:
#   if existing=$(gh_issue_exists "kagenti/adk" "Broken link in README.md"); then
#     echo "Issue #$existing already open"
#   fi
#
# Args:
#   $1 - full repo name (e.g., "kagenti/adk")
#   $2 - search string (matched against issue title/body by GitHub)
# Returns: 0 if found (prints issue number), 1 if not found
gh_issue_exists() {
  local repo="$1"
  local search="$2"
  local result

  result=$(gh issue list \
    --repo "$repo" \
    --search "$search" \
    --state open \
    --json number \
    --jq '.[0].number' \
    2>/dev/null || echo "")

  if [ -n "$result" ] && [ "$result" != "null" ]; then
    echo "$result"
    return 0
  fi

  return 1
}

# Close an issue with a comment. Checks the exit code of `gh issue close`
# before reporting success -- this prevents the "close-before-verify" bug
# where we'd claim an issue was closed when the API call actually failed.
#
# Usage:
#   if close_issue_if_valid "kagenti/adk" "123" "Fixed in scan 2026-05-21-001."; then
#     echo "Closed"
#   fi
#
# Args:
#   $1 - full repo name
#   $2 - issue number
#   $3 - comment to add when closing
# Returns: 0 on success, 1 on failure (prints warning to stderr)
close_issue_if_valid() {
  local repo="$1"
  local number="$2"
  local comment="$3"

  if gh issue close "$number" --repo "$repo" --comment "$comment" 2>/dev/null; then
    return 0
  fi

  echo "  WARN: Failed to close issue #$number in $repo" >&2
  return 1
}

# Returns 0 if any open PR in $repo plausibly covers $issue_number.
# Prints the covering PR number on stdout when found (for logging).
#
# Uses a three-layer detection strategy:
#   Layer 1: GraphQL closingIssuesReferences (keyword-agnostic, author-agnostic)
#   Layer 2: Keyword text search across all authors (close/fix/resolve variants)
#   Layer 3: File + URL overlap in PR diffs (catches unlisted but covered issues)
#
# Args:
#   $1 - full repo name (e.g., "kagenti/adk")
#   $2 - issue number
#   $3 - (optional) source file path from the issue body
#   $4 - (optional) broken URL from the issue body
# Returns: 0 if covered, 1 otherwise
issue_has_open_pr() {
  local repo="$1"
  local issue_number="$2"
  local source_file="${3:-}"
  local broken_url="${4:-}"
  local owner="${repo%/*}"
  local repo_name="${repo#*/}"
  local pr_number

  # Layer 1: GraphQL closingIssuesReferences (cheapest, most authoritative)
  pr_number=$(gh api graphql -f query='
    query($owner:String!, $repo:String!, $num:Int!) {
      repository(owner:$owner, name:$repo) {
        issue(number:$num) {
          closedByPullRequestsReferences(first:5, includeClosedPrs:false) {
            nodes { number state }
          }
        }
      }
    }' \
    -F owner="$owner" -F repo="$repo_name" -F num="$issue_number" \
    --jq '.data.repository.issue.closedByPullRequestsReferences.nodes[] | select(.state == "OPEN") | .number' \
    2>/dev/null | head -1)

  if [ -n "$pr_number" ]; then
    echo "$pr_number"
    return 0
  fi

  # Layer 2: Keyword search fallback (broader text match, all authors)
  pr_number=$(gh pr list --repo "$repo" --state open \
    --search "#$issue_number" \
    --json number,body \
    --jq ".[] | select(.body | test(\"(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)\\\\s+#$issue_number(?![0-9])\")) | .number" \
    2>/dev/null | head -1)

  if [ -n "$pr_number" ]; then
    echo "$pr_number"
    return 0
  fi

  # Layer 3: File + URL overlap (only when source_file and broken_url provided)
  if [ -n "$source_file" ] && [ -n "$broken_url" ]; then
    local pr_numbers
    pr_numbers=$(gh pr list --repo "$repo" --state open \
      --json number,files \
      --jq ".[] | select(.files[]?.path == \"$source_file\") | .number" \
      2>/dev/null)

    local candidate_pr
    local escaped_url
    escaped_url=$(printf '%s' "$broken_url" | sed -E 's/[.[\*^$()+?{|]/\\&/g')

    while IFS= read -r candidate_pr; do
      [ -z "$candidate_pr" ] && continue
      if gh pr diff "$candidate_pr" --repo "$repo" 2>/dev/null \
        | grep -Eq "^-.*$escaped_url"; then
        echo "$candidate_pr"
        return 0
      fi
    done <<< "$pr_numbers"
  fi

  return 1
}

# =============================================================================
# SKILL PROVENANCE AND ATTRIBUTION (RepoMan Phase 6)
# =============================================================================

# Canonical skill source repo. Every attribution footer points here (the repo
# where skills are canonical), NOT at the automation repo that happens to host
# this library copy.
SKILL_SOURCE_REPO="${SKILL_SOURCE_REPO:-rossoctl/agent-skills}"

# Resolve a skill's pinned commit SHA, writing a per-skill _meta file beside the
# skill on first success (create-only, self-healing).
#
# The meta file is keyed PER SKILL NAME (_meta.<skill-name>.json), not per
# directory: in the flat scripts/ layout every program shares one SCRIPT_DIR, so
# a directory-only key would let whichever skill runs first pin ITS sha for all
# of them, and create-only means the wrong sha would never self-correct. Keying
# by name keeps each skill's pinned sha independent in any layout.
#
# On entry, if that per-skill meta file already exists it is read and its
# .version echoed -- no network call. Otherwise the SHA is resolved from the
# canonical source repo's commit history for that skill's path. On success the
# meta file is written and the SHA echoed; on failure (offline, unauthorized,
# rate limited) NOTHING is written -- the function warns to stderr and echoes
# empty, so the caller falls back to the blob/main attribution and the next run
# retries. It must never write a sentinel such as {"version":"unknown"}: a
# present-but-bogus file would stop the retry and pin a wrong version forever.
#
# Usage: sha=$(resolve_skill_meta "$SCRIPT_DIR" "link-health-scanner")
# Args:
#   $1 - skill directory (where the meta file lives / will be written)
#   $2 - skill name (its path segment under skills/ in the source repo)
# Prints: the resolved commit SHA, or empty string on failure.
# Returns: 0 always (provenance resolution never affects the scan/fix rc).
resolve_skill_meta() {
  local skill_dir="$1"
  local skill_name="$2"
  local meta_file="$skill_dir/_meta.$skill_name.json"
  local sha=""

  # Create-only: an existing _meta.<skill>.json with a valid .version is
  # authoritative, never overwritten (refreshing on skill update is the deploy
  # layer's job). But a present-yet-corrupt file (truncated write, hand-edit,
  # not JSON) yields no .version -- treating that as authoritative would pin the
  # skill to the blob/main fallback forever with no self-heal. So we only short-
  # circuit on a readable version; a corrupt file falls through to re-resolution,
  # which overwrites it on success, honoring the spec's self-heal invariant.
  if [ -f "$meta_file" ]; then
    sha=$(jq -r '.version // empty' "$meta_file" 2>/dev/null)
    if [ -n "$sha" ]; then
      printf '%s' "$sha"
      return 0
    fi
    echo "WARN: $meta_file exists but carries no usable .version (corrupt?); re-resolving provenance." >&2
  fi

  # Resolve the pinned SHA from the canonical source repo's history for this
  # skill's path. Failure here is non-fatal and leaves the meta file absent.
  sha=$(gh api \
    "repos/$SKILL_SOURCE_REPO/commits?path=skills/$skill_name&per_page=1" \
    --jq '.[0].sha' 2>/dev/null)

  if [ -z "$sha" ] || [ "$sha" = "null" ]; then
    echo "WARN: could not resolve provenance SHA for skill '$skill_name'; using blob/main attribution (will retry next run)." >&2
    printf ''
    return 0
  fi

  # Write the per-skill _meta.<skill>.json atomically beside the skill.
  local installed_at
  installed_at=$(date -u +"%Y-%m-%d")
  local tmp="$meta_file.tmp.$$"
  if jq -n \
      --arg version "$sha" \
      --arg source "$SKILL_SOURCE_REPO" \
      --arg installed_at "$installed_at" \
      '{version: $version, source: $source, installed_at: $installed_at}' \
      > "$tmp" 2>/dev/null && mv "$tmp" "$meta_file" 2>/dev/null; then
    :
  else
    # Could not persist (read-only dir, etc.): still return the resolved SHA so
    # this run gets a pinned footer, but leave no file so the next run retries.
    rm -f "$tmp" 2>/dev/null
    echo "WARN: resolved provenance SHA for '$skill_name' but could not write $meta_file (will retry next run)." >&2
  fi

  printf '%s' "$sha"
  return 0
}

# Build the attribution footer for a skill's PR / issue body.
#
# Resolves the skill's pinned SHA (via resolve_skill_meta, using the caller's
# own SCRIPT_DIR as the skill directory so it works on every deploy layout) and
# returns the pinned-SHA RepoMan footer. On resolution failure it returns the
# blob/main fallback that pins to the live default branch instead -- additive,
# so a working scan never depends on a reachable GitHub API.
#
# Usage: footer=$(skill_attribution "link-health-scanner")
# Args:
#   $1 - skill name (also the path segment under skills/)
# Prints: a one-line "Generated by RepoMan ..." attribution footer.
skill_attribution() {
  local skill_name="$1"
  local skill_dir="${SCRIPT_DIR:-.}"
  local sha
  sha=$(resolve_skill_meta "$skill_dir" "$skill_name")

  if [ -n "$sha" ]; then
    printf 'Generated by RepoMan %s@%s (https://github.com/%s/blob/%s/skills/%s/SKILL.md).' \
      "$skill_name" "${sha:0:7}" "$SKILL_SOURCE_REPO" "$sha" "$skill_name"
  else
    printf 'Generated by RepoMan %s (https://github.com/%s/blob/main/skills/%s/SKILL.md).' \
      "$skill_name" "$SKILL_SOURCE_REPO" "$skill_name"
  fi
}
