// ScanMergeMoveIdentityTests.swift
// Move/rename identity in the scan-completion merge (feature/move-rename-identity).
//
// A moved or renamed file must keep its catalog record IDENTITY — id, dossier
// fields, user curation, pair references — instead of being pruned and
// re-created as a stranger. Rick's driving case: 134 GB of digitized-tape
// .mkv masters on /Volumes/MediaExpansion will later be MOVED (cross-volume)
// to /Volumes/LaCieWorkspace, and their transcripts/captions/tags must follow.
//
// RED phase (this file, pre-implementation): the identity tests below FAIL
// against current commitScanResults — a complete rescan prunes the old record
// (genuinely gone from its old path) and appends a fresh stranger at the new
// path, destroying id + enrichment. GREEN once the merge fingerprint-matches
// added files against gone/absent records and adopts them.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Fixture helpers (private per-file, mirroring ScanMergeScopeTests)

/// Minimal cataloged record at an arbitrary path, optionally fingerprinted.
private func makeRecord(path: String, md5: String = "", sizeBytes: Int64 = 1_000_000) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = sizeBytes
    r.partialMD5 = md5
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    return r
}

/// Pipeline model with deterministic in-memory scan options. Unlike
/// ScanMergeScopeTests' helper, checksums are ON — partialMD5 is the
/// move-fingerprint's identity key, so these pipelines must hash.
@MainActor
private func makeMovePipelineModel() -> VideoScanModel {
    let model = VideoScanModel()
    var opts = ScanOptions()
    opts.skipSmallFiles = false      // fixtures are tiny junk-byte files
    opts.skipChecksums = false       // fingerprints REQUIRE partialMD5
    opts.probeExtensionless = false
    model.scanOptions = opts
    return model
}

private func makeTempDir(_ label: String) throws -> URL {
    // Canonicalize /var/folders → /private/var/folders (walker yields
    // realpath'd URLs; seeded record paths must share that prefix).
    var dir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("vs_moveid_\(label)_\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if let canonical = try dir.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
        dir = URL(fileURLWithPath: canonical, isDirectory: true)
    }
    return dir
}

/// Distinct per-index junk bytes so every fixture file gets a UNIQUE
/// partialMD5 (identical content would make every fingerprint collide).
private func distinctBytes(_ index: Int) -> Data {
    Data((0..<64).map { UInt8(truncatingIfNeeded: $0 &+ index &* 31) })
}

@Suite("Scan-merge move/rename identity")
struct ScanMergeMoveIdentityTests {

    // MARK: - 1. Same-root rename keeps the record's identity (pipeline)

