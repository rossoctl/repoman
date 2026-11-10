#!/usr/bin/env bash
# Pure writer/validator for the three ~/.repoman file kinds RepoMan reads.
#
# Subcommands: init-config, add-repo, enable-program, set-output. Each writes
# exactly one thing, validates it, and persists atomically (temp file in the
# target directory, then `mv` into place, so a crash mid-write never leaves a
# half-written JSON file).
#
# This script never calls gh, never prompts, never clones, never forks. It
# receives already-resolved inputs (from the repoman-setup skill) and writes
# JSON. All paths honor the same $REPOMAN_* overrides the reader uses:
#   REPOMAN_CONFIG_FILE   (default ~/.repoman/config.json)
#   REPOMAN_REPOS_FILE    (default ~/.repoman/repos.json)
#   REPOMAN_PROGRAMS_DIR  (default ~/.repoman/programs/)
#
# ## Portability
# Targets bash 3.2+ (macOS default) through modern bash: no mapfile, no
# declare -A in tested paths.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/program-lib.sh"

# Known program identifiers, matched against the actual scanner scripts and
# standing orders in this repo: scripts/link-health-scanner.sh,
# scripts/dep-bump-scanner.sh, scripts/pr-review-scanner.sh,
# scripts/automation-health-dashboard.sh, standing-orders/repo-sync.md.
#
# This hardcoded list is the current source of truth for the allowlist. A
# user who introduces a new program must add its identifier here until the
# program registry (_index.json, tracked in #76) replaces it with a
# discovered list.
KNOWN_PROGRAMS="link-health dep-bump pr-review automation-health repo-sync weekly-report doc-drift"

usage() {
  cat <<'EOF'
Usage: repoman-setup.sh <subcommand> [flags]

Pure writer/validator for the ~/.repoman config files. Non-interactive: no
gh calls, no prompting, no clone, no fork.

Subcommands:
  init-config --repos-dir <path> --fork-owner <owner>
      Write config.json {repos_dir, fork_owner}.

  add-repo (--owner <o> --name <n>)... | <JSON array on stdin>
      Merge one or more {owner,name} entries into repos.json. Dedups on
      owner/name.

  enable-program --program <name>
      Merge {"enabled": true} into programs/<name>.json.
      Known programs: link-health, dep-bump, pr-review, automation-health,
      repo-sync, weekly-report, doc-drift.

  set-output --program <name> --mode same|central [--repo <owner/name>]
      Merge {"output_repo": {...}} into programs/<name>.json.
      --repo is required (and validated as owner/name) iff --mode central.

  set-requirements --program <name> [--pat-scopes <csv>] \
      [--labels-required <csv>] [--labels-applied <csv>]
      Merge {pat_scopes, labels_required, labels_applied} (each parsed from a
      comma-separated value into a JSON array) into programs/<name>.json. A
      missing or empty CSV yields [].

Each subcommand also accepts --help.

Path overrides (same as the reader):
  REPOMAN_CONFIG_FILE, REPOMAN_REPOS_FILE, REPOMAN_PROGRAMS_DIR
EOF
}

is_known_program() {
  local name="$1" p
  for p in $KNOWN_PROGRAMS; do
    [ "$p" = "$name" ] && return 0
  done
  return 1
}

# Atomically write $2 (file content) to $1 (target path): temp file in the
# same directory, then mv into place. mkdir -p the target's directory first.
atomic_write() {
  local target="$1" content="$2" dir tmp
  dir="$(dirname "$target")"
  mkdir -p "$dir"
  tmp="$(mktemp "$dir/.repoman-setup.XXXXXX")"
  # Clean up the temp file if the write or the rename fails (e.g. disk full).
  # Under set -e a bare failing printf/mv would abort the script and orphan the
  # .repoman-setup.XXXXXX temp file in the target dir, so guard each step and
  # remove the temp before propagating the failure. On success the mv consumes
  # the temp file. (An inline guard, not a RETURN trap: a function-scoped
  # RETURN trap leaks to later functions' returns under set -u.)
  if ! printf '%s\n' "$content" > "$tmp"; then
    rm -f "$tmp"
    echo "ERROR: atomic_write: failed to write temp file for $target." >&2
    return 1
  fi
  if ! mv "$tmp" "$target"; then
    rm -f "$tmp"
    echo "ERROR: atomic_write: failed to move temp file into $target." >&2
    return 1
  fi
}

