// OneEngineSensorTests.swift
// GH #143 step 5–6 (docs/design/one_removal_marker_and_trash_engine.md §5):
// sensors that keep ONE Trash engine and ONE removal marker true at the
// source level, plus the audit's T5.
//
//   1. No code moves or removes a file except the reviewed allowlist — every
//      entry names WHY it may (the engine; a door not yet moved, by name;
//      app-owned scratch / partial outputs; non-media files). A new file
//      that calls trashItem/removeItem fails until it is reviewed here; an
//      entry that no longer matches fails too, so the list stays honest.
//   2. `trashItem(` — the Finder Trash itself — only in MediaTrash.move,
//      THE one Trash call every door reaches (plus two People reference-
//      photo deletes, which are not catalog media).
//   3. No code deletes a VideoRecord row from `records` except the
//      catalog-repair allowlist (none of them mean "gone").
//   4. Only the engine writes the removal marker or its legacy mirrors.
//   5. Every RemovalMarker state is reachable from a door.
//   T5. quarantineAndDelete is gone; deleteQuarantined defaults to the Trash.
//
// Dimensions: sensor (source scan, fails closed on an empty scan), logic
// (reachability), isolation (sandbox catalog, ledger and Trash).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("One engine — source sensors and T5 (GH #143)", .serialized)
@MainActor
struct OneEngineSensorTests {

    // MARK: The scan

