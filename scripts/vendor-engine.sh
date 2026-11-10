#!/usr/bin/env bash
set -uo pipefail
# Vendor the RepoMan engine from an automation checkout, then stamp the source
# commit SHA for provenance. Two modes:
#   --dest   <dir>  : the repoman plugin's flat scripts dir (the release bundle).
#   --skills <dir>  : the standalone link-health/dep-bump skill dirs under it.
#
# Explicit manifests (never a glob): the run can only ever write the dirs and
# files named in MANIFEST/EXTRA_FILES (plugin) or SKILL_SET/SKILL_LIB
# (standalone) — preserving the agent-skills#51 intent that no unlisted path is
# touched, now that standalone dirs are a deliberate target.
# Part of the RepoMan v0.1.0 packaged release (epic rossoctl/automation#72).
#
#   vendor-engine.sh --source <automation-repo> --dest   <repoman-scripts-dir> [--allow-dirty]
#   vendor-engine.sh --source <automation-repo> --skills <repoman-skills-dir>  [--allow-dirty]

SRC="" DEST="" SKILLS="" ALLOW_DIRTY=false
# needs_value <flag> <argc>: a value-taking flag must have an argument after it,
# or `shift 2` would fail to shift and the loop would spin forever.
needs_value() { [ "$2" -ge 2 ] || { echo "ERROR: $1 needs a value" >&2; exit 2; }; }
while [ $# -gt 0 ]; do
  case "$1" in
    --source) needs_value "$1" "$#"; SRC="$2"; shift 2 ;;
    --dest)   needs_value "$1" "$#"; DEST="$2"; shift 2 ;;
    --skills) needs_value "$1" "$#"; SKILLS="$2"; shift 2 ;;
    --allow-dirty) ALLOW_DIRTY=true; shift ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SRC" ] || { echo "ERROR: --source is required" >&2; exit 2; }
if [ -n "$DEST" ] && [ -n "$SKILLS" ]; then
  echo "ERROR: --dest and --skills are mutually exclusive" >&2; exit 2
fi
[ -n "$DEST" ] || [ -n "$SKILLS" ] || { echo "ERROR: one of --dest or --skills is required" >&2; exit 2; }

# Fail closed: if $SRC cannot be inspected at all (not a git checkout — e.g.
# a tarball extract — or git missing), the dirty check below would read the
# resulting empty output as "clean", the run would only die at the stamp
# step, and the dest would be left half-vendored with a stale _vendor.json.
# Unconditional: the stamp needs a source HEAD even with --allow-dirty.
if ! git -C "$SRC" rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: cannot inspect $SRC (not a git checkout?); the provenance stamp requires a source HEAD" >&2; exit 1
fi

# Provenance guard: the stamp records the source HEAD SHA, so vendoring a
# dirty tree would stamp a commit that does not contain the copied bytes
# (see repoman#20). Reject a dirty source unless --allow-dirty is passed
# (scratch experiments only; the stamp then knowingly lies about the bytes).
if [ "$ALLOW_DIRTY" = false ] && [ -n "$(git -C "$SRC" status --porcelain 2>/dev/null)" ]; then
  echo "ERROR: source $SRC has uncommitted changes; commit or stash them so the provenance stamp matches the vendored bytes (or pass --allow-dirty)" >&2; exit 1
fi

# The 26 engine shell scripts. Flat set: nearly all source program-lib.sh,
# which sources core.sh/github-api.sh/fork.sh/org.sh/repoman-requirements.sh.
MANIFEST="automation-health-dashboard core dep-bump-fixer dep-bump-scanner \
doc-drift-fixer doc-drift-precheck doc-drift-scanner \
extract-broken-links fork github-api link-health-fixer link-health-scanner \
org parse-diff-map pr-review-fixer pr-review-impact pr-review-lib \
pr-review-scanner program-lib repo-sync repoman-check repoman-index \
repoman-requirements repoman-run repoman-setup weekly-report"

# Non-shell engine files copied alongside the manifest (explicit, no glob).
EXTRA_FILES="doc-drift-check.py"

# The six modular lib files every standalone skill dir needs. program-lib.sh is
# the aggregator; it sources the other five siblings via $SCRIPT_DIR, so all six
# must be co-located in each skill dir for sourcing to resolve.
SKILL_LIB="program-lib core github-api fork org repoman-requirements"

# Per-skill file set for --skills mode: "<skill-dir>:<basename>[,<basename>…]".
# Each entry's basenames are source files under $SRC/scripts/ to co-locate, on
# top of SKILL_LIB. A basename with an extension (link-check.py) is taken as-is;
# one without gets ".sh" appended. Explicit, never a glob (preserves the
# agent-skills#51 intent that this can only write the dirs/files named here).
# dep-bump-fixer's SKILL.md mentions dep-bump-scanner.sh only as a usage example,
# not a runtime dependency, so it is deliberately NOT co-located there.
SKILL_SET="link-health-scanner:link-health-scanner,extract-broken-links,link-check.py \
link-health-fixer:link-health-fixer \
dep-bump-scanner:dep-bump-scanner \
dep-bump-fixer:dep-bump-fixer"

# Resolve the SOURCE repo HEAD sha once (shared by both modes' stamps).
if ! SRC_SHA=$(git -C "$SRC" rev-parse HEAD 2>/dev/null); then
  echo "ERROR: cannot read source HEAD sha from $SRC" >&2; exit 1
fi

