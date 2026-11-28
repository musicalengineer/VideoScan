// AVSyncJobTests.swift — Check A/V Sync in the app (design
// docs/design/av_sync_analysis.md §6): the one job, its refusals, the result
// store's truth rules, the original's resolution, and the wiring sensors.
//
// The job runs through MediaFileOperationsCenter.startAVSync with the REAL
// Core analyzer; only the ffmpeg read is replaced (the `reader` seam) by
// evidence built from synthetic PCM and motion — so the verdicts are the
// analyzer's own. Media-level truth (ffmpeg, the five formats, 2 hours) is
// VideoScanCore's AVSync suites.

import Foundation
import Testing
@_spi(Testing) import VideoScanCore
@testable import VideoScan

/// Synthetic evidence: speech-like PCM (seeded bursts) and a motion train, the
/// processed side's sound delayed by `soundLateMs`.
enum AVSyncAppFixture {
    static let rate = 8_000

    static func pcm(seconds: Double, seed: UInt64) -> [Int16] {
        var state = seed
        func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(1 << 53)
        }
        var out = [Int16](repeating: 0, count: Int(seconds * Double(rate)))
        var i = 0
        while i < out.count {
            let length = Int((0.05 + 0.3 * next()) * Double(rate))
            let freq = 200 + 2_000 * next(), amp = 4_000 + 12_000 * next()
            for k in 0..<length where i + k < out.count {
                let envelope = exp(-Double(k) / Double(length / 2))
                out[i + k] = Int16(amp * envelope * (sin(Double(k) * 2 * .pi * freq / Double(rate)) + 0.5 * (next() - 0.5)))
            }
            i += length + Int(0.2 * next() * Double(rate))
        }
        return out
    }

    static func motion(seconds: Double, seed: UInt64) -> [Float] {
        var state = seed
        let grid = 0.005
        var out = [Float](repeating: 5, count: Int(seconds / grid))
        for i in out.indices {
            state = state &* 2_862_933_555_777_941_757 &+ 3_037_000_493
            if Double(state >> 11) / Double(1 << 53) < 0.015 { out[i] += 400 }
        }
        return AVSyncSignalMath.movingAverage(out, radius: 2)
    }

    static func evidence(pcm: [Int16], motion: [Float]) -> AVSyncFileEvidence {
        let audio = AudioPCM(sampleRate: rate, samples: pcm)
        let onset = AVSyncSignalMath.onsetEnvelope(samples: pcm, sampleRate: rate, gridSeconds: 0.005)
        return AVSyncFileEvidence(signals: AVSyncSignals(gridSeconds: 0.005, onset: onset, motion: motion),
                                  fingerprint: AudioFingerprint.compute(audio))
    }

    /// (original, processed): the processed sound `soundLateMs` later.
    static func pair(seconds: Double = 60, soundLateMs: Int) -> (AVSyncFileEvidence, AVSyncFileEvidence) {
        let sound = pcm(seconds: seconds, seed: 42)
        let picture = motion(seconds: seconds, seed: 7)
        let delay = soundLateMs * rate / 1_000
        let late = [Int16](repeating: 0, count: delay) + sound.prefix(sound.count - delay)
        return (evidence(pcm: sound, motion: picture), evidence(pcm: Array(late), motion: picture))
    }

    static func side(_ name: String, digest: String?, size: Int64 = 1_000) -> AVSyncSide {
        AVSyncSide(recordID: UUID(), filename: name, path: "/Volumes/Test/\(name)", sizeBytes: size,
                   durationSeconds: 60, digest: digest)
    }

    static let d1 = String(repeating: "1", count: 64)
    static let d2 = String(repeating: "2", count: 64)
    static let d3 = String(repeating: "3", count: 64)

    static let steadyStat: AVSyncJob.Stat = { _ in AVSyncJob.FileStamp(size: 1_000, modified: Date(timeIntervalSince1970: 1)) }

    /// A reader that answers `original` / `processed` by the side's file name.
    static func reader(_ evidence: (AVSyncFileEvidence, AVSyncFileEvidence),
                       calls: AVSyncCallCounter? = nil) -> AVSyncJob.Reader {
        { side, _, progress in
            calls?.bump()
            progress(1)
            return side.filename.hasPrefix("orig") ? evidence.0 : evidence.1
        }
    }
}

