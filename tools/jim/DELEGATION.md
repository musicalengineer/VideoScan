# Delegating to Jim (orchestrator policy)

This is the contract Claude/Codex follow when handing work to the local gofer. It is
**additive** to `.claude/agents/MANAGER.md` — reference it, don't duplicate it there.

Jim is **not** a native Claude/Codex subagent. He is an external local model reached
through a shell helper. Delegation is a deliberate policy, not automatic: you decide
when a task is Jim-shaped, hand it off, and **verify the result before using it**.

## How to hand off
```bash
tools/jim/bin/jim "<one bounded task, with all needed context inline>"
# or pipe larger context:
cat some.diff | tools/jim/bin/jim "Draft a one-line commit message for this diff"
# hard task Jim bounced? escalate to the cloud brain:
tools/jim/bin/jim --escalate "<task>"
```

## Delegate to Jim when the task is ALL of:
- **Bounded** — fully specified, all needed context fits in the prompt.
- **Verifiable** — you can cheaply check the output is right.
- **Low-stakes** — a wrong answer costs seconds, not data or a regression.
- **High-volume / grunt** — the kind of chore that otherwise burns your own budget.

Good: commit-message drafts, release-note lines, summarizing a channel message or an
ffprobe blob, classifying a provided file list, extracting TODOs, boilerplate test stubs.

## Do NOT delegate to Jim:
- Architecture, concurrency, or design reasoning.
- Anything needing repo-wide context, the running app, or files not in the prompt.
- Anything irreversible or security-sensitive.
Those stay with Claude/Codex (or `--escalate` to the cloud brain for the borderline-hard ones).

## The verifier contract (non-negotiable)
1. **Never apply Jim's output unverified.** Read it; confirm it does exactly the task.
2. If Jim returns `ESCALATE: ...` or `INSUFFICIENT CONTEXT: ...`, either supply what he
   needs and retry, run it yourself, or `--escalate`. Do not browbeat a small model into
   guessing — that is exactly how the previous gofer (Fred) failed.
3. Treat Jim's output as a **draft from a junior**, not as ground truth.

## Cost & privacy
- Local Jim = free, private, no rate limits. Prefer him for bulk.
- `--escalate` = Ollama Cloud: rate-limited (free tier) and **prompts leave the machine** —
  never escalate anything you would not put in a third-party API.
