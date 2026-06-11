---
name: codex-review
description: Runs an automated codex review loop on the current branch's PR — requests a review, waits for codex to reply, fixes the findings, and re-requests until codex reports no issues. Use when the user wants codex to review a PR, says "ask codex to review", "loop codex on this", "get a clean codex pass", or types "/codex-review".
user-invokable: true
---

# codex-review

Drives the full codex review cycle on the current branch's PR so the user doesn't
have to babysit it: **request → wait → fix → re-request**, looping until codex
comes back clean.

Codex is the `chatgpt-codex-connector[bot]` GitHub App on the repo. It is
triggered by an `@codex review` PR comment and replies one of two ways:

- **Clean** — an *issue comment*: `Codex Review: Didn't find any major issues. Delightful!`
- **Findings** — a *PR review* (`### 💡 Codex Review`) plus inline review comments
  tagged `P1`/`P2`/`P3` anchored to specific lines.

Codex typically replies in **~3–6 minutes**, so polling every 2 minutes is right.

> **Script paths.** Commands below are written relative to this skill's directory
> (`scripts/…`). Run them from the skill root, or prefix with the skill's absolute
> path if your harness invokes from elsewhere.

## When to invoke

- The user asks to get a codex review, "loop codex", or wants a clean pass before merge.
- After pushing a branch with an open PR.
- Re-runs are safe.

**Don't** invoke when there's no PR for the branch yet (open one first), or when the
user only wants a one-off comment posted with no follow-through (just
`gh pr comment` then).

## Inputs

None required — infers the PR from the current branch. Optional: a PR number as
the first arg to `request-review.sh` if not on the PR's branch.

## Required environment

- `gh` CLI authenticated (`gh auth status`).
- Codex GitHub App (`chatgpt-codex-connector[bot]`) installed on the repo.
- **Optional, for fast webhook wakes** (Step 2): the `cli/gh-webhook` extension
  (`gh extension install cli/gh-webhook`), `python3` on PATH, and the
  `admin:repo_hook` token scope (`gh auth refresh -s admin:repo_hook`). All
  optional — without them the poller prints `WEBHOOK=FAILED reason=…` and falls
  back to plain polling, which works the same, just with more latency.

## The loop

Track progress with TaskCreate so each iteration is visible. Cap at **6
iterations** to avoid spinning; if still not clean, stop and report.

### Step 1 — Request a review

```bash
scripts/request-review.sh
```

This refuses if the tree is dirty or has unpushed commits (codex reviews the
*pushed* HEAD). Commit and push first if it complains. It posts `@codex review`
and writes the request marker to `.git/codex-loop.json`.

### Step 2 — Wait for codex

Run the poller **in the background** (`run_in_background: true`) so the harness
wakes you the instant codex replies — don't foreground-sleep or hand-poll:

```bash
scripts/poll-review.sh
```

It blocks until codex responds (or the `CODEX_POLL_MAX` deadline, default 1800s =
30 min), then prints a `VERDICT=` line. **The verdict is always the last line** —
parse that:

- `VERDICT=CLEAN` → go to **Done**.
- `VERDICT=FINDINGS` → go to **Step 3**.
- `VERDICT=TIMEOUT` → tell the user codex didn't respond in 30 min; ask whether to
  keep waiting (re-run Step 2) or stop.