final class AVSyncCallCounter: @unchecked Sendable {   // guarded by `lock`
    private let lock = NSLock()
    private var value = 0
    func bump() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - Refusals and words (pure)

@MainActor
struct AVSyncJobRulesTests {

    @Test("refused before reading: no full hash, same content, unreachable, changed size")
    func refusals() {
        let stat = AVSyncAppFixture.steadyStat
        let ok = AVSyncJob.Pair(processed: AVSyncAppFixture.side("proc.mp4", digest: AVSyncAppFixture.d1),
                                original: AVSyncAppFixture.side("orig.mov", digest: AVSyncAppFixture.d2))
        #expect(AVSyncJob.refusal(ok, stat: stat) == nil)

        let noHash = AVSyncJob.Pair(processed: AVSyncAppFixture.side("proc.mp4", digest: nil),
                                    original: ok.original)
        #expect(AVSyncJob.refusal(noHash, stat: stat)?.contains("no whole-file fingerprint yet — run Full Hashes first") == true)

        let same = AVSyncJob.Pair(processed: ok.processed,
                                  original: AVSyncAppFixture.side("orig.mov", digest: AVSyncAppFixture.d1))
        #expect(AVSyncJob.refusal(same, stat: stat) == "the two files are the same content")

        #expect(AVSyncJob.refusal(ok, stat: { _ in nil })?.contains("is not reachable") == true)
        let grown: AVSyncJob.Stat = { _ in AVSyncJob.FileStamp(size: 2_000, modified: Date()) }
        #expect(AVSyncJob.refusal(ok, stat: grown)?.contains("changed since it was catalogued") == true)
    }

    @Test("F3: a duration of 0 (or less) is unknown — the reader gets nil, not zero seconds")
    func zeroDurationIsUnknown() {
        func side(_ seconds: Double) -> AVSyncSide {
            AVSyncSide(recordID: UUID(), filename: "x.mp4", path: "/x", sizeBytes: 1, durationSeconds: seconds, digest: nil)
        }
        #expect(AVSyncJob.expectedDuration(of: side(0)) == nil)
        #expect(AVSyncJob.expectedDuration(of: side(-1)) == nil)
        #expect(AVSyncJob.expectedDuration(of: side(61.5)) == 61.5)
    }

    @Test("refused before reading when the stored stamp no longer describes the file (not size alone)")
    func staleStampIsRefused() {
        let stamp = FileIdentityStamp(device: 1, inode: 1, size: 1_000, mtimeNs: 0)
        let stale = ContentFixity(digest: AVSyncAppFixture.d1, byteCount: 1_000, stamp: stamp, computedAt: Date())
        let processed = AVSyncSide(recordID: UUID(), filename: "proc.mp4", path: "/Volumes/Test/proc.mp4",
                                   sizeBytes: 1_000, durationSeconds: 60, digest: AVSyncAppFixture.d1, fixity: stale)
        let pair = AVSyncJob.Pair(processed: processed, original: AVSyncAppFixture.side("orig.mov", digest: AVSyncAppFixture.d2))
        // Size matches (steadyStat), but no file on disk carries that stamp.
        let why = AVSyncJob.refusal(pair, stat: AVSyncAppFixture.steadyStat, vouch: AVSyncJob.realVouch)
        #expect(why == "the processed file (proc.mp4) may have changed since its whole-file fingerprint was taken — run Full Hashes again")
        #expect(AVSyncJob.refusal(pair, stat: AVSyncAppFixture.steadyStat, vouch: { _ in true }) == nil)
    }

