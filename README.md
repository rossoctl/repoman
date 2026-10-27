# RepoMan

RepoMan runs automated maintenance **programs** (PR review, link health, dependency
bumps, weekly reports, repo sync) across a set of GitHub repos you enroll once. It
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

Each program is also published as its own standalone plugin, for using one on its own
(for example a one-off PR review) without the full RepoMan setup. Run `/plugin` after
adding the marketplace to browse the authoritative list.

## Prerequisites

- `bash` 3.2+ — runs on the macOS system default; no bash-4 features are used.
- `gh` (GitHub CLI, authenticated with org access)
- `jq`

Individual programs may have additional requirements documented in their `SKILL.md`.

## How it is built

The engine scripts are vendored from [rossoctl/automation](https://github.com/rossoctl/automation)
(the development source of truth) into this distribution repo, with a provenance stamp
(`skills/repoman/scripts/_vendor.json`) recording the exact source commit. See the
`CHANGELOG.md` for release history.

## License

Apache-2.0. See [LICENSE](LICENSE).