# write_vendor_stamp <dest-dir> <newline-separated-file-list>
# Writes <dest-dir>/_vendor.json with the source repo, the source HEAD sha, a
# fresh timestamp, and the given file list. vendored_at intentionally varies per
# run; source_sha + files are the stable, tested provenance.
write_vendor_stamp() {
  local dest="$1" files_nl="$2" files_json now
  if ! files_json=$(printf '%s\n' "$files_nl" | jq -R . | jq -s .); then
    echo "ERROR: could not build file list for $dest" >&2; return 1
  fi
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if ! jq -n --arg repo "rossoctl/automation" --arg sha "$SRC_SHA" --arg at "$now" \
        --argjson files "$files_json" \
        '{source_repo:$repo, source_sha:$sha, vendored_at:$at, files:$files}' \
        > "$dest/_vendor.json"; then
    echo "ERROR: provenance stamp write failed for $dest" >&2; return 1
  fi
}

if [ -n "$DEST" ]; then
  # --- Plugin mode: flat engine manifest into one dest dir. ---
  # Pre-validate the WHOLE manifest before copying anything, so a source missing
  # late in the list cannot leave a half-vendored dest with a stale _vendor.json.
  # shellcheck disable=SC2086
  for f in $MANIFEST; do
    if [ ! -f "$SRC/scripts/$f.sh" ]; then
      echo "ERROR: missing engine source: $SRC/scripts/$f.sh (nothing copied)" >&2; exit 1
    fi
  done
  # shellcheck disable=SC2086
  for f in $EXTRA_FILES; do
    if [ ! -f "$SRC/scripts/$f" ]; then
      echo "ERROR: missing engine source: $SRC/scripts/$f (nothing copied)" >&2; exit 1
    fi
  done

  mkdir -p "$DEST"
  # shellcheck disable=SC2086
  for f in $MANIFEST; do
    if ! cp "$SRC/scripts/$f.sh" "$DEST/$f.sh"; then
      echo "ERROR: copy failed for $f.sh" >&2; exit 1
    fi
  done
  # shellcheck disable=SC2086
  for f in $EXTRA_FILES; do
    if ! cp "$SRC/scripts/$f" "$DEST/$f"; then
      echo "ERROR: copy failed for $f" >&2; exit 1
    fi
  done

  # word-splitting $MANIFEST into one line per script is intentional
  # shellcheck disable=SC2086
  stamp_files=$( { printf '%s\n' $MANIFEST | sed 's/$/.sh/'; printf '%s\n' $EXTRA_FILES; } )
  write_vendor_stamp "$DEST" "$stamp_files" || exit 1

  # shellcheck disable=SC2086
  echo "Vendored $(echo $MANIFEST | wc -w | tr -d ' ') engine scripts (+ extras) to $DEST (source $SRC_SHA)"

elif [ -n "$SKILLS" ]; then
  # --- Standalone-skill mode: resync each standalone skill dir. ---
  # Resolve every skill's source file list first, then pre-validate the WHOLE
  # union, so a source missing for any skill fails loud with no dir half-vendored.
  # resolve_basename() maps a SKILL_SET token to the source basename under scripts/:
  #   "link-check.py" -> "link-check.py"; "dep-bump-scanner" -> "dep-bump-scanner.sh"
  resolve_basename() {
    case "$1" in
      *.*) printf '%s' "$1" ;;   # already has an extension (e.g. .py)
      *)   printf '%s.sh' "$1" ;;
    esac
  }

  # Pre-validate: every lib file + every per-skill file must exist in the source.
  # shellcheck disable=SC2086
  for entry in $SKILL_SET; do
    skill_dir="${entry%%:*}"; csv="${entry#*:}"
    for f in $SKILL_LIB; do
      [ -f "$SRC/scripts/$f.sh" ] || { echo "ERROR: missing engine source: $SRC/scripts/$f.sh (for $skill_dir; nothing copied)" >&2; exit 1; }
    done
    IFS=',' read -ra parts <<< "$csv"
    for p in "${parts[@]}"; do
      bn=$(resolve_basename "$p")
      [ -f "$SRC/scripts/$bn" ] || { echo "ERROR: missing engine source: $SRC/scripts/$bn (for $skill_dir; nothing copied)" >&2; exit 1; }
    done
  done

  # Copy + stamp per skill dir.
  # shellcheck disable=SC2086
  for entry in $SKILL_SET; do
    skill_dir="${entry%%:*}"; csv="${entry#*:}"
    dest="$SKILLS/$skill_dir/scripts"
    mkdir -p "$dest"
    files_nl=""
    for f in $SKILL_LIB; do
      if ! cp "$SRC/scripts/$f.sh" "$dest/$f.sh"; then
        echo "ERROR: copy failed for $f.sh -> $dest" >&2; exit 1
      fi
      files_nl="${files_nl}${f}.sh
"
    done
    IFS=',' read -ra parts <<< "$csv"
    for p in "${parts[@]}"; do
      bn=$(resolve_basename "$p")
      if ! cp "$SRC/scripts/$bn" "$dest/$bn"; then
        echo "ERROR: copy failed for $bn -> $dest" >&2; exit 1
      fi
      files_nl="${files_nl}${bn}
"
    done
    # Trim trailing newline before stamping.
    write_vendor_stamp "$dest" "${files_nl%$'\n'}" || exit 1
    echo "Resynced $skill_dir (source $SRC_SHA)"
  done
fi
