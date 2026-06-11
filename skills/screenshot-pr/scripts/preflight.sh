#!/usr/bin/env bash
# Pre-flight gates for screenshot-pr — repo-agnostic.
#
# Checks the gates that are independent of the diff scope. Diff-dependent
# decisions (empty scope, the route cap-and-ask) are evaluated by the skill
# after running scope.mjs, since the cap-and-ask is interactive.
#
# Reads the per-repo config via config.mjs so the dev-server URL(s) aren't
# hardwired. Exits 0 if all required gates pass; non-zero otherwise. Always
# prints the full status table so one run surfaces every failure.

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Pull webUrl / apiUrl / comparison from the per-repo config (env overrides win).
if command -v node >/dev/null 2>&1; then
  eval "$(node "$SCRIPT_DIR/config.mjs" --shell 2>/dev/null)"
fi
WEB_URL="${SCREENSHOT_PR_WEB_URL:-http://localhost:3000}"
API_URL="${SCREENSHOT_PR_API_URL:-}"

pass=()
fail=()

check() {
  local name="$1" message="$2" status="$3"
  if [ "$status" = "ok" ]; then
    pass+=("✓ $name — $message")
  else
    fail+=("✗ $name — $message")
  fi
}

# G1 — PR exists for current branch (and we're not on the default branch)
branch="$(git branch --show-current 2>/dev/null)"
if [ -z "$branch" ]; then
  check G1 "could not read current branch (detached HEAD?)" fail
elif [ "$branch" = "master" ] || [ "$branch" = "main" ]; then
  check G1 "on $branch — skill expects a feature branch with an open PR" fail
elif pr_json="$(gh pr view --json number 2>/dev/null)"; then
  pr_number="$(echo "$pr_json" | sed -n 's/.*"number":\([0-9]*\).*/\1/p')"
  check G1 "PR #${pr_number} found for $branch" ok
else
  check G1 "no PR found for $branch — run \`gh pr create\` first" fail
fi

# G2 — Working tree clean (the before-pass checks files out at the base sha)
if [ -z "$(git status --porcelain 2>/dev/null)" ]; then
  check G2 "working tree clean" ok
else
  check G2 "uncommitted changes — commit or stash before running" fail
fi

# G3 — Branch up-to-date with origin
if git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
  ahead="$(git rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)"
  if [ "$ahead" = "0" ]; then
    check G3 "branch matches origin" ok
  else
    check G3 "local branch is ahead of origin by $ahead commit(s) — push first" fail
  fi
else
  check G3 "branch has no upstream — \`git push -u origin $branch\` first" fail
fi

# G4 — gh image extension (the upload mechanism)
if gh image --help >/dev/null 2>&1; then
  check G4 "gh image extension installed" ok
else
  check G4 "gh image missing — \`gh extension install drogers0/gh-image\`" fail
fi

# G5 — Web dev server reachable
if curl -sf -o /dev/null -m 3 "$WEB_URL" 2>/dev/null; then
  check G5 "web dev server reachable at $WEB_URL" ok
else
  check G5 "web dev server unreachable at $WEB_URL — start it, or set webUrl in config" fail
fi

# G6 — API reachable (only when an apiUrl is configured; otherwise skipped)
if [ -n "$API_URL" ]; then
  api_code="$(curl -s -o /dev/null -w '%{http_code}' -m 3 "$API_URL/" 2>/dev/null || echo 000)"
  if [ "$api_code" != "000" ]; then
    check G6 "api reachable at $API_URL (HTTP $api_code)" ok
  else
    check G6 "api unreachable at $API_URL — start it, or unset apiUrl" fail
  fi
fi

# G8 — gh authenticated
if gh auth status >/dev/null 2>&1; then
  check G8 "gh authenticated" ok
else
  check G8 "gh not authenticated — run \`gh auth login\`" fail
fi

printf '\nPre-flight:\n'
for line in "${pass[@]}"; do printf '  %s\n' "$line"; done
for line in "${fail[@]}"; do printf '  %s\n' "$line"; done

if [ "${#fail[@]}" -gt 0 ]; then
  printf '\n%d gate(s) failed — aborting.\n' "${#fail[@]}" >&2
  exit 1
fi

printf '\nAll independent gates pass. Run scope.mjs next to compute routes.\n'
