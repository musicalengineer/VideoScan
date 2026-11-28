// AVSyncJob.swift
// ONE SENTENCE: the one engine of "Check A/V Sync" (CLAUDE.md rule 4) — for
// each processed file and its original, read both through ffmpeg, measure the
// sound-vs-picture shift (VideoScanCore AVSyncAnalyzer) and say it in words.
//
// Design: docs/design/av_sync_analysis.md §6. An MFO job (rule 5): a row with
// progress, Pause/Stop, a per-pair detail on double-click, START from the
// Center, one log line per pair, and the OUTCOME line the Center writes at the
// terminal transition. The menu verb (Analyze ▸ Check A/V Sync…) and, later,
// the background cycler call THIS job.
//
// It reads, never writes media: both files are opened by ffmpeg read-only and
// piped. Every check that can say no runs before the first read (§10.6):
// both files must carry a whole-file SHA-256 (identity is the digest — the
// result is keyed by both), must be different content, must be reachable, and
// must still be the size the catalog knows. Their size and modification date
// are taken again after the read; a file that changed while it was read gives
// no result ("refuse rather than guess").
//
// SPEED (Rick 2026-11-28): the two files of a pair are read at the same time
// (they usually sit on different drives, and the read is drive-bound), and
// each file's signals are kept for the session (AVSyncEvidenceCache) so an
// original compared against several processed versions is read once.
//
// Pause: the pause coordinator's ProcessControl SIGSTOPs every live ffmpeg
// child (sound and picture of both files — four), and the stall watchdog is
// held while paused. Stop cancels the task; ProcessRunner kills the children.
// A read that fails cancels the other; the failure names its side.
//
// MEMORY: per pair, each reader holds its file's PCM (8 kHz Int16: 57.6 MB
// per hour of sound — two files at once now) plus both files' signals
// (≈ 17 MB per 2 hours); the reports kept on the items are ≈ 200 B per window.
//
// (For Rick: `@MainActor final class` ≈ a C++ object whose methods all run on
// the UI thread; the `await`s are where it yields while ffmpeg works.)

import Combine
import Foundation
import os
import SwiftUI
import VideoScanCore

private let avSyncLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fileOps")

@MainActor
final class AVSyncJob: @MainActor MediaFileOperationJob, MediaFileOperationOwnDetail {

    struct Pair: Sendable, Identifiable, Equatable {
        let id = UUID()
        let processed: AVSyncSide
        let original: AVSyncSide
    }

    enum Outcome: Sendable, Equatable {
        case measured(AVSyncReport)
        /// A gate said no before anything was read (or the file changed).
        case refused(String)
        case failed(String)
        case cancelled

        var words: String {
            switch self {
            case let .measured(report): return report.sentence
            case let .refused(why): return "not checked: \(why)"
            case let .failed(why): return "failed: \(why)"
            case .cancelled: return "stopped"
            }
        }
    }

    struct Item: Identifiable {
        let pair: Pair
        var outcome: Outcome?
        var id: UUID { pair.id }
    }

    /// Size and modification date — "is it still the same file?".
    struct FileStamp: Equatable, Sendable {
        let size: Int64
        let modified: Date
    }

    /// Test seams. Production: the real reader and a stat of the path.
    typealias Reader = @Sendable (AVSyncSide, ProcessControl, @escaping @Sendable (Double?) -> Void) async throws
        -> AVSyncFileEvidence
    typealias Stat = @Sendable (String) -> FileStamp?

    nonisolated static let realReader: Reader = { side, control, progress in
        try await AVSyncSignalReader().read(path: side.path, expectedDurationSeconds: expectedDuration(of: side),
                                            control: control, progress: progress)
    }

    /// The catalog's duration, or nil when it does not know one (0 or less —
    /// review F3: never "zero seconds long", which made a 10-minute deadline
    /// and no progress ticks for the stall watchdog).
    nonisolated static func expectedDuration(of side: AVSyncSide) -> Double? {
        AVSyncSignalReader.knownDuration(side.durationSeconds)
    }

    /// Does the side's stored stamp still describe the file on disk?
    typealias Vouch = @Sendable (AVSyncSide) -> Bool

    /// No stamp (the digest came from an archive fixity): size governs.
    nonisolated static let realVouch: Vouch = { side in
        guard let fixity = side.fixity else { return true }
        return fixity.describesFileNow(FileIdentityStamp.capture(path: side.path))
    }

    nonisolated static let realStat: Stat = { path in
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = (attrs[.size] as? NSNumber)?.int64Value,
              let modified = attrs[.modificationDate] as? Date else { return nil }
        return FileStamp(size: size, modified: modified)
    }

