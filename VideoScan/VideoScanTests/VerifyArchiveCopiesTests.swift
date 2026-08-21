// VerifyArchiveCopiesTests.swift
// Verify Archive Copies (GH #167) — the five-dimension checklist:
//
//   LOGIC     — the recovery replay (stripped fixity restored from the
//               manifest), refresh on an already-verified copy, missing
//               file, orphan (manifest-only), unmanifested (catalog-only),
//               read-only refusal, summary wording.
//   MEDIA     — mxf + avi/dv synthetic ffmpeg fixtures promoted then
//               verified (hashing is byte-level; two containers pin that
//               nothing container-specific leaks into the path).
//   SCALE     — a 10k-row manifest parses inside an explicit budget.
//   ISOLATION — poisoned shared designation not inherited; UserDefaults
//               VALUES and the real App Support tree byte-for-byte
//               unchanged by a full verify run (GH #167 caution: this
//               machine's real archive was the clobber victim — every
//               test here is provably sandboxed under the temp dir).
//   SENSOR    — verify twice: the second run restores nothing, appends
//               nothing to the manifest, invents no records — the
//               read-only-on-media contract pinned at suite scale.
//
// The mismatch case is the heart: corrupt one byte → MUST flag, MUST NOT
// restore fixity — the outcome this tool exists to surface.

import Foundation
import Testing
@testable import VideoScan

// MARK: - Shared helpers

@MainActor
private enum VerifyTestSupport {

    /// Run one verify job to completion (no gates — sandbox volumes).
    static func run(_ model: VideoScanModel) async -> VerifyArchiveCopiesJob {
        let job = VerifyArchiveCopiesJob(model: model)
        job.start()
        await job.task?.value
        return job
    }

    /// Sandbox + model + initialized archive + `count` promoted blobs.
    /// Returns (sandbox, model, sources, their archive-copy records).
    static func promotedSandbox(_ label: String, count: Int, bytes: Int = 64 * 1024) async throws
        -> (sb: MasterArchiveTestSupport.Sandbox, model: VideoScanModel,
            sources: [VideoRecord], copies: [VideoRecord]) {
        let sb = try MasterArchiveTestSupport.makeSandbox(label)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        var sources: [VideoRecord] = []
        for i in 0..<count {
            let url = try MasterArchiveTestSupport.writeBlob(
                at: sb.sources.appendingPathComponent("test_vac_\(i).mov"),
                bytes: bytes + i, seed: UInt64(i + 41))
            sources.append(MasterArchiveTestSupport.makeRecord(path: url.path))
        }
        model.records = sources
        _ = try #require(await MasterArchiveTestSupport.promote(model, ids: sources.map(\.id)))
        let copies = try sources.map { try #require(model.masterArchiveCopy(of: $0)) }
        return (sb, model, sources, copies)
    }

    static func outcome(_ job: VerifyArchiveCopiesJob, named name: String)
        -> VerifyArchiveCopiesJob.FileOutcome? {
        job.outcomes.first { $0.name == name || $0.name.hasSuffix("/" + name) }
    }
}

// MARK: - Logic

@Suite("Verify Archive Copies — logic", .serialized)
@MainActor
struct VerifyArchiveCopiesLogicTests {

    @Test("GH #167 replay: stripped archiveFixity is restored from the manifest after an end-to-end re-read")
    func strippedFixityRestored() async throws {
        let (sb, model, _, copies) = try await VerifyTestSupport.promotedSandbox("restore", count: 2)
        defer { sb.cleanup() }
        let expectedDigests = copies.map { $0.archiveFixity?.digest }
        for copy in copies { copy.archiveFixity = nil }   // the clobber

        let job = await VerifyTestSupport.run(model)
        guard case .finished(let summary) = job.state else {
            Issue.record("verify did not finish: \(job.state)"); return
        }
        #expect(job.tally.restored == 2)
        #expect(job.tally.mismatch == 0 && job.tally.missing == 0 && job.tally.orphan == 0)
        #expect(summary.contains("fixity restored on 2"))
        for (copy, expected) in zip(copies, expectedDigests) {
            let fixity = try #require(copy.archiveFixity)
            #expect(fixity.digest == expected, "restored digest is the manifest's")
            #expect(fixity.algorithm == "sha256")
            #expect(fixity.sizeBytes == copy.sizeBytes)
        }
        #expect(job.outcomes.filter { $0.kind == .restored }.count == 2)
    }

