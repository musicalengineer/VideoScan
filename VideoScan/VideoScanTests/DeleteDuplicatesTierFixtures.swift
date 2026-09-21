// DeleteDuplicatesTierFixtures.swift
// Shared fixtures for the Delete Duplicates suites since the copy-count
// tier (Rick 2026-09-20 evening): a duplicate is only removed when its
// family keeps a fixity-verified Master Archive copy, and only removed
// OUTRIGHT when three or more verified copies remain. Every suite that
// expects a permanent deletion gives the keeper's family both — one
// helper, one line per fixture — so the old assertions still describe the
// old behaviour, and the tier suite exercises the other rungs on purpose.
//
// The Trash rung moves files with FileManager.trashItem in production;
// tests route it into a scratch folder so no fixture ever lands in Rick's
// real Trash.

import CryptoKit
import Foundation
import VideoScanCore
@testable import VideoScan

/// Give `keeper`'s family what the tier needs for a PERMANENT deletion:
/// a fixity-verified archive copy of the keeper's bytes (an
/// `archivePromotion` derivative of the keeper with `archiveFixity` AND
/// the stamp-bound `contentFixity` Verify Archive Copies writes — since
/// codex 1606 #1 an archive copy counts only through that, like any
/// sibling) and, by default, one more verified member of the same
/// duplicate group (a `.review` row with a stored ContentFixity) — so
/// archive + keeper + sibling = 3 verified copies remain after any extra
/// goes. Files are written beside the keeper (or in `directory`). Both
/// records are appended to `model.records`.
@MainActor
@discardableResult
func addVerifiedArchiveFamily(to model: VideoScanModel, keeper: VideoRecord, in directory: URL? = nil,
                              withSibling: Bool = true) -> (archive: VideoRecord, sibling: VideoRecord?) {
    let dir = directory
        ?? URL(fileURLWithPath: (keeper.fullPath as NSString).deletingLastPathComponent, isDirectory: true)
    let bytes = (try? Data(contentsOf: URL(fileURLWithPath: keeper.fullPath))) ?? Data([0])
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    let base = keeper.filename.isEmpty ? "keeper.mov" : keeper.filename

    let archiveURL = dir.appendingPathComponent("archive-of-\(base)")
    FileManager.default.createFile(atPath: archiveURL.path, contents: bytes)
    let archive = VideoRecord()
    archive.fullPath = archiveURL.path
    archive.filename = archiveURL.lastPathComponent
    archive.directory = dir.path
    archive.sizeBytes = Int64(bytes.count)
    archive.derivedFrom = keeper.id
    archive.derivationKind = ArchivePromotion.derivationKind
    archive.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(), sizeBytes: Int64(bytes.count))
    archive.contentFixity = ContentFixity.captured(path: archiveURL.path, digest: digest, byteCount: Int64(bytes.count))
    model.records.append(archive)

    var sibling: VideoRecord?
    if withSibling {
        let siblingURL = dir.appendingPathComponent("verified-sibling-of-\(base)")
        FileManager.default.createFile(atPath: siblingURL.path, contents: bytes)
        let s = VideoRecord()
        s.fullPath = siblingURL.path
        s.filename = siblingURL.lastPathComponent
        s.directory = dir.path
        s.sizeBytes = Int64(bytes.count)
        s.partialMD5 = keeper.partialMD5
        s.durationSeconds = keeper.durationSeconds
        s.duplicateGroupID = keeper.duplicateGroupID
        s.duplicateDisposition = .review
        s.duplicateConfidence = .high
        s.contentFixity = ContentFixity.captured(path: siblingURL.path, digest: digest, byteCount: Int64(bytes.count))
        model.records.append(s)
        sibling = s
    }
    return (archive, sibling)
}

/// The Trash step for tests: move the file into `dir/Trash` and return
/// where it went.
func scratchTrash(in dir: URL) -> (URL) throws -> URL {
    let trash = dir.appendingPathComponent("Trash", isDirectory: true)
    return { file in
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var destination = trash.appendingPathComponent(file.lastPathComponent)
        var n = 2
        while FileManager.default.fileExists(atPath: destination.path) {
            destination = trash.appendingPathComponent("\(file.deletingPathExtension().lastPathComponent) \(n).\(file.pathExtension)")
            n += 1
        }
        try FileManager.default.moveItem(at: file, to: destination)
        return destination
    }
}

extension SignatureVerification.Hooks {
    /// The same hooks with the Trash step routed into `dir/Trash`.
    func withScratchTrash(in dir: URL) -> SignatureVerification.Hooks {
        var copy = self
        copy.trashItem = scratchTrash(in: dir)
        return copy
    }
}