    // Finder-rename shape: file renamed within the scanned root between two
    // complete scans. ONE record must survive — same id, same instance, new
    // path, enrichment intact. RED pre-fix: the old record is pruned
    // (genuinely gone from its old path) and a stranger appears at the new
    // path with a fresh id and no enrichment.
    @Test @MainActor
    func sameRootRenameKeepsRecordIdentity() async throws {
        let dir = try makeTempDir("rename")
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldURL = dir.appendingPathComponent("1987-tape-a.mov")
        try distinctBytes(1).write(to: oldURL)

        let model = makeMovePipelineModel()
        let t1 = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [t1]
        model.startTarget(t1)
        _ = await t1.scanTask?.value

        let original = try #require(model.records.first { $0.fullPath == oldURL.path },
                                     "Fixture sanity: first scan must catalog the file")
        #expect(!original.partialMD5.isEmpty,
                "Fixture sanity: hashing must be on — the fingerprint needs partialMD5")
        let originalID = original.id
        original.notes = "curated"
        original.lifecycleStage = .archived
        original.sceneCaptions = [SceneCaption(timestamp: 1.0, text: "backyard 1987")]

        // The rename, as Finder would do it.
        let newURL = dir.appendingPathComponent("1987-tape-a-RENAMED.mov")
        try FileManager.default.moveItem(at: oldURL, to: newURL)

        let t2 = CatalogScanTarget(searchPath: dir.path)
        model.scanTargets = [t1, t2]
        model.startTarget(t2)
        _ = await t2.scanTask?.value

        #expect(model.records.count == 1,
                "A rename must yield ONE record, not a prune + stranger (got \(model.records.count))")
        let after = try #require(model.records.first { $0.fullPath == newURL.path },
                                 "The record must now live at the renamed path")
        #expect(after.id == originalID,
                "The record's identity must survive the rename (RED pre-fix: fresh id)")
        #expect(after === original,
                "The surviving record must be the ORIGINAL instance (pair references resolve by identity)")
        #expect(after.notes == "curated")
        #expect(after.lifecycleStage == .archived)
        #expect(after.sceneCaptions.first?.text == "backyard 1987")
        #expect(after.filename == "1987-tape-a-RENAMED.mov",
                "Scan-derived fields must refresh to the new location")
    }

    // MARK: - 2. Cross-root move follows the record (pipeline — Rick's case)

    // The MediaExpansion → LaCieWorkspace shape: file MOVED to a different
    // volume/root; the old root has NOT been rescanned when the new root's
    // scan runs. The record (with its transcript) must follow the file. A
    // LATER rescan of the old root must then prune nothing.
    @Test @MainActor
    func crossRootMoveFollowsRecordToNewRoot() async throws {
        let rootX = try makeTempDir("rootX")     // "MediaExpansion"
        let rootY = try makeTempDir("rootY")     // "LaCieWorkspace"
        defer {
            try? FileManager.default.removeItem(at: rootX)
            try? FileManager.default.removeItem(at: rootY)
        }
        let tapeX = rootX.appendingPathComponent("digitized-tape-07.mkv")
        try distinctBytes(7).write(to: tapeX)
        // Anchor keeps the LATER rootX rescan's discovery non-empty (an empty
        // discovery never prunes anyway, which would mask the real assertion).
        try distinctBytes(8).write(to: rootX.appendingPathComponent("anchor.mov"))

        let model = makeMovePipelineModel()
        let t1 = CatalogScanTarget(searchPath: rootX.path)
        model.scanTargets = [t1]
        model.startTarget(t1)
        _ = await t1.scanTask?.value

        let tape = try #require(model.records.first { $0.fullPath == tapeX.path })
        #expect(!tape.partialMD5.isEmpty, "Fixture sanity: fingerprint needs partialMD5")
        let tapeID = tape.id
        tape.audioTranscript = "…Donna laughing on the porch…"
        tape.notes = "1987 Christmas master"

        // The cross-volume move (into a subfolder, so directory updates too).
        let destDir = rootY.appendingPathComponent("masters", isDirectory: true)
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        let tapeY = destDir.appendingPathComponent("digitized-tape-07.mkv")
        try FileManager.default.moveItem(at: tapeX, to: tapeY)

        // Scan the NEW root — the old root has not been rescanned.
        let t2 = CatalogScanTarget(searchPath: rootY.path)
        model.scanTargets = [t1, t2]
        model.startTarget(t2)
        _ = await t2.scanTask?.value

        #expect(model.records.count == 2,
                "tape (followed) + anchor = 2 records (got \(model.records.count))")
        let followed = try #require(model.records.first { $0.fullPath == tapeY.path },
                                    "The record must now live under the new root")
        #expect(followed.id == tapeID,
                "Identity must survive the cross-root move (RED pre-fix: stranger id)")
        #expect(followed.audioTranscript == "…Donna laughing on the porch…",
                "The transcript must follow the file")
        #expect(followed.notes == "1987 Christmas master")
        #expect(!model.records.contains { $0.fullPath == tapeX.path },
                "No ghost record may remain at the old path")

        // The later rescan of the OLD root prunes nothing: the tape record no
        // longer lives under rootX, and the anchor is re-seen.
        let t3 = CatalogScanTarget(searchPath: rootX.path)
        model.scanTargets = [t1, t2, t3]
        model.startTarget(t3)
        _ = await t3.scanTask?.value

        #expect(model.records.count == 2,
                "A later rescan of the old root must prune nothing (got \(model.records.count))")
        #expect(model.records.contains { $0.id == tapeID && $0.fullPath == tapeY.path },
                "The moved record is untouched by the old root's rescan")
    }

    // MARK: - 4. Pair references survive a partner's move (unit, via merge)

    // R1.pairedWith → R2 (the Correlate feature's A/V pairing). R2's file
    // moves cross-root. Adoption must keep R2's INSTANCE (and id), so R1's
    // reference still resolves. RED pre-fix: R2 pruned + stranger appended,
    // R1.pairedWith dangles at a record no longer in the catalog.
    @Test @MainActor
    func pairReferenceSurvivesPartnerMove() async throws {
        let vids = try makeTempDir("pairvids")       // scan root (reachable)
        let oldVol = try makeTempDir("pairold")      // partner's old home
        defer {
            try? FileManager.default.removeItem(at: vids)
            try? FileManager.default.removeItem(at: oldVol)
        }

        let model = VideoScanModel()
        // R2's file no longer exists at its old path (moved away).
        let r2 = makeRecord(path: oldVol.appendingPathComponent("audio-essence.mxf").path,
                            md5: "fp-pair", sizeBytes: 5000)
        let r1 = makeRecord(path: oldVol.appendingPathComponent("video-essence.mxf").path)
        r1.pairedWith = r2
        model.records = [r1, r2]

        let fresh = makeRecord(path: vids.appendingPathComponent("audio-essence.mxf").path,
                               md5: "fp-pair", sizeBytes: 5000)
        let outcome = await model.commitScanResults(
            root: vids.path, volName: "Y",
            targetRecords: [fresh], scanWasComplete: true)

        #expect(outcome.moved == 1 && outcome.pruned == 0,
                "The adoption must be counted as moved, not pruned (moved=\(outcome.moved), pruned=\(outcome.pruned))")
        let r2InCatalog = model.records.filter { $0.id == r2.id }
        #expect(r2InCatalog.count == 1,
                "R2 must survive as exactly one record (got \(r2InCatalog.count); RED pre-fix: 0 — replaced by a stranger)")
        #expect(r2InCatalog.first === r2, "R2 must be the ORIGINAL instance")
        #expect(r2.fullPath == fresh.fullPath, "R2 must have followed its file")
        let r1InCatalog = try #require(model.records.first { $0.id == r1.id })
        #expect(r1InCatalog.pairedWith === r2,
                "R1's pair reference must still resolve to R2 after the move")
    }

    // MARK: - 5. Mass reorganize is not a mass deletion (unit, via merge)

    // Rick renames a whole folder tree: 60 of 60 records "vanish" from their
    // old paths and reappear elsewhere under the same root. Pre-fix this
    // fires the mass-deletion tripwire (60 > 50 and 100% > 20%), snapshots,
    // and prunes all 60 — destroying every id. Moved adoptions must be
    // excluded from the prune count BEFORE the tripwire judges it.
    @Test @MainActor
    func massReorganizeKeepsIdentitiesAndStaysOffTheTripwire() async throws {
        let store = try makeTempDir("massstore")
        let vids = try makeTempDir("massvids")
        defer {
            try? FileManager.default.removeItem(at: store)
            try? FileManager.default.removeItem(at: vids)
        }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: store)
        // Old paths: files never created → genuinely gone from disk.
        let seeds = (0..<60).map {
            makeRecord(path: vids.appendingPathComponent("clip\($0).mov").path,
                       md5: "fp-\($0)", sizeBytes: Int64(1000 + $0))
        }
        seeds[0].notes = "curated"
        model.records = seeds
        model.catalogStore.saveNow(records: seeds)

        // The reorganize: same files (same fingerprints) under archive/.
        let fresh = (0..<60).map {
            makeRecord(path: vids.appendingPathComponent("archive/clip\($0).mov").path,
                       md5: "fp-\($0)", sizeBytes: Int64(1000 + $0))
        }
        let outcome = await model.commitScanResults(
            root: vids.path, volName: "X",
            targetRecords: fresh, scanWasComplete: true)

        #expect(outcome.moved == 60 && outcome.pruned == 0,
                "All 60 must count as moved, none pruned (moved=\(outcome.moved), pruned=\(outcome.pruned))")
        #expect(!outcome.tripwireFired,
                "A reorganize must not fire the mass-deletion tripwire (RED against a naive impl that judges pre-exclusion counts)")
        #expect(model.records.count == 60,
                "60 records in, 60 out — a reorganize is not a deletion (got \(model.records.count))")
        let survivingIDs = Set(model.records.map(\.id))
        #expect(survivingIDs == Set(seeds.map(\.id)),
                "Every record identity must survive the reorganize (RED pre-fix: all replaced)")
        let clip0 = model.records.first { $0.fullPath == vids.appendingPathComponent("archive/clip0.mov").path }
        #expect(clip0?.notes == "curated", "Enrichment must follow each file")
        let snapshots = try FileManager.default.contentsOfDirectory(atPath: store.path)
            .filter { $0.hasPrefix("catalog.pre-merge.") }
        #expect(snapshots.isEmpty,
                "The mass-deletion tripwire must NOT fire on a reorganize (found snapshot \(snapshots))")
    }

    // MARK: - 3. Copy is not a move — a candidate still on disk is never adopted

    // File copied to the scanned root, ORIGINAL STILL EXISTS: the original's
    // record must be untouched and the copy lands as a plain new record
    // (the existing duplicate machinery owns copies).
    @Test @MainActor
    func copyWithOriginalStillOnDiskIsNotAdopted() async throws {
        let vids = try makeTempDir("copyvids")
        let elsewhere = try makeTempDir("copyorig")
        defer {
            try? FileManager.default.removeItem(at: vids)
            try? FileManager.default.removeItem(at: elsewhere)
        }
        // The original file EXISTS on disk — the existence sweep must see it.
        let origURL = elsewhere.appendingPathComponent("orig.mkv")
        try distinctBytes(3).write(to: origURL)

        let model = VideoScanModel()
        let orig = makeRecord(path: origURL.path, md5: "fp-copy", sizeBytes: 4242)
        model.records = [orig]

        let fresh = makeRecord(path: vids.appendingPathComponent("copy.mkv").path,
                               md5: "fp-copy", sizeBytes: 4242)
        let outcome = await model.commitScanResults(
            root: vids.path, volName: "Y",
            targetRecords: [fresh], scanWasComplete: true)

        #expect(outcome.moved == 0, "A copy must never be treated as a move")
        #expect(model.records.count == 2,
                "Original + copy = TWO records (got \(model.records.count))")
        #expect(orig.fullPath == origURL.path, "The original record is untouched")
        #expect(model.records.contains { $0 === fresh },
                "The copy lands as the fresh record with its own identity")
    }

    // MARK: - 6a. Atomicity: candidate removed during the await is never adopted

    // Extends the during-await mutation sensor style (ScanMergeRobustnessTests
    // test 18): a fingerprint-matched candidate whose record is REMOVED from
    // the catalog during the merge's one suspension must not be adopted —
    // adoption would resurrect it. The fresh record lands as a plain stranger.
    @Test @MainActor
    func candidateRemovedDuringAwaitIsNotResurrected() async throws {
        let vids = try makeTempDir("atomicvids")
        let oldVol = try makeTempDir("atomicold")
        defer {
            try? FileManager.default.removeItem(at: vids)
            try? FileManager.default.removeItem(at: oldVol)
        }

        let model = VideoScanModel()
        // File gone from disk + fingerprint match: WOULD be adopted…
        let candidate = makeRecord(path: oldVol.appendingPathComponent("moved.mkv").path,
                                   md5: "fp-atomic", sizeBytes: 7777)
        model.records = [candidate]
        // …but the record leaves the catalog during the suspension.
        model.scanMergeDuringExistenceChecksForTesting = { @MainActor in
            model.records.removeAll { $0 === candidate }
        }
        defer { model.scanMergeDuringExistenceChecksForTesting = nil }

        let fresh = makeRecord(path: vids.appendingPathComponent("moved.mkv").path,
                               md5: "fp-atomic", sizeBytes: 7777)
        let outcome = await model.commitScanResults(
            root: vids.path, volName: "Y",
            targetRecords: [fresh], scanWasComplete: true)

        #expect(outcome.moved == 0,
                "A candidate that left the catalog during the await must not be matched")
        #expect(!model.records.contains { $0.id == candidate.id },
                "The removed record must STAY removed — never resurrected by adoption")
        #expect(model.records.contains { $0 === fresh },
                "The scanned file still lands, as a plain new record")
        #expect(candidate.fullPath == oldVol.appendingPathComponent("moved.mkv").path,
                "The detached instance is never mutated")
    }

    // MARK: - 6b. Atomicity: candidate that APPEARED during the await has no
    // evidence — never adopted

    // The ?? -retain discipline, move-flavored: a record added to the catalog
    // during the suspension was never statted by the sweep. No evidence → no
    // adoption, even though its file is gone and its fingerprint matches.
    @Test @MainActor
    func candidateAppearingDuringAwaitIsNotAdoptedWithoutEvidence() async throws {
        let vids = try makeTempDir("appearvids")
        let oldVol = try makeTempDir("appearold")
        defer {
            try? FileManager.default.removeItem(at: vids)
            try? FileManager.default.removeItem(at: oldVol)
        }

        let model = VideoScanModel()
        let lateCandidate = makeRecord(path: oldVol.appendingPathComponent("late.mkv").path,
                                       md5: "fp-late", sizeBytes: 8888)
        model.scanMergeDuringExistenceChecksForTesting = { @MainActor in
            model.records.append(lateCandidate)
        }
        defer { model.scanMergeDuringExistenceChecksForTesting = nil }

        let fresh = makeRecord(path: vids.appendingPathComponent("late.mkv").path,
                               md5: "fp-late", sizeBytes: 8888)
        let outcome = await model.commitScanResults(
            root: vids.path, volName: "Y",
            targetRecords: [fresh], scanWasComplete: true)

        #expect(outcome.moved == 0,
                "No stat evidence for the late candidate → it must NOT be adopted (RED against absent-means-gone semantics)")
        #expect(lateCandidate.fullPath == oldVol.appendingPathComponent("late.mkv").path,
                "The late candidate keeps its own path")
        #expect(model.records.contains { $0 === fresh },
                "The scanned file lands as a plain new record")
        #expect(model.records.contains { $0 === lateCandidate },
                "The late record itself is retained untouched")
    }

    // MARK: - Safety rails: purged and hash-less records never match

    // A soft-deleted (purged) record must never adopt: it would swallow the
    // fresh record into a hidden row and the moved file would vanish from
    // the visible catalog.
    @Test @MainActor
    func purgedRecordIsNeverAMoveCandidate() async throws {
        let vids = try makeTempDir("purgevids")
        let oldVol = try makeTempDir("purgeold")
        defer {
            try? FileManager.default.removeItem(at: vids)
            try? FileManager.default.removeItem(at: oldVol)
        }

        let model = VideoScanModel()
        let purged = makeRecord(path: oldVol.appendingPathComponent("hidden.mkv").path,
                                md5: "fp-purged", sizeBytes: 9999)
        purged.purgedAt = Date()
        model.records = [purged]

        let fresh = makeRecord(path: vids.appendingPathComponent("hidden.mkv").path,
                               md5: "fp-purged", sizeBytes: 9999)
        let outcome = await model.commitScanResults(
            root: vids.path, volName: "Y",
            targetRecords: [fresh], scanWasComplete: true)

        #expect(outcome.moved == 0, "Purged records must never adopt")
        #expect(model.records.contains { $0 === fresh },
                "The moved file must be VISIBLE — a plain new active record")
        #expect(purged.fullPath == oldVol.appendingPathComponent("hidden.mkv").path,
                "The purged record stays where (and as) it was")
    }

    // Hash-less records (skipChecksums scans, hash I/O errors) carry an empty
    // partialMD5 — two blanks must never fingerprint-match each other, or
    // every unhashed record would cross-adopt.
    @Test @MainActor
    func blankFingerprintsNeverMatch() async throws {
        let vids = try makeTempDir("blankvids")
        defer { try? FileManager.default.removeItem(at: vids) }

        let model = VideoScanModel()
        // Same (blank md5, same size) on the gone record and the added one.
        let gone = makeRecord(path: vids.appendingPathComponent("gone.mov").path,
                              md5: "", sizeBytes: 1234)
        model.records = [gone]

        let fresh = makeRecord(path: vids.appendingPathComponent("new.mov").path,
                               md5: "", sizeBytes: 1234)
        let outcome = await model.commitScanResults(
            root: vids.path, volName: "X",
            targetRecords: [fresh], scanWasComplete: true)

        #expect(outcome.moved == 0 && outcome.pruned == 1,
                "Blank fingerprints must never match — the gone record is pruned, not adopted (moved=\(outcome.moved), pruned=\(outcome.pruned))")
        #expect(model.records.count == 1 && model.records.first === fresh)
    }

    // MARK: - Same-root beats catalog-wide THROUGH the merge

    // Both a same-root gone record and a cross-root absent record match the
    // added file's fingerprint: the same-root one adopts (rename in place
    // beats a cross-volume match); the cross-root one is left alone.
    @Test @MainActor
    func sameRootCandidateWinsOverCrossRootThroughMerge() async throws {
        let vids = try makeTempDir("prefvids")
        let oldVol = try makeTempDir("prefold")
        defer {
            try? FileManager.default.removeItem(at: vids)
            try? FileManager.default.removeItem(at: oldVol)
        }

        let model = VideoScanModel()
        let sameRoot = makeRecord(path: vids.appendingPathComponent("old-name.mkv").path,
                                  md5: "fp-pref", sizeBytes: 6000)
        let crossRoot = makeRecord(path: oldVol.appendingPathComponent("new-name.mkv").path,
                                   md5: "fp-pref", sizeBytes: 6000)
        model.records = [sameRoot, crossRoot]

        let fresh = makeRecord(path: vids.appendingPathComponent("new-name.mkv").path,
                               md5: "fp-pref", sizeBytes: 6000)
        let outcome = await model.commitScanResults(
            root: vids.path, volName: "X",
            targetRecords: [fresh], scanWasComplete: true)

        #expect(outcome.moved == 1 && outcome.pruned == 0)
        #expect(sameRoot.fullPath == fresh.fullPath,
                "The SAME-ROOT candidate must win the adoption despite the cross-root one's better name match")
        #expect(crossRoot.fullPath == oldVol.appendingPathComponent("new-name.mkv").path,
                "The cross-root record is untouched")
        #expect(model.records.count == 2)
    }
}

