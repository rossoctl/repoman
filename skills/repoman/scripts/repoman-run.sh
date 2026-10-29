#!/usr/bin/env bash
# repoman run <program> [target...] — the RepoMan run-path orchestrator.
#
# Pure glue: resolves a program to its step profile, (optionally) narrows to a
# named enrolled subset, runs the capability gate + clone refresh as the profile
# requires, execs the program, and writes its _index.json entry. Non-interactive
# (output routing must be set beforehand via repoman-setup.sh set-output).
#
# The run-path half of the RepoMan v0.1.0 completion work (issue #107, epic #72).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/program-lib.sh
. "$SCRIPT_DIR/program-lib.sh"

usage() {
  # Program list is DERIVED from the table (via _known_programs) so it cannot
  # drift from what is actually runnable.
  cat <<EOF
Usage: repoman-run.sh <program> [target...] [--dry-run] [--help]

Run a RepoMan program against the enrolled repos (or a named subset).
<program> is one of: $(_known_programs)
[target...] are owner/name slugs or bare names ALREADY reconciled by the skill.
Non-interactive: output routing must be set beforehand (repoman-setup.sh set-output).
EOF
}

# Per-program step table. One row per program. Fields (tab-separated):
#   1 program  2 profile  3 needs_clone_refresh  4 posts_output  5 writes_index
#   6 scanner_script  7 display_name  8 report_path  9 supports_dry_run
#   10 needs_live
# needs_live=yes means the program PREVIEWS by default and publishes only on an
# explicit --live (e.g. automation-health-dashboard); the orchestrator forwards
# --live on a normal run for those. The scanners push by default (silenced by
# --dry-run), so they are needs_live=no.
# Must stay consistent with KNOWN_PROGRAMS in repoman-setup.sh (unify = #76).
_PROGRAM_TABLE="\
link-health	scanner	yes	yes	yes	link-health-scanner.sh	Link Health	$HOME/reports/link-health	yes	no
dep-bump	scanner	yes	yes	yes	dep-bump-scanner.sh	Dependency Bumps	$HOME/reports/dep-bump	yes	no
pr-review	scanner	no	no	no	pr-review-scanner.sh	PR Review		yes	no
weekly-report	scanner	no	no	no	weekly-report.sh	Weekly Report		no	no
doc-drift	scanner	yes	yes	yes	doc-drift-scanner.sh	Doc Drift	$HOME/reports/doc-drift	yes	no
automation-health	index-consumer	no	no	no	automation-health-dashboard.sh	Automation Health		yes	yes
repo-sync	sync	no	no	no	repo-sync.sh	Repo Sync		yes	no"

# _program_row <program> -> echoes the tab-separated row, or returns 1 if unknown.
# NOTE: the `while` runs in a subshell (right side of a pipe), so a `return`
# inside it cannot set this function's status; the trailing `grep .` detects
# whether any row matched and sets the exit status. bash 3.2-safe.
_program_row() {
  local want="$1"
  printf '%s\n' "$_PROGRAM_TABLE" | awk -F'\t' -v w="$want" '$1==w {print; exit}' | grep .
}

# _known_programs -> space-separated list of known program ids.
_known_programs() {
  printf '%s\n' "$_PROGRAM_TABLE" | awk -F'\t' 'NF {printf "%s ", $1}'
}

# _row_field <row> <n> -> the n-th tab-separated field (1-indexed).
_row_field() { printf '%s\n' "$1" | awk -F'\t' -v n="$2" '{print $n}'; }

