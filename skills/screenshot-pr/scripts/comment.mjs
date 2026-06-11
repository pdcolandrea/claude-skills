#!/usr/bin/env node
// Render the PR-comment markdown body from a manifest of captures plus
// the URL map emitted by upload.sh. The skill handles the actual
// posting via `gh api` (POST for new, PATCH for existing) using the
// comment signature `<!-- screenshot-pr v1 -->` to find/replace.
//
// Usage:
//   node comment.mjs <manifest.json> <urls.json> > body.md
//
// manifest.json shape:
//   {
//     "prNumber": 72,
//     "updatedIso": "2026-05-18T19:30:00Z",
//     "captures": [
//       {
//         "route": "/[slug]",
//         "scenario": "default",
//         "viewports": {
//           "desktop": { "beforeRel": "before/...", "afterRel": "after/..." },
//           "mobile":  { "beforeRel": "before/...", "afterRel": "after/..." }
//         }
//       }
//     ],
//     "gaps": [
//       { "route": "/dashboard/settings", "scenario": "default", "viewport": "desktop",
//         "actionsTried": ["navigate", "click .nav-notifications"],
//         "hypothesis": "scenario should start on the Notifications tab" }
//     ],
//     "suspectCrossPackage": false,
//     "newOnBranch": [
//       { "route": "/foo", "scenario": "default", "viewport": "desktop" }
//     ]
//   }
//
// urls.json: { "before/foo.png": "https://github.com/user-attachments/assets/...", ... }

import fs from 'node:fs';

const [, , manifestPath, urlsPath] = process.argv;
if (!manifestPath || !urlsPath) {
  process.stderr.write('usage: comment.mjs <manifest.json> <urls.json>\n');
  process.exit(1);
}

const manifest = JSON.parse(fs.readFileSync(manifestPath, 'utf8'));
const urls = JSON.parse(fs.readFileSync(urlsPath, 'utf8'));

const urlFor = (rel) => (rel ? urls[rel] : null);

const isNewOnBranch = (route, scenario, viewport) =>
  (manifest.newOnBranch ?? []).some(
    (n) => n.route === route && n.scenario === scenario && n.viewport === viewport
  );

const cellFor = (viewports, key, side, route, scenario) => {
  const v = viewports[key];
  if (!v) return '—';
  const rel = side === 'before' ? v.beforeRel : v.afterRel;
  const url = urlFor(rel);
  if (url) return `![${side}-${key}](${url})`;
  if (side === 'before' && isNewOnBranch(route, scenario, key)) return '*(new on branch)*';
  return '—';
};

const lines = [];
lines.push('<!-- screenshot-pr v1 -->');
lines.push(`## 🖼 Screenshots — updated ${manifest.updatedIso} UTC`);
lines.push('');

if (manifest.captures.length === 0) {
  lines.push('_No captures produced. See the gap list below._');
  lines.push('');
} else {
  for (const cap of manifest.captures) {
    lines.push(`### \`${cap.route}\` — ${cap.scenario}`);
    lines.push('');
    lines.push('|         | desktop | mobile-web |');
    lines.push('|---------|---------|------------|');
    lines.push(
      '| before  | ' +
        cellFor(cap.viewports, 'desktop', 'before', cap.route, cap.scenario) +
        ' | ' +
        cellFor(cap.viewports, 'mobile', 'before', cap.route, cap.scenario) +
        ' |'
    );
    lines.push(
      '| after   | ' +
        cellFor(cap.viewports, 'desktop', 'after', cap.route, cap.scenario) +
        ' | ' +
        cellFor(cap.viewports, 'mobile', 'after', cap.route, cap.scenario) +
        ' |'
    );
    lines.push('');
  }
}

if (manifest.gaps && manifest.gaps.length > 0) {
  lines.push(`### ⚠ Gaps (${manifest.gaps.length})`);
  lines.push('');
  for (const g of manifest.gaps) {
    lines.push(
      `- \`${g.route}\` (${g.viewport}, ${g.scenario}): could not reveal target after ${g.actionsTried.length} action(s).`
    );
    if (g.actionsTried.length > 0) {
      lines.push(`  Tried: ${g.actionsTried.map((a) => `\`${a}\``).join(' → ')}`);
    }
    if (g.hypothesis) {
      lines.push(`  *Likely fix:* ${g.hypothesis}`);
    }
  }
  lines.push('');
}

if (manifest.suspectCrossScope ?? manifest.suspectCrossPackage) {
  lines.push('### ⚠ Out-of-scope changes detected');
  lines.push('');
  lines.push(
    'Files outside the screenshotted source scope changed between base and HEAD. The ' +
      'before-snapshot was rendered with only the in-scope source reverted to the base ' +
      'commit, so it may not reflect the base commit\'s true render. Treat the before ' +
      'column as advisory.'
  );
  lines.push('');
}

process.stdout.write(lines.join('\n') + '\n');
