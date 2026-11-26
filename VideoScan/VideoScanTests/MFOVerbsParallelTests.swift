// MFOVerbsParallelTests.swift
// Rick 2026-11-20: "prove to yourself you can run each MFO verb in parallel …
// we do not want to serialize when we can parallelize." The Media File
// Operations Center does not serialize jobs (its only limit is the per-volume
// gate: internal/SSD unrestricted, HDD 1, other 2 — MediaVolumeGatePolicy);
// this file proves it through the REAL engine on synthetic media.
//
//   * LOGIC + MEDIA MATRIX: every verb that has an engine and can run on a
//     synthetic fixture is started through ONE MediaFileOperationsCenter, each
//     in its own sandbox (own folder, own CatalogStore, own ledger, own logs,
//     own archive root). Each verb runs ALONE first (its outcome is the
//     reference), then ALL of them at once; every concurrent outcome must equal
//     its alone outcome. The fixtures span mp4/h264, mov/prores, mkv/ffv1+pcm,
//     mxf/mpeg2+pcm and avi/dv.
//   * TIMING (printed, not asserted beyond "concurrent beats serial"): the sum
//     of the alone runs vs the concurrent wall clock.
//   * SCALE (MFOVerbsScalingTests.swift): a fixed batch of real jobs admitted K at a
//     time for K = 1 … 48 — the N where wall time stops improving on this Mac.
//   * SENSOR (MFOVerbsParallelInventorySensorTests): every kind in
//     MediaFileOperationKind.all has a parallelism verdict here, and every
//     verb this file does not run says why.
//
// Not `.serialized`: the suites are the claim. Synthetic `test_` fixtures in
// per-scenario temp folders only — never family media, never App Support.
// Memory: each fixture is ≤ 4 s of 320×240 … 720×576 video (≤ ~3 MB); the
// concurrent run holds ~30 of them on disk and a handful of ffmpeg children
// at once — tens of MB, bounded by the scenario count.
//
// (For Rick: a scenario is a pair of closures — build the fixture, then start
// the job and read back its facts — ≈ a C++ struct of two std::function, so
// the same scenario runs alone and in the crowd without copying its setup.)

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - Parallelism verdicts (the inventory, pinned)

/// How a verb may run beside others. The inventory table in the report and
/// this enum say the same thing; the sensor below pins that every kind has one.
enum MFOParallelVerdict: Equatable {
    /// Runs beside any other job, sharing nothing it can corrupt.
    case parallelSafe
    /// Runs beside any other job once it has its own sandbox (catalog store,
    /// archive root, folder) — the shared thing is the catalog or the archive.
    case parallelSafeWithIsolation
    /// The engine itself admits one of these at a time (per Center or per
    /// archive root), by design — the reason is the string.
    case oneAtATimeByDesign(String)
    /// No engine to run (retired verb kept in the vocabulary) — the reason.
    case noEngine(String)
}

enum MFOParallelInventory {
    /// One entry per kind in `MediaFileOperationKind.all`. A verdict about
    /// TWO jobs of the SAME kind is in the string; different kinds run side
    /// by side unless the string says otherwise.
    static let verdicts: [String: MFOParallelVerdict] = [
        "combine": .noEngine("not a Center job: VideoScanModel+Combine runs its own pool (maxConcurrency); the kind is only its badge"),
        "compare": .parallelSafe,
        "extract": .noEngine("startExtract retired 2026-10-07 (MediaFileOperations.swift:1323); the kind stays for old log lines"),
        "ripFrames": .noEngine("startRipAllFrames retired 2026-10-07 (MediaFileOperations.swift:1323); the kind stays for old log lines"),
        "reformat": .parallelSafe,
        "analyze": .parallelSafeWithIsolation,
        "transcode": .parallelSafe,
        "cleanup": .parallelSafe,
        "trim": .parallelSafe,
        "balanceAudio": .parallelSafe,
        "rebuildAudio": .parallelSafe,
        "verifyAudio": .parallelSafe,
        "verifyVideo": .parallelSafe,
        "checkMedia": .parallelSafe,
        "repair": .parallelSafe,
        "findPerson": .parallelSafeWithIsolation,
        "promote": .parallelSafeWithIsolation,
        "verifyArchive": .parallelSafeWithIsolation,
        "archiveAngel": .parallelSafeWithIsolation,
        "deleteDuplicates": .parallelSafeWithIsolation,
        "pruneCopies": .oneAtATimeByDesign("batches queue behind each other in one Center (startPruneApply → enqueue) — one removal turn at a time"),
        "findSimilarFootage": .parallelSafeWithIsolation,
        "bindFixity": .parallelSafeWithIsolation,
        "lockArchive": .parallelSafeWithIsolation,
        "compareFootage": .parallelSafe,
        "fingerprintBackfill": .parallelSafeWithIsolation,
        "showAgain": .parallelSafeWithIsolation,
        "checkCopies": .parallelSafeWithIsolation,
        "fillFullHashes": .parallelSafeWithIsolation,
        "cleanupTrash": .oneAtATimeByDesign("one Cleanup per Center (startCleanup(selection:) refuses a second) — the one bulk removal door"),
        "fingerprintSound": .parallelSafeWithIsolation,
        "auditCatalog": .oneAtATimeByDesign("one catalog checker per Center: refused while Validate runs (validateRunsItsOwn) — runs as Validate's first phase"),
        "verifyCatalog": .oneAtATimeByDesign("one catalog checker per Center: refused while Validate runs (validateRunsItsOwn) — runs as Validate's second phase"),
        "validateCatalog": .parallelSafeWithIsolation,
        "findMaster": .parallelSafe,
        "indexFrames": .parallelSafeWithIsolation,
        "estimateProvenance": .parallelSafeWithIsolation,
        "remeasureSoundLevels": .parallelSafeWithIsolation,
        "findMovedCopies": .parallelSafe,
    ]

