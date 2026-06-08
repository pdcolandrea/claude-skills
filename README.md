# pdcolandrea-skills

A [Claude Code](https://claude.com/claude-code) plugin marketplace of skills I use
day to day. Add the marketplace once, then install any skill below.

## Install

In a Claude Code session:

```
/plugin marketplace add pdcolandrea/claude-skills
/plugin install codex-review@pdcolandrea-skills
```

Or from the shell:

```bash
claude plugin marketplace add pdcolandrea/claude-skills
claude plugin install codex-review@pdcolandrea-skills
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
