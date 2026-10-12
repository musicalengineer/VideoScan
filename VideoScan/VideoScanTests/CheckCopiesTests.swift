// CheckCopiesTests.swift
// "Check these copies first" — the engine half (Rick 2026-10-11):
//   LOGIC   — after the job, a twin with the same bytes is grouped by the
//             catalog's own analysis (keeper + extra copy); a twin whose
//             sampled hash matches but whose bytes differ carries a different
//             full digest. (The delete-review classifier half of this test
//             lives with the footer review sheet, not on this branch.)
//   SCALE   — planning over 100k records inside a budget.
//   SENSOR  — the job never moves, renames or rewrites a file (source scan +
//             fingerprints); an offline twin is skipped, counted, and never
//             elected keeper.
//   MEDIA   — the hash runs over synthetic test_* fixtures: mp4/h264,
//             mov/prores, mkv/ffv1+pcm, mxf, avi/dv — every digest equals an
//             independent SHA-256 of the file.

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private func sha256(_ path: String) -> String {
    SHA256.hash(data: (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data())
        .map { String(format: "%02x", $0) }.joined()
}

/// A twin-ready record: stream type, length and head+tail hash so the
/// catalog's duplicate analysis scores the pair (hash 8 + duration 3 + name 3).
@MainActor
private func twinReady(_ r: VideoRecord, md5: String, stars: Int = 0) {
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.durationSeconds = 61
    r.partialMD5 = md5
    r.starRating = stars
    if stars == 0 { r.userNotes = "" }
}

@MainActor
private func runJob(_ model: VideoScanModel, _ ids: Set<UUID>,
                    online: @escaping @Sendable (String) -> Bool = { _ in true }) async -> CheckCopiesSummary {
    let job = CheckCopiesJob(recordIDs: ids, model: model)
    job.volumeOnline = online
    job.start()
    return await job.result()
}

// MARK: - Logic

@Suite("Check copies — fresh hashes promote proven copies", .serialized)
@MainActor
struct CheckCopiesLogicTests {

    @Test("same bytes → grouped keeper + extra copy; same sampled hash, other bytes → different full digest")
    func promotesOnlyProvenCopies() async throws {
        let sb = try ShowAgainSandbox.make("checkcopies"); defer { sb.cleanup() }
        let model = sb.model
        // Pair 1: identical bytes.
        let keeper = try sb.record("Thanksgiving2009.mov", bytes: 7_000, stage: .none)
        let copy = try sb.record("Thanksgiving2009 copy.mov", bytes: 7_000)
        try Data(contentsOf: URL(fileURLWithPath: keeper.fullPath)).write(to: URL(fileURLWithPath: copy.fullPath))
        twinReady(keeper, md5: "m1", stars: 3); twinReady(copy, md5: "m1")
        // Pair 2: same size + head/tail hash, different bytes.
        let other = try sb.record("Clip03.dv", bytes: 7_000, stage: .none)
        let lookalike = try sb.record("Clip03 copy.dv", bytes: 7_000)
        try Data(repeating: 0x5A, count: 7_000).write(to: URL(fileURLWithPath: lookalike.fullPath))
        twinReady(other, md5: "m2", stars: 3); twinReady(lookalike, md5: "m2")

        let summary = await runJob(model, [copy.id, lookalike.id])
        #expect(summary.seeds == 2 && summary.twins == 2)
        #expect(summary.hashed == 4, Comment(rawValue: summary.line))
        #expect(summary.regrouped >= 4, Comment(rawValue: summary.line))
        #expect(keeper.duplicateDisposition == .keep && copy.duplicateDisposition == .extraCopy,
                "the catalog's own analysis groups the pair")

        #expect(keeper.contentFixity?.digest == copy.contentFixity?.digest, "same bytes, same full digest")
        #expect(other.contentFixity?.digest != nil && other.contentFixity?.digest != lookalike.contentFixity?.digest,
                "a sampled-hash lookalike is told apart by its full digest")
    }

    @Test("a record that already has a valid full hash is not read again; an archived one is left alone")
    func planSkipsHashedAndArchived() throws {
        let sb = try ShowAgainSandbox.make("checkcopies_plan"); defer { sb.cleanup() }
        let hashed = try sb.record("a.mov", bytes: 100)
        hashed.contentFixity = ContentFixity.captured(path: hashed.fullPath, digest: sha256(hashed.fullPath), byteCount: 100)
        let archived = try sb.record("b.mov", bytes: 100)
        archived.archiveFixity = ArchiveFixity(digest: "ab", verifiedAt: Date(), sizeBytes: 100)
        let plain = try sb.record("c.mov", bytes: 100)
        for r in [hashed, archived, plain] { r.partialMD5 = "same" }
        let usable = hashed.contentFixity?.isUsableForVerification == true
        let plan = CheckCopiesPlanner.plan(seeds: [plain.id], records: sb.model.records, isReadOnly: { _ in false })
        #expect(plan.seedCount == 1 && plan.twinCount == 2)
        #expect(plan.archivedLeftAlone == 1)
        #expect(plan.alreadyHashed == (usable ? 1 : 0))
        #expect(plan.toHash.map(\.id).contains(plain.id))
        #expect(!plan.toHash.map(\.id).contains(archived.id))
    }
}