    @Test("the row summary: one pair says its sentence; several are counted")
    func summary() {
        let inSync = AVSyncReport(policyIdentity: "v1", verdict: .inSync(withinMs: 3, measured: 5, total: 5, notMeasured: [], setAside: 0))
        let late = AVSyncReport(policyIdentity: "v1", verdict: .offset(shiftMs: -80))
        #expect(AVSyncJob.summary([.measured(late)]) == "sound 80 ms late against the picture, the same through the whole file")
        #expect(AVSyncJob.summary([.measured(inSync), .measured(late), .refused("x"), .failed("y")])
                == "4 checked: 1 in sync, 1 to review, 0 could not be measured, 1 not checked, 1 failed")
    }

    @Test("the log line carries the words, the numbers and both digests")
    func logLine() {
        let pair = AVSyncJob.Pair(processed: AVSyncAppFixture.side("proc.mp4", digest: AVSyncAppFixture.d1),
                                  original: AVSyncAppFixture.side("orig.mov", digest: AVSyncAppFixture.d2))
        let report = AVSyncReport(policyIdentity: "v1", verdict: .offset(shiftMs: -80), coarseOffsetSeconds: -0.064,
                                  medianShiftMs: -80, driftMsPerMinute: 0.1)
        let line = AVSyncJob.logLine(pair: pair, outcome: .measured(report), policy: .default)
        #expect(line.hasPrefix("check a/v sync: proc.mp4 vs orig.mov — sound 80 ms late against the picture"))
        #expect(line.contains("median -80.0 ms") && line.contains("policy v1") && line.contains("sha256 111111111111 vs 222222222222"))
    }
}

// MARK: - The result store (truth)

@MainActor
struct AVSyncResultStoreTests {

    let report = AVSyncReport(policyIdentity: AVSyncPolicy.default.identity, verdict: .offset(shiftMs: -80))

    @Test("kept only with both digests; found only by the processed file's CURRENT digest")
    func keyedByDigests() {
        let store = AVSyncResultStore()
        let proc = AVSyncAppFixture.side("proc.mp4", digest: AVSyncAppFixture.d1)
        let orig = AVSyncAppFixture.side("orig.mov", digest: AVSyncAppFixture.d2)
        #expect(!store.record(report, processed: AVSyncAppFixture.side("p", digest: nil), original: orig))
        #expect(store.isEmpty)
        #expect(store.record(report, processed: proc, original: orig))
        #expect(store.entry(forProcessedDigest: AVSyncAppFixture.d1)?.report == report)
        #expect(store.entry(forProcessedDigest: AVSyncAppFixture.d3) == nil, "changed bytes → a different digest → nothing")
        #expect(store.entry(forProcessedDigest: AVSyncAppFixture.d2) == nil, "the original is not the processed file")
        #expect(store.entry(forProcessedDigest: nil) == nil)
    }

    @Test("a result judged by another policy or an older analyzer is not shown")
    func currentRulesOnly() {
        let store = AVSyncResultStore()
        let proc = AVSyncAppFixture.side("proc.mp4", digest: AVSyncAppFixture.d1)
        let orig = AVSyncAppFixture.side("orig.mov", digest: AVSyncAppFixture.d2)
        var tuned = report
        tuned.policyIdentity = "v1~custom"
        store.record(tuned, processed: proc, original: orig)
        #expect(store.entry(forProcessedDigest: AVSyncAppFixture.d1) == nil)
        var old = report
        old.analyzerVersion = 0
        store.record(old, processed: proc, original: orig)
        #expect(store.entry(forProcessedDigest: AVSyncAppFixture.d1) == nil)
        store.record(report, processed: proc, original: orig)
        #expect(store.entry(forProcessedDigest: AVSyncAppFixture.d1) != nil)
    }

