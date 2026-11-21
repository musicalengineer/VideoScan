import Testing
import Combine
import Foundation
@testable import VideoScan
@_spi(Testing) import VideoScanCore   // LogExpectation / LogLineMatcher (expectingLog, LogSinks+Test.swift)

// MARK: - MFO file-log START/OUTCOME summaries (2026-07-18)
//
// Every MFO job writes exactly ONE start line and ONE terminal line to
// `appLog` (videoscan.log). Motivating gap: a Balance Audio render
// failure (ffmpeg exit 183) never reached videoscan.log — the failure
// text lived only in the MFO window and OSLog, so the file-log
// postmortem went cold after the "dropping silent audio track(s)"
// notice. These tests pin:
//
//   - the exact line format per terminal state (done / FAILED /
//     refused / cancelled) — pure, via the static builders;
//   - the Center's terminal watcher: exactly-once OUTCOME per job, no
//     duplicates across the change-event flood, refused wording,
//     already-terminal-at-add coverage, same-turn clearFinished;
//   - end-to-end one-start-one-terminal through real jobs (compare
//     Tier-1 duplicate / compare fail / cleanup fail-fast / trim
//     duplicate-refusal) — including that the jobs' REMOVED ad-hoc
//     appLog lines don't come back (no double start, no double done).
//
// Each test binds its own InMemoryLogSink for its task tree
// (`expectingLog` / `withAppLog`, see LogSinks+Test.swift), so the suites
// run in parallel and no other test's line can reach a sink.

// MARK: - Fake job

/// Minimal conformer whose state the tests drive directly. `@Published`
/// on the stored state means every assignment fires `objectWillChange`
/// — exactly what a real job's terminal transition does.
@MainActor
private final class FakeSummaryJob: @MainActor MediaFileOperationJob {
    let id = UUID()
    let kind: MediaFileOperationKind
    let title: String
    var subtitle: String = ""
    var fraction: Double = 0
    var isIndeterminate = false
    let startedAt = Date()
    var finishedAt: Date?

    @Published var settableState: MediaFileOperationState
    var state: MediaFileOperationState { settableState }

    /// Backs the protocol's `wasRefused` (defaulted false for every
    /// other conformer).
    var refused = false
    var wasRefused: Bool { refused }

    init(kind: MediaFileOperationKind = .trim,
         title: String = "fake.mov",
         state: MediaFileOperationState = .running) {
        self.kind = kind
        self.title = title
        self.settableState = state
    }

    func cancel() { settableState = .cancelled }
}

// MARK: - Shared helpers

/// Let the Center's deferred (next-main-actor-turn) terminal checks run,
/// polling until `condition` holds or the bounded budget runs out.
/// Yield-driven, so a passing test finishes in microseconds.
@MainActor
private func drainMainActor(until condition: () -> Bool) async {
    for i in 0..<400 {
        if condition() { return }
        if i % 40 == 39 {
            try? await Task.sleep(nanoseconds: 5_000_000)   // 5 ms backstop
        } else {
            await Task.yield()
        }
    }
}

// MARK: - Pure line-format tests

@Suite("MFO summary line formats (pure)")
struct MFOSummaryLineFormatTests {