// MARK: - Scale

@Suite("Check copies — scale (100k records)", .serialized)
@MainActor
struct CheckCopiesScaleTests {

    /// 100k records, 10k seeds, each with one sampled-hash twin.
    /// Budget (Debug, M4 Max, headroom ×3+): planning < 1 s.
    @Test func planningAt100k() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            r.fullPath = "/Volumes/Scale/\(i / 1000)/clip_\(i).mov"
            r.filename = "clip_\(i).mov"
            r.sizeBytes = Int64(10_000 + i / 2)
            r.contentHash = "v1:\(i / 2)"
            records.append(r)
        }
        let seeds = Set(stride(from: 0, to: 100_000, by: 10).map { records[$0].id })
        let t0 = Date()
        let plan = CheckCopiesPlanner.plan(seeds: seeds, records: records, isReadOnly: { _ in false })
        let elapsed = -t0.timeIntervalSinceNow
        #expect(plan.seedCount == 10_000 && plan.twinCount == 10_000)
        #expect(plan.toHash.count == 20_000)
        #expect(elapsed < 1, "planning took \(elapsed) s")
    }
}

// MARK: - Sensor

@Suite("Check copies — sensor: read only; offline is never the keeper", .serialized)
@MainActor
struct CheckCopiesSensorTests {

    static let forbidden = [
        "trashItem", "removeItem", "moveItem", "copyItem", "replaceItem", "linkItem",
        "unlink(", "rename(", "renamex", "renameat", "chflags", "truncate(", "ftruncate",
        "FileHandle(forWriting", "FileHandle(forUpdating", "O_WRONLY", "O_RDWR", "setAttributes",
        "startReviewedDeleteDuplicates", "DeleteDuplicatesJob(", ".write(to:",
    ]

    @Test("no file-moving, -removing or -writing call in the job's source")
    func sourceIsReadOnly() throws {
        let code = try SourceTree.appSource(named: "CheckCopies.swift").split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
        for call in Self.forbidden { #expect(!code.contains(call), "CheckCopies.swift calls \(call)") }
    }

    @Test("every file is still at its path with the same bytes, inode and mtime after the run")
    func filesUntouched() async throws {
        let sb = try ShowAgainSandbox.make("checkcopies_ro"); defer { sb.cleanup() }
        let a = try sb.record("x.mov", bytes: 5_000)
        let b = try sb.record("x copy.mov", bytes: 5_000, stage: .none)
        try Data(contentsOf: URL(fileURLWithPath: a.fullPath)).write(to: URL(fileURLWithPath: b.fullPath))
        twinReady(a, md5: "m"); twinReady(b, md5: "m", stars: 2)
        let before = try [a, b].map { try MediaFingerprint.of($0.fullPath) }
        let summary = await runJob(sb.model, [a.id])
        let after = try [a, b].map { try MediaFingerprint.of($0.fullPath) }
        #expect(before == after)
        #expect(summary.hashed == 2, Comment(rawValue: summary.line))
        let trash = sb.root.appendingPathComponent("Trash")
        #expect(!FileManager.default.fileExists(atPath: trash.path))
    }

    @Test("a twin whose drive is not connected is skipped, counted, and never elected keeper")
    func offlineTwinNeverKeeper() async throws {
        let sb = try ShowAgainSandbox.make("checkcopies_off"); defer { sb.cleanup() }
        let model = sb.model
        let offlineRoot = "/Volumes/CheckCopiesOffline_\(UUID().uuidString.prefix(8))"
        let local = try sb.record("Brockton.mov", bytes: 6_000)
        let away = VideoRecord()
        away.fullPath = offlineRoot + "/Brockton.mov"; away.filename = "Brockton.mov"; away.sizeBytes = 6_000
        away.directory = offlineRoot
        twinReady(local, md5: "m"); twinReady(away, md5: "m", stars: 5)   // the away copy would win on stars
        model.records.append(away)
        let target = CatalogScanTarget(searchPath: offlineRoot)
        target.isReachable = false
        model.scanTargets = [target]
        model.duplicateKeeperSettings.volumePrecedence = [(offlineRoot as NSString).lastPathComponent]

        let summary = await runJob(model, [local.id], online: { !$0.hasPrefix(offlineRoot) })
        #expect(summary.driveNotConnected == 1, Comment(rawValue: summary.line))
        #expect(summary.hashed == 1)
        #expect(away.contentFixity == nil, "nothing is written for a file that was not read")
        #expect(away.duplicateDisposition != .keep, "an offline copy is never the keeper")
        #expect(local.duplicateDisposition == .keep, "the connected copy is elected")
    }
}

// MARK: - Media matrix

@Suite("Check copies — media matrix", .serialized)
@MainActor
struct CheckCopiesMediaMatrixTests {