    @Test("F5: re-recording refreshes the FIFO order; an eviction never drops another entry's lookup")
    func reRecordRefreshesAndEvictionKeepsLookups() {
        let store = AVSyncResultStore()
        let proc = AVSyncAppFixture.side("proc.mp4", digest: AVSyncAppFixture.d1)
        let origA = AVSyncAppFixture.side("origA.mov", digest: AVSyncAppFixture.d2)
        let origB = AVSyncAppFixture.side("origB.mov", digest: AVSyncAppFixture.d3)
        store.record(report, processed: proc, original: origA)   // k1 (oldest)
        store.record(report, processed: proc, original: origB)   // k2
        store.record(report, processed: proc, original: origA)   // k1 again: now the newest
        for i in 0..<(AVSyncResultStore.cap - 1) {               // fill to the cap, then one past it
            store.record(report, processed: AVSyncAppFixture.side("p\(i)", digest: String(format: "%064x", i + 100)),
                         original: origA)
        }
        #expect(store.entry(forProcessedDigest: AVSyncAppFixture.d1)?.original.filename == "origA.mov",
                "the refreshed k1 must survive; k2 (older) is the one evicted")
        // Evict k1 too: the processed digest has no entry left, so nothing answers — but if k2
        // had still been there, the lookup must have fallen back to it, never to nil.
        let store2 = AVSyncResultStore()
        store2.record(report, processed: proc, original: origB)  // k2 (newer content of the pair kept)
        store2.record(report, processed: proc, original: origA)  // k1 latest
        store2.record(report, processed: proc, original: origB)  // k2 refreshed → newest; k1 oldest
        for i in 0..<(AVSyncResultStore.cap - 1) {
            store2.record(report, processed: AVSyncAppFixture.side("q\(i)", digest: String(format: "%064x", i + 500)),
                          original: origA)
        }
        #expect(store2.entry(forProcessedDigest: AVSyncAppFixture.d1)?.original.filename == "origB.mov",
                "evicting k1 must not drop the lookup of the surviving k2")
    }

    @Test("FIFO cap; the line names the original and when")
    func capAndLine() throws {
        let store = AVSyncResultStore()
        let orig = AVSyncAppFixture.side("orig.mov", digest: AVSyncAppFixture.d2)
        var first: String?
        for i in 0...AVSyncResultStore.cap {
            let digest = String(format: "%064x", i + 10)
            if first == nil { first = digest }
            store.record(report, processed: AVSyncAppFixture.side("p\(i)", digest: digest), original: orig)
        }
        #expect(store.count == AVSyncResultStore.cap)
        #expect(store.entry(forProcessedDigest: first) == nil, "the oldest was evicted")
        let entry = try #require(store.entry(forProcessedDigest: String(format: "%064x", AVSyncResultStore.cap + 10)))
        let line = AVSyncResultStore.line(for: entry)
        #expect(line.hasPrefix("sound 80 ms late against the picture, the same through the whole file — against orig.mov, checked "))
    }
}

// MARK: - The job, end to end through the Center

@MainActor
@Suite(.serialized)
struct AVSyncJobRunTests {

    func pair(processedDigest: String? = AVSyncAppFixture.d1) -> AVSyncJob.Pair {
        AVSyncJob.Pair(processed: AVSyncAppFixture.side("proc.mp4", digest: processedDigest),
                       original: AVSyncAppFixture.side("orig.mov", digest: AVSyncAppFixture.d2))
    }

    @Test("a measured pair: the analyzer's words in the row, the store and the log (START, per pair, OUTCOME)")
    func measuredPair() async throws {
        let center = MediaFileOperationsCenter()
        let evidence = AVSyncAppFixture.pair(soundLateMs: 80)
        let (job, _) = await expectingLog(
            .once(.hasPrefix("check a/v sync: proc.mp4 vs orig.mov — sound-vs-picture timing of 1 file(s)")),
            .once(.hasPrefix("check a/v sync: proc.mp4 vs orig.mov — sound 80 ms late against the picture")),
            .once(.hasPrefix("check a/v sync done: proc.mp4 vs orig.mov — sound 80 ms late")),
            .inOrder(.contains("timing of 1 file(s)"), .hasPrefix("check a/v sync done: "))
        ) {
            let job = center.startAVSync(pairs: [pair()], reader: AVSyncAppFixture.reader(evidence),
                                         stat: AVSyncAppFixture.steadyStat)
            await job?.task?.value
            return job
        }
        let done = try #require(job)
        guard case let .finished(summary) = done.state else {
            Issue.record("expected finished, got \(done.state)"); return
        }
        #expect(summary.hasPrefix("sound 80 ms late"))
        #expect(done.finishedAt != nil && done.fraction == 1)
        let entry = try #require(center.avSyncResults.entry(forProcessedDigest: AVSyncAppFixture.d1))
        #expect(entry.original.filename == "orig.mov")
        guard case let .offset(shift) = entry.report.verdict else { Issue.record("expected offset"); return }
        #expect(abs(shift + 80) <= 5)
    }

