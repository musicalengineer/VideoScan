// FindMasterTests.swift — Provenance ▸ Find Master (by sound), app side
// (design provenance_retroactive_2026_10_26 §Phase A tests).
//   FindMasterPlanTests   — logic/truth: each refusal reason; scale: 100k
//                           records planned < 1 s.
//   FindMasterAnswerTests — truth: every positive sentence carries its
//                           evidence; none claims direction; negatives say
//                           what was searched.
//   FindMasterJobTests    — logic: one START + one OUTCOME whose counts sum
//                           to the selection; Stop mid-run; Pause holds
//                           between queries. Isolation: a missing/poisoned
//                           sidecar refuses before reading; a run writes
//                           nothing to the sidecar.
// Prints are crafted (seeded random landmarks), written to a scratch
// sidecar — no file of Rick's, no App Support data.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// Records and a scratch sidecar for the Find Master tests.
@MainActor
enum FindMasterFixtures {
    static func digest(_ n: Int) -> String { String(format: "%064x", n) }

    static func record(_ n: Int, name: String? = nil, hashed: Bool = true, stamp: AudioFingerprintStamp.Outcome? = .fingerprinted,
                       landmarks: Int = 500, audioCodec: String = "aac") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name ?? "clip\(n).mov"
        r.fullPath = "/Volumes/FMTest/\(r.filename)"
        r.sizeBytes = Int64(1_000 + n)
        r.audioCodec = audioCodec
        if hashed {
            r.contentFixity = ContentFixity(digest: digest(n), byteCount: r.sizeBytes,
                                            stamp: FileIdentityStamp(device: 1, inode: UInt64(n), size: r.sizeBytes, mtimeNs: 0))
        }
        if let stamp {
            r.audioFingerprint = AudioFingerprintStamp(contentDigest: "sha256:" + digest(n), sizeBytes: r.sizeBytes,
                                                       outcome: stamp, analyzedSeconds: stamp == .noAudio ? 0 : 60,
                                                       complete: true, landmarks: stamp == .noAudio ? 0 : landmarks,
                                                       bytes: 100)
        }
        return r
    }

    static func key(_ n: Int) -> AudioFingerprintStore.Key {
        AudioFingerprintStore.Key(contentDigest: "sha256:" + digest(n), sizeBytes: Int64(1_000 + n))
    }

    /// A "recording": `perSecond` random landmarks per second for `seconds`.
    static func recording(seconds: Int, seed: UInt64, perSecond: Int = 12) -> (hashes: [UInt32], times: [UInt32]) {
        var state = seed
        func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        var hashes: [UInt32] = [], times: [UInt32] = []
        for s in 0..<seconds {
            for _ in 0..<perSecond {
                hashes.append(AudioFingerprint.packHash(f1: Int(next() % 512), f2: Int(next() % 512), dt: Int(1 + next() % 63)))
                times.append(UInt32(Double(s) / 0.064 + Double(next() % 15)))
            }
        }
        return (hashes, times)
    }

    static func print(_ r: (hashes: [UInt32], times: [UInt32]), seconds: Double) -> AudioFingerprint {
        AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: seconds,
                         hashes: r.hashes, times: r.times)
    }

    /// Master (1), a 40 s clip of it from 100 s (2), an unrelated (3), a
    /// second clip from 200 s (4) — written to a fresh sidecar.
    static func sidecar() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_findmaster_\(UUID().uuidString)", isDirectory: true)
        let master = recording(seconds: 300, seed: 7)
        func clip(from start: Int, seconds: Int) -> AudioFingerprint {
            let lo = Double(start) / 0.064, hi = Double(start + seconds) / 0.064
            var hashes: [UInt32] = [], times: [UInt32] = []
            for (h, t) in zip(master.hashes, master.times) where Double(t) >= lo && Double(t) < hi {
                hashes.append(h); times.append(t - UInt32(lo))
            }
            return print((hashes, times), seconds: Double(seconds))
        }
        let store = try AudioFingerprintStore(directory: dir)
        try store.put([
            .init(key: key(1), fingerprint: print(master, seconds: 300), sourcePath: "test"),
            .init(key: key(2), fingerprint: clip(from: 100, seconds: 40), sourcePath: "test"),
            .init(key: key(3), fingerprint: print(recording(seconds: 120, seed: 99), seconds: 120), sourcePath: "test"),
            .init(key: key(4), fingerprint: clip(from: 200, seconds: 30), sourcePath: "test"),
        ])
        return dir
    }

    static func plan(selected: [Int], refusedToo: Bool = false) -> FindMasterPlan {
        var records = [1, 2, 3, 4].map { record($0) }
        if refusedToo { records.append(record(5, hashed: false)) }
        let chosen = records.filter { selected.contains(Int($0.sizeBytes) - 1_000) || (refusedToo && $0.sizeBytes == 1_005) }
        return FindMasterPlan.make(selected: chosen, all: records, isArchived: { _ in false })
    }
}

