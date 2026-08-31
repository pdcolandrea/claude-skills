#!/usr/bin/env bash
# Local codex review — the CLI equivalent of the request-review/poll-review
# pair, with the same output contract: findings on stdout, and the LAST line
# is always `VERDICT=CLEAN | FINDINGS | UNKNOWN | ERROR`.
#
#   local-review.sh                                      # branch vs auto-detected base
#   local-review.sh --base master                        # explicit base
#   local-review.sh --uncommitted                        # staged + unstaged + untracked only
#   local-review.sh --commit <sha>                       # one commit
#   local-review.sh "focus on concurrency"               # focused, auto base
#   local-review.sh --base master "focus on concurrency" # focused, explicit scope
#
# RUN IT FROM THE ROOT OF THE REPO YOU WANT REVIEWED, not from the skill
# directory — it resolves the target repo from the current working directory.
# Use the script's absolute path:
#   ~/.claude/skills/codex-review/scripts/local-review.sh …
#
# How the focus brief works. `codex review` rejects `[PROMPT]` alongside any of
# --base/--commit/--uncommitted: the positional prompt IS the scope-instruction
# slot, and the flags fill it for you. So when a brief is given this script
# drops the flag and folds the scope into the prompt text instead ("review only
# the diff of X…"), which keeps scope *and* focus. Verified against
# codex-cli 0.144.1: same `- [P1] …` output contract either way.
#
# Typically takes 3-8 minutes; callers should run it in the background. The full
# raw transcript is kept at $(git rev-parse --git-dir)/codex-local-review.log.
#
# Env: CODEX_LOCAL_STALL (default 600s of log silence => stalled)
#      CODEX_LOCAL_MAX   (default 3600s hard wall-clock cap)
set -uo pipefail

STALL="${CODEX_LOCAL_STALL:-600}"
MAXWALL="${CODEX_LOCAL_MAX:-3600}"

usage() { sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; }

command -v codex >/dev/null 2>&1 || {
  echo "codex CLI not found on PATH"
  echo "VERDICT=ERROR reason=codex-not-installed"
  exit 1
}
git rev-parse --git-dir >/dev/null 2>&1 || {
  echo "not inside a git repository — run this from the root of the repo you want reviewed,"
  echo "e.g. cd <repo> && ~/.claude/skills/codex-review/scripts/local-review.sh"
  echo "VERDICT=ERROR reason=not-a-git-repo"
  exit 1
}

scope_kind=""       # base | commit | uncommitted
scope_ref=""
passthru=()         # flags forwarded to codex verbatim in both modes
prompt_parts=()
rest_is_prompt=0

set_scope() {
  if [ -n "$scope_kind" ]; then
    echo "conflicting scope flags: --$scope_kind and --$1 (pick one)"
    echo "VERDICT=ERROR reason=bad-args"
    exit 1
  fi
  scope_kind="$1"
  scope_ref="${2:-}"
}

while [ $# -gt 0 ]; do
  if [ "$rest_is_prompt" -eq 1 ]; then prompt_parts+=("$1"); shift; continue; fi
  case "$1" in
    --) rest_is_prompt=1; shift ;;
    -h | --help) usage; exit 0 ;;
    --base | --commit)
      [ $# -ge 2 ] || { echo "$1 needs a value"; echo "VERDICT=ERROR reason=bad-args"; exit 1; }
      set_scope "${1#--}" "$2"; shift 2 ;;
    --uncommitted) set_scope uncommitted ""; shift ;;
    --title | -c | --config | --enable | --disable)
      [ $# -ge 2 ] || { echo "$1 needs a value"; echo "VERDICT=ERROR reason=bad-args"; exit 1; }
      passthru+=("$1" "$2"); shift 2 ;;
    --strict-config) passthru+=("$1"); shift ;;
    -*)
      echo "unrecognised flag: $1 (pass a focus brief as a plain quoted argument, or use -- to end flags)"
      echo "VERDICT=ERROR reason=bad-args"
      exit 1 ;;
    *) prompt_parts+=("$1"); shift ;;
  esac
done

prompt=""
if [ "${#prompt_parts[@]}" -gt 0 ]; then
  prompt="${prompt_parts[*]}"
fi

# No explicit target => review the branch against the repo's default branch.
if [ -z "$scope_kind" ]; then
  base=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')
  if [ -z "$base" ]; then
    base=$(git for-each-ref --format='%(refname:short)' refs/heads/main refs/heads/master | head -1)
  fi
  if [ -z "$base" ]; then
    echo "could not detect a base branch (no origin/HEAD, no local main/master)"
    echo "VERDICT=ERROR reason=no-base-branch"
    exit 1
  fi
  scope_kind="base"
  scope_ref="$base"
