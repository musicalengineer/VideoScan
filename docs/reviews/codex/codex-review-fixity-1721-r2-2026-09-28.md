# Codex review — Fixity #1721 r2

- Range: `1f6c6532..af8228e6`
- Credits spent: unavailable
- Tokens: 59965
- Finding count: 2
- Verdict: merge-after-fixes
- Run: 2026-09-28T21:28:05Z (cycle #13, tools/codex_review.py)

## Codex answer

Credits spent: unavailable | Finding count: 2
Verdict: merge-after-fixes

- **P2 — Failed final batches cannot be retried in the same session.** `VideoScan/VideoScan/BindFixityToVolumeJob.swift:272`: `failSave` leaves the UUID-bound fixities in memory without retaining pending persistence across jobs. `FixityRebind.swift:161` consequently excludes them from subsequent candidates. **Counterexample:** bind two legacy records, fail the final save, restore saving, then start the job again. It reports “nothing to do” and never calls the acknowledged save; neither binding has reached disk through this workflow. The advertised retry does not recover them. Preserve pending bindings for acknowledged retry, or compare-and-set rollback the unsaved mutations. **Pin:** extend `aFailedSaveIsSurfacedAndNothingClaimsStored` with a two-record final-batch failure followed by a new job; require an acknowledged save and verify both bindings after catalog reload.

- **P2 — Changed-digest logs still claim storage before acknowledgment.** `VideoScan/VideoScan/BindFixityToVolumeJob.swift:314`: both log messages say the replacement digest was “stored” immediately after the in-memory mutation. **Counterexample:** re-read a legacy record whose digest differs, then inject save failure. The console and unified log already claim the new digest was stored despite `storedCount == 0`. The later failure summary does not make that earlier claim accurate. Defer those messages until acknowledgment or explicitly describe the digest as pending save. **Pin:** use a mismatching legacy digest and suspend/fail `saveCatalogForTesting`; assert no storage claim appears before acknowledgment or after failure.

`FixityRebind.swift`: read, no findings on the FIFO fix or weakened #1707 invariants. The permitted `VideoScanModel`/`CatalogStore` save path: read, no additional findings; lock-busy and stale-generation refusals propagate as failure. `FixityStampVolumeIdentityTests.swift`: read, no independent findings; the failure test stops before exercising retry.

Reviewed `af8228e6` only. No builds or tests run.

## Brief

Re-review, SCOPED to the fix commit for your #1721 HOLD (two P2s) on `fix/fixity-stamp-volume-uuid`: range `1f6c6532..af8228e6` — ONE commit, af8228e6. Use `git show af8228e6`. Read-only; do not build or run. Do not explore outside these files: VideoScan/VideoScan/FixityRebind.swift, VideoScan/VideoScan/BindFixityToVolumeJob.swift, the `saveCatalogAcknowledged` path it calls (CatalogStore / VideoScanModel — that function and what it awaits only), and VideoScan/VideoScanTests/FixityStampVolumeIdentityTests.swift. The later merges of main (e5b836d8, 230f9486) and 7550b0b9 (a test-only allowlist entry for main's ArchiveRefile.swift) are out of scope — skip them.

ONE-SENTENCE WORKFLOW: "Re-read every legacy-stamped file on one volume, bind its digest to the volume's persistent UUID, and never claim a binding is stored until the catalog save that holds it has succeeded."

YOUR #1721 FINDINGS AND THE CLAIMED FIXES (each red first)
- P2-1 (FixityRebind): blocking O_RDONLY open before the interruption and regular-file checks; a FIFO with no writer blocked > 3 s holding the volume gate. Fix: check interruption before any I/O; open with O_NONBLOCK; fstat the OPENED fd, refuse anything but S_ISREG; clear O_NONBLOCK for the reads; fd-bound before/after identity checks unchanged. Pin: pre-stopped rehash of a writerless FIFO returns promptly (was > 3 s).
- P2-2 (BindFixityToVolumeJob): only scheduled the debounced save, then counted bindings as stored. Fix: every 25 bindings (or 60 s), on Stop, on disconnect and at completion the job AWAITS `model.saveCatalogAcknowledged`; only acknowledged bindings count (`storedCount`, summary "N of M stored"); a failed save stops the job, shows "could not be saved" on the row and in the log, and leaves it resumable. Pin: injected save failure + checkpoint counter (seam `saveCatalogForTesting`).

ATTACK
1. P2-1: any path where a non-regular file (FIFO, socket, device, directory, symlink to one) is read, or where open(2) can still block; O_NONBLOCK not cleared before a read that then returns EAGAIN and is treated as a short/complete read and a digest; the fd leaked on an early-return path; interruption between open and fstat.
2. P2-2: a binding counted as stored with no acknowledged save covering it (Stop / disconnect / pause / error paths, the final partial batch); a save that "succeeds" while a concurrent writer's refusal (stale generation, lock busy) is swallowed; a failed save that still advances the resume cursor so those files are never re-bound; the summary or log over-claiming.
3. Anything in these changes that weakens your #1707 rules (legacy stamp untrusted until one full re-read; missing UUID never a wildcard).

EVIDENCE (M4, macOS 27, Xcode 27, Debug, after merging main): FixityStampVolumeIdentityTests 18/18; 53 app suites (fixity, signature, Delete Duplicates incl. every codex-pin suite, Prune, MFO, ArchiveLock) 383 tests, 0 failures; VideoScanCore 228 XCTest + 485 Swift Testing incl. all ContentFixity/VolumeIdentity suites green (one GEDCOM 200k perf ceiling over under load, 25/25 alone).

OUTPUT (stdout, Markdown, under 400 words):
first line exactly `Credits spent: <n or unavailable> | Finding count: <n>`
then a line `Verdict: merge / merge-after-fixes / hold`
then findings, each with file:line, a concrete counterexample, and the test that would pin it. Do not explore outside these files.

## Closed

Closed by `99d52873` at 2026-09-28T21:36:11Z. r2 #1 ee333820 (rollback on failed save; retry re-reads; pin aFailedFinalSaveIsUndoneAndARetryRebindsBoth + rollbackLeavesARecordSomeoneElseChanged), r2 #2 99d52873 (digest-changed lines only after ack; 2 pins). Red first; FixityStampVolumeIdentity 22/22, +4 suites 44/44 Debug.