    @Test func startLineFormat() {
        #expect(MediaFileOperationsCenter.startSummaryLine(
            verb: "balance audio", title: "Clip 28.dv",
            plan: "rightOnly → Clip 28_balanced.mov")
            == "balance audio: Clip 28.dv — rightOnly → Clip 28_balanced.mov")
    }

    @Test func doneLineFormat() {
        #expect(MediaFileOperationsCenter.terminalSummaryLine(
            verb: "trim", title: "tape7.mxf",
            state: .finished(summary: "Trimmed → tape7_trimmed.mxf (1.2 GB)"),
            wasRefused: false)
            == "trim done: tape7.mxf — Trimmed → tape7_trimmed.mxf (1.2 GB)")
    }

    /// The FAILED line carries the SAME user-facing reason the MFO
    /// window shows — the exact gap from the 2026-07-17 Balance Audio
    /// postmortem (ffmpeg exit + stderr clause only in the window).
    @Test func failedLineFormat() {
        #expect(MediaFileOperationsCenter.terminalSummaryLine(
            verb: "balance audio", title: "Clip 28.dv",
            state: .failed(message: "Conversion failed (ffmpeg exit 183)"),
            wasRefused: false)
            == "balance audio FAILED: Clip 28.dv — Conversion failed (ffmpeg exit 183)")
    }

    @Test func refusedLineFormat() {
        #expect(MediaFileOperationsCenter.terminalSummaryLine(
            verb: "trim", title: "tape7.mxf",
            state: .failed(message: "A trim of tape7.mxf is already running"),
            wasRefused: true)
            == "trim refused: tape7.mxf — A trim of tape7.mxf is already running")
    }

    @Test func cancelledLineFormat() {
        #expect(MediaFileOperationsCenter.terminalSummaryLine(
            verb: "compare", title: "a.mov vs b.mov",
            state: .cancelled, wasRefused: false)
            == "compare cancelled: a.mov vs b.mov")
    }

    // Negative: active states have no OUTCOME line.
    @Test func activeStatesProduceNoLine() {
        for state: MediaFileOperationState in [.running, .cancelling] {
            #expect(MediaFileOperationsCenter.terminalSummaryLine(
                verb: "trim", title: "x", state: state, wasRefused: false) == nil)
        }
    }

    /// Pin the verb per kind — greps over historical logs depend on the
    /// wording staying put ("balance audio", not "balanceAudio").
    @Test func logVerbMapping() {
        #expect(MediaFileOperationKind.combine.logVerb == "combine")
        #expect(MediaFileOperationKind.compare.logVerb == "compare")
        #expect(MediaFileOperationKind.extract.logVerb == "extract faces")
        #expect(MediaFileOperationKind.ripFrames.logVerb == "extract frames")
        #expect(MediaFileOperationKind.reformat.logVerb == "reformat")
        #expect(MediaFileOperationKind.analyze.logVerb == "analyze")
        #expect(MediaFileOperationKind.transcode.logVerb == "transcode")
        #expect(MediaFileOperationKind.cleanup.logVerb == "cleanup")
        #expect(MediaFileOperationKind.trim.logVerb == "trim")
        #expect(MediaFileOperationKind.balanceAudio.logVerb == "balance audio")
    }
}

// MARK: - Center terminal watcher (fake jobs)
//
// Each test states the lines it expects up front (`expectingLog`, the
// gmock-shaped layer in LogSinks+Test.swift): `.once(.equals(line))` plus
// `.noOtherLines(matching: .contains(name))` is "exactly this one line
// mentions my file". The scope waits (bounded) for the OUTCOME, which the
// Center writes one main-actor turn after the terminal state lands.
//
// Every body RETURNS its Center: the OUTCOME hop holds the Center weakly,
// so it must outlive the body while the scope waits for the line.
// (C++: the mock outlives the call under test; here the object under test
// must outlive the wait for its asynchronous call into the mock.)

@MainActor
@Suite("MFO Center OUTCOME watcher")
struct MFOCenterOutcomeWatcherTests {

    @Test func finishedJobWritesExactlyOneDoneLine() async {
        let name = "fake-\(UUID().uuidString).mov"
        await expectingLog(
            .once(.equals("trim done: \(name) — ok")),
            .noOtherLines(matching: .contains(name))
        ) {
            let center = MediaFileOperationsCenter()
            let job = FakeSummaryJob(kind: .trim, title: name)
            center.add(job)
            job.settableState = .finished(summary: "ok")
            return center
        }
    }

