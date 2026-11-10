#!/usr/bin/env bash
# RepoMan input model: reads ~/.repoman/config.json and ~/.repoman/repos.json
# (repoman_config, repoman_get_repos, is_enrolled), plus repos-dir validation.
#
# ## Portability
# Targets bash 3.2+ (macOS default) through modern bash.
#
# No intra-library deps: functions invoke gh/git/jq/builtins directly, so this
# module sources no sibling module. Self-contained for vendoring. (repoman_config
# and repoman_get_repos do read runtime JSON data files under ~/.repoman -- that
# is caller data, not a module.)
[ -n "${_ORG_SH_LOADED:-}" ] && return
_ORG_SH_LOADED=1

# =============================================================================
# PATH VALIDATION
# =============================================================================

# Validate that a repos directory is set and not pointing to a dangerous path.
# Rejects root filesystem paths, system directories, and $HOME itself
# (without a subdirectory). Intended to prevent accidental scanning or
# modification of system files.
#
# Usage: validate_repos_dir "$REPOS_DIR" [label]
# Args:
#   $1 - the repos directory path to validate
#   $2 - optional label for how the caller names this path in its own errors
#        (default "REPOS_DIR", the env var the scanner/fixer flow exports).
#        repoman-setup.sh passes "--repos-dir" so messages match the flag the
#        user actually typed, rather than an env var that interface never asks
#        for.
# Returns: 0 if valid, returns 1 with an error message if invalid. (Returns,
# not exits: the caller unwinds its own error path -- both the top-level
# scanner/fixer callers under set -e and repoman-setup.sh's cmd_init_config
# treat a non-zero return as the failure it is.)
validate_repos_dir() {
  local path="$1"
  local label="${2:-REPOS_DIR}"

  if [ -z "$path" ]; then
    echo "ERROR: $label is not set." >&2
    echo "Point it at the directory containing your org's cloned repos." >&2
    return 1
  fi

  # Resolve to absolute path for comparison
  local resolved
  resolved=$(cd "$path" 2>/dev/null && pwd) || resolved="$path"

  # Reject obviously dangerous paths
  local dangerous_paths=("/" "/etc" "/usr" "/var" "/sys" "/proc" "/bin" "/sbin" "/lib" "/tmp")
  for dangerous in "${dangerous_paths[@]}"; do
    if [ "$resolved" = "$dangerous" ]; then
      echo "ERROR: $label cannot be '$resolved' -- this is a system directory." >&2
      return 1
    fi
  done

  # Reject $HOME itself (must be a subdirectory)
  if [ "$resolved" = "$HOME" ]; then
    echo "ERROR: $label cannot be your home directory itself." >&2
    echo "Use a subdirectory instead." >&2
    return 1
  fi

  # Check the directory exists
  if [ ! -d "$path" ]; then
    echo "ERROR: $label '$path' does not exist." >&2
    echo "Create it (and clone your org's repos there) or point $label at an existing directory." >&2
    return 1
  fi

  return 0
}

# =============================================================================
# REPOMAN INPUT MODEL
# =============================================================================
#
# RepoMan reads two user-managed files under ~/.repoman:
#   config.json : deployment-wide constants ({repos_dir, fork_owner})
#   repos.json  : the enrolled set (array of {owner, name})
# There is no $ORG and no core-repos.txt. Repos are addressed as owner/name,
# and clone dirs are owner-namespaced ($REPOS_DIR/<owner>/<name>/).