    @Test("MISMATCH: one corrupted byte → flagged loudly, fixity NOT restored, job row goes red; intact sibling still restored")
    func mismatchIsFlaggedAndNeverRestored() async throws {
        let (sb, model, _, copies) = try await VerifyTestSupport.promotedSandbox("mismatch", count: 2)
        defer { sb.cleanup() }
        for copy in copies { copy.archiveFixity = nil }

        // Corrupt ONE byte of the first archived file, size unchanged.
        let victim = copies[0]
        let victimURL = URL(fileURLWithPath: victim.fullPath)
        var bytes = try Data(contentsOf: victimURL)
        bytes[100] ^= 0xFF
        try bytes.write(to: victimURL)

        let job = await VerifyTestSupport.run(model)
        guard case .failed(let message) = job.state else {
            Issue.record("a mismatch run must finish RED (.failed), got \(job.state)"); return
        }
        #expect(message.contains("MISMATCH"))
        #expect(job.tally.mismatch == 1)
        #expect(victim.archiveFixity == nil, "fixity must NEVER be restored over a mismatch")
        // Partial results honored: the intact file was still restored.
        #expect(job.tally.restored == 1)
        #expect(copies[1].archiveFixity != nil)
        let outcome = try #require(job.outcomes.first { $0.kind == .mismatch })
        #expect(outcome.detail.contains("POSSIBLE CORRUPTION"))
    }

    @Test("MISSING: archived file deleted → flagged, fixity untouched, run completes")
    func missingFileFlagged() async throws {
        let (sb, model, _, copies) = try await VerifyTestSupport.promotedSandbox("missing", count: 2)
        defer { sb.cleanup() }
        for copy in copies { copy.archiveFixity = nil }
        try FileManager.default.removeItem(atPath: copies[0].fullPath)

        let job = await VerifyTestSupport.run(model)
        guard case .finished = job.state else {
            Issue.record("verify did not finish: \(job.state)"); return
        }
        #expect(job.tally.missing == 1)
        #expect(job.tally.restored == 1)
        #expect(copies[0].archiveFixity == nil)
        #expect(copies[1].archiveFixity != nil)
    }

    @Test("ORPHAN: manifest row with no catalog record → reported only; no record is invented")
    func orphanReportedOnly() async throws {
        let (sb, model, sources, copies) = try await VerifyTestSupport.promotedSandbox("orphan", count: 1)
        defer { sb.cleanup() }
        // Drop the copy record from the catalog — the manifest row and
        // the on-disk file remain (the clobber-class shape).
        let orphanRel = VerifyArchiveCopiesJob.relPath(of: copies[0].fullPath,
                                                       underRoot: sb.archiveRoot.path)
        model.records = sources
        let recordCountBefore = model.records.count

        let job = await VerifyTestSupport.run(model)
        guard case .finished = job.state else {
            Issue.record("verify did not finish: \(job.state)"); return
        }
        #expect(job.tally.orphan == 1)
        #expect(model.records.count == recordCountBefore, "no catalog record invented")
        let outcome = try #require(job.outcomes.first { $0.kind == .orphan })
        #expect(outcome.name == orphanRel)
    }