    let id = UUID()
    let kind: MediaFileOperationKind = .checkAVSync
    let startedAt = Date()
    let policy: AVSyncPolicy

    @Published private(set) var items: [Item]
    @Published private(set) var state: MediaFileOperationState = .running
    @Published private(set) var finishedAt: Date?
    @Published private(set) var fraction: Double = 0
    @Published private(set) var status = "Starting…"
    @Published private(set) var waitingForVolumeLabel: String?
    private(set) var wasRefused = false

    private let store: AVSyncResultStore
    private let reader: Reader
    private let stat: Stat
    private let vouch: Vouch
    private let gatesFor: (Pair) -> [MediaVolumeGate]
    private let cache: AVSyncEvidenceCache
    private let readerIdentity: String
    /// Read fraction of the current pair's original [0] and processed [1].
    private var sideFractions: [Double] = [0, 0]
    private let pauseCoordinator = JobPauseCoordinator()
    private var stallMonitor: StallMonitor?
    private var stallReason: String?
    private var wasCancelled = false
    /// The run task — internal so tests can await it.
    private(set) var task: Task<Void, Never>?

    init(pairs: [Pair], store: AVSyncResultStore, policy: AVSyncPolicy = .default,
         gatesFor: @escaping (Pair) -> [MediaVolumeGate] = { _ in [] },
         reader: @escaping Reader = AVSyncJob.realReader, stat: @escaping Stat = AVSyncJob.realStat,
         vouch: @escaping Vouch = AVSyncJob.realVouch,
         cache: AVSyncEvidenceCache = AVSyncEvidenceCache(), readerIdentity: String = AVSyncSignalReader().identity) {
        items = pairs.map { Item(pair: $0, outcome: nil) }
        self.cache = cache
        self.readerIdentity = readerIdentity
        self.store = store
        self.policy = policy
        self.gatesFor = gatesFor
        self.reader = reader
        self.stat = stat
        self.vouch = vouch
    }

    /// True while the stall watchdog is running (tests: never while queued
    /// for a volume gate).
    var isWatchingForStall: Bool { stallMonitor?.isRunningForTesting ?? false }

    // MARK: MediaFileOperationJob

    var title: String {
        guard let first = items.first else { return "Check A/V Sync" }
        if items.count == 1 { return "\(first.pair.processed.filename) vs \(first.pair.original.filename)" }
        return "\(items.count) files against their originals"
    }

    var subtitle: String {
        if let label = waitingForVolumeLabel { return "Waiting for \(label)…" }
        switch state {
        case .running: return pauseCoordinator.isPaused ? "Paused — \(status)" : status
        case .cancelling: return "Stopping…"
        case let .finished(summary): return summary
        case let .failed(message): return message
        case .cancelled: return "Stopped"
        }
    }

    var isIndeterminate: Bool { waitingForVolumeLabel != nil }
    var canPause: Bool { true }
    var isPaused: Bool { pauseCoordinator.isPaused }

    func pause() {
        guard state.isActive, pauseCoordinator.pause() else { return }
        objectWillChange.send()
        avSyncLog.info("check a/v sync paused: \(self.title, privacy: .public)")
    }

    func resume() {
        guard pauseCoordinator.resume() else { return }
        objectWillChange.send()
        avSyncLog.info("check a/v sync resumed: \(self.title, privacy: .public)")
    }

    func cancel() {
        guard state.isActive, !wasCancelled else { return }
        wasCancelled = true
        if pauseCoordinator.isPaused { pauseCoordinator.resume() }   // a stopped child cannot take SIGTERM
        state = .cancelling
        task?.cancel()
        if task == nil { finish() }
    }

    // MARK: Run

    func start() {
        guard task == nil, state.isActive else { return }
        task = Task { [weak self] in
            await self?.run()
        }
    }

    private func run() async {
        for index in items.indices {
            if Task.isCancelled || wasCancelled { break }
            let outcome = await measure(items[index].pair, index: index)
            items[index].outcome = outcome
            appLog.write(Self.logLine(pair: items[index].pair, outcome: outcome, policy: policy))
        }
        finish()
    }

    private func finish() {
        guard finishedAt == nil else { return }
        for index in items.indices where items[index].outcome == nil { items[index].outcome = .cancelled }
        stallMonitor?.stop()
        stallMonitor = nil
        if let stallReason {
            state = .failed(message: stallReason)
        } else if wasCancelled {
            state = .cancelled
        } else {
            let outcomes = items.compactMap(\.outcome)
            wasRefused = !outcomes.isEmpty && outcomes.allSatisfy { if case .refused = $0 { true } else { false } }
            let summary = Self.summary(outcomes)
            if outcomes.contains(where: { if case .measured = $0 { true } else { false } }) || outcomes.isEmpty {
                state = .finished(summary: summary)
            } else {
                state = .failed(message: summary)
            }
        }
        fraction = 1
        finishedAt = Date()
    }