    /// Verbs the concurrent test does not start, with the reason. Everything
    /// else in `verdicts` that is not `.noEngine` runs in the crowd.
    static let notInTheCrowd: [String: String] = [
        "analyze": "needs the caption orchestrator's models (VLM + Whisper via Ollama) — external services; AnalyzeLegacyCodecTests runs it per file",
        "findPerson": "needs reference faces and the frozen recognition models; FindPerson*Tests cover the job",
        "archiveAngel": "an orchestrator of Verify Audio + Balance + Promote, all three in the crowd; ArchiveAngelWholeJobTests runs it end to end",
        "pruneCopies": "queues by design (see its verdict); PruneApplyJobTests covers the queue",
        "cleanupTrash": "one per Center by design (see its verdict); CleanupTrashRunTests covers it",
        "auditCatalog": "runs inside validateCatalog (in the crowd); refused beside it by design",
        "verifyCatalog": "runs inside validateCatalog (in the crowd); refused beside it by design",
        "compareFootage": "needs the FootageSpectrum helper's Python environment (venv-mlx); FootageSpectrumTests covers the job",
        "indexFrames": "needs a frame-embedding model; FrameIndexEngineTests runs it with a stub embedder",
        "findMaster": "reads a fingerprint sidecar built by fingerprintSound; FindMasterTests covers the job",
        "estimateProvenance": "reads only the catalog's provenance tables (no media); ProvenanceEstimateTests covers the job",
        "remeasureSoundLevels": "needs saved Check Media cards from before the fix (#516); SoundLevelsRemeasureTests covers the job",
        "findMovedCopies": "needs held-back rows from an October import; HeldBackTests covers the job (reads only, writes nothing)",
        "fingerprintBackfill": "needs the perceptual-fingerprint model; PerceptualFingerprintStoreTests covers the job",
        "bindFixity": "needs an archive volume with pre-identity fixity stamps; FixityStampVolumeIdentityTests covers the job",
    ]
}

// MARK: - Harness

/// One verb's run: started through the Center, read back once terminal.
struct MFOVerbRun {
    let start: @MainActor (MediaFileOperationsCenter) -> (any MediaFileOperationJob)?
    /// The outcome facts — compared alone vs in the crowd. Must not contain
    /// anything run-specific (paths, clocks); `MFOVerbHarness.state` helps.
    let facts: @MainActor (any MediaFileOperationJob) -> String
    let cleanup: () -> Void
}

struct MFOVerbScenario {
    let kind: MediaFileOperationKind
    /// Builds the fixture (not timed) in a fresh sandbox.
    let prepare: @MainActor () async throws -> MFOVerbRun
}

@MainActor
enum MFOVerbHarness {

