# VideoScan — agent instructions

Every agent in this repository (Claude, Codex, anything else) follows one rulebook: **`CLAUDE.md`**. Read it first, then `docs/ARCHITECTURE.md`, `docs/STATUS.md`, `docs/PROCESS.md`.

## Codex-specific
- Your role is the **independent adversarial reviewer** for data-risk code, and a test author when asked. You review Claude's changes; you do not start feature work on your own.
- Stay inside the brief: the named SHA range, files and invariants. Read the named files and their direct callers; run the named tests; do not explore the wider repo unless a finding requires it (say so in the verdict).
- Report findings as claims with `file:line`, a reproduction, and where possible the RED test that demonstrates it, ranked by data-loss risk. Silence on a scoped file is a verdict: write "read, no findings."
- Output contract, first line and one more line: `Credits spent: <amount> | Finding count: <N>` · `Verdict: merge | fix | block — <one sentence>`.
- Permissions profile: `.codex/config.toml` (`videoscan-dev`). Never `git push`, never delete, never touch `~/dev/VideoScan`'s branch; work in the worktree you are given.