/// Collects log lines (tests only).
@MainActor
final class FindMasterLineSink {
    var lines: [String] = []
    func note(_ line: String) { lines.append(line) }
}

@Suite("FindMasterPlan")
@MainActor
struct FindMasterPlanTests {
    typealias F = FindMasterFixtures

    @Test("each refusal reason, one record each — and a searchable record becomes a query")
    func eachRefusalReason() {
        let notHashed = F.record(1, hashed: false)
        let noPrint = F.record(2, stamp: nil)
        let noSound = F.record(3, stamp: .noAudio, audioCodec: "")
        let tiny = F.record(4, landmarks: 12)
        let good = F.record(5)
        let plan = FindMasterPlan.make(selected: [notHashed, noPrint, noSound, tiny, good],
                                       all: [notHashed, noPrint, noSound, tiny, good], isArchived: { _ in false })
        #expect(plan.queries.map(\.recordID) == [good.id])
        #expect(plan.queries.first?.key == F.key(5))
        #expect(plan.refusals.map(\.reason) == [.notHashed, .noSoundPrint, .noSound, .tooLittleSound(landmarks: 12)])
        // The fifth reason is decided when the print is loaded (the stamp
        // does not carry the recipe): the finder's refusal maps to it.
        #expect(FindMasterAnswer.reason(for: .otherRecipe(query: 1, index: 2)) == .olderRecipe)
        #expect(FindMasterAnswer.refusal(.notHashed).contains("Fill In Full Hashes"))
        #expect(FindMasterAnswer.refusal(.noSoundPrint).contains("Fingerprint Sound"))
        #expect(FindMasterAnswer.refusal(.noSound).contains("No sound to match"))
        #expect(FindMasterAnswer.refusal(.tooLittleSound(landmarks: 12)).contains("12 landmarks; 20 needed"))
        #expect(FindMasterAnswer.refusal(.olderRecipe).contains("older recipe"))
        // Negative counts: the silent content and the unprinted one.
        #expect(plan.noSoundTrackContents == 1)
        #expect(plan.notFingerprintedContents == 1)
    }

    @Test("a stamp keyed on the sampled hash is not searchable")
    func sampledKeyedStampIsNoSoundPrint() {
        let r = F.record(6)
        r.audioFingerprint?.contentDigest = "v1:abc"
        #expect(FindMasterPlan.make(selected: [r], all: [r], isArchived: { _ in false }).refusals.map(\.reason) == [.noSoundPrint])
    }

    @Test("labels prefer a live record over one in the Trash")
    func labelsPreferLiveCopies() {
        let trashed = F.record(7, name: "trashed.mov")
        trashed.removal = .inTrash(movedAt: Date(), trashPath: nil, reason: .unspecified)
        let live = F.record(7, name: "live.mov")
        let plan = FindMasterPlan.make(selected: [], all: [trashed, live], isArchived: { _ in false })
        #expect(plan.labels["sha256:" + F.digest(7)]?.name == "live.mov")
    }

