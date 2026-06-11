#!/usr/bin/env node
// Load + normalize the per-repo screenshot-pr config.
//
// This is the single seam that makes the skill generic: every repo-specific
// value (dev-server URL, routes, source globs, dynamic-segment fills, viewports)
// lives here, sourced from an OPTIONAL config file so nothing is hardwired.
//
// Config file (all keys optional) — first found wins:
//   .screenshot-pr.json
//   .claude/screenshot-pr.json
//   .config/screenshot-pr.json
//
// Env overrides (highest precedence): SCREENSHOT_PR_WEB_URL, SCREENSHOT_PR_API_URL.
//
// Usage:
//   node config.mjs            # prints the normalized config as JSON
//   node config.mjs --shell    # prints `KEY='value'` lines for `eval` in bash
//   import { loadConfig, repoRoot } from './config.mjs'

import { execSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';

export const repoRoot = execSync('git rev-parse --show-toplevel', {
  encoding: 'utf8',
}).trim();

const DEFAULTS = {
  // Dev server the running app is served from. Override per-repo.
  webUrl: 'http://localhost:3000',
  // Optional companion API the app needs to render. null = don't gate on it.
  apiUrl: null,
  // Explicit routes to screenshot. When non-empty, route auto-derivation is
  // skipped entirely — this is the reliable, framework-agnostic path.
  routes: [],
  // Fills for dynamic URL segments, e.g. { "[slug]": "marcus-johnson" }.
  dynamicParams: {},
  // Viewports captured for every route. [width, height].
  viewports: { desktop: [1280, 900], mobile: [390, 844] },
  // Path prefixes that count as "the app's visual source". When set, the diff
  // scope and the before-checkout are limited to these (good for monorepos so
  // an API change doesn't get reverted). Empty = whole repo, visual files only.
  sourceGlobs: [],
  // Extra path substrings to exclude from scope on top of the built-in list.
  excludeGlobs: [],
  // "both" = before + after side-by-side. "after" = current state only.
  comparison: 'both',
  // Override PR base detection. null = infer from the open PR, then main/master.
  baseBranch: null,
  // Hard cap on routes before the skill stops and asks the user to narrow.
  maxRoutes: 5,
};

const CONFIG_PATHS = [
  '.screenshot-pr.json',
  '.claude/screenshot-pr.json',
  '.config/screenshot-pr.json',
];

function readConfigFile() {
  for (const rel of CONFIG_PATHS) {
    const abs = path.join(repoRoot, rel);
    if (fs.existsSync(abs)) {
      try {
        return { source: rel, data: JSON.parse(fs.readFileSync(abs, 'utf8')) };
      } catch (err) {
        process.stderr.write(`screenshot-pr: failed to parse ${rel}: ${err.message}\n`);
        process.exit(1);
      }
    }
  }
  return { source: null, data: {} };
}

export function loadConfig() {
  const { source, data } = readConfigFile();
  const cfg = { ...DEFAULTS, ...data };
  // Deep-merge the object-valued keys so partial overrides keep the defaults.
  cfg.viewports = { ...DEFAULTS.viewports, ...(data.viewports ?? {}) };
  cfg.dynamicParams = { ...DEFAULTS.dynamicParams, ...(data.dynamicParams ?? {}) };

  // Env overrides win over the file.
  if (process.env.SCREENSHOT_PR_WEB_URL) cfg.webUrl = process.env.SCREENSHOT_PR_WEB_URL;
  if (process.env.SCREENSHOT_PR_API_URL) cfg.apiUrl = process.env.SCREENSHOT_PR_API_URL;

  cfg.configSource = source;
  return cfg;
}

// ─── CLI ─────────────────────────────────────────────────────────────────────

const invokedDirectly = path.resolve(process.argv[1] ?? '') === path.resolve(new URL(import.meta.url).pathname);

if (invokedDirectly) {
  const cfg = loadConfig();
  if (process.argv.includes('--shell')) {
    const esc = (v) => `'${String(v).replace(/'/g, `'\\''`)}'`;
    process.stdout.write(`SCREENSHOT_PR_WEB_URL=${esc(cfg.webUrl)}\n`);
    process.stdout.write(`SCREENSHOT_PR_API_URL=${esc(cfg.apiUrl ?? '')}\n`);
    process.stdout.write(`SCREENSHOT_PR_COMPARISON=${esc(cfg.comparison)}\n`);
    process.stdout.write(`SCREENSHOT_PR_CONFIG_SOURCE=${esc(cfg.configSource ?? '')}\n`);
  } else {
    process.stdout.write(JSON.stringify(cfg, null, 2) + '\n');
  }
}
