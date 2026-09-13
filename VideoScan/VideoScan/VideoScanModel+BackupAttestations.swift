// VideoScanModel+BackupAttestations.swift
// The model half of the backup attestations (Rick 2026-09-12, promote-
// and-prune stage 1; the pure model is BackupAttestation.swift in
// VideoScanCore):
//
//   - `recordAttestation(kind:answer:label:by:at:for:)` — the ONE write
//     path. Replaces the same-kind answer on each record, posts a
//     RECORD-SCOPED catalog-mutation notification per record AS IT IS
//     UPDATED (the same shape InspectorPlaceView uses) so the search
//     index, the debounced save and the chrome caches refresh, writes the
//     console lines in ONE batch, and hands the archive-journal lines to
//     ONE off-main append. No UI calls it yet — the "Archived — what
//     next?" sheet is stage 2.
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
// MAIN-ACTOR RULE (codex #1416 / #1429, 2026-09-12): `recordAttestation`
// does NO file I/O on the main actor — not the journal, not the console
// log. The first cut opened/wrote/fsynced one journal line per record
// inline and fsynced one `appLog` line per record — on a slow archive
// volume or a 5,000-record batch that is a beachball, and every
// notification waited for the loop to end. Now: the loop only mutates
// records and posts; ONE worker task per call (chained after the
// previous call's, so both files stay in call order) hops to the
// cooperative pool (`@concurrent`) and there writes the console lines
// through `appLog.writeBatch` (one lock / one write / one fsync — GH
// #162; PersistentLog documents writeBatch as off-main work) and appends
// the journal batch with a single O_APPEND write + one fsync. A failed
// append logs the REAL error with the journal path; the records are
// already updated and announced by then.
//
// Isolation: the journal root is the model's designated archive root —
// tests inject a sandbox designation; nothing here ever names a real
// volume path. The journal writer is injectable (`journalWriter:`) so a
// test can count appends without a file system.
//
// (For Rick: `Task { … }` from a `@MainActor` method is like posting a
// closure to a worker queue that inherits the caller's task-locals;
// `@concurrent` is what actually moves the body OFF the main thread — a
// bare `nonisolated async` would run on the caller's actor, the trap this
// repo has hit three times.)

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
            self.at = BackupAttestation.Timestamp.quantized(at)
            self.recordID = record.id
            self.filename = record.filename
            self.fullPath = record.fullPath
            self.kind = a.kind.rawValue
            self.answer = a.answer.rawValue
            self.label = a.label
            self.by = a.by
            self.line = a.journalLine
        }

        // `at` uses the attestation's own Timestamp representation
        // (millisecond ISO-8601) — the journal and the catalog never
        // disagree about when. Tolerant of the whole-second lines the
        // first writer produced.
        private enum CodingKeys: String, CodingKey { case at, recordID, filename, fullPath, kind, answer, label, by, line }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = try BackupAttestation.Timestamp.decode(from: c, forKey: .at)
            recordID = try c.decode(UUID.self, forKey: .recordID)
            filename = try c.decode(String.self, forKey: .filename)
            fullPath = try c.decode(String.self, forKey: .fullPath)
            kind = try c.decode(String.self, forKey: .kind)
            answer = try c.decode(String.self, forKey: .answer)
            label = try c.decodeIfPresent(String.self, forKey: .label)
            by = try c.decode(String.self, forKey: .by)
            line = try c.decode(String.self, forKey: .line)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(BackupAttestation.Timestamp.string(at), forKey: .at)
            try c.encode(recordID, forKey: .recordID)
            try c.encode(filename, forKey: .filename)
            try c.encode(fullPath, forKey: .fullPath)
            try c.encode(kind, forKey: .kind)
            try c.encode(answer, forKey: .answer)
            try c.encodeIfPresent(label, forKey: .label)
            try c.encode(by, forKey: .by)
            try c.encode(line, forKey: .line)
        }
    }

    /// The append seam: production is `append(_:rootPath:)`; a test can
    /// count calls or refuse. Must be `@Sendable` — it is carried into
    /// the off-main task.
    typealias Writer = @Sendable ([Entry], String) throws -> Void
    static let liveWriter: Writer = { entries, root in try append(entries, rootPath: root) }

    static func url(rootPath: String) -> URL {
        URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent(MasterArchiveLayout.indexFolder, isDirectory: true)
            .appendingPathComponent(filename)
    }

    /// Append a BATCH: every entry encoded up front, then one descriptor-
    /// relative open under `00_Index/` (O_NOFOLLOW, regular file, created
    /// on first use), ONE O_APPEND write + ONE fsync. Throws when the root
    /// is unreachable or the barrier fails — the caller logs and moves
    /// on. An empty batch is a no-op (no open, no fsync).
    /// (`nonisolated` ≈ a free function: safe off the main actor.)
    nonisolated static func append(_ entries: [Entry], rootPath: String) throws {
        guard !entries.isEmpty else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = Data()
        for e in entries {
            data.append(try encoder.encode(e))
            data.append(0x0A)
        }
        let fd = try ArchivePromoteEngine.openIndexFile(root: rootPath, name: filename, mustExist: false)
        defer { close(fd) }
        try ArchivePromoteEngine.appendDurable(fd: fd, data: data, full: false,
                                               label: "attestation journal append (\(entries.count) line(s))")
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
        return text.split(separator: "\n").compactMap { line in
            guard let d = line.data(using: .utf8) else { return nil }
            return try? decoder.decode(Entry.self, from: d)
        }
    }

    /// The error text the log carries: the engine's own description for
    /// its failures (errno included), `localizedDescription` otherwise.
    nonisolated static func describe(_ error: Error) -> String {
        if let f = error as? ArchivePromoteEngine.Failure { return f.description }
        return error.localizedDescription
    }
}

