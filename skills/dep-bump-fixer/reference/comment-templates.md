# Comment Templates -- Dep Bump Fixer

## Fixer Signature

All comments end with this signature (used for duplicate detection):

```
_Automated analysis by Kagenti Dep Bump Fixer (scan <scan_id>)_
```

## Security Escalation (critical/high)

```markdown
## Security Bump Escalation

**Package:** <package> (<from> -> <to>)
**Severity:** <tier> | **SLA:** <N> days | **Overdue:** <M> days
**CI Status:** <passing|failing|pending|unknown>

### Advisory Context
Vulnerability references: <CVE-XXXX-XXXXX, GHSA-xxxx-xxxx-xxxx>

<Release notes / changelog excerpt>

### Action Required
This PR has exceeded the <N>-day SLA for <tier>-severity patches. Please review and merge, or document a deferral reason.

---
_Automated analysis by Kagenti Dep Bump Fixer (scan <scan_id>)_
```

## Routine Analysis (minor/patch)

```markdown
## Dependency Update Analysis

**Package:** <package> (<from> -> <to>)
**Ecosystem:** <ecosystem> | **Age:** <M> days (SLA: <N> days)
**CI Status:** <passing|failing|pending|unknown>

### Changelog Summary
<Release notes excerpt from PR body>

### Risk Assessment
- Breaking changes: <None detected | description>
- Recommendation: <Safe to merge | Review needed>

---
_Automated analysis by Kagenti Dep Bump Fixer (scan <scan_id>)_
```

## Major Version Bump

```markdown
## Major Version Bump Analysis

**Package:** <package> (<from> -> <to>)
**Ecosystem:** <ecosystem> | **Age:** <M> days

### Migration Notes
<Breaking changes excerpt from PR body>

### Recommendation
Major version bumps require manual review. Consider:
- Bundling with related dependency updates
- Scheduling migration work if breaking changes affect multiple files
- Deferring with documented justification if migration is non-trivial

---
_Automated analysis by Kagenti Dep Bump Fixer (scan <scan_id>)_
```

## Issue Comment (posted on scanner-created issue after PR comment)

```markdown
Analysis posted on PR #<number>. Awaiting human action.

_Automated analysis by Kagenti Dep Bump Fixer (scan <scan_id>)_
```

## Field Extraction (from scanner issue body)

```bash
pr_number=$(echo "$body" | sed -nE 's/^\*\*PR:\*\*[[:space:]]*#([0-9]+)/\1/p' | head -1)
package=$(echo "$body" | sed -nE 's/^\*\*Package:\*\*[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
severity=$(echo "$body" | sed -nE 's/^\*\*Severity:\*\*[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
sla_days=$(echo "$body" | sed -nE 's/^\*\*SLA:\*\*[[:space:]]*([0-9]+).*/\1/p' | head -1)
age_days=$(echo "$body" | sed -nE 's/^\*\*Age:\*\*[[:space:]]*([0-9]+).*/\1/p' | head -1)
ecosystem=$(echo "$body" | sed -nE 's/^\*\*Ecosystem:\*\*[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
category=$(echo "$body" | sed -nE 's/^Category:[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
version_str=$(echo "$body" | sed -nE 's/^\*\*Version:\*\*[[:space:]]*(.*)/\1/p' | head -1 | sed 's/[[:space:]]*$//')
```