    /// One pair: refuse before reading; read both; refuse if either changed;
    /// analyse off the main actor; keep the result.
    private func measure(_ pair: Pair, index: Int) async -> Outcome {
        if let why = Self.refusal(pair, stat: stat, vouch: vouch) { return .refused(why) }
        let stampsBefore = (stat(pair.original.path), stat(pair.processed.path))
        let label = "check a/v sync \(pair.processed.filename)"
        let monitor = StallMonitor(label: label) { [weak self] silent in
            Task { @MainActor [weak self] in self?.handleStall(silentFor: silent) }
        }
        // Started only once the volume gates are held: waiting hours behind
        // another job's read is not a stall (review, 2026-11-28).
        let beginWatching: @Sendable () async -> Void = { [weak self] in
            await self?.watch(monitor)
        }
        defer { monitor.stop(); if stallMonitor === monitor { stallMonitor = nil } }
        do {
            let gathered = try await gather(pair, index: index, stamps: stampsBefore, monitor: monitor,
                                            beginWatching: beginWatching)
            let evidence = gathered.evidence
            try Task.checkCancellation()
            if stat(pair.original.path) != stampsBefore.0 || stat(pair.processed.path) != stampsBefore.1 {
                return .refused("a file changed while it was being read")
            }
            for (fresh, key) in gathered.toKeep { cache.insert(fresh, for: key) }
            status = "Measuring \(pair.processed.filename)…"
            let report = await Self.analyze(evidence, policy: policy)
            store.record(report, processed: pair.processed, original: pair.original)
            return .measured(report)
        } catch is CancellationError {
            return .cancelled
        } catch let failure as ReadFailure {
            return Task.isCancelled ? .cancelled : .failed(failure.words)
        } catch {
            return Task.isCancelled ? .cancelled : .failed(String(describing: error))
        }
    }

    /// A pair's evidence: each side from the session's kept signals when its
    /// key matches, the rest read from disk (both at once, under the volume
    /// gates). `toKeep` = what was read, to keep once the after-read stat
    /// check has passed.
    private func gather(_ pair: Pair, index: Int, stamps: (FileStamp?, FileStamp?), monitor: StallMonitor,
                        beginWatching: @escaping @Sendable () async -> Void) async throws
        -> (evidence: Evidence, toKeep: [(AVSyncFileEvidence, AVSyncEvidenceCache.Key)]) {
        let keys = (cacheKey(pair.original, stamps.0), cacheKey(pair.processed, stamps.1))
        let kept = (keys.0.flatMap { cache.evidence(for: $0) }, keys.1.flatMap { cache.evidence(for: $0) })
        for (side, hit) in [(pair.original, kept.0), (pair.processed, kept.1)] where hit != nil {
            appLog.write("check a/v sync: \(side.filename) — its signals were read earlier this session"
                         + " (same SHA-256, size and date); not read again")
        }
        sideFractions = [kept.0 == nil ? 0 : 1, kept.1 == nil ? 0 : 1]
        if let original = kept.0, let processed = kept.1 {
            return (Evidence(original: original, processed: processed), [])
        }
        let control = pauseCoordinator.control
        let onOriginal: @Sendable (Double?) -> Void = { [weak self] f in
            self?.progress(index: index, part: 0, of: f, monitor: monitor)
        }
        let onProcessed: @Sendable (Double?) -> Void = { [weak self] f in
            self?.progress(index: index, part: 1, of: f, monitor: monitor)
        }
        let evidence = try await withGates(gatesFor(pair)[...]) { [reader] in
            await beginWatching()
            return try await Self.readBoth(pair, kept: kept, reader: reader, control: control,
                                           progress: (onOriginal, onProcessed))
        }
        var toKeep: [(AVSyncFileEvidence, AVSyncEvidenceCache.Key)] = []
        if kept.0 == nil, let key = keys.0 { toKeep.append((evidence.original, key)) }
        if kept.1 == nil, let key = keys.1 { toKeep.append((evidence.processed, key)) }
        return (evidence, toKeep)
    }

    private func watch(_ monitor: StallMonitor) {
        guard state.isActive else { return }
        stallMonitor = monitor
        monitor.start()
        pauseCoordinator.register(monitor)
    }

    struct Evidence: Sendable {
        let original: AVSyncFileEvidence
        let processed: AVSyncFileEvidence
    }