    /// Waits until `job` leaves its active state; false on timeout.
    static func awaitTerminal(_ job: any MediaFileOperationJob, seconds: Double = 240) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(seconds)
        while job.state.isActive {
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(10))
        }
        // The Center's terminal watcher and the jobs' own epilogues hop a
        // main-actor turn or two after the state flips.
        for _ in 0..<3 { await Task.yield() }
        return true
    }

    /// The terminal state with run-specific detail removed.
    /// `encoded`: the verb ENCODES (hardware VideoToolbox / x264 rate
    /// control) — its output is not bit-reproducible run to run, so the
    /// byte size in its summary is dropped; everything else must match.
    static func state(_ job: any MediaFileOperationJob, root: URL? = nil, encoded: Bool = false) -> String {
        func clean(_ s: String) -> String {
            var t = s
            if encoded {
                t = t.replacingOccurrences(of: #"\(\d+(\.\d+)? (B|KB|MB|GB)\)"#, with: "(<size>)", options: .regularExpression)
            }
            if let root { t = t.replacingOccurrences(of: root.path, with: "<sb>") }
            // Timestamps in derived names and elapsed clocks differ per run.
            t = t.replacingOccurrences(of: #"\d{8}-\d{6}"#, with: "<ts>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\b\d+(\.\d+)?\s?(ms|s|sec|seconds)\b"#, with: "<t>", options: .regularExpression)
            t = t.replacingOccurrences(of: #"\b\d+m \d+s\b"#, with: "<t>", options: .regularExpression)
            return t
        }
        switch job.state {
        case .finished(let summary): return "finished: " + clean(summary)
        case .failed(let message): return (job.wasRefused ? "refused: " : "failed: ") + clean(message)
        case .cancelled: return "cancelled"
        case .running: return "running"
        case .cancelling: return "cancelling"
        }
    }

    static func sha256(_ path: String) -> String {
        guard let h = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return "unreadable" }
        defer { try? h.close() }
        var hasher = SHA256()
        while let chunk = try? h.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    static func exists(_ url: URL?) -> Bool { url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false }

    struct Outcome {
        let kind: MediaFileOperationKind
        let facts: String
        let seconds: Double
    }

    /// Prepares every scenario, starts them all on `center`, waits for all.
    /// `limit` = how many may be in flight at once (nil = all). Returns the
    /// outcomes in scenario order and the wall time of the run phase.
    /// `centerPerJob`: each job gets its own Center, as each test in the
    /// testbed does — needed when the batch repeats a catalog-wide verb,
    /// which a Center admits once per kind by design.
    static func run(_ scenarios: [MFOVerbScenario], limit: Int? = nil, centerPerJob: Bool = false,
                    center: MediaFileOperationsCenter = MediaFileOperationsCenter()) async throws
        -> (outcomes: [Outcome], wall: Double, mainLagMax: Double) {
        var runs: [MFOVerbRun] = []
        defer {
            let cleanups = runs.map(\.cleanup)
            runs.removeAll()
            cleanups.forEach { $0() }
        }
        for s in scenarios { runs.append(try await s.prepare()) }

        let clock = ContinuousClock()
        let t0 = clock.now
        var jobs = [(any MediaFileOperationJob)?](repeating: nil, count: runs.count)
        var took = [Double](repeating: 0, count: runs.count)
        var startedAt = [ContinuousClock.Instant](repeating: t0, count: runs.count)
        var lastEnd = t0
        var centers: [MediaFileOperationsCenter] = []
        var mainLagMax = 0.0
        var inFlight: [Int] = []
        var next = 0
        let cap = limit ?? runs.count
        while next < runs.count || !inFlight.isEmpty {
            while next < runs.count && inFlight.count < cap {
                startedAt[next] = clock.now
                let c = centerPerJob ? MediaFileOperationsCenter() : center
                centers.append(c)   // a Center owns its jobs' bookkeeping — keep it alive for the run
                jobs[next] = runs[next].start(c)
                if jobs[next] != nil { inFlight.append(next) }
                next += 1
            }
            if inFlight.isEmpty { continue }
            // Main-actor lag: this loop asks for 5 ms; how late it wakes is
            // how busy the main actor is (every job is @MainActor).
            let asked = clock.now
            try? await Task.sleep(for: .milliseconds(5))
            mainLagMax = max(mainLagMax, seconds(clock.now - asked) - 0.005)
            inFlight.removeAll { i in
                guard let job = jobs[i], !job.state.isActive || clock.now - t0 > .seconds(900) else { return false }
                lastEnd = clock.now
                took[i] = seconds(lastEnd - startedAt[i])
                return true
            }
        }
        let wall = seconds(lastEnd - t0)
        // Facts once everything has stopped: reading them (hashes) is not
        // part of anyone's run time.
        var outcomes: [Outcome] = []
        for i in runs.indices {
            guard let job = jobs[i] else {
                outcomes.append(Outcome(kind: scenarios[i].kind, facts: "not started", seconds: 0)); continue
            }
            _ = await awaitTerminal(job, seconds: 1)
            outcomes.append(Outcome(kind: scenarios[i].kind, facts: runs[i].facts(job), seconds: took[i]))
        }
        // Let go of the jobs (and the models, stores and open sidecar
        // databases they hold) before the sandboxes are removed.
        jobs.removeAll()
        centers.forEach { $0.clearFinished() }
        centers.removeAll()
        return (outcomes, wall, mainLagMax)
    }

    static func seconds(_ d: Duration) -> Double {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }
}

// MARK: - Fixtures

@MainActor
enum MFOVerbFixtures {

    /// A sandbox for one scenario: realpath'd temp folder, own catalog store,
    /// own ledger, own log folder (ShowAgainSandbox — the catalog-door suites'
    /// sandbox).
    static func sandbox(_ label: String) throws -> ShowAgainSandbox {
        try ShowAgainSandbox.make("mfopar_\(label)")
    }

    /// A real synthetic fixture in `dir` (RepairFixtures' media matrix).
    static func media(_ c: RepairFixtures.Container, in dir: URL, stem: String, seconds: Int = 2) throws -> URL {
        try RepairFixtures.make(c, in: dir, stem: stem, seconds: seconds)
    }

    /// A catalog row for a file on disk, appended to `model`.
    @discardableResult
    static func record(_ url: URL, in model: VideoScanModel, seconds: Double = 2) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = url.path
        r.filename = url.lastPathComponent
        r.directory = url.deletingLastPathComponent().path
        r.ext = url.pathExtension.lowercased()
        r.sizeBytes = RepairFixtures.size(url)
        r.durationSeconds = seconds
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        model.records.append(r)
        return r
    }

    // MARK: The scenarios

    /// Every verb the crowd runs. `copies` > 1 repeats the list (fresh
    /// sandboxes each) for the scaling sweep.
    static func all() -> [MFOVerbScenario] {
        [compare(), transcode(), trim(4), reformat(), cleanup(), balanceAudio(), rebuildAudio(4), verifyAudio(), verifyVideo(),
         checkMedia(), repair(), fillFullHashes(), fingerprintSound(4), checkCopies(), showAgain(), findSimilarFootage(),
         validateCatalog(), promote(), verifyArchive(), lockArchive(), deleteDuplicates()]
    }

    static func compare(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .compare) {
        let sb = try sandbox("compare")
        let a = try media(.mp4H264, in: sb.files, stem: "test_cmp_a", seconds: len)
        let b = sb.files.appendingPathComponent("test_cmp_b.mp4")
        try FileManager.default.copyItem(at: a, to: b)
        let ra = record(a, in: sb.model), rb = record(b, in: sb.model)
        return MFOVerbRun(start: { $0.startCompare(recordA: ra, recordB: rb) },
                          facts: { MFOVerbHarness.state($0, root: sb.root) },
                          cleanup: sb.cleanup)
    } }

    static func transcode(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .transcode) {
        let sb = try sandbox("transcode")
        let src = try media(.movProRes, in: sb.files, stem: "test_tc_src", seconds: len)
        let rec = record(src, in: sb.model, seconds: Double(len))
        let out = sb.files.appendingPathComponent("test_tc_src.vs.archive.mov")
        let before = MFOVerbHarness.sha256(src.path)
        return MFOVerbRun(
            start: { $0.startTranscode(record: rec, preset: .archival, outputURL: out, model: sb.model) },
            facts: { job in
                let t = job as? TranscodeJob
                return MFOVerbHarness.state(job, root: sb.root, encoded: true)
                    + " | published=\(MFOVerbHarness.exists(t?.publishedURL)) | source same=\(MFOVerbHarness.sha256(src.path) == before)"
            },
            cleanup: sb.cleanup)
    } }

    static func trim(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .trim) {
        let sb = try sandbox("trim")
        let src = try media(.mp4H264, in: sb.files, stem: "test_trim_src", seconds: max(len, 4))
        let rec = record(src, in: sb.model, seconds: Double(max(len, 4)))
        rec.videoCodec = "h264"
        let before = MFOVerbHarness.sha256(src.path)
        return MFOVerbRun(
            start: { $0.startTrim(record: rec, range: TrimRange(inSeconds: 1, outSeconds: Double(max(len, 4) - 1)), model: sb.model) },
            facts: { job in
                let t = job as? TrimJob
                return MFOVerbHarness.state(job, root: sb.root)
                    + " | published=\(MFOVerbHarness.exists(t?.publishedURL)) | source same=\(MFOVerbHarness.sha256(src.path) == before)"
            },
            cleanup: sb.cleanup)
    } }

    static func reformat(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .reformat) {
        let sb = try sandbox("reformat")
        let src = try media(.aviDV, in: sb.files, stem: "test_rf_src", seconds: len)
        let rec = record(src, in: sb.model, seconds: Double(len))
        let before = MFOVerbHarness.sha256(src.path)
        return MFOVerbRun(
            start: { $0.startReformat(record: rec, model: sb.model, orchestrator: nil) },
            facts: { job in
                let r = job as? ReformatJob
                return MFOVerbHarness.state(job, root: sb.root, encoded: true)
                    + " | published=\(MFOVerbHarness.exists(r?.publishedURL)) | source same=\(MFOVerbHarness.sha256(src.path) == before)"
            },
            cleanup: sb.cleanup)
    } }

    static func cleanup(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .cleanup) {
        let sb = try sandbox("cleanup")
        let path = try CleanupTestMedia.generate(into: sb.files, name: "test_cu_src.mp4", duration: Double(len), size: "720x480",
                                                 rate: "30000/1001", videoCodec: "libx264",
                                                 extraVideoArgs: ["-preset", "ultrafast", "-flags", "+ilme+ildct"],
                                                 audioCodec: "aac")
        // durationSeconds 0 → scratch is the system temp dir, never a RAM disk.
        let rec = makeCleanupSourceRecord(path: path, durationSeconds: 0, fieldOrder: "tt")
        sb.model.records.append(rec)
        let before = MFOVerbHarness.sha256(path)
        return MFOVerbRun(
            start: { $0.startCleanup(record: rec, recipe: CleanupRecipeRegistry.vhsQuickClean, model: sb.model) },
            facts: { job in
                let c = job as? CleanupJob
                return MFOVerbHarness.state(job, root: sb.root, encoded: true)
                    + " | published=\(MFOVerbHarness.exists(c?.publishedURL)) | source same=\(MFOVerbHarness.sha256(path) == before)"
            },
            cleanup: sb.cleanup)
    } }

    static func balanceAudio(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .balanceAudio) {
        let sb = try sandbox("balance")
        let path = try BalanceAudioTestMedia.generate(into: sb.files, channelCase: .leftOnly, wrapper: .movH264Pcm,
                                                      duration: Double(len))
        let analysis = try await AudioBalanceProbe.analyze(path: path)
        let rec = makeBalanceSourceRecord(path: path, durationSeconds: analysis.shape.durationSeconds,
                                          audioCodec: analysis.shape.audioCodec)
        sb.model.records.append(rec)
        let before = MFOVerbHarness.sha256(path)
        return MFOVerbRun(
            start: { $0.startBalanceAudio(record: rec, analysis: analysis, model: sb.model) },
            facts: { job in
                let b = job as? BalanceAudioJob
                return MFOVerbHarness.state(job, root: sb.root)
                    + " | published=\(MFOVerbHarness.exists(b?.publishedURL)) | source same=\(MFOVerbHarness.sha256(path) == before)"
            },
            cleanup: sb.cleanup)
    } }

    static func rebuildAudio(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .rebuildAudio) {
        let sb = try sandbox("rebuild")
        let path = try VerifyAudioTestMedia.generate(into: sb.files, name: "test_rb_src.mp4", videoCodec: "libx264",
                                                     extraVideoArgs: ["-preset", "ultrafast"], audioCodec: "aac",
                                                     videoDuration: Double(max(len, 4)))
        let d = try await VerifyAudioProbe.diagnose(path: path)
        let rec = makeBalanceSourceRecord(path: path, durationSeconds: d.shape.containerDurationSeconds,
                                          audioCodec: d.shape.audioCodec)
        sb.model.records.append(rec)
        let before = MFOVerbHarness.sha256(path)
        return MFOVerbRun(
            start: { $0.startRebuildAudio(record: rec, reason: "parallel test", shape: d.shape, model: sb.model) },
            facts: { job in
                let r = job as? RebuildAudioJob
                return MFOVerbHarness.state(job, root: sb.root)
                    + " | published=\(MFOVerbHarness.exists(r?.publishedURL)) | source same=\(MFOVerbHarness.sha256(path) == before)"
            },
            cleanup: sb.cleanup)
    } }

    static func verifyAudio(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .verifyAudio) {
        let sb = try sandbox("verifyaudio")
        let src = try media(.mkvFFV1, in: sb.files, stem: "test_va_src", seconds: len)
        let rec = record(src, in: sb.model, seconds: Double(len))
        return MFOVerbRun(
            start: { $0.startVerifyAudio(record: rec, model: sb.model) },
            facts: { MFOVerbHarness.state($0, root: sb.root) + " | status=\(rec.audioVerifyStatus)" },
            cleanup: sb.cleanup)
    } }

    static func verifyVideo(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .verifyVideo) {
        let sb = try sandbox("verifyvideo")
        let src = try media(.mxfMPEG2, in: sb.files, stem: "test_vv_src", seconds: len)
        let rec = record(src, in: sb.model, seconds: Double(len))
        return MFOVerbRun(
            start: { $0.startVerifyVideo(record: rec, model: sb.model) },
            facts: { MFOVerbHarness.state($0, root: sb.root) + " | status=\(rec.videoVerifyStatus)" },
            cleanup: sb.cleanup)
    } }

    static func checkMedia(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .checkMedia) {
        let sb = try sandbox("checkmedia")
        let src = try media(.aviDV, in: sb.files, stem: "test_cm_src", seconds: len)
        let rec = record(src, in: sb.model, seconds: Double(len))
        return MFOVerbRun(
            start: { $0.startCheckMedia(records: [rec], tier: .quick, model: sb.model) },
            facts: { MFOVerbHarness.state($0, root: sb.root) + " | card=\(rec.mediaReportCard.map { "\($0.verdict)" } ?? "none")" },
            cleanup: sb.cleanup)
    } }

    static func repair(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .repair) {
        let sb = try sandbox("repair")
        let src = try media(.mp4H264, in: sb.files, stem: "test_rp_src", seconds: len)
        let rec = record(src, in: sb.model, seconds: Double(len))
        rec.mediaReportCard = MediaRepairJobTests.layoutProblemCard(size: RepairFixtures.size(src))
        let out = RepairFixtures.repairedURL(for: src)
        let before = MFOVerbHarness.sha256(src.path)
        return MFOVerbRun(
            start: { $0.startRepair(record: rec, fixes: [.remux], output: out, besideOriginal: true, model: sb.model) },
            facts: { job in
                MFOVerbHarness.state(job, root: sb.root)
                    + " | copy=\(MFOVerbHarness.exists(out)) | source same=\(MFOVerbHarness.sha256(src.path) == before)"
            },
            cleanup: sb.cleanup)
    } }

    static func fillFullHashes(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .fillFullHashes) {
        let sb = try sandbox("fullhash")
        for i in 0..<3 { try sb.record("test_fh_\(i).mov", bytes: 40_000 * len + i, stage: .none) }
        return MFOVerbRun(
            start: { $0.startFullHashBackfill(model: sb.model, marker: nil) },
            facts: { job in
                let f = job as? FullHashBackfillJob
                return MFOVerbHarness.state(job, root: sb.root) + " | hashed=\(f?.totals[.hashed] ?? -1)"
            },
            cleanup: sb.cleanup)
    } }

    static func fingerprintSound(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .fingerprintSound) {
        let sb = try sandbox("fpsound")
        for (i, c) in [RepairFixtures.Container.mp4H264, .movProRes].enumerated() {
            let url = try media(c, in: sb.files, stem: "test_fs_\(i)", seconds: max(len, 4))
            let r = record(url, in: sb.model, seconds: Double(max(len, 4)))
            r.contentHash = "v1:" + r.filename
        }
        return MFOVerbRun(
            start: { $0.startAudioFingerprintBackfill(model: sb.model) },
            facts: { job in
                let f = job as? AudioFingerprintBackfillJob
                return MFOVerbHarness.state(job, root: sb.root) + " | fingerprinted=\(f?.totals[.fingerprinted] ?? -1)"
            },
            cleanup: sb.cleanup)
    } }

    static func checkCopies(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .checkCopies) {
        let sb = try sandbox("checkcopies")
        let keeper = try sb.record("test_cc_keeper.mov", bytes: 7_000, stage: .none)
        let copy = try sb.record("test_cc_keeper copy.mov", bytes: 7_000, stage: .none)
        // Same bytes (sb.record seeds content with the name's length).
        try Data(contentsOf: URL(fileURLWithPath: keeper.fullPath)).write(to: URL(fileURLWithPath: copy.fullPath))
        for r in [keeper, copy] {
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.durationSeconds = 61
            r.partialMD5 = "same-sampled-hash"
        }
        let ids: Set<UUID> = [keeper.id, copy.id]
        return MFOVerbRun(
            start: { $0.startCheckCopies(recordIDs: ids, model: sb.model) },
            facts: { job in
                MFOVerbHarness.state(job, root: sb.root)
                    + " | grouped=\(keeper.duplicateGroupID != nil && keeper.duplicateGroupID == copy.duplicateGroupID)"
            },
            cleanup: sb.cleanup)
    } }

    static func showAgain(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .showAgain) {
        let sb = try sandbox("showagain")
        let a = try sb.record("test_sa_a.mov", bytes: 500)
        try sb.record("test_sa_gone.mov", bytes: 10, onDisk: false)
        let reviewed = await sb.model.showAgainReview(disk: ShowAgainSandbox.onlineRealStat)
        return MFOVerbRun(
            start: { $0.startShowAgain(model: sb.model, reviewed: reviewed) },
            facts: { MFOVerbHarness.state($0, root: sb.root) + " | stage=\(a.archiveStage)" },
            cleanup: sb.cleanup)
    } }

    static func findSimilarFootage(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .findSimilarFootage) {
        let sb = try sandbox("similar")
        for (i, name) in ["test_sf_a.mov", "test_sf_b.mov", "test_sf_c.mov"].enumerated() {
            let r = FindSimilarFootageFixtures.rec(name, dir: sb.files.path, dur: 600 + Double(i) * 0.01,
                                                   hash: "v1:\(i)")
            sb.model.records.append(r)
        }
        return MFOVerbRun(
            start: { $0.startFindSimilarFootage(scope: .catalog, model: sb.model) },
            facts: { MFOVerbHarness.state($0, root: sb.root) },
            cleanup: sb.cleanup)
    } }

    static func validateCatalog(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .validateCatalog) {
        let scene = try ValidateScene.make("mfopar")
        return MFOVerbRun(
            start: { center in
                TestHostDrive.identifiedSync {
                    center.startValidateCatalog(model: scene.sandbox.model, marker: CatalogAuditRunMarker())
                }
            },
            facts: { MFOVerbHarness.state($0, root: scene.sandbox.root) },
            cleanup: scene.cleanup)
    } }

    /// A Master Archive sandbox with one real file (sound present) ready to
    /// promote; `promoted` runs the promotion during prepare.
    static func archiveSandbox(_ label: String, promoted: Bool, len: Int) async throws
        -> (MasterArchiveTestSupport.Sandbox, VideoScanModel, VideoRecord) {
        let sb = try MasterArchiveTestSupport.makeSandbox("mfopar_\(label)")
        let src = try media(.movProRes, in: sb.sources, stem: "test_ar_\(label)", seconds: len)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path, userDate: "1992-07-15", starRating: 1)
        rec.durationSeconds = Double(len)
        model.records.append(rec)
        if promoted {
            let job = await MasterArchiveTestSupport.promote(model, ids: [rec.id])
            guard case .finished? = job?.state else {
                throw CocoaError(.fileWriteUnknown, userInfo: [NSLocalizedDescriptionKey: "setup promote: \(String(describing: job?.state))"])
            }
        }
        return (sb, model, rec)
    }

    static func promote(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .promote) {
        let (sb, model, rec) = try await archiveSandbox("promote", promoted: false, len: len)
        let plan = try #require(model.buildPromotePlan(recordIDs: [rec.id]))
        return MFOVerbRun(
            start: { $0.startPromote(plan: plan, model: model) },
            facts: { job in
                MFOVerbHarness.state(job, root: sb.root)
                    + " | archived files=\(MasterArchiveTestSupport.archivedFiles(sb).count)"
                    + " | manifest rows=\(MasterArchiveTestSupport.manifestRows(sb).count)"
            },
            cleanup: sb.cleanup)
    } }

    static func verifyArchive(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .verifyArchive) {
        let (sb, model, _) = try await archiveSandbox("verify", promoted: true, len: len)
        return MFOVerbRun(
            start: { $0.startVerifyArchiveCopies(model: model) },
            facts: { MFOVerbHarness.state($0, root: sb.root) },
            cleanup: sb.cleanup)
    } }

    static func lockArchive(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .lockArchive) {
        let (sb, model, _) = try await archiveSandbox("lock", promoted: true, len: len)
        return MFOVerbRun(
            start: { $0.startArchiveLockCatchUp(model: model) },
            facts: { MFOVerbHarness.state($0, root: sb.root) },
            cleanup: sb.cleanup)
    } }

    static func deleteDuplicates(_ len: Int = 2) -> MFOVerbScenario { MFOVerbScenario(kind: .deleteDuplicates) {
        let sb = try sandbox("deldup")
        let source = try media(.mkvFFV1, in: sb.files, stem: "test_dd_master", seconds: len)
        let digest = MFOVerbHarness.sha256(source.path)
        // A per-scenario name: every scenario trashes into the one test-host
        // Trash, so the name is the sandbox's.
        let extraURL = sb.files.appendingPathComponent("test_dd_extra_\(sb.root.lastPathComponent).mkv")
        try FileManager.default.copyItem(at: source, to: extraURL)
        let group = UUID()
        let keeper = record(source, in: sb.model)
        keeper.partialMD5 = "m"
        keeper.duplicateGroupID = group; keeper.duplicateDisposition = .keep; keeper.duplicateConfidence = .high
        let extra = record(extraURL, in: sb.model)
        extra.partialMD5 = "m"
        extra.duplicateGroupID = group; extra.duplicateDisposition = .extraCopy; extra.duplicateConfidence = .high
        _ = addVerifiedArchiveFamily(to: sb.model, keeper: keeper)
        let planRoot = sb.root.appendingPathComponent("plans", isDirectory: true)
        return MFOVerbRun(
            start: { $0.startDeleteDuplicates(onVolume: sb.files.path, model: sb.model, planRoot: planRoot) },
            facts: { job in
                let trashed = extra.removal?.trashPath
                defer { if let trashed { try? FileManager.default.removeItem(atPath: trashed) } }
                return MFOVerbHarness.state(job, root: sb.root)
                    + " | extra=\(extra.removal.map { "\($0.state)" } ?? "live")"
                    + " | trash bytes same=\(trashed.map { MFOVerbHarness.sha256($0) == digest } ?? false)"
                    + " | keeper same=\(MFOVerbHarness.sha256(source.path) == digest)"
            },
            cleanup: sb.cleanup)
    } }
}

