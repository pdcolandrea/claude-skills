# pdcolandrea-skills

A [Claude Code](https://claude.com/claude-code) plugin marketplace of skills I use
day to day. Add the marketplace once, then install any skill below.

## Install

In a Claude Code session:

```
/plugin marketplace add pdcolandrea/claude-skills
/plugin install codex-review@pdcolandrea-skills
/plugin install screenshot-pr@pdcolandrea-skills
/plugin install aso-appstore-screenshots@pdcolandrea-skills
/plugin install orchestrator@pdcolandrea-skills
/plugin install design-reference@pdcolandrea-skills
```

Or from the shell:

```bash
claude plugin marketplace add pdcolandrea/claude-skills
claude plugin install codex-review@pdcolandrea-skills
claude plugin install screenshot-pr@pdcolandrea-skills
claude plugin install aso-appstore-screenshots@pdcolandrea-skills
claude plugin install orchestrator@pdcolandrea-skills
claude plugin install design-reference@pdcolandrea-skills
```

Run `/plugin` with no args to browse and toggle installed skills.

## Skills

### `codex-review`

Drives the full codex review cycle on the current branch's PR — **request → wait →
fix → re-request**, looping until [OpenAI Codex](https://github.com/apps/codex)
comes back clean, so you don't have to babysit it.

Trigger it by asking Claude to "get a codex review" / "loop codex on this", or run
`/codex-review` directly.

**Requirements**

- `gh` CLI authenticated (`gh auth status`).
- The Codex GitHub App (`chatgpt-codex-connector[bot]`) installed on the repo, and
  an open PR for the current branch.
- *Optional, for sub-minute wake latency:* the `cli/gh-webhook` extension
  (`gh extension install cli/gh-webhook`), `python3` on PATH, and the
  `admin:repo_hook` token scope (`gh auth refresh -s admin:repo_hook`). Without
  these it transparently falls back to polling.

The poller is generic and concurrency-safe: repo/PR are inferred per-invocation
and state lives under `.git/`, so you can run it across many repos at once. See
[`skills/codex-review/SKILL.md`](skills/codex-review/SKILL.md) for the full
contract, env vars (`CODEX_POLL_INTERVAL`, `CODEX_POLL_MAX`,
`CODEX_REVIEW_WEBHOOK`), and webhook diagnostics.

### `screenshot-pr`

Captures **before + after** screenshots of the visual changes in the current
branch's PR (desktop + mobile-web), uploads them to GitHub as `user-attachments`,
and posts a single **updating** bot comment. It's agent-driven — it explores the
live app with Playwright MCP to *find* the changed UI on screen, not just hit a
route — so a polish PR actually shows the component that changed.

Trigger it by asking Claude to "attach screenshots" / "show what changed
visually", or run `/screenshot-pr` directly after `gh pr create`.

**Requirements**

- A running web dev server (default `http://localhost:3000`).
- **Playwright MCP** connected (the capture engine).
- `gh` CLI authenticated, plus the `gh image` extension for the upload
  (`gh extension install drogers0/gh-image`) — URLs inherit repo visibility, so
  private repos stay private.
- `node` for the bundled helpers.

It's **repo-agnostic**: every repo-specific value lives in an optional
`.screenshot-pr.json` (dev-server URL, routes, source globs, dynamic-segment
fills, viewports). With no config it reads `localhost:3000` and auto-derives
routes from the diff for Next.js repos. See
[`skills/screenshot-pr/SKILL.md`](skills/screenshot-pr/SKILL.md) and the
annotated [`references/screenshot-pr.example.json`](skills/screenshot-pr/references/screenshot-pr.example.json).

### `aso-appstore-screenshots`

Generates high-converting App Store screenshots for an iOS app. It analyzes the
app's codebase to discover the 3–5 core benefits that drive downloads, reviews and
pairs your simulator screenshots with each benefit, then produces polished, ASO-
optimized images. Generation is two-stage: a deterministic Pillow **scaffold**
(exact text, device frame, screenshot placement) is enhanced by **Nano Banana Pro**
for a photorealistic result, keeping the whole set visually consistent.

Trigger it by asking Claude to "make my App Store screenshots", or run
`/aso-appstore-screenshots` from inside your app's project.

**Requirements**

- `python3` with **Pillow** (`pip install Pillow`).
- **SF Pro Display** (Black + Regular) fonts installed — on macOS, from
  [Apple's developer fonts](https://developer.apple.com/fonts/) at `/Library/Fonts/`.
- **Gemini MCP** connected for the enhancement stage (provides `generate_image` /
  `edit_image`). Register it with a [Google AI key](https://aistudio.google.com/apikey):

  ```bash
  claude mcp add gemini -s user -e GEMINI_API_KEY=your-key -- npx -y @houtini/gemini-mcp
  ```

Progress (benefits, pairings, brand colour, generation state) is saved to memory so
you can resume across sessions. See
[`skills/aso-appstore-screenshots/SKILL.md`](skills/aso-appstore-screenshots/SKILL.md).

> **Credit:** adapted from
> [adamlyttleapps/claude-skill-aso-appstore-screenshots](https://github.com/adamlyttleapps/claude-skill-aso-appstore-screenshots)
> (MIT). The original license is retained in
> [`skills/aso-appstore-screenshots/LICENSE`](skills/aso-appstore-screenshots/LICENSE).

### `orchestrator`

Picks **which model runs each delegated task** — a subagent, a parallel fan-out,
or a Workflow stage — instead of running everything on one model. It scores the
work on **cost / intelligence / taste** and routes to the cheapest model that
clears the bar: bulk/mechanical work to **gpt-5.6-sol** (via the codex plugin),
user-facing UI/copy/API design to **fable-5** or **opus-5**, reviews to a
fable/opus pass plus an independent codex read. It carries standing permission
to escalate to a smarter model when the output misses the bar.

Trigger it by asking Claude which model should do a task, to "spin up agents" /
"fan out" / "run a workflow", or any time work is being delegated. See
[`skills/orchestrator/SKILL.md`](skills/orchestrator/SKILL.md).

> **Credit:** the model-routing rubric — scoring delegatable work on cost,
> intelligence, and taste, and routing each task to the cheapest model that clears
> the bar — is adapted from Theo Browne
> ([@t3dotgg](https://github.com/t3dotgg)).

### `design-reference`

Section-by-section **design QA** for a web app — two skills that work as a pair.

Tall reference PNGs (20,000+ px) get downsampled ~14× when read directly, so
pixel-level review is impossible. `design-reference-import` probes a design folder,
helps you pick 6–10 section boundaries, writes a `design.json` manifest, and slices
both the desktop and mobile PNG into per-section crops at native resolution.

`design-reference-compare` then **investigates** one section against its crop at
both viewports: it reads the reference first (to avoid "looks fine" confirmation
bias), samples computed styles via Playwright MCP, loads the project's design
tokens, and diffs against a fixed checklist — layout, typography, color,
imagery, missing/extra elements, console hygiene. Every color and font must trace
back to a token; the default verdict is **drift until evidence proves a match**.
Output is a categorized diff plus a punch list of `file:line` fixes.

Trigger it with `/design-reference-import design-context/<screen>` once per design
folder, then `/design-reference-compare design-context/<screen> <section>` (omit the
section to list them) before calling any UI work done.

**Requirements**

- **Playwright MCP** connected (the capture engine) and the project's web dev
  server running.
- `python3` with **Pillow** for the slicer (`pip3 install --user Pillow`).

It's **repo-agnostic**: live URL, route, dev command, and design-token paths all
live in each folder's `design.json`, and compare auto-detects the token source
(Tailwind `globals.css`, `tailwind.config`, a theme module) when the manifest is
silent. See
[`skills/design-reference-import/SKILL.md`](skills/design-reference-import/SKILL.md)
and
[`skills/design-reference-compare/SKILL.md`](skills/design-reference-compare/SKILL.md).

## Adding a skill to this marketplace

1. Drop the skill under `skills/<name>/` (a `SKILL.md` plus any `scripts/`,
   `references/`, etc.). Reference bundled scripts with **relative** paths
   (`scripts/foo.sh`), never `~/.claude/...`, so they resolve wherever the skill
   is installed.
2. Add an entry to the `plugins` array in
   [`.claude-plugin/marketplace.json`](.claude-plugin/marketplace.json).
3. Commit and push — installers pick it up on the next `marketplace add`/update.

## License

[MIT](LICENSE)
