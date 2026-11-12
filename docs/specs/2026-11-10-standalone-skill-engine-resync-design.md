# Standalone-Skill Engine Resync Design

**Status:** approved (design settled 2026-11-10)
**Closes:** rossoctl/repoman#5
**Related:** [rossoctl/repoman#6](https://github.com/rossoctl/repoman/issues/6)
(dashboard-copy parity),
[rossoctl/automation#140](https://github.com/rossoctl/automation/issues/140)
(link-health-scanner rework — kept in mind, not designed around)

## Problem

The four standalone skill dirs — `skills/link-health-scanner/scripts/`,
`skills/link-health-fixer/scripts/`, `skills/dep-bump-scanner/scripts/`, and
`skills/dep-bump-fixer/scripts/` — each bundle their own scanner/fixer plus a
**662-line monolithic `program-lib.sh`** last meaningfully updated Jun 2026. The current engine in `rossoctl/automation` replaced that
monolith with a 20-line aggregator `program-lib.sh` that sources five refactored
modules (`core.sh`, `github-api.sh`, `fork.sh`, `org.sh`,
`repoman-requirements.sh`), and the standalone scanners/fixers themselves have
diverged from the canonical engine copies.

`scripts/vendor-engine.sh` already vendors the engine into the **repoman plugin**
dir (`skills/repoman/scripts/`), but it is deliberately scoped to that one flat
dir with a hard guard that it "must never touch a standalone skill's scripts/"
([agent-skills#51](https://github.com/rossoctl/agent-skills/issues/51)). Nothing
resyncs the four standalone dirs, so they drift.

Because the repoman-native skills have been
[removed](https://github.com/rossoctl/agent-skills/pull/56) from
`rossoctl/agent-skills`, `rossoctl/repoman` is now the single source of these skills — so this resync,
including the SKILL.md prose, lands entirely here with no cross-repo coordination.

## Why a full-dir replacement is safe (verified)

Investigated against automation
[`c138e5f`](https://github.com/rossoctl/automation/commit/c138e5f7a4fea6b8ba6bbb84558374f81cc6915f)
and the repoman standalone dirs:

- **Sourcing is identical.** Both the standalone and canonical scripts begin with
  `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"` then
  `source "$SCRIPT_DIR/program-lib.sh"`. The modular aggregator drops in unchanged.
- **The modular set is a superset.** The modular lib defines 29 functions; the old
  monolith defined 15, all of which exist in the modular set. Replacing the lib can
  only add capability, never remove a function a standalone script relied on.
- **Every lib function the canonical scanners/fixers call is present** in the
  modular set, including `fixer_comment_count` (added to the engine in
  rossoctl/automation#136). So the canonical scanner/fixer + the 6-file modular lib
  set run as-is in a standalone dir.
- **No standalone-specific behavior to preserve.** The standalone skills already use
  the enrolled-set / `~/.repoman/` model (`repoman_load_enrolled`, `repoman_config`);
  the dirs are stale snapshots, not an alternate design.

## Design

### Extend `vendor-engine.sh` with a standalone-skill mode

`vendor-engine.sh` gains a second mode selected by flag. Existing plugin behavior is
unchanged (back-compatible).

```
vendor-engine.sh --source <automation> --dest   <repoman-plugin-scripts>   # existing
vendor-engine.sh --source <automation> --skills <repoman-skills-dir>        # new
```

- `--skills <dir>` resyncs all four standalone skill dirs under `<dir>`.
- `--dest` and `--skills` are **mutually exclusive**; at least one is required.
  Passing both is a usage error (exit 2).

### Per-skill manifest (explicit, never a glob)

The [agent-skills#51](https://github.com/rossoctl/agent-skills/issues/51) guard —
"never touch a standalone skill's scripts/" — is
consciously relaxed into an explicit per-skill manifest. The intent of the guard
(no accidental writes, no globbing) is preserved: the mode can only ever write the
dirs and files named below.

Every skill receives the **6-file modular lib set**: `program-lib.sh`, `core.sh`,
`github-api.sh`, `fork.sh`, `org.sh`, `repoman-requirements.sh`.

| skill dir           | lib set | own script              | extra co-located files                    |
|---------------------|---------|-------------------------|-------------------------------------------|
| link-health-scanner | yes     | link-health-scanner.sh  | extract-broken-links.sh, link-check.py    |
| link-health-fixer   | yes     | link-health-fixer.sh    | —                                         |
| dep-bump-scanner    | yes     | dep-bump-scanner.sh     | —                                         |
| dep-bump-fixer      | yes     | dep-bump-fixer.sh       | —                                         |

The extras come from the `$SCRIPT_DIR/<dep>` references the canonical scripts make:
only `link-health-scanner` references co-located non-lib files. `dep-bump-fixer`'s
SKILL.md mentions `dep-bump-scanner.sh` only as a docs usage example, not a runtime
dependency, so it is **not** co-located into the fixer dir.

### Data flow

1. Parse mode and validate flag exclusivity.
2. Expand the per-skill manifest into the full set of source paths under
   `$SRC/scripts/`.
3. **Pre-validate the entire union before copying anything** (reuse the existing
   whole-manifest pre-check), so a source missing for any skill fails loud and
   leaves no dir half-resynced.
4. For each skill dir: `mkdir -p`, copy its file set, write its `_vendor.json`.
5. Echo a per-skill summary.

### Provenance stamp and idempotency contract

Each resynced dir gets its own `_vendor.json`, mirroring the plugin stamp
(`source_repo`, `source_sha` = automation HEAD, `vendored_at`, `files`).

The tested idempotency contract: **same source → byte-identical copied scripts, the
same `source_sha`, and the same per-dir `files` list.** `vendored_at` carries a
wall-clock timestamp and may differ across runs and across dirs; it is intentionally
not part of the determinism guarantee. This matches the existing plugin-mode test,
which asserts `source_sha` stability on rerun rather than whole-file equality. The
stamp format is unchanged.

### SKILL.md invocation fix (all four standalone skills)

All four standalone SKILL.md files document a removed invocation model: the `--org`
flag (dropped from the engine) and a manual "clone every org repo into `REPOS_DIR`"
story. The current engine:

- no longer accepts `--org` (scanners take `--dry-run` and `--issue-limit` only);
- reads the repos directory from `~/.repoman/config.json:repos_dir` (set via
  `repoman-setup.sh init-config --repos-dir <path> --fork-owner <owner>`, both flags
  required; `--repos-dir` must already exist — `init-config` does not create it).
  `repoman_config` loads that key and
  **overwrites any `REPOS_DIR` in the environment**, so an environment-only
  `export REPOS_DIR=` is inert; a missing `config.json` fails loud with
  `ERROR: RepoMan config not found`; and
- resolves **which** repos to act on from the enrolled set in
  `~/.repoman/repos.json` (via `repoman_load_enrolled` / `repoman_get_repos`), which
  **fails loud** when that file is missing or empty.

Fix across all four:

- Replace `--org <org>` examples with the current invocation: the repos dir comes
  from `~/.repoman/config.json:repos_dir` (not an `export REPOS_DIR=`), clones live
  at `<repos_dir>/<owner>/<name>`, and the enrolled set drives which repos run.
- Add a short prerequisites note: the skill reads the enrolled set from
  `~/.repoman/repos.json` (set up via `/repoman` setup or `repoman-setup.sh`) and
  fails loud if it is absent — so an agent running the skill standalone can detect
  missing setup and flag it to the user rather than misread the error.

`github-pr-review` is **not** affected: its SKILL.md uses `OWNER`/`REPO` + `gh`
directly and references none of `--org`, `REPOS_DIR`, or the enrolled set.

## Out of scope

- The repoman plugin dir (`skills/repoman/scripts/`) — covered by the existing
  plugin mode; it may be re-vendored separately to pick up automation `c138e5f`, but
  that is not this change.
- [rossoctl/automation#140](https://github.com/rossoctl/automation/issues/140)'s
  link-health-scanner rework. This resync copies whatever
  automation currently has; when #140 lands, a re-run of `--skills` resyncs it with
  no special-casing here.

## Deliverables

1. `scripts/vendor-engine.sh`: add `--skills` mode with the per-skill manifest, flag
   exclusivity, whole-union pre-validate, per-dir copy + `_vendor.json`.
2. `tests/test-vendor-engine.sh`: extend (do not fork) with standalone-mode cases.
3. The four standalone skill dirs: resynced content matching automation `c138e5f`
   (the modular lib set + canonical scanner/fixer + link-health-scanner extras).
4. The four standalone SKILL.md files: invocation fix + `~/.repoman/` prerequisites
   note.

## Testing

Extend `tests/test-vendor-engine.sh` alongside the existing plugin cases:

- each of the four dirs is populated with exactly its manifest file set (per-dir
  counts);
- `link-health-scanner` receives `link-check.py` and `extract-broken-links.sh`;
- each per-dir `_vendor.json` has `source_sha` == source HEAD and the correct `files`
  list; a rerun from the same source yields the same `source_sha` + `files` and
  byte-identical copied scripts (`vendored_at` free to vary);
- a missing source fails loud and leaves **no** dir half-vendored;
- `--dest` and `--skills` together is a usage error.

**Dogfood:** run the extended `--skills` mode against the real automation checkout
(`c138e5f`), then assert each resynced scanner/fixer sources its lib and runs a
`--help`/dry invocation, and is shellcheck-clean — proving the modular set resolves
in the standalone dir.

## Acceptance criteria

- [ ] `vendor-engine.sh --skills <dir>` populates all four standalone dirs with their
      manifest set; `--dest` plugin mode unchanged.
- [ ] `--dest` + `--skills` together exits non-zero with a usage error.
- [ ] A source missing for any skill fails loud with no dir half-vendored.
- [ ] Per-dir `_vendor.json` records the automation HEAD sha; rerun is content-stable
      (`source_sha` + `files`).
- [ ] Each resynced scanner/fixer sources the modular lib and runs; shellcheck clean.
- [ ] All four standalone SKILL.md files use the current invocation and carry the
      `~/.repoman/` prerequisites note; `github-pr-review` untouched.
- [ ] Extended `tests/test-vendor-engine.sh` green.
