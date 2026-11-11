#!/usr/bin/env bash
# Regression test for scripts/vendor-engine.sh — the RepoMan v0.1.0 engine
# vendor + provenance stamp. Part of the RepoMan release (epic
# rossoctl/automation#72).
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VENDOR="$SCRIPT_DIR/../scripts/vendor-engine.sh"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
fail=0

MANIFEST="automation-health-dashboard core dep-bump-fixer dep-bump-scanner \
doc-drift-fixer doc-drift-precheck doc-drift-scanner \
extract-broken-links fork github-api link-health-fixer link-health-scanner \
org parse-diff-map pr-review-fixer pr-review-impact pr-review-lib \
pr-review-scanner program-lib repo-sync repoman-check repoman-index \
repoman-requirements repoman-run repoman-setup weekly-report"
EXTRA_FILES="doc-drift-check.py"
EXPECTED_SH=26
EXPECTED_FILES=27

# Fake automation source repo holding the engine scripts, committed so it has a HEAD.
SRC="$TMP/auto"; mkdir -p "$SRC/scripts"
# shellcheck disable=SC2086
for f in $MANIFEST; do echo "#!/usr/bin/env bash" > "$SRC/scripts/$f.sh"; done
# shellcheck disable=SC2086
for f in $EXTRA_FILES; do echo "# py" > "$SRC/scripts/$f"; done
git -C "$SRC" init -q
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm init
DEST="$TMP/dest"

# --- Happy path: all shell scripts + extras copied ---
if ! bash "$VENDOR" --source "$SRC" --dest "$DEST" >/dev/null 2>&1; then
  echo "FAIL: happy-path vendor returned non-zero"; fail=1
fi
n=$(find "$DEST" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "$n" = "$EXPECTED_SH" ]; then echo "PASS: $EXPECTED_SH scripts copied"; else echo "FAIL: copied $n, expected $EXPECTED_SH"; fail=1; fi
if [ -f "$DEST/doc-drift-check.py" ]; then echo "PASS: doc-drift-check.py copied"; else echo "FAIL: doc-drift-check.py missing"; fail=1; fi

# --- Provenance stamp: correct SOURCE repo HEAD sha + file list ---
want=$(git -C "$SRC" rev-parse HEAD)
got=$(jq -r '.source_sha' "$DEST/_vendor.json" 2>/dev/null)
if [ "$got" = "$want" ]; then echo "PASS: stamp sha == source HEAD"; else echo "FAIL: stamp sha $got != source $want"; fail=1; fi
if jq -e --argjson n "$EXPECTED_FILES" '.files | length == $n' "$DEST/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: stamp lists $EXPECTED_FILES files"; else echo "FAIL: stamp file list wrong"; fail=1; fi
if jq -e '.source_repo == "rossoctl/automation"' "$DEST/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: stamp names source repo"; else echo "FAIL: stamp source_repo wrong"; fail=1; fi
if jq -e '.files | index("doc-drift-check.py")' "$DEST/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: stamp lists doc-drift-check.py"; else echo "FAIL: stamp missing doc-drift-check.py"; fail=1; fi

# --- Idempotency: second run, same source => identical stamp sha ---
bash "$VENDOR" --source "$SRC" --dest "$DEST" >/dev/null 2>&1
got2=$(jq -r '.source_sha' "$DEST/_vendor.json" 2>/dev/null)
if [ "$got2" = "$want" ]; then echo "PASS: idempotent stamp sha"; else echo "FAIL: idempotency $got2 != $want"; fail=1; fi

# --- Dirty source: rejected before any copy, dest left uncreated ---
DIRTYDEST="$TMP/dirtydest"
echo x >> "$SRC/scripts/org.sh"   # uncommitted modification
if bash "$VENDOR" --source "$SRC" --dest "$DIRTYDEST" >/dev/null 2>&1; then
  echo "FAIL: dirty source was not rejected"; fail=1
else echo "PASS: dirty source rejected"; fi
if [ ! -d "$DIRTYDEST" ]; then echo "PASS: dirty rejection left dest uncreated"; else echo "FAIL: dirty rejection still created dest"; fail=1; fi
# --- Dirty source with --allow-dirty: override works, stamp still stamped ---
if bash "$VENDOR" --source "$SRC" --dest "$DIRTYDEST" --allow-dirty >/dev/null 2>&1; then
  echo "PASS: --allow-dirty overrides the guard"
else echo "FAIL: --allow-dirty did not override"; fail=1; fi
if [ -f "$DIRTYDEST/org.sh" ]; then echo "PASS: --allow-dirty run copied files"; else echo "FAIL: --allow-dirty run copied nothing"; fail=1; fi
git -C "$SRC" checkout -- scripts/org.sh   # restore for the tests below

