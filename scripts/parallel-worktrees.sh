#!/usr/bin/env bash
# Run several headless agents in parallel, each in its own git worktree.
#
# Usage:
#   parallel-worktrees.sh run "fix-auth:Fix the token refresh bug" "add-csv:Add CSV export"
#   parallel-worktrees.sh status
#   parallel-worktrees.sh merge-check     # dry-run merge of each agent branch into BASE_BRANCH
#   parallel-worktrees.sh clean
#
# Env: AGENT_CMD (default: "claude -p"), BASE_BRANCH (default: main), WT_DIR (default: ../.agent-worktrees)
set -euo pipefail
AGENT_CMD="${AGENT_CMD:-claude -p}"
BASE_BRANCH="${BASE_BRANCH:-main}"
ROOT="$(git rev-parse --show-toplevel)"
WT_DIR="${WT_DIR:-$ROOT/../.agent-worktrees}"
mkdir -p "$WT_DIR"

cmd="${1:-}"; shift || true
case "$cmd" in
  run)
    for spec in "$@"; do
      name="${spec%%:*}"; prompt="${spec#*:}"
      path="$WT_DIR/$name"; branch="agent/$name"
      git worktree add -q -b "$branch" "$path" "$BASE_BRANCH"
      ( cd "$path"; rc=0; $AGENT_CMD "$prompt" > "$WT_DIR/$name.log" 2>&1 || rc=$?; \
        echo "exit=$rc" >> "$WT_DIR/$name.log" ) &
      echo "started $name (branch $branch, log $WT_DIR/$name.log)"
    done
    wait; echo "all agents finished";;
  status)
    git worktree list
    for f in "$WT_DIR"/*.log; do [[ -f "$f" ]] && echo "$(basename "$f"): $(tail -n1 "$f")"; done;;
  merge-check)
    for b in $(git for-each-ref --format='%(refname:short)' refs/heads/agent/); do
      if git merge-tree --write-tree "$BASE_BRANCH" "$b" >/dev/null 2>&1; then echo "OK        $b"
      else echo "CONFLICT  $b"; fi
    done;;
  clean)
    for b in $(git for-each-ref --format='%(refname:short)' refs/heads/agent/); do
      git worktree remove --force "$WT_DIR/${b#agent/}" 2>/dev/null || true
      git branch -D "$b"
    done;;
  *) sed -n '2,10p' "$0"; exit 1;;
esac