    @Test("UNMANIFESTED: catalog archive copy with no manifest row → re-hashed and reported; no manifest row invented, no fixity blessed without a reference")
    func unmanifestedReportedWithoutInventingRows() async throws {
        let (sb, model, _, _) = try await VerifyTestSupport.promotedSandbox("unmani", count: 1)
        defer { sb.cleanup() }
        // Hand-place a file inside the archive tree and catalog it as an
        // archive copy — bypassing Promote, so no manifest row exists
        // (the rescan-cataloged shape the '· N unverified' count shows).
        let strayDir = sb.archiveRoot.appendingPathComponent("30_Video/Undated", isDirectory: true)
        try FileManager.default.createDirectory(at: strayDir, withIntermediateDirectories: true)
        let stray = try MasterArchiveTestSupport.writeBlob(
            at: strayDir.appendingPathComponent("xxxx-xx-xx_test_stray.mov"),
            bytes: 32 * 1024, seed: 999)
        let strayRec = MasterArchiveTestSupport.makeRecord(path: stray.path)
        strayRec.derivationKind = ArchivePromotion.derivationKind
        model.records.append(strayRec)
        let manifestRowsBefore = MasterArchiveTestSupport.manifestRows(sb).count

        let job = await VerifyTestSupport.run(model)
        guard case .finished = job.state else {
            Issue.record("verify did not finish: \(job.state)"); return
        }
        #expect(job.tally.unmanifested == 1)
        #expect(strayRec.archiveFixity == nil,
                "a hash with no independent reference is not ground truth — nothing written")
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == manifestRowsBefore,
                "verify never appends manifest rows")
        let outcome = try #require(job.outcomes.first { $0.kind == .unmanifested })
        #expect(outcome.detail.contains("no manifest row"))
    }

    @Test("audit path: an already-verified copy re-verifies (verifiedAt refreshed, digest unchanged)")
    func alreadyVerifiedRefreshes() async throws {
        let (sb, model, _, copies) = try await VerifyTestSupport.promotedSandbox("refresh", count: 1)
        defer { sb.cleanup() }
        let before = try #require(copies[0].archiveFixity)
        let runStart = Date()

        let job = await VerifyTestSupport.run(model)
        guard case .finished = job.state else {
            Issue.record("verify did not finish: \(job.state)"); return
        }
        #expect(job.tally.verified == 1 && job.tally.restored == 0)
        let after = try #require(copies[0].archiveFixity)
        #expect(after.digest == before.digest)
        #expect(after.verifiedAt >= runStart, "audit refreshes the verification stamp")
    }

    @Test("read-only viewer: refused before any I/O, nothing written")
    func readOnlyRefused() async throws {
        let (sb, model, _, copies) = try await VerifyTestSupport.promotedSandbox("readonly", count: 1)
        defer { sb.cleanup() }
        copies[0].archiveFixity = nil
        model.isReadOnly = true

        let job = await VerifyTestSupport.run(model)
        guard case .failed(let message) = job.state else {
            Issue.record("read-only must refuse, got \(job.state)"); return
        }
        #expect(message.contains("read-only"))
        #expect(copies[0].archiveFixity == nil)
        #expect(job.outcomes.isEmpty)
    }

    @Test("summary wording pins the loud mismatch clause and the restored count")
    func summaryWording() {
        var t = VerifyArchiveCopiesJob.Tally()
        t.verified = 3; t.restored = 2; t.mismatch = 1; t.missing = 1
        t.orphan = 2; t.unmanifested = 1
        let line = VerifyArchiveCopiesJob.summaryLine(t)
        #expect(line.hasPrefix("1 MISMATCH — possible corruption"))
        #expect(line.contains("5 verified"))
        #expect(line.contains("fixity restored on 2"))
        #expect(line.contains("2 in manifest only"))
    }
}

// MARK: - Media matrix (byte-level hashing across containers)

struct VerifyMatrixCase: Sendable, CustomStringConvertible {
    let label: String
    let filename: String
    let videoCodec: String
    let audioCodec: String?
    let size: String
    let extraVideoArgs: [String]
    var description: String { label }
}

private let verifyMatrix: [VerifyMatrixCase] = [
    VerifyMatrixCase(label: "mxf", filename: "test_vac_x264.mxf", videoCodec: "libx264",
                     audioCodec: "pcm_s16le", size: "720x576", extraVideoArgs: []),
    VerifyMatrixCase(label: "avi/dv", filename: "test_vac_dv.avi", videoCodec: "dvvideo",
                     audioCodec: "pcm_s16le", size: "720x576", extraVideoArgs: ["-pix_fmt", "yuv420p"]),
]

@Suite("Verify Archive Copies — media matrix", .serialized)
@MainActor
struct VerifyArchiveCopiesMediaMatrixTests {