fi

cmd=()
[ "${#passthru[@]}" -gt 0 ] && cmd=("${passthru[@]}")

if [ -z "$prompt" ]; then
  # Unfocused: let codex's own scope flags drive it.
  case "$scope_kind" in
    base) cmd+=(--base "$scope_ref") ;;
    commit) cmd+=(--commit "$scope_ref") ;;
    uncommitted) cmd+=(--uncommitted) ;;
  esac
else
  # Focused: the prompt slot is the only one codex will accept, so the scope
  # goes into the prose. See the header note.
  case "$scope_kind" in
    base) scope_sentence="Review ONLY the changes on the current branch against base \`$scope_ref\` — the diff \`git diff $scope_ref...HEAD\`. Ignore uncommitted and untracked files entirely." ;;
    commit) scope_sentence="Review ONLY the changes introduced by commit \`$scope_ref\` — \`git show $scope_ref\`. Ignore uncommitted and untracked files entirely." ;;
    uncommitted) scope_sentence="Review ONLY the uncommitted changes in the working tree — staged, unstaged and untracked files. Ignore anything already committed." ;;
  esac
  cmd+=("$scope_sentence

Report every finding as a bullet of exactly this shape:
- [P1] short title — path:line-range
  One indented paragraph explaining the problem and the fix.
Use P1 for must-fix, P2 for should-fix, P3 for optional. If you find nothing
material, say so in prose and emit no bullets at all.

Focus area from the requester:
$prompt")
fi

log="$(git rev-parse --absolute-git-dir)/codex-local-review.log"
: >"$log"

log_mtime() { stat -f %m "$log" 2>/dev/null || stat -c %Y "$log" 2>/dev/null || echo 0; }

codex review "${cmd[@]}" >"$log" 2>&1 &
codex_pid=$!
started=$(date +%s)
stall_reason=""

# Watchdog: codex stalls in the field (log goes silent while the process stays
# alive). The liveness signal is the log's mtime, not the process state.
while kill -0 "$codex_pid" 2>/dev/null; do
  sleep 10
  now=$(date +%s)
  quiet=$(( now - $(log_mtime) ))
  if [ "$quiet" -ge "$STALL" ]; then stall_reason="stalled quiet=${quiet}s"; break; fi
  if [ $(( now - started )) -ge "$MAXWALL" ]; then stall_reason="wall-clock elapsed=$(( now - started ))s"; break; fi
done

if [ -n "$stall_reason" ]; then
  pkill -P "$codex_pid" >/dev/null 2>&1 || true
  kill -TERM "$codex_pid" >/dev/null 2>&1 || true
  sleep 2
  kill -KILL "$codex_pid" >/dev/null 2>&1 || true
  echo "--- last lines of $log ---"
  tail -40 "$log"
  echo "log: $log"
  echo "VERDICT=ERROR reason=${stall_reason%% *} detail=\"$stall_reason\""
  exit 1
fi

wait "$codex_pid"
status=$?

# codex streams its whole session; each assistant message is introduced by a
# standalone `codex` marker line. The review verdict is the block after the
# LAST marker.
final=$(awk '/^codex$/ { n = NR } { lines[NR] = $0 } END { if (n) for (i = n + 1; i <= NR; i++) print lines[i] }' "$log")

if [ "$status" -ne 0 ] || [ -z "$final" ]; then
  echo "--- last lines of $log ---"
  tail -40 "$log"
  echo "log: $log"
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
echo "log: $log"

# Findings arrive as `- [P1] title — path:lines` bullets. The severity words are
# accepted too so a vocabulary change doesn't read as clean.
count=$(printf '%s\n' "$final" | grep -cEi '^[[:space:]]*-[[:space:]]*\[(P[0-9]|critical|high|medium|low)\]' || true)
if [ "${count:-0}" -gt 0 ]; then
  echo "VERDICT=FINDINGS count=$count"
  exit 0
fi

# Never fail toward CLEAN. If the body carries anything that *looks* like a
# findings list but didn't match above, the format drifted — say so instead of
# reporting a clean pass nobody verified.
drift=$(printf '%s\n' "$final" | grep -cEi '^[[:space:]]*-[[:space:]]*\[|review comments?:|^[[:space:]]*[0-9]+\.[[:space:]]*\[' || true)
if [ "${drift:-0}" -gt 0 ]; then
  echo "VERDICT=UNKNOWN reason=unrecognised-findings-format"
  exit 0
fi

echo "VERDICT=CLEAN"