    @Test("100k-record snapshot: plan and labels in under a second")
    func hundredThousandRecordSnapshot() {
        let records = (0..<100_000).map { F.record($0) }
        let clock = ContinuousClock()
        let start = clock.now
        let plan = FindMasterPlan.make(selected: Array(records.prefix(50)), all: records, isArchived: { _ in false })
        let seconds = TimingBudget.seconds(clock.now - start)
        print(String(format: "FindMasterPlan 100k: %.3f s, %d labels", seconds, plan.labels.count))
        #expect(plan.labels.count == 100_000)
        #expect(plan.queries.count == 50)
        #expect(seconds < 1)
    }
}

@Suite("FindMasterAnswer")
struct FindMasterAnswerTests {

    static func candidate(_ verdict: AudioMatchVerdict, offset: Double = 760.2) -> AudioMasterCandidate {
        let evidence = AudioMatchEvidence(matchedLandmarks: 412, coverage: 0.93, overlapSeconds: 40, spanSeconds: 40,
                                          offsetSeconds: offset, queryDurationSeconds: 40, masterDurationSeconds: 3_600)
        return AudioMasterCandidate(key: AudioFingerprintStore.Key(contentDigest: "sha256:" + String(repeating: "a", count: 64), sizeBytes: 9),
                                    match: AudioMatch(evidence: evidence, verdict: verdict, queryLandmarks: 500, masterLandmarks: 9_000,
                                                      spanStartInMasterSeconds: 760, spanEndInMasterSeconds: 800), votes: 30)
    }

    static let verdicts: [AudioMatchVerdict] = [
        .sameRecording, .containedInMaster(offsetSeconds: 760.2), .masterContainedInQuery(offsetSeconds: 12),
        .overlap(offsetSeconds: 760.2, seconds: 42), .inconclusive(reason: .masterIncomplete),
    ]

    @Test("every positive sentence carries verdict, span, offset, coverage, landmarks and 'sound'")
    func sentenceCarriesItsEvidence() throws {
        let timecode = try Regex(#"\d\d:\d\d:\d\d–\d\d:\d\d:\d\d"#)
        for verdict in Self.verdicts {
            let s = FindMasterAnswer.sentence(Self.candidate(verdict), other: "Cape-1993.mkv")
            #expect(s.contains("Cape-1993.mkv"), "\(s)")
            #expect(s.contains(timecode), "no time span: \(s)")
            #expect(s.contains("offset 760.2 s"), "\(s)")
            #expect(s.contains("coverage 0.93"), "\(s)")
            #expect(s.contains("412 matching landmarks"), "\(s)")
            #expect(s.contains("proof: sound"), "\(s)")
        }
        #expect(FindMasterAnswer.sentence(Self.candidate(.containedInMaster(offsetSeconds: 760.2)), other: "X")
            .contains("inside X from 00:12:40–00:13:20"))
    }

    @Test("no sentence claims which file is the master or the original")
    func neverClaimsDirection() {
        let geometry = ["inside", "contains", "same recording", "shares", "lines up"]
        for verdict in Self.verdicts {
            let s = FindMasterAnswer.sentence(Self.candidate(verdict), other: "tape.mov").lowercased()
            #expect(!s.contains("master"), "\(s)")
            #expect(!s.contains("original"), "\(s)")
            #expect(geometry.contains { s.contains($0) }, "\(s)")
        }
        for line in [FindMasterAnswer.noneFound(searched: 3, noSoundTrack: 1, notFingerprinted: 2),
                     FindMasterAnswer.summary(.init(searched: 2, inside: 1, none: 1), seconds: 1)] {
            #expect(!line.lowercased().contains("original"))
        }
    }

