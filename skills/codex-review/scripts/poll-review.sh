#!/usr/bin/env bash
# Block until codex responds to the review requested by request-review.sh, then
# print a verdict and exit. Intended to be run with run_in_background:true so the
# harness re-invokes the agent the moment codex replies (rather than burning a
# fixed wait).
#
# Verdict (last line of stdout):
#   VERDICT=CLEAN     codex found no issues ("Didn't find any major issues")
#   VERDICT=FINDINGS  codex posted a review with suggestions
#   VERDICT=TIMEOUT   no codex response within the deadline
#
# Wake mechanism: two modes, chosen by CODEX_REVIEW_WEBHOOK (default on).
#   - Webhook (preferred): `gh webhook forward` streams the repo's
#     issue_comment / pull_request_review events over GitHub's hosted relay to a
#     tiny local listener, so we wake within seconds of codex replying. Prints
#     `WEBHOOK=ACTIVE` once engaged.
#   - Polling (fallback): re-check the API every CODEX_POLL_INTERVAL. Used when
#     webhooks are disabled OR setup fails (no extension, no python3, no
#     admin:repo_hook scope, port busy, …). On failure it prints
#     `WEBHOOK=FAILED reason=<why>` BEFORE falling back, so the agent can tell the
#     user the webhook path didn't work.
# Either way the FINAL line is the VERDICT= line — parse that.
#
# Detection gates purely on "response timestamp >= request timestamp". Codex
# always reviews current PR HEAD when triggered, so a response that lands after
# our request is necessarily for our request. (Sha-matching is unreliable: the
# sha in the review body differs from the inline comments' commit_id.)
set -euo pipefail

INTERVAL="${CODEX_POLL_INTERVAL:-120}"      # seconds between API re-checks
MAX="${CODEX_POLL_MAX:-1800}"               # give up after this many seconds
WEBHOOK="${CODEX_REVIEW_WEBHOOK:-1}"        # 1 = try webhook then fall back; 0 = poll only
PORT="${CODEX_WEBHOOK_PORT:-}"              # local listener port; empty = auto-pick a free one (safe for concurrent agents)
NUDGE_INTERVAL=5                            # seconds between local signal-file checks (webhook mode)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

STATE_FILE="$(git rev-parse --git-dir)/codex-loop.json"
if [ ! -f "$STATE_FILE" ]; then
  echo "ERROR: no review in flight ($STATE_FILE missing). Run request-review.sh first." >&2
  exit 1
fi
PR="$(jq -r .pr "$STATE_FILE")"
export REQ_TS="$(jq -r .requested_at "$STATE_FILE")"
BOT='chatgpt-codex-connector[bot]'
export BOT
deadline=$(( $(date +%s) + MAX ))

# Print "VERDICT=..." and return 0 if codex has responded for this request;
# return 1 if there's nothing yet. The single source of truth for the verdict —
# both wake modes call this; the webhook only decides *when* to call it.
check_verdict() {
  local clean findings
  clean="$(gh api "repos/{owner}/{repo}/issues/$PR/comments" \
    --jq '[.[] | select(.user.login==env.BOT) | select(.created_at>=env.REQ_TS) | select(.body|test("[Dd]idn.t find any"))] | length' 2>/dev/null || echo 0)"
  # Coerce anything non-numeric (transient API error, 404 body, empty) to 0.
  case "$clean" in ''|*[!0-9]*) clean=0 ;; esac
  if [ "$clean" -gt 0 ]; then
    echo "VERDICT=CLEAN"; return 0
  fi
  findings="$(gh api "repos/{owner}/{repo}/pulls/$PR/reviews" \
    --jq '[.[] | select(.user.login==env.BOT) | select(.submitted_at>=env.REQ_TS) | select(.body|test("Codex Review"))] | length' 2>/dev/null || echo 0)"
  case "$findings" in ''|*[!0-9]*) findings=0 ;; esac
  if [ "$findings" -gt 0 ]; then
    echo "VERDICT=FINDINGS"; return 0
  fi
  return 1
}

poll_loop() {
  while :; do
    if check_verdict; then exit 0; fi
    if [ "$(date +%s)" -ge "$deadline" ]; then echo "VERDICT=TIMEOUT"; exit 0; fi
    sleep "$INTERVAL"
  done
}