    /// Regression (2026-11-20, log seam): the OUTCOME hop starts from the
    /// job's change publisher, so it runs in whatever task published the
    /// terminal state — here a detached one, with no task-locals. The
    /// Center writes the line under the scope the job was ADDED in.
    @Test("regression: a terminal state published from outside the task tree still writes its OUTCOME to the adder's capture")
    func outcomeFromADetachedPublisherReachesTheAddersCapture() async {
        let name = "fake-\(UUID().uuidString).mov"
        await expectingLog(
            .once(.equals("trim done: \(name) — ok")),
            .noOtherLines(matching: .contains(name)),
            waitingUpTo: .seconds(120)
        ) {
            let center = MediaFileOperationsCenter()
            let job = FakeSummaryJob(kind: .trim, title: name)
            center.add(job)
            await Task.detached { @MainActor in job.settableState = .finished(summary: "ok") }.value
            return center
        }
    }

    /// The change-event flood must not double the OUTCOME: keep firing
    /// state re-assignments after the terminal transition (a real job
    /// publishes subtitle/fraction churn from straggler beats).
    @Test func terminalLineIsWrittenOnlyOnceDespiteEventFlood() async {
        let name = "fake-\(UUID().uuidString).mov"
        let sink = InMemoryLogSink()
        await expectingLog(.once(.contains(name)), sink: sink) {
            let center = MediaFileOperationsCenter()
            let job = FakeSummaryJob(kind: .cleanup, title: name)
            center.add(job)
            job.settableState = .finished(summary: "done clause")
            for _ in 0..<10 {
                job.settableState = .finished(summary: "done clause")   // re-fires objectWillChange
                await Task.yield()
            }
            await drainMainActor { sink.contains(name) }
            await drainMainActor { false }   // exhaust any stragglers: a second line would be here by now
            return center
        }
    }

    /// A job can arrive at the Center already terminal (the parked
    /// refused row) — it never publishes another change, so `add` must
    /// check once by itself.
    @Test func alreadyTerminalJobAtAddStillGetsItsLine() async {
        let name = "fake-\(UUID().uuidString).mov"
        await expectingLog(
            .once(.equals("compare FAILED: \(name) — boom")),
            .noOtherLines(matching: .contains(name))
        ) {
            let center = MediaFileOperationsCenter()
            center.add(FakeSummaryJob(kind: .compare, title: name,
                                      state: .failed(message: "boom")))
            return center
        }
    }

    @Test func refusedFlagFlipsWordingToRefused() async {
        let name = "fake-\(UUID().uuidString).mov"
        await expectingLog(
            .once(.equals("balance audio refused: \(name) — safety gate said no")),
            .noOtherLines(matching: .contains(name))
        ) {
            let center = MediaFileOperationsCenter()
            let job = FakeSummaryJob(kind: .balanceAudio, title: name)
            job.refused = true
            center.add(job)
            job.settableState = .failed(message: "safety gate said no")
            return center
        }
    }

    @Test func cancelledJobWritesCancelledLine() async {
        let name = "fake-\(UUID().uuidString).mov"
        await expectingLog(
            .once(.equals("extract frames cancelled: \(name)")),
            .noOtherLines(matching: .contains(name))
        ) {
            let center = MediaFileOperationsCenter()
            let job = FakeSummaryJob(kind: .ripFrames, title: name)
            center.add(job)
            job.settableState = .cancelling            // active — no line yet
            job.settableState = .cancelled
            return center
        }
    }

    /// clearFinished in the SAME main-actor turn as the terminal
    /// transition: the deferred check hasn't run yet, so the removal
    /// path must write the line synchronously — and the deferred check
    /// must not double it afterwards.
    @Test func sameTurnClearFinishedStillWritesExactlyOneLine() async {
        let name = "fake-\(UUID().uuidString).mov"
        let sink = InMemoryLogSink()
        await expectingLog(
            .once(.equals("transcode done: \(name) — ok")),
            .noOtherLines(matching: .contains(name)),
            sink: sink
        ) {
            let center = MediaFileOperationsCenter()
            let job = FakeSummaryJob(kind: .transcode, title: name)
            center.add(job)
            job.settableState = .finished(summary: "ok")
            center.clearFinished()                     // same turn — no awaits between
            // Checked HERE, before any suspension: the line is already written.
            sink.verify(.once(.equals("transcode done: \(name) — ok")))

            await drainMainActor { false }             // let the deferred check land; the scope then proves it added nothing
            return center
        }
    }
}