/// FindSimilarFootageJobTests' record factory, reachable from here.
@MainActor
enum FindSimilarFootageFixtures {
    static func rec(_ name: String, dir: String, dur: Double, hash: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = dir + "/" + name
        r.directory = dir
        r.durationSeconds = dur
        r.frameRate = "29.97"
        r.sizeBytes = 1000
        r.contentHash = hash
        r.videoCodec = "h264"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }
}

// MARK: - The crowd

@Suite("MFO verbs — every verb at once through one Center, same outcome as alone", .scratchCleanup)
@MainActor
struct MFOVerbsParallelTests {

    @Test("every runnable verb, alone then all at once: each concurrent outcome equals its alone outcome; concurrent beats serial",
          .timeLimit(.minutes(10)))
    func everyVerbConcurrentlyMatchesAlone() async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let scenarios = MFOVerbFixtures.all()

        // WARM-UP (unmeasured): the process's first jobs pay one-time costs
        // (VideoToolbox sessions, framework loading) that would land on ALONE.
        _ = try await MFOVerbHarness.run(scenarios)
        // ALONE: one at a time, one Center, fresh sandboxes.
        let alone = try await MFOVerbHarness.run(scenarios, limit: 1)
        // CROWD: every verb at once, one Center, fresh sandboxes.
        let crowd = try await MFOVerbHarness.run(scenarios)