    @Test("an unchanged copy reads in sync")
    func inSync() async throws {
        let center = MediaFileOperationsCenter()
        let job = center.startAVSync(pairs: [pair()], reader: AVSyncAppFixture.reader(AVSyncAppFixture.pair(soundLateMs: 0)),
                                     stat: AVSyncAppFixture.steadyStat)
        await job?.task?.value
        #expect(center.avSyncResults.entry(forProcessedDigest: AVSyncAppFixture.d1)?.report.verdict.isInSync == true)
    }

    @Test("refused before reading: nothing is read, the OUTCOME says refused, nothing is kept")
    func refusedPair() async throws {
        let center = MediaFileOperationsCenter()
        let calls = AVSyncCallCounter()
        let (job, _) = await expectingLog(
            .once(.hasPrefix("check a/v sync refused: proc.mp4 vs orig.mov — not checked: the processed file")),
            .never(.hasPrefix("check a/v sync done: "))
        ) {
            let job = center.startAVSync(pairs: [pair(processedDigest: nil)],
                                         reader: AVSyncAppFixture.reader(AVSyncAppFixture.pair(soundLateMs: 0), calls: calls),
                                         stat: AVSyncAppFixture.steadyStat)
            await job?.task?.value
            return job
        }
        #expect(calls.count < 1)
        #expect(job?.wasRefused == true)
        #expect(center.avSyncResults.isEmpty)
    }

    @Test("a file that changes while it is read gives no result")
    func changedDuringRead() async throws {
        let center = MediaFileOperationsCenter()
        let ticks = AVSyncCallCounter()
        let stat: AVSyncJob.Stat = { _ in
            ticks.bump()
            // First four stats (refusal × 2, stamps × 2) see the catalogued file; later ones a newer one.
            return AVSyncJob.FileStamp(size: 1_000, modified: Date(timeIntervalSince1970: ticks.count <= 4 ? 1 : 2))
        }
        let job = center.startAVSync(pairs: [pair()], reader: AVSyncAppFixture.reader(AVSyncAppFixture.pair(soundLateMs: 80)),
                                     stat: stat)
        await job?.task?.value
        #expect(job?.items.first?.outcome == .refused("a file changed while it was being read"))
        #expect(center.avSyncResults.isEmpty)
    }

    @Test("a read failure names the file and the reason")
    func readFailure() async throws {
        let center = MediaFileOperationsCenter()
        let reader: AVSyncJob.Reader = { side, _, _ in
            if side.filename.hasPrefix("orig") { throw AVSyncSignalReader.Failure.noPicture }
            return AVSyncAppFixture.pair(soundLateMs: 0).1
        }
        let job = center.startAVSync(pairs: [pair()], reader: reader, stat: AVSyncAppFixture.steadyStat)
        await job?.task?.value
        #expect(job?.items.first?.outcome == .failed("the original (orig.mov): the file has no picture"))
        guard case .failed? = job?.state else { Issue.record("expected failed, got \(String(describing: job?.state))"); return }
    }

    @Test("Stop: the read is cancelled, the row says Stopped, OUTCOME cancelled, nothing kept")
    func stop() async throws {
        let center = MediaFileOperationsCenter()
        let reader: AVSyncJob.Reader = { _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return AVSyncAppFixture.pair(soundLateMs: 0).0
        }
        let (job, _) = await expectingLog(.once(.hasPrefix("check a/v sync cancelled: proc.mp4 vs orig.mov"))) {
            let job = center.startAVSync(pairs: [pair()], reader: reader, stat: AVSyncAppFixture.steadyStat)
            try? await Task.sleep(for: .milliseconds(50))
            job?.cancel()
            await job?.task?.value
            return job
        }
        #expect(job?.state == .cancelled)
        #expect(job?.items.first?.outcome == .cancelled)
        #expect(center.avSyncResults.isEmpty)
    }