// MARK: - End-to-end through real jobs

@MainActor
@Suite("MFO log summaries end-to-end")
struct MFOLogSummaryEndToEndTests {

    private func record(_ path: String,
                        streamType: StreamType = .videoAndAudio) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = streamType.rawValue
        return r
    }

    /// Compare two byte-identical temp files (Tier 1 — no ffmpeg):
    /// exactly one START line and one "compare done:" line, in order.
    @Test func compareWritesOneStartAndOneDoneLine() async throws {
        let stem = "dup-\(UUID().uuidString.prefix(8))"
        let start = "compare: \(stem)A.bin vs \(stem)B.bin — duplicate check"
        let done = "compare done: \(stem)A.bin vs \(stem)B.bin — \(PairCompareVerdict.exactDuplicates.title)"
        try await expectingLog(
            .once(.equals(start)),
            .once(.equals(done)),
            .inOrder(.equals(start), .equals(done)),
            .noOtherLines(matching: .contains(stem))
        ) {
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("MFOLogTests-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: dir) }
            let bytes = Data(repeating: 0x42, count: 64 * 1024)
            let a = dir.appendingPathComponent("\(stem)A.bin").path
            let b = dir.appendingPathComponent("\(stem)B.bin").path
            FileManager.default.createFile(atPath: a, contents: bytes)
            FileManager.default.createFile(atPath: b, contents: bytes)

            let center = MediaFileOperationsCenter()
            let job = center.startCompare(recordA: record(a), recordB: record(b))
            await job.task?.value
            return center
        }
    }

    /// Compare against a missing file: the OUTCOME is a FAILED line
    /// carrying the job's user-facing reason.
    @Test func compareFailureWritesFailedLine() async throws {
        let stem = "missing-\(UUID().uuidString.prefix(8))"
        let started = LogLineMatcher.all(.hasPrefix("compare: "), .contains(stem))
        let failed = LogLineMatcher.all(.hasPrefix("compare FAILED: "), .contains(stem))
        let ((_, job), log) = await expectingLog(
            .once(started),
            .once(failed),
            .inOrder(started, failed),
            .noOtherLines(matching: .contains(stem))
        ) {
            let a = "/tmp/MFOLogTests-\(stem)-a.bin"
            let b = "/tmp/MFOLogTests-\(stem)-b.bin"

            let center = MediaFileOperationsCenter()
            let job = center.startCompare(recordA: record(a), recordB: record(b))
            await job.task?.value
            return (center, job)
        }
        // The reason is known only now: checked after, on the same capture.
        guard case .failed(let message) = job.state else {
            Issue.record("expected .failed, got \(job.state)")
            return
        }
        log.verify(.once(.all(failed, .hasSuffix(message))))
    }

    /// Cleanup on a missing source fails fast (no ffmpeg): exactly one
    /// START (the Center's — CleanupJob's old ad-hoc start line was
    /// removed, this pins that it stays removed) and one FAILED line.
    @Test func cleanupFailFastWritesOneStartOneFailed() async throws {
        let stem = "cleanup-\(UUID().uuidString.prefix(8))"
        let started = LogLineMatcher.hasPrefix("cleanup: MFOLogTests-\(stem).mov — ")
        let failed = LogLineMatcher.all(.hasPrefix("cleanup FAILED: "), .contains(stem),
                                        .contains("Source file missing on disk"))
        await expectingLog(
            .once(started),
            .once(failed),
            .inOrder(started, failed),
            .never(.hasPrefix("cleanup done: ")),
            .noOtherLines(matching: .contains(stem))
        ) {
            let missing = "/tmp/MFOLogTests-\(stem).mov"
            let source = makeCleanupSourceRecord(path: missing,
                                                 durationSeconds: 0,
                                                 fieldOrder: "tt")

            let center = MediaFileOperationsCenter()
            let job = center.startCleanup(record: source,
                                          recipe: CleanupRecipeRegistry.vhsQuickClean,
                                          model: VideoScanModel())
            await job.task?.value
            return center
        }
    }

    /// Duplicate trim dispatch: the second job is refused — one
    /// "trim refused:" line, NO start line for it (nothing started).
    /// The first job runs (and fails on the missing source) with its
    /// own one start + one FAILED pair.
    @Test func duplicateTrimDispatchWritesRefusedLine() async throws {
        let stem = "trim-\(UUID().uuidString.prefix(8))"
        // first job: start + FAILED; second job: refused only.
        await expectingLog(
            .once(.all(.hasPrefix("trim: "), .contains(stem))),
            .once(.all(.hasPrefix("trim FAILED: "), .contains(stem))),
            .once(.all(.hasPrefix("trim refused: "), .contains(stem))),
            .noOtherLines(matching: .contains(stem))
        ) {
            let missing = "/tmp/MFOLogTests-\(stem).mov"
            let source = record(missing)
            let range = TrimRange(inSeconds: 0, outSeconds: 1)
            let model = VideoScanModel()

            let center = MediaFileOperationsCenter()
            // Same main-actor turn: the first job's run Task hasn't begun,
            // so it is still .running when the second dispatch arrives.
            let first = center.startTrim(record: source, range: range, model: model)
            let second = center.startTrim(record: source, range: range, model: model)
            #expect(second.wasRefused)

            await first.task?.value
            await second.task?.value
            return center
        }
    }

    /// Balance duplicate dispatch returns nil (no job row) — the
    /// Center writes the refused line directly.
    @Test func duplicateBalanceDispatchWritesRefusedLine() async throws {
        let sink = InMemoryLogSink()
        withAppLog(sink) {
            let stem = "balance-\(UUID().uuidString.prefix(8))"
            let path = "/tmp/MFOLogTests-\(stem).mov"
            let source = record(path)
            let analysis = AudioBalanceAnalysis(
                classification: .leftOnly,
                measurements: AudioBalanceMeasurements(
                    channels: [AudioChannelLevels(rmsDBFS: -20, peakDBFS: -10),
                               AudioChannelLevels(rmsDBFS: -90, peakDBFS: -80)],
                    differenceRMSDBFS: nil),
                shape: AudioBalanceStreamShape(
                    videoCodec: "h264", totalStreams: 2, videoStreams: 1,
                    audioStreams: 1, audioCodec: "aac", audioChannels: 2,
                    audioBitRate: nil, durationSeconds: 1,
                    audioStreamInfos: [AudioBalanceStreamInfo(
                        absoluteIndex: 1, codec: "aac", channels: 2, bitRate: nil)]),
                programStreamCount: 1,
                programStreamIndex: 1,
                droppedStreamIndices: [])
            let model = VideoScanModel()

            let center = MediaFileOperationsCenter()
            // Park an ACTIVE (never-started, so state stays .running)
            // balance job for the record, then dispatch a duplicate.
            let parked = BalanceAudioJob(record: source, analysis: analysis, model: model)
            center.add(parked)
            let refused = center.startBalanceAudio(record: source, analysis: analysis,
                                                   model: model)
            #expect(refused == nil)

            // Checked after, and BEFORE the cancel below (which writes its
            // own "cancelled" line for the parked row): the refusal is
            // written synchronously by the dispatch.
            sink.verify(
                .once(.all(.hasPrefix("balance audio refused: "), .contains(stem), .contains("already running"))),
                .noOtherLines(matching: .contains(stem)))

            parked.cancel()   // don't leave an active fake row behind
        }
    }

    /// TrimJob.refuseToStart marks the job refused — the flag the
    /// Center's OUTCOME line keys the wording on.
    @Test func trimRefuseToStartSetsWasRefused() {
        let job = TrimJob(record: record("/tmp/x.mov"),
                          range: TrimRange(inSeconds: 0, outSeconds: 1),
                          model: VideoScanModel())
        #expect(!job.wasRefused)
        job.refuseToStart(reason: "duplicate")
        #expect(job.wasRefused)
        #expect(job.state == .failed(message: "duplicate"))
    }
}
