#!/usr/bin/env bash
# Single point of parsing for the SKILL.md `### Requirements (machine-readable)`
# block. Everything downstream consumes the normalized JSON this emits; nothing
# else parses SKILL.md.
#
# ## Portability
# Targets bash 3.2+ (macOS default): no mapfile, no declare -A, no associative
# arrays.
[ -n "${_REPOMAN_REQUIREMENTS_SH_LOADED:-}" ] && return
_REPOMAN_REQUIREMENTS_SH_LOADED=1

# Print normalized requirements JSON for a SKILL.md file.
# Usage: repoman_parse_requirements <skill-md-path>
# Emits {"pat_scopes":[...],"labels_required":[...],"labels_applied":[...],"programs":[...]}
# Missing keys default to []. Fails loud (return 1) on a malformed block.
repoman_parse_requirements() {
  local skill_md="$1"
  if [ ! -f "$skill_md" ]; then
    echo "ERROR: repoman_parse_requirements: file not found: $skill_md" >&2
    return 1
  fi

  local in_block=0 line key body
  # Per-bullet list-splitting scratch (declared here, not inside the loop, so
  # block-scoping expectations are not misled; reset per bullet at use site).
  local IFS_SAVE item items
  # Newline-delimited item accumulators, one per recognized key.
  local pat_scopes="" labels_required="" labels_applied="" programs=""

  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      '###'[[:space:]]*[Rr]equirements*) in_block=1; continue ;;
    esac
    if [ "$in_block" -eq 1 ]; then
      # A new heading closes the leaf block.
      case "$line" in
        '##'[[:space:]]*|'###'[[:space:]]*) in_block=0; continue ;;
      esac
      # Only consider "- key: ..." bullets; ignore blank/prose lines.
      case "$line" in
        '- '*': '*)
          key="${line#- }"; key="${key%%:*}"
          body="${line#*: }"
          case "$key" in
            pat_scopes|labels_required|labels_applied|programs) ;;
            *) echo "ERROR: repoman_parse_requirements: unknown key '$key' in Requirements block of $skill_md (recognized keys: pat_scopes, labels_required, labels_applied, programs; the block accepts no prose bullets -- put notes outside the block)" >&2; return 1 ;;
          esac
          # Value must be bracketed.
          case "$body" in
            '['*']') ;;
            *) echo "ERROR: repoman_parse_requirements: value for '$key' must be a [bracketed] list in $skill_md" >&2; return 1 ;;
          esac
          # Strip brackets, split on commas, trim, append non-empty items.
          body="${body#[}"; body="${body%]}"
          IFS_SAVE="$IFS"; items=""
          IFS=','
          for item in $body; do
            # trim leading/trailing whitespace
            item="${item#"${item%%[![:space:]]*}"}"
            item="${item%"${item##*[![:space:]]}"}"
            [ -n "$item" ] && items="${items}${item}"$'\n'
          done
          IFS="$IFS_SAVE"
          case "$key" in
            pat_scopes)      pat_scopes="$items" ;;
            labels_required) labels_required="$items" ;;
            labels_applied)  labels_applied="$items" ;;
            programs)        programs="$items" ;;
          esac
          ;;
      esac
    fi
  done < "$skill_md"

  # Build each JSON array from a newline-delimited accumulator via jq -R -s.
  # No sort: the normalized-JSON contract preserves the author-declared order
  # from the SKILL.md bullet. Downstream consumers test membership, not order,
  # so insertion order is behaviorally safe and more faithful than alphabetizing.
  _rpr_json_array() {
    # stdin: newline-delimited items (possibly empty) -> compact JSON array
    jq -R -s 'split("\n") | map(select(length > 0))'
  }
  local j_pat j_lr j_la j_prog
  j_pat=$(printf '%s' "$pat_scopes" | _rpr_json_array)
  j_lr=$(printf '%s' "$labels_required" | _rpr_json_array)
  j_la=$(printf '%s' "$labels_applied" | _rpr_json_array)
  j_prog=$(printf '%s' "$programs" | _rpr_json_array)
  unset -f _rpr_json_array

  jq -n \
    --argjson pat_scopes "$j_pat" \
    --argjson labels_required "$j_lr" \
    --argjson labels_applied "$j_la" \
    --argjson programs "$j_prog" \
    '{pat_scopes:$pat_scopes, labels_required:$labels_required, labels_applied:$labels_applied, programs:$programs}'
}

# This file is a sourced library, not a command. Executing it directly used to
# exit 0 and print nothing: a caller that ran `repoman-requirements.sh <skill>`
# (instead of sourcing it) captured an empty string, parsed it as [], and wrote
# EMPTY requirements -- a silent capability-gate failure. Fail loud instead.
# "${BASH_SOURCE[0]}" == "$0" only when this file is the executed script, not
# when it is sourced. bash 3.2-safe.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  echo "ERROR: repoman-requirements.sh is a sourced library, not a command." >&2
  echo "Source it, then call the function:" >&2
  # Show the real resolved path to this library (BASH_SOURCE[0] is this file,
  # since we only reach here when executed). A snippet with $0 or an
  # unexpanded BASH_SOURCE would refer to the CALLER's script, not this one.
  echo "    . \"${BASH_SOURCE[0]}\"" >&2
  echo "    repoman_parse_requirements <skill-md-path>" >&2
  exit 2
fi