# Read ~/.repoman/config.json and export the deployment-wide constants.
# Sets: REPOS_DIR (from .repos_dir, leading ~ expanded to $HOME), FORK_OWNER
# (from .fork_owner). Override the path with $REPOMAN_CONFIG_FILE (tests).
# Fails loud (return 1) on a missing file or a missing/empty required key --
# report/source targets are NOT read here; they are per-program (Phase 2).
repoman_config() {
  local config_file="${REPOMAN_CONFIG_FILE:-$HOME/.repoman/config.json}"
  if [ ! -f "$config_file" ]; then
    echo "ERROR: RepoMan config not found: $config_file" >&2
    return 1
  fi

  local repos_dir fork_owner
  repos_dir=$(jq -r '.repos_dir // empty' "$config_file")
  fork_owner=$(jq -r '.fork_owner // empty' "$config_file")

  if [ -z "$repos_dir" ]; then
    echo "ERROR: config.json missing required key: repos_dir ($config_file)" >&2
    return 1
  fi
  if [ -z "$fork_owner" ]; then
    echo "ERROR: config.json missing required key: fork_owner ($config_file)" >&2
    return 1
  fi

  # Expand a leading ~ to $HOME. jq returns the literal string "~", so these
  # patterns match a literal tilde and we expand to $HOME by hand -- SC2088's
  # "tilde does not expand in quotes" is exactly the intent here, not a bug.
  # shellcheck disable=SC2088
  case "$repos_dir" in
    "~") repos_dir="$HOME" ;;
    "~/"*) repos_dir="$HOME/${repos_dir#"~/"}" ;;
  esac

  REPOS_DIR="$repos_dir"
  FORK_OWNER="$fork_owner"
  export REPOS_DIR FORK_OWNER
}