    static func overlap(coverage: Double, landmarks: Int, n: Int = 1) -> AudioMasterCandidate {
        let evidence = AudioMatchEvidence(matchedLandmarks: landmarks, coverage: coverage, overlapSeconds: 600, spanSeconds: 6,
                                          offsetSeconds: 196.9, queryDurationSeconds: 600, masterDurationSeconds: 4_000)
        return AudioMasterCandidate(key: AudioFingerprintStore.Key(contentDigest: "sha256:" + String(repeating: "\(n)", count: 64), sizeBytes: 9),
                                    match: AudioMatch(evidence: evidence, verdict: .overlap(offsetSeconds: 196.9, seconds: 6),
                                                      queryLandmarks: 16_000, masterLandmarks: 90_000,
                                                      spanStartInMasterSeconds: 268.9, spanEndInMasterSeconds: 274.9), votes: 9)
    }

    @Test("weak overlaps: below the matcher's minCoverage AND under 3× its landmark floor; everything else is strong")
    func weakOverlapsAreSplitByTheMatchersConstants() {
        #expect(FindMasterAnswer.weakCoverageBelow == AudioMatchPolicy.default.minCoverage)
        #expect(FindMasterAnswer.weakLandmarksBelow == 3 * AudioMatchPolicy.default.minMatchedLandmarks)
        let realDataLike = Self.overlap(coverage: 0.03, landmarks: 24, n: 1)       // the 2026-10-26 smoke's shape
        let manyLandmarks = Self.overlap(coverage: 0.03, landmarks: 400, n: 2)      // a long genuine shared stretch
        let distributed = Self.overlap(coverage: 0.70, landmarks: 24, n: 3)         // a short query, well covered
        let atTheLine = Self.overlap(coverage: 0.49, landmarks: 59, n: 4)
        let contained = Self.candidate(.containedInMaster(offsetSeconds: 760.2))
        #expect(FindMasterAnswer.isWeak(realDataLike))
        #expect(FindMasterAnswer.isWeak(atTheLine))
        #expect(!FindMasterAnswer.isWeak(manyLandmarks))
        #expect(!FindMasterAnswer.isWeak(distributed))
        #expect(!FindMasterAnswer.isWeak(contained))
        let (strong, weak) = FindMasterAnswer.split([contained, realDataLike, manyLandmarks, atTheLine, distributed])
        #expect(strong.map(\.key) == [contained.key, manyLandmarks.key, distributed.key], "rank order kept")
        #expect(weak.map(\.key) == [realDataLike.key, atTheLine.key])
        let header = FindMasterAnswer.weakHeader(count: 2)
        #expect(header.hasPrefix("2 weak overlaps"))
        #expect(header.contains("0.50") && header.contains("60"))
        #expect(!header.lowercased().contains("master") && !header.lowercased().contains("original"))
    }

    @Test("a negative says what was searched and what could not be")
    func negativeSaysWhatWasSearched() {
        let s = FindMasterAnswer.noneFound(searched: 3_575, noSoundTrack: 1_014, notFingerprinted: 122)
        #expect(s.contains("searched 3,575 sounded contents"))
        #expect(s.contains("1,014 have no sound track"))
        #expect(s.contains("122 not fingerprinted"))
        #expect(!s.lowercased().contains("no master"))
    }
}

@Suite("FindMasterJob", .serialized)
@MainActor
struct FindMasterJobTests {
    typealias F = FindMasterFixtures

    @Test("exactly one START and one OUTCOME; the OUTCOME's counts sum to the selection")
    func startAndOutcomeOnceWithCounts() async throws {
        let dir = try F.sidecar()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = FindMasterLineSink()
        let job = FindMasterJob(plan: F.plan(selected: [2, 3], refusedToo: true), sidecarDirectory: dir, note: sink.note)
        job.start()
        await job.task?.value
        #expect(sink.lines.filter { $0.hasPrefix("START find master") }.count == 1)
        #expect(sink.lines.filter { $0.hasPrefix("OUTCOME find master") }.count == 1)
        let t = job.tally
        #expect(t.searched + t.refused + t.notStarted == 3)
        #expect(t.inside == 1 && t.none == 1 && t.refused == 1)
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
        // The clip's answer names the master and where it sits.
        let clip = try #require(job.results.first { $0.name == "clip2.mov" })
        guard case .found(let found, _) = clip.outcome else { Issue.record("\(clip.outcome)"); return }
        #expect(found.first?.key == F.key(1))
        #expect(sink.lines.contains { $0.contains("inside clip1.mov from 00:01:40") })
    }