# --- Missing source fails loud AND leaves the dest empty (no half-vendored dir) ---
BADDEST="$TMP/baddest"
missing_source_fails() (
  BAD="$TMP/bad"; mkdir -p "$BAD/scripts"
  # shellcheck disable=SC2086
  for f in $MANIFEST; do echo x > "$BAD/scripts/$f.sh"; done
  # shellcheck disable=SC2086
  for f in $EXTRA_FILES; do echo x > "$BAD/scripts/$f"; done
  rm "$BAD/scripts/org.sh"
  git -C "$BAD" init -q
  git -C "$BAD" -c user.email=t@t -c user.name=t add -A
  git -C "$BAD" -c user.email=t@t -c user.name=t commit -qm init
  bash "$VENDOR" --source "$BAD" --dest "$BADDEST" >/dev/null 2>&1
)
if ! missing_source_fails; then echo "PASS: missing source fails loud"; else echo "FAIL: missing source did not fail"; fail=1; fi
copied=$(find "$BADDEST" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "${copied:-0}" = "0" ]; then echo "PASS: no half-vendored dir (dest empty on failure)"; else echo "FAIL: $copied files copied before the abort (half-vendored)"; fail=1; fi

# --- Non-git source (full manifest, no .git): rejected before any copy ---
# The dirty guard's `git status --porcelain` is empty for a non-git dir, which
# used to read as "clean"; the run then died only at the stamp step, after
# overwriting the dest. Must fail closed — with and without --allow-dirty
# (the stamp needs a source HEAD either way).
NOGITDEST="$TMP/nogitdest"
NOGIT="$TMP/nogit"; mkdir -p "$NOGIT/scripts"
# shellcheck disable=SC2086
for f in $MANIFEST; do echo x > "$NOGIT/scripts/$f.sh"; done
# shellcheck disable=SC2086
for f in $EXTRA_FILES; do echo x > "$NOGIT/scripts/$f"; done
if bash "$VENDOR" --source "$NOGIT" --dest "$NOGITDEST" >/dev/null 2>&1; then
  echo "FAIL: non-git source was not rejected"; fail=1
else echo "PASS: non-git source rejected"; fi
if [ ! -d "$NOGITDEST" ]; then echo "PASS: non-git rejection left dest uncreated"; else echo "FAIL: non-git rejection still created dest"; fail=1; fi
if bash "$VENDOR" --source "$NOGIT" --dest "$NOGITDEST" --allow-dirty >/dev/null 2>&1; then
  echo "FAIL: non-git source accepted with --allow-dirty"; fail=1
else echo "PASS: non-git source rejected even with --allow-dirty"; fi

# --- Standalone --skills mode: each dir gets exactly its manifest set ---
# link-check.py is a link-health-scanner extra not already in the fake source.
echo "# py" > "$SRC/scripts/link-check.py"
git -C "$SRC" -c user.email=t@t -c user.name=t add -A
git -C "$SRC" -c user.email=t@t -c user.name=t commit -qm link-check
SK="$TMP/skills"
if ! bash "$VENDOR" --source "$SRC" --skills "$SK" >/dev/null 2>&1; then
  echo "FAIL: --skills vendor returned non-zero"; fail=1
fi
SKILL_LIB="program-lib core github-api fork org repoman-requirements"
check_skill_dir() { # <skill-dir> <file…>  (files are basenames incl. extension)
  local dir="$1"; shift
  local d="$SK/$dir/scripts" ok=1 f
  for f in $SKILL_LIB; do
    [ -f "$d/$f.sh" ] || { ok=0; echo "  missing $dir/$f.sh"; }
  done
  for f in "$@"; do
    [ -f "$d/$f" ] || { ok=0; echo "  missing $dir/$f"; }
  done
  [ -f "$d/_vendor.json" ] || { ok=0; echo "  missing $dir/_vendor.json"; }
  if [ "$ok" = 1 ]; then echo "PASS: $dir populated"; else echo "FAIL: $dir incomplete"; fail=1; fi
}
check_skill_dir link-health-scanner link-health-scanner.sh extract-broken-links.sh link-check.py
check_skill_dir link-health-fixer link-health-fixer.sh
check_skill_dir dep-bump-scanner dep-bump-scanner.sh
check_skill_dir dep-bump-fixer dep-bump-fixer.sh
# dep-bump-fixer must NOT co-locate dep-bump-scanner.sh (docs-only reference)
if [ -f "$SK/dep-bump-fixer/scripts/dep-bump-scanner.sh" ]; then
  echo "FAIL: dep-bump-fixer should not co-locate dep-bump-scanner.sh"; fail=1
else
  echo "PASS: dep-bump-fixer has no scanner co-location"
fi
# Per-dir stamp: source_sha == source HEAD, and files list is dir-specific.
sk_want=$(git -C "$SRC" rev-parse HEAD)
sk_got=$(jq -r '.source_sha' "$SK/dep-bump-scanner/scripts/_vendor.json" 2>/dev/null)
if [ "$sk_got" = "$sk_want" ]; then echo "PASS: per-dir stamp sha == source HEAD"; else echo "FAIL: per-dir stamp sha $sk_got != $sk_want"; fail=1; fi
# link-health-scanner stamp lists link-check.py; dep-bump-scanner stamp does not.
if jq -e '.files | index("link-check.py")' "$SK/link-health-scanner/scripts/_vendor.json" >/dev/null 2>&1 \
   && ! jq -e '.files | index("link-check.py")' "$SK/dep-bump-scanner/scripts/_vendor.json" >/dev/null 2>&1; then
  echo "PASS: per-dir files list is skill-specific"
