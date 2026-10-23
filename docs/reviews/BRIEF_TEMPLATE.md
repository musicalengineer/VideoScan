# Codex review brief — <title>

*Copy to `.scratch/briefs/<slug>.md`, fill in, run `python3 tools/codex_review.py --title "<title>" --range <a>..<b> --brief <path>`. The brief is not committed; the verdict and closure go in the PR or commit.*

**Workflow in one sentence (the user's words):** <e.g. "move the extra copies of promoted files to the Trash">

**Range:** `<sha>..<sha>` on branch `<name>` · **Worktree:** `<abs path>`

**In scope (read these and their direct callers; nothing else):**
- `<path>` — `<functions>`
- `<path>`

**Invariants to attack** (one line each; cite `docs/DESIGN.md` §):
1. <e.g. "Prove the surviving copy exists and matches by full SHA-256 at the moment of unlink; show me a path where it doesn't.">
2.
3.

**Evidence already run:** <suites and counts; sensor lane line; red/green table reference>

**Known and accepted (do not report):** <deliberate limitations, with who accepted them>

**Output contract:**
```
Credits spent: <amount> | Finding count: <N>
Verdict: merge | fix | block — <one sentence>
```
Then findings ranked by data-loss risk, each with `file:line`, a reproduction, and a RED test where possible. For every in-scope file with nothing to report write "read, no findings." Do not explore outside the files above unless a finding requires it, and say so.
