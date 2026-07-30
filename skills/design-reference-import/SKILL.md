---
name: design-reference-import
description: Set up a new design-reference folder for section-by-section comparison. Reads tall desktop+mobile reference PNGs, helps identify section boundaries, writes a manifest, and slices the PNGs into per-section crops. Use when the user has added a new design folder (e.g. a new screen's reference images) and wants to make it reviewable against the live site.
user-invokable: true
args:
  - name: folder
    description: Path to the design folder containing the source PNGs (e.g. design-context/landing-page). One folder per screen.
    required: true
---

# design-reference-import

Bootstraps a design-reference folder so future section-by-section comparisons against the live web app are fast and high-fidelity. This is the **setup half** of the pair — `design-reference-compare` is the runtime half.

Repo-agnostic: everything project-specific (source PNGs, live URL, token files, section boundaries) lands in the folder's `design.json`, not in this skill.

> **Script paths.** Commands below are relative to this skill's directory (`scripts/…`). Run them from the skill root, or prefix with the skill's absolute path if your harness invokes from elsewhere.

## When to use

- A new folder of design references has appeared (tall desktop PNG + tall mobile PNG, optionally HTML).
- The user wants to start reviewing implementation work section-by-section against those references.
- Run **once per design folder**. Re-run only if the source PNGs are replaced or sections need to be re-cut.

## Where design folders live

Convention: one folder per screen under a top-level `design-context/` directory (`design-context/landing-page/`, `design-context/sign-in/`, …). If the project already has a different home for reference designs, use that — the skill only cares about the folder it's pointed at.

## Why this exists

Tall reference PNGs (often 20,000+ px) get downsampled ~14x by vision when read directly, so pixel-level review is impossible. Slicing them into per-section crops at native resolution makes them readable, and a manifest pairs each slice to a live-site anchor + viewport so `design-reference-compare` can run a clean side-by-side later.

## Inputs (auto-detect, then confirm)

In the target folder, expect:

- **Desktop PNG** — width matches a desktop viewport (e.g. 1280 or 3x = 3840). Often very tall.
- **Mobile PNG** — width matches a mobile viewport (e.g. 390, or 3x = ~1170, or whatever the design tool exports — 460 is common).
- **HTML files** (optional) — Claude Design / Paper / Pencil exports. Useful for Playwright re-renders later; not required for slicing.

Detect them automatically and confirm with the user before proceeding. If only one variant exists, that's fine — record only that one in the manifest.

## Steps

### 0. Ensure prerequisites

The slicer needs Python 3 + Pillow. Check and install if missing:

```bash
python3 -c "import PIL" 2>/dev/null || pip3 install --user Pillow
```

Run this every invocation — it's a no-op if PIL is already present. macOS system Python 3.9+ usually has it; on a fresh machine the install step is one-time.

### 1. Inspect the sources

Run `file *.png` in the folder to confirm pixel dimensions. Record:

- `desktop.image` (filename), `desktop.pngWidth`, `desktop.pngHeight`, `desktop.viewportWidth` (the CSS viewport this design is for — usually 1280)
- `mobile.image`, `mobile.pngWidth`, `mobile.pngHeight`, `mobile.viewportWidth` (usually 390)

The PNG width is often 3x the viewport width (retina export). Slicer crops in PNG coordinates; viewport width is used at compare time to set the live-site viewport.

### 2. Identify section boundaries

Reading the full PNG directly is useless — vision downsamples 14×+ on tall references, so you can't tell where sections start. **Probe with 300px strips instead.**

Pick a strip interval based on PNG height (every ~1000–2000px for a 20k-tall desktop, every ~400–800px for a 7k-tall mobile). For each strip, crop a thin band and save it, then read each saved crop — at 300px tall they render at near-native resolution and headlines/section markers are clearly legible.

```bash
python3 - <<'PY'
from PIL import Image
img = Image.open('<folder>/<png>')
w, h = img.size
for y in range(0, h, 1500):   # tune step for the PNG height
    img.crop((0, y, w, min(y + 300, h))).save(f'/tmp/probe-y{y}.png')
PY
```

Then `Read` each `/tmp/probe-y*.png` and note which y-range each section starts/ends at. Repeat for both PNGs (desktop + mobile have independent boundaries).

Aim for **6–10 sections** per design — small enough to review at native resolution, big enough not to fragment a single component. Use ids that map to live-site anchors where possible (`hero`, `stats`, `how-it-works`, `comparison`, `testimonials`, `pricing`, `final-cta`, `footer`).

For each section, record both desktop and mobile y-ranges. **Mobile section count can differ from desktop** — they're independent designs. Give them the same `id` only if they're the same conceptual section; use different ids if the content genuinely differs.

**Watch for source-PNG padding.** Some exports have unused white/dark canvas past the last visible content. Probe the final ~500px of each PNG and clip the last section's height so it stops at the real bottom of the design.

### 3. Write the manifest

Write `<folder>/design.json`. Schema:

```json
{
  "name": "landing",
  "liveUrl": "http://localhost:3000",
  "route": "/",
  "devCommand": "yarn dev",
  "tokens": ["app/globals.css"],
  "sources": {
    "desktop": {
      "image": "Desktop _ 1280.png",
      "pngWidth": 3840,
      "pngHeight": 21900,
      "viewportWidth": 1280
    },
    "mobile": {
      "image": "mobile-iphone-design-full.png",
      "pngWidth": 460,
      "pngHeight": 7355,
      "viewportWidth": 390
    }
  },
  "sections": [
    {
      "id": "hero",
      "anchor": null,
      "desktop": { "y": 0, "height": 2850 },
      "mobile":  { "y": 0, "height": 1000 }
    },
    {
      "id": "how-it-works",
      "anchor": "#how-it-works",
      "desktop": { "y": 3900, "height": 3300 },
      "mobile":  { "y": 1300, "height": 1800 }
    }
  ]
}
```

Notes on the schema:

- `liveUrl` — base URL of the live site for compare-time screenshots. Optional; defaults to `http://localhost:3000`.
- `route` — path this design covers, appended to `liveUrl` at compare time (e.g. `/`, `/pricing`, `/marcus/book`). Optional; defaults to `/`.
- `devCommand` — the project's command to start that server, quoted back to the user when it isn't running. Optional but worth filling in — saves the compare step guessing.
- `tokens` — repo-relative paths to the design-token sources every live color/font must trace back to (a Tailwind `globals.css`, a theme file, a tokens JSON). Optional; compare auto-detects when absent, so set it whenever the project's tokens live somewhere non-obvious.
- `anchor` — CSS selector or `#id` that exists on the live site for this section. `null` if there isn't one (compare will use scroll-y instead).
- `desktop.y`/`mobile.y` — top of the crop in PNG pixels.
- `desktop.height`/`mobile.height` — crop height in PNG pixels.
- The crop spans the full PNG width; no `x`/`width` needed.

### 4. Run the slicer

```bash
python3 scripts/slice.py <folder>
```

This:
- Reads `<folder>/design.json`.
- For each section × variant, crops the source PNG into `<folder>/sections/{desktop,mobile}/<NN>-<id>.png` using PIL (`img.crop((0, y, width, y+height))` — top-left anchored).
- Logs each crop with its dimensions.

**Do not switch to `sips`.** `sips --cropOffset Y X --cropToHeightWidth H W` does centered cropping — `--cropOffset 0 0` crops the middle of the image, not the top-left. This bit us before; PIL avoids it.

### 5. Sanity-check the slices

Read 2–3 of the generated section crops. They should be:
- Readable at native resolution (no aggressive downsampling).
- Clean cuts — no half-rendered sections at top or bottom.

If a section is cut wrong, edit the manifest and re-run the slicer. Slices overwrite cleanly.

### 6. Ignore the slices in git

Sections are regenerable from `design.json` + the source PNGs, and they can be large. Add `<folder>/sections/` to the project's `.gitignore` (or to a `.gitignore` inside the folder).

The manifest **is** committed — it's the source of truth for what each section means.

## Done state

- `<folder>/design.json` exists and matches the actual PNG dimensions.
- `<folder>/sections/desktop/*.png` and `<folder>/sections/mobile/*.png` are populated.
- Each section crop is readable at near-native resolution.
- `<folder>/sections/` is gitignored.
- Tell the user the design is ready to use with `design-reference-compare`.

## Common pitfalls

- **Section heights too tall.** If a single slice is over ~3000px tall, it'll still get downsampled when read. Split into two sections.
- **Wrong PNG width.** If you record `pngWidth: 1280` but the file is actually 3840, the crop coordinates will be off by 3x. Always run `file <png>` to confirm.
- **Desktop and mobile section ids drift.** That's OK — they're separate designs. `compare` will handle missing variants gracefully.
- **Don't slice from HTML.** Use the PNG. HTML rendering is for a future compare-mode feature, not for source-of-truth slicing.