// MARK: - Matcher unit tests (pure function — no model, no disk)

@Suite("Move matcher — deterministic ambiguity resolution")
struct ScanMergeMoveMatcherTests {

    private func fp(_ n: Int) -> ScanMergeFingerprint {
        ScanMergeFingerprint(partialMD5: "md5-\(n)", sizeBytes: Int64(1000 + n))
    }

    @Test func fingerprintMismatchNeverMatches() {
        let result = VideoScanModel.matchMovedFiles(
            added: [ScanMergeAddedFile(path: "/new/a.mkv", fingerprint: fp(1))],
            candidates: [ScanMergeMoveCandidate(path: "/old/a.mkv", fingerprint: fp(2), sameRoot: true)])
        #expect(result.isEmpty)
    }

    @Test func sameRootBeatsCatalogWide() {
        // The catalog-wide candidate has the BETTER path-suffix match; the
        // same-root candidate must still win (rule 1 outranks rule 2).
        let result = VideoScanModel.matchMovedFiles(
            added: [ScanMergeAddedFile(path: "/root/family/tape.mkv", fingerprint: fp(1))],
            candidates: [
                ScanMergeMoveCandidate(path: "/elsewhere/family/tape.mkv", fingerprint: fp(1), sameRoot: false),
                ScanMergeMoveCandidate(path: "/root/old-tape.mkv", fingerprint: fp(1), sameRoot: true),
            ])
        #expect(result == ["/root/family/tape.mkv": "/root/old-tape.mkv"])
    }

