#!/usr/bin/env bash
# Test-driven agent loop helper: stop the agent from "fixing" tests by editing them.
#   lock-tests.sh lock   [tests_dir]            -> chmod a-w (soft lock)
#   lock-tests.sh unlock [tests_dir]
#   lock-tests.sh verify <base_ref> [tests_dir] -> exit 1 if tests changed vs base_ref (hard check, use in CI)
# NOTE: chmod is advisory (an agent running as your user can undo it). Use `verify` in CI as the real gate.
set -euo pipefail
mode="${1:-}"
case "$mode" in
  lock)   chmod -R a-w "${2:-tests}"; echo "locked ${2:-tests}";;
  unlock) chmod -R u+w "${2:-tests}"; echo "unlocked ${2:-tests}";;
  verify)
    base="${2:?base ref required}"; dir="${3:-tests}"
    if git diff --quiet "$base" -- "$dir"; then echo "tests untouched"
    else echo "tests were modified:"; git diff --stat "$base" -- "$dir"; exit 1; fi;;
  *) sed -n '2,7p' "$0"; exit 1;;
esac
