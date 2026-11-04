// AudioFingerprintAttemptTests.swift
// GH #416 part 2 (Rick approved option B, 2026-11-03): a file whose sound
// was heard but too little to print, or whose decode failed, is TRIED at
// most 3 times per engine version, and the tries are recorded in
// catalog.sqlite (`sound_attempts`, schema v15) through the one commit door
// — so a relaunch does not forget them and the plan stops reading the same
// ~1,138 files every run.
//
// Dimensions:
//   LOGIC      3 tries then skipped; a newer engine version retries; a
//              success removes the attempts row; only decode failures and
//              heard-too-little count (missing, drive gone, record changed,
//              cut off, a timeout, ffmpeg missing do not).
//   TRUTH      the coverage report does not count a capped file as left to
//              analyze and says "N gave up after 3 tries".
//   ISOLATION  a v1-only record never gets an attempts row; two disputed
//              fixities never key one.
//   SCALE      the plan over 100k records with capped attempts (in budget).
//   SENSOR     the catalog-writer quartet (debounce, write hold, role flip,
//              relaunch) — the attempt rides the record like the stamp.
// Media matrix: N/A (no decode; the pass is stubbed — the decoder itself
// is AudioFingerprintBackfillMediaMatrixTests' job).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// A print that HEARD sound (2 loud seconds) but made no landmark.
private let heardTooLittlePass: AudioFingerprintBackfillJob.Pass = { item in
    AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 3,
                     activeSeconds: [true, true, false], hashes: [], times: [], secondsAboveSilenceCeiling: 2)
}

/// ffmpeg could not decode the file.
private let decodeFailsPass: AudioFingerprintBackfillJob.Pass = { _ in
    throw AudioPCMDecoder.Failure.decodeFailed(exitCode: 1, stderrTail: "Invalid data found when processing input")
}

/// A printable print.
private let printablePass: AudioFingerprintBackfillJob.Pass = { item in
    AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: item.durationSeconds,
                     complete: true, hashes: (0..<64).map { UInt32($0) &* 2_654_435_761 &+ 3 },
                     times: (0..<64).map { UInt32($0 * 2) })
}

@MainActor
enum AttemptScene {

    /// The real job, a stub pass, the PRODUCTION save.
    @discardableResult
    static func run(_ model: VideoScanModel, pass: @escaping AudioFingerprintBackfillJob.Pass,
                    fileExists: (@Sendable (String) -> Bool)? = nil) async -> AudioFingerprintBackfillJob {
        let job = AudioFingerprintBackfillJob(model: model)
        job.volumeOnline = { _ in true }
        if let fileExists { job.fileExists = fileExists }
        job.tickMilliseconds = 20
        job.passForTesting = pass
        job.ffmpegPath = "/bin/ls"   // the stubbed pass never runs ffmpeg
        job.start()
        await job.task?.value
        return job
    }

    /// One committed record with a full SHA-256 (content fixity), on disk.
    static func soundFile(_ scene: CutoverScene, label: String) throws -> (record: VideoRecord, digest: String) {
        let dir = scene.folder.appendingPathComponent("media", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let size = 32 * 1024
        let url = try MasterArchiveTestSupport.writeBlob(at: dir.appendingPathComponent("\(label).mov"), bytes: size, seed: 417)
        let digest = try scene.sha256(url)
        let r = try scene.freshCopy(of: .healthy, path: url.path)
        r.sizeBytes = Int64(size)
        r.audioFingerprint = nil
        r.audioCodec = "aac"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.durationSeconds = 3
        r.contentHash = "v1:\(label)"
        r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(size))
        scene.model.records.append(r)
        try #require(scene.model.saveCatalogNow(), "fixture: the record is in catalog.sqlite")
        return (r, digest)
    }

    /// One integer from the scene's catalog.sqlite (a second handle).
    static func count(_ scene: CutoverScene, _ sql: String) throws -> Int {
        Int(try sqliteTable(scene.databaseURL, sql).first?.first ?? "") ?? -1
    }

    static func planned(_ model: VideoScanModel) -> Set<UUID> {
        Set(model.audioFingerprintBackfillPlan().lanes.flatMap(\.items).map(\.id))
    }
}

@Suite("Fingerprint sound — #416 part 2: heard-too-little and failed decodes are tried 3 times, not forever", .serialized)
@MainActor
struct AudioFingerprintAttemptTests {

    @Test("RED #416: a heard-too-little file is tried 3 times across relaunches, then the plan skips it")
    func heardTooLittleIsTriedThreeTimesThenSkipped() async throws {
        let scene = try CutoverScene.make("attempt_htl"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, _) = try AttemptScene.soundFile(scene, label: "clip1")
        for run in 1...3 {
            try await scene.relaunch()
            #expect(AttemptScene.planned(scene.model).contains(r.id), "run \(run): still to try")
            let job = await AttemptScene.run(scene.model, pass: heardTooLittlePass)
            #expect(job.totals[.heardTooLittle] == 1, "run \(run): \(job.totals.line)")
        }
        try await scene.relaunch()
        #expect(!AttemptScene.planned(scene.model).contains(r.id), "after 3 tries and a relaunch the file is not read a fourth time")
    }

