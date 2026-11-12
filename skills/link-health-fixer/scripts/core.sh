#!/usr/bin/env bash
# Core utilities for the automation programs: workspace/temp management, portable
# date math, JSON-schema validation, scan diffing, and report file I/O.
#
# ## Portability
# Targets bash 3.2+ (macOS default) through modern bash. No associative arrays,
# no mapfile/readarray, no GNU-only sed/grep/date flags without a BSD fallback.
#
# Load-once guard: safe to source multiple times (self-sourcing modules may pull
# this in more than once).
[ -n "${_CORE_SH_LOADED:-}" ] && return
_CORE_SH_LOADED=1

# =============================================================================
# WORKSPACE MANAGEMENT
# =============================================================================

# Create a temp directory and register automatic cleanup on script exit.
# After calling this, use $PROGRAM_TMPDIR for all temp files.
#
# Usage: setup_workspace "link-fixer"
# Args:
#   $1 - prefix for the temp directory name (default: "program")
setup_workspace() {
  local prefix="${1:-program}"

  PROGRAM_TMPDIR=$(mktemp -d "/tmp/${prefix}-XXXXXX")
  # Automatic cleanup: remove the temp dir when the script exits
  trap 'rm -rf "$PROGRAM_TMPDIR"' EXIT
}

# Generate a unique scan ID for today in the format YYYY-MM-DD-NNN.
# The sequence number (NNN) increments based on how many scans already
# ran today (read from history.json). This prevents ID collisions when
# a scanner is triggered multiple times in one day.
#
# Usage: SCAN_ID=$(generate_scan_id "$REPORTS_DIR" "2026-05-21")
# Args:
#   $1 - path to the reports directory (must contain history.json)
#   $2 - today's date in YYYY-MM-DD format
# Prints: the scan ID (e.g., "2026-05-21-002")
generate_scan_id() {
  local reports_dir="$1"
  local scan_date="$2"
  local last_seq=0

  # Count how many scans already happened today
  if [ -f "$reports_dir/history.json" ]; then
    last_seq=$(jq -r \
      --arg date "$scan_date" \
      '[.[] | select(.scan_id | startswith($date))] | length' \
      "$reports_dir/history.json")
  fi

  # Zero-padded sequence number
  printf "%s-%03d" "$scan_date" $((last_seq + 1))
}

# =============================================================================
# PORTABLE DATE UTILITIES
# =============================================================================

# Convert an ISO 8601 timestamp (YYYY-MM-DDTHH:MM:SSZ) to Unix epoch seconds.
# Works on both macOS (BSD date) and Linux (GNU date), with a pure-awk fallback
# that requires no external language runtime. Returns 0 on parse failure.
#
# Usage: epoch=$(iso_to_epoch "2026-06-12T14:00:00Z")
# Args:
#   $1 - ISO 8601 timestamp string (must end in Z for UTC)
# Prints: Unix epoch seconds (integer)
iso_to_epoch() {
  local timestamp="$1"

  if [ -z "$timestamp" ]; then
    echo "0"
    return
  fi

  # Try GNU date first (Linux)
  local epoch
  epoch=$(date -d "$timestamp" +%s 2>/dev/null) && { echo "$epoch"; return; }

  # Try BSD date (macOS) — TZ=UTC ensures the Z suffix is honored
  epoch=$(TZ=UTC date -j -f "%Y-%m-%dT%H:%M:%SZ" "$timestamp" +%s 2>/dev/null) && { echo "$epoch"; return; }

  # Fallback: pure awk (no external dependencies beyond POSIX)
  # Parses YYYY-MM-DDTHH:MM:SSZ and computes epoch via day-counting arithmetic.
  epoch=$(echo "$timestamp" | awk -F'[-T:Z]' '{
    if (NF < 6) { print 0; exit }
    y = $1 + 0; m = $2 + 0; d = $3 + 0
    H = $4 + 0; M = $5 + 0; S = $6 + 0

    # Days in each month (non-leap)
    split("31,28,31,30,31,30,31,31,30,31,30,31", mdays, ",")

    # Count days from 1970-01-01
    days = 0
    for (yr = 1970; yr < y; yr++) {
      days += 365
      if (yr % 4 == 0 && (yr % 100 != 0 || yr % 400 == 0)) days++
    }
    for (mo = 1; mo < m; mo++) {
      days += mdays[mo] + 0
      if (mo == 2 && y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) days++
    }
    days += d - 1

    print (days * 86400) + (H * 3600) + (M * 60) + S
  }' 2>/dev/null) && { echo "$epoch"; return; }

  echo "0"
}

# Write a file atomically using a temp file and mv.
# Unlike write_report_latest, this takes a source file path (not content string),
# avoiding argument-length limits for large files.
#
# Usage: atomic_write_file "$TMPDIR/state.json" "$REPORTS_DIR/state.json"
# Args:
#   $1 - source file path (contents to write)
#   $2 - destination file path
atomic_write_file() {
  local src="$1"
  local dst="$2"
  local tmp="${dst}.tmp.$$"

  cp "$src" "$tmp"
  mv "$tmp" "$dst"
}

# =============================================================================
# JSON SCHEMA VALIDATION
# =============================================================================