    @Test func longerCommonSuffixBeatsShorter() {
        let result = VideoScanModel.matchMovedFiles(
            added: [ScanMergeAddedFile(path: "/new/family/xmas/tape.mkv", fingerprint: fp(1))],
            candidates: [
                ScanMergeMoveCandidate(path: "/volA/misc/tape.mkv", fingerprint: fp(1), sameRoot: false),
                ScanMergeMoveCandidate(path: "/volB/family/xmas/tape.mkv", fingerprint: fp(1), sameRoot: false),
            ])
        #expect(result == ["/new/family/xmas/tape.mkv": "/volB/family/xmas/tape.mkv"],
                "…/family/xmas/tape.mkv (3 trailing components) must beat …/misc/tape.mkv (1)")
    }

    @Test func lexicographicCandidateIsTheFinalTiebreak() {
        let result = VideoScanModel.matchMovedFiles(
            added: [ScanMergeAddedFile(path: "/new/tape.mkv", fingerprint: fp(1))],
            candidates: [
                ScanMergeMoveCandidate(path: "/volB/tape.mkv", fingerprint: fp(1), sameRoot: false),
                ScanMergeMoveCandidate(path: "/volA/tape.mkv", fingerprint: fp(1), sameRoot: false),
            ])
        #expect(result == ["/new/tape.mkv": "/volA/tape.mkv"],
                "Equal rank → lexicographically smaller candidate path, deterministically")
    }

    @Test func oneCandidateManyAddedAdoptsExactlyOnce() {
        // Copy-then-delete-original shape: two identical added files, one
        // gone candidate. Exactly ONE adoption (best suffix), the other
        // added file stays unmatched (lands as a normal new record).
        let result = VideoScanModel.matchMovedFiles(
            added: [
                ScanMergeAddedFile(path: "/new/other-name.mkv", fingerprint: fp(1)),
                ScanMergeAddedFile(path: "/new/tape.mkv", fingerprint: fp(1)),
            ],
            candidates: [ScanMergeMoveCandidate(path: "/old/tape.mkv", fingerprint: fp(1), sameRoot: true)])
        #expect(result == ["/new/tape.mkv": "/old/tape.mkv"],
                "One candidate → one adoption, won by the better suffix match")
    }

    @Test func manyToManyAssignsEachCandidateOnce() {
        // Folder reorganize with filename-preserving moves: every added file
        // pairs with the candidate sharing its filename, never double-booked.
        let added = (0..<5).map {
            ScanMergeAddedFile(path: "/root/archive/clip\($0).mov", fingerprint: fp($0))
        }
        let candidates = (0..<5).map {
            ScanMergeMoveCandidate(path: "/root/clip\($0).mov", fingerprint: fp($0), sameRoot: true)
        }
        let result = VideoScanModel.matchMovedFiles(added: added, candidates: candidates)
        #expect(result.count == 5)
        for i in 0..<5 {
            #expect(result["/root/archive/clip\(i).mov"] == "/root/clip\(i).mov")
        }
    }

    @Test func resultIsIndependentOfInputOrder() {
        let added = [
            ScanMergeAddedFile(path: "/new/b/tape.mkv", fingerprint: fp(1)),
            ScanMergeAddedFile(path: "/new/a/tape.mkv", fingerprint: fp(1)),
        ]
        let candidates = [
            ScanMergeMoveCandidate(path: "/old/a/tape.mkv", fingerprint: fp(1), sameRoot: false),
            ScanMergeMoveCandidate(path: "/old/b/tape.mkv", fingerprint: fp(1), sameRoot: false),
        ]
        let forward = VideoScanModel.matchMovedFiles(added: added, candidates: candidates)
        let reversed = VideoScanModel.matchMovedFiles(added: added.reversed(),
                                                      candidates: candidates.reversed())
        #expect(forward == reversed, "The matcher must be deterministic under input reordering")
        #expect(forward == ["/new/a/tape.mkv": "/old/a/tape.mkv",
                            "/new/b/tape.mkv": "/old/b/tape.mkv"],
                "…/a/tape.mkv pairs with …/a/tape.mkv (suffix 2 beats 1)")
    }

    @Test func commonTrailingComponentsCounts() {
        #expect(VideoScanModel.commonTrailingComponents("/a/family/t.mkv", "/b/family/t.mkv") == 2)
        #expect(VideoScanModel.commonTrailingComponents("/a/x/t.mkv", "/b/y/t.mkv") == 1)
        #expect(VideoScanModel.commonTrailingComponents("/a/old.mkv", "/a/new.mkv") == 0)
        #expect(VideoScanModel.commonTrailingComponents("/same/p.mkv", "/same/p.mkv") == 2)
    }

    @Test func blankFingerprintIsNotViable() {
        #expect(!ScanMergeFingerprint(partialMD5: "", sizeBytes: 1234).isViable)
        #expect(!ScanMergeFingerprint(partialMD5: "abc", sizeBytes: 0).isViable)
        #expect(ScanMergeFingerprint(partialMD5: "abc", sizeBytes: 1).isViable)
    }
}
