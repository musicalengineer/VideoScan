Brief: N1014-H-MediaOps-jobs | Source: main@ebcd2f09 | Wall clock: 30 | Files read: 28
Finding count: 6 (REAL 3 / NEEDS-MAC 1 / NOISE 2)
Verdict: The publishers (DerivativeOutputPublish, CombineOutputPublish, PartialFileNaming/ExclusivePublish) and Transcode/Combine hold up. The weak spots are the older jobs that skipped them: Reformat's fixed, unreserved partial name can mix up two batch jobs, Cleanup publishes without the length check, and Combine's mux runs without a stall watchdog. No job writes into or renames a source file.

Note on rule 3 of the standing rules: this row's brief said "do not commit or push", so the report is left uncommitted in the working tree.

## Findings

### N1014-H-MediaOps-jobs-F1 — P2 · REAL · Two Reformat jobs in one batch can share one partial file; each deletes or publishes the other's
- **Symbol:** `ReformatJob.runReformat` — MediaOps/ReformatJob.swift:201 (fixed partial name `ReformatJob.partialURL`, :532), :206 (`try? removeItem(atPath: partialPath)` before the encode), :299/:307/:321/:339 (the same removal on stall, cancel, failed check and too-small output), :348 (publish). Name source: `derivedFileURL`, MediaOps/DerivedFileNaming.swift:54 (timestamp to the second). Batch caller: Catalog/CatalogRowContextMenu+Actions.swift:74.
- **What's wrong:**
  - Transcode and Combine reserve a unique `<stem>.<8 hex>.vs-partial.<ext>` with O_EXCL and register it live.
  - Reformat does neither. Its partial is `<stem>.vs.hevc.<YYYYMMDD-HHMMSS>.vs-partial.mp4`, built from the source *stem*.
  - The comment at :203 says this name is "our own litter". That only holds while no other job has the same name.
  - `startReformat` (MediaFileOperations.swift:1073) has no same-record or same-output check. Trim, Balance and Rebuild all have one.
- **Scenario:**
  1. One folder holds two legacy-codec files with the same stem and different extensions (e.g. an `.avi` capture and a `.mov` export of the same tape).
  2. The user multi-selects them and accepts "Reformat and Analyze".
  3. The loop at :74 builds both jobs in the same second, so both get the same output URL and the same partial path.
  4. Both Tasks start right away (no gates). Job B's first act (:206) unlinks the partial that job A's ffmpeg has already opened.
  5. A's ffmpeg keeps writing to the unlinked inode, while B's ffmpeg (`-y`) creates a new file at that name.
  6. When A ends, every check at :318–343 runs against **B's in-progress file**. The duration check is skipped because ffprobe can't read an mp4 that has no `moov` yet, and `FFmpegEncodeCheck` skips rather than fails when it can't measure. The size is over 10 KB.
  7. So A publishes B's half-written encode under the final name, catalogues it with `derivedFrom = A`, and queues Analyze on it.
  8. B's `+faststart` pass then reopens a partial name that is gone. B fails, and nothing flags A's output.
  9. In the other ordering, both ffmpegs share one inode and write over each other.
- **Impact:**
  - A derivative with the wrong content or no `moov` is published as good and catalogued with the wrong lineage.
  - Sources and pre-existing files are untouched, because the publish itself is no-clobber. That is why this is P2, not P1.
  - The exact bytes left on disk need a Mac to observe. The shared path and the unconditional removal are certain from the code.
- **Pinning test (fails today):**
  1. Build `ReformatJob(record: a.avi)` and `ReformatJob(record: a.mov)` (same temp dir) back-to-back.
  2. Assert `ReformatJob.partialURL(for: j1.outputURL) != ReformatJob.partialURL(for: j2.outputURL)`. Alternatively, assert that the partial a started job writes passes `PartialFileNaming.isPartialName` (i.e. it was reserved).
  3. Add a source sensor: ReformatJob.swift must not contain `removeItem(atPath: partialPath)`.
- **Fix direction:**
  1. Reserve through `DerivativeOutputPublish.reservePartial` and discard through `PartialFileNaming.remove`, as TranscodeJob does (:247–255, :466).
  2. On a publish error, keep the finished encode with `keepUnpublished`. Today it is left at an unprotected name (:355).
- **Related, lower risk (not separate findings):**
  - Rebuild (`<stem>_RepairedAudio.mov`, RebuildAudioJob.swift:73) and Balance (`<stem>_balanced.mov` for raw DV) can also give two different records the same output name.
  - Their per-record guards don't cover that.
  - Their `taken()` check treats an existing partial as taken, so only a near-simultaneous start collides. Those jobs start from a sheet one at a time, not from a batch loop.

### N1014-H-MediaOps-jobs-F2 — P2 · REAL · Cleanup publishes a render cut short by a source read error as a good cleaned copy
- **Symbol:** `CleanupFFmpegEngine.render` — MediaOps/CleanupFFmpegEngine.swift:110–124. Caller: `CleanupJob.runCleanup` → `publishOffMain` (CleanupJob.swift:~285) → catalogued, then "Cleaned → … Original untouched."
- **What's wrong:**
  - Render checks only the exit code and a 10 KB minimum.
  - `FFmpegEncodeCheck.verdict` (Media/FFmpegEncodeCheck.swift:84) exists because "ffmpeg can exit 0 on a truncated input". Its length check is used by Transcode and Reformat only (grep: no other callers).
  - Trim, Rebuild, Balance and Combine each run their own duration verification. Cleanup has none.