**Wake mechanism (and the `WEBHOOK=` lines).** By default the poller tries to wake
via webhook (`gh webhook forward`, GitHub's hosted relay → a tiny local listener)
so it reacts within seconds instead of waiting up to `CODEX_POLL_INTERVAL`. It
emits one status line before the verdict:

- `WEBHOOK=ACTIVE` — webhooks engaged; nothing to report.
- `WEBHOOK=FAILED reason=<why>` — **tell the user the webhook path failed (quote
  the reason) and that it fell back to polling.** Reasons:
  - `gh-webhook-extension-not-installed` → `gh extension install cli/gh-webhook`
  - `python3-not-found`
  - `forward-failed-…` → usually the gh token lacks `admin:repo_hook`
    (`gh auth refresh -s admin:repo_hook`)
  - `another-agent-on-this-machine-is-setting-up-webhooks-for-this-repo` →
    **expected & harmless** — a concurrent review on the same repo won the setup
    race; this one just polls. No action needed.
  - `forwarder-hook-already-on-repo …` → a live concurrent review on **another
    machine** holds the repo's single webhook slot (its hook is *active*). This
    one polls; it self-clears when that review exits. **No action needed** —
    dead/leaked hooks (active==false) are now pruned automatically on startup, so
    a reported one is genuinely live.
  - `listener-failed-port-…` → set `CODEX_WEBHOOK_PORT` to a free port.

The fallback is seamless — a `WEBHOOK=FAILED` line never changes the verdict, it
just means the wait reverted to polling every `CODEX_POLL_INTERVAL` (default 120s).
Set `CODEX_REVIEW_WEBHOOK=0` to skip webhooks and poll directly.

**Concurrency (safe across projects and agents).** The poller is fully generic —
repo and PR are inferred per-invocation (`repos/{owner}/{repo}`, `gh pr view`),
and state lives at `$(git rev-parse --git-dir)/codex-loop.json`, which is per-repo
*and* per-worktree. Run it in any number of different repos at once: each picks a
free listener port and its own per-repo webhook. The one shared constraint is
GitHub's **one webhook-per-repo** limit, so for multiple agents on the *same* repo
only one gets webhooks; the rest detect this (via a machine-local setup lock or
the hook pre-check) and cleanly fall back to polling. No collisions, no leaked
hooks under normal exit.

### Step 3 — Read and fix the findings

```bash
scripts/findings.sh
```

This prints the review summary and each inline finding (`path:line` + body), each
tagged with a `[comment_id=…]`. For each one:

- **P1 / P2** — fix unless it's a clear false positive.
- **P3** — fix if quick and correct; otherwise use judgment.
- A finding you **deliberately won't fix** (genuine false positive, intentional
  design, out of scope): do **not** loop forever on it. Note it, and if *every*
  remaining finding falls in this bucket, break the loop and surface them to the
  user with your reasoning instead of re-requesting.

Match the surrounding code style. Run the repo's verify/test gate after edits
(e.g. `yarn verify`, `npm test`, or whatever the project uses — check
`CLAUDE.md`/`package.json`), then commit and push:

```bash
git commit -am "fix(review): address codex findings" && git push
```

**Reply on each finding's comment** so the thread reads as resolved — use the
`comment_id` from `findings.sh`:

```bash
scripts/reply.sh <comment_id> "Fixed in <sha> — <one-line of what changed>."
```

Reply to every finding you acted on (a short confirmation of the fix) and to every
one you're deliberately skipping (your reasoning). Do this *after* pushing so you
can reference the fix commit sha.

Then **go back to Step 1** to request a fresh review of the new HEAD.

### Done

When the verdict is `CLEAN`, report to the user: number of iterations, a one-line
summary of what was fixed each round, and the PR link. Leave `.git/codex-loop.json`
in place (it's inside `.git`, never committed).

## Notes

- Detection gates on **response timestamp ≥ request timestamp**, not commit sha —
  codex's review-body sha differs from its inline comments' `commit_id`, so sha
  matching is unreliable. Each `request-review.sh` stamps a fresh timestamp, so a
  late reply to a previous round is correctly ignored.
- This skill only drives codex. CodeRabbit and Vercel bots comment on their own;
  ignore them unless the user asks otherwise.
- Tune cadence per-run with `CODEX_POLL_INTERVAL` / `CODEX_POLL_MAX` env vars.
- Webhook mode is best-effort and self-healing: `gh webhook forward` registers a
  *temporary* repo webhook and deletes it on graceful exit; even while active, the
  poller still does a safety API re-check every `CODEX_POLL_INTERVAL`, so a dropped
  delivery can't strand the loop. Verdict classification always runs through the
  same gh-api detection — the webhook only decides *when* to check, never *what*
  the verdict is. Disable entirely with `CODEX_REVIEW_WEBHOOK=0`.
