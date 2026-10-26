// AdvReview20261026Tests.swift
// Regression pins for the 2026-10-26 nightly adversarial review
// (docs/reviews/adversarial/2026-10-26.md), P2 F1 (MOPS-6): a Migrate where
// nothing was copied (or any file is left unproven) still said "Your files
// are safe … you can retire <drive>". F2 (⌘⌫) is in
// AdvReview20261026TrashTests.swift.

import CryptoKit
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite struct RelocateSummaryAllSafeHeadlineTests {

    /// The headline's words moved from the sheet's private properties into
    /// `RelocateSummaryHeadline.init` (RelocateSummary.swift) with the fix;
    /// the reviewer's check follows them there so it can never pass vacuously.
    static var sheetFile: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/MediaOps/RelocateSummary.swift")
    }

    /// The code of the property starting at `start`, up to `end`, comment
    /// lines dropped; nil when `end` is no longer there (the words are gone).
    static func codeBefore(_ end: String, inPropertyStarting start: String, of text: String) throws -> String? {
        let s = try #require(text.range(of: start), "\(start) not found")
        guard let e = text.range(of: end, range: s.upperBound..<text.endIndex) else { return nil }
        return text[s.upperBound..<e.lowerBound]
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    @Test func allSafeWordsAskAboutFailedAndUnmatchedFiles() throws {
        let text = try String(contentsOf: Self.sheetFile, encoding: .utf8)
        let checks = [
            ("init(_ s: RelocateSummary) {", "title = \"Your files are safe\""),
            ("init(_ s: RelocateSummary) {", "Everything's accounted for"),
        ]
        for (start, end) in checks {
            let code = try #require(try Self.codeBefore(end, inPropertyStarting: start, of: text),
                                    "\(end) not found after \(start) — move this check with the words")
            let asksEachCount = code.contains("salvageFailedCount") && code.contains("stillThereCount")
                && code.contains("notMarkedCount")
            let asksAPredicate = code.contains("ccountedFor") || code.contains("eedsAttention") || code.contains("llSafe")
            #expect(asksEachCount || asksAPredicate,
                    "\(start) reaches \(end) without asking whether a file failed to copy, was left at its path or was not marked")
        }
    }
}

/// The headline's words as a pure value of the summary: "safe" and
/// "retire" appear only when every file was copied-and-verified or has a
/// checksum-verified copy on a safe drive.
@Suite struct RelocateSummaryHeadlineTests {

    static func summary(dryRun: Bool = false, copied: Int = 0, backedUp: Int = 0, degraded: Int = 0,
                        salvageFailed: Int = 0, notMarked: Int = 0, stillThere: Int = 0,
                        adopted: Int = 0, proven: Int? = nil, missing: Int = 0) -> RelocateSummary {
        RelocateSummary(
            isDryRun: dryRun, sourceVolumeName: "OldDrive", sourceVolumeRootPath: "/Volumes/OldDrive",
            destinationDisplay: "Workspace/from-OldDrive", destinationRootPath: "/Volumes/Workspace/from-OldDrive",
            succeededCount: copied, bytesCopied: Int64(copied) * 1_000, adoptedCount: adopted,
            safelyRedundantCount: backedUp + degraded, safelyRedundantBytes: 0,
            sourceMovesCount: 0, manuallyDeletedCount: missing, salvageFailedCount: salvageFailed, skippedCount: 0,
            safelyBackedUpCount: backedUp, degradedOnlyCount: degraded,
            salvageFailedPaths: [], witnessSamples: [], elapsedSeconds: 1, averageMBps: 0, snapshotPath: nil,
            notMarkedCount: notMarked, stillThereCount: stillThere,
            provenBackupCount: proven ?? backedUp)
    }

    static func saysSafeOrRetire(_ h: RelocateSummaryHeadline) -> Bool {
        let words = (h.title + " " + h.body).lowercased()
        return words.contains("safe") && !words.contains("not proven safe") || words.contains("retire")
            || words.contains("accounted for") || words.contains("checksum-verified") || h.invitesRetire
    }

    /// The finding's own example: nothing copied, 37 backed up, 3 failed.
    @Test func nothingCopiedAndThreeFailedNeverSaysSafeOrRetire() {
        let h = RelocateSummaryHeadline(Self.summary(backedUp: 37, salvageFailed: 3))
        #expect(!Self.saysSafeOrRetire(h), "\(h)")
        #expect(h.tint == .orange)
        #expect(h.body.contains("No files were copied"), "\(h.body)")
        #expect(h.body.contains("3 files are not proven safe yet"), "\(h.body)")
        #expect(h.body.contains("Keep OldDrive"), "\(h.body)")
    }

