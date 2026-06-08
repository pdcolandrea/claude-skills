#!/usr/bin/env bash
# Reply to one of codex's inline review comments so the thread shows it's
# resolved. Use the comment_id surfaced by findings.sh.
# Usage: reply.sh <comment_id> "message"
set -euo pipefail

if [ "$#" -lt 2 ] || [ -z "${1:-}" ] || [ -z "${2:-}" ]; then
  echo "usage: reply.sh <comment_id> \"message\"" >&2
  exit 1
fi

COMMENT_ID="$1"
BODY="$2"
PR="$(jq -r .pr "$(git rev-parse --git-dir)/codex-loop.json")"

gh api --method POST \
  "repos/{owner}/{repo}/pulls/$PR/comments/$COMMENT_ID/replies" \
  -f body="$BODY" --jq '.html_url'