# _resolve_targets <target...> -> newline-delimited owner/name set, or non-zero
# on an unknown/unenrolled target. Trusts the skill's reconciliation; only
# VALIDATES enrollment (defensive). Bare name -> repoman_match_name. With no
# targets, emits nothing (caller treats as the whole enrolled set).
_resolve_targets() {
  [ "$#" -gt 0 ] || return 0
  local t resolved nmatch
  for t in "$@"; do
    case "$t" in
      */*)
        if is_enrolled "$t"; then
          printf '%s\n' "$t"
        else
          echo "ERROR: target '$t' is not enrolled" >&2; return 1
        fi ;;
      *)
        if ! resolved=$(repoman_match_name "$t"); then
          echo "ERROR: failed resolving target '$t'" >&2; return 1
        fi
        if [ -z "$resolved" ]; then
          echo "ERROR: target '$t' matches no enrolled repo" >&2; return 1
        fi
        # repoman_match_name emits one line per matching owner/name. A bare name
        # enrolled under >=2 owners is AMBIGUOUS: fail loud with the candidates
        # rather than silently broaden the run to all of them. (This CLI accepts
        # bare names directly, so it must not guess which owner was meant.)
        nmatch=$(printf '%s\n' "$resolved" | grep -c .)
        if [ "$nmatch" -gt 1 ]; then
          echo "ERROR: target '$t' is ambiguous — enrolled under multiple owners:" >&2
          printf '  %s\n' "$resolved" >&2
          echo "Re-run with an explicit owner/name." >&2
          return 1
        fi
        printf '%s\n' "$resolved" ;;
    esac
  done | awk 'NF && !seen[$0]++'   # dedup, preserve first-seen order
}

# Run-scoped temp dir for subset projection; cleaned on any exit (success,
# error, or signal). Only a hard kill -9 leaks, and $TMPDIR is OS-reclaimed.
RUN_TMPDIR=""
_cleanup_run_tmp() { [ -n "$RUN_TMPDIR" ] && rm -rf "$RUN_TMPDIR"; }
trap _cleanup_run_tmp EXIT

# _project_subset <dir> <newline-delimited owner/name> -> path to a throwaway
# repos.json (inside <dir>) holding exactly that subset. Lives in $TMPDIR (NOT
# under ~/.repoman/); written directly as a projection, which is allowed because
# it is outside the guarded dir (HARD INVARIANT guards only ~/.repoman/ state).
# The CALLER owns the dir (and its cleanup) so the EXIT trap can see it — a dir
# created in this command-substitution subshell would not be visible to the
# parent's trap, leaking the temp dir.
_project_subset() {
  local dir="$1" set_in="$2"
  local out="$dir/repos.json"
  if ! printf '%s\n' "$set_in" \
      | jq -R 'select(length>0) | {owner: (split("/")[0]), name: (split("/")[1])}' \
      | jq -s '.' > "$out"; then
    echo "ERROR: failed writing subset repos file" >&2; return 1
  fi
  printf '%s\n' "$out"
}

# _bin <name> -> path to a sibling script, overridable by REPOMAN_RUN_BIN (tests
# inject stubs there).
_bin() { echo "${REPOMAN_RUN_BIN:-$SCRIPT_DIR}/$1"; }

# _require_output_repo <program> -> rc 0 if output_repo is present and
# well-formed in programs/<name>.json (mode:same, or mode:central with a
# non-empty owner/name repo); non-zero + fail-loud otherwise. Never prompts.
_require_output_repo() {
  local program="$1" progdir f mode repo
  progdir="${REPOMAN_PROGRAMS_DIR:-$HOME/.repoman/programs}"
  f="$progdir/$program.json"
  if [ ! -f "$f" ]; then
    echo "ERROR: $program: output destination not set (no $f). Run /repoman or repoman-setup.sh set-output." >&2
    return 1
  fi
  mode=$(jq -r '.output_repo.mode // empty' "$f" 2>/dev/null)
  if [ -z "$mode" ]; then
    echo "ERROR: $program: output destination not set. Run /repoman or repoman-setup.sh set-output." >&2
    return 1
  fi
  if [ "$mode" = "central" ]; then
    repo=$(jq -r '.output_repo.repo // empty' "$f" 2>/dev/null)
    case "$repo" in
      */*) : ;;
      *) echo "ERROR: $program: output_repo mode=central but 'repo' missing/malformed in $f" >&2; return 1 ;;
    esac
  fi
  return 0
}

# _run_capability_check <program> -> non-zero if the scope gate failed.
# repoman-check.sh exits non-zero iff a PAT scope gap was found; label gaps are
# warnings there and do not flip its exit. We surface its stderr and propagate.
_run_capability_check() {
  local program="$1"
  if ! bash "$(_bin repoman-check.sh)" --program "$program"; then
    echo "ERROR: $program: capability check failed (scope gate)." >&2
    return 1
  fi
}

# _run_clone_refresh -> non-zero only on TOTAL sync failure. repo-sync.sh exits
# 1 iff ALL enrolled repos failed (a partial failure is logged there and exits
# 0); total failure is fatal because there is nothing cloned to scan.
_run_clone_refresh() {
  if ! bash "$(_bin repo-sync.sh)"; then
    echo "ERROR: clone refresh failed for all repos; cannot scan." >&2
    return 1
  fi
}

# _write_index <program> <display_name> <report_path> -> registers the program
# in _index.json via repoman-index.sh. The orchestrator is the SOLE index
# writer (scanners no longer self-register). A failed index write is logged, not
# fatal: the program's reports are the primary product.
_write_index() {
  local program="$1" display="$2" report_path="$3"
  local index_file="${REPOMAN_INDEX_FILE:-$(dirname "$report_path")/_index.json}"
  if ! bash "$(_bin repoman-index.sh)" --index "$index_file" \
        --program "$program" --display-name "$display" --report-path "$report_path"; then
    echo "WARNING: failed to update program registry at $index_file (program output was still produced)" >&2
  fi
}

