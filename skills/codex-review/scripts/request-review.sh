#!/usr/bin/env bash
# Post an "@codex review" comment on the current branch's PR and record the
# request marker (PR number, HEAD sha, request timestamp) so poll-review.sh can
# tell codex's *new* response apart from any prior review on the PR.
#
# Refuses to run with a dirty tree or unpushed commits — codex reviews the
# pushed HEAD, so a local-only change would get a stale review.
set -euo pipefail

PR="${1:-$(gh pr view --json number -q .number 2>/dev/null || true)}"
if [ -z "${PR:-}" ]; then
  echo "ERROR: no PR for the current branch. Open one with 'gh pr create' first." >&2
  exit 1
fi

if [ -n "$(git status --porcelain)" ]; then
  echo "ERROR: working tree is dirty. Commit your fixes before requesting a review." >&2
  exit 1
fi

# Unpushed commits => codex would review a stale HEAD.
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  if [ -n "$(git rev-list '@{u}..HEAD')" ]; then
    echo "ERROR: local commits are not pushed. Run 'git push' before requesting a review." >&2
    exit 1
  fi
else
  echo "ERROR: branch has no upstream. Run 'git push -u origin HEAD' first." >&2
  exit 1
fi

HEAD_SHA="$(git rev-parse HEAD)"
gh pr comment "$PR" --body "@codex review" >/dev/null
# Stamp the request *after* the comment lands so the poll's >= comparison only
# ever matches codex responses that come back after this point.
REQUEST_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

STATE_FILE="$(git rev-parse --git-dir)/codex-loop.json"
jq -n --argjson pr "$PR" --arg sha "$HEAD_SHA" --arg ts "$REQUEST_TS" \
  '{pr:$pr, head:$sha, requested_at:$ts}' >"$STATE_FILE"

echo "Requested codex review on PR #$PR @ $REQUEST_TS (HEAD ${HEAD_SHA:0:10})"
echo "state: $STATE_FILE"