- **Scenario:**
  1. Cleanup runs on a 60-minute capture on an aging USB drive. Read errors (bad sectors) begin at minute 20.
  2. ffmpeg's input loop logs the read error and treats it as end-of-file, without `-xerror`, so it exits 0. The read error returns at once, so the stall watchdog never fires.
  3. A valid 20-minute `cleanup-render.mov` passes the exit and size gates.
  4. It is copied next to the original as `<stem>_cleaned.mov`, catalogued with `derivedFrom`, and reported as success.
- **Impact:** a cut-short derivative is published as good. The original is untouched and still catalogued, so this is P2. The brief's own example of P1 is "a truncated output published as good", so Rick may want to raise it.
- **Pinning test (fails today):**
  1. Set `VS_FFMPEG_PATH` to a wrapper that runs real ffmpeg to write a 5-second `test_` lavfi clip to the last argument, then exits 0.
  2. Run `CleanupFFmpegEngine.render` with `source.durationSeconds = 60`.
  3. Expect `CleanupEngineError.renderFailed`. Today it returns the URL.
- **Fix direction:** after the size gate, call `FFmpegEncodeCheck.durationShortfall(sourceSeconds: probe(source), outputSeconds: probe(renderURL))`.

### N1014-H-MediaOps-jobs-F3 — P3 · REAL · Combine's ffmpeg mux and its verify probes run with no stall watchdog or deadline
- **Symbols:**
  - `CombineEngine.runFFMpeg` — MediaOps/CombineEngine.swift:46: `runProcess` with no `deadlineSeconds`, no `StallMonitor`, no `control`.
  - `CombineVerifier.verifyCombineOutput` — CombineVerifier.swift:22: `runFFProbe` called without `timeoutSeconds`.
  - `CombineVerifier.decodeTestFrame` (:194) and `detectAudioLevel` (:161): no deadline either.
  - Every other ffmpeg job in scope arms a `StallMonitor` (Transcode, Reformat, Trim, Cleanup, Rebuild, Balance). Grep for StallMonitor/deadline in the Combine files finds only `runFFProbe`'s optional parameter.
- **Scenario:**
  1. A Combine batch reads a pair straight from a local USB drive. Staging only buffers network paths.
  2. The drive stops responding mid-mux. ffmpeg blocks in read(2) and prints nothing.
  3. The row stays "muxing" indefinitely, and the rest of the overnight batch never runs.
  4. That is the 14-hour hang class the watchdogs were added for. A wedged ffprobe in verify does the same.
- **Impact:** no file is lost. Stop still cancels, and a cancel removes only the reserved partial. P3.
- **Pinning test (fails today):**
  1. Set `VS_FFMPEG_PATH` to a script that sleeps silently.
  2. Run one pair through `processCombinePair` with a short stall threshold.
  3. Expect the pair to fail as stalled within the threshold. Today it never returns.

### N1014-H-MediaOps-jobs-F4 — P3 · NEEDS-MAC · Trim, Cleanup, Rebuild and Balance publish with `FileManager.moveItem`, not ExclusivePublish
- **Symbols:**
  - `TrimJob.promoteNonClobbering` — TrimJob.swift:588
  - `CleanupJob.publishOffMain` — CleanupJob.swift:435
  - `RebuildAudioJob.runRebuild` — RebuildAudioJob.swift:555
  - `BalanceAudioJob` publish — BalanceAudioJob.swift:600
- **What's wrong:**
  - These four rely on "moveItem FAILS if the destination exists" (comments at CleanupJob.swift:391, TrimJob.swift:19).
  - As far as I know, Foundation implements that as an existence check followed by rename(2). That is the same check-then-act window that codex #1642 removed from the Combine/Transcode fallback.
  - The brief's rule is RENAME_EXCL, else link(2), else refuse (`ExclusivePublish.renameNoClobber`).
- **Scenario:** a second writer (a Finder copy, or a second instance of the app) creates `<stem>_cleaned.mov` between moveItem's check and its rename. rename(2) then replaces that file and the job reports success.
- **Why NEEDS-MAC:**
  - Whether Darwin's moveItem really has that window, rather than using `renamex_np(RENAME_EXCL)` inside, has to be checked on macOS.
  - The window is microseconds, and the colliding names belong to these jobs only.
- **Also:** the comment at CleanupJob.swift:395 says `ReformatJob.atomicPublish` "replaces an existing destination". That is stale: it has been no-clobber since 2026-09-22.
- **Pinning test:**
  1. Use a `FileManager` subclass, or swizzle on the Mac, that creates the destination between `fileExists` and the rename inside `moveItem`.
  2. Assert the pre-existing destination's inode survives.
  3. The simpler pin is a source sensor that these four files call `ExclusivePublish.renameNoClobber`. It fails today.

