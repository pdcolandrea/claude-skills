#!/usr/bin/env bash
# Print codex's findings for the in-flight review (the one recorded by
# request-review.sh): the review summary body plus every inline comment posted
# after the request. Gated on timestamp, same as poll-review.sh.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_FILE="$(git rev-parse --git-dir)/codex-loop.json"
PR="$(jq -r .pr "$STATE_FILE")"
export REQ_TS="$(jq -r .requested_at "$STATE_FILE")"
export BOT='chatgpt-codex-connector[bot]'

echo "## Codex review summary"
gh api "repos/{owner}/{repo}/pulls/$PR/reviews" \
  --jq '.[] | select(.user.login==env.BOT) | select(.submitted_at>=env.REQ_TS) | .body'

echo ""
echo "## Inline findings"
echo "(reply to each once fixed: $SCRIPT_DIR/reply.sh <comment_id> \"message\")"
gh api "repos/{owner}/{repo}/pulls/$PR/comments" --paginate \
  --jq '.[] | select(.user.login==env.BOT) | select(.created_at>=env.REQ_TS) | "\n### \(.path):\(.line // .original_line // .start_line) [comment_id=\(.id)]\n\(.body)"'