# Print the enrolled repo set, one "owner/name" per line, in file order.
# Reads ~/.repoman/repos.json (array of {owner,name}); override the path with
# $REPOMAN_REPOS_FILE (tests). Fails loud (return 1) on a missing/empty file
# or an entry missing owner or name -- never silently scan an empty set.
#
# Usage (portable; no mapfile on bash 3.2):
#   REPOS=(); while IFS= read -r r; do [ -n "$r" ] && REPOS+=("$r"); done \
#     < <(repoman_get_repos)
repoman_get_repos() {
  local repos_file="${REPOMAN_REPOS_FILE:-$HOME/.repoman/repos.json}"
  if [ ! -f "$repos_file" ]; then
    echo "ERROR: RepoMan repos file not found: $repos_file" >&2
    return 1
  fi

  # jq -e exits non-zero if the array is empty or any entry lacks owner/name;
  # the guarded expression fails the whole read rather than emit a bad ref.
  # An empty string is rejected too: jq's `//` fires only on null/false/absent,
  # not on "", so a `{"owner":"a","name":""}` typo would otherwise emit "a/".
  # select() drops the empty/null value so `//` sees `empty` and errors.
  local out
  if ! out=$(jq -er '
      if length == 0 then error("empty repos array")
      else .[] | ((.owner | select(. != null and . != "")) // error("entry missing owner")) as $o
                 | ((.name  | select(. != null and . != "")) // error("entry missing name"))  as $n
                 | "\($o)/\($n)"
      end' "$repos_file" 2>/dev/null); then
    echo "ERROR: repos.json is empty or has a malformed entry: $repos_file" >&2
    return 1
  fi
  printf '%s\n' "$out"
}

# Return 0 if the given "owner/name" is in the enrolled set, else 1.
# Exact whole-line match (grep -Fx) to avoid substring false positives.
# Args: $1 - "owner/name"
#
# Re-parses repos.json on every call, so it is a one-off membership check, not a
# per-iteration one. To iterate the enrolled clones in a loop, use
# enrolled_clone_dirs (which drives from the enrolled set and stats each clone).
is_enrolled() {
  local repo="$1"
  repoman_get_repos | grep -qxF "$repo"
}

# Load the enrolled set once for in-memory membership checks. A thin semantic
# alias for repoman_get_repos: it prints the same "owner/name"-per-line set and
# fails loud identically, and it re-reads repos.json on every call (there is no
# internal caching -- capturing the result once is the caller's job). Callers
# capture it into a variable before a loop:
#   enrolled=$(repoman_load_enrolled) || exit 1
repoman_load_enrolled() {
  repoman_get_repos
}

# Return 0 if "owner/name" ($1) is in a preloaded enrolled set ($2, newline-
# separated as produced by repoman_load_enrolled), else 1. Exact whole-line
# match (grep -Fx) -- same substring-safe semantics as is_enrolled, but against
# a preloaded set string rather than a file read. For a one-off check of a repo
# discovered outside the enrolled set; the clone loops instead drive from the
# set directly via enrolled_clone_dirs, so they need no per-repo membership test.
# Args: $1 - "owner/name"; $2 - the preloaded enrolled set
is_enrolled_in() {
  local repo="$1" enrolled="$2"
  printf '%s\n' "$enrolled" | grep -qxF "$repo"
}

# Emit each ENROLLED "owner/name" whose clone exists under $REPOS_DIR, one per
# line, in enrolled order. This is the scanners'/fixers' loop driver: they
# iterate the enrolled set and stat each clone, rather than globbing
# "$REPOS_DIR"/*/ and filtering. Globbing silently dropped a ".github" repo,
# because bash excludes leading-dot entries from a "*/" glob unless dotglob is
# set; driving from enrollment makes the enrolled set authoritative and treats
# a leading-dot name as the ordinary string it is. A repo enrolled but not yet
# cloned (no "$REPOS_DIR/owner/name/.git") is skipped, not emitted.
# Args: $1 - the preloaded enrolled set (as from repoman_load_enrolled).
# Reads: $REPOS_DIR (must be set by repoman_config).
# Callers capture once and iterate with a here-string, keeping the loop body in
# the current shell so counters accumulate:
#   CLONES=$(enrolled_clone_dirs "$ENROLLED")
#   while IFS= read -r full_repo; do ... done <<< "$CLONES"
enrolled_clone_dirs() {
  local enrolled="$1" full
  printf '%s\n' "$enrolled" | while IFS= read -r full; do
    [ -n "$full" ] || continue
    [ -d "$REPOS_DIR/$full/.git" ] || continue
    printf '%s\n' "$full"
  done
}

# Emit every enrolled "owner/name" whose NAME component == <bare-name> ($1),
# one per line, in enrolled (file) order. Zero matches -> no output, return 0
# (the caller distinguishes 0/1/>=2 matches by counting output lines, mapping
# onto the entrypoint skill's reconciliation rules 5/3/4). Drives from
# repoman_get_repos, so it honors $REPOMAN_REPOS_FILE and PROPAGATES its
# fail-loud behavior on a missing/empty/malformed file -- a read failure must
# not look like "zero matches", so capture-then-iterate (not a bare pipe, whose
# exit would be the while's 0 regardless of the left side). Whole-name match via
# suffix strip (${line##*/}), substring-safe: "cort" never matches "cortex".
# bash 3.2-safe: no mapfile, no associative arrays.
# Args: $1 - bare repo name (no owner, no slash)
repoman_match_name() {
  local want="$1" line repos
  repos=$(repoman_get_repos) || return 1
  printf '%s\n' "$repos" | while IFS= read -r line; do
    [ -n "$line" ] || continue
    # Must end the loop body with a 0-status command: a trailing non-matching
    # line would otherwise leave `[ ... ] && printf` at exit 1, making the while
    # (and the whole pipe) return 1 on a successful "no match for the last
    # repo", which a `set -e` caller reads as a hard failure. The `if` guard
    # keeps the body's final status 0 regardless of whether this line matched.
    if [ "${line##*/}" = "$want" ]; then
      printf '%s\n' "$line"
    fi
  done
}

# =============================================================================
# REPO SELECTION
# =============================================================================
#
# Single source of truth for which repos the programs act on: the enrolled set
# in ~/.repoman/repos.json (see REPOMAN INPUT MODEL above). Programs derive
# their repo set from repoman_get_repos()/is_enrolled(), so coverage is defined
# in one place rather than hardcoded per script. Repos are addressed as
# owner/name and clone dirs are owner-namespaced, so there is no canonical-name
# remap step: each repo's directory is its owner/name pair, unambiguously.