    private static let fixtures: [(name: String, args: [String])] = {
        let v = ["-f", "lavfi", "-i", "testsrc=duration=2:size=160x120:rate=25"]
        let a = ["-f", "lavfi", "-i", "sine=frequency=440:duration=2:sample_rate=48000"]
        return [
            ("test_cc_h264.mp4", v + a + ["-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac"]),
            ("test_cc_prores.mov", v + a + ["-c:v", "prores_ks", "-c:a", "pcm_s16le"]),
            ("test_cc_ffv1.mkv", v + a + ["-c:v", "ffv1", "-c:a", "pcm_s16le"]),
            ("test_cc_mpeg2.mxf", ["-f", "lavfi", "-i", "testsrc=duration=2:size=720x576:rate=25"] + a
                + ["-c:v", "mpeg2video", "-c:a", "pcm_s16le", "-ar", "48000"]),
            ("test_cc_dv.avi", ["-f", "lavfi", "-i", "testsrc=duration=2:size=720x480:rate=30000/1001"] + a
                + ["-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le"]),
        ]
    }()

    @Test("each container's file and its copy are hashed in full; digests match an independent SHA-256",
          .timeLimit(.minutes(3)))
    func hashesEveryContainer() async throws {
        try #require(CleanupTestMedia.toolsAvailable)
        let dir = try CleanupTestMedia.makeScratchDir("checkcopies_mm")
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = VideoScanModel(logDirectory: dir.appendingPathComponent("logs", isDirectory: true))
        model.catalogStore = CatalogStore(directory: dir.appendingPathComponent("catalog", isDirectory: true))
        var seeds: Set<UUID> = []
        for f in Self.fixtures {
            let path = dir.appendingPathComponent(f.name).path
            try CleanupTestMedia.runFFmpeg(f.args, output: path)
            let copyPath = dir.appendingPathComponent("copy_" + f.name).path
            try FileManager.default.copyItem(atPath: path, toPath: copyPath)
            for p in [path, copyPath] {
                let r = VideoRecord()
                r.fullPath = p; r.filename = (p as NSString).lastPathComponent; r.directory = dir.path
                r.sizeBytes = (try FileManager.default.attributesOfItem(atPath: p)[.size] as? NSNumber)?.int64Value ?? 0
                twinReady(r, md5: "pm-\(f.name)")
                model.records.append(r)
                if p == path { seeds.insert(r.id) }
            }
        }
        let before = try model.records.map { try MediaFingerprint.of($0.fullPath) }
        let summary = await runJob(model, seeds)
        #expect(summary.planned == 10 && summary.hashed == 10, Comment(rawValue: summary.line))
        for r in model.records {
            #expect(r.contentFixity?.digest == sha256(r.fullPath), "\(r.filename)")
        }
        #expect(try model.records.map { try MediaFingerprint.of($0.fullPath) } == before, "no file changed")
    }
}