# Webhook-mode child state + cleanup (script-scoped so the EXIT trap can see them).
# PRE_FWD_HOOKS is the set of forwarder-hook ids that existed *before* we started,
# so the backstop only ever deletes the temp hook this run created.
REASON=""
FWD_PID=""; LISTENER_PID=""; SIG_FILE=""; FWD_LOG=""; PRE_FWD_HOOKS=""; WEBHOOK_LAUNCHED=0; LOCK_DIR=""
forwarder_hook_ids() {
  gh api "repos/{owner}/{repo}/hooks" \
    --jq '.[] | select(.config.url // "" | test("webhook-forwarder")) | .id' 2>/dev/null || true
}
cleanup_webhook() {
  if [ -n "$FWD_PID" ]; then
    # SIGINT (not TERM): gh webhook forward deletes its temp repo hook on interrupt.
    kill -INT "$FWD_PID" >/dev/null 2>&1 || true
    for _ in 1 2 3 4 5 6 7 8; do kill -0 "$FWD_PID" 2>/dev/null || break; sleep 0.5; done
    kill "$FWD_PID" >/dev/null 2>&1 || true   # force if it ignored the interrupt
  fi
  [ -n "$LISTENER_PID" ] && kill "$LISTENER_PID" >/dev/null 2>&1 || true
  # Backstop: if graceful interrupt didn't remove the hook, delete the one we
  # created — but ONLY when there's exactly one forwarder hook that wasn't in the
  # pre-start snapshot. If several "unknown" hooks exist, a concurrent review on
  # this same repo is running; we can't tell which is ours (the forwarder URL is
  # identical), so we leave them all for their own process's SIGINT cleanup rather
  # than risk deleting a sibling's live hook. (A leak is recoverable; killing a
  # live sibling mid-review is not.)
  if [ "$WEBHOOK_LAUNCHED" = 1 ]; then
    local h unknown_count=0 unknown_id=""
    for h in $(forwarder_hook_ids); do
      case " $PRE_FWD_HOOKS " in
        *" $h "*) ;;  # pre-existing — leave it
        *) unknown_count=$(( unknown_count + 1 )); unknown_id="$h" ;;
      esac
    done
    if [ "$unknown_count" -eq 1 ]; then
      gh api -X DELETE "repos/{owner}/{repo}/hooks/$unknown_id" >/dev/null 2>&1 || true
    fi
  fi
  [ -n "$SIG_FILE" ] && rm -f "$SIG_FILE" >/dev/null 2>&1 || true
  [ -n "$FWD_LOG" ] && rm -f "$FWD_LOG" >/dev/null 2>&1 || true
  # Release the per-repo setup lock if we still hold it (held only during setup;
  # normally already released once webhooks went active — see run_webhook).
  [ -n "$LOCK_DIR" ] && rmdir "$LOCK_DIR" >/dev/null 2>&1 || true
}