    /// Every unproven bucket on its own withholds the safe/retire words —
    /// with or without copies.
    @Test(arguments: [
        (0, 0, 0, 1), (0, 0, 1, 0), (0, 1, 0, 0), (1, 0, 0, 0),
    ])
    func eachUnprovenBucketWithholdsSafeAndRetire(_ counts: (Int, Int, Int, Int)) {
        let (failed, notMarked, stillThere, degraded) = counts
        for copied in [0, 4] {
            let h = RelocateSummaryHeadline(Self.summary(copied: copied, backedUp: 2, degraded: degraded,
                                                         salvageFailed: failed, notMarked: notMarked,
                                                         stillThere: stillThere))
            #expect(!Self.saysSafeOrRetire(h), "copied \(copied), counts \(counts): \(h)")
            #expect(h.title == "Some files are not proven safe yet")
            #expect(h.body.contains("1 file is not proven safe yet"), "\(h.body)")
        }
    }

    /// Codex #150 F2: a source marked missing (old path gone, nothing
    /// matched) proves no surviving copy — it withholds safe and retire.
    @Test func aMissingSourceWithholdsSafeAndRetire() {
        let h = RelocateSummaryHeadline(Self.summary(backedUp: 1, missing: 1))
        #expect(!Self.saysSafeOrRetire(h), "\(h)")
        #expect(h.body.contains("1 file is not proven safe yet"), "\(h.body)")
    }

    /// Codex #150 F1/F5: a Bucket E backup matched only by partial MD5 +
    /// stat (or only on an Aging drive) is not proven — no "safe", no
    /// "checksum-verified", no retire.
    @Test func anUnprovenBackupWithholdsSafeAndRetire() {
        let h = RelocateSummaryHeadline(Self.summary(backedUp: 37, proven: 36))
        #expect(!Self.saysSafeOrRetire(h), "\(h)")
        #expect(h.body.contains("36 are already backed up on other drives, matched by full SHA-256 checksum"), "\(h.body)")
        #expect(h.body.contains("1 file is not proven safe yet"), "\(h.body)")
    }

    /// Nothing copied and nothing backed up: no proof happened this run, so
    /// no "safe" and no retire line.
    @Test func nothingCopiedNothingBackedUpIsNotSafe() {
        let h = RelocateSummaryHeadline(Self.summary())
        #expect(!Self.saysSafeOrRetire(h), "\(h)")
        #expect(h.title == "Nothing was copied")
        // Closing pass F1: an adoption with no proof is not safe either.
        let adopted = RelocateSummaryHeadline(Self.summary(adopted: 2))
        #expect(!Self.saysSafeOrRetire(adopted), "\(adopted)")
        #expect(adopted.title == "Some files are not proven safe yet")
    }

    /// The truly all-safe and copied-and-verified runs keep their words.
    @Test func provenRunsKeepTheirWords() {
        let allSafe = RelocateSummaryHeadline(Self.summary(backedUp: 37))
        #expect(allSafe.title == "Your files are safe" && allSafe.invitesRetire)
        #expect(allSafe.body.contains("each matched by its full SHA-256 checksum. Everything's accounted for — you can retire OldDrive"))
        let mixed = RelocateSummaryHeadline(Self.summary(copied: 3, backedUp: 1))
        #expect(mixed.title == "Files copied and verified" && mixed.invitesRetire)
        let dry = RelocateSummaryHeadline(Self.summary(dryRun: true, salvageFailed: 2))
        #expect(dry.title == "Dry-run preview" && !dry.invitesRetire)
    }
}

/// Codex #150 F1/F5 end to end: a real Migrate whose only backup is a
/// catalogued same-MD5 copy. The retire words stand only when that copy is
/// proven by its full SHA-256 now, on a safe drive that is not Aging.
@Suite(.serialized) @MainActor
struct RelocateSummaryProofTests {

    struct Rig {
        let root: URL, source: URL, dest: URL, catalog: URL, backup: URL
        init() throws {
            root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("vs-migrate-proof-\(UUID().uuidString.prefix(8))", isDirectory: true)
            source = root.appendingPathComponent("source"); dest = root.appendingPathComponent("dest")
            catalog = root.appendingPathComponent("catalog"); backup = root.appendingPathComponent("MyBook")
            for url in [source, dest, catalog, backup] {
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            }
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    static func bytes(_ seed: Int) -> Data { Data((0..<4_096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }) }

    /// A catalog row for `url`, with its full SHA-256 fixity when `hashed`.
    static func row(_ url: URL, hashed: Bool) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = url.path; r.filename = url.lastPathComponent
        r.directory = url.deletingLastPathComponent().path
        let data = (try? Data(contentsOf: url)) ?? Data()
        r.sizeBytes = Int64(data.count)
        r.partialMD5 = FileHasher.partialMD5(path: url.path)
        if hashed {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            r.contentFixity = ContentFixity.captured(path: url.path, digest: digest, byteCount: Int64(data.count))
        }
        return r
    }

