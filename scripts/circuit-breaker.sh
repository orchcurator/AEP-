#!/usr/bin/env bash
# Circuit breaker for agent fix loops.
# Runs an agent command repeatedly; if the failure count does not improve for
# N consecutive attempts, hard-resets to the starting commit and exits 2 (escalate).
#
# Usage:
#   circuit-breaker.sh --test "npm test" --agent "claude -p 'Fix the failing tests'" \
#                      [--max-attempts 5] [--patience 2] [--fail-pattern 'FAIL|FAILED|Error']
# Exit codes: 0 = tests pass, 2 = rolled back (escalate), 1 = usage/setup error
set -euo pipefail

TEST=""; AGENT=""; MAX=5; PATIENCE=2; PATTERN='FAIL|FAILED|Error'
while [[ $# -gt 0 ]]; do
  case "$1" in
    --test) TEST="$2"; shift 2;;
    --agent) AGENT="$2"; shift 2;;
    --max-attempts) MAX="$2"; shift 2;;
    --patience) PATIENCE="$2"; shift 2;;
    --fail-pattern) PATTERN="$2"; shift 2;;
    *) echo "unknown arg: $1" >&2; exit 1;;
  esac
done
[[ -z "$TEST" || -z "$AGENT" ]] && { echo "--test and --agent are required" >&2; exit 1; }
git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo" >&2; exit 1; }
[[ -n "$(git status --porcelain)" ]] && { echo "working tree must be clean (commit or stash first)" >&2; exit 1; }

BASE=$(git rev-parse HEAD)
count_failures() { { bash -c "$TEST" 2>&1 || true; } | grep -Ec "$PATTERN" || true; }

best=$(count_failures)
echo "[breaker] baseline failure lines: $best (base=$BASE)"
[[ "$best" -eq 0 ]] && { echo "[breaker] nothing to fix"; exit 0; }

stalled=0
for ((i=1; i<=MAX; i++)); do
  echo "[breaker] attempt $i/$MAX"
  bash -c "$AGENT" || echo "[breaker] agent exited non-zero"
  now=$(count_failures)
  echo "[breaker] failures: $now (best: $best)"
  if [[ "$now" -eq 0 ]]; then echo "[breaker] green"; exit 0; fi
  if [[ "$now" -lt "$best" ]]; then best=$now; stalled=0; else stalled=$((stalled+1)); fi
  if [[ "$stalled" -ge "$PATIENCE" ]]; then
    echo "[breaker] no improvement for $stalled attempts -> rollback to $BASE"
    git reset --hard "$BASE" && git clean -fd
    exit 2
  fi
done
echo "[breaker] max attempts reached -> rollback"
git reset --hard "$BASE" && git clean -fd
exit 2
