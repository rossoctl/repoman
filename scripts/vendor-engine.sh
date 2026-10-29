#!/usr/bin/env bash
set -uo pipefail
# Vendor the RepoMan engine from an automation checkout into the repoman plugin's
# flat scripts dir, then stamp the source commit SHA for provenance.
#
# Explicit manifest (never a glob) so this can only ever populate the repoman
# plugin — it must never touch a standalone skill's scripts/ (see agent-skills#51).
# Part of the RepoMan v0.1.0 packaged release (epic rossoctl/automation#72).
#
#   vendor-engine.sh --source <automation-repo> --dest <repoman-scripts-dir>

SRC="" DEST=""
while [ $# -gt 0 ]; do
  case "$1" in
    --source) SRC="${2:-}"; shift 2 ;;
    --dest)   DEST="${2:-}"; shift 2 ;;
    *) echo "ERROR: unknown arg: $1" >&2; exit 2 ;;
  esac
done
[ -n "$SRC" ] && [ -n "$DEST" ] || { echo "ERROR: --source and --dest are required" >&2; exit 2; }

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

# Provenance stamp: record the SOURCE repo's HEAD sha (not the dest repo's).
if ! SHA=$(git -C "$SRC" rev-parse HEAD 2>/dev/null); then
  echo "ERROR: cannot read source HEAD sha from $SRC" >&2; exit 1
fi
NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
# word-splitting $MANIFEST into one line per script is intentional
# shellcheck disable=SC2086
if ! FILES_JSON=$( {
  printf '%s\n' $MANIFEST | sed 's/$/.sh/'
  printf '%s\n' $EXTRA_FILES
} | jq -R . | jq -s .); then
  echo "ERROR: could not build file list" >&2; exit 1
fi
if ! jq -n --arg repo "rossoctl/automation" --arg sha "$SHA" --arg at "$NOW" \
      --argjson files "$FILES_JSON" \
      '{source_repo:$repo, source_sha:$sha, vendored_at:$at, files:$files}' \
      > "$DEST/_vendor.json"; then
  echo "ERROR: provenance stamp write failed" >&2; exit 1
fi

# shellcheck disable=SC2086
echo "Vendored $(echo $MANIFEST | wc -w | tr -d ' ') engine scripts (+ extras) to $DEST (source $SHA)"