    @Test("promote a real container, strip fixity, verify restores it",
          .timeLimit(.minutes(2)),
          arguments: verifyMatrix)
    func verifyAcrossContainers(testCase: VerifyMatrixCase) async throws {
        try #require(CleanupTestMedia.toolsAvailable, "ffmpeg/ffprobe are required project dependencies")
        let sb = try MasterArchiveTestSupport.makeSandbox("vmx")
        defer { sb.cleanup() }
        let src = try CleanupTestMedia.generate(into: sb.sources, name: testCase.filename,
                                                duration: 1.0, size: testCase.size, rate: "25",
                                                videoCodec: testCase.videoCodec,
                                                extraVideoArgs: testCase.extraVideoArgs,
                                                audioCodec: testCase.audioCodec)
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let rec = MasterArchiveTestSupport.makeRecord(path: src)
        model.records = [rec]
        _ = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        let copy = try #require(model.masterArchiveCopy(of: rec))
        let expected = try #require(copy.archiveFixity?.digest)
        copy.archiveFixity = nil

        let job = await VerifyTestSupport.run(model)
        guard case .finished = job.state else {
            Issue.record("verify did not finish: \(job.state)"); return
        }
        #expect(job.tally.restored == 1 && job.tally.mismatch == 0)
        #expect(copy.archiveFixity?.digest == expected)
    }
}

// MARK: - Scale

@Suite("Verify Archive Copies — scale")
struct VerifyArchiveCopiesScaleTests {

    @Test("a 10k-row manifest parses into the three-way index under budget", .timeLimit(.minutes(1)))
    func tenThousandRowManifestParsesUnderBudget() throws {
        var text = MasterArchiveLayout.manifestHeader + "\n"
        text.reserveCapacity(10_000 * 200)
        for i in 0..<10_000 {
            let row = ArchiveManifestCSV.Row(
                promotedAt: Date(timeIntervalSince1970: Double(i)),
                archiveRelPath: "30_Video/1990-1999/199\(i % 10)/199\(i % 10)-xx-xx_Clip_\(i).mov",
                sha256: String(format: "%064x", i),
                sizeBytes: Int64(i) * 1_000,
                originalPath: "/Volumes/Test, with commas/\"quoted\"/clip \(i).mov",
                originalVolume: "TestVol",
                recordID: UUID(),
                sourceRecordID: UUID(),
                recordDate: "199\(i % 10)-xx-xx",
                dateConfidence: "user-known",
                people: ["Donna", "Rick"],
                starRating: 3,
                readiness: "playable")
            text += ArchiveManifestCSV.line(for: row)
        }
        let clock = ContinuousClock()
        var index: VerifyArchiveManifestIndex?
        let elapsed = clock.measure {
            index = VerifyArchiveManifestIndex.parse(text: text)
        }
        let parsed = try #require(index)
        #expect(parsed.rowCount == 10_000)
        #expect(parsed.byRecordID.count == 10_000)
        #expect(parsed.bySourceID.count == 10_000)
        // Budget: an M-series Mac parses this in well under a second;
        // 2 s leaves headroom for a loaded CI box without hiding a
        // quadratic regression (which would take minutes).
        #expect(elapsed < .seconds(2), "10k-row manifest parse took \(elapsed)")
        let spot = try #require(parsed.byRelPath["30_Video/1990-1999/1990/1990-xx-xx_Clip_0.mov"])
        #expect(spot.sha256 == String(format: "%064x", 0))
    }
}

// MARK: - Isolation + sensor

@Suite("Verify Archive Copies — isolation & sensor", .serialized)
@MainActor
struct VerifyArchiveCopiesIsolationTests {

    @Test("ISOLATION (poisoned-state): a poisoned shared designation is not inherited; UserDefaults VALUES and the real App Support tree are byte-for-byte unchanged by a full verify run")
    func isolation() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("viso")
        defer { sb.cleanup() }
        let poisoned = MasterArchiveDesignation(targetPath: "/Volumes/Poison",
                                                rootPath: "/Volumes/Poison/Breen_Family_Archive")
        let sharedSlotBefore = CatalogStore.shared.masterArchive
        CatalogStore.shared.masterArchive = poisoned
        defer { CatalogStore.shared.masterArchive = sharedSlotBefore }