main() {
  local program="" dry_run=false
  local -a targets=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --help|-h) usage; return 0 ;;
      --dry-run) dry_run=true; shift ;;
      -*) echo "ERROR: unknown flag: $1" >&2; usage >&2; return 2 ;;
      *) if [ -z "$program" ]; then program="$1"; else targets+=("$1"); fi; shift ;;
    esac
  done
  [ -n "$program" ] || { echo "ERROR: no program given" >&2; usage >&2; return 2; }

  local row
  if ! row=$(_program_row "$program"); then
    echo "ERROR: unknown program '$program'. Known programs: $(_known_programs)" >&2
    return 2
  fi

  local profile; profile=$(_row_field "$row" 2)

  local needs_clone; needs_clone=$(_row_field "$row" 3)
  local posts_output; posts_output=$(_row_field "$row" 4)
  local writes_index; writes_index=$(_row_field "$row" 5)
  local scanner_script; scanner_script=$(_row_field "$row" 6)
  local display_name; display_name=$(_row_field "$row" 7)
  local report_path; report_path=$(_row_field "$row" 8)
  local supports_dry_run; supports_dry_run=$(_row_field "$row" 9)
  local needs_live; needs_live=$(_row_field "$row" 10)

  # Validate / resolve any named targets against the enrolled set (defensive;
  # the skill has already reconciled them). Empty -> whole enrolled set.
  local resolved_set
  if ! resolved_set=$(_resolve_targets "${targets[@]+"${targets[@]}"}"); then
    return 1
  fi

  # Output routing must be set beforehand for programs that post results.
  if [ "$posts_output" = "yes" ]; then
    _require_output_repo "$program" || return 1
  fi

  # Narrow to a subset via a throwaway repos file when targets were named.
  # Only the scanner profile narrows to a subset; index-consumer (dashboard)
  # and sync (repo-sync) act over the whole enrolled set regardless of targets.
  if [ "$profile" = "scanner" ] && [ -n "$resolved_set" ]; then
    # Create the temp dir in the PARENT so the EXIT trap (which reads the
    # global RUN_TMPDIR) can clean it; a dir made inside _project_subset's
    # command-substitution subshell would be invisible to the trap and leak.
    if ! RUN_TMPDIR=$(mktemp -d); then
      echo "ERROR: mktemp -d failed; cannot project repo subset" >&2; return 1
    fi
    local subset_file
    if ! subset_file=$(_project_subset "$RUN_TMPDIR" "$resolved_set"); then
      return 1
    fi
    export REPOMAN_REPOS_FILE="$subset_file"
    # Explicit subset signal for stateful scanners: a narrowed run must scope its
    # diff/close/write to only these repos and carry the rest of the previous
    # report forward, and must NOT append a (partial) history row. Newline-
    # delimited owner/name. Absent => whole-set run (scanners behave as before).
    export REPOMAN_SUBSET_REPOS="$resolved_set"
  fi

  # Execution preconditions apply to the scanner profile only. index-consumer
  # (dashboard) reads the index and needs no scope/clone; sync (repo-sync) IS the
  # clone refresh and takes no PAT scopes — both skip the gate and refresh.
  if [ "$profile" = "scanner" ]; then
    _run_capability_check "$program" || return 1
    if [ "$needs_clone" = "yes" ]; then
      _run_clone_refresh || return 1
    fi
  fi

  # Exec the program. Flag forwarding:
  #   --dry-run run: forward --dry-run to programs that accept it, so they
  #     suppress their mutating tail (issue/PR/docs push).
  #   normal run: for a needs_live program (previews by default, publishes only
  #     on --live, e.g. the dashboard), forward --live so a scheduled run
  #     actually publishes. The push-by-default scanners get nothing.
  # Never forward both --dry-run and --live.
  # Invoke via an explicit `bash` interpreter rather than relying on the file's
  # execute bit: the repo's scanners are not uniformly chmod +x (e.g.
  # dep-bump-scanner.sh is 100644 in git) and the house convention everywhere
  # else is `bash <script>`.
  local -a prog_args=()
  if "$dry_run"; then
    [ "$supports_dry_run" = "yes" ] && prog_args+=(--dry-run)
  else
    [ "$needs_live" = "yes" ] && prog_args+=(--live)
  fi
  if ! bash "$(_bin "$scanner_script")" "${prog_args[@]+"${prog_args[@]}"}"; then
    echo "ERROR: $program exec failed" >&2; return 1
  fi

  # Register in the index (sole writer). Only for programs with the shape, and
  # NOT on a dry run: a dry run writes no latest.json, so registering it would
  # point the dashboard at a report that does not exist (it would then error
  # "No program reports found"). The index must name where reports ACTUALLY
  # landed: the scanner writes to ${REPORTS_DIR:-<program default>}, so honor a
  # REPORTS_DIR override here too, falling back to the table's default.
  if [ "$writes_index" = "yes" ] && ! "$dry_run"; then
    local effective_report_path="${REPORTS_DIR:-$report_path}"
    _write_index "$program" "$display_name" "$effective_report_path"
  fi
  return 0
}

main "$@"
