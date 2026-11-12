#!/usr/bin/env bash
# Aggregator for the automation library modules. Kept as the stable entrypoint
# so program scripts can `source "$SCRIPT_DIR/program-lib.sh"` unchanged.
#
# Source this file at the top of program scripts:
#   SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   source "$SCRIPT_DIR/program-lib.sh"
#
# Prerequisites: jq, gh (GitHub CLI), coreutils (comm, sort, wc, mktemp)
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$_LIB_DIR/core.sh"
# shellcheck source=/dev/null
. "$_LIB_DIR/github-api.sh"
# shellcheck source=/dev/null
. "$_LIB_DIR/fork.sh"
# shellcheck source=/dev/null
. "$_LIB_DIR/org.sh"
# shellcheck source=/dev/null
. "$_LIB_DIR/repoman-requirements.sh"