        for (a, c) in zip(alone.outcomes, crowd.outcomes) {
            #expect(!a.facts.hasPrefix("failed") && !a.facts.hasPrefix("refused") && a.facts != "not started",
                    "\(a.kind) alone did not succeed: \(a.facts)")
            #expect(c.facts == a.facts, "\(c.kind): in the crowd «\(c.facts)» ≠ alone «\(a.facts)»")
        }
        let serial = alone.outcomes.reduce(0) { $0 + $1.seconds }
        let line = String(format: "MFO parallel: %d verbs — serial %.1f s (sum of alone runs, wall %.1f s), concurrent wall %.1f s, speedup %.1f×; main-actor lag max %.0f ms alone, %.0f ms in the crowd",
                          scenarios.count, serial, alone.wall, crowd.wall, alone.wall / max(crowd.wall, 0.001),
                          alone.mainLagMax * 1000, crowd.mainLagMax * 1000)
        print(line)
        for (a, c) in zip(alone.outcomes, crowd.outcomes) {
            let name = a.kind.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0)
            print("MFO parallel:   \(name) alone " + String(format: "%5.2f s · in the crowd %5.2f s · ", a.seconds, c.seconds) + a.facts)
        }
        #expect(crowd.wall < alone.wall, "\(line)")
    }

    @Test("SENSOR: every verb the crowd does not run is excluded with a reason; the crowd and the exclusions cover every engine-backed kind")
    func theCrowdCoversEveryVerb() {
        let crowd = Set(MFOVerbFixtures.all().map(\.kind.rawValue))
        let all = Set(MediaFileOperationKind.all.map(\.rawValue))
        let noEngine = Set(MFOParallelInventory.verdicts.compactMap { k, v in
            if case .noEngine = v { return k } else { return nil } })
        let excluded = Set(MFOParallelInventory.notInTheCrowd.keys)
        #expect(crowd.isDisjoint(with: excluded), "a verb is both run and excluded: \(crowd.intersection(excluded))")
        #expect(crowd.union(excluded).union(noEngine) == all,
                "unaccounted: \(all.subtracting(crowd.union(excluded).union(noEngine)).sorted())")
    }
}

