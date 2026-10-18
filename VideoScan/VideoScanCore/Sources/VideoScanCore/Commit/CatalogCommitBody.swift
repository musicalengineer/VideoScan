// CatalogCommitBody.swift
// The body of one commit's write (cutover B2; CatalogCommit.swift says what
// a commit is). Runs on the store's queue inside `repository.write`; talks
// to the store only through `CatalogTransaction`'s doors, so no SQL and no
// GRDB type appears here.
//
// Per record (its own savepoint): insert or update the `files` row, the
// tombstone FIRST when the removal marker moved (the DDL refuses the marker
// change without it), the row's archive copy / backups / footage decisions /
// duplicate member / sound print when they differ, the display row + one
// `row_knowledge` row per curated field that differs, the row-scoped values
// and the pair link, and the bound rows of each derived kind that differs
// (each kind in a nested savepoint: derived values are regenerable, so a
// value the bound table cannot hold is left out with words, not a refusal
// of the whole row).
//
// (For Rick: the unit of work's apply loop; each `try` that throws inside a
// savepoint rolls back that one record and becomes its `.refused` words.)

import Foundation

struct CatalogCommitBody {
    let plan: CatalogCommit.Plan
    let tx: any CatalogTransaction
    let ledger: CatalogCommitLedger

    private var source: String { CatalogRow.RowKnowledge.appSource(plan.door) }

    /// Thrown when nothing landed, so no empty generation is committed.
    struct NothingLanded: Error, CustomStringConvertible {
        var description: String { "nothing in this commit differed from catalog.sqlite or could be stored" }
    }

    /// The designation guard (GH #167), carried over from catalog.json.
    struct DesignationLossRefused: Error, CustomStringConvertible {
        var description: String {
            "the Master Archive designation would be removed without Clear Master Archive — refused; catalog.sqlite keeps it (GH #167)"
        }
    }

    func run() throws {
        var landed = 0
        for item in plan.items {
            let row = commit(item)
            if row.landing.landed { landed += 1 }
            ledger.record(row)
        }
        let designationLanded = try writeDesignation()
        guard landed > 0 || designationLanded else {
            ledger.noteNothingLanded()
            throw NothingLanded()
        }
    }

    // MARK: - One record

    private func commit(_ item: CatalogCommit.Item) -> CatalogCommit.RowResult {
        var result = CatalogCommit.RowResult(id: item.id, fingerprint: item.fingerprint, digest: nil, landing: .unchanged)
        let current: CatalogRecordDTO
        do {
            current = try CatalogRecordDTO(snapshot: item.snapshot, migrationLoadedAt: plan.now)
        } catch {
            result.landing = .refused("the record could not be mapped to catalog rows: \(error)")
            return result
        }
        switch current.digestState {
        case .none:
            result.landing = .deferred(CatalogCommitWords.noDigest)
            return result
        case .disagree(let digests):
            result.landing = .refused("its two whole-file hashes disagree (\(digests.joined(separator: " vs "))) — Verify the file before it can be stored")
            return result
        case .known(let digest, _):
            result.digest = digest
            result.landing = landing(current, digest: digest)
            return result
        }
    }

    private func landing(_ current: CatalogRecordDTO, digest: String) -> CatalogCommit.Landing {
        do {
            let stored = try storedDTO(id: current.file.id)
            if let was = stored?.digestState.digest, was != digest {
                return .refused(CatalogCommitWords.digestChanged(from: was, to: digest))
            }
            let diff = CatalogRecordDiff(stored: stored, current: current)
            if diff.isEmpty { return .unchanged }
            var notes: [String] = []
            try tx.inSavepoint {
                notes = try write(current, digest: digest, stored: stored, diff: diff)
            }
            return .written(curated: diff.knowledge.filter(CatalogCommitWords.sharedByCopies.contains), notes: notes)
        } catch {
            return .refused(CatalogCommitWords.engine(error))
        }
    }

    /// The stored row as the DTO a record loaded from it would give.
    private func storedDTO(id: String) throws -> CatalogRecordDTO? {
        guard let row = try tx.storedRow(id: id) else { return nil }
        let record = try VideoRecord(loaded: row)
        // A live record's partner is an object; the encoder writes its id.
        if let partner = record.pendingPairedWithID { record.pairedWith = VideoRecord(id: partner) }
        return try CatalogRecordDTO(record: record, migrationLoadedAt: plan.now)
    }

    private func write(_ current: CatalogRecordDTO, digest: String, stored: CatalogRecordDTO?,
                       diff: CatalogRecordDiff) throws -> [String] {
        let id = current.file.id
        if let stored {
            if diff.file || diff.marker { try updateRow(current, stored: stored, diff: diff) }
        } else {
            try insertRow(current)
        }
        var notes: [String] = []
        if diff.archiveCopy { try tx.replaceArchiveCopy(fileID: id, current.archiveCopy) }
        if diff.backups { try tx.replaceBackupDestinations(fileID: id, current.backupDestinations) }
        if diff.footageDecisions { try tx.replaceFootageDecisions(rowID: id, digest: digest, current.curated.footageDecisions) }
        if diff.duplicate, let words = try tx.replaceDuplicateMember(fileID: id, current.duplicateMember) { notes.append(words) }
        if diff.soundPrint { try tx.replaceSoundPrint(digest: digest, current.soundPrint) }
        try writeKnowledge(current, digest: digest, fields: diff.knowledge)
        if diff.pair {
            try tx.appendRowKnowledge(CatalogRow.RowKnowledge(fileID: id, digest: digest, field: CatalogLiveWritesSchema.pairField,
                                                              value: current.pairLink?.linkValue ?? .object([:]),
                                                              setAt: plan.now, source: source))
        }
        notes += writeDerived(current, digest: digest, kinds: diff.derived)
        return notes
    }