        let defaultsBefore = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        let appSupportBefore = Self.appSupportSnapshot()

        let model = MasterArchiveTestSupport.makeModel(sb)
        #expect(model.masterArchive == nil, "poisoned shared designation not inherited")
        try MasterArchiveTestSupport.initialize(model, in: sb)
        let src = try MasterArchiveTestSupport.writeBlob(
            at: sb.sources.appendingPathComponent("test_viso.mov"), bytes: 64 * 1024, seed: 7)
        let rec = MasterArchiveTestSupport.makeRecord(path: src.path)
        model.records = [rec]
        _ = try #require(await MasterArchiveTestSupport.promote(model, ids: [rec.id]))
        model.masterArchiveCopy(of: rec)?.archiveFixity = nil

        let job = await VerifyTestSupport.run(model)
        guard case .finished = job.state else {
            Issue.record("verify did not finish: \(job.state)"); return
        }
        #expect(job.tally.restored == 1)
        #expect(model.masterArchive?.rootPath.hasPrefix(
            FileManager.default.temporaryDirectory.standardizedFileURL.path) == true,
            "the archive under test lives in the sandbox, never on a real volume")

        let defaultsAfter = UserDefaults.standard.dictionaryRepresentation() as NSDictionary
        #expect(defaultsBefore.isEqual(to: defaultsAfter as! [AnyHashable: Any]),
                "UserDefaults values changed: \(Self.diffKeys(defaultsBefore, defaultsAfter))")
        #expect(Self.appSupportSnapshot() == appSupportBefore,
                "real App Support tree changed — GH #167's victim was the REAL catalog")
    }

    @Test("SENSOR: verify twice — the second run restores nothing, appends no manifest rows, invents no records (read-only-on-media pinned)")
    func secondRunIsPureAudit() async throws {
        let (sb, model, _, copies) = try await VerifyTestSupport.promotedSandbox("sensor", count: 3)
        defer { sb.cleanup() }
        for copy in copies { copy.archiveFixity = nil }

        let first = await VerifyTestSupport.run(model)
        #expect(first.tally.restored == 3)
        let manifestAfterFirst = MasterArchiveTestSupport.manifestRows(sb).count
        let recordsAfterFirst = model.records.count
        let digests = copies.map { $0.archiveFixity?.digest }

        let second = await VerifyTestSupport.run(model)
        guard case .finished = second.state else {
            Issue.record("second verify did not finish: \(second.state)"); return
        }
        #expect(second.tally.restored == 0, "nothing left to restore")
        #expect(second.tally.verified == 3)
        #expect(second.tally.mismatch == 0)
        #expect(MasterArchiveTestSupport.manifestRows(sb).count == manifestAfterFirst,
                "manifest untouched by verification")
        #expect(model.records.count == recordsAfterFirst, "no records invented")
        #expect(copies.map { $0.archiveFixity?.digest } == digests, "digests stable across runs")
    }

    // Same snapshot helpers as MasterArchivePromoteTests (private there).
    private static func appSupportSnapshot() -> [String: String] {
        let dir = (CatalogStore.shared.fileLocation as NSString).deletingLastPathComponent
        let fm = FileManager.default
        var out: [String: String] = [:]
        guard let e = fm.enumerator(atPath: dir) else { return out }
        for case let rel as String in e {
            let attrs = (try? fm.attributesOfItem(atPath: (dir as NSString).appendingPathComponent(rel))) ?? [:]
            let size = (attrs[.size] as? NSNumber)?.int64Value ?? -1
            let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
            out[rel] = "\(size):\(mtime)"
        }
        return out
    }

    private static func diffKeys(_ a: NSDictionary, _ b: NSDictionary) -> [String] {
        var out: [String] = []
        for case let k as String in Set(a.allKeys.compactMap { $0 as? String }).union(b.allKeys.compactMap { $0 as? String }) {
            let x = a[k] as AnyObject?, y = b[k] as AnyObject?
            if !(x?.isEqual(y) ?? (y == nil)) { out.append(k) }
        }
        return out.sorted()
    }
}
