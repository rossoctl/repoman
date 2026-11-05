# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.1.1] - 2026-11-04

### Added

- **doc-drift program.** The scanner and fixer compare documentation to the code at a pinned git ref (paths, flags, enumerations, retired names, versions, and absence claims) and draft Keep a Changelog notes from merged pull requests. It ships inside the `repoman` plugin and as its own marketplace plugin.
- **Shellcheck** for the vendor tooling (`scripts/vendor-engine.sh` and `tests/test-vendor-engine.sh`).

### Changed

- Marketplace version is `0.1.1`. The `v0.1.1` tag is cut from `main` after this release merges.
- Bundled engine is vendored from `rossoctl/automation` `fa619090`, including the pinned-SHA footer for PR review and the weekly report.

## [0.1.0] - 2026-10-27

First tagged release of RepoMan, distributed through the `rossoctl-repoman`
marketplace.

RepoMan runs automated maintenance **programs** across a set of GitHub repos you
enroll once, handling the capability checks and output wiring for you. `/repoman` is
a single intent-dispatching entrypoint that infers whether you are setting up,
enabling a program, or running one.

### Added

- **Self-contained `repoman` plugin.** One install bundles the `/repoman` entrypoint,
  every program skill, and the engine scripts, so you install once and enable more
  programs on the fly. The engine is vendored into the plugin and resolved at runtime
  via `${CLAUDE_PLUGIN_ROOT}` — no separate automation checkout is required.
- **Six programs** ship ready to enable: `link-health` (scanner + fixer),
  `dep-bump` (scanner + fixer), `pr-review`, `repo-sync`, `automation-health`, and
  `weekly-report`.
- **Standalone program plugins** remain installable on their own, for using a single
  program (for example a one-off PR review) without the full RepoMan bundle.
- **Provenance stamp** (`_vendor.json`) records the exact `rossoctl/automation` commit
  the bundled engine was vendored from, so a shipped bundle is traceable to its source.

### Changed

- `marketplace.json` version reconciled to `0.1.0`.
- All skills now declare `bash` 3.2+ and run on the macOS system default.

### Notes

- Engine development lives in `rossoctl/automation`; engine fixes reach every RepoMan
  user through a single `repoman` plugin update.

### Contributors

Gloire Rubambiza, Aleksander Slominski, Mariusz Sabath, Jim Cadden.

[0.1.1]: https://github.com/rossoctl/repoman/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/rossoctl/repoman/releases/tag/v0.1.0
