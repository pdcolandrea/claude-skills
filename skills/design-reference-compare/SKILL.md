---
name: design-reference-compare
description: Investigate a section of the live web app against its design reference at both desktop and mobile viewports. Goes beyond eyeball-diffing — samples computed styles, checks DOM hygiene, captures console errors, and compares colors/typography against the project's design tokens. Use whenever the user is implementing or polishing a section of a design and wants to verify it matches.
user-invokable: true
args:
  - name: design
    description: Path to the design folder containing design.json (e.g. design-context/landing-page). One folder per screen.
    required: true
  - name: section
    description: Section id from design.json (e.g. hero, pricing, footer). Omit to list available sections.
    required: false
---

# design-reference-compare

Runtime half of the design-reference pair. This is an **investigation**, not a glance: every run gathers concrete evidence — pixels, computed styles, design tokens, DOM hygiene, console output — and produces a categorized diff with severities. Skipping the evidence-gathering steps defeats the purpose.

**Prerequisite**: the target design folder has been bootstrapped with `design-reference-import` — it must contain `design.json` and `sections/{desktop,mobile}/*.png`.

Repo-agnostic: the live URL, route, dev command, and token files all come from `design.json`, with sane fallbacks when they're absent.

**Requirements**: Playwright MCP connected (the capture engine), and the project's web dev server running.

## The bar: nearly pixel-perfect

This skill is **not time-boxed**. Take as long as the section deserves. The bar is **nearly pixel-perfect parity with the reference** — colors trace to the same design tokens, fonts/sizes/weights match, spacing is within ±2px, element counts match, layout structure matches. Anything else is drift and gets reported.

There is no "good enough" mode. There are three valid verdicts only:

- **✓ matches** — every checklist item passes. Live and reference are visually equivalent. If you'd hesitate before saying "yes this is the same," it's not ✓.
- **◐ intentional difference** — the delta is explainable and accepted (e.g. the design uses a placeholder name but live shows a real record; the design shows a still frame of an animation that's mid-flight live). Cite *why* it's intentional.
- **✗ drift** — anything else. Single-pixel misalignments, slightly off hexes, font-weight off by 100, missing border — all of these are ✗. Be honest. The user is asking the skill *because* the eye missed this last time.

When uncertain, **drill in further** rather than settling: take a tighter element screenshot, sample more child elements via `browser_evaluate`, zoom the reference crop. Confidence comes from evidence, not from running out of patience.

## When to use

- After implementing or editing a section, before declaring the change "done".
- Whenever the user asks to "compare against the design", "verify the hero matches", "check the spacing", etc.
- Always run **both viewports** — never just desktop or just mobile. Mobile and desktop are independent designs and one passing does not imply the other passes.

## Inputs

- `design` — path to the design folder.
- `section` — section id (matches `sections[].id` in `design.json`). Omit to list sections and exit.

## Why the workflow is in this order

The investigation steps are sequenced deliberately. **Do not skip or reorder them**:

1. Build a mental model of the design **first** (step 3) — looking at the live before knowing what the design says produces "looks fine" confirmation bias.
2. Sample computed styles **before** opening the live screenshot (step 5) — numerical evidence anchors the visual review.
3. Read the four images **after** you already have computed styles + tokens loaded (step 6) — your eyes now know what to look for.
4. Diff against a fixed checklist (step 7) — free-form looking misses the same things every time.

## Steps

### 1. Load the manifest

Read `<design>/design.json`. Confirm:
- The section id exists in `sections[]`.
- The matching reference crops exist on disk:
  - `<design>/sections/desktop/<NN>-<id>.png`
  - `<design>/sections/mobile/<NN>-<id>.png`
- If a variant is missing in the manifest (e.g. a section only exists on desktop), say so and skip that variant.
- If crops are missing on disk, instruct the user to re-run `design-reference-import` first.

Also note `liveUrl` (default `http://localhost:3000`), `route` (default `/`), `devCommand`, and `tokens` — they drive steps 2 and 4.

### 2. Confirm the dev server is running

```bash
curl -s -o /dev/null -w "%{http_code}" $LIVE_URL
```

`$LIVE_URL` is `manifest.liveUrl` + `manifest.route`. If it returns anything other than 200/3xx, stop and ask the user to start the dev server — quote `manifest.devCommand` if the manifest has one, otherwise infer the command from the project (`package.json` scripts, README, CLAUDE.md/AGENTS.md). Don't guess silently and don't screenshot an error page.

### 3. Read the design references FIRST

Before touching Playwright, read the reference crops:

1. `<design>/sections/desktop/<NN>-<id>.png`
2. `<design>/sections/mobile/<NN>-<id>.png`

Out loud, note for yourself: what's the headline? Where's the CTA? What colors stand out? What's the layout structure (single column, grid, split)? This is the mental model the rest of the workflow tests against. Skipping this step is the #1 source of "looks fine" misses.

### 4. Load the design tokens

Every color and font in the live section should trace back to a token the project already defines. Anything that doesn't is a candidate for drift.

Read the token sources, in this order of preference:

1. `manifest.tokens` — repo-relative paths recorded at import time. Use these when present.
2. Auto-detect, when the manifest doesn't say. Look for, in rough order of likelihood:
   - a Tailwind v4 global stylesheet with `:root` custom properties — `app/globals.css`, `src/app/globals.css`, `apps/*/app/globals.css`, `styles/globals.css`
   - `tailwind.config.{ts,js}` (`theme.extend`) for pre-v4 projects
   - a theme/tokens module — `theme.ts`, `tokens.ts`, `design-tokens.json`, `packages/*/theme*`
   - a CSS-in-JS theme object or a Unistyles/Stitches/vanilla-extract theme
   Prefer whichever the section's own component files actually import from.
3. If nothing turns up, say so explicitly in the report and fall back to internal consistency (do the live values at least agree with the rest of the app?) — but flag the missing token source as a finding, because untokenized values are exactly the drift this skill exists to catch.

Note the palette (`--background`, `--foreground`, `--primary`, `--accent`, …), the type scale, spacing steps, and radii, whatever shape they take in this project.

### 5. Capture live evidence via Playwright MCP

For each variant (`desktop`, then `mobile`):

1. **Set viewport**:
   - desktop: `mcp__playwright__browser_resize` with width = `manifest.sources.desktop.viewportWidth` (usually 1280), height 900.
   - mobile: same with mobile viewport width (usually 390), height 844.
2. **Clear console state**: call `mcp__playwright__browser_console_messages` once to flush prior captures.
3. **Navigate**: `mcp__playwright__browser_navigate` to `manifest.liveUrl` + `manifest.route`.
4. **Wait for animations to settle**: if the section has an obvious "anchor word" (a headline like "PRICING"), `mcp__playwright__browser_wait_for` for that text. Otherwise sleep 800ms via `browser_evaluate`.
5. **Scroll into view**:
   - If `anchor` exists: `document.querySelector('<anchor>')?.scrollIntoView({behavior:'instant', block:'start'})`.
   - Otherwise: compute `liveY = (section[variant].y / pngHeight) * documentHeight` and `window.scrollTo(0, liveY)`.
6. **Sample computed styles** via `mcp__playwright__browser_evaluate` — this is the *evidence* you'll cite in the diff:
   ```js
   () => {
     const el = document.querySelector('<anchor or section root>');
     if (!el) return { error: 'section root not found' };
     const cs = getComputedStyle(el);
     const headings = [...el.querySelectorAll('h1,h2,h3')].slice(0, 3).map(h => {
       const c = getComputedStyle(h);
       return { tag: h.tagName, text: h.textContent.trim().slice(0, 60),
                fontFamily: c.fontFamily, fontSize: c.fontSize, fontWeight: c.fontWeight,
                color: c.color, letterSpacing: c.letterSpacing };
     });
     const ctas = [...el.querySelectorAll('button, a[class*="button"], [role="button"]')].slice(0, 3).map(b => {
       const c = getComputedStyle(b);
       return { text: b.textContent.trim().slice(0, 40),
                bg: c.backgroundColor, color: c.color, fontWeight: c.fontWeight };
     });
     const imgs = [...el.querySelectorAll('img')].map(i => ({
       src: i.currentSrc || i.src, alt: i.alt, broken: i.naturalWidth === 0,
       w: i.naturalWidth, h: i.naturalHeight
     }));
     const rect = el.getBoundingClientRect();
     return { bg: cs.backgroundColor, color: cs.color,
              fontFamily: cs.fontFamily,
              padding: cs.padding, gap: cs.gap,
              rect: { w: Math.round(rect.width), h: Math.round(rect.height) },
              headings, ctas, imgs };
   }
   ```
   Record the returned object for use in step 7.
7. **Screenshot** with `mcp__playwright__browser_take_screenshot`:
   - Element screenshot is preferred when an anchor exists — pass the selector so Playwright crops to that element.
   - Otherwise use viewport screenshot.
   - Save to `/tmp/compare-<design-name>-<id>-<variant>.png`.
8. **Capture console**: after the screenshot, call `mcp__playwright__browser_console_messages` again and note any errors or warnings emitted during this run.

### 6. Read the live screenshots

Read in order, as separate tool calls so each lands at full resolution:

1. `/tmp/compare-<design-name>-<id>-desktop.png`
2. `/tmp/compare-<design-name>-<id>-mobile.png`

You already have the design references in your head from step 3 — now you're looking for specific deltas, not "what does this look like."

### 7. Diff against the checklist (do not freelance)

For each variant, walk this checklist explicitly. Each item is either ✓ (pixel-equivalent), ◐ (intentional difference with cited reason), or ✗ (drift). **List the item even when it matches** — silence on an item is ambiguous.

**The default is ✗ until evidence proves ✓.** Don't grant ✓ to anything you only glanced at. If you sampled the computed style and it traces to the right token, that's ✓ with evidence. If you eyeballed the color and "it looks the same," that's still ✗ until you sample it.

**Layout**:
- Element count in section (count CTAs, cards, list items)
- Top/bottom/left/right alignment
- Inter-element spacing (gap)
- Section padding (top/bottom)
- Section bounding-box ratio (`rect.w × rect.h` from step 5 vs reference aspect)

**Typography** (use the computed styles from step 5, not eyeballing):
- Headline: family, size, weight, color
- Body: family, size, weight, color
- Tracking / letter-spacing if visibly tight or loose in design
- **Every value must trace to a token from step 4**. If `fontSize: 14.4px` but the type scale only has `--text-sm: 14px`, that's drift.

**Color** (computed styles + tokens from step 4):
- Section background
- Card/panel backgrounds
- Accent colors (CTAs, highlights, badges)
- Text color
- **Every hex/rgb must trace to a token**. A random `#23241F` that doesn't match any token = drift.

**Iconography / imagery**:
- Right images present and right size?
- All `<img>` have `alt`? Any `broken: true` from step 5?
- Icon library consistent with design (lucide vs custom)?

**State / content**:
- Buttons in rest state (not focused/hovered from a stray pointer)?
- Forms empty as designed, or have placeholder text?
- Animation in resting state (not mid-flight)?

**Missing / extra elements**:
- Anything in design not in live?
- Anything in live not in design?

**Console hygiene** (from step 5.8):
- Any errors during navigation/render?
- Any 404s or failed network requests?

### 8. Report

Output structure:

```
## <section> — desktop / mobile

**Verdict**: ✓ matches  |  ◐ minor drift  |  ✗ needs work

**Layout**
- ✓/◐/✗ <item> — <evidence: numbers, screenshots, computed style>

**Typography**
- ...

**Color**
- ...

**DOM / Console**
- ...

**Punch list** (only if not ✓):
1. <specific fix> — `file_path:line_number` if known
2. ...
```

Repeat per variant. Be specific. "Headline color is `rgb(245, 245, 245)` but the token is `--foreground: oklch(0.985 0 0)` (≈ `rgb(252, 252, 252)`) — slight greying drift" beats "headline looks slightly off."

### 9. Suggest fixes only after reporting

Once the diff is on the table, ask the user if they want fixes applied, or propose specific code edits referenced by `file_path:line_number`. Don't auto-edit during the compare step — the compare is purely diagnostic.

## Listing mode

If `section` is omitted, read `design.json` and print:

```
Available sections in <design>:
  01 hero          (desktop ✓, mobile ✓, anchor: —)
  02 stats         (desktop ✓, mobile ✓, anchor: —)
  03 how-it-works  (desktop ✓, mobile ✓, anchor: #how-it-works)
  04 comparison    (desktop ✓, mobile ✓, anchor: #comparison)
  05 pricing       (desktop ✓, mobile ✓, anchor: #pricing)
  ...
```

Then stop. The user picks a section and re-invokes.

## Multi-section mode (optional)

If the user asks to "compare everything" or "run the full design pass", iterate over all sections. For each:
- Run steps 3–8.
- Append the diff to a running summary.
- At the end, print a punch list of every section + its top issue (or "✓ matches" if clean).

This is heavier — only do it when explicitly requested.

## Common pitfalls

- **Rushing.** The skill has no deadline. If you're tempted to wrap up early, drill in further instead — take a tighter screenshot, sample another element, re-read the reference at native resolution. Confidence comes from extra evidence, not from cutting it short.
- **"Looks fine" without reading the images and computed styles.** This is the #1 failure mode. The investigation produces evidence; cite the evidence in the report. If a finding doesn't reference either a pixel observation, a computed style value, or a token, it didn't come from the investigation.
- **Granting ✓ too generously.** Default is ✗ until evidence proves ✓. "Close enough" is ✗.
- **Skipping step 3 (read design first).** When you read live and design at the same time, you skim both. Read design alone, build the mental model, *then* look at live.
- **Eyeballing colors.** Eyes are bad at distinguishing similar greys, near-blacks, and near-whites. Always use the `browser_evaluate` computed-style sample, not the screenshot, as ground truth for color.
- **Eyeballing font sizes.** Same — use `fontSize` from computed styles. 14px and 16px look identical at most viewing distances.
- **Dev server not running.** Bail early with a clear message.
- **Wrong viewport.** If the live screenshot is 1440px wide but the reference is 1280px, the diff is meaningless. Always set viewport from the manifest.
- **Animation-driven content.** Some sections have entry animations. Use `mcp__playwright__browser_wait_for` for an anchor word, or sleep 800ms before screenshotting.
- **Sticky header overlap.** When scrolling to an anchor, the sticky nav can cover the section top. Prefer element-screenshot mode when an anchor exists; don't claim "missing heading" when it's just hidden under the nav.
- **Designs intentionally differ between desktop and mobile.** Don't flag desktop-only treatments as missing from mobile (or vice versa). Check the manifest for what's in each variant.
- **Generated/dummy content.** Live data may differ from design placeholders (a real record's name vs a made-up one). Flag the delta but don't treat it as a bug.
