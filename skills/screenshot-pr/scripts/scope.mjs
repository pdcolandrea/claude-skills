#!/usr/bin/env node
// Compute the screenshot scope for the current PR — generically, across repos.
//
// - Resolves the PR base (config → open PR's base ref → main/master) and diffs
//   HEAD against the merge-base.
// - Filters the diff to visual source files (config.sourceGlobs if set, else a
//   built-in visual-extension whitelist minus tests/build/vendor noise).
// - Routes: if config.routes is set, uses them verbatim (the reliable path).
//   Otherwise makes a best-effort derivation for Next.js (app/ + pages/) so the
//   common case still works zero-config; for anything else it returns [] and
//   leaves route-finding to the agent (Playwright MCP exploration).
// - Extracts framework-agnostic recognition signals (added user-visible strings
//   and non-noisy class names) so the agent can confirm the changed UI is on
//   screen before it shoots.
// - Flags changes that fall OUTSIDE the screenshotted source scope so the
//   before-snapshot caveat can be surfaced.
//
// Emits one JSON object to stdout. Errors → stderr, exit 1.

import { execSync } from 'node:child_process';
import path from 'node:path';
import { loadConfig, repoRoot } from './config.mjs';

const cfg = loadConfig();
const sh = (cmd) => execSync(cmd, { encoding: 'utf8', cwd: repoRoot }).trim();
const shSafe = (cmd) => {
  try {
    return sh(cmd);
  } catch {
    return '';
  }
};

// ─── Base resolution ─────────────────────────────────────────────────────────

function refExists(ref) {
  return shSafe(`git rev-parse --verify --quiet ${ref}`) !== '';
}

function resolveBaseBranch() {
  if (cfg.baseBranch) return cfg.baseBranch;
  // The open PR's base is the source of truth when available.
  const prBase = shSafe('gh pr view --json baseRefName -q .baseRefName 2>/dev/null');
  if (prBase) return prBase;
  for (const guess of ['main', 'master']) {
    if (refExists(`origin/${guess}`) || refExists(guess)) return guess;
  }
  return 'main';
}

const baseBranch = resolveBaseBranch();
const baseRef = refExists(`origin/${baseBranch}`) ? `origin/${baseBranch}` : baseBranch;
const baseSha = shSafe(`git merge-base ${baseRef} HEAD`) || shSafe('git rev-parse HEAD~1');
const headSha = sh('git rev-parse HEAD');
const headCommitterIso = sh('git log -1 --format=%cI HEAD');

const changedFiles = shSafe(`git diff --name-only ${baseSha}..HEAD`).split('\n').filter(Boolean);

// ─── Scope filtering ─────────────────────────────────────────────────────────

const VISUAL_EXT = /\.(tsx|jsx|ts|js|mjs|cjs|vue|svelte|astro|mdx|css|scss|sass|less)$/;

const BUILTIN_EXCLUDE = [
  /(^|\/)node_modules\//,
  /(^|\/)(dist|build|out|coverage|\.next|\.turbo|\.cache)\//,
  /(^|\/)public\//,
  /\.test\.[jt]sx?$/,
  /\.spec\.[jt]sx?$/,
  /(^|\/)__tests__\//,
  /\.stories\.[jt]sx?$/,
  /\.d\.ts$/,
  /\.config\.[jt]s$/,
];

// A trailing "/**" or "/" is treated as a path prefix; otherwise exact-ish prefix.
const normalizeGlob = (g) => g.replace(/\/\*\*$/, '/').replace(/\/$/, '') + '/';
const sourcePrefixes = (cfg.sourceGlobs ?? []).map(normalizeGlob);

const matchesSourceGlobs = (file) =>
  sourcePrefixes.length === 0 || sourcePrefixes.some((p) => (file + '/').startsWith(p) || file.startsWith(p));