else
  echo "FAIL: per-dir files list not skill-specific"; fail=1
fi
# Idempotency: rerun => same source_sha + same files list for a dir.
bash "$VENDOR" --source "$SRC" --skills "$SK" >/dev/null 2>&1
sk_got2=$(jq -r '.source_sha' "$SK/dep-bump-scanner/scripts/_vendor.json" 2>/dev/null)
if [ "$sk_got2" = "$sk_want" ]; then echo "PASS: --skills idempotent stamp sha"; else echo "FAIL: --skills idempotency $sk_got2 != $sk_want"; fail=1; fi

# --- --skills: a source missing for ONE skill fails loud, NO dir half-vendored ---
BAD2="$TMP/bad2"; mkdir -p "$BAD2/scripts"
# shellcheck disable=SC2086
for f in $MANIFEST; do echo "#!/usr/bin/env bash" > "$BAD2/scripts/$f.sh"; done
echo "# py" > "$BAD2/scripts/link-check.py"
rm "$BAD2/scripts/dep-bump-fixer.sh"   # one skill's own script missing
git -C "$BAD2" init -q
git -C "$BAD2" -c user.email=t@t -c user.name=t add -A
git -C "$BAD2" -c user.email=t@t -c user.name=t commit -qm init
SKBAD="$TMP/skbad"
if bash "$VENDOR" --source "$BAD2" --skills "$SKBAD" >/dev/null 2>&1; then
  echo "FAIL: missing skill source should fail loud"; fail=1
else
  echo "PASS: missing skill source fails loud"
fi
skcopied=$(find "$SKBAD" -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
if [ "${skcopied:-0}" = "0" ]; then echo "PASS: no skill dir half-vendored"; else echo "FAIL: $skcopied files copied before abort"; fail=1; fi

# --- --skills inherits the dirty-source and non-git guards (they run before the
# mode branch). Locks in that a future refactor moving a guard into --dest only
# cannot silently expose --skills to a dirty/non-git source. ---
SKDIRTY="$TMP/skdirty"
echo x >> "$SRC/scripts/org.sh"   # dirty the (otherwise clean) source
if bash "$VENDOR" --source "$SRC" --skills "$SKDIRTY" >/dev/null 2>&1; then
  echo "FAIL: --skills dirty source was not rejected"; fail=1
else echo "PASS: --skills dirty source rejected"; fi
if [ ! -e "$SKDIRTY" ]; then echo "PASS: --skills dirty rejection wrote nothing"; else echo "FAIL: --skills dirty rejection wrote to dest"; fail=1; fi
git -C "$SRC" checkout -- scripts/org.sh   # restore
SKNOGITDEST="$TMP/sknogitdest"
if bash "$VENDOR" --source "$NOGIT" --skills "$SKNOGITDEST" >/dev/null 2>&1; then
  echo "FAIL: --skills non-git source was not rejected"; fail=1
else echo "PASS: --skills non-git source rejected"; fi
if [ ! -e "$SKNOGITDEST" ]; then echo "PASS: --skills non-git rejection wrote nothing"; else echo "FAIL: --skills non-git rejection wrote to dest"; fail=1; fi

# --- Mode exclusivity: --dest and --skills together is a usage error ---
# Must be rejected specifically for being mutually exclusive, not for --skills
# being an unknown flag (which is the pre-feature behavior).
excl_err=$(bash "$VENDOR" --source "$SRC" --dest "$DEST" --skills "$TMP/sk" 2>&1)
excl_rc=$?
if [ "$excl_rc" != "0" ] && printf '%s' "$excl_err" | grep -qi 'mutually exclusive'; then
  echo "PASS: --dest + --skills rejected as mutually exclusive"
else
  echo "FAIL: --dest + --skills not rejected for exclusivity (rc=$excl_rc, msg=$excl_err)"; fail=1
fi
# --- --skills alone is an accepted flag (not 'unknown arg') ---
sk_err=$(bash "$VENDOR" --source "$SRC" --skills "$TMP/skflag" 2>&1 || true)
if printf '%s' "$sk_err" | grep -qi 'unknown arg'; then
  echo "FAIL: --skills still treated as unknown arg: $sk_err"; fail=1
else
  echo "PASS: --skills is a recognized flag"
fi
# --- A value-taking flag with no value must fail, not hang (clawgenti #26) ---
if bash "$VENDOR" --source "$SRC" --skills >/dev/null 2>&1; then
  echo "FAIL: --skills with no value should be a usage error"; fail=1
else
  echo "PASS: --skills with no value is rejected (no hang)"
fi

[ "$fail" -eq 0 ] && echo "PASS" || { echo "FAILURES"; exit 1; }
