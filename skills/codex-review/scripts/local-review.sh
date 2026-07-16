#!/usr/bin/env bash
# Local codex review — the CLI equivalent of the request-review/poll-review
# pair, with the same output contract: findings on stdout, and the LAST line
# is always `VERDICT=CLEAN | FINDINGS | ERROR`.
#
#   local-review.sh                    # diff vs auto-detected base branch
#   local-review.sh --base master      # explicit base
#   local-review.sh --uncommitted      # staged + unstaged + untracked only
#   local-review.sh --commit <sha>     # one commit
#   local-review.sh --base master "focus on concurrency"   # custom prompt
#
# Runs `codex review` (the local Codex CLI, not the GitHub App) against the
# working tree. Typically takes 3–8 minutes; callers should run it in the
# background. The full raw transcript is kept at
# $(git rev-parse --git-dir)/codex-local-review.log for debugging.
set -uo pipefail

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH"
  echo "VERDICT=ERROR reason=codex-not-installed"
  exit 1
}
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "not inside a git repository"
  echo "VERDICT=ERROR reason=not-a-git-repo"
  exit 1
}

args=()
mode_given=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base | --commit)
      args+=("$1" "$2")
      mode_given=1
      shift 2
      ;;
    --uncommitted)
      args+=("$1")
      mode_given=1
      shift
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

# No explicit target → review the branch against the repo's default branch.
if [ "$mode_given" -eq 0 ]; then
  base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  if [ -z "$base" ]; then
    base=$(git for-each-ref --format='%(refname:short)' refs/heads/main refs/heads/master | head -1)
  fi
  if [ -z "$base" ]; then
    echo "could not detect a base branch (no origin/HEAD, no local main/master)"
    echo "VERDICT=ERROR reason=no-base-branch"
    exit 1
  fi
  args+=(--base "$base")
fi

log="$(git rev-parse --git-dir)/codex-local-review.log"
codex review "${args[@]}" >"$log" 2>&1
status=$?

# codex streams its whole session; each assistant message is introduced by a
# standalone `codex` marker line. The review verdict is the block after the
# LAST marker.
final=$(awk '/^codex$/ { n = NR } { lines[NR] = $0 } END { if (n) for (i = n + 1; i <= NR; i++) print lines[i] }' "$log")

if [ "$status" -ne 0 ] || [ -z "$final" ]; then
  echo "--- last lines of $log ---"
  tail -40 "$log"
  echo "VERDICT=ERROR exit=$status"
  exit 1
fi

# The CLI prints the final message twice (streamed, then echoed as the "last
# message" on exit) with no separator — if the block is its own first half
# repeated, keep one copy.
lines=$(printf '%s\n' "$final" | wc -l | tr -d ' ')
if [ $((lines % 2)) -eq 0 ]; then
  half=$((lines / 2))
  first_half=$(printf '%s\n' "$final" | head -n "$half")
  second_half=$(printf '%s\n' "$final" | tail -n "$half")
  [ "$first_half" = "$second_half" ] && final=$first_half
fi

printf '%s\n' "$final"

# Findings arrive as `- [P1] title — path:lines` bullets; none means clean.
count=$(printf '%s\n' "$final" | grep -cE '^[[:space:]]*-[[:space:]]*\[P[0-9]\]' || true)
if [ "${count:-0}" -gt 0 ]; then
  echo "VERDICT=FINDINGS count=$count"
else
  echo "VERDICT=CLEAN"
fi