const userExclude = (cfg.excludeGlobs ?? []).map((g) => g.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
const userExcludeRe = userExclude.length ? new RegExp(userExclude.join('|')) : null;

const isInScope = (file) =>
  VISUAL_EXT.test(file) &&
  !BUILTIN_EXCLUDE.some((re) => re.test(file)) &&
  !(userExcludeRe && userExcludeRe.test(file)) &&
  matchesSourceGlobs(file);

const inScopeFiles = changedFiles.filter(isInScope);

// "Cross-scope" = a changed file outside the screenshotted source scope. Only
// meaningful when sourceGlobs narrows the scope; otherwise we can't tell.
const suspectCrossScope =
  sourcePrefixes.length > 0 && changedFiles.some((f) => !matchesSourceGlobs(f));

// ─── Best-effort Next.js route derivation (fallback when no config.routes) ────

// app router: .../app/(group)/foo/page.tsx  → /foo   (groups & @parallel erased)
// pages router: .../pages/foo/bar.tsx       → /foo/bar  (index → '', _app/_doc/api skipped)
function nextRouteFromFile(rel) {
  const appMatch = rel.match(/(?:^|\/)app\/(.+)$/);
  if (appMatch) {
    const file = path.basename(appMatch[1]);
    if (!/^(page|layout)\.(tsx|jsx|ts|js)$/.test(file)) return null;
    const segs = appMatch[1].split('/').slice(0, -1).filter((s) => !s.startsWith('(') && !s.startsWith('@'));
    return '/' + segs.join('/');
  }
  const pagesMatch = rel.match(/(?:^|\/)pages\/(.+)\.(tsx|jsx|ts|js)$/);
  if (pagesMatch) {
    const p = pagesMatch[1];
    if (/^(_app|_document|_error)$/.test(path.basename(p)) || p.startsWith('api/') || p.includes('/api/')) {
      return null;
    }
    const segs = p.split('/');
    if (segs[segs.length - 1] === 'index') segs.pop();
    return '/' + segs.join('/');
  }
  return null;
}

function deriveRoutes() {
  const set = new Set();
  for (const f of inScopeFiles) {
    const r = nextRouteFromFile(f);
    if (r !== null) set.add(r === '' ? '/' : r);
  }
  return [...set].sort();
}

const routes = (cfg.routes && cfg.routes.length > 0) ? [...cfg.routes] : deriveRoutes();

// ─── Recognition extraction (framework-agnostic) ──────────────────────────────

const NOISY_CLASS_RE = new RegExp(
  '^(' +
    [
      'flex', 'grid', 'block', 'inline', 'hidden', 'relative', 'absolute', 'fixed', 'sticky',
      'items-(start|end|center|baseline|stretch)',
      'justify-(start|end|center|between|around|evenly)',
      '(gap|p|px|py|pt|pr|pb|pl|m|mx|my|mt|mr|mb|ml|space-(x|y))-\\d+',
      'w-\\w+', 'h-\\w+', 'min-w-\\w+', 'max-w-\\w+',
      'text-(xs|sm|base|lg|xl|2xl|3xl|4xl)',
      'font-(sans|serif|mono|normal|medium|semibold|bold)',
      'rounded(-\\w+)?', 'border(-\\w+)?', 'shadow(-\\w+)?',
      'overflow-\\w+', 'cursor-\\w+', 'transition(-\\w+)?', 'duration-\\d+', 'ease-\\w+',
    ].join('|') +
    ')$'
);

function extractRecognition() {
  if (inScopeFiles.length === 0) return { recognitionStrings: [], recognitionClasses: [] };
  // Diff only the in-scope files so recognition signals come from visual code.
  const pathArgs = inScopeFiles.map((f) => `'${f.replace(/'/g, `'\\''`)}'`).join(' ');
  const diff = shSafe(`git diff ${baseSha}..HEAD -- ${pathArgs}`);
  const strings = new Set();
  const classes = new Set();

  for (const line of diff.split('\n')) {
    if (!line.startsWith('+') || line.startsWith('+++')) continue;
    const added = line.slice(1);

    // JSX/template text between tags: >Hello world<
    for (const m of added.matchAll(/>\s*([A-Z][A-Za-z0-9 ,.'’?!:&-]{2,80})\s*</g)) {
      const s = m[1].trim();
      if (s && !/^\{.*\}$/.test(s)) strings.add(s);
    }
    // className / :class / class= attribute values.
    for (const m of added.matchAll(/(?:className|:class|class)\s*=\s*["'`]([^"'`]+)["'`]/g)) {
      for (const cls of m[1].split(/\s+/)) if (cls && !NOISY_CLASS_RE.test(cls)) classes.add(cls);
    }
    for (const m of added.matchAll(/\bcn\(\s*["']([^"']+)["']/g)) {
      for (const cls of m[1].split(/\s+/)) if (cls && !NOISY_CLASS_RE.test(cls)) classes.add(cls);
    }
    // User-visible copy in string literals ("Pick another day").
    for (const m of added.matchAll(/["']([A-Z][a-zA-Z][^"']{4,80})["']/g)) {
      const s = m[1];
      if (/^[A-Z][a-zA-Z][a-zA-Z .,'’!?:&-]+$/.test(s)) strings.add(s);
    }
  }

  return {
    recognitionStrings: [...strings].slice(0, 40),
    recognitionClasses: [...classes].slice(0, 40),
  };
}

const { recognitionStrings, recognitionClasses } = extractRecognition();

// ─── Emit ────────────────────────────────────────────────────────────────────

const result = {
  baseBranch,
  baseSha,
  headSha,
  headCommitterIso,
  webUrl: cfg.webUrl,
  apiUrl: cfg.apiUrl,
  viewports: cfg.viewports,
  dynamicParams: cfg.dynamicParams,
  comparison: cfg.comparison,
  maxRoutes: cfg.maxRoutes,
  configSource: cfg.configSource,
  routesFromConfig: !!(cfg.routes && cfg.routes.length > 0),
  changedFiles,
  inScopeFiles,
  routes,
  suspectCrossScope,
  recognitionStrings,
  recognitionClasses,
};

process.stdout.write(JSON.stringify(result, null, 2) + '\n');