// MARK: - Model

/// What `recordAttestation` did: the records it wrote (synchronously,
/// announced before return) and the off-main flush — console batch plus
/// journal append — awaitable (`await write.flush?.value`) when a caller
/// or test needs the lines on disk. nil = nothing was written, so nothing
/// to flush.
struct BackupAttestationWrite {
    let records: [VideoRecord]
    let flush: Task<Void, Never>?
}

extension VideoScanModel {

    /// The tail of the flush chain: each call's worker waits for the
    /// previous one, so the console log and `.attestation_journal.jsonl`
    /// both stay in call order even though the writes run off-main. (A
    /// static stored property is allowed in an extension; an instance
    /// one is not.)
    @MainActor private static var attestationFlushTail: Task<Void, Never>?

    /// Record the user's word for `recordIDs`: `kind` = `answer`, with an
    /// optional label ("iCloud", "Tim's house"). Replaces the same-kind
    /// answer on each record (history is the journal's job), posts one
    /// record-scoped mutation per record as it is written, and hands the
    /// console lines (one batch) and the journal lines (one durable
    /// append) to ONE ordered off-main worker. Unknown ids are skipped.
    /// Never touches a file on the main actor.
    @MainActor
    @discardableResult
    func recordAttestation(kind: BackupAttestation.Kind,
                           answer: BackupAttestation.Answer,
                           label: String? = nil,
                           by: String = "rick",
                           at: Date = Date(),
                           for recordIDs: [UUID],
                           journalWriter: @escaping ArchiveAttestationJournal.Writer = ArchiveAttestationJournal.liveWriter)
    -> BackupAttestationWrite {
        // One attestation value for the whole batch (same kind / answer /
        // label / when / who) — quantized once by the initializer.
        let attestation = BackupAttestation(kind: kind, answer: answer, label: label, attestedAt: at, by: by)
        let root = masterArchiveRootPath
        var changed: [VideoRecord] = []
        var entries: [ArchiveAttestationJournal.Entry] = []
        var lines: [String] = []
        changed.reserveCapacity(recordIDs.count)
        lines.reserveCapacity(recordIDs.count)
        if root != nil { entries.reserveCapacity(recordIDs.count) }
        for id in recordIDs {
            guard let rec = record(forID: id) else { continue }
            rec.backupAttestations = BackupAttestation.replacing(rec.backupAttestations, with: attestation)
            changed.append(rec)
            if root != nil {
                entries.append(ArchiveAttestationJournal.Entry(at: attestation.attestedAt,
                                                              record: (rec.id, rec.filename, rec.fullPath),
                                                              attestation: attestation))
            }
            lines.append("attestation: \(rec.filename) — \(attestation.journalLine)")
            // Announced NOW — the save/index/chrome refresh never waits
            // for the journal.
            NotificationCenter.default.post(name: .videoScanCatalogMutated, object: rec)
        }
        guard !changed.isEmpty else {
            return BackupAttestationWrite(records: [], flush: nil)
        }
        // Snapshots for the worker (value types — nothing shared with the
        // main-actor state after this point).
        let consoleLines = lines
        let journalBatch = entries
        let previous = Self.attestationFlushTail
        let task = Task(priority: .utility) {
            await previous?.value
            await Self.flushAttestationsOffMain(console: consoleLines, journal: journalBatch,
                                                rootPath: root, writer: journalWriter)
        }
        Self.attestationFlushTail = task
        return BackupAttestationWrite(records: changed, flush: task)
    }

    /// The off-main hop, in this order: the console batch (one
    /// `writeBatch`), then one durable journal append when an archive is
    /// designated; on an append failure the REAL error and the journal
    /// path go to the log (the records are already updated and announced
    /// — best effort, by design).
    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func flushAttestationsOffMain(console: [String],
                                                     journal: [ArchiveAttestationJournal.Entry],
                                                     rootPath: String?,
                                                     writer: ArchiveAttestationJournal.Writer) async {
        if !console.isEmpty { appLog.writeBatch(console) }
        guard let rootPath, !journal.isEmpty else { return }
        do {
            try writer(journal, rootPath)
        } catch {
            let path = ArchiveAttestationJournal.url(rootPath: rootPath).path
            appLog.write("attestation: \(journal.count) journal line(s) not written to \(path) — "
                         + "\(ArchiveAttestationJournal.describe(error)); catalog records were updated")
        }
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
