# Issue Body Format

The scanner creates GitHub issues with the following structured body. The fixer parses these fields to identify what to fix.

## Template

```markdown
## Describe the bug

Broken link detected by automated link health scan.

**Repo:** <org>/<repo>
**File:** <relative/path/to/file.md>
**Broken URL:** <https://example.com/broken>
**HTTP Status:** <404>
**First detected:** <YYYY-MM-DD>
**Scan ID:** <YYYY-MM-DD-NNN>

## Steps To Reproduce

1. Open https://github.com/<org>/<repo>/blob/main/<file>
2. Click or follow the link to `<url>`
3. Observe <status> error

## Expected Behavior

The link should resolve to valid documentation.

## Additional Context

Category: <internal|external>
Detected by: Link Health Scanner (scan <scan-id>)
```

## Field Descriptions

| Field | Format | Description |
|-------|--------|-------------|
| Repo | `org/repo` | The repository containing the broken link |
| File | relative path | Path to the file containing the link (from repo root) |
| Broken URL | `https://...` | The URL that returned an error |
| HTTP Status | numeric or text | HTTP status code (404, 403, etc.) or error type (timeout) |
| First detected | `YYYY-MM-DD` | Date of the scan that first found this broken link |
| Scan ID | `YYYY-MM-DD-NNN` | Unique identifier for the scan run |
| Category | `internal` or `external` | Whether the URL points to the same org or externally |

## Labels Applied

- `kind/bug` -- always
- `broken-link/internal` -- if URL points to the same GitHub org
- `broken-link/external` -- if URL points outside the org

## Issue Title Format

```
:bug: Broken link in <file>: <url>
```

Truncated to 250 characters if necessary.
