#!/usr/bin/env bash
set -euo pipefail

# extract-broken-links.sh — Turn lychee JSON output into broken-link records.
#
# Reads a lychee --format json report and emits one JSON object per broken
# link (JSONL, one record per line). URLs pointing at unreachable-by-design
# hostnames (Kubernetes cluster-local .svc names, *.local, RFC1918 ranges) are
# suppressed, since an external scanner can never reach them. lychee status is
# normalized to enum tokens: numeric HTTP codes stay as-is; text statuses map
# to timeout / dns / unreachable / unchecked / error / unknown.
#
# This logic was previously inline in link-health-scanner.sh; it is extracted
# here so it can be unit-tested against synthetic lychee fixtures.
#
# Usage:
#   extract-broken-links.sh <lychee-json> <repo> <repos-prefix>
#   cat report.json | extract-broken-links.sh - <repo> <repos-prefix>
#
# Arguments:
#   <lychee-json>   Path to a lychee JSON report, or - to read from stdin.
#   <repo>          Full "owner/name" repo reference (e.g. "rossoctl/cortex");
#                   emitted verbatim in the "repo" field.
#   <repos-prefix>  Absolute path prefix stripped from lychee's file keys
#                   (e.g. "/home/claw/kagenti/rossoctl/").
#
# Output (stdout): JSONL, zero or more objects of the form
#   {"repo":"rossoctl/foo","file":"docs/x.md","url":"https://...","status":"404","category":"external"}
#
# Exit codes:
#   0 - success (may emit zero records)
#   1 - usage error (missing arguments or file not found)

# --- Argument handling ---
if [ $# -lt 3 ]; then
  echo "Usage: extract-broken-links.sh <lychee-json> <repo-name> <repos-prefix>" >&2
  echo "       cat report.json | extract-broken-links.sh - <repo-name> <repos-prefix>" >&2
  exit 1
fi

LYCHEE_INPUT="$1"
REPO_FULL="$2"   # full "owner/name" reference, emitted verbatim
REPOS_PREFIX="$3"

if [ "$LYCHEE_INPUT" != "-" ] && [ ! -f "$LYCHEE_INPUT" ]; then
  echo "ERROR: File not found: $LYCHEE_INPUT" >&2
  exit 1
fi

# Empty input produces no records.
if [ "$LYCHEE_INPUT" != "-" ] && [ ! -s "$LYCHEE_INPUT" ]; then
  exit 0
fi

# --- Extract broken links from error_map (skip non-URL entries like "Error building URL") ---
# Normalize lychee/link-check status to enum tokens: numeric codes stay as-is,
# text statuses map to: timeout, dns, unreachable, unchecked, error, unknown.
# Suppress URLs with unreachable-by-design hostnames (cluster-local, .local, RFC1918).
# "unchecked" (egress-proxy refusal) must match before the error catch-all so
# the scanner can keep those out of the issue open/close path.
jq -r --arg repo "$REPO_FULL" --arg repos_dir "$REPOS_PREFIX" '
  .error_map // {} | to_entries[] |
  .key as $filepath |
  .value[] |
  select(.url | test("^https?://")) |
  # Suppress unreachable-by-design hostnames at URL level.
  # Bare .svc covers both plain cluster-local service names (foo.ns.svc) and
  # the fully-qualified foo.ns.svc.cluster.local form.
  select(.url | test("://[^/]*\\.svc([:/]|$)") | not) |
  select(.url | test("://[^/]*\\.svc\\.cluster\\.local([:/]|$)") | not) |
  select(.url | test("://[^/]*\\.local([:/]|$)") | not) |
  select(.url | test("://(10\\.[0-9]|172\\.(1[6-9]|2[0-9]|3[01])\\.[0-9]|192\\.168\\.[0-9])[0-9.]*([:/]|$)") | not) |
  (.status.code // .status.text // null) as $raw_status |
  (
    if $raw_status == null then "unknown"
    elif ($raw_status | type) == "number" then ($raw_status | tostring)
    elif ($raw_status | test("^[0-9]{3}$")) then $raw_status
    elif ($raw_status | ascii_downcase) == "unchecked" then "unchecked"
    elif ($raw_status | ascii_downcase | test("timeout")) then "timeout"
    elif ($raw_status | ascii_downcase | test("resolve|dns")) then "dns"
    elif ($raw_status | ascii_downcase | test("refused|reset|closed|unreachable|connect")) then "unreachable"
    else "error"
    end
  ) as $status |
  {
    repo: $repo,
    file: ($filepath | ltrimstr($repos_dir) | ltrimstr("./")),
    url: .url,
    status: $status,
    category: (
      # internal = a link back into the scanned owner (derived from $repo,
      # owner/name), so it follows the enrolled owner, not a hardcoded org list.
      if (.url | test("github\\.com/" + ($repo | split("/")[0]) + "/")) then "internal"
      else "external"
      end
    )
  }
' "${LYCHEE_INPUT/#-//dev/stdin}"