    @Test("Pause suspends the ffmpeg children through the job's ProcessControl; Resume continues")
    func pauseResume() async throws {
        let center = MediaFileOperationsCenter()
        let seen = AVSyncControlBox()
        let reader: AVSyncJob.Reader = { _, control, _ in
            seen.set(control)
            try await Task.sleep(for: .seconds(60))
            return AVSyncAppFixture.pair(soundLateMs: 0).0
        }
        let job = try #require(center.startAVSync(pairs: [pair()], reader: reader, stat: AVSyncAppFixture.steadyStat))
        try await Task.sleep(for: .milliseconds(50))
        #expect(job.canPause)
        job.pause()
        #expect(job.isPaused && seen.control?.isSuspended == true)
        #expect(job.subtitle.hasPrefix("Paused"))
        job.resume()
        #expect(!job.isPaused && seen.control?.isSuspended == false)
        job.cancel()
        await job.task?.value
    }

    @Test("the stall watchdog starts only once the volume gates are held — queueing is not a stall")
    func watchdogAfterGates() async throws {
        let gate = MediaVolumeGate(root: "/Volumes/Test", label: "Test", semaphore: AsyncSemaphore(limit: 1))
        try await gate.semaphore.wait()   // another job holds the drive
        let job = AVSyncJob(pairs: [pair()], store: AVSyncResultStore(), gatesFor: { _ in [gate] },
                            reader: AVSyncAppFixture.reader(AVSyncAppFixture.pair(soundLateMs: 0)),
                            stat: AVSyncAppFixture.steadyStat)
        job.start()
        try await Task.sleep(for: .milliseconds(100))
        #expect(job.subtitle == "Waiting for Test…")
        #expect(!job.isWatchingForStall, "waiting for the drive must not arm the stall watchdog")
        await gate.semaphore.signal()
        await job.task?.value
        guard case .finished = job.state else { Issue.record("expected finished, got \(job.state)"); return }
    }

    @Test("a second dispatch for a file already being checked is refused")
    func duplicateDispatch() async throws {
        let center = MediaFileOperationsCenter()
        let reader: AVSyncJob.Reader = { _, _, _ in
            try await Task.sleep(for: .seconds(60))
            return AVSyncAppFixture.pair(soundLateMs: 0).0
        }
        let p = pair()
        let first = center.startAVSync(pairs: [p], reader: reader, stat: AVSyncAppFixture.steadyStat)
        #expect(first != nil)
        #expect(center.startAVSync(pairs: [p], reader: reader, stat: AVSyncAppFixture.steadyStat) == nil)
        first?.cancel()
        await first?.task?.value
    }
}

final class AVSyncControlBox: @unchecked Sendable {   // guarded by `lock`
    private let lock = NSLock()
    private var value: ProcessControl?
    func set(_ control: ProcessControl) { lock.lock(); value = control; lock.unlock() }
    var control: ProcessControl? { lock.lock(); defer { lock.unlock() }; return value }
}

// MARK: - The original (pure, over plain facts — runs off the main actor)

struct AVSyncOriginalsTests {