    /// Run a real Migrate of a source holding one file whose backup is on
    /// MyBook (`trust`); `tamper` runs after cataloguing, before the run.
    func migrate(trust: VolumeTrust, hashed: Bool = true,
                 tamper: (Rig) throws -> Void = { _ in }) async throws -> RelocateSummary {
        let rig = try Rig(); defer { rig.cleanup() }
        let src = rig.source.appendingPathComponent("clip.mov")
        let copy = rig.backup.appendingPathComponent("clip.mov")
        try Self.bytes(7).write(to: src)
        try Self.bytes(7).write(to: copy)
        let srcRow = Self.row(src, hashed: hashed)
        let copyRow = Self.row(copy, hashed: hashed)
        if hashed {
            try #require(srcRow.contentFixity?.isUsableForVerification == true
                         && copyRow.contentFixity?.isUsableForVerification == true,
                         "the fixture could not stamp a usable fixity")
        }
        try tamper(rig)

        let model = VideoScanModel()
        model.relocateWitnessIndependence = RelocateReconcile.witnessIsNotTheSourceFile
        model.catalogStore = CatalogStore(directory: rig.catalog)
        model.records = [srcRow, copyRow]
        let safe = CatalogScanTarget(searchPath: rig.backup.path)
        safe.role = .backup; safe.trust = trust
        model.scanTargets = [CatalogScanTarget(searchPath: rig.source.path), safe]
        model.catalogStore.saveNow(records: model.records)
        model.relocateVolume(RelocateOptions(sourceVolumeRootPath: rig.source.path, destinationRoot: rig.dest,
                                             maxConcurrency: 1, dryRun: false,
                                             skipAlreadyRelocated: true, skipDupsOnOtherVolumes: true))
        let deadline = Date().addingTimeInterval(30)
        while model.pendingRelocateSummary == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return try #require(model.pendingRelocateSummary)
    }

    /// Control / truth: a backup proven by its full SHA-256 on a reliable
    /// drive keeps "Your files are safe" and the retire invitation.
    @Test func aHashedUntouchedBackupInvitesRetire() async throws {
        let s = try await migrate(trust: .reliable)
        try #require(s.safelyRedundantCount == 1, "the fixture must land in Bucket E")
        #expect(RelocateSummaryHeadline(s).invitesRetire, "\(RelocateSummaryHeadline(s))")
    }

    /// Codex's recipe: the backup was overwritten with different bytes of
    /// the same size after it was catalogued. Bucket E still matches it by
    /// the stored partial MD5 and the size; the summary must not.
    @Test func anOverwrittenBackupIsNotProven() async throws {
        let s = try await migrate(trust: .reliable) { rig in
            try Self.bytes(99).write(to: rig.backup.appendingPathComponent("clip.mov"))
        }
        try #require(s.safelyRedundantCount == 1, "the stale partial MD5 still lands it in Bucket E")
        #expect(!RelocateSummaryHeadline(s).invitesRetire, "\(RelocateSummaryHeadline(s))")
    }

    /// No full SHA-256 on record at all (partial MD5 only): not proven.
    @Test func anUnhashedBackupIsNotProven() async throws {
        let s = try await migrate(trust: .reliable, hashed: false)
        try #require(s.safelyRedundantCount == 1)
        #expect(!RelocateSummaryHeadline(s).invitesRetire, "\(RelocateSummaryHeadline(s))")
    }

    /// Codex closing pass F1 (recipe): source A has no stored hash and an
    /// unrelated same-size X sits at A's planned destination, so Migrate
    /// adopts X by size alone; source C has a genuinely proven backup. The
    /// adoption proves nothing — no retire invitation.
    @Test func aSizeOnlyAdoptionNeverInvitesRetire() async throws {
        let rig = try Rig(); defer { rig.cleanup() }
        let srcA = rig.source.appendingPathComponent("a.mov")
        try Self.bytes(1).write(to: srcA)
        try Self.bytes(2).write(to: rig.dest.appendingPathComponent("a.mov"))   // unrelated, same size
        let rowA = Self.row(srcA, hashed: false); rowA.partialMD5 = ""
        let srcC = rig.source.appendingPathComponent("c.mov")
        let copyC = rig.backup.appendingPathComponent("c.mov")
        try Self.bytes(7).write(to: srcC)
        try Self.bytes(7).write(to: copyC)
        let rowC = Self.row(srcC, hashed: true), copyRow = Self.row(copyC, hashed: true)

        let model = VideoScanModel()
        model.relocateWitnessIndependence = RelocateReconcile.witnessIsNotTheSourceFile
        model.catalogStore = CatalogStore(directory: rig.catalog)
        model.records = [rowA, rowC, copyRow]
        let safe = CatalogScanTarget(searchPath: rig.backup.path)
        safe.role = .backup; safe.trust = .reliable
        model.scanTargets = [CatalogScanTarget(searchPath: rig.source.path), safe]
        model.catalogStore.saveNow(records: model.records)
        model.relocateVolume(RelocateOptions(sourceVolumeRootPath: rig.source.path, destinationRoot: rig.dest,
                                             maxConcurrency: 1, dryRun: false,
                                             skipAlreadyRelocated: true, skipDupsOnOtherVolumes: true))
        let deadline = Date().addingTimeInterval(30)
        while model.pendingRelocateSummary == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        let s = try #require(model.pendingRelocateSummary)
        try #require(s.adoptedCount == 1, "the fixture must adopt X for A (adopted \(s.adoptedCount), copied \(s.succeededCount))")
        #expect(!RelocateSummaryHeadline(s).invitesRetire, "\(RelocateSummaryHeadline(s))")
    }

