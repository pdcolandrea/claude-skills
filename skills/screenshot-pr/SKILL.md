---
name: screenshot-pr
description: Captures before+after screenshots of the visual changes in the current PR (desktop + mobile-web) using Playwright MCP, uploads them to GitHub as user-attachments, and posts/updates a single bot comment on the PR. Repo-agnostic — driven by an optional .screenshot-pr.json. Use when the user wants to attach screenshots to a PR, show visual changes for review, or runs "/screenshot-pr".
user-invokable: true
---

# screenshot-pr

Captures **before + after** screenshots of the visual changes introduced by the
current branch's PR, at **desktop and mobile-web viewports**, and posts them as a
single updating bot comment on the PR.

The skill is **agent-driven**: it explores the live app with Playwright MCP to
*find* the changed UI on screen (not just navigate to a route), so a polish PR
that tweaks a sidebar actually screenshots the sidebar, not an empty landing page.

It is **repo-agnostic**. Nothing is hardwired — the dev-server URL, routes,
source scope, dynamic-segment fills, and viewports all come from an **optional**
`.screenshot-pr.json` (see *Configuration* below). With no config file it still
works for the common cases: it reads the dev server at `http://localhost:3000`,
auto-derives routes for Next.js (app/ + pages/) repos from the diff, and falls
back to agent exploration for everything else.

> **Script paths.** Commands below are relative to this skill's directory
> (`scripts/…`). Run them from the skill root, or prefix with the skill's
> absolute path if your harness invokes from elsewhere.

## When to invoke

- After `git push` and `gh pr create` on the current branch, before requesting review.
- When the user asks to "attach screenshots", "show what changed visually", or types `/screenshot-pr`.
- Re-runs are safe — each run **updates the same bot comment** (it never duplicates).

**Don't** invoke when:

- The diff is only API/types/tests/config — there's nothing to screenshot.
- No PR exists yet for the branch — the skill refuses (open one first).

## Inputs

None. The skill infers everything from `git` + `gh` state on the current branch,
plus the optional `.screenshot-pr.json`.

## Required environment

| What | Why / how |
|---|---|
| A running web dev server | The app must be served (default `http://localhost:3000`; set `webUrl` to change). The skill does **not** start it. |
| **Playwright MCP** | The capture engine (`mcp__playwright__browser_*`). Must be connected. |
| `gh` CLI | Authenticated (`gh auth status`). Infers the PR, posts the comment. |
| `gh image` extension | The upload mechanism → GitHub `user-attachments`. Install once: `gh extension install drogers0/gh-image`. URLs inherit repo visibility (private repos stay private). |
| `node` | Runs the bundled `.mjs` helpers. |

## Configuration

Optional `.screenshot-pr.json` at the repo root (also read from
`.claude/screenshot-pr.json` or `.config/screenshot-pr.json`). Every key is
optional; see [`references/screenshot-pr.example.json`](references/screenshot-pr.example.json)
for the fully-annotated template. The keys that matter most across repos:

| Key | Default | Purpose |
|---|---|---|
| `webUrl` | `http://localhost:3000` | Where the dev server is served. |
| `apiUrl` | `null` | Companion API the app needs; gates pre-flight only when set. |
| `routes` | `[]` | **Explicit routes to shoot.** When set, auto-derivation is skipped — this is the reliable, framework-agnostic path. |
| `dynamicParams` | `{}` | Fills for dynamic segments, e.g. `{ "[slug]": "hello-world" }`. |
| `viewports` | `{desktop:[1280,900], mobile:[390,844]}` | What to capture per route. |
| `sourceGlobs` | `[]` (whole repo) | Path prefixes that count as the app's visual source. Narrow this in a monorepo so an API/package change doesn't get reverted in the before-pass. |
| `comparison` | `both` | `both` = before+after; `after` = current state only. |
| `baseBranch` | inferred | Override the PR base used for the diff. |
| `maxRoutes` | `5` | Cap before the skill stops and asks you to narrow. |

Env overrides win over the file: `SCREENSHOT_PR_WEB_URL`, `SCREENSHOT_PR_API_URL`.

---

## Procedure

### Step 1 — Pre-flight gates