    @Test("the lineage original comes first; then files of similar length, closest first; matched off the main actor")
    func candidates() async {
        let original = AVSyncFileFacts(filename: "tape7.mov", durationSeconds: 600)
        let topaz = AVSyncFileFacts(filename: "tape7_topaz.mp4", durationSeconds: 600, derivedFrom: original.id)
        let near = AVSyncFileFacts(filename: "other.mov", durationSeconds: 610)
        let far = AVSyncFileFacts(filename: "far.mov", durationSeconds: 900)
        let soundOnly = AVSyncFileFacts(filename: "tape7.wav", durationSeconds: 600, eligible: false)
        let all = [original, topaz, near, far, soundOnly]
        let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })
        #expect(AVSyncOriginals.lineageOriginal(of: topaz, byID: byID) == original)
        #expect(AVSyncOriginals.candidates(for: topaz, in: all, byID: byID).map(\.filename) == ["tape7.mov", "other.mov"])
        let rows = await AVSyncOriginals.rows(for: [topaz.id, soundOnly.id], in: all)
        #expect(rows.count == 1 && rows.first?.chosen == original.id)
        #expect(rows.first?.candidates.first?.label.hasPrefix("Made from: tape7.mov") == true)
    }

    @Test("no lineage, a self-link or an ineligible parent: no known original")
    func noLineage() {
        let lone = AVSyncFileFacts(filename: "lone.mp4", durationSeconds: 60)
        #expect(AVSyncOriginals.lineageOriginal(of: lone, byID: [:]) == nil)
        let selfID = UUID()
        let selfLinked = AVSyncFileFacts(id: selfID, filename: "self.mp4", durationSeconds: 60, derivedFrom: selfID)
        #expect(AVSyncOriginals.lineageOriginal(of: selfLinked, byID: [selfID: selfLinked]) == nil)
        let silentParent = AVSyncFileFacts(filename: "parent.mov", durationSeconds: 60, eligible: false)
        let child = AVSyncFileFacts(filename: "child.mp4", durationSeconds: 60, derivedFrom: silentParent.id)
        #expect(AVSyncOriginals.lineageOriginal(of: child, byID: [silentParent.id: silentParent]) == nil)
    }

    @Test("a record's facts: picture and sound, live, its lineage and whether it has a full hash")
    @MainActor
    func factsFromRecord() {
        let r = VideoRecord()
        r.filename = "a.mp4"
        r.durationSeconds = 12
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        let facts = AVSyncFileFacts(record: r)
        #expect(facts.eligible && !facts.hasDigest && facts.durationSeconds == 12)
        r.streamTypeRaw = StreamType.audioOnly.rawValue
        #expect(!AVSyncFileFacts(record: r).eligible)
    }
}

// MARK: - Wiring sensors (source)

struct AVSyncWiringSensorTests {

    @Test("Analyze ▸ Check A/V Sync… opens the sheet; the sheet starts the one job")
    func menuAndSheet() throws {
        let menu = try SourceTree.appSource(named: "CatalogRowContextMenu+FileOps.swift")
        #expect(menu.contains("Button(CatalogRowMenuText.checkAVSync)"))
        #expect(menu.contains("avSyncRequest = AVSyncSheetRequest("))
        #expect(menu.contains(".accessibilityIdentifier(\"catalog.row.checkAVSync\")"))
        let host = try SourceTree.appSource(named: "CatalogHelpers.swift")
        #expect(host.contains(".sheet(item: $avSyncRequest)"))
        #expect(host.contains("fileOpsCenter.startAVSync(pairs: pairs)"))
        #expect(CatalogRowMenuText.checkAVSync == "Check A/V Sync\u{2026}")
    }

    @Test("Media Info and the Inspector show the one timing line, from the store, by digest")
    func timingLine() throws {
        let inspector = try SourceTree.appSource(named: "InspectorPanel.swift")
        #expect(inspector.contains("AVSyncTimingLine(store: avSyncResults, digest: contentDigest"))
        let info = try SourceTree.appSource(named: "MediaInfoSheet.swift")
        #expect(info.contains("AVSyncTimingLine(store: store, digest: request.contentDigest)"))
        let presenter = try SourceTree.appSource(named: "CatalogRowContextMenu+Media.swift")
        #expect(presenter.contains("contentDigest: CatalogCommit.digest(of: rec)"))
    }