    @Test("RED #416: a file ffmpeg cannot decode is tried 3 times across relaunches, then the plan skips it")
    func decodeFailureIsTriedThreeTimesThenSkipped() async throws {
        let scene = try CutoverScene.make("attempt_fail"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, _) = try AttemptScene.soundFile(scene, label: "broken1")
        for run in 1...3 {
            try await scene.relaunch()
            let job = await AttemptScene.run(scene.model, pass: decodeFailsPass)
            #expect(job.totals[.failed] == 1, "run \(run): \(job.totals.line)")
        }
        try await scene.relaunch()
        #expect(!AttemptScene.planned(scene.model).contains(r.id), "after 3 failed decodes the file is not read a fourth time")
    }

    @Test("a file missing at its path is not an attempt: after 4 runs it is still planned")
    func missingIsNotAnAttempt() async throws {
        let scene = try CutoverScene.make("attempt_missing"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, _) = try AttemptScene.soundFile(scene, label: "gone1")
        for _ in 1...4 {
            try await scene.relaunch()
            _ = await AttemptScene.run(scene.model, pass: decodeFailsPass, fileExists: { _ in false })
        }
        try await scene.relaunch()
        #expect(AttemptScene.planned(scene.model).contains(r.id), "missing at its path is not the file's fault — tried again when it is there")
    }

    // MARK: - LOGIC

    @Test("a print after two tries ends them: sound_attempts has no row, the reloaded record carries none, sound_prints has the print")
    func aPrintEndsTheTries() async throws {
        let scene = try CutoverScene.make("attempt_success"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, digest) = try AttemptScene.soundFile(scene, label: "late1")
        for _ in 1...2 {
            try await scene.relaunch()
            await AttemptScene.run(scene.model, pass: heardTooLittlePass)
        }
        try await scene.relaunch()
        #expect(scene.model.records.first { $0.id == r.id }?.audioFingerprintAttempt?.attempts == 2)
        await AttemptScene.run(scene.model, pass: printablePass)
        try await scene.relaunch()
        let reloaded = try #require(scene.model.records.first { $0.id == r.id })
        #expect(reloaded.audioFingerprintAttempt == nil, "a print is not an attempt")
        #expect(reloaded.audioFingerprint?.contentDigest == "sha256:" + digest)
        #expect(try AttemptScene.count(scene, "SELECT count(*) FROM sound_attempts") == 0)
        #expect(try AttemptScene.count(scene, "SELECT count(*) FROM sound_prints WHERE digest = '\(digest)'") == 1)
    }

    @Test("a timeout and a missing ffmpeg are not attempts; a cut-off run is not either")
    func environmentFailuresAreNotAttempts() async throws {
        let scene = try CutoverScene.make("attempt_env"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, _) = try AttemptScene.soundFile(scene, label: "slow1")
        for _ in 1...4 {
            await AttemptScene.run(scene.model, pass: { _ in throw AudioPCMDecoder.Failure.timedOut })
            await AttemptScene.run(scene.model, pass: { _ in throw AudioPCMDecoder.Failure.ffmpegMissing(path: "/nope") })
        }
        #expect(r.audioFingerprintAttempt == nil, "a slow drive or a missing tool is not the file's fault")
        try await scene.relaunch()
        #expect(AttemptScene.planned(scene.model).contains(r.id))
    }

    @Test("a record with only a sampled v1: hash never gets a try (it is tried every run, as before)")
    func aSampledOnlyRecordNeverGetsATry() async throws {
        let sb = try ShowAgainSandbox.make("attempt_v1"); defer { sb.cleanup() }
        let r = try sb.record("v1only.mov", bytes: 2_000, onDisk: true, stage: .none)
        r.contentHash = "v1:v1only"
        r.durationSeconds = 3
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.audioCodec = "aac"
        for _ in 1...4 { await AttemptScene.run(sb.model, pass: heardTooLittlePass) }
        #expect(r.audioFingerprintAttempt == nil)
        #expect(AttemptScene.planned(sb.model).contains(r.id))
    }