Run `scripts/preflight.sh` from the repo root. It checks (and prints a status
table for) the diff-independent gates:

| Gate | Check |
|---|---|
| G1 | PR exists for current branch, and it's not `main`/`master` |
| G2 | Working tree clean (the before-pass checks files out at the base sha) |
| G3 | Branch up-to-date with origin |
| G4 | `gh image` extension installed |
| G5 | Web dev server reachable at `webUrl` |
| G6 | API reachable at `apiUrl` — **only if `apiUrl` is configured** |
| G8 | `gh auth status` succeeds |

If **any** gate fails, print the table and stop. Do not partially proceed.

### Step 2 — Scope the diff

Run `node scripts/scope.mjs`. It emits JSON to stdout:

```json
{
  "baseBranch": "main",
  "baseSha": "abc123",
  "headSha": "def456",
  "headCommitterIso": "2026-05-18T19:30:00Z",
  "webUrl": "http://localhost:3000",
  "viewports": { "desktop": [1280,900], "mobile": [390,844] },
  "dynamicParams": { "[slug]": "hello-world" },
  "comparison": "both",
  "maxRoutes": 5,
  "routesFromConfig": false,
  "changedFiles": ["app/pricing/page.tsx", "..."],
  "inScopeFiles": ["app/pricing/page.tsx"],
  "routes": ["/pricing"],
  "suspectCrossScope": false,
  "recognitionStrings": ["Pick another day", "items in cart"],
  "recognitionClasses": ["bg-lime-500"]
}
```

How `routes` is decided:

- **`routesFromConfig: true`** → `config.routes` verbatim. Trust them.
- **`routesFromConfig: false`** → best-effort Next.js derivation (changed
  `app/**/page.tsx` / `pages/**` files → routes). For non-Next repos or
  component-only diffs this is often `[]` — that's expected.

Then:

- **`routes` empty + diff has visual files** → the route auto-derivation didn't
  find a host page. **Reason about it yourself**: read `inScopeFiles`, figure out
  which page renders the changed component, and use that (the recognition loop in
  Step 6 confirms you got it right). If you genuinely can't tell, ask the user.
- **`routes` empty + no visual files** → exit cleanly: "no visual changes
  detected; nothing to screenshot." Not an error.
- **`routes.length > maxRoutes`** → print the list, ask the user to confirm
  "all", pick a subset, or abort.

### Step 3 — Capture the "after" pass (HEAD)

For each `{route, viewport}`:

1. Open a Playwright page. Set the viewport to the `[w,h]` from `viewports`.
2. **Inject the freeze init script.** Generate it with
   `node scripts/freeze.mjs "<headCommitterIso>" > /tmp/screenshot-pr-init.js`,
   then apply via `page.addInitScript({ path })` — or, if the MCP lacks init
   scripts, `browser_evaluate` its contents immediately after navigation. It
   pins `Date`, kills CSS animations/transitions, and forces reduced motion so
   before/after pairs are deterministic and comparable.
3. Navigate to `webUrl + route`. Substitute any dynamic segment using
   `dynamicParams` (e.g. `[slug]` → `hello-world`).
4. **Wait for settle:** `document.fonts.ready` → 2× `requestAnimationFrame` → ~200ms idle.
5. **Recognition + exploration loop** (Step 6).
6. **Screenshot** with `mcp__playwright__browser_take_screenshot`. Save to
   `.tmp-screenshots/after/<safe-route>-<viewport>.png`.

### Step 4 — Capture the "before" pass (base commit)

Skip this entirely when `comparison` is `"after"`.

Check the in-scope source out at the base commit so the running dev server
hot-reloads the old UI. Limit the checkout to the configured `sourceGlobs` when
set (so a monorepo's API/packages aren't reverted); otherwise revert the visual
source tree:

```bash
# narrowed (monorepo with sourceGlobs): git checkout "$BASE_SHA" -- apps/web
git checkout "$BASE_SHA" -- .
sleep 2   # let HMR pick up the revert
```

Repeat Step 3 for each `{route, viewport}`, saving to `.tmp-screenshots/before/`.
Then **restore HEAD immediately**:

```bash
git checkout HEAD -- .
```

If `suspectCrossScope` was true, the before-shots may not reflect the true base
render — the final comment surfaces that caveat automatically.