# =============================================================================
# init-config
# =============================================================================

cmd_init_config() {
  if [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: repoman-setup.sh init-config --repos-dir <path> --fork-owner <owner>

Write ~/.repoman/config.json ({repos_dir, fork_owner}), overridable via
REPOMAN_CONFIG_FILE. Both flags are required and non-empty. A leading ~ in
--repos-dir is expanded to $HOME the same way the reader (repoman_config)
expands it. repos_dir is validated with validate_repos_dir (from the reader).
Idempotent: re-running overwrites the file.
EOF
    return 0
  fi

  local repos_dir="" fork_owner=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --repos-dir)
        # Guard arity before `shift 2`: a trailing flag with no value leaves
        # only one positional, so `shift 2` fails and `set -e` aborts the
        # script SILENTLY (exit 1, no message) before the checks below ever
        # run. Fail loudly instead, consistent with every other error here.
        [ $# -ge 2 ] || { echo "ERROR: init-config: --repos-dir requires a value." >&2; return 1; }
        repos_dir="$2"
        shift 2
        ;;
      --fork-owner)
        [ $# -ge 2 ] || { echo "ERROR: init-config: --fork-owner requires a value." >&2; return 1; }
        fork_owner="$2"
        shift 2
        ;;
      *)
        echo "ERROR: init-config: unknown flag: $1" >&2
        return 1
        ;;
    esac
  done

  if [ -z "$repos_dir" ]; then
    echo "ERROR: init-config: --repos-dir is required and must be non-empty." >&2
    return 1
  fi
  if [ -z "$fork_owner" ]; then
    echo "ERROR: init-config: --fork-owner is required and must be non-empty." >&2
    return 1
  fi

  # Expand a leading ~ the same way repoman_config expands it, so the value
  # persisted here and the value the reader resolves at read time agree when
  # compared post-expansion (the raw string with "~" is still what gets
  # written to config.json -- validate_repos_dir needs the expanded form to
  # check an existing directory).
  local expanded="$repos_dir"
  # shellcheck disable=SC2088
  case "$expanded" in
    "~") expanded="$HOME" ;;
    "~/"*) expanded="$HOME/${expanded#"~/"}" ;;
  esac

  # Pass the flag name so validate_repos_dir's errors name "--repos-dir" (what
  # the user typed here), not the "REPOS_DIR" env var of the scanner/fixer flow.
  validate_repos_dir "$expanded" "--repos-dir"

  local json
  json=$(jq -n --arg repos_dir "$repos_dir" --arg fork_owner "$fork_owner" \
    '{repos_dir: $repos_dir, fork_owner: $fork_owner}')

  local target="${REPOMAN_CONFIG_FILE:-$HOME/.repoman/config.json}"
  atomic_write "$target" "$json"
}

# =============================================================================
# add-repo
# =============================================================================