    @Test("weak overlaps: counted as their own bucket, one log line with their count; strong hits listed one per line")
    func weakOverlapsAreCountedAndLoggedTogether() throws {
        let job = FindMasterJob(plan: F.plan(selected: [2]), sidecarDirectory: URL(fileURLWithPath: "/nonexistent"), note: { _ in })
        let weak1 = FindMasterAnswerTests.overlap(coverage: 0.03, landmarks: 24, n: 1)
        let weak2 = FindMasterAnswerTests.overlap(coverage: 0.02, landmarks: 26, n: 2)
        let strong = FindMasterAnswerTests.candidate(.containedInMaster(offsetSeconds: 760.2))
        job.count(.found([weak1, weak2], searched: 10))
        job.count(.found([strong, weak1], searched: 10))
        #expect(job.tally.weakOnly == 1)
        #expect(job.tally.inside == 1)
        #expect(job.tally.searched == 2)
        #expect(FindMasterAnswer.summary(job.tally, seconds: 1).contains("1 only weak overlaps"))
        let query = try #require(job.plan.queries.first)
        let lines = job.lines(for: query, outcome: .found([strong, weak1, weak2], searched: 10))
        #expect(lines.count == 2)
        #expect(lines[0].contains("inside"))
        #expect(lines[1].contains("2 weak overlaps"))
        #expect(lines[1].contains("24 landmarks") && lines[1].contains("26 landmarks"))
    }

    @Test("Stop after query 1 of 3 → stopped, 1 searched, 2 not started")
    func stopMidRunSaysStopped() async throws {
        let dir = try F.sidecar()
        defer { try? FileManager.default.removeItem(at: dir) }
        let sink = FindMasterLineSink()
        let job = FindMasterJob(plan: F.plan(selected: [2, 3, 4]), sidecarDirectory: dir, note: sink.note)
        job.afterQuery = { [weak job] n in if n == 1 { job?.cancel() } }
        job.start()
        await job.task?.value
        #expect(job.state == .cancelled)
        #expect(job.tally.searched == 1)
        #expect(job.tally.notStarted == 2)
        let outcome = try #require(sink.lines.last)
        #expect(outcome.hasPrefix("OUTCOME find master — stopped"))
        #expect(outcome.contains("2 not started"))
    }

    @Test("a paused job does not start query 2 until resumed")
    func pauseHoldsBetweenQueries() async throws {
        let dir = try F.sidecar()
        defer { try? FileManager.default.removeItem(at: dir) }
        let job = FindMasterJob(plan: F.plan(selected: [2, 4]), sidecarDirectory: dir, note: { _ in })
        job.afterQuery = { [weak job] n in if n == 1 { job?.pause() } }
        job.start()
        // Wait for the pause itself (the Debug index build takes seconds),
        // bounded; if it never comes, stop the job rather than hang the run.
        let deadline = ContinuousClock.now + .seconds(60)
        while !(job.isPaused && job.results.count == 1), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        guard job.isPaused else {
            Issue.record("the job never paused after query 1")
            job.cancel()
            await job.task?.value
            return
        }
        try await Task.sleep(for: .milliseconds(400))
        #expect(job.results.count == 1, "query 2 started while paused")
        job.resume()
        await job.task?.value
        #expect(job.results.count == 2)
        guard case .finished = job.state else { Issue.record("\(job.state)"); return }
    }

