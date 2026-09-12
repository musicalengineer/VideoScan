// VideoScanModel+BackupAttestations.swift
// The model half of the backup attestations (Rick 2026-09-12, promote-
// and-prune stage 1; the pure model is BackupAttestation.swift in
// VideoScanCore):
//
//   - `recordAttestation(kind:answer:label:by:at:for:)` — the ONE write
//     path. Replaces the same-kind answer on each record, journals one
//     line per record in the archive's attestation journal
//     ("attestation cloud=yes 'iCloud' by rick"), logs it, and posts a
//     RECORD-SCOPED catalog-mutation notification per record (the same
//     shape InspectorPlaceView uses) so the search index, the debounced
//     save and the chrome caches refresh. No UI calls it yet — the
//     "Archived — what next?" sheet is stage 2.
//   - `ArchiveAttestationJournal` — `00_Index/.attestation_journal.jsonl`
//     beside the promote journal: append-only JSONL, one entry per record
//     per answer, written through the same descriptor-relative durable
//     path Promote uses. Best effort: an offline or undesignated archive
//     never blocks an attestation (the catalog record is the truth; the
//     journal is the audit trail). The Media Ledger (design amendment 2)
//     will fold these lines in; it is NOT built here.
//   - `protectionSummary(for:)` — the protection line for a Promote
//     BATCH: groups the batch's records with every same-content copy in
//     the catalog (one pass over `records`), builds `CopyFacts` and hands
//     them to the pure `ProtectionSummary`. Never called per table row.
//
// Isolation: the journal root is the model's designated archive root —
// tests inject a sandbox designation; nothing here ever names a real
// volume path.

import Foundation

// MARK: - Attestation journal (00_Index/.attestation_journal.jsonl)

enum ArchiveAttestationJournal {
    static let filename = ".attestation_journal.jsonl"

    struct Entry: Codable, Equatable, Sendable {
        let at: Date
        let recordID: UUID
        let filename: String
        let fullPath: String
        let kind: String
        let answer: String
        let label: String?
        let by: String
        /// The human line: "attestation cloud=yes 'iCloud' by rick".
        let line: String

        init(at: Date, record: (id: UUID, filename: String, fullPath: String), attestation a: BackupAttestation) {
            self.at = at
            self.recordID = record.id
            self.filename = record.filename
            self.fullPath = record.fullPath
            self.kind = a.kind.rawValue
            self.answer = a.answer.rawValue
            self.label = a.label
            self.by = a.by
            self.line = a.journalLine
        }
    }

    static func url(rootPath: String) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Append one entry: descriptor-relative open under `00_Index/`
    /// (O_NOFOLLOW, regular file, created on first use), one O_APPEND
    /// write + fsync. Throws when the root is unreachable — the caller
    /// logs and moves on.
    /// (`nonisolated` ≈ a free function: safe off the main actor.)
    nonisolated static func append(_ entry: Entry, rootPath: String) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(entry)
        data.append(0x0A)
        let fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: false)
        defer { close(fd) }
        try ArchivePromoteEngine.appendDurable(fd: fd, data: data, full: false, label: "attestation journal append")
    }

    /// Every entry, in file order. Unparseable lines are skipped; a
    /// missing journal is simply empty.
    nonisolated static func entries(rootPath: String) -> [Entry] {
        let fd: Int32
        do {
            fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: true)
        } catch {
            return []
        }
        defer { close(fd) }
        guard let data = try? ArchivePromoteEngine.readAll(fd: fd),
              let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Entry.self, from: d)
        }
    }
}

// MARK: - Model

extension VideoScanModel {