cmd_add_repo() {
  if [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: repoman-setup.sh add-repo (--owner <o> --name <n>)...
       repoman-setup.sh add-repo   (JSON array of {owner,name} on stdin)

Merge one or more {owner,name} entries into repos.json, overridable via
REPOMAN_REPOS_FILE. --owner/--name may repeat to add several repos in one
call, in order; the flags must alternate. A second --owner before its --name,
a --name with no preceding --owner, or a trailing --owner with no following
--name is rejected. Alternatively, pipe a JSON array of {owner,name} objects
on stdin (used with no --owner/--name flags). Rejects any entry with an empty
or missing owner or name. Dedups on owner/name (first occurrence wins);
creates the array if the file is absent.
EOF
    return 0
  fi

  local new_entries="[]"

  if [ $# -eq 0 ]; then
    # No flags given: read a JSON array from stdin.
    local stdin_json
    stdin_json=$(cat)
    if ! printf '%s' "$stdin_json" | jq -e 'type == "array"' >/dev/null 2>&1; then
      echo "ERROR: add-repo: stdin must be a JSON array of {owner,name}." >&2
      return 1
    fi
    new_entries="$stdin_json"
  else
    local owner="" name=""
    local pairs="[]"
    while [ $# -gt 0 ]; do
      case "$1" in
        --owner)
          # Guard arity before `shift 2`: a trailing flag with no value would
          # otherwise make `shift 2` fail and `set -e` abort silently (exit 1,
          # no message) before any error below runs.
          [ $# -ge 2 ] || { echo "ERROR: add-repo: --owner requires a value." >&2; return 1; }
          # A --name consumes the pending --owner and clears it. If owner is
          # still set here, a second --owner arrived before its --name (e.g.
          # "--owner alice --owner bob --name repo") -- that would silently
          # pair bob/repo and drop alice, so fail loudly on the mis-ordering
          # instead of guessing.
          if [ -n "$owner" ]; then
            echo "ERROR: add-repo: --owner given twice before a --name (mis-ordered flags?)." >&2
            return 1
          fi
          owner="$2"
          shift 2
          ;;
        --name)
          [ $# -ge 2 ] || { echo "ERROR: add-repo: --name requires a value." >&2; return 1; }
          # --name must follow its --owner; a --name with no pending owner is
          # a mis-ordered or lone flag, not an empty-owner entry to validate
          # downstream.
          if [ -z "$owner" ]; then
            echo "ERROR: add-repo: --name given without a preceding --owner." >&2
            return 1
          fi
          name="$2"
          shift 2
          pairs=$(jq -n -c --argjson arr "$pairs" --arg owner "$owner" --arg name "$name" \
            '$arr + [{owner: $owner, name: $name}]')
          owner=""
          name=""
          ;;
        *)
          echo "ERROR: add-repo: unknown flag: $1" >&2
          return 1
          ;;
      esac
    done
    # A pending owner here means a trailing --owner never met its --name.
    # Report it specifically, mirroring the loud double-owner/lone-name errors
    # above, rather than letting it fall through to the generic empty-set check.
    if [ -n "$owner" ]; then
      echo "ERROR: add-repo: --owner given without a following --name." >&2
      return 1
    fi
    new_entries="$pairs"
  fi

  # Reject an empty resolved set BEFORE any write. An empty JSON array on
  # stdin (mis-ordered flags are already caught loudly above) would otherwise
  # merge in nothing and write out an empty repos.json (or leave an absent
  # file absent) with exit 0 -- the reader then fails loud at READ time with
  # "empty repos array" instead of setup catching it immediately.
  if [ "$(printf '%s' "$new_entries" | jq 'length')" -eq 0 ]; then
    echo "ERROR: add-repo: no repos to add (empty resolved set)." >&2
    return 1
  fi

  # Validate: every entry must have a non-empty owner AND name.
  if ! printf '%s' "$new_entries" | jq -e '
      all(.[]; (.owner // "") != "" and (.name // "") != "")
    ' >/dev/null 2>&1; then
    echo "ERROR: add-repo: every entry requires a non-empty owner and name." >&2
    return 1
  fi

  local repos_file="${REPOMAN_REPOS_FILE:-$HOME/.repoman/repos.json}"
  local existing="[]"
  if [ -f "$repos_file" ]; then
    existing=$(cat "$repos_file")
  fi

  # Merge, preserving first-seen order, deduping on "owner/name". jq's
  # unique_by/group_by both SORT by the key, discarding input order, so a
  # manual reduce with a seen-set keeps the accumulator in first-seen order:
  # existing entries stay before newly-added ones, and a later duplicate
  # (existing or new) is dropped rather than reordering the list.
  local merged
  merged=$(jq -n --argjson existing "$existing" --argjson new "$new_entries" '
    ($existing + $new) as $all
    | reduce $all[] as $item
        ({seen: {}, out: []};
          ($item.owner + "/" + $item.name) as $key
          | if .seen[$key] then .
            else {seen: (.seen + {($key): true}), out: (.out + [$item])}
            end)
    | .out
  ')

  atomic_write "$repos_file" "$merged"
}

# =============================================================================
# enable-program
# =============================================================================

cmd_enable_program() {
  if [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: repoman-setup.sh enable-program --program <name>

Merge {"enabled": true} into programs/<name>.json, overridable via
REPOMAN_PROGRAMS_DIR. <name> is checked against a known-program allowlist
(link-health, dep-bump, pr-review, automation-health, repo-sync,
weekly-report) so a typo cannot create a stray file. Creates the programs/ dir if absent. This is a
JSON merge, not an overwrite: existing keys (e.g. output_repo) survive.
EOF
    return 0
  fi

  local program=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --program)
        # Guard arity before `shift 2` (see init-config): a trailing --program
        # with no value would abort silently under set -e otherwise.
        [ $# -ge 2 ] || { echo "ERROR: enable-program: --program requires a value." >&2; return 1; }
        program="$2"
        shift 2
        ;;
      *)
        echo "ERROR: enable-program: unknown flag: $1" >&2
        return 1
        ;;
    esac
  done

  if [ -z "$program" ]; then
    echo "ERROR: enable-program: --program is required and must be non-empty." >&2
    return 1
  fi
  if ! is_known_program "$program"; then
    echo "ERROR: enable-program: unknown program '$program'. Known programs: $KNOWN_PROGRAMS" >&2
    return 1
  fi

  local programs_dir="${REPOMAN_PROGRAMS_DIR:-$HOME/.repoman/programs}"
  local target="$programs_dir/$program.json"
  local existing="{}"
  if [ -f "$target" ]; then
    existing=$(cat "$target")
  fi

  local merged
  merged=$(jq -n --argjson existing "$existing" '$existing + {enabled: true}')

  atomic_write "$target" "$merged"
}

# =============================================================================
# set-output
# =============================================================================

cmd_set_output() {
  if [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: repoman-setup.sh set-output --program <name> --mode same|central [--repo <owner/name>]

Merge {"output_repo": {...}} into programs/<name>.json, overridable via
REPOMAN_PROGRAMS_DIR. <name> is checked against the same known-program
allowlist as enable-program. --mode must be "same" or "central". --repo is
required (and validated as owner/name) iff --mode is "central"; it is
ignored/omitted for "same". This is a JSON merge, not an overwrite: existing
keys (e.g. enabled) survive.
EOF
    return 0
  fi

  local program="" mode="" repo=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --program)
        # Guard arity before `shift 2` (see init-config): a trailing flag with
        # no value would abort silently under set -e otherwise.
        [ $# -ge 2 ] || { echo "ERROR: set-output: --program requires a value." >&2; return 1; }
        program="$2"
        shift 2
        ;;
      --mode)
        [ $# -ge 2 ] || { echo "ERROR: set-output: --mode requires a value." >&2; return 1; }
        mode="$2"
        shift 2
        ;;
      --repo)
        [ $# -ge 2 ] || { echo "ERROR: set-output: --repo requires a value." >&2; return 1; }
        repo="$2"
        shift 2
        ;;
      *)
        echo "ERROR: set-output: unknown flag: $1" >&2
        return 1
        ;;
    esac
  done

  if [ -z "$program" ]; then
    echo "ERROR: set-output: --program is required and must be non-empty." >&2
    return 1
  fi
  if ! is_known_program "$program"; then
    echo "ERROR: set-output: unknown program '$program'. Known programs: $KNOWN_PROGRAMS" >&2
    return 1
  fi

  case "$mode" in
    same) ;;
    central) ;;
    *)
      echo "ERROR: set-output: --mode must be 'same' or 'central' (got '$mode')." >&2
      return 1
      ;;
  esac

  local output_repo_json
  if [ "$mode" = "central" ]; then
    if [ -z "$repo" ]; then
      echo "ERROR: set-output: --repo is required when --mode is 'central'." >&2
      return 1
    fi
    case "$repo" in
      */*) ;;
      *)
        echo "ERROR: set-output: --repo must be 'owner/name' (got '$repo')." >&2
        return 1
        ;;
    esac
    local repo_owner="${repo%%/*}" repo_name="${repo#*/}"
    # Require EXACTLY one slash: repo_name must not contain another slash
    # (rejects e.g. "a/b/c", which the earlier */* check alone would accept).
    case "$repo_name" in
      */*)
        echo "ERROR: set-output: --repo must be exactly 'owner/name' (got '$repo')." >&2
        return 1
        ;;
    esac
    if [ -z "$repo_owner" ] || [ -z "$repo_name" ]; then
      echo "ERROR: set-output: --repo must be 'owner/name' with both parts non-empty (got '$repo')." >&2
      return 1
    fi
    output_repo_json=$(jq -n --arg mode "$mode" --arg repo "$repo" \
      '{mode: $mode, repo: $repo}')
  else
    output_repo_json=$(jq -n --arg mode "$mode" '{mode: $mode}')
  fi

  local programs_dir="${REPOMAN_PROGRAMS_DIR:-$HOME/.repoman/programs}"
  local target="$programs_dir/$program.json"
  local existing="{}"
  if [ -f "$target" ]; then
    existing=$(cat "$target")
  fi

  local merged
  merged=$(jq -n --argjson existing "$existing" --argjson output_repo "$output_repo_json" \
    '$existing + {output_repo: $output_repo}')

  atomic_write "$target" "$merged"
}

# =============================================================================
# set-requirements
# =============================================================================

cmd_set_requirements() {
  if [ "${1:-}" = "--help" ]; then
    cat <<'EOF'
Usage: repoman-setup.sh set-requirements --program <name> \
         [--pat-scopes <csv>] [--labels-required <csv>] [--labels-applied <csv>]

Merge {pat_scopes, labels_required, labels_applied} (each a JSON array parsed
from a comma-separated value) into programs/<name>.json, overridable via
REPOMAN_PROGRAMS_DIR. <name> is checked against the known-program allowlist.
Pure writer: no gh, no SKILL.md read. Takes ALREADY-RESOLVED values (the
setup skill parses SKILL.md via repoman_parse_requirements and passes the
CSVs here). A missing or empty CSV yields []. JSON merge: existing keys
(enabled, output_repo) survive.
EOF
    return 0
  fi

  local program="" pat_scopes="" labels_required="" labels_applied=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --program)
        # Guard arity before `shift 2` (see init-config): a trailing flag with
        # no value would abort silently under set -e otherwise.
        [ $# -ge 2 ] || { echo "ERROR: set-requirements: --program requires a value." >&2; return 1; }
        program="$2"
        shift 2
        ;;
      --pat-scopes)
        [ $# -ge 2 ] || { echo "ERROR: set-requirements: --pat-scopes requires a value." >&2; return 1; }
        pat_scopes="$2"
        shift 2
        ;;
      --labels-required)
        [ $# -ge 2 ] || { echo "ERROR: set-requirements: --labels-required requires a value." >&2; return 1; }
        labels_required="$2"
        shift 2
        ;;
      --labels-applied)
        [ $# -ge 2 ] || { echo "ERROR: set-requirements: --labels-applied requires a value." >&2; return 1; }
        labels_applied="$2"
        shift 2
        ;;
      *)
        echo "ERROR: set-requirements: unknown flag: $1" >&2
        return 1
        ;;
    esac
  done

  if [ -z "$program" ]; then
    echo "ERROR: set-requirements: --program is required and must be non-empty." >&2
    return 1
  fi
  if ! is_known_program "$program"; then
    echo "ERROR: set-requirements: unknown program '$program'. Known programs: $KNOWN_PROGRAMS" >&2
    return 1
  fi

  # CSV -> compact JSON array (trim items, drop empties). Local to the
  # writer; does NOT source the parser (pure-writer module boundary). No
  # sort: matches the Task 1 SKILL.md parser's ordering contract, which
  # preserves author-declared order end to end (SKILL.md -> parser -> this
  # writer). Re-sorting here would silently reorder what the parser produced.
  _csv_to_json_array() {
    printf '%s' "$1" | jq -R -s '
      split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length > 0))'
  }
  local j_ps j_lr j_la
  j_ps=$(_csv_to_json_array "$pat_scopes")
  j_lr=$(_csv_to_json_array "$labels_required")
  j_la=$(_csv_to_json_array "$labels_applied")
  unset -f _csv_to_json_array

  local programs_dir="${REPOMAN_PROGRAMS_DIR:-$HOME/.repoman/programs}"
  local target="$programs_dir/$program.json"
  local existing="{}"
  if [ -f "$target" ]; then
    existing=$(cat "$target")
  fi

  local merged
  merged=$(jq -n --argjson existing "$existing" \
    --argjson ps "$j_ps" --argjson lr "$j_lr" --argjson la "$j_la" \
    '$existing + {pat_scopes: $ps, labels_required: $lr, labels_applied: $la}')

  atomic_write "$target" "$merged"
}

# =============================================================================
# Dispatch
# =============================================================================

main() {
  if [ $# -eq 0 ] || [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    usage
    return 0
  fi

  local subcommand="$1"
  shift

  case "$subcommand" in
    init-config)
      cmd_init_config "$@"
      ;;
    add-repo)
      cmd_add_repo "$@"
      ;;
    enable-program)
      cmd_enable_program "$@"
      ;;
    set-output)
      cmd_set_output "$@"
      ;;
    set-requirements)
      cmd_set_requirements "$@"
      ;;
    *)
      echo "ERROR: unknown subcommand: $subcommand" >&2
      usage >&2
      return 1
      ;;
  esac
}

main "$@"