// MARK: - Sensor: the inventory covers every kind

@Suite("MFO verbs — parallelism inventory sensor", .scratchCleanup)
struct MFOVerbsParallelInventorySensorTests {

    @Test("SENSOR: every MediaFileOperationKind has a parallelism verdict, and no verdict names a kind that is gone")
    func everyKindHasAVerdict() {
        let kinds = Set(MediaFileOperationKind.all.map(\.rawValue))
        let judged = Set(MFOParallelInventory.verdicts.keys)
        #expect(kinds.subtracting(judged).isEmpty, "no verdict yet: \(kinds.subtracting(judged).sorted())")
        #expect(judged.subtracting(kinds).isEmpty, "verdict for a kind that is gone: \(judged.subtracting(kinds).sorted())")
        #expect(Set(MFOParallelInventory.notInTheCrowd.keys).isSubset(of: kinds))
    }

    @Test("SENSOR: the Center serializes nothing but the per-volume gate and per-kind duplicate guards — no global job semaphore")
    func theCenterHasNoGlobalQueue() throws {
        let center = SourceTree.strippingComments(try SourceTree.appSource(named: "MediaFileOperations.swift"))
        // The one admission semaphore is the per-volume gate, created in gatePlan.
        #expect(center.components(separatedBy: "AsyncSemaphore(limit:").count == 2,
                "a second semaphore in the Center would serialize jobs beyond the per-volume gate")
        #expect(!center.contains("maxConcurrentJobs") && !center.contains("jobQueue"))
    }
}