    @Test("a missing, poisoned or -wal-less sidecar is refused before reading; no query runs")
    func unopenableSidecarRefusesBeforeReading() async throws {
        let missing = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_findmaster_missing_\(UUID().uuidString)")
        let poisoned = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("test_findmaster_poison_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: poisoned, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: poisoned) }
        try Data(repeating: 0x5A, count: 4_096).write(to: poisoned.appendingPathComponent(AudioFingerprintStore.fileName))
        // A WAL sidecar "last closed by another program": no -wal, no -shm
        // (test-owned scratch files). Refused (TODO #386), never re-created.
        let noWAL = try F.sidecar()
        defer { try? FileManager.default.removeItem(at: noWAL) }
        let noWALFile = noWAL.appendingPathComponent(AudioFingerprintStore.fileName).path
        try? FileManager.default.removeItem(atPath: noWALFile + "-wal")
        try? FileManager.default.removeItem(atPath: noWALFile + "-shm")
        for (dir, words) in [(missing, "no sound prints yet"), (poisoned, "not a database"), (noWAL, "write-ahead log")] {
            let sink = FindMasterLineSink()
            let job = FindMasterJob(plan: F.plan(selected: [2, 3]), sidecarDirectory: dir, note: sink.note)
            job.start()
            await job.task?.value
            #expect(job.wasRefused)
            guard case .failed(let message) = job.state else { Issue.record("\(job.state)"); continue }
            #expect(message.contains(words), "\(message)")
            #expect(job.tally.searched == 0)
            #expect(job.results.isEmpty)
            #expect(sink.lines.filter { $0.hasPrefix("OUTCOME find master") }.count == 1)
        }
        // Refusing never created the missing sidecar, nor the missing -wal.
        #expect(!FileManager.default.fileExists(atPath: missing.path))
        #expect(!FileManager.default.fileExists(atPath: noWALFile + "-wal"))
    }

    /// Bytes + mtime of the main file and -wal; inode of each sidecar file.
    struct SidecarFacts: Equatable {
        var db = Data(), wal: Data?
        var dbModified: Date?, walModified: Date?
        var inodes: [String: Int] = [:]
        static func of(_ dir: URL) throws -> SidecarFacts {
            let fm = FileManager.default
            let path = dir.appendingPathComponent(AudioFingerprintStore.fileName).path
            var f = SidecarFacts()
            f.db = try Data(contentsOf: URL(fileURLWithPath: path))
            f.dbModified = try fm.attributesOfItem(atPath: path)[.modificationDate] as? Date
            if fm.fileExists(atPath: path + "-wal") {
                f.wal = try Data(contentsOf: URL(fileURLWithPath: path + "-wal"))
                f.walModified = try fm.attributesOfItem(atPath: path + "-wal")[.modificationDate] as? Date
            }
            for suffix in ["", "-wal", "-shm"] {
                if let ino = try? fm.attributesOfItem(atPath: path + suffix)[.systemFileNumber] as? Int { f.inodes[suffix] = ino }
            }
            return f
        }
    }

    @Test("a run writes nothing: bytes, mtime and inodes unchanged — idle, and while a writer holds -wal frames")
    func writesNothing() async throws {
        let dir = try F.sidecar()
        defer { try? FileManager.default.removeItem(at: dir) }
        func run() async {
            let job = FindMasterJob(plan: F.plan(selected: [1, 2, 3, 4]), sidecarDirectory: dir, note: { _ in })
            job.start()
            await job.task?.value
            if case .finished = job.state {} else { Issue.record("\(job.state)") }
        }
        // Idle sidecar (no other connection).
        let idle = try SidecarFacts.of(dir)
        await run()
        #expect(try SidecarFacts.of(dir) == idle)
        // A running Fingerprint Sound: an open writer whose newest row lives
        // only in -wal frames — never checkpointed by this reader.
        var writer: AudioFingerprintStore? = try AudioFingerprintStore(directory: dir)
        try writer?.put([.init(key: F.key(9), fingerprint: F.print(F.recording(seconds: 30, seed: 3), seconds: 30), sourcePath: "test")])
        let walSize = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(AudioFingerprintStore.fileName).path + "-wal")[.size] as? Int ?? 0
        #expect(walSize > 0, "the fixture must have WAL frames")
        let busy = try SidecarFacts.of(dir)
        await run()
        #expect(try SidecarFacts.of(dir) == busy)
        writer = nil
        _ = writer
    }
}
