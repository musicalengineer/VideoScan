// ArchiveAngelPlan+Follow.swift
// A prepared row follows its catalog record through a rename.
//
// Rick 2026-09-10: "View AA files, click Show in Catalog, rename, come back
// to AA and see the refreshed name … this is how a user might do it so it
// seems we ought to allow this." The record id is the identity; the path
// is where the file lives right now. A row is followed to the record's
// new path only when the file there is byte-for-byte what was prepared
// (same size; same content hash when both sides know one). Anything else
// is left alone for the identity re-check to refuse with a reason.
//
// The proposed archive name tracks the new filename unless the user typed
// one in the sheet (`userEditedName`), in which case their word stands.

import Foundation

extension ArchiveAngelPlan {

    /// What the follow needs from the catalog record — a value, so the
    /// decision is pure and table-testable.
    struct FollowFacts: Equatable, Sendable {
        var fullPath: String
        var filename: String
        var sizeBytes: Int64
        var contentHash: String
        /// The name the naming rule proposes for the record as it is now.
        var proposedName: String
    }

    enum FollowOutcome: Equatable, Sendable {
        case unchanged
        case followed(from: String, to: String)
        case refused(String)
    }

    /// Pure. `fileSizeAtNewPath` = the size of the file at
    /// `record.fullPath` (resolved), nil when nothing is there.
    static func follow(_ entry: inout Entry, record: FollowFacts,
                       fileSizeAtNewPath: Int64?) -> FollowOutcome {
        guard entry.status == .ready else { return .unchanged }
        if VideoScanModel.samePath(record.fullPath, entry.sourcePath), record.filename == entry.filename {
            return .unchanged
        }
        guard let sizeNow = fileSizeAtNewPath else {
            return .refused("The record moved to \(record.fullPath) but no file is there")
        }
        guard sizeNow == entry.sizeBytes, record.sizeBytes == entry.sizeBytes else {
            return .refused("The record moved to \(record.fullPath) but that file is not the one prepared "
                            + "(\(entry.sizeBytes) → \(sizeNow) bytes)")
        }
        if !entry.sourceContentHash.isEmpty, !record.contentHash.isEmpty,
           entry.sourceContentHash != record.contentHash {
            return .refused("The record moved to \(record.fullPath) but its content hash differs from the prepared file")
        }
        let from = entry.sourcePath
        entry.sourcePath = record.fullPath
        entry.filename = record.filename
        if entry.userEditedName != true {
            entry.proposedName = record.proposedName
        }
        return .followed(from: from, to: record.fullPath)
    }
}

extension ArchiveAngelPromoter {

    /// Follow every ready row to its record's current path. Returns the
    /// log lines for rows that moved or could not be followed; the caller
    /// saves the plan when anything changed. Main actor: reads records.
    @MainActor
    @discardableResult
    static func followRenames(plan: inout ArchiveAngelPlan, model: VideoScanModel,
                              fileManager fm: FileManager = .default) -> [String] {
        var lines: [String] = []
        for i in plan.entries.indices where plan.entries[i].status == .ready {
            guard let rec = model.record(forID: plan.entries[i].id) else { continue }
            let facts = ArchivePathResolver.facts(for: rec)
            let people = rec.confirmedByUserPeople.map(\.name) + rec.detectedPeople
            let record = ArchiveAngelPlan.FollowFacts(
                fullPath: rec.fullPath, filename: rec.filename, sizeBytes: rec.sizeBytes,
                contentHash: rec.contentHash,
                proposedName: ArchiveAngelNaming.proposedName(facts: facts, people: people, tags: rec.tags))
            let resolved = URL(fileURLWithPath: rec.fullPath).resolvingSymlinksInPath().path
            let size = ((try? fm.attributesOfItem(atPath: resolved))?[.size] as? NSNumber)?.int64Value
            switch ArchiveAngelPlan.follow(&plan.entries[i], record: record, fileSizeAtNewPath: size) {
            case .unchanged: break
            case .followed(let from, let to):
                let line = "Archive Angel: \(plan.entries[i].filename) was renamed in the catalog — following "
                    + "\((from as NSString).lastPathComponent) → \((to as NSString).lastPathComponent)"
                plan.log.append(line)
                lines.append(line)
            case .refused(let why):
                let line = "Archive Angel: \(plan.entries[i].filename) not followed — \(why)"
                plan.log.append(line)
                lines.append(line)
            }
        }
        return lines
    }
}