    /// Record the user's word for `recordIDs`: `kind` = `answer`, with an
    /// optional label ("iCloud", "Tim's house"). Replaces the same-kind
    /// answer on each record (history is the journal's job), journals one
    /// line per record, and posts one record-scoped mutation per record.
    /// Unknown ids are skipped. Returns the records that were written.
    @MainActor
    @discardableResult
    func recordAttestation(kind: BackupAttestation.Kind,
                           answer: BackupAttestation.Answer,
                           label: String? = nil,
                           by: String = "rick",
                           at: Date = Date(),
                           for recordIDs: [UUID]) -> [VideoRecord] {
        var changed: [VideoRecord] = []
        var journalFailures = 0
        let root = masterArchiveRootPath
        for id in recordIDs {
            guard let rec = record(forID: id) else { continue }
            let attestation = BackupAttestation(kind: kind, answer: answer, label: label, attestedAt: at, by: by)
            rec.backupAttestations = BackupAttestation.replacing(rec.backupAttestations, with: attestation)
            changed.append(rec)
            if let root {
                do {
                    try ArchiveAttestationJournal.append(
                        ArchiveAttestationJournal.Entry(at: at, record: (rec.id, rec.filename, rec.fullPath),
                                                        attestation: attestation),
                        rootPath: root)
                } catch {
                    journalFailures += 1
                }
            }
            appLog.write("attestation: \(rec.filename) — \(attestation.journalLine)")
        }
        if journalFailures > 0 {
            appLog.write("attestation: \(journalFailures) journal line(s) not written (archive root unreachable); catalog records updated")
        }
        for rec in changed {
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: rec)
        }
        return changed
    }

    // MARK: Protection summary (per batch)

    /// The protection line for a Promote batch. ONE pass over `records`
    /// groups every same-content copy (segmented `contentHash`, plus the
    /// promote link for archive copies) into families keyed by the
    /// batch's records; `isOnline` is injectable so tests never touch a
    /// volume. Worst case: O(records) time, one small `CopyFacts` per
    /// record in the touched families.
    @MainActor
    func protectionSummary(for recordIDs: [UUID],
                           isOnline: (VideoRecord) -> Bool = { VolumeReachability.isReachable(path: $0.fullPath) }) -> ProtectionSummary {
        let families = Self.protectionFamilies(batch: Set(recordIDs), catalog: records,
                                               isArchiveCopy: { $0.derivationKind == ArchivePromotion.derivationKind },
                                               isOnline: isOnline)
        return ProtectionSummary.summarize(families: families)
    }

    /// Pure grouping (main-actor because `VideoRecord` is not Sendable):
    /// family key = the record's non-empty `contentHash`, else its id; an
    /// archive copy joins its promotion source's family. Only families
    /// containing a batch record are returned, in a stable order.
    @MainActor
    static func protectionFamilies(batch: Set<UUID>,
                                   catalog: [VideoRecord],
                                   isArchiveCopy: (VideoRecord) -> Bool,
                                   isOnline: (VideoRecord) -> Bool) -> [[ProtectionSummary.CopyFacts]] {
        guard !batch.isEmpty else { return [] }
        // Pass 1: key every record by content (or identity).
        var keyByID: [UUID: String] = [:]
        keyByID.reserveCapacity(catalog.count)
        for r in catalog {
            keyByID[r.id] = r.contentHash.isEmpty ? "i:\(r.id.uuidString)" : "h:\(r.contentHash)"
        }
        // Pass 2: an archive copy takes its source's key when the two
        // would otherwise split (a source hashed over SMB is often empty).
        for r in catalog where isArchiveCopy(r) {
            if let src = r.derivedFrom, let k = keyByID[src] { keyByID[r.id] = k }
        }
        var wanted: [String: Int] = [:]   // family key → output index
        var families: [[ProtectionSummary.CopyFacts]] = []
        for id in batch.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let k = keyByID[id], wanted[k] == nil else { continue }
            wanted[k] = families.count
            families.append([])
        }
        guard !wanted.isEmpty else { return [] }
        for r in catalog {
            guard let k = keyByID[r.id], let idx = wanted[k] else { continue }
            if r.isPurged { continue }
            let archive = isArchiveCopy(r)
            let volume = r.volumeName.isEmpty ? VolumeReachability.volumeName(forPath: r.fullPath) : r.volumeName
            families[idx].append(ProtectionSummary.CopyFacts(
                volumeName: volume,
                isOnline: isOnline(r),
                isArchiveCopy: archive,
                fixityVerified: archive && r.archiveFixity != nil,
                attestations: r.backupAttestations))
        }
        return families
    }
}