    @Test("a newer engine retries: 3 tries by an OLDER engine count 0, the file is planned and its count restarts")
    func aNewerEngineRetries() async throws {
        let sb = try ShowAgainSandbox.make("attempt_engine"); defer { sb.cleanup() }
        let r = try sb.record("old.mov", bytes: 2_000, onDisk: true, stage: .none)
        let digest = String(repeating: "c", count: 64)
        r.contentHash = "v1:old"
        r.durationSeconds = 3
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.audioCodec = "aac"
        r.contentFixity = ContentFixity.captured(path: r.fullPath, digest: digest, byteCount: 2_000)
        r.audioFingerprintAttempt = AudioFingerprintAttempt(contentDigest: "sha256:" + digest,
                                                            engineVersion: AudioFingerprintStamp.currentEngineVersion - 1,
                                                            outcome: .heardTooLittle, attempts: 3)
        #expect(AttemptScene.planned(sb.model).contains(r.id), "an older engine's 3 tries do not skip it")
        await AttemptScene.run(sb.model, pass: heardTooLittlePass)
        #expect(r.audioFingerprintAttempt?.attempts == 1)
        #expect(r.audioFingerprintAttempt?.engineVersion == AudioFingerprintStamp.currentEngineVersion)
        r.audioFingerprintAttempt?.attempts = 3
        let plan = sb.model.audioFingerprintBackfillPlan()
        #expect(!plan.lanes.flatMap(\.items).contains { $0.id == r.id })
        #expect(plan.gaveUp == 1 && plan.gaveUpHeardTooLittle == 1 && plan.gaveUpFailed == 0)
    }

    @Test("the words: START and OUTCOME say how many were skipped after 3 tries; the problem row says which try")
    func theWordsSayIt() async throws {
        let scene = try CutoverScene.make("attempt_words"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        _ = try AttemptScene.soundFile(scene, label: "w1")
        var last: AudioFingerprintBackfillJob?
        for _ in 1...3 { last = await AttemptScene.run(scene.model, pass: decodeFailsPass) }
        #expect(last?.problems.contains { $0.detail.contains("try 3 of 3; not tried again by this engine") } == true,
                "\(last?.problems.map(\.detail) ?? [])")
        let fourth = await AttemptScene.run(scene.model, pass: decodeFailsPass)
        let words = AudioFingerprintBackfillTotals.gaveUpWords(1)
        #expect(words == "1 skipped after 3 tries (heard too little / failed) — a new engine retries them")
        #expect(fourth.totals.line.contains(words), Comment(rawValue: fourth.totals.line))
        #expect(scene.sandbox.catalogLogText().contains("START — ") && scene.sandbox.catalogLogText().contains(words))
    }

    // MARK: - TRUTH: the coverage count

    @Test("TRUTH: a capped file is covered (observed), never 'left'; the Catalog Status note says how many gave up; an older engine's tries are still left")
    func coverageCountsAGiveUpAsObservedAndSaysSo() throws {
        let sb = try ShowAgainSandbox.make("attempt_cov"); defer { sb.cleanup() }
        let digest = String(repeating: "d", count: 64)
        func rec(_ name: String, engine: Int, tries: Int) throws -> VideoRecord {
            let r = try sb.record(name, bytes: 2_000, onDisk: true, stage: .none)
            r.contentHash = "v1:" + name
            r.contentFixity = ContentFixity.captured(path: r.fullPath, digest: digest, byteCount: 2_000)
            r.audioFingerprintAttempt = AudioFingerprintAttempt(contentDigest: "sha256:" + digest, engineVersion: engine,
                                                                outcome: .failed, attempts: tries)
            return r
        }
        let capped = try rec("capped.mov", engine: AudioFingerprintStamp.currentEngineVersion, tries: 3)
        let trying = try rec("trying.mov", engine: AudioFingerprintStamp.currentEngineVersion, tries: 2)
        let oldEngine = try rec("old.mov", engine: AudioFingerprintStamp.currentEngineVersion - 1, tries: 3)
        let inputs = [capped, trying, oldEngine].map(AnalyzeCoverageInput.init(record:))
        #expect(inputs.map(\.soundGaveUp) == [true, false, false])
        let report = AnalyzeCoverageCalculator.compute(inputs: inputs, volumes: [], mountedRoots: [], scope: AnalysisScope())
        let sound = report.counts(.soundPrints)
        #expect(sound.eligible == 3)
        #expect(sound.covered == 1, "the capped file is observed")
        #expect(sound.remaining == 2, "still trying, or tried only by an older engine")
        #expect(report.soundGaveUp == 1)
        let row = CatalogFreshnessRows.row(.soundPrints, report: report, facts: CatalogFreshnessFacts(), running: [])
        #expect(row.note == "1 gave up after 3 tries (heard too little or would not decode) — a new engine retries them")
    }

    // MARK: - SCALE