    struct ReadFailure: Error {
        let words: String
    }

    nonisolated private static func read(_ side: AVSyncSide, role: String, reader: Reader, control: ProcessControl,
                                         progress: @escaping @Sendable (Double?) -> Void) async throws -> AVSyncFileEvidence {
        do {
            return try await reader(side, control, progress)
        } catch let failure as AVSyncSignalReader.Failure {
            throw ReadFailure(words: "\(role) (\(side.filename)): \(failure.words)")
        }
    }

    /// Read the sides not already kept, both at once. The first failure
    /// cancels the other read (its ffmpeg children are killed) and is the one
    /// reported, naming its side.
    /// (For Rick: a throwing task group ≈ launching two std::async jobs and
    /// joining both, where the first exception cancels the sibling.)
    nonisolated static func readBoth(_ pair: Pair, kept: (AVSyncFileEvidence?, AVSyncFileEvidence?), reader: @escaping Reader,
                                     control: ProcessControl,
                                     progress: (@Sendable (Double?) -> Void, @Sendable (Double?) -> Void))
        async throws -> Evidence {
        try await withThrowingTaskGroup(of: (Int, AVSyncFileEvidence).self) { group in
            if kept.0 == nil {
                group.addTask { (0, try await read(pair.original, role: "the original", reader: reader,
                                                   control: control, progress: progress.0)) }
            }
            if kept.1 == nil {
                group.addTask { (1, try await read(pair.processed, role: "the processed file", reader: reader,
                                                   control: control, progress: progress.1)) }
            }
            var read: [Int: AVSyncFileEvidence] = [:]
            for try await (side, evidence) in group { read[side] = evidence }
            guard let original = kept.0 ?? read[0], let processed = kept.1 ?? read[1] else {
                throw CancellationError()
            }
            return Evidence(original: original, processed: processed)
        }
    }

    /// The cache key for a side, or nil when it has no digest or stamp
    /// (the refusal gate stops those before here).
    private func cacheKey(_ side: AVSyncSide, _ stamp: FileStamp?) -> AVSyncEvidenceCache.Key? {
        guard let digest = side.digest, let stamp else { return nil }
        return .init(digest: digest, size: stamp.size, modified: stamp.modified, readerIdentity: readerIdentity)
    }

    /// The analysis is pure CPU (a fraction of a second to a few seconds for
    /// two hours) — run it off the main actor.
    @concurrent
    nonisolated private static func analyze(_ evidence: Evidence, policy: AVSyncPolicy) async -> AVSyncReport {
        AVSyncAnalyzer.analyze(original: evidence.original, processed: evidence.processed, policy: policy)
    }

    /// Called from ffmpeg's reader threads.
    nonisolated private func progress(index: Int, part: Int, of fraction: Double?, monitor: StallMonitor) {
        monitor.tick()
        guard let fileFraction = fraction else { return }
        Task { @MainActor [weak self] in
            guard let self, self.state.isActive else { return }
            self.sideFractions[part] = min(1, max(self.sideFractions[part], fileFraction))
            let perPair = 1.0 / Double(max(1, self.items.count))
            let both = self.sideFractions
            self.fraction = min(1, perPair * (Double(index) + (both[0] + both[1]) / 2))
            self.status = Self.readingStatus(self.items[index].pair, fractions: both)
        }
    }

    /// Hold each volume gate in order (sorted by the Center), then run `body`.
    private func withGates<T: Sendable>(_ gates: ArraySlice<MediaVolumeGate>,
                                        _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let gate = gates.first else {
            waitingForVolumeLabel = nil
            return try await body()
        }
        waitingForVolumeLabel = gate.label
        return try await gate.semaphore.withPermit { [weak self] in
            guard let self else { throw CancellationError() }
            return try await self.withGates(gates.dropFirst(), body)
        }
    }

    func handleStall(silentFor: Double) {
        guard state.isActive, stallReason == nil, !wasCancelled else { return }
        let paths = items.flatMap { [$0.pair.original.path, $0.pair.processed.path] }
        stallReason = "Stalled — no progress for \(Int(silentFor))s. \(StallMonitor.attribution(forPaths: paths))"
        appLog.write("check a/v sync watchdog: \(title) stalled \(Int(silentFor))s; stopping")
        task?.cancel()
    }

    // MARK: Pure rules (tested)

    /// "Reading A (40 %) and B (55 %)" — a side already read is left out.
    nonisolated static func readingStatus(_ pair: Pair, fractions: [Double]) -> String {
        let parts = zip([pair.original, pair.processed], fractions)
            .filter { $0.1 < 1 }
            .map { "\($0.0.filename) (\(Int($0.1 * 100)) %)" }
        return parts.isEmpty ? "Read \(pair.processed.filename) and its original" : "Reading " + parts.joined(separator: " and ")
    }