    @Test("the feature keeps its state out of VideoScanModel (rule 12) and runs ffmpeg only through Core's reader")
    func boundaries() throws {
        for name in ["AVSyncJob.swift", "AVSyncResultStore.swift", "MediaFileOperations+AVSync.swift",
                     "AVSyncSheet.swift", "AVSyncTimingLine.swift"] {
            let source = try SourceTree.appSource(named: name).split(separator: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
            #expect(!source.contains("extension VideoScanModel"), "\(name)")
            #expect(!source.contains("Process()"), "\(name)")
        }
        #expect(MediaFileOperationKind.checkAVSync.hasDetailView)
        #expect(MediaFileOperationKind.checkAVSync.logVerb == "check a/v sync")
    }
}

// MARK: - The real call site: ffmpeg, the reader, the stat, the Center

/// One media integration test: a 40 s pair made by ffmpeg in test scratch
/// (pseudo-random flashes for the picture, the synthetic speech for the
/// sound), the processed copy's sound 120 ms later, checked by the real job
/// with the real reader and stat. Nothing of Rick's is read.
@MainActor
@Suite(.scratchCleanup)
struct AVSyncJobMediaTests {

    static func writeWAV(_ samples: [Int16], rate: Int, to url: URL) throws {
        var data = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes); data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(UInt32(rate)); u32(UInt32(rate * 2))
        u16(2); u16(16); data.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { withUnsafeBytes(of: s.littleEndian) { data.append(contentsOf: $0) } }
        try data.write(to: url)
    }

    static func ffmpeg(_ args: [String]) async throws {
        let result = await ProcessRunner.runProcess(executable: FFmpegLocator.ffmpegPath,
                                                    arguments: ["-nostdin", "-v", "error"] + args, deadlineSeconds: 300)
        try #require(result.exitCode == 0, "ffmpeg: \(result.stderr.suffix(300))")
    }

    static func side(_ url: URL, digest: String) throws -> AVSyncSide {
        let size = try #require((try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value)
        return AVSyncSide(recordID: UUID(), filename: url.lastPathComponent, path: url.path, sizeBytes: size,
                          durationSeconds: 40, digest: digest)
    }

    @Test("a 120 ms late copy, end to end: real ffmpeg read, the job's words, the store's line")
    func endToEnd() async throws {
        let dir = try TestScratch.unique("test_avsync_job_media_")
        let wav = dir.appendingPathComponent("sound.wav")
        try Self.writeWAV(AVSyncAppFixture.pcm(seconds: 40, seed: 99), rate: 8_000, to: wav)
        let original = dir.appendingPathComponent("orig.mov")
        // A frame-hash flash: about 8 % of frames light up, at no regular period.
        let picture = "color=c=gray:s=160x90:r=30:d=40,format=gray,"
            + "geq=lum='40+190*gt(st(0\\,sin(N*12.9898)*43758.5453)-floor(ld(0))\\,0.92)'"
        try await Self.ffmpeg(["-f", "lavfi", "-i", picture, "-i", wav.path, "-map", "0:v", "-map", "1:a",
                               "-c:v", "prores_ks", "-profile:v", "0", "-c:a", "pcm_s16le", "-ar", "48000", "-y", original.path])
        let processed = dir.appendingPathComponent("proc.mp4")
        try await Self.ffmpeg(["-i", original.path, "-af", "adelay=120:all=1", "-c:v", "libx264", "-preset", "ultrafast",
                               "-pix_fmt", "yuv420p", "-c:a", "aac", "-y", processed.path])
        let before = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()

        let center = MediaFileOperationsCenter()
        let pair = AVSyncJob.Pair(processed: try Self.side(processed, digest: AVSyncAppFixture.d1),
                                  original: try Self.side(original, digest: AVSyncAppFixture.d2))
        let job = try #require(center.startAVSync(pairs: [pair]))
        await job.task?.value
        guard case let .finished(summary) = job.state else {
            Issue.record("expected finished: \(job.state) — \(job.items.first?.outcome?.words ?? "")"); return
        }
        #expect(summary.hasPrefix("sound 12") && summary.contains(" ms late against the picture"), "\(summary)")
        let entry = try #require(center.avSyncResults.entry(forProcessedDigest: AVSyncAppFixture.d1))
        guard case let .offset(shift) = entry.report.verdict else { Issue.record("expected an offset"); return }
        #expect(abs(shift + 120) <= 5, "\(shift)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() == before,
                "the job writes nothing beside the files it reads")
    }
}
