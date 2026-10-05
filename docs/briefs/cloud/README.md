# Cloud review sessions — standing rules (every brief inherits these)

Program: `docs/briefs/cloud-credit-review-program-2026-10-05.md`. Ledger:
`docs/reviews/cloud/LEDGER.md`.

You are a Claude Code **cloud session on Linux**. You have no Xcode, no Apple
frameworks, no media, no App Support and no local volumes. Read the code;
do not try to build the app.

1. **Read only the files your brief names**, plus any callee you must follow
   to settle a finding (say which callees you followed in the report). Do not
   explore elsewhere. If the scope looks wrong, say so in the report; do not widen it.
2. **Never change source, tests or project files.** Your only output is ONE
   report file at the path your brief gives.
3. Commit the report on a branch named `cloud/<brief-id>` and push that branch.
   Never push to `main`. Never open a PR.
4. **Report header (first lines, exact shape):**
   ```
   Brief: <id> | Source: main@<sha> | Wall clock: <min> | Files read: <n>
   Finding count: <n> (REAL <a> / NEEDS-MAC <b> / NOISE <c>)
   Verdict: <one sentence>
   ```
5. **Every finding:** ID (`<brief-id>-F<n>`), severity P1–P3, class
   REAL / NEEDS-MAC / NOISE, **symbol** (type.function, the stable key) and
   file:line, the concrete failing scenario (inputs/state → wrong result),
   and the smallest pinning test that would fail today. P1 means a family file,
   the archive or the family record can be lost or corrupted.
6. **Hard to refute, or it goes.** For each finding, before you write it,
   look for the guard that would make it false: callers, a lock held one level up,
   a fail-closed check at the removal boundary. Many of these paths have had
   five codex rounds. If you cannot name the concrete scenario, mark it NOISE
   or leave it out. Twenty plausible findings are worth less than one true one.
7. **Time box: about 45 minutes.** If scope is bigger than that, go by the
   brief's priority order and list what you did not reach under "Not covered".
8. Plain words: no media paths, family names or filenames from fixtures in the report.
