# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

> Merged from two real, sourced files: the **Karpathy four rules**
> (`multica-ai/andrej-karpathy-skills` — the mindset layer) and **Boris Cherny's
> operational setup** (`0xquinto/bcherny-claude`, transcribed from his Threads/X tips —
> the mechanics layer). Treat this file as a prompt: keep it terse, delete what goes
> stale, and update it whenever Claude makes a mistake.

## Project

`Cleanitup` — TODO: one sentence on what this does. (No code exists here yet.)

---

## Operating principles — the four rules (Karpathy)

Apply these on every task, before and while writing code.

1. **Think Before Coding** — State your assumptions explicitly. If uncertain, ask.
   Surface confusion and tradeoffs; never make a silent decision.
2. **Simplicity First** — Minimum code that solves the problem. Nothing speculative.
   No unnecessary abstractions, no unrequested features.
3. **Surgical Changes** — Touch only what you must. Clean up only your own mess.
   Preserve surrounding style; don't refactor unrelated code unless asked.
4. **Goal-Driven Execution** — Define success criteria, then loop until verified.
   Turn vague tasks into measurable objectives with explicit verification steps.

> Bias toward caution over speed. Success = fewer unnecessary diffs, fewer rewrites from
> overcomplication, and clarifying questions asked *before* implementation.

---

## Workflow (Boris)

### Verification loop — 2–3x quality
1. Make changes  →  2. Typecheck  →  3. Run tests  →  4. Lint  →
5. Before any PR: full lint + test suite. Never commit without tests passing first.

### Plan mode
- Start every complex task in plan mode (shift+tab to cycle). Pour energy into the plan
  so the implementation 1-shots.
- When something goes sideways, switch **back** to plan mode and re-plan. Don't keep
  pushing a bad path.
- Use plan mode for the verification step too, not just the build.

### Auto mode
- Boris's #1 tip: run in **auto mode** (no permission prompts) — cycle with shift+tab
  (default → auto-accept → plan).
- It's the building block for *multi-clauding*: let one session run unattended while you
  work another in parallel.
- Keep guardrails when unattended: scoped allow-lists in `.claude/settings.json`,
  worktrees for isolation, and a `Stop` hook to nudge the session onward.
- Make it sticky via `defaultMode` in `.claude/settings.json`.

### Parallel work
- Offload individual tasks to **subagents** to keep the main context window clean.
- Only one agent edits a given file at a time.
- For fully parallel workstreams use git worktrees:
  `git worktree add .claude/worktrees/<name> origin/main`

### Automation & sessions
- `/loop <interval> <skill>` for recurring runs; `/schedule` for cron (up to a week).
  Turn repetitive workflows into skills, then loop them.
- `/branch` (or `claude --resume <id> --fork-session`) to fork; `/btw` for side queries;
  `/teleport` to continue a cloud session locally.
- `--add-dir` / `"additionalDirectories"` in settings.json for multi-repo work.

---

## Code style & conventions

- **TypeScript:** prefer `type` over `interface`; never use `enum` (use string-literal
  unions); never use `any` without explicit approval.
- Descriptive names. Small, focused functions. Tests for new functionality.
- Handle errors explicitly — never swallow them.
- TODO: pin language/formatter specifics once the stack is chosen.

## Things Claude should NOT do
- Don't skip error handling or commit without passing tests.
- Don't make breaking API changes without discussion.
- Don't refactor unrelated code while doing something else (see rule 3).
- TODO: append real mistakes here as they happen, so they aren't repeated.

## Commands

TODO — fill once tooling exists; keep only commands you actually run:

```sh
# typecheck   TODO
# test        TODO
# test (one)  TODO   ← add the single-test command early
# lint        TODO
# format      TODO
```

---

## Self-improvement (Boris)

This file is a living prompt, not documentation. After every correction, add a one-line
rule so the mistake isn't repeated — end corrections with *"Now update CLAUDE.md so you
don't make that mistake again."* Keep iterating until the mistake rate measurably drops.
When a line stops mattering, delete it: shorter is better.