    /// The refusal for a pair, or nil. Runs before anything is read.
    nonisolated static func refusal(_ pair: Pair, stat: Stat, vouch: Vouch = { _ in true }) -> String? {
        for (side, role) in [(pair.processed, "the processed file"), (pair.original, "the original")] {
            if side.digest == nil {
                return "\(role) (\(side.filename)) has no whole-file fingerprint yet — run Full Hashes first"
            }
        }
        if pair.processed.digest == pair.original.digest { return "the two files are the same content" }
        for (side, role) in [(pair.processed, "the processed file"), (pair.original, "the original")] {
            guard let stamp = stat(side.path) else {
                return "\(role) (\(side.filename)) is not reachable — connect its drive"
            }
            if stamp.size != side.sizeBytes {
                return "\(role) (\(side.filename)) changed since it was catalogued (\(stamp.size) bytes, catalog says \(side.sizeBytes))"
            }
            // The digest is evidence only while its stamp still describes the
            // file (device, inode, size, mtime, ctime) — the #523 precedent.
            if !vouch(side) {
                return "\(role) (\(side.filename)) may have changed since its whole-file fingerprint was taken — run Full Hashes again"
            }
        }
        return nil
    }

    /// The row's summary: one pair → its sentence; several → counts.
    nonisolated static func summary(_ outcomes: [Outcome]) -> String {
        if outcomes.count == 1, let only = outcomes.first { return only.words }
        var inSync = 0, review = 0, cannot = 0, refused = 0, failed = 0, stopped = 0
        for outcome in outcomes {
            switch outcome {
            case let .measured(report):
                if report.verdict.isInSync { inSync += 1 } else if report.verdict.needsReview { review += 1 } else { cannot += 1 }
            case .refused: refused += 1
            case .failed: failed += 1
            case .cancelled: stopped += 1
            }
        }
        var parts = ["\(inSync) in sync", "\(review) to review", "\(cannot) could not be measured"]
        if refused > 0 { parts.append("\(refused) not checked") }
        if failed > 0 { parts.append("\(failed) failed") }
        if stopped > 0 { parts.append("\(stopped) stopped") }
        return "\(outcomes.count) checked: " + parts.joined(separator: ", ")
    }

    /// One videoscan.log line per pair: the words, the numbers behind them,
    /// both digests (prefix) and the policy — the result's record until the
    /// catalog has a table for it.
    nonisolated static func logLine(pair: Pair, outcome: Outcome, policy: AVSyncPolicy) -> String {
        let digests = "\(pair.processed.digest.map { String($0.prefix(12)) } ?? "-")"
            + " vs \(pair.original.digest.map { String($0.prefix(12)) } ?? "-")"
        var line = "check a/v sync: \(pair.processed.filename) vs \(pair.original.filename) — \(outcome.words)"
        if case let .measured(report) = outcome {
            let median = report.medianShiftMs.map { String(format: "%.1f", $0) } ?? "-"
            let drift = report.driftMsPerMinute.map { String(format: "%.2f", $0) } ?? "-"
            line += " [median \(median) ms, drift \(drift) ms/min, \(report.measuredWindows)/\(report.windows.count) windows,"
                + " coarse \(report.coarseOffsetSeconds.map { String(format: "%.3f", $0) } ?? "-") s,"
                + " policy \(report.policyIdentity), analyzer v\(report.analyzerVersion), sha256 \(digests)]"
        } else {
            line += " [sha256 \(digests), policy \(policy.identity)]"
        }
        return line
    }

    // MARK: Detail (double-click)

    var detailView: AnyView { AnyView(AVSyncJobDetailView(job: self)) }
}

/// The per-pair list under the row.
struct AVSyncJobDetailView: View {
    @ObservedObject var job: AVSyncJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(job.items) { item in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(item.pair.processed.filename) — against \(item.pair.original.filename)")
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(item.outcome?.words ?? "waiting…")
                        .font(.callout)
                        .foregroundStyle(Self.color(item.outcome))
                        .textSelection(.enabled)
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("mfo.avSync.detail")
    }

    static func color(_ outcome: AVSyncJob.Outcome?) -> Color {
        guard let outcome else { return .secondary }
        switch outcome {
        case let .measured(report):
            if report.verdict.isInSync { return .green }
            return report.verdict.needsReview ? .orange : .secondary
        case .refused, .cancelled: return .secondary
        case .failed: return .red
        }
    }
}