    @Test("SCALE: planning 100k records, a third of them capped, stays inside the budget and skips exactly the capped ones")
    func planningAt100kWithCappedTries() throws {
        let sb = try ShowAgainSandbox.make("attempt_scale"); defer { sb.cleanup() }
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/D\(i % 10)/f\(i).mov"
            r.filename = "f\(i).mov"
            r.sizeBytes = 1_000
            r.contentHash = "v1:\(i)"
            let hex = String(format: "%064x", i)
            r.contentFixity = ContentFixity(digest: hex, byteCount: 1_000, stamp: FileIdentityStamp(device: 1, inode: UInt64(i), size: 1_000, mtimeNs: 1))
            if i % 3 == 0 {
                r.audioFingerprintAttempt = AudioFingerprintAttempt(contentDigest: "sha256:" + hex, outcome: .heardTooLittle, attempts: 3)
            }
            records.append(r)
        }
        let clock = ContinuousClock()
        var plan = AudioFingerprintBackfillPlan()
        let elapsed = clock.measure { plan = AudioFingerprintBackfillPlanner.plan(records: records) { _ in false } }
        #expect(plan.gaveUp == 33_334)
        #expect(plan.fileCount == 66_666)
        #expect(elapsed < .seconds(5), "100k plan took \(elapsed)")
    }

    // MARK: - SENSOR: the catalog-writer quartet (rule 8)

    @Test("quartet 1: a try, then a star inside the debounce window — both are in catalog.sqlite after a relaunch")
    func aTryAndAnEditInTheDebounceWindowBothLand() async throws {
        let scene = try CutoverScene.make("attempt_debounce"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, _) = try AttemptScene.soundFile(scene, label: "deb1")
        let item = try #require(scene.model.audioFingerprintBackfillPlan().lanes.flatMap(\.items).first { $0.id == r.id })
        #expect(scene.model.applyAudioFingerprintAttempt(.heardTooLittle, detail: "2 audible seconds", to: item) != nil)
        scene.model.saveCatalogDebounced()
        r.starRating = 3
        scene.model.saveCatalogDebounced()
        #expect(scene.model.saveCatalogNow())
        try await scene.relaunch()
        let back = try #require(scene.model.records.first { $0.id == r.id })
        #expect(back.audioFingerprintAttempt?.attempts == 1)
        #expect(back.starRating == 3)
    }

    @Test("quartet 2: during another job's write hold the job's save is refused — its tries are undone, nothing half-written, and a relaunch tries again")
    func aWriteHoldUndoesTheTries() async throws {
        let scene = try CutoverScene.make("attempt_hold"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, _) = try AttemptScene.soundFile(scene, label: "hold1")
        _ = await scene.model.catalogStore.holdWrites(reason: "a test job is reading the catalog", owner: CatalogWriteHoldOwner())
        let job = await AttemptScene.run(scene.model, pass: heardTooLittlePass)
        scene.model.catalogStore.releaseWriteHold()
        #expect(job.saveFailed, Comment(rawValue: job.totals.line))
        #expect(r.audioFingerprintAttempt == nil, "the unsaved try was undone")
        try await scene.relaunch()
        #expect(try AttemptScene.count(scene, "SELECT count(*) FROM sound_attempts") == 0)
        #expect(AttemptScene.planned(scene.model).contains(r.id))
    }

    @Test("quartet 3: across a role flip — a try accepted before the session turns read-only is committed; after it, none is written")
    func aRoleFlipCommitsTheTryThenRefuses() async throws {
        let scene = try CutoverScene.make("attempt_role"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, _) = try AttemptScene.soundFile(scene, label: "role1")
        let item = try #require(scene.model.audioFingerprintBackfillPlan().lanes.flatMap(\.items).first { $0.id == r.id })
        #expect(scene.model.applyAudioFingerprintAttempt(.failed, detail: "exit 1", to: item) != nil)
        scene.model.applyReadOnlyMode(true)
        #expect(scene.model.applyAudioFingerprintAttempt(.failed, detail: "exit 1", to: item) == nil, "a viewer writes no try")
        let loaded = try await scene.sqliteLoad()
        #expect(loaded.records.first { $0.id == r.id }?.audioFingerprintAttempt?.attempts == 1, "the accepted try was committed at the flip")
    }

    @Test("quartet 4 (relaunch): a try survives a quit and relaunch with its count, outcome, engine and words")
    func aTrySurvivesARelaunch() async throws {
        let scene = try CutoverScene.make("attempt_relaunch"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let (r, digest) = try AttemptScene.soundFile(scene, label: "rel1")
        await AttemptScene.run(scene.model, pass: decodeFailsPass)
        let live = try #require(r.audioFingerprintAttempt)
        try await scene.relaunch()
        let back = try #require(scene.model.records.first { $0.id == r.id }?.audioFingerprintAttempt)
        #expect(back.contentDigest == "sha256:" + digest)
        #expect(back.attempts == 1 && back.outcome == .failed && back.engineVersion == live.engineVersion)
        #expect(back.detail?.contains("Invalid data found") == true, "\(back.detail ?? "nil")")
        #expect(abs(back.lastAt.timeIntervalSince(live.lastAt)) < 1)
    }
}
