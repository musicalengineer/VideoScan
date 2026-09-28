---
name: safety-critical
description: Safety-critical mode for changes that can lose, move, rewrite or misfile family media or its records (the Master Archive / FamilyArchive, the 00_Index manifest and journals, the media ledger, delete/trash/prune, fixity, resume/recovery, anything that writes a user's curated data). Invoke with /safety-critical before designing or changing such code. Not for UI polish, wording, ranking heuristics or docs.
---

# Safety-critical mode

Rick's rule of thumb (2026-09-27): **the simple, elegant design is easier to
implement, test and maintain.** Some things are just hard, and
improve-by-iteration is how you find the elegant version. Good design balances
elegance and practicality. This mode exists because both halves matter: the
rigor below is right for data-risk code, and it must be spent on the smallest
design that does the job.

## Part 1 — Simplify first (before any hardening)

1. **Say the workflow in one sentence, in the user's words.** Example: "change
   the name or date of one archived file." Write it at the top of the branch's
   first commit message and of the codex brief.
2. **Cut everything the sentence doesn't need.** Side effects on other
   records, crash-recovery replay, cleverness "while we're here" all go. If it
   seems needed, ask Rick in one question before building it.
3. **One editor, one writer.** Two sheets editing the same item is an
   unhealthy workflow; refuse the second ("This item is being edited") rather
   than reconcile afterwards.
4. **Archived means fixed.** Background jobs never write an archived record's
   name or date; they may add metadata. Only the user changes them, through
   Update….
5. **Re-scope when reviews drift.** If two review rounds in a row land their
   findings in machinery the sentence didn't require, stop and propose a
   smaller design (lesson: Refile, 6 codex rounds → Update…, −41% lines).

## Part 2 — Then harden what's left

- **Red first.** Every fix has a pinning test shown failing before the fix (or
  red by mutation when the red needs a new seam). Report executed counts;
  `-only-testing` filters by SUITE, never by method.
- **Refuse before mutating.** Every check that can say no (target exists,
  volume read-only/offline, fixity mismatch, lock busy, guard) runs before
  the first write.
- **Move, never copy + delete, on the same volume.** No-clobber rename
  (`renameatx_np` / `renamex_np` with `RENAME_EXCL`). Verify identity (device +
  inode + size) and the digest after.
- **Backups outlive doubt.** Take the backup under the archive lock; keep it
  unless the outcome is *proven* safe. Unknown means keep.
- **Name every outcome.** success / refused / rolledBack / mixedState (say
  where the file is) / incompleteRecovery. Each one has a test, and none is
  reported as success.
- **Log like an auditor.** START and OUTCOME lines, old → new per field, where
  the change lives on disk, and how to revert. Written to the console,
  catalog.log and videoscan.log through one sink, plus a ledger event.
- **Five test dimensions** (CLAUDE.md): logic, scale (100k, budget, nothing
  O(records) in view bodies), media matrix, isolation (poisoned state), sensor.
- **Scoped codex review** through `python3 tools/codex_review.py`. The brief
  names the exact files and the invariants to attack, and ends "do not explore
  outside these files". Each finding is closed by a pinning test or declined
  in the review doc with a reason. Stop the loop when findings drop to P2 or
  lower and the core path is covered; file what's left.
- **Reviewer budget (Rick 2026-09-27).** Codex (independent model family) is
  the data-risk reviewer. The in-house `qa` agent (same family as Claude,
  fresh context, ~50–150k tokens a pass) is a first pass only when the change
  is big, and the stand-in when codex is out of credits or unavailable — not
  both by default. Routine work: tests + Rick's spot test, no review.
- **Nothing deletes overnight** except scratch (see the rm allow/deny list in
  `.claude/settings.json`).

## Output of this mode

Before writing code, post (to Rick, briefly): the one-sentence workflow, what
was cut, the outcomes table, and the invariants codex will attack. Then build.
