---
name: orchestrator
description: Chooses which model runs a delegated task (subagent, parallel fan-out, or Workflow stage) and how to invoke it. Use whenever spawning agents with the Agent tool, authoring or running a Workflow, delegating to a subagent, dispatching bulk/mechanical work, requesting a review, or otherwise deciding which model should do a piece of work. Trigger on "which model", "spin up agents", "fan out", "run a workflow", "delegate this", "have gpt/codex/fable/opus do X".
---

# Orchestrator — model routing

Pick the model **per task**, not per session. You are the orchestrator; the model
you assign to a subagent/stage is a first-class decision. Route by the table
below, then invoke via the mechanics section.

## Roster (higher = better on every axis)

| Model       | Cost | Intelligence | Taste | Invoke as                          |
| ----------- | ---- | ------------ | ----- | ---------------------------------- |
| gpt-5.6-sol | 8    | 9            | 7     | codex plugin — the codex model     |
| fable-5     | 2    | 9            | 9     | `model: "fable"`                   |
| opus-5      | 4    | 7            | 8     | `model: "opus"`                    |
| sonnet-5    | 5    | 5            | 7     | `model: "sonnet"`                  |

**Cost = what I actually pay** (OpenAI's limits are generous, so the codex model
is effectively the cheapest thing on the board). Never use Haiku.

**One codex model.** `gpt-5.6-sol` ("sol") is *the* codex pick — the `model` set
in `~/.codex/config.toml`, so an unqualified codex call is sol. Intel 9 and taste
7 mean it clears the user-facing gate, so there is no cheaper-but-dumber codex
tier to fall back to: when sol isn't right for a task, the answer is a *smarter*
model, not a cheaper one.

## Route by task shape

| The task is…                                             | Send it to                                              |
| -------------------------------------------------------- | ------------------------------------------------------- |
| Bulk / mechanical / clear-spec impl, migrations, data    | **gpt-5.6-sol** — the codex workhorse for delegated bulk; token-efficient, smart enough |
| User-facing: UI, UX, copy, API design (needs taste ≥ 7)  | **fable-5** (best taste) or **opus-5**; **gpt-5.6-sol** clears the gate (taste 7) as the cheaper option for lighter UI/copy |
| Hardest unsupervised reasoning (fuzzy spec, deep debug)  | **fable-5** or **gpt-5.6-sol** (both intel 9)            |
| Review of a plan or implementation                       | **fable-5** or **opus-5**; add a **codex** (sol) pass for an independent 2nd read |
| Anything else / catch-all                                | **opus-5**                                              |

## Decision rules

- **Defaults, not limits.** You have standing permission to escalate: if a
  cheaper model's output misses the bar, rerun or redo it on a smarter model
  **without asking**. Judge the output, not the price tag — escalating costs less
  than shipping mediocre work.
- **When axes conflict for anything that ships: intelligence > taste > cost.**
  Cost is a tie-breaker only.
- **Taste gate:** never route user-facing work (UI/copy/API design) below taste 7.
  Everything in the roster clears it today — the gate is there so a cheaper model
  added later can't quietly take UI work.
- **Reviews want a second, independent perspective.** A fable/opus review plus a
  **codex** pass catches more than either alone.

## Invocation mechanics

**Claude models (fable-5, opus-5, sonnet-5)** — pass `model` on the call:

- `Agent` tool: `subagent_type` + `model: "fable" | "opus" | "sonnet"`.
- `Workflow`: `agent(prompt, { model: "fable", ... })`, or `model` on a phase.

**codex → the codex plugin** (do NOT hand-roll bash wrappers; use the plugin).
The plugin runs whatever `model` is set in `~/.codex/config.toml` — **`gpt-5.6-sol`**
— so every codex call is sol and no `-m` override is needed.

- `/codex:review [--base <ref>]` — read-only quality assessment / branch review.
- `/codex:adversarial-review <focus>` — skeptical design review (auth, tradeoffs,
  reliability); append focus text to steer it.
- `/codex:rescue` — subcontract active debugging, multi-file refactor, or an
  implementation loop when a second pass is needed.
- Async: `/codex:status`, `/codex:result`, `/codex:cancel` (with `--background`).
- Inside a **Workflow/subagent**, delegate codex work via the
  `codex:codex-rescue` agent type or the plugin's native slash commands /
  `codex-cli-runtime` skills — never raw terminal wrappers.
- **Fallback:** if the codex CLI/plugin isn't installed in this project, substitute
  a **fable-5** (or **opus-5**) agent for the codex slot and note the swap.

## Closed-loop QA (optional)

Keep the review gate on with `/codex:setup --enable-review-gate` — a stop hook
challenges Claude's output with Codex before finalizing, so broken code or weak
assumptions don't reach the main session unvetted.

## Worked example — a 3-stage feature

1. **Plan** the change → **opus-5** (or fable-5) subagent.
2. **Implement** the clear-spec pieces in parallel → **gpt-5.6-sol** via
   `/codex:rescue` or `codex:codex-rescue` agents.
3. **Review** the diff → **fable-5** agent + a **codex** `/codex:review` pass;
   reconcile both. Escalate any rejected fix to a smarter model rather than
   patching blind.

---

> **Credit:** the model-routing rubric — scoring delegatable work on cost,
> intelligence, and taste, and routing each task to the cheapest model that clears
> the bar — is adapted from Theo Browne ([@t3dotgg](https://github.com/t3dotgg)).