    private func insertRow(_ current: CatalogRecordDTO) throws {
        guard let content = current.content else { throw CatalogCommitWords.Refusal(CatalogCommitWords.noDigest) }
        var fresh = content
        fresh.firstSeenHow = .job          // first seen by the app after the port, not by the import
        try tx.upsertVolume(current.volume)
        try tx.ensureContent(fresh)
        let caseSensitive = try tx.volumeCaseSensitive(current.volume.volumeUUID)
        try tx.insertFile(OccurrenceWriter.storable(current.file), volumeCaseSensitive: caseSensitive)
    }

    /// The tombstone FIRST when the marker moved (the DDL checks it names
    /// the new revision and the new marker), then the columns.
    private func updateRow(_ current: CatalogRecordDTO, stored: CatalogRecordDTO, diff: CatalogRecordDiff) throws {
        if diff.marker {
            try appendTombstone(current.file, storedRevision: stored.file.removalRevision)
        }
        try tx.upsertVolume(current.volume)
        try tx.updateFile(OccurrenceWriter.storable(current.file), markerChanged: diff.marker)
    }

    private func appendTombstone(_ file: CatalogRecordDTO.FileRow, storedRevision: Int) throws {
        guard file.removalRevision == storedRevision + 1 else {
            throw CatalogCommitWords.Refusal(CatalogCommitWords.markerJump(stored: storedRevision, now: file.removalRevision))
        }
        try tx.insertTombstone(CatalogRow.Tombstone(
            fileID: file.id, revision: file.removalRevision,
            state: file.removalState.flatMap(CatalogDDL.RemovalState.init(rawValue:)), since: file.removalSince,
            reason: file.removalReason, trashPath: file.removalTrashPath, trashEmptiedAt: file.removalTrashEmptiedAt,
            lastSeen: file.removalLastSeen, writtenAt: plan.now, door: source))
    }

    /// Display rows for the content (per-content fields), then one
    /// `row_knowledge` row per field that differs (JSON null = cleared).
    private func writeKnowledge(_ current: CatalogRecordDTO, digest: String, fields: [CatalogDDL.KnowledgeField]) throws {
        for field in fields {
            try tx.writeDisplayValue(digest: digest, field: field, current.curated, setAt: plan.now)
            try tx.appendRowKnowledge(CatalogRow.RowKnowledge(
                fileID: current.file.id, digest: digest, field: field.rawValue,
                value: CatalogRecordDTO.knowledgeValue(field, raw: current.raw) ?? .null, setAt: plan.now, source: source))
        }
    }

    /// Each differing kind in its own savepoint; a kind the bound table
    /// cannot hold is left as it was and named.
    private func writeDerived(_ current: CatalogRecordDTO, digest: String, kinds: [CatalogDDL.DerivedKind]) -> [String] {
        var notes: [String] = []
        for kind in kinds {
            do {
                try tx.inSavepoint {
                    try tx.replaceDerived(digest: digest, kind: kind, current.derivedUnverified.filter { $0.kind == kind })
                }
            } catch {
                notes.append("derived \(kind.rawValue) not stored: \(CatalogCommitWords.engine(error))")
            }
        }
        return notes
    }

    // MARK: - The designation

    private func writeDesignation() throws -> Bool {
        guard case .current(let json, let clearAuthorized) = plan.designation else { return false }
        let stored = try tx.masterArchiveJSON()
        guard !Self.sameJSON(stored, json) else { return false }
        if stored != nil, json == nil, !clearAuthorized { throw DesignationLossRefused() }
        try tx.setMasterArchive(json: json)
        return true
    }

    static func sameJSON(_ a: String?, _ b: String?) -> Bool {
        switch (a, b) {
        case (nil, nil): return true
        case (let x?, let y?): return CatalogJSONValue.parse(x) == CatalogJSONValue.parse(y)
        default: return false
        }
    }
}

/// The words a commit speaks (one place, so tests and the app quote them).
enum CatalogCommitWords {

    struct Refusal: Error, CustomStringConvertible {
        let description: String
        init(_ words: String) { description = words }
    }

    static let noDigest = "no whole-file hash yet — catalog.sqlite keeps a row only for content it can name; "
        + "it is stored once Compute Full Hashes (or the next scan, batch B3) gives it one"

    static func digestChanged(from was: String, to now: String) -> String {
        "its whole-file hash changed (\(was.prefix(12))… → \(now.prefix(12))…): a replaced file is a new row, "
            + "and the rescan (batch B3) records it — the stored row is unchanged"
    }

    static func markerJump(stored: Int, now: Int) -> String {
        "its removal marker changed \(now - stored) times within one save (revision \(stored) → \(now)); "
            + "catalog.sqlite records each change with its own tombstone and cannot invent the one in between, "
            + "so this row is not saved (its file is untouched; the other rows are saved)"
    }

    static func engine(_ error: Error) -> String {
        String(describing: error)
    }

    /// The curated fields every copy of one content shows (the display
    /// tables are keyed by digest).
    static let sharedByCopies: Set<CatalogDDL.KnowledgeField> = [
        .userNotes, .tags, .mediaDisposition, .starRating, .confirmedByUserPeople, .rejectedPeople,
        .userDate, .userDateConfidence, .userPlace, .userPlaceConfidence, .backupAttestations, .familyMusic,
    ]
}