    /// One real Migrate of a source holding hashed A (its original bytes
    /// already copied to A's planned destination) plus hashed C with a
    /// proven backup; `tamper` runs after cataloguing, before the run.
    func migrateAdoption(tamper: (Rig) throws -> Void) async throws -> RelocateSummary {
        let rig = try Rig(); defer { rig.cleanup() }
        let srcA = rig.source.appendingPathComponent("a.mov")
        try Self.bytes(1).write(to: srcA)
        let rowA = Self.row(srcA, hashed: true)
        try #require(rowA.contentFixity?.isUsableForVerification == true)
        try Self.bytes(1).write(to: rig.dest.appendingPathComponent("a.mov"))   // the original bytes
        let srcC = rig.source.appendingPathComponent("c.mov")
        let copyC = rig.backup.appendingPathComponent("c.mov")
        try Self.bytes(7).write(to: srcC)
        try Self.bytes(7).write(to: copyC)
        let rowC = Self.row(srcC, hashed: true), copyRow = Self.row(copyC, hashed: true)
        try tamper(rig)

        let model = VideoScanModel()
        model.relocateWitnessIndependence = RelocateReconcile.witnessIsNotTheSourceFile
        model.catalogStore = CatalogStore(directory: rig.catalog)
        model.records = [rowA, rowC, copyRow]
        let safe = CatalogScanTarget(searchPath: rig.backup.path)
        safe.role = .backup; safe.trust = .reliable
        model.scanTargets = [CatalogScanTarget(searchPath: rig.source.path), safe]
        model.catalogStore.saveNow(records: model.records)
        model.relocateVolume(RelocateOptions(sourceVolumeRootPath: rig.source.path, destinationRoot: rig.dest,
                                             maxConcurrency: 1, dryRun: false,
                                             skipAlreadyRelocated: true, skipDupsOnOtherVolumes: true))
        let deadline = Date().addingTimeInterval(30)
        while model.pendingRelocateSummary == nil && Date() < deadline {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }
        return try #require(model.pendingRelocateSummary)
    }

    /// Codex round 3 recipe: A is hashed, its original bytes are copied to
    /// the destination, then the SOURCE is overwritten in place with
    /// different same-size bytes. The destination still matches A's stored
    /// digest, but that digest no longer describes the source.
    @Test func anAdoptionWhoseSourceChangedIsNotProven() async throws {
        let s = try await migrateAdoption { rig in
            try Self.bytes(55).write(to: rig.source.appendingPathComponent("a.mov"))
        }
        try #require(s.adoptedCount == 1, "adopted \(s.adoptedCount), copied \(s.succeededCount)")
        #expect(s.provenAdoptedCount == 0)
        #expect(!RelocateSummaryHeadline(s).invitesRetire, "\(RelocateSummaryHeadline(s))")
    }

    /// Control: source untouched, destination holds its bytes — proven.
    @Test func anAdoptionOfAnUntouchedHashedSourceIsProven() async throws {
        let s = try await migrateAdoption { _ in }
        try #require(s.adoptedCount == 1)
        #expect(s.provenAdoptedCount == 1)
        #expect(RelocateSummaryHeadline(s).invitesRetire, "\(RelocateSummaryHeadline(s))")
    }

    /// Codex #150 F5: the only backup is on a drive marked Aging.
    @Test func anAgingOnlyBackupNeverInvitesRetire() async throws {
        let s = try await migrate(trust: .aging)
        try #require(s.safelyRedundantCount == 1)
        #expect(!RelocateSummaryHeadline(s).invitesRetire, "\(RelocateSummaryHeadline(s))")
    }
}