### N1014-H-MediaOps-jobs-F5 — P3 · NOISE · Combine is not a `MediaFileOperationJob` row
- **Where:** `CombineJobsSection` (CombineWindow.swift:1–11) is a separate section in the MFO window with its own row model. The file's header says this is a deliberate "Phase 1" choice.
- **Why NOISE:** the CLAUDE.md long-operations rule (2026-09-27) asks for the standard row, double-click detail and one log sink. Combine has its own START/OUTCOME lines through `log`/`appLog`. This is a known, documented deviation, not a regression. Listed so the gap is on record.

### N1014-H-MediaOps-jobs-F6 — P3 · NOISE · The rescue copier's `.partial` sweep could unlink a rescued file genuinely named `<x>.partial`
- **Symbol:** `RescueFileCopier.copy` — RescueFileCopier.swift:206 and :229.
- **Scenario:**
  1. The source tree holds both `clip.mov` and `clip.mov.partial`.
  2. On a resumed rescue, `clip.mov` is already present, so :206 unlinks the rescued copy of `clip.mov.partial`.
- **Why NOISE:**
  - The same pass then re-copies `clip.mov.partial` from the source, which is never written.
  - The data is lost only if the source read then fails, and a real source file named that way is unlikely.

## Guards checked that held
- **No clobbering on publish.**
  - `ExclusivePublish.renameNoClobberDetailed` tries RENAME_EXCL, then link(2) with an inode-checked unlink, else refuses. There is no rename-over and no `replaceItemAt` anywhere in scope.
  - Combine, Transcode and Reformat all publish through it.
- **Replace never deletes.** Transcode's Replace sends the old file to the Trash, only after the new output exists, only when RENAME_EXCL is supported, and only after a re-check against the Master Archive rule (`archiveCheck`). A failed take says where the Trash copy is.
- **Partial cleanup stays on its own files.**
  - `PartialFileNaming.remove` refuses non-partial names and protected (`.keep`) outputs, and uses unlink(2), so it is never recursive.
  - The sweep skips live and protected partials and keeps the 24-hour threshold.
  - A finished-but-unpublished output is protected and then moved to `.vs-kept.` without overwriting anything.
- **The F3 pattern from N1007 (try? removeItem deleting a file the job didn't create):**
  - Transcode/Combine: safe (reserved partials).
  - Trim: per-record dedupe guard plus a stem-fixed name.
  - Cleanup scratch: a per-job UUID directory. The Cleanup partial is chosen after `taken()`.
  - Rebuild/Balance: per-record guards plus `taken()`.
  - Only Reformat lacks the guard (F1).
- **Exit codes and truncation:**
  - Transcode and Reformat check the exit code and then the length. Combine checks the exit code, then duration, audio coverage and a decode test.
  - Trim checks the exit code, then codec, stream count and duration. Rebuild/Balance check the exit code, the shape and the audio stream's own duration.
  - Transcode Preservation: an empty or mismatched framemd5 always fails (`compareFrameMD5` returns malformed). A killed or failed verify decode cannot pass as a match.
- **Cancel and stall:** every in-scope ffmpeg job except Combine (F3) has a watchdog. A stall wins over a cancel (`MFOTerminalCause`), and a cancel removes only the partial. Preservation keeps the already-published, length-checked master when verify is cancelled. That is deliberate and commented.
- **Sources are never written:**
  - ffmpeg always writes a partial, and the output can never equal the source. A Transcode name is `<stem>.vs.<purpose>.<ext>` and a path extension never contains dots. Combine stages copies.
  - Rescue opens the source O_RDONLY and checks size and mtime before it publishes.
- **Code quality:** no `try!`, force casts or force unwraps in the scope files. Disk work runs off-main (`@concurrent` hops). The O(records) scans (`records.first/firstIndex`) run once per job, not in view bodies.

## Callees followed
- `FFmpegEncodeCheck` (Media/)
- `ProcessRunner.runProcess` / `runStreaming` (VideoScanCore: exit code on signal and launch failure, deadline)
- `derivedFileURL` (DerivedFileNaming)
- `MediaFileOperationsCenter.add` / `startReformat` / `startTrim` / `startRebuildAudio` / `startBalanceAudio` dedupe guards
- `CatalogRowContextMenu+Actions` reformat batch
- `TranscodeDestination` / `TranscodeSheet` naming and Replace
- `TranscodeJob+FrameMD5.compareFrameMD5`
- `CombineVerifier`
- `CombineWindow` header

## Not covered
- The rest of BalanceAudioJob's body (only the publish/verify region and its naming were read). Whether any Balance batch caller can start two same-output records at once.
- The VolumeRescueOperation caller of RescueFileCopier (it lives in Volumes/): whether the rescue folder is always app-created, which the "replace an incomplete destination" rename at :292 depends on, and how its progress is reported to MFO.
- `VideoScanModel+CombineBatchPlan`, `stageCombineInputs` and `CombineSheet`. Pause semantics on Combine.
- Logs that leak media paths: every job logs full paths `.public` to the local videoscan.log and catalog.log by design. Nothing leaves the machine, so this was not raised.