### Step 5 — Recognition + exploration loop (per page)

Goal: reach a DOM state where the changed UI is **on screen**, then screenshot.

1. After navigation + settle, check the DOM:
   - Contains any `recognitionStrings` string? → success, screenshot now.
   - Contains an element matching any non-noisy `recognitionClasses` class? → success.
2. If not visible, take up to **6 actions** (`browser_click`, `browser_fill`,
   `browser_evaluate` for scroll) to reveal it. Reason about the route's natural
   user flow from the rendered DOM.
3. Re-check after each action.
4. Still not found after 6 actions → **declare a gap** for this target: record
   route, viewport, actions tried, and a one-line **hypothesis** for why it
   failed. Do **not** screenshot a landing state as a substitute — that's
   anti-evidence.
5. **Asymmetric case:** recognition succeeds on "after" but fails on "before"
   usually means the UI is new on this branch — mark the before slot `(new on
   branch)` instead of a missing image.

### Step 6 — Upload + comment

Upload every PNG and capture the URL map:

```bash
scripts/upload.sh .tmp-screenshots > /tmp/screenshot-pr-urls.json
```

Build a manifest JSON (`/tmp/screenshot-pr-manifest.json`) of the captures,
gaps, and `suspectCrossScope`, then render the comment body:

```bash
node scripts/comment.mjs /tmp/screenshot-pr-manifest.json /tmp/screenshot-pr-urls.json > /tmp/screenshot-pr-body.md
```

Manifest shape (see the header of `scripts/comment.mjs` for the full spec):

```json
{
  "updatedIso": "2026-05-18T19:30:00Z",
  "captures": [
    { "route": "/pricing", "scenario": "default",
      "viewports": {
        "desktop": { "beforeRel": "before/pricing-desktop.png", "afterRel": "after/pricing-desktop.png" },
        "mobile":  { "beforeRel": "before/pricing-mobile.png",  "afterRel": "after/pricing-mobile.png" }
      } }
  ],
  "gaps": [],
  "newOnBranch": [],
  "suspectCrossScope": false
}
```

Post or update the comment. The body carries a `<!-- screenshot-pr v1 -->`
signature — find an existing one and `PATCH` it, else `POST` a new one:

```bash
# find:  gh api repos/{owner}/{repo}/issues/<pr>/comments --jq '.[] | select(.body | startswith("<!-- screenshot-pr v1 -->")) | .id'
# new:   gh pr comment <pr> --body-file /tmp/screenshot-pr-body.md
# update:gh api -X PATCH repos/{owner}/{repo}/issues/comments/<id> -f body="$(cat /tmp/screenshot-pr-body.md)"
```

### Step 7 — Cleanup

- `git checkout HEAD -- .` (idempotent restore — never leave the tree on base).
- Delete `.tmp-screenshots/` and the `/tmp/screenshot-pr-*` scratch files.
- Print the comment URL: `https://github.com/<owner>/<repo>/pull/<n>#issuecomment-<id>`.

---

## Determinism (baked into freeze.mjs)

Date is pinned to the HEAD commit time, CSS animations/transitions are zeroed,
and reduced motion is forced — both passes use the **same** pinned moment so
before/after pairs are directly comparable. Always settle (`fonts.ready` →
rAF → idle) before shooting.

## Failure handling

- **Loud, not silent.** Every gap appears in the PR comment with a hypothesis.
  Never substitute a landing-state screenshot when recognition fails.
- **Idempotent reruns.** The same comment is updated, not duplicated; its
  timestamp shows the last run.
- **Clean tree is non-negotiable.** The before-pass `git checkout`s the working
  tree to the base sha — uncommitted changes would be clobbered. Pre-flight
  refuses a dirty tree; do not auto-stash.

## Known follow-ups

- **Auth-gated routes** — routes behind a login won't render. Until a dev-only
  session-mint hook exists, list them as gaps. Per-repo: a config-declared
  cookie/login step could be added.
- **Mobile-native** — only mobile-*web* viewports are covered; native (Expo /
  device) screenshots are out of scope.
- **CI variant** — a GitHub Action that re-runs on every push for canonical
  attestation rather than local-dev capture.
