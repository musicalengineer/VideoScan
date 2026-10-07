# VideoScan Swift playbook

Source: main@1cf5bbea · Brief: N1007-P-swift-playbook · Drafted 2026-10-07 (cloud, read-only; nothing was built)

This is a template book for the coding jobs VideoScan does again and again. Rick asked for "a good template for
just about every kind of coding job". Each section below covers one job and gives the same six things:

- the pattern,
- a short Swift skeleton,
- the canonical source it follows,
- the smells to avoid,
- the **best** example in the repo today,
- the **worst** one that should move to the pattern.

Best and worst were picked by grepping `VideoScan/VideoScan/` and `VideoScan/VideoScanCore/` and reading each
candidate, not from memory. Line numbers are as of the source SHA above, so expect them to drift. The skeletons are
sketches of the shape, not drop-in code. They use the house types (`MediaFileOperationJob`, `ProcessRunner`,
`AtomicFilePublish`, `DamagedFileSetAside`) under their real names, so a brief can say "do it like §3" and mean
something exact. Each section has a short C++ note for Rick.

## Contents

0. [House rules every section assumes](#0-house-rules-every-section-assumes)
1. [A long operation (MFO job)](#1-a-long-operation-mfo-job)
2. [A list or table over 100k records](#2-a-list-or-table-over-100k-records)
3. [An ffmpeg / ffprobe call](#3-an-ffmpeg--ffprobe-call)
4. [A ledger, journal or SQLite write](#4-a-ledger-journal-or-sqlite-write)
5. [A settings pane](#5-a-settings-pane)
6. [A background analyzer / cycler](#6-a-background-analyzer--cycler)
7. [A decision with several outcomes](#7-a-decision-with-several-outcomes)
8. [A Hallie query path](#8-a-hallie-query-path)
9. [Saving a hand-curated JSON file](#9-saving-a-hand-curated-json-file)
10. [How to use this in a brief or review](#10-how-to-use-this-in-a-brief-or-review)

Summary of picks:

| # | Job | Best (follow this) | Worst (migrate this) |
|---|---|---|---|
| 1 | MFO job | `PerceptualFingerprintBackfillJob` MediaOps/PerceptualFingerprintBackfillJob.swift:52 | `analyzeDuplicates` MediaOps/VideoScanModel+Duplicates.swift:111 |
| 2 | 100k list | `startTriageBuild` Catalog/VideoScanModel+TriageSnapshot.swift:119 | volume context menu count, Catalog/CatalogView+VolumeTable.swift:519 |
| 3 | ffmpeg | TranscodeJob encode, MediaOps/TranscodeJob.swift:312 | `AllFramesRipper.runFFmpeg` Media/AllFramesRipper.swift:343 |
| 4 | ledger / journal | `ArchivePromoteJournal.appendRetractable` Archive/ArchivePromoteJournal.swift:78 | `FindTagIngestState.save` VideoScanCore/FindTagJournal.swift:404 |
| 5 | settings | `PruneBarSettingsSection` MediaOps/PruneBarSettingsSection.swift:13 + `ImportanceBar.load(defaults:)` VideoScanCore/PrunePlan.swift:435 | `ScanPerformanceSettings` Volumes/ScanPerformanceSettings.swift:19 |
| 6 | cycler | `PreviewSweepEngine` VideoScanCore/PreviewSweepEngine.swift:35 | `catchUpInferredDates` Catalog/VideoScanModel+DateInference.swift:757 |
| 7 | several outcomes | `ArchiveRefile.Outcome` Archive/ArchiveRefile.swift:343 | `PersonFinderModel.undoLastDelete` People/PersonFinderModel.swift:961 |
| 8 | Hallie query | `ArchivistPresenceExecutor` Hallie/ArchivistPresenceExecutor.swift:452/:485 | `HallieLineageQuestion.detectShape` Hallie/HallieLineageQuestion.swift:228 |
| 9 | curated JSON | `FamilyAssetStore.excludePhoto` FamilyTree/FamilyAssetStore.swift:1055 | `ValidationLabelStore.load/save` People/ValidationLabelStore.swift:54 |

(App paths are relative to `VideoScan/VideoScan/`. Core paths are relative to `VideoScan/VideoScanCore/Sources/`.)

---

## 0. House rules every section assumes

These come from CLAUDE.md and `docs/practices/software_dev_policy.md`. The sections don't repeat them.

- **Anything that can run past about a minute is an MFO job** (§1). It never gets its own progress UI and it never
  runs silently.
- **No O(records) work in a SwiftUI view body.** Ever. That includes `contextMenu` and toolbar builders, because
  they are view bodies too.
- **Five test dimensions:** logic, scale (100k synthetic records with a time budget), media matrix (mp4/h264,
  mov/prores, mkv/ffv1+pcm, mxf, avi/dv), isolation (a poisoned-state test), and a sensor that pins the fix at scale.
  Each section names which ones apply.
- **Never `FileManager.replaceItemAt`** or `replaceItem(at:…)`. Both are `RENAME_SWAP`, which wedged the kernel on
  2026-09-14. Publish with `AtomicFilePublish` (small files) or `ExclusivePublish` / `DerivativeOutputPublish` /
  `CombineOutputPublish` (media). `AtomicFilePublishSensorTests` fails if `replaceItemAt` comes back.
- **Nothing is deleted.** Media goes to the Trash, repo files go to `.trash/`, and a damaged curated file is renamed
  aside.
- **Get off the main actor on purpose.** With approachable concurrency, a plain `nonisolated async func` runs on
  the *caller's* actor, which is usually main. Mark heavy work `@concurrent`. The repo writes it as
  `#if compiler(>=6.2) @concurrent #endif` (for example MediaLedger.swift:161, DuplicateDetector.swift:322). Only
  `Sendable` values cross: take a `snapshotClone()` of a `VideoRecord` on main, work on the clone, and copy the
  result back on main.
  - C++: think of `@MainActor` as "this member is only touched on the UI thread". `@concurrent` is
    `std::async(std::launch::async, …)`. `Sendable` is "safe to hand to another thread without a mutex".
- **Data-risk paths** (delete/move/rewrite media, the ledger, resume/recovery, the archive, fixity, curated user
  data) get `/safety-critical` before design and a codex pass after the batch.

---

## 1. A long operation (MFO job)

**Pattern.** Give each operation one `@MainActor final class` that conforms to `MediaFileOperationJob`
(MediaOps/MediaFileOperations.swift:435). The Media File Operations Center owns the row.

- The job publishes the row fields: `title`, `subtitle` (that is "N of M · current file · time left"), `fraction`
  and `state`. It also keeps a per-item `[Item]` list for the double-click detail.
- `start()` is idempotent. `cancel()` sets `.cancelling` and cancels the task. `pause()`/`resume()` take effect at
  a safe boundary (between files) or via `JobPauseCoordinator` for an ffmpeg child.
- A refusal before any work uses `refuseToStart`, which sets `wasRefused` so the log says "refused", not "FAILED".
- Heavy work goes through a volume gate (`MediaVolumeGate` + `PausableGatePermit`) so a spinning disk gets one
  reader.
- Logging goes through **one sink function** that writes the console, catalog.log, videoscan.log and the unified
  log. It writes a START line, a progress line every N items, and one OUTCOME line. The Center also writes its own
  exactly-once OUTCOME line (MediaFileOperations.swift:685–710).
- Durable state is checkpointed every K items or every T seconds. A failed save stops the job and undoes the unsaved
  part.

**Skeleton.**

```swift
@MainActor
final class FrobnicateJob: @MainActor MediaFileOperationJob {
    struct Item: Identifiable, Sendable { enum Kind { case done, failed, offline }; let id: Int; let name: String; let kind: Kind; let why: String }
    let id = UUID(), kind = MediaFileOperationKind.frobnicate, startedAt = Date()
    @Published private(set) var state: MediaFileOperationState = .running
    @Published private(set) var subtitle = "Preparing…", fraction = 0.0, finishedAt: Date?
    @Published private(set) var items: [Item] = []          // double-click detail
    var isIndeterminate: Bool { total == 0 }
    var canPause: Bool { state == .running }; private(set) var isPaused = false
    private var task: Task<Void, Never>?; private var total = 0
    var title: String { "Frobnicate \(total) file(s)" }

    func start()  { guard task == nil else { return }; task = Task { [weak self] in await self?.run() } }
    func cancel() { guard state.isActive else { return }; state = .cancelling; task?.cancel() }
    func pause()  { isPaused = true }   // honoured between items
    func resume() { isPaused = false }

    private func run() async {
        let plan = await FrobnicatePlan.build()               // off-main, Sendable
        total = plan.count; note("START — \(total) file(s); read-only on media")
        for (i, entry) in plan.enumerated() {
            while isPaused && !Task.isCancelled { try? await Task.sleep(for: .milliseconds(200)) }
            if Task.isCancelled || state == .cancelling { break }
            subtitle = FrobnicateJob.progressLine(done: i, total: total, current: entry.name, since: startedAt)
            items.append(await FrobnicateEngine.one(entry))   // @concurrent inside
            fraction = Double(i + 1) / Double(total)
            if (i + 1) % 50 == 0 { note("progress — \(i + 1) of \(total)") }
        }
        finish()                                              // stamps finishedAt, one OUTCOME line
    }
    private func note(_ s: String) { model?.frobnicateNote("Frobnicate: " + s) } // ONE sink
}
```

**Canonical source.**

- *The Swift Programming Language*, "Concurrency": tasks, cooperative cancellation (`Task.isCancelled`) and
  `@MainActor`.
- Swift Concurrency proposals SE-0304 (structured concurrency) and SE-0461 (`nonisolated(nonsending)` and
  `@concurrent`).
- NetNewsWire's account-refresh progress (one progress object per refresh, combined for the UI) has the same
  "one owner of progress, the view only observes" shape.

**Smells.**

- A `@Published var fooStatus: String` on `VideoScanModel` plus a toolbar spinner. That is an ad-hoc progress UI.
- No N of M, no Stop, or a Stop that doesn't stop the child process.
- `appLog.write` and `model.log` and `os_log` copy-pasted at each call site, instead of one `…Note` sink.
- An OUTCOME line written from several exits. Write it from one place, so it happens exactly once.
- A clock that keeps ticking after the job ends. `finishedAt` must be stamped once (the 2026-07-07 regression).
- Progress published at the rate the engine produces it. Throttle to about 4 Hz (`PromoteProgressReporter`,
  `ThrottledMainActorUpdate`).
- Checkpoint saves that are fire-and-forget. Await an acknowledged save.

**Best: `PerceptualFingerprintBackfillJob`** (MediaOps/PerceptualFingerprintBackfillJob.swift:52; run loop :181).
It is the newest job, it was written to the 2026-09-27 rule clause by clause, and its header says so:

- verb chip, N of M, current file, time left (`progressLine` :441), Pause between files (:165) and Stop that ends
  ffmpeg;
- one sink, `perceptualFingerprintNote`, writing START, a progress line every 50 files and the OUTCOME;
- an awaited checkpoint every 25 items or 60 s, and a failed save undoes the unsaved fingerprints;
- volume gates, a `StallMonitor`, and a refusal on a read-only catalog.

For the *data-safety* half (intent journal, reconcile on restart, a per-file outcome list, one batch save), read
`PromoteToArchiveJob.run` (Archive/PromoteToArchiveJob.swift:282). It is the most hardened job, but it has no Pause.

**Worst: `analyzeDuplicates`** (MediaOps/VideoScanModel+Duplicates.swift:111). This is the catalog-wide duplicate
pass (the GH #104 beachball class). The grouping did move off-main, but the run is still not an MFO job:

- progress is the `duplicateStatus` string shown in the toolbar, cleared ten seconds later by an `asyncAfter`;
- there is no N of M, no time left, no Stop, no per-item detail and no START/OUTCOME pair in videoscan.log.

Correlate All (`VideoScanModel+Correlate.swift`, `correlateStatus`) has the same shape and should move alongside it.

**Tests.** Logic: the pure `progressLine` and `summaryCounts`. Scale: a 100k-item plan builds under its budget.
Isolation: the job under a test host never touches the real catalog. Sensor: one START and exactly one OUTCOME line
per run, including cancel.

> C++: the job is a class with a worker coroutine. `@Published` fields are members guarded by "UI thread only", and
> the row is an observer. `Task.cancel()` sets a flag the worker polls. It is not `pthread_cancel`.

---

## 2. A list or table over 100k records

**Pattern.** The view observes a **snapshot object**, never `model.records`.

- The model builds the snapshot in two steps:
  1. A cheap **projection** on main: one O(records) pass that copies only the fields the table needs into
     `Sendable` values, timed.
  2. A **build** off-main (`Task.detached` or `@concurrent`): filter, search and sort over the projection.
- A generation counter stops a late build from publishing over a newer one. The rebuild is debounced (250 ms,
  stretched to 10× the last projection time, capped at 5 s).
- Building only happens while a view is on screen (a viewer count, not a flag).
- Click handlers look records up by id. View bodies only index the snapshot's arrays.

**Skeleton.**

```swift
extension VideoScanModel {
    func noteThingCatalogChanged() {                       // called from every mutation funnel
        guard thingViewers > 0, !thingRefreshScheduled else { return }
        thingRefreshScheduled = true
        let delay = Self.debounceNanos(lastProjectionNanos: thingLastProjectionNanos)
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            self?.thingRefreshScheduled = false
            self?.startThingBuild()
        }
    }
    private func startThingBuild() {
        thingTask?.cancel(); thingGeneration &+= 1
        let gen = thingGeneration, query = thingQuery
        let t0 = DispatchTime.now().uptimeNanoseconds
        let projection = ThingBuilder.project(records)    // the ONE O(records) pass on main
        thingLastProjectionNanos = DispatchTime.now().uptimeNanoseconds &- t0
        thingTask = Task.detached(priority: .userInitiated) { [weak self] in
            guard let rows = ThingBuilder.build(projection, query: query,
                                                isCancelled: { Task.isCancelled }) else { return }
            await MainActor.run {
                guard let self, self.thingGeneration == gen, self.thingViewers > 0 else { return }
                self.thingSnapshot.publish(rows)          // the view observes thingSnapshot only
            }
        }
    }
}
```

**Canonical source.**

- SwiftUI data flow: WWDC20 "Data Essentials in SwiftUI" and WWDC21 "Demystify SwiftUI". `body` is called often
  and must be cheap. Identity comes from stable ids.
- Apple's `Table` documentation: rows are `Identifiable` values, and sorting is done by the model.
- NetNewsWire's timeline fetches articles asynchronously and gives the view a ready array. The view never queries the
  database.

**Smells.**

- `model.records.filter`, `.count`, `.first(where:)` or `.contains` inside `body`, a `contextMenu` builder, a
  toolbar or a computed property that `body` reads.
- A `@Published` array on `VideoScanModel` that 20 views observe, so every record change redraws them all.
- A rebuild per mutation with no debounce. A Delete Duplicates run sends thousands of them.
- No generation check, so an old search result flashes over a new one.
- Sorting with a closure that reads `VideoRecord` (a class, main-actor state) from a background task.

**Best: Triage snapshot** (Catalog/VideoScanModel+TriageSnapshot.swift:119 `startTriageBuild`, debounce :69).
It has everything above: one timed projection on main, a detached build with cancellation, a generation stamp, an
adaptive debounce (measured at about 2 µs per record), work only while the tab is visible, and a test hook that
counts projections (`triageProjectionCount`). `refreshDossierCountsNow` (Model/VideoScanModel.swift:350) is the small
version for chrome counts.

**Worst: the volume context menu's caption count** (Catalog/CatalogView+VolumeTable.swift:519).
`model.records.filter { $0.fullPath.hasPrefix(…) && … }.count` is evaluated inside the view builder for the menu,
just to choose a label and enable the button. That is an O(records) string-prefix scan, on main, every time the menu's
view is rebuilt. The neighbouring `model.records.contains(where:)` at :595 has the same problem. Move both to the
per-target counts that `VolumeStatusCache` already keeps. That is the GH #104 fix template.

**Tests.** Scale: 100k synthetic records, projection plus build under budget. Sensor: the projection count stays at 1
across a query change. Isolation: the reachability seam (`triageReachability`), so no test depends on plugged-in
drives.

> C++: the projection is copying `struct Row { … }` out of a `std::vector<Record*>` under the UI lock. The build
> sorts the copy on a worker. The generation counter is a sequence number that the publisher checks before
> committing.

---

## 3. An ffmpeg / ffprobe call

**Pattern.** Every child process goes through `ProcessRunner.runProcess` (VideoScanCore/ProcessRunner.swift:192).
It drains both pipes all the time, caps stderr, kills on task cancel and on a deadline (SIGTERM, then SIGKILL, then
abandon), and reports `timedOut` separately from the exit code.

- Pass a `ProcessControl` so Pause can SIGSTOP the child, and feed a `StallMonitor` from progress lines so a sleeping
  drive fails the file instead of hanging for 14 hours.
- Output goes to a **reserved unique partial** (`DerivativeOutputPublish.reservePartial` or `PartialFileNaming`).
- Judge the result: exit code first, then `FFmpegEncodeCheck` (length and duration).
- Only then publish with no-clobber (`ExclusivePublish`, `renamex_np(RENAME_EXCL)`). Never touch the source.

**Skeleton.**

```swift
nonisolated static func encode(_ src: URL, to output: URL, ffmpeg: String,
                               pauser: JobPauseCoordinator, monitor: StallMonitor) async throws -> URL {
    let partial = try DerivativeOutputPublish.reservePartial(for: output)   // O_EXCL, registered live
    defer { PartialFileNaming.unregisterLive(partial) }
    monitor.start(); defer { monitor.stop() }
    let result = await ProcessRunner.runProcess(
        executable: ffmpeg,
        arguments: ["-nostdin", "-hide_banner", "-i", src.path, /* codec args */
                    "-progress", "pipe:2", "-y", partial.path],
        stderrLine: { _ in monitor.tick() },                 // progress feeds the watchdog
        deadlineSeconds: nil,                                 // stall monitor bounds silence instead
        control: pauser.control)                              // SIGSTOP/SIGCONT for Pause
    if Task.isCancelled { discardPartial(partial); throw CancellationError() }
    if let why = await FFmpegEncodeCheck.verdict(for: result, sourcePath: src.path,
                                                 outputPath: partial.path) {
        discardPartial(partial); throw EncodeFailure(why)     // exit code, THEN length
    }
    let outcome = try DerivativeOutputPublish.publish(partial: partial.path, as: output,
                                                      policy: .keepBoth, archiveCheck: nil,
                                                      trash: { try trashItem($0) })
    return outcome.publishedURL
}
```

For ffprobe (metadata), the same call with `deadlineSeconds:` set. A probe on a dead network share must come back as
"timed out", never as "undecodable" (GH #136).

**Canonical source.**

- Swift Concurrency: `withTaskCancellationHandler` and checked continuations (SE-0300), which `ProcessRunner`
  wraps.
- Foundation's `Process` and `Pipe` documentation (a pipe that nobody drains blocks the child).
- POSIX `rename(2)` / `renamex_np(RENAME_EXCL)` for publishing.
- House: `AtomicFilePublish.swift` header (why not `RENAME_SWAP`) and `DerivativeOutputPublish.swift` header (the
  four publish rules).

**Smells.**

- `let p = Process()` in feature code.
- `readDataToEndOfFile()` after the child exits. The pipe can fill first and deadlock.
- No deadline on a probe.
- Treating `timedOut` or a SIGTERM exit as "the file is bad".
- A fixed partial name built from the source stem. Two batch jobs then share it (N1014-F1, since fixed in Reformat by
  `reservePartial`).
- `removeItem` at the output name before the encode exists.
- Publishing without the length check (N1014-F2, Cleanup).
- `FileManager.moveItem` as the publish (N1014-F4).
- No stall watchdog on a long mux (N1014-F3, Combine).

**Best: TranscodeJob's encode** (MediaOps/TranscodeJob.swift:312). It uses `ProcessRunner.runProcess` with
`control: pauser.control`, progress lines that tick a `StallMonitor`, a stall cause reported ahead of a generic
cancel, the partial discarded on every failure, and the exit code checked before length (`FFmpegEncodeCheck`) before
anything is published through `DerivativeOutputPublish`. The 2026-09-19 comment notes that the exit status used to
be thrown away. TrimJob (:329) and VerifyAudioProbe (:500) follow the same call shape.

**Worst: `AllFramesRipper.runFFmpeg`** (Media/AllFramesRipper.swift:343). It is one of 16 hand-rolled `Process()`
sites:

- it has no deadline and no stall monitor (a sleeping drive hangs the rip forever);
- it has no `ProcessControl`, so `RipAllFramesJob` sets `canPause = false` (RipAllFramesJob.swift:59);
- stderr is drained with `readDataToEndOfFile()` inside the termination handler.

It already passes a progress callback, so it maps directly onto `runProcess(stdoutLine:stderrLine:control:)`. Other
hand-rolled sites to sweep after it: `FFmpegFrameProvider.swift:56`, `AudioTranscriber.swift:363` and
`WhisperWorkerTranscriber.swift:549`.

**Tests.** Media matrix: all five synthetic fixtures through the call. Logic: the progress-line parser. Sensor: a
fake child that ignores SIGTERM must still return `timedOut` within deadline + grace.

> C++: `ProcessRunner` is `posix_spawn` plus two reader threads plus `waitpid` in a SIGCHLD handler, with an RAII
> guard that kills the child if the owning coroutine is destroyed. `RENAME_EXCL` is `link()` + `unlink()` in one
> atomic syscall.

---

## 4. A ledger, journal or SQLite write

**Pattern.** Pick the storage by what the data *is*:

- **Append-only facts** (the media ledger, the promote intent journal, Find & Tag verdicts) are JSONL.
  - Open with `O_WRONLY|O_APPEND|O_CREAT|O_NOFOLLOW|O_CLOEXEC` (descriptor-relative inside the archive's
    `00_Index`).
  - Do **one** `write` per batch, then a durability barrier.
  - Serialize all writes on one ordered off-main worker (a `Task` chained after the previous one) or under the
    archive index lock.
  - A write that *gates* an action (an intent that must be journaled before a copy starts) **throws**, and the
    action does not start.
  - When an intent may need taking back, return a receipt (offset + bytes) and retract only if it is still the last
    line, byte for byte.
- **A whole small document** (state, plans, sidecars) is rewritten through `AtomicFilePublish.write(…, durability:)`.
  Use `.fullFsync` when losing it costs user work.
- **A rebuildable cache** (probe cache, person-finder cache) is SQLite in WAL mode with `synchronous=NORMAL`, one
  connection behind a lock, prepared statements, and every return code checked.
- Readers stay `nonisolated` and bounded (a read limit), and they never block the writer.

**Skeleton.**

```swift
final class FactLedger: @unchecked Sendable {             // NSLock guards `tail`
    private let lock = NSLock(); private var tail: Task<Void, Never>?
    let url: URL

    /// Gating append: returns only after the bytes are durable, or throws.
    func appendConfirmed(_ events: [FactEvent]) async throws {
        let data = try FactEvent.encodeLines(events)          // encode on the caller (cheap)
        let previous = lock.withLock { tail }
        let work = Task(priority: .utility) { [url] () -> Result<Void, Error> in
            await previous?.value                              // strict ordering
            return Result { try await Self.appendDurable(data, to: url) }
        }
        lock.withLock { tail = Task { _ = await work.value } }
        try await work.value.get()
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func appendDurable(_ data: Data, to url: URL) async throws {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw LedgerFailure.io("open", errno) }
        defer { close(fd) }
        try writeAll(data, to: fd)                             // EINTR + short-write loop
        guard fcntl(fd, F_FULLFSYNC) == 0 || fsync(fd) == 0 else { throw LedgerFailure.io("sync", errno) }
    }
}
```

**Canonical source.**

- SQLite documentation, "Atomic Commit In SQLite" and "Write-Ahead Logging".
- Apple's `fcntl(2)` man page on `F_FULLFSYNC`: on macOS, plain `fsync` only reaches the drive's cache.
- NetNewsWire's RSDatabase `DatabaseQueue`: one serial queue owns the connection, and callers never touch the
  handle.
- House: `AtomicFilePublish.swift` (one entry point that owns the temp name, the write, the rename and the cleanup).

**Smells.**

- Rewriting a whole journal to add one line.
- `Data.write(options: .atomic)` for anything the user cannot recreate. It has no fsync, and APFS may show the
  rename before the data.
- `try?` around the write, with a `Bool` that nobody checks.
- A fixed temp name. Two saves then trample each other (the reason `AtomicFilePublish` exists).
- An append from the main actor.
- `sqlite3_exec` with the return code thrown away for a statement that matters (`MetadataCache.exec`,
  Media/MetadataCache.swift:485, is fine only because that store is a cache).
- Durability chosen without a comment that says why.

**Best: `ArchivePromoteJournal.appendRetractable`** (Archive/ArchivePromoteJournal.swift:78). It:

- encodes one JSON line;
- takes `ArchiveIndexLock.withExclusive`;
- opens descriptor-relative with `O_NOFOLLOW`;
- does one `O_APPEND` write and a barrier through `appendDurable` (ArchivePromoteEngine.swift:786, which checks for
  short writes);
- returns a receipt so a refusal can retract exactly its own line;
- throws, so "a promotion whose intent cannot be journaled durably must not start".

For the app-wide ledger's ordered off-main worker, read `MediaLedger.append` / `appendConfirmed`
(Archive/MediaLedger.swift:102/:132). Both journals use `fsync(2)`, not `F_FULLFSYNC`. If that is deliberate, say
so in a comment at `appendDurable`.

**Worst: `FindTagIngestState.save`** (VideoScanCore/FindTagJournal.swift:404). This sidecar records how far the app
has ingested a verdict journal:

- its doc comment says the return value means "the sidecar durably reached disk", but the body is
  `try? encoder.encode` then `data.write(options: .atomic)`, with no fsync and the error dropped;
- its partner `restored(from:)` (:391) reads a damaged file as "nothing applied".

Move it to `AtomicFilePublish.write(…, durability: .fullFsync)` and have it throw. Ingest is idempotent, so the
damaged-as-empty read here costs a re-ingest, not data. Say that in a comment rather than leave it implied.

**Tests.** Logic: encode/decode round trip and a torn last line ignored on read. Scale: append 100k lines and read
them back under budget. Sensor: in the style of `AtomicFilePublishSensorTests`, fail if a store named as curated
writes with `.atomic`.

> C++: an append-only journal is a write-ahead log. `O_APPEND` makes the seek-and-write atomic per `write` call, and
> `F_FULLFSYNC` is the macOS spelling of "really flush, including the disk cache". The chained `Task` is a
> single-consumer work queue without the queue object.

---

## 5. A settings pane

**Pattern.** A setting has **one definition** of each of these: key, default, bounds, and a `load(defaults:)` that
takes the store as a parameter.

- The pane binds to the same keys (`@AppStorage(Key.x)`, or a binding into a value type that saves explicitly).
- The consumer (plan, engine) reads through `load(defaults:)`, so pane and engine agree by construction and a test
  can pass its own `UserDefaults(suiteName:)`.
- Values are clamped on **load**, not only in the UI. A hand-edited `defaults write` or an old build can store
  anything (the 2026-06-14 `combineConcurrency = 0` deadlock).
- A setting that starts or stops a service routes through a model method (`setPreviewSweepEnabled`), not a bare
  binding.
- Under a test host, the default store must not be the real one.

**Skeleton.**

```swift
public struct FrobSettings: Equatable, Sendable {
    public enum Key { public static let workers = "frob.workers"; public static let enabled = "frob.enabled" }
    public static let defaults = FrobSettings(workers: 4, enabled: true)
    public static let workerRange = 1...16
    public var workers: Int; public var enabled: Bool

    /// The ONLY reader. Injected store; clamps whatever is stored.
    public static func load(defaults store: UserDefaults) -> FrobSettings {
        var s = Self.defaults
        if store.object(forKey: Key.workers) != nil {
            s.workers = min(max(store.integer(forKey: Key.workers), workerRange.lowerBound), workerRange.upperBound)
        }
        if store.object(forKey: Key.enabled) != nil { s.enabled = store.bool(forKey: Key.enabled) }
        return s
    }
}

struct FrobSettingsSection: View {
    @AppStorage(FrobSettings.Key.workers) private var workers = FrobSettings.defaults.workers
    @AppStorage(FrobSettings.Key.enabled) private var enabled = FrobSettings.defaults.enabled
    var body: some View {
        Section("Frobnicator") {
            Stepper("Workers: \(workers)", value: $workers, in: FrobSettings.workerRange)
            Toggle("Run in the background", isOn: $enabled)
            Button("Reset to defaults") { workers = FrobSettings.defaults.workers; enabled = FrobSettings.defaults.enabled }
        }
    }
}
```

**Canonical source.**

- SwiftUI data flow: Apple's `AppStorage` and `Settings` scene documentation, and WWDC20 "Data Essentials in
  SwiftUI" (a single source of truth).
- Swift API Design Guidelines (name keys and accessors for what they mean).
- NetNewsWire's `AppDefaults`: one type owns every key, default and typed accessor, and the rest of the app never
  spells a key string.

**Smells.**

- Key strings spelled in two places (`"perf_" + "probesPerVolume"` in one file, the literal in another).
- `nonisolated(unsafe) static let defaults = UserDefaults.standard` hard-wired inside the type, so tests must patch
  global state.
- Clamping only in the `Slider` range.
- A setting read in a view body that does work on change. Do the work in a model method.
- `@AppStorage` for something that must survive a reinstall or travel with the archive. That is not a preference;
  it is data (§9).

**Best: `PruneBarSettingsSection`** (MediaOps/PruneBarSettingsSection.swift:13) with
**`ImportanceBar.load(defaults:)`** (VideoScanCore/PrunePlan.swift:435). The pane's `@AppStorage` keys are
`ImportanceBar.Key.*`, the defaults are `ImportanceBar.defaults`, and the prune plan reads the same keys through an
injected store. Its header says "this pane and the sheet agree by construction". The `AnalyzeSchedule.stored(for:in:)`
(Analyze/AnalyzeCyclers.swift:172) also takes its store as a parameter.

**Worst: `ScanPerformanceSettings`** (Volumes/ScanPerformanceSettings.swift:19). The store is a hard-wired
`nonisolated(unsafe) private static let defaults = UserDefaults.standard`, keys are built by string concatenation
in two functions, and only one of five values is clamped on load (`combineConcurrency`, after the production
deadlock). `AsyncSemaphoreTests` has to work around the fixed store. Give it `Key`, `load(defaults:)` and clamp
every field.

**Tests.** Isolation (the important one): a poisoned suite (`workers = 0`, `-5`, a string where an int belongs)
loads as clamped values. Logic: the pane's reset sets exactly `defaults`. No test writes `.standard`.

> C++: `load(defaults:)` is a factory that takes its config source by reference instead of reaching for a singleton.
> It is dependency injection for the registry.

---

## 6. A background analyzer / cycler

**Pattern.** A cycler is not an MFO job. It has no "done", only "current", and its natural state is running quietly
or paused (Analyze/AnalyzeCyclers.swift:1–8).

- The engine is a **value type composed of injected collaborators**: a plan provider, a store, the per-item work, and
  gate predicates (thermal state, recent user interaction, another bulk job running). It holds no reference to
  `VideoScanModel`, so the same engine runs in-process, in a CLI helper and in tests.
- It runs at `.background` or `.utility`, yields between items, polls cancellation, and stops when the gates say so.
- It writes through the store's API, never into records directly from off-main.
- **Incremental by construction:** a done item stops being a candidate (a stamp such as `dupAnalyzedAt`), so a
  cancelled pass resumes for free.
- A failure goes to a bounded negative cache, so one bad file is not retried every cycle.

**Skeleton.**

```swift
public struct FrobSweepEngine: Sendable {
    public let plan: @Sendable () async -> [FrobCandidate]          // guarded snapshot; [] = superseded
    public let store: any FrobStore                                  // read index + write-through
    public let failures: any FrobFailureStore                        // negative cache, bounded
    public let thermal: @Sendable () -> ProcessInfo.ThermalState
    public let lastInteraction: @Sendable () -> CFAbsoluteTime?
    public let work: @Sendable (FrobCandidate) async throws -> FrobResult
    public let status: @Sendable @MainActor (FrobStatus) -> Void    // the Analyze row

    public func run() async {
        for item in await plan() {
            if Task.isCancelled { return }
            while shouldYield() {                                    // thermal / user is busy
                await status(.paused(reason: "busy")); try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
            }
            guard !failures.contains(item.key), !store.has(item.key) else { continue }
            do { try store.put(try await work(item), for: item.key) }
            catch { failures.record(item.key, error) }
            await Task.yield()
        }
        await status(.current)
    }
    private func shouldYield() -> Bool {
        thermal() >= .serious || (lastInteraction().map { CFAbsoluteTimeGetCurrent() - $0 < 2 } ?? false)
    }
}
```

**Canonical source.**

- Swift Concurrency: task priorities, `Task.yield()`, cooperative cancellation, and `Sendable` closures as
  collaborators.
- Apple's Energy Efficiency Guide for Mac Apps: QoS classes and responding to `ProcessInfo.thermalState`.
- NetNewsWire's `AccountRefreshTimer`: a small timer object that decides *when*, separate from the refresher that
  does the work.

**Smells.**

- A `@MainActor` function that walks every record ("bounded to 50k rows per pass" is still 50k on main).
- An engine that holds `VideoScanModel` (it can't be tested headless or moved to a helper).
- No interaction or thermal gate.
- A per-item failure retried forever.
- Per-item progress lines (cyclers log a START and OUTCOME per pass; MFO jobs log per item).
- A cycler that writes `VideoRecord` fields from a background task.

**Best: `PreviewSweepEngine`** (VideoScanCore/PreviewSweepEngine.swift:35). It is a `Sendable` struct built only
from injected abstractions (plan, `PreviewCache`, `PreviewSweepFailureStore`, thermal, last interaction,
`isExternallyBusy`, a per-path skip, the executor) and main-actor sinks. Its header says it holds "NO reference to
VideoScanModel", so the same engine runs in the app and in the out-of-process helper. The preemption trade-off is
written down (per work item, at most two in flight).

**Worst: `catchUpInferredDates`** (Catalog/VideoScanModel+DateInference.swift:757). It is marked `@MainActor`. It
buckets every eligible record, runs rules 0–3, and scans evidence for up to `limit: 50_000` rows, all synchronously
on main. The Analyze panel calls it directly, with the comment "Runs on the main actor today … moving it off-main is a
Phase C item" (Analyze/AnalyzeRunner.swift:111). The pure rule functions are already `static`, so the migration is:

1. project to a `Sendable` pass input on main;
2. run rules 0–3 in an `@concurrent` function;
3. apply the result on main with a liveness check, as `analyzeDuplicates` does.

**Tests.** Logic: each rule as a pure function. Scale: 100k records under budget, with a sensor asserting the
main-actor share stays below a fixed time. Isolation: inject a fake thermal state and interaction clock.

> C++: the engine is a policy-based struct whose policies are `std::function`s handed in at construction. There are
> no singletons, so a unit test constructs it with fakes.

---

## 7. A decision with several outcomes

**Pattern.** Return an `enum` that names **every** outcome. Each case carries what the caller needs to tell the
person, and to record, *where things are now*. For a multi-step mutation (move a file, then rewrite an index), the
outcome set is:

| Case | Means | The caller must |
|---|---|---|
| `success(Done)` | every step done and verified | adopt the new state |
| `refused(String)` | a guard said no before anything changed | say "nothing was changed" |
| `rolledBack(String)` | something changed and was put back, confirmed | say "undone"; ledger it |
| `incompleteRecovery(String)` | put back, but the flush was not confirmed | keep the backup; ask for a verify |
| `mixedState(String, original: String?)` | putting back failed too | point the record at where the original *is* (found by identity) |

- Switch exhaustively at the caller, with no `default:`, so a new case is a compile error everywhere.
- Each case writes its own ledger outcome string and its own user sentence.
- A refusal is not a failure: in MFO terms it sets `wasRefused`.

**Skeleton.**

```swift
enum RefileOutcome: Sendable, Equatable {
    case refiled(Done)
    case refused(String)
    case rolledBack(String)
    case incompleteRecovery(String)
    case mixedState(String, originalRelPath: String?)
}

@MainActor
func applyRefile(_ plan: RefilePlan) async -> UpdateResult {
    let outcome = await RefileEngine.run(plan)                 // @concurrent; never throws past here
    switch outcome {                                           // NO default: — new cases must be handled
    case .refiled(let done):
        return adopt(done)
    case .refused(let why):
        note("refused: \(why). Nothing was changed.")
        return .init(kind: .refused, message: "Not updated — \(why). Nothing was changed.")
    case .rolledBack(let why):
        ledger(.rolledBack, why); note("ROLLED BACK: \(why)")
        return .init(kind: .rolledBack, message: "Update failed and was undone — \(why).")
    case .incompleteRecovery(let why):
        ledger(.incompleteRecovery, why); keepIndexBackup()
        return .init(kind: .incompleteRecovery, message: "Put back, not confirmed saved. Run Verify Copies.\n\(why)")
    case .mixedState(let why, let originalAt):
        ledger(.mixedState, why, location: originalAt)
        if let originalAt { repointRecord(to: originalAt) }    // identity-checked, never "a file exists there"
        return .init(kind: .mixedState, message: "Could not put it back — \(why)")
    }
}
```

**Canonical source.**

- *The Swift Programming Language*, "Enumerations" (associated values) and "Error Handling" (when to throw and when
  to return a value).
- Swift API Design Guidelines (name cases for what happened, read at the use site: `.rolledBack`, not `.error2`).
- Exhaustive `switch` is Swift's answer to the "forgot one" class.

**Smells.**

- `-> Bool` plus a side-channel `lastError: String?`.
- `throws` for an outcome the caller is *expected* to handle (refused is not exceptional).
- `default:` in the switch.
- One "failed" case that hides "nothing changed" vs "half changed".
- Deciding where the file is with `fileExists`. Use identity (device + inode) instead.
- An outcome that tells the person but writes no ledger line, or the reverse.

**Best: `ArchiveRefile.Outcome`** (Archive/ArchiveRefile.swift:343) and its consumer
(Archive/VideoScanModel+ArchiveUpdate.swift:303). The five cases each have a doc comment that states the on-disk
state. The engine maps internal step errors onto them (`StepError.backupIsSafeToDiscard`), and the consumer switches
exhaustively. Each case writes its own ledger outcome (`"rolledBack"`, `"incompleteRecovery"`, `"mixedState"`) and
its own plain sentence. `mixedState` repoints the record to the original found by identity. `RecordFinderFiling`
(FamilyTree/RecordFinderFiling.swift:147) follows the same shape for documents.

**Worst: `PersonFinderModel.undoLastDelete`** (People/PersonFinderModel.swift:961). `POIStorage.restorePOIFolder`
already returns a four-case enum (`restored`, `destinationExists`, `sourceMissing`, `ioError`). The model flattens it
to `Bool` and puts the reason in `lastUndoError`.

- `sourceMissing` returns `false` *and clears the error*, so a caller can't tell "nothing to undo" from "refused".
- The true case does not say where the folder was restored.

Return the enum (or a `RestoreOutcome` that wraps it) and let the banner switch on it.

**Tests.** Logic: one test per case, each naming its on-disk state. Sensor: a source scan that fails if a data-risk
mutator returns `Bool`, if you want to enforce it.

> C++: an enum with associated values is `std::variant<Done, Refused, RolledBack, …>`, and an exhaustive `switch` is
> `std::visit` with an overload set. The compiler rejects a missing alternative.

---

## 8. A Hallie query path

**Pattern.** Text goes in and an answer with evidence comes out, through typed stages:

1. **Recognise.** Deterministic recognisers, written as ordered *data* (phrase tables or rule arrays where
   "first match wins" is the spec), produce a closed enum of question shapes. If no recogniser claims the
   sentence, the local model translates it into the same closed AST (`ArchivistQueryAST`, a tagged union with
   validated ranges).
2. **Plan.** A pure function (`ArchivistQueryPlanner.plan`) resolves people and returns a closed plan enum. Ambiguity,
   an unknown person and too many people are named outcomes (§7), not strings.
3. **Snapshot.** On main, copy the needed record fields into `Sendable` snapshots, in bounded batches with
   `Task.yield()` between them. Cache the snapshot per catalog revision.
4. **Execute.** A pure, `nonisolated` function over the snapshot. It polls cancellation every N rows, keeps a
   bounded set of citations, and puts a typed **evidence basis** on every claim.
5. **Compose.** One summary function per evidence kind, shared by the chat window, the shell and the conversation
   log, so the wording can't drift.

**Skeleton.**

```swift
enum ThingQuestion: Equatable, Sendable { case count(person: String), list(person: String, year: Int?) }

enum ThingRecogniser {
    /// ORDER IS THE SPEC. Each rule is data; the oracle test pins the order.
    static let rules: [(name: String, match: @Sendable (String) -> ThingQuestion?)] = [
        ("count",  { s in s.firstMatch(of: /how many videos of (?<p>.+)/).map { .count(person: String($0.p)) } }),
        ("list",   { s in s.firstMatch(of: /videos of (?<p>.+?)(?: in (?<y>\d{4}))?$/)
                              .map { .list(person: String($0.p), year: $0.y.flatMap { Int($0) }) } }),
    ]
    static func detect(_ text: String) -> ThingQuestion? {
        let s = text.lowercased()
        for rule in rules { if let q = rule.match(s) { return q } }
        return nil                                            // → translator → ArchivistQueryAST
    }
}

@MainActor
func answer(_ q: ThingQuestion, model: VideoScanModel) async -> ThingAnswer {
    let snaps = await ThingSnapshot.capture(model.records, batchSize: 2_000)   // yields between batches
    return await Task.detached(priority: .userInitiated) {
        ThingExecutor.execute(q, records: snaps)               // pure; cites an EvidenceBasis per hit
    }.value
}
```

**Canonical source.**

- *The Swift Programming Language*, "Enumerations" (associated values, and indirect enums for an AST) and
  "Protocols" (`Sendable`).
- Swift Concurrency: value snapshots across isolation domains.
- Swift API Design Guidelines (cases named for the question asked).
- NetNewsWire's timeline `FetchType` enum: one closed description of "what to show", turned into a fetch by one
  function, never by string matching in the view.

**Smells.**

- A 200-line `if` chain where each line is a phrase (data written as code; lizard can't even measure it).
- Executors that read `VideoRecord` on main for the whole catalog.
- Answer text built in three places.
- A claim with no evidence basis ("transcript mentions X" with no snippet was wrong on 2026-09-05).
- A free-form `[String: Any]` from the model instead of a validated AST.
- Unbounded result arrays.
- Ambiguity handled by picking the first match.

**Best: `ArchivistPresenceExecutor`** (Hallie/ArchivistPresenceExecutor.swift: `capture` :452, `execute` :485).
`capture` is the only main-actor step: bounded batches, `Task.yield()` between them, and a cancellation check per
batch. `execute` is a pure, nonisolated function over immutable snapshots. It polls cancellation every 256 rows,
keeps at most 25 citations while still counting every match, and backs every hit with a typed
`ArchivistEvidenceBasis` that has one shared `summary`. Upstream, `ArchivistQueryAST` (Hallie/ArchivistQueryAST.swift:28)
and `ArchivistQueryPlanner.plan` (Hallie/ArchivistQueryPlanner.swift:180) give the closed AST and closed plan
enums. For a recogniser that was just migrated to the table shape, see `HalliePersonaQuestion`'s phrase tables
(Hallie/HalliePersonaQuestion.swift:125 onward, GH #281 R3), pinned by `HalliePersonaParserOracleTests`.

**Worst: `HallieLineageQuestion.detectShape`** (Hallie/HallieLineageQuestion.swift:228). It is an ordered
first-match `if` chain of about 48 decision points over 207 lines, in a 2,077-line file with 95 regex call sites.
N1007-D-Hallie-rewrite-eval measured 84 branch leaves, 11 of which no corpus or test string reaches, and one of which
(p9) is dead, shadowed by an earlier pattern. Its order is load-bearing and pinned only by comments. Migrate it the
way the persona parser went: an ordered rule array behind a back-to-back oracle test against a frozen copy of the
old chain.

**Tests.** Logic: per-rule cases and the oracle (old chain vs new table over every corpus and test sentence). Scale:
`execute` over 100k snapshots under budget. Isolation: a temp-root configuration for any CyberBrain or family-tree
read (HallieTurnExecutor.swift:976).

> C++: the AST is a `std::variant` of structs. `rules` is a `std::vector<std::pair<const char*, std::function<…>>>`
> walked in order. `capture` copies POD rows out under the UI lock, and `execute` is a `const` free function over a
> `std::span<const Row>`.

---

## 9. Saving a hand-curated JSON file

This bug class was found **five times** in recent reviews: N1009-D-Core-F1 (identity rulings),
N1012-R-FamilyTree-writes-F2 (photo "not of" sidecar), N1020-D-People-F1 (validation labels), N1020-D-People-F4
(holdout clears) and N1013-D-FamilyTree-F2 (bookmarks). It always goes the same way: the file stops decoding (a hand
edit, a sync-tool conflict copy, a newer build's enum case, a damaged block), `load` returns empty, and the next
single edit saves over everything.

**Pattern.** Use two readers and one writer.

- **`load` (display)** may stay lenient: missing *or* damaged reads as empty, so the window still opens. It must log
  🔴 on damaged and must not cache that empty value for writing.
- **`loadForUpdate` (before any save)** must tell three cases apart:
  1. **missing** (ENOENT): empty is the truth;
  2. **readable**: the decoded value;
  3. **present but unreadable or undecodable** (including an unknown `storeVersion`): **move it aside** with
     `DamagedFileSetAside.move` (a `renamex_np(RENAME_EXCL)` to `<name>.damaged-<ISO8601>`, never copy or
     delete), log 🔴 with the path and how to restore it, then continue from empty. If the move fails, **throw**
     and leave the bytes where they are.
- **Read-modify-write** re-reads from disk under one lock (process-wide `NSLock`, or the archive index lock).
  Apply the single change to the fresh copy, never to a load-time copy (N1012-F1, N1013-F2 scenario B: two windows
  or two Macs).
- **Publish** with `AtomicFilePublish.write(data, to:, durability: .fullFsync)`. Report the caught error's own
  errno, not the global `errno`, which is stale after cleanup (N1013-F3).
- **Forward compatibility:** a file from a newer `storeVersion` is "damaged" for *writing*. Never downgrade it in
  place.

**Skeleton.**

```swift
enum CuratedStore {
    private static let lock = NSLock()                         // one RMW at a time, process-wide

    static func mutate(_ url: URL, log: (String) -> Void, _ change: (inout Curated) -> Void) throws {
        try lock.withLock {
            var doc = try loadForUpdate(url, log: log)         // ALWAYS from disk, never a cached copy
            change(&doc)
            let data = try encoder.encode(doc)
            try AtomicFilePublish.write(data, to: url, durability: .fullFsync, createIntermediates: false)
        }
    }

    /// missing → empty · readable → value · damaged → moved aside, then empty · can't move → throw
    static func loadForUpdate(_ url: URL, log: (String) -> Void) throws -> Curated {
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch where isMissingFile(error) { return Curated() }
        catch { return try setAside(url, why: error.localizedDescription, log: log) }
        guard let doc = try? decoder.decode(Curated.self, from: data),
              doc.storeVersion <= Curated.currentVersion else {
            return try setAside(url, why: "not readable as this file's format", log: log)
        }
        return doc
    }

    private static func setAside(_ url: URL, why: String, log: (String) -> Void) throws -> Curated {
        do {
            let kept = try DamagedFileSetAside.move(url)        // RENAME_EXCL, never delete
            log("🔴 \(url.lastPathComponent) could not be read (\(why)) — moved aside to \(kept.path); fix it and rename it back to restore.")
            return Curated()
        } catch {
            log("🔴 \(url.lastPathComponent) could not be read (\(why)) and could not be set aside — nothing was saved.")
            throw error                                          // refuse; bytes untouched
        }
    }
}
```

**Canonical source.**

- Apple, "Encoding and Decoding Custom Types" (Codable). A decode failure is all-or-nothing over an array.
- POSIX `rename(2)` and Apple's `renamex_np(2)` (`RENAME_EXCL`).
- `fcntl(2)` `F_FULLFSYNC`.
- House: `DamagedFileSetAside.swift` (VideoScanCore) and `AtomicFilePublish.swift` headers.

**Smells.**

- `(try? Data(contentsOf:)).flatMap { try? decode } ?? Empty()` on any path that later saves.
- `guard let data = try? … else { return }` in a `load` that leaves `labels = []` and logs nothing.
- `save()` writing `self.items` (the load-time copy) instead of re-reading.
- `Data.write(options: .atomic)` for curated data.
- A `poison_…StartEmpty` test that checks only the load half. Every such test needs a partner that saves once and
  asserts the original bytes survive.
- A version check that returns `nil`, and the caller then saves at the old version.

**Best: `FamilyAssetStore.excludePhoto`** (FamilyTree/FamilyAssetStore.swift:1055) with `loadExclusionForUpdate`
(:1096). It is the N1012-F2 fix and does everything above: three-way load (missing / readable / damaged); damaged
bytes moved aside through the shared `DamagedFileSetAside.move` with a 🔴 line that says how to restore; a refusal
when the move fails; the read-modify-write under one process-wide lock, always from disk; publish through
`AtomicFilePublish … .fullFsync` with `createIntermediates: false`; and the real errno from `posixCode(of:)`.
`PersonFactOverlayStore.loadForUpdate` (VideoScanCore/PersonFactOverlay.swift:361) is the Core equivalent.

**Worst: `ValidationLabelStore`** (People/ValidationLabelStore.swift: `load` :54, `save` :64). `load` is
`guard let data = try? Data(contentsOf:) else { return }` then `if let decoded = try? decode`. On failure it logs
nothing and leaves `labels = []`. Then `record(…)` appends one row and `save()` rewrites the file with
`.atomic`, no backup and no fsync. One unknown `ConfirmRating` case from a newer build erases every hand rating
(N1020-D-People-F1, still open). The existing isolation test pins today's behaviour (`labels.count == 1`) and
needs reversing. Next in line, the same shape: `HoldoutClearStore`, `FamilyTreeBookmarks.load/save`
(FamilyTree/FamilyTreeBookmarks.swift:84/:101), `FamilyIdentityDecisions` (fix on a branch) and
`MediaPersonLinks.swift:182`. There are 41 `.atomic)` write sites in the app and Core. Sort them into curated vs
cache and move the curated ones.

**Tests.** Isolation (the point): write `"{ not json"`, then a valid file with `storeVersion: 999`; call the
mutator once; assert a `.damaged-*` sibling holds the original bytes and the new file holds only the new edit. A
second test makes the folder unwritable for the rename and asserts that the mutator throws and the bytes are
unchanged. Concurrency: two models on one directory each toggle one entry, and the file holds both.

> C++: `loadForUpdate` is a `std::expected<Doc, LoadError>` where `LoadError::Damaged` is never silently converted
> to `Doc{}`. Moving aside is `rename(path, path + ".damaged-…")` with `RENAME_EXCL`. The mutex makes the
> read-modify-write a critical section, like a compare-and-swap whose "compare" is "I just re-read it under the
> lock".

---

## 10. How to use this in a brief or review

**In a brief.** Name the section and the best example: "Implement as an MFO job per swift_playbook §1; copy the
shape of `PerceptualFingerprintBackfillJob`." Then list only the deviations. List which of the five test dimensions
apply; each section's **Tests** line is the starting checklist. For data-risk work (§4, §7, §9 and the publish half
of §3), add `/safety-critical` and plan a bundled codex pass.

**In a review.** For each changed function, ask "which job is this?", then check it against that section's
**Smells**. A smell is a finding only once you've named the concrete failing scenario and looked for the guard that
would make it false (cloud README rule 6). The **Worst** examples are known debt, not new findings. Cite them as
"migration candidate, playbook §N" so they aren't re-reported each night.

**When a pick goes stale.** If a Worst example gets migrated, replace it with the next one listed in its section
and update the summary table. If a better Best appears, swap it and say why in one sentence. Line numbers drift.
The symbol (`Type.function`) is the stable key, as in the findings rules.

**Not covered here** (candidates for a later revision): a sheet or modal that confirms a destructive plan, a
Vision/CoreML face pass, a SwiftData or CloudKit path (none in the app today), and the TestDriver UI-test shape.

## Blockers & environment

- Linux cloud session. No Xcode, so nothing was built and no test was run. Every pick comes from reading source at
  main@1cf5bbea.
- `ci/baselines/complexity_debt.json` was not consulted. The §8 complexity numbers come from
  `docs/reviews/cloud/N1007-D-Hallie-rewrite-eval.md`.
- The external canonical sources (Apple documentation, WWDC sessions, NetNewsWire) are cited from knowledge. They
  were not fetched in this session, so a reader on the Mac should check any type name quoted from NetNewsWire
  before relying on it.
- The brief row says to commit on `cloud/N1007-P-swift-playbook`. The Manager's dispatch for this run said not to
  commit or push, so this file is left uncommitted in the working tree.
