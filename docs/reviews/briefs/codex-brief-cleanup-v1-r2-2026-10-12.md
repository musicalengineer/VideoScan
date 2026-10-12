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