# Validate that a JSON file matches an expected structure.
# Uses jq to check that required top-level keys exist and are arrays.
# On failure, prints a warning and resets the file to the provided default.
#
# Usage:
#   validate_json_schema "$STATE_FILE" \
#     '(.in_progress | type) == "array" and (.reviewed | type) == "array"' \
#     '{"in_progress": [], "reviewed": []}'
#
# Args:
#   $1 - path to the JSON file
#   $2 - jq boolean expression that must return true for valid files
#   $3 - default JSON content to write if validation fails
# Returns: 0 if valid (or reset succeeded), 1 if file cannot be written
validate_json_schema() {
  local file="$1"
  local check_expr="$2"
  local default_content="$3"

  # File does not exist: write default
  if [ ! -f "$file" ]; then
    printf '%s\n' "$default_content" > "$file"
    return 0
  fi

  # File is not valid JSON: reset
  if ! jq empty "$file" 2>/dev/null; then
    echo "WARN: $file is not valid JSON, resetting to default." >&2
    printf '%s\n' "$default_content" > "$file"
    return 0
  fi

  # File does not pass schema check: reset
  local valid
  valid=$(jq -r "$check_expr" "$file" 2>/dev/null || echo "false")
  if [ "$valid" != "true" ]; then
    echo "WARN: $file failed schema validation, resetting to default." >&2
    printf '%s\n' "$default_content" > "$file"
    return 0
  fi

  return 0
}

# =============================================================================
# DIFF LOGIC
# =============================================================================

# Compare current findings against a previous scan to determine what's new,
# what's fixed, and what's recurring. Uses set operations (comm) on sorted keys.
#
# After calling, three files are available in $PROGRAM_TMPDIR:
#   new_keys.txt       - items in current but not previous (just appeared)
#   fixed_keys.txt     - items in previous but not current (resolved)
#   recurring_keys.txt - items in both (still broken)
#
# Usage:
#   read -r new fixed recurring < <(diff_against_previous \
#     "$TMPDIR/current.jsonl" "$TMPDIR/prev.jsonl" '[.repo, .file, .url] | join("|")')
#
# Args:
#   $1 - path to current findings file (JSONL, one JSON object per line)
#   $2 - path to previous findings file (JSONL)
#   $3 - jq expression that extracts the comparison key from each object
#         (must produce a single string per line)
# Prints: three space-separated counts: "NEW FIXED RECURRING"
diff_against_previous() {
  local current_file="$1"
  local prev_file="$2"
  local key_expr="$3"

  # Extract and sort keys from both files
  jq -r "$key_expr" "$current_file" | sort > "$PROGRAM_TMPDIR/current_keys.txt"
  jq -r "$key_expr" "$prev_file"    | sort > "$PROGRAM_TMPDIR/prev_keys.txt"

  # Set operations using comm:
  #   comm -23 = lines only in file 1 (new items)
  #   comm -13 = lines only in file 2 (fixed items)
  #   comm -12 = lines in both files (recurring)
  comm -23 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/new_keys.txt"

  comm -13 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/fixed_keys.txt"

  comm -12 "$PROGRAM_TMPDIR/current_keys.txt" "$PROGRAM_TMPDIR/prev_keys.txt" \
    > "$PROGRAM_TMPDIR/recurring_keys.txt"

  # Count each set
  local new_count
  local fixed_count
  local recurring_count
  new_count=$(wc -l < "$PROGRAM_TMPDIR/new_keys.txt" | tr -d ' ')
  fixed_count=$(wc -l < "$PROGRAM_TMPDIR/fixed_keys.txt" | tr -d ' ')
  recurring_count=$(wc -l < "$PROGRAM_TMPDIR/recurring_keys.txt" | tr -d ' ')

  echo "$new_count $fixed_count $recurring_count"
}

# =============================================================================
# REPORTS
# =============================================================================

# Overwrite latest.json with the provided JSON content.
# Creates the reports directory if it doesn't exist.
#
# Usage:
#   write_report_latest "$REPORTS_DIR" "$json_string"
#
# Args:
#   $1 - path to the reports directory
#   $2 - JSON content to write (as a string)
#   $3 - (optional) filename (default: "latest.json")
write_report_latest() {
  local reports_dir="$1"
  local content="$2"
  local filename="${3:-latest.json}"

  mkdir -p "$reports_dir"
  printf '%s\n' "$content" > "$reports_dir/$filename.tmp" && mv "$reports_dir/$filename.tmp" "$reports_dir/$filename"
}

# Append a row to history.json, keeping the file under a maximum row count.
# If history.json doesn't exist or is empty, initializes it as a JSON array.
# Oldest entries are trimmed when the cap is exceeded.
#
# Usage:
#   append_history_row "$REPORTS_DIR" "$history_row_json" 500
#   append_history_row "$REPORTS_DIR" "$row" 500 "fixer-history.json"
#
# Args:
#   $1 - path to the reports directory
#   $2 - JSON object to append (as a string, e.g., '{"scan_id":"...","date":"..."}')
#   $3 - maximum number of rows to keep (default: 500)
#   $4 - (optional) filename (default: "history.json")
append_history_row() {
  local reports_dir="$1"
  local row="$2"
  local max_rows="${3:-500}"
  local filename="${4:-history.json}"

  mkdir -p "$reports_dir"

  local history_file="$reports_dir/$filename"

  # If history file exists and is non-empty, append and trim
  if [ -f "$history_file" ] && [ -s "$history_file" ]; then
    local tmp_file="$PROGRAM_TMPDIR/history_new.json"

    jq \
      --argjson row "$row" \
      --argjson cap "$max_rows" \
      '. + [$row] | if length > $cap then .[-$cap:] else . end' \
      "$history_file" > "$tmp_file"

    mv "$tmp_file" "$history_file"
  else
    # Initialize as a single-element array
    echo "[$row]" > "$history_file"
  fi
}
