#!/usr/bin/env node
// Emit a Playwright init-script that freezes time, animation, and motion.
//
// The skill calls this with the pinned ISO date and the file is then
// passed to Playwright via `page.addInitScript` (or via the MCP equivalent
// — `browser_evaluate` immediately after navigation if init scripts aren't
// available). Writing it as a real file means the agent can inspect/debug
// the exact init payload between runs.
//
// Usage:
//   node freeze.mjs <iso-date> > /tmp/screenshot-pr-init.js
//   then: page.addInitScript({ path: '/tmp/screenshot-pr-init.js' })
// or:
//   evaluate the contents inside the page after navigation

const isoDate = process.argv[2];
if (!isoDate || Number.isNaN(Date.parse(isoDate))) {
  process.stderr.write(`usage: freeze.mjs <iso-date>\n`);
  process.exit(1);
}

const ms = Date.parse(isoDate);

const script = `
(() => {
  // Pin Date so dynamic UI (time slots, "today" labels) renders deterministically.
  // Both before and after passes use the same pinned moment so pairs are comparable.
  const PINNED_MS = ${ms};
  const RealDate = Date;
  class FrozenDate extends RealDate {
    constructor(...args) {
      if (args.length === 0) return new RealDate(PINNED_MS);
      return new RealDate(...args);
    }
    static now() {
      return PINNED_MS;
    }
  }
  Object.setPrototypeOf(FrozenDate, RealDate);
  Object.defineProperty(globalThis, 'Date', { value: FrozenDate, configurable: true, writable: true });
  performance.now = (origin => () => 0)(performance.now);

  // Kill all CSS animations and transitions. This handles Tailwind 'animate-*',
  // Framer Motion (which writes inline transition styles — they get overridden
  // by the !important rules), and bare CSS transitions equally.
  const inject = () => {
    if (document.getElementById('__screenshot_pr_no_motion')) return;
    const style = document.createElement('style');
    style.id = '__screenshot_pr_no_motion';
    style.textContent = \`
      *, *::before, *::after {
        animation-duration: 0s !important;
        animation-delay: 0s !important;
        animation-iteration-count: 1 !important;
        transition-duration: 0s !important;
        transition-delay: 0s !important;
        scroll-behavior: auto !important;
        caret-color: transparent !important;
      }
      html { scroll-behavior: auto !important; }
    \`;
    (document.head ?? document.documentElement).appendChild(style);
  };
  if (document.head) inject();
  else new MutationObserver((_, obs) => {
    if (document.head) {
      inject();
      obs.disconnect();
    }
  }).observe(document.documentElement, { childList: true });
})();
`;

process.stdout.write(script);