# Attempt the webhook wake path. On a verdict/timeout it prints the verdict and
# exits the whole process. On any setup/runtime failure it sets REASON, tears the
# helpers down, and returns 1 so the caller can fall back to polling.
run_webhook() {
  command -v python3 >/dev/null 2>&1 || { REASON="python3-not-found"; return 1; }
  gh extension list 2>/dev/null | grep -q 'gh-webhook' || { REASON="gh-webhook-extension-not-installed"; return 1; }
  local repo
  repo="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"
  [ -n "$repo" ] || { REASON="cannot-resolve-repo"; return 1; }

  # Per-repo setup lock (machine-local, atomic via mkdir). GitHub allows only one
  # forwarder hook per repo, and `gh webhook forward` manages that hook *by URL* —
  # so two instances racing on the same repo step on each other's shared hook and
  # BOTH collapse. The lock serializes setup so exactly one agent on this machine
  # creates the hook; others fall back to polling. Held only through setup (we
  # release it the moment webhooks go active), so a steady-state crash leaks at
  # most the hook (caught by the next run's pre-check), never a permanent lock.
  local lock="${TMPDIR:-/tmp}/codex-webhook-$(printf '%s' "$repo" | tr -c 'A-Za-z0-9' '_').lock"
  if mkdir "$lock" 2>/dev/null; then
    LOCK_DIR="$lock"
  else
    REASON="another-agent-on-this-machine-is-setting-up-webhooks-for-this-repo"
    return 1
  fi

  # With the lock held, check for an existing forwarder hook: a live sibling on a
  # DIFFERENT machine, or a hook leaked by a crashed run. Either way we can't use
  # webhooks (the create would 422), and we must not touch that hook.
  if [ -n "$(forwarder_hook_ids | tr '\n' ' ' | tr -d ' ')" ]; then
    REASON="forwarder-hook-already-on-repo (concurrent review elsewhere, or leaked hook — list/clean: gh api repos/$repo/hooks)"
    cleanup_webhook; return 1
  fi

  # Pick a free port unless one was pinned, so concurrent agents on other repos
  # don't collide on a fixed port. Tiny TOCTOU window between pick and bind is
  # covered by the listener-alive check below.
  local port="$PORT"
  if [ -z "$port" ]; then
    port="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1",0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || true)"
    [ -n "$port" ] || { REASON="cannot-pick-free-port"; cleanup_webhook; return 1; }
  fi

  SIG_FILE="$(mktemp -t codex_webhook_sig.XXXXXX)"
  FWD_LOG="$(mktemp -t codex_webhook_fwd.XXXXXX)"
  : > "$SIG_FILE"

  # Snapshot forwarder hooks that already exist (e.g. a concurrent review on
  # another branch) so cleanup only removes the one we're about to create.
  PRE_FWD_HOOKS="$(forwarder_hook_ids | tr '\n' ' ')"

  python3 "$SCRIPT_DIR/webhook-listener.py" "$port" "$SIG_FILE" >/dev/null 2>&1 &
  LISTENER_PID=$!
  gh webhook forward --repo="$repo" --events=issue_comment,pull_request_review \
    --url="http://127.0.0.1:$port" >"$FWD_LOG" 2>&1 &
  FWD_PID=$!
  # EXIT covers normal exit; INT/TERM ensure cleanup runs if the harness or user
  # terminates the background process (each handler exits → fires the EXIT trap).
  trap cleanup_webhook EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # Give both a moment to bind / register; a quick death means setup failed.
  sleep 3
  if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
    REASON="listener-failed-port-${port}-likely-in-use"
    cleanup_webhook; trap - EXIT INT TERM; FWD_PID=""; LISTENER_PID=""; return 1
  fi
  if ! kill -0 "$FWD_PID" 2>/dev/null; then
    # Most common cause is a lost create race (sibling won the one-per-repo slot).
    REASON="forward-failed-$(head -1 "$FWD_LOG" 2>/dev/null | tr -d '\r\n' | cut -c1-100)"
    cleanup_webhook; trap - EXIT INT TERM; FWD_PID=""; LISTENER_PID=""; return 1
  fi

  # Forward is alive => it registered the hook, and the pre-check guaranteed none
  # existed before us, so the single forwarder hook on this repo is definitively
  # ours. Only now is it safe for cleanup to delete it.
  WEBHOOK_LAUNCHED=1
  # Release the setup lock now that our hook exists — the hook itself is the
  # steady-state mutex (a later agent's pre-check will see it and fall back).
  rmdir "$LOCK_DIR" >/dev/null 2>&1 || true; LOCK_DIR=""
  echo "WEBHOOK=ACTIVE"

  local last_size=0 last_api=0 now size
  while :; do
    now="$(date +%s)"
    size="$(wc -c < "$SIG_FILE" 2>/dev/null | tr -d ' ' || echo 0)"
    # Re-check on a webhook nudge, or every INTERVAL as a safety net (in case a
    # delivery was missed). The webhook just makes the first branch fire fast.
    if [ "$size" != "$last_size" ] || [ $(( now - last_api )) -ge "$INTERVAL" ]; then
      last_size="$size"; last_api="$now"
      if check_verdict; then exit 0; fi   # EXIT trap tears down the helpers
    fi
    if [ "$now" -ge "$deadline" ]; then echo "VERDICT=TIMEOUT"; exit 0; fi
    # If a helper died mid-run, fall back to polling for the remaining time.
    if ! kill -0 "$FWD_PID" 2>/dev/null; then
      REASON="forward-process-exited"; cleanup_webhook; trap - EXIT INT TERM; FWD_PID=""; LISTENER_PID=""; return 1
    fi
    if ! kill -0 "$LISTENER_PID" 2>/dev/null; then
      REASON="listener-process-exited"; cleanup_webhook; trap - EXIT INT TERM; FWD_PID=""; LISTENER_PID=""; return 1
    fi
    sleep "$NUDGE_INTERVAL"
  done
}

if [ "$WEBHOOK" != "0" ]; then
  if run_webhook; then
    exit 0
  fi
  echo "WEBHOOK=FAILED reason=${REASON:-unknown}"
fi
poll_loop
