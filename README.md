# RepoMan

RepoMan runs automated maintenance **programs** (PR review, link health, dependency
bumps, weekly reports, repo sync, doc drift) across a set of GitHub repos you enroll once. It
handles the capability checks and output wiring for you, so you install once and
enable programs on the fly.

`/repoman` is a single intent-dispatching entrypoint: it reads your `~/.repoman/`
state and your message and infers whether you are setting up, enabling a program, or
running one.

Built to the [Agent Skills specification](https://agentskills.io/specification).

## Installation

### Claude Code (plugin marketplace)

```
/plugin marketplace add rossoctl/repoman
/plugin install repoman@rossoctl-repoman
```

That one install is the whole system — the `repoman` plugin is **self-contained**: it
bundles the `/repoman` entrypoint, every program skill (scanner and fixer), and the
engine scripts. Enabling more programs later needs no further installs.

### Updating

Refresh the marketplace and update the plugin (a Claude Code restart applies updates):

```
/plugin marketplace update rossoctl-repoman
/plugin update repoman@rossoctl-repoman
```

Updating `repoman` refreshes the bundled engine too, so engine fixes reach every user
through a single plugin update.

## Programs

The `repoman` bundle ships these programs, each ready to enable:

| Program | What it does |
|---------|--------------|
| [repoman](skills/repoman/) | The entrypoint: first-time setup, enabling a program, enrolling repos or an org, running a program across enrolled repos |
| [link-health](skills/link-health-scanner/) | Scan repos for broken links and file issues ([fixer](skills/link-health-fixer/) re-verifies and opens fix PRs) |
| [dep-bump](skills/dep-bump-scanner/) | Monitor Dependabot PRs, classify by severity, flag SLA breaches ([fixer](skills/dep-bump-fixer/) posts commentary to accelerate review) |
| [pr-review](skills/github-pr-review/) | Automated PR review: conventions, security, CI status, inline comments |
| [repo-sync](skills/repo-sync/) | Keep local clones of enrolled repos current; read-only toward GitHub |
| [automation-health](skills/automation-health-dashboard/) | Generate an executive-facing dashboard combining all program metrics |
| [weekly-report](skills/github-weekly-report/) | Weekly org activity reports with merged PRs, CI health, and active-epic tracking |
| [doc-drift](skills/doc-drift-scanner/) | Scan repos for documentation drift and draft changelog notes from merged PRs ([fixer](skills/doc-drift-fixer/) re-verifies and opens mechanical doc fix PRs) |

Each program is also published as its own standalone plugin, for using one on its own
(for example a one-off PR review) without the full RepoMan setup. Run `/plugin` after
adding the marketplace to browse the authoritative list.

## Prerequisites

- `bash` 3.2+ — runs on the macOS system default; no bash-4 features are used.
- `gh` (GitHub CLI, authenticated with org access)
- `jq`

Individual programs may have additional requirements documented in their `SKILL.md`.

## Development

RepoMan is developed across three repositories:

| Repository | Role |
|------------|------|
| [rossoctl/automation](https://github.com/rossoctl/automation) | Engine source of truth: the flat scripts in `scripts/`, plus tests and specs. All engine changes are made and tested there first. |
| [rossoctl/agent-skills](https://github.com/rossoctl/agent-skills) | Skills designed to work standalone as well as with RepoMan. |
| [rossoctl/repoman](https://github.com/rossoctl/repoman) (this repo) | Distribution (`rossoctl-repoman` marketplace) and the canonical home for RepoMan-specific `SKILL.md`s. The engine is not authored here. |

See the `[CHANGELOG.md](https://github.com/rossoctl/repoman/blob/main/CHANGELOG.md)` for release history.

### Contributor workflow

1. **Place the work.** A skill that is useful on its own → author it in
   agent-skills. A RepoMan-specific program (keeps state under `~/.repoman`) →
   deterministic scripts in automation, `SKILL.md` in this repo. New programs
   start from automation's `docs/program-template.md`. A new program also
   needs repoman-side wiring that is not engine code: a
   `.claude-plugin/marketplace.json` entry, a row in the README
   `## Programs` table, and the program → skill mapping in
   `skills/repoman/SKILL.md`.
2. **Test in automation**, next to the existing tests in `tests/`. Bash 3.2
   only: no `mapfile`, no associative arrays, BSD fallbacks for GNU-only
   flags. If the skill writes to `~/.repoman`, give its `SKILL.md` a
   machine-readable `### Requirements` block so `repoman-check.sh` can gate
   the run.
3. **Keep real state out of test runs.** Point `REPOMAN_CONFIG_FILE` /
   `REPOMAN_REPOS_FILE` at scratch files; never hand-edit `~/.repoman`
   (`repoman-setup.sh` is its only writer); drive first runs through
   `repoman-run.sh <program> owner/repo --dry-run` and drop `--dry-run` only
   once the output looks right.
4. **Vendor the engine** into this repo (below) — a new engine script must be
   added to both the vendor manifest and its test fixture in
   `tests/test-vendor-engine.sh`, including the expected counts — then run
   that test. To try the plugin without reinstalling from the marketplace:
   `claude plugin marketplace add <this-repo>` then
   `claude plugin install repoman@rossoctl-repoman`.
5. **Before the PR**: `git config core.hooksPath scripts/hooks`, sign off
   with `git commit -s` (DCO), use a conventional title, one purpose per PR.

### Vendoring the engine

Both `skills/repoman/scripts/` (the plugin bundle) and the standalone
`skills/{link-health,dep-bump}-{scanner,fixer}/scripts/` dirs are **generated
output** — vendored copies of the automation engine, each stamped with its
source commit in a `_vendor.json`. Never edit those files directly: an in-place
fix bypasses automation's tests and is silently overwritten on the next vendor.
To pick up engine changes, run the vendor script from this repo against a
**clean automation checkout** — the stamp records the source HEAD SHA, so
vendoring uncommitted changes would produce a stamp that does not match the
copied bytes (the script rejects a dirty source unless `--allow-dirty` is
passed):

```bash
# The plugin bundle:
scripts/vendor-engine.sh --source <path-to-automation-checkout> \
  --dest skills/repoman/scripts

# The standalone skill dirs:
scripts/vendor-engine.sh --source <path-to-automation-checkout> \
  --skills skills
```

The two modes are mutually exclusive. Each copies an explicit manifest (never a
glob): `--dest` populates only the plugin dir, and `--skills` populates only the
listed standalone skill dirs with the modular lib set plus each skill's own
scripts — so the script only ever writes the paths its manifests name. Both
pre-validate the whole source set before copying anything and rewrite each
`_vendor.json` with the automation HEAD SHA vendored from.
`tests/test-vendor-engine.sh` is the regression test for both modes.

## License

Apache-2.0. See [LICENSE](LICENSE).
