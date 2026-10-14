# Codex review — Cleanup v1 r2

- Range: `e5d39127..02de09be`
- Credits spent: unavailable (billing telemetry not exposed)
- Tokens: 111484
- Finding count: 3
- Verdict: fix — F1 still permits loss of the last outside-Trash copy during proof; F3 and F5 retain the narrower P2 gaps described above.
- Run: 2026-10-12T19:32:58Z (cycle #69, tools/codex_review.py)

## Codex answer

Credits spent: unavailable (billing telemetry not exposed) | Finding count: 3

Reviewed `e5d39127..02de09be` at `02de09be`. No files written. Tests inspected, not executed.

- **F1 — `94e59dad`: partially closed; P1 remains.** `CleanupProof.swift:61` implements the required ancestry checks, called for both copy paths at `:84` and junk at `:182`. This closes the reported **before-execution** substitutions. However, copies check ancestry only **before the full reads**; the final keeper check at `:101` compares file identity only.

  Reproduction: in `betweenReadsForTesting`, move the keeper’s **parent directory** into `.Trashes/501/`, then replace its old location with a directory symlink. Moving the parent preserves the child’s inode, size, timestamps and volume UUID. The target read succeeds, the keeper’s final identity comparison follows the symlink and matches, and `:104` returns proven. Cleanup can therefore trash the last outside-Trash copy.

  **Smallest fix:** repeat `ancestryProblem` for both paths after the reads, immediately before returning proven; add this directory-move case using the existing between-reads seam. This change occurs **before proof completes**, distinct from the excluded proof→Trash window.

- **F2 — `5ed941f8`: closed for the reported volume-swap cases.** `CleanupProof.swift:111` requires the planned UUID and persistent-identity comparison; keeper and target reach it at `:91` and `:124`. Missing external junk requires the original UUID at `:198`; `CleanupDiskProbe.swift:56` checks the mounted volume. Absent, substituted and unidentified external volumes hold.

- **F3 — `fc83301e`: partially closed, P2:** every active row is visited (`CleanupPlan.swift:330`), but symlink-traversing aliases lose their identity at `CleanupDiskProbe.swift:34` and never enter the index (`CleanupPlan.swift:333`); a canonical target plus an unhashed alias through a linked directory still permits trashing the target and leaves the alias active—retain resolved identity for indexing while excluding the alias from selection.

- **F4 — `6d11f06a`: closed.** `CleanupTrashJob.swift:223`, `:549`, `:552` and `:558` assign the final subtitle before terminal state publication; `CleanupPane.swift:100` consequently captures the final summary.

- **F5 — `9e61c4e0`: partially closed, P2:** settled totals now count actual reads once, but `CleanupTrashJob.swift:510` can sample in-flight bytes immediately before `CleanupProof.swift:156` resets/transfers them, then read the incremented ledger at `CleanupTrashJob.swift:513`, double-counting that read for a progress update; make counter transfer and combined snapshot atomic, or use one cumulative counter.

- **F6 — `28a4fa1d`: closed.** Returned engine outcomes are consumed at `CleanupTrashJob.swift:317`; the insertion guard at `:486` prevents callback/result double settlement, including receipt entries.

- **F7 — `bbdbdd4d`: closed.** `CleanupPlan.swift:208` computes totals and sorted reasons once, invoked at `:341`; `CleanupPane.swift:277` and `:290` read those stored values.

- **Dry-run P2 — `2aa8e527`: closed.** `VideoScanModel+Cleanup.swift:95` projects only the specified hand marks. `CleanupPlan.swift:112` excludes machine-attributed note lines; `originalFullPath` contributes nothing. Category comparisons and explanatory reasons are at `:100`.

`c80cc264` adds the stated cases at `CleanupTrashHardeningTests.swift:26`, `:56`, `:81` and `:111`: content mutation between reads, post-proof Stop, failed-checkpoint ordering and acknowledged-save reload. The mutation case changes file bytes; it does not exercise the parent-directory relocation above.

`CleanupPane.swift`, `VideoScanModel+Cleanup.swift`, `VideoScanModel+JunkDelete.swift`, and the scoped test changes: **read, no independent findings**. No additional P1 introduced by the fixes was identified for wrong stamps, FamilyArchive copy trimming or unlinking.

Verdict: fix — F1 still permits loss of the last outside-Trash copy during proof; F3 and F5 retain the narrower P2 gaps described above.

## Brief

# Codex brief: Triage ▸ Cleanup v1, round 2 (FINAL)

**Answer contract.** First line: `Credits spent: <amount> | Finding count: <N>`. A line `Verdict: <merge | fix | block> …`. Write no files; answer only. Under ~1,000 words.

Second and last round (Rick's rule). Round 1: `docs/reviews/codex/codex-review-2026-10-12-cleanup-v1.md`, findings 1–7. Rick runs this on his real archive after merge (dry run today: 601 copies / 324 GB; 20 FamilyArchive junk files).

**Range:** branch `worktree-agent-aa316ffbf0a4f7b2f`, `e5d39127..02de09be` (`git log e5d39127..02de09be`; read files with `git show 02de09be:<path>`). `02de09be` is a merge of main (docs only). Paths under `VideoScan/VideoScan/`.

- F1 `94e59dad` — `CleanupProof.ancestryProblem` at execution, both files, both lanes: plain file, `realpath == path`, not under `.Trash`/`.Trashes`, by real spelling not in an archive root or Avid MediaFiles.
- F2 `5ed941f8` — `plannedFileProblem`: volume UUID + inode + size + mtime (never device number; no UUID ⇒ never proves); junk "missing" only when the planned volume's UUID is the one mounted at its path now (`CleanupDiskProbe.mountVolumeUUID`); no mount / other disk / no planned UUID ⇒ hold.
- F3 `fc83301e` — physical index over every active row (off-main).
- F4 `6d11f06a` — subtitle published before terminal state.
- F5 `9e61c4e0` — read bytes ledger, counted once.
- F6 `28a4fa1d` — engine result items not settled through the callback are settled from the result once (`settledIDs`).
- F7 `bbdbdd4d` — plan stores totals; no reduction in the page.
- Dry-run P2 `2aa8e527` — `CleanupHandMarks` counts only stars, confirmed people, typed date/place, user notes `MachineNote` does not attribute to a machine; never `originalFullPath`.
- `c80cc264` — `CleanupTrashHardeningTests`: mutation between reads held; Stop after a passed proof reported moved; blocked save moves exactly the first batch; reload after acknowledged save shows moved rows In the Trash.
- Files: `MediaOps/Cleanup/CleanupProof.swift`, `CleanupDiskProbe.swift`, `CleanupPlan.swift`, `CleanupTrashJob.swift`, `Catalog/CleanupPane.swift`, `MediaOps/VideoScanModel+JunkDelete.swift`; tests `VideoScanTests/CleanupTrash*.swift`.

**Do only this:** for each of F1–F7 and the dry-run P2, confirm the cited commit closes it (file:line) or say exactly what is open. Then any NEW P1 the fixes introduced: a route to trashing the last outside-Trash copy; a held/offline/cancelled row stamped; "missing" stamped while the original volume could still hold the file; a FamilyArchive copy trimmed; an unlink. P2/P3: at most three, one line each.

**Known and out of scope (not findings):** the proof→Trash pathname window without quarantine (#315); copies whose content already has an archive master are left to the Archive tab's Excess-copies door; the renamed "Avid MediaFiles_from_…" folder is intentionally not matched by the Avid rule.

**Do not explore outside the files those commits touch and their tests.**

## Closure (Manager, 2026-10-12)

Final round. F1 re-check after reads (d8cf9b82), F3 resolved identity indexed (31a5006a), F5 ledger-owned snapshot (2c027d84); 189 tests in 22 suites green; merged to main 2026-10-12. Open: proof→Trash pathname window → #315 (engine RemovalStep / quarantine).

## Closed

Closed by `HEAD` at 2026-10-12T19:48:19Z. 3 fixed; merged
