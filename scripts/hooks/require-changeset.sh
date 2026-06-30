#!/usr/bin/env bash
# PreToolUse(Bash) guard — refuse `gh pr create` when no semversioner changeset
# is pending. Mirrors the CI `changeset-required` job so a PR never reaches
# GitHub destined to fail. Reads the Claude Code hook payload on stdin.
#
# Exit 0  -> allow the command.
# Exit 2  -> block it; stderr is shown to the agent so it can fix and retry.
set -euo pipefail

input="$(cat)"
cmd="$(printf '%s' "$input" | jq -r '.tool_input.command // ""' 2>/dev/null || true)"

# Only guard PR creation; every other Bash command passes straight through.
case "$cmd" in
  *"gh pr create"*) ;;
  *) exit 0 ;;
esac

# Resolve the repo the PR is created in. If the command cd's into a directory
# (e.g. a git worktree) honour that; otherwise fall back to the git toplevel of
# the current dir, then the Claude project dir.
target_dir=""
case "$cmd" in
  *"cd "*) target_dir="$(printf '%s' "$cmd" | sed -n 's/.*cd \([^ &;|]*\).*/\1/p' | head -n1)" ;;
esac

root=""
[ -n "$target_dir" ] && root="$(git -C "$target_dir" rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] || root="$(git rev-parse --show-toplevel 2>/dev/null || true)"
[ -n "$root" ] || root="${CLAUDE_PROJECT_DIR:-$PWD}"

count=0
for f in "$root"/.semversioner/next-release/*.json; do
  [ -e "$f" ] && count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
  {
    echo "Blocked: no semversioner changeset in .semversioner/next-release/ ($root)."
    echo "CI job 'changeset-required' will fail this PR. Record one first:"
    echo "  make add-change BUMP=major|minor|patch MSG=\"what changed\""
  } >&2
  exit 2
fi
exit 0