    /// Per app source file (relative path), how many CODE lines match any of
    /// `patterns`. Comment lines are skipped; a trailing `// …` is cut. Crude
    /// on purpose and fail-safe: a false hit makes the sensor red, never green.
    static func hits(_ patterns: [String]) -> [String: Int] {
        let regexes = patterns.compactMap { try? NSRegularExpression(pattern: $0) }
        var out: [String: Int] = [:]
        for (rel, url) in SourceTree.appSources {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("*") || line.hasPrefix("/*") { continue }
                let code = line.components(separatedBy: " //")[0]
                let range = NSRange(code.startIndex..., in: code)
                if regexes.contains(where: { $0.firstMatch(in: code, range: range) != nil }) {
                    out[rel, default: 0] += 1
                }
            }
        }
        return out
    }

    private func expectMatches(_ found: [String: Int], allowlist: [String: String], _ what: String,
                               sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(SourceTree.appSources.count > 500, "the scan read the app tree", sourceLocation: sourceLocation)
        let unreviewed = Set(found.keys).subtracting(allowlist.keys).sorted()
        #expect(unreviewed.isEmpty, "\(what) in a file nobody reviewed: \(unreviewed)", sourceLocation: sourceLocation)
        let stale = Set(allowlist.keys).subtracting(found.keys).sorted()
        #expect(stale.isEmpty, "allowlist entries that no longer match — remove them: \(stale)", sourceLocation: sourceLocation)
    }

    // MARK: 1. Files leave only through reviewed code

    static let fileRemovalAllowlist: [String: String] = [
        // THE one Trash call. No other production code removes media: the
        // verifier's last unlink went in codex round 1 F1 (GH #143).
        "MediaOps/MediaTrash.swift": "THE one Trash call (every Trash door reaches it)",
        // App-owned scratch, partial outputs, temp files.
        "ArchiveAngel/Prepare/ArchiveAngelJob.swift": "Angel prepare scratch",
        "ArchiveAngel/Prepare/ArchiveAngelPlan.swift": "Angel buffer batch dir, fenced to <buffer>/batch-…",
        "Archive/ArchiveIndexRename.swift": "archive index staging dirs (not media)",
        "Media/AudioTranscriber.swift": "transcriber temp dir",
        "Media/CaptionRunner.swift": "caption temp frames",
        "Media/PerceptualFingerprinter.swift": "fingerprint temp file",
        "Media/ReviewThumbnailRenderer.swift": "thumbnail temp PNG",
        "Media/VideoScanModel+ProbeEngine.swift": "probe temp file",
        "MediaOps/BalanceAudioJob.swift": "its own partial output",
        "MediaOps/CleanupJob.swift": "its own scratch dir and partial output",
        "MediaOps/FootageSpectrumHelper.swift": "Spectrum run output",
        "MediaOps/RebuildAudioJob.swift": "its own partial output",
        "MediaOps/RelocateEngine.swift": "Migrate's own partial copy at the destination",
        "MediaOps/TrimJob.swift": "its own partial output",
        "MediaOps/VideoScanModel+Combine.swift": "Combine temp dir",
        "People/PersonFinderCompilation.swift": "compiled clips and work dirs",
        "People/FindPersonJob.swift": "clip list temp file",
        // App data, not catalog media.
        "App/BundleExporter.swift": "export bundle it is about to rewrite",
        "App/BundleImporter.swift": "import temp",
        "Catalog/CatalogStore.swift": "catalog backup rotation",
        "Catalog/CatalogSync.swift": "sync staging dirs",
        "Catalog/CatalogWriteError.swift": "rotated error log",
        "FamilyTree/CouplePortrait.swift": "portrait cache",
        "FamilyTree/FamilyAssetStore.swift": "asset store destination",
        "FamilyTree/FamilySearchPullCoordinator.swift": "pull staging",
        "Hallie/HalliePhotoImport.swift": "picked-photo temp",
        "Hallie/Voice/HallieNeuralSpeech.swift": "speech output dirs",
        "Hallie/Voice/HalliePronunciationLexicon.swift": "lexicon staging",
        "Hallie/Web/HallieWebPoster.swift": "web partials",
        "Hallie/Web/HallieWebProxy.swift": "web partials",
        "People/AdaFaceEngine.swift": "model download",
        "People/ArcFaceEngine.swift": "model download",
        "People/FamilyEditSheet.swift": "own temp copy",
        "People/FamilyGroup.swift": "reference photos (to the Trash)",
        "People/IdentifyFamilyModel.swift": "idempotent model copy",
        "People/POIProfileFileStore.swift": "profile staging and link",
        "People/POIStorage.swift": "POI temp",
        "People/PersonEditSheet.swift": "reference photo (to the Trash)",
        "People/RecipeGenderAgeGate.swift": "model copy",
        "Volumes/ScanCheckpoint.swift": "scan checkpoint file",
        "Volumes/ScanJobsStorage.swift": "scan job files",
    ]

    @Test func noFileLeavesExceptThroughReviewedCode() {
        expectMatches(Self.hits([#"trashItem\("#, #"removeItem\("#]), allowlist: Self.fileRemovalAllowlist,
                      "trashItem/removeItem")
    }

    // MARK: 2. The Finder Trash itself

    static let trashItemAllowlist: [String: String] = [
        "MediaOps/MediaTrash.swift": "THE one Trash call",
        "People/FamilyGroup.swift": "reference photos, not catalog media",
        "People/PersonEditSheet.swift": "reference photo, not catalog media",
    ]

    @Test func onlyTheOneTrashCallUsesTheFinderTrash() {
        expectMatches(Self.hits([#"trashItem\("#]), allowlist: Self.trashItemAllowlist, "trashItem")
        // Every media Trash door reaches it.
        for (file, call) in [("VideoScanModel+JunkDelete.swift", "try MediaTrash.move(url).path"),
                             ("DeleteDuplicatesJob.swift", "try MediaTrash.move(url)"),
                             ("SignatureVerification.swift", "(hooks.trashItem ?? MediaTrash.move)(original)"),
                             ("DerivativeOutputPublish.swift", "try MediaTrash.move(url)")] {
            let code = (try? SourceTree.appCode(named: file)) ?? ""
            #expect(code.contains(call), "\(file) no longer goes through MediaTrash.move")
        }
    }

    // MARK: 3. Rows are never deleted when a file leaves

    static let rowRemovalAllowlist: [String: String] = [
        "Volumes/VideoScanModel+ScanMerge.swift": "re-seen replacement; prune of ACTIVE rows whose file is gone (marker rows exempt, #143 b)",
        "Volumes/VideoScanModel+DeleteScanTarget.swift": "Forget a volume's records — explicit, confirmed catalog repair",
        "MediaOps/VideoScanModel+NonVideoMediaPurge.swift": "catalog scope: non-video rows, files untouched",
        "MediaOps/VideoScanModel+CoverArtMusicPurge.swift": "catalog scope: cover-art music rows, files untouched",
        "MediaOps/VideoScanModel+UnrelatedAudioPurge.swift": "catalog scope: unrelated audio rows, files untouched",
        "MediaOps/VideoScanModel+MissingAudio.swift": "undo of the probe row it appended itself",
        "Model/VideoScanModel.swift": "clear all results / reload",
    ]

    @Test func noRowIsDeletedOutsideCatalogRepair() {
        expectMatches(Self.hits([#"\brecords\.remove\("#, #"\brecords\.removeAll\b"#, #"\brecords\.removeFirst\b"#,
                                 #"\brecords\.removeLast\b"#, #"\brecords\s*=\s*records\.filter\b"#]),
                      allowlist: Self.rowRemovalAllowlist, "a records row removal")
        // T4's door specifically: Delete Duplicates' settle keeps the row.
        let settle = (try? SourceTree.appCode(named: "VideoScanModel+Duplicates.swift")) ?? ""
        #expect(!settle.isEmpty && !settle.contains("records.remove"), "Delete Duplicates deletes a row again")
    }

    // MARK: 4. One writer of the marker and its legacy mirrors

    static let markerWriterAllowlist: [String: String] = [
        "MediaOps/VideoScanModel+RemovalMarker.swift": "THE engine's catalog half",
        "Catalog/VideoScanModel+RescanPreservation.swift": "carries the existing marker across a rescan (no new state)",
        "ArchiveAngel/Review/VideoScanModel+ArchiveAngelBufferHygiene.swift": "an unrelated `removal` Task field",
    ]

    @Test func onlyTheEngineWritesTheMarker() {
        expectMatches(Self.hits([#"\.removal\s*=[^=]"#, #"\.purgedAt\s*=[^=]"#,
                                 #"lifecycleStage\s*=\s*\.trashed\b"#, #"lifecycleStage\s*=\s*\.deletedPermanently\b"#]),
                      allowlist: Self.markerWriterAllowlist, "a removal-marker / purgedAt / Trashed write")
    }

    /// The marker's write counter (codex r2 2026-10-16 F4): ONLY the engine
    /// bumps it (`+= 1`, on a change of the marker); the rescan carry copies
    /// it with the marker, nothing else assigns it.
    static let revisionBumpAllowlist: [String: String] = [
        "MediaOps/VideoScanModel+RemovalMarker.swift": "THE engine bumps it on every change of the marker",
    ]
    static let revisionCarryAllowlist: [String: String] = [
        "Catalog/VideoScanModel+RescanPreservation.swift": "carries the revision with the marker across a rescan (no bump)",
    ]

    @Test func onlyTheEngineBumpsTheRemovalRevision() {
        expectMatches(Self.hits([#"\bremovalRevision\s*(\+=|-=|\+\+|--)"#]), allowlist: Self.revisionBumpAllowlist, "a removalRevision bump")
        expectMatches(Self.hits([#"\bremovalRevision\s*=[^=]"#]), allowlist: Self.revisionCarryAllowlist, "a removalRevision assignment")
        let engine = (try? SourceTree.appCode(named: "VideoScanModel+RemovalMarker.swift")) ?? ""
        #expect(engine.components(separatedBy: "removalRevision += 1").count == 4, "stamp (on change), clear (on change), revert — three bumps")
        #expect(engine.contains("if rec.removal != marker { rec.removalRevision += 1 }"), "an identical re-stamp is not a change")
        #expect(engine.contains("if rec.removal != nil { rec.removalRevision += 1 }"), "Restore of a live row is not a change")
        #expect(engine.contains("guard rec.removal == wrote, rec.removalRevision == revision else { return false }"), "revert is value AND revision")
    }

    // MARK: 5. Every state is reachable from a door

    @Test func everyRemovalStateIsReachableFromADoor() async throws {
        #expect(RemovalMarker.State.allCases.count == 3, "a new state needs a door pinned here")
        let sb = try JunkTrashSandbox("states"); defer { sb.cleanup() }
        let model = sb.model()
        let present = sb.junk(try sb.write("test_present.mov"))
        let gone = sb.junk(sb.files.appendingPathComponent("test_gone.mov"))   // never written
        let kept = sb.junk(try sb.write("test_kept.mov", fill: 0x22))
        model.records = [present, gone, kept]

        _ = await model.trashSelectedRecords([present, gone], fileOperation: sb.trash.operation)
        _ = model.purgeRecords(ids: [kept.id])

        #expect(present.removal?.state == .inTrash, "⌘⌫ → In the Trash")
        #expect(gone.removal?.state == .missing, "a file already gone at its turn → Missing")
        #expect(kept.removal?.state == .removedFromCatalog, "Remove from Catalog → Removed")
        #expect(FileManager.default.fileExists(atPath: kept.fullPath))
        let reached = Set([present, gone, kept].compactMap { $0.removal?.state })
        #expect(reached == Set(RemovalMarker.State.allCases))
        #expect(model.records.count == 3, "no door deleted a row")
    }

    // MARK: T5 — Trash only in the verifier

    @Test func quarantineAndDeleteIsGoneAndTheDefaultDisposalIsTheTrash() throws {
        let code = try SourceTree.appCode(named: "SignatureVerification.swift")
        #expect(!code.contains("func quarantineAndDelete"), "the permanent-unlink convenience is back")
        #expect(code.contains("disposal: Disposal = .trash"), "deleteQuarantined's default must be the Trash")
    }

    @Test func aQuarantinedDuplicateWithNoDisposalNamedGoesToTheTrash() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_charter_never_unlink_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let size = FileHasher.segmentSize + 333
        let bytes = Data((0..<size).map { UInt8($0 % 251) })
        let keeper = dir.appendingPathComponent("keeper.mov"); try bytes.write(to: keeper)
        let copy = dir.appendingPathComponent("copy.mov"); try bytes.write(to: copy)
        var hooks = SignatureVerification.Hooks(shouldCancel: { false }, didReadBlock: { _ in })
        let fakeTrash = dir.appendingPathComponent("Trash", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeTrash, withIntermediateDirectories: true)
        hooks.trashItem = { url in
            let dest = fakeTrash.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: dest); return dest
        }
        let proof = try SignatureVerification.verify(keeperPath: keeper.path, duplicatePath: copy.path,
                                                     hooks: hooks).get()
        guard case .quarantined(let ticket) = SignatureVerification.quarantine(proof, hooks: hooks) else {
            Issue.record("fixture: the copy was not quarantined"); return
        }
        let result = SignatureVerification.deleteQuarantined(ticket, hooks: hooks)   // no disposal named
        #expect(result != .deleted(bytes: Int64(size)), "unlinked outright — the app is Trash only")
        #expect(FileManager.default.fileExists(atPath: fakeTrash.appendingPathComponent("copy.mov").path))
        #expect(FileManager.default.fileExists(atPath: keeper.path))
    }
}
