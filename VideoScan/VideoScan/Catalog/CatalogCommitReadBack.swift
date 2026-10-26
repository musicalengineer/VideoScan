// CatalogCommitReadBack.swift
// Catalog ▸ Reopen's read-back after another writer (codex #141 F2 → #143
// "refuse and name" → #145), split out of CatalogCommitter.swift so the
// committer file stays the synchronous pipeline. CatalogCommitter.readBack
// runs it: the SET of what to check (here), ONE store read snapshot (`find`,
// off the main actor), then one VERDICT per entry (here) — the commit door's
// own comparison (Core CatalogRowCheck), so the two cannot disagree.
//
// What is checked — everything the next commit could write over:
//   * every changed record with an expectation (its row lock, or its held
//     payload's lock — #145 F1) — the row and the shared scalars it edited;
//   * every changed record this session CREATED whose content the store
//     already holds (#145 F2): its shared scalars against a stored sibling,
//     through the content's per-field baseline;
//   * every QUEUED PURGE (#145 F3): a door took the record out of memory,
//     the store still holds it — its lock alone (a purge writes no values).
// A mismatch HOLDS the entry (out of every commit, named in catalog.log);
// a row that is gone or no longer decodes FAILS the read-back and saving
// stays blocked (#145 F5: every row read is decoded, whatever its lock says).
//
// Memory: per entry one loaded row (and, for a new copy, one sibling row)
// for the length of the read — worst case every record changed: one copy of
// the catalog's rows, what a launch holds; dropped when Reopen returns.
//
// (For Rick: the "validate the cache against disk" pass a write-behind
// cache runs after it lost its lease — compare, never merge.)

import Foundation
import VideoScanCore

@MainActor
enum CatalogReadBack {

    /// One record (or queued purge) the read-back checks.
    struct Wanted: Sendable {
        let id: UUID
        /// The row's (or held payload's) lock; nil for a new copy.
        let expected: CatalogCommit.Expectation?
        /// A record this session created: the content its scalars meet (F2).
        let newCopy: CatalogCommitBaseline.NewCopy?
        /// A purge a door queued; the record is no longer in memory (F3).
        let purge: Bool
    }

    /// What one read snapshot found for the wanted entries.
    struct Findings: Sendable {
        let generation: Int
        var found: [UUID: CatalogRowCheck.Found] = [:]
        var content: [UUID: CatalogLoadedRow] = [:]
    }

    /// One entry's outcome on Reopen.
    enum Verdict: Equatable {
        case saveable
        case held(String)
        case failed(String)
    }

    /// The entries: the changed records with something to check, then the
    /// queued purges the store still holds.
    static func wanted(changed: [VideoRecord], records: [VideoRecord], queuedPurges: [UUID],
                       baseline: CatalogCommitBaseline) -> [Wanted] {
        let fresh = baseline.newCopies(changed, among: records)
        var out: [Wanted] = changed.compactMap { record in
            if let expected = baseline.expectation(of: record.id) {
                return Wanted(id: record.id, expected: expected, newCopy: nil, purge: false)
            }
            return fresh[record.id].map { Wanted(id: record.id, expected: nil, newCopy: $0, purge: false) }
        }
        for id in queuedPurges {
            if let expected = baseline.expectation(of: id) { out.append(Wanted(id: id, expected: expected, newCopy: nil, purge: true)) }
        }
        return out
    }

    /// Inside the one read snapshot (off the main actor).
    nonisolated static func find(_ wanted: [Wanted], in reader: any CatalogReader) throws -> Findings {
        var out = Findings(generation: reader.generation)
        for entry in wanted {
            if entry.expected != nil { out.found[entry.id] = try CatalogRowCheck.find(id: entry.id.uuidString, in: reader) }
            if let copy = entry.newCopy {
                out.content[entry.id] = try reader.storedContentRow(digest: copy.digest, excluding: entry.id.uuidString)
            }
        }
        return out
    }

    /// The commit door's own comparison, in Reopen's words. `record`: the
    /// in-memory record (nil for a queued purge — it left memory).
    static func verdict(_ entry: Wanted, record: VideoRecord?, read: Findings, sharedBaseline: CatalogSharedCurated?) -> Verdict {
        let found = read.found[entry.id] ?? .nothing
        // Codex #145 F5: decoded whatever the lock says — a changed lock used
        // to make an undecodable row an ordinary HELD row (the failure
        // swallowed while naming it) and saving was unblocked.
        if let broken = undecodable(found, read.content[entry.id]) {
            let who = record.map { "record \(entry.id.uuidString) (\($0.filename))" }
                ?? "row \(entry.id.uuidString) (queued for removal from the catalog)"
            return .failed("\(who): \(broken.words) — quit and relaunch, then redo the change(s)")
        }
        guard let record else { return purgeVerdict(entry, found: found) }
        let snapshot = VideoRecordDTO(record)
        let mismatch: CatalogRowCheck.Mismatch?
        if let expected = entry.expected {
            mismatch = CatalogRowCheck.check(expected, snapshot: snapshot, sharedBaseline: sharedBaseline, found: found)
        } else {
            mismatch = CatalogRowCheck.checkNewCopy(snapshot: snapshot, sharedBaseline: entry.newCopy?.baseline,
                                                    content: read.content[entry.id])
        }
        guard let mismatch else { return .saveable }
        switch mismatch {
        case .rowGone, .undecodable:
            return .failed("record \(entry.id.uuidString) (\(record.filename)): \(mismatch.words) — quit and relaunch, then redo the change(s)")
        case .rowChanged, .materialised, .pendingGone, .pendingChanged, .sharedChanged:
            return .held(heldWords(record, mismatch: mismatch, stored: found, newCopy: entry.newCopy != nil))
        }
    }

    /// The first stored row the read-back read that no longer becomes a
    /// record (F5), as the door's own mismatch words; nil when all decode.
    /// One decode per row read — what a launch does for every row.
    private static func undecodable(_ found: CatalogRowCheck.Found, _ content: CatalogLoadedRow?) -> CatalogRowCheck.Mismatch? {
        var rows: [CatalogLoadedRow] = content.map { [$0] } ?? []
        if case .row(let row) = found { rows.append(row) }
        for row in rows {
            do { _ = try VideoRecord(loaded: row) } catch { return .undecodable(String(describing: error)) }
        }
        return nil
    }

    /// A queued purge (F3): its lock alone.
    private static func purgeVerdict(_ entry: Wanted, found: CatalogRowCheck.Found) -> Verdict {
        guard entry.purge, let expected = entry.expected,
              let mismatch = CatalogRowCheck.check(expected, found: found) else { return .saveable }
        let what = "row \(entry.id.uuidString) (queued for removal from the catalog)"
        switch mismatch {
        case .rowGone, .undecodable:
            return .failed("\(what): \(mismatch.words) — quit and relaunch, then remove it again if it should go")
        case .rowChanged, .materialised, .pendingGone, .pendingChanged, .sharedChanged:
            return .held("the catalog changed under you: \(what) — \(mismatch.words); its removal was not saved and it stays "
                         + "in the catalog; relaunch to see the catalog's values, then remove it again if it should go")
        }
    }

    /// The words for a row held out of every commit: why, and which parts
    /// differ between the catalog and this session (the commit's own
    /// comparison, CatalogRecordDiff) — theirs and ours together, since a
    /// part the baseline cannot attribute is not guessed at.
    static func heldWords(_ record: VideoRecord, mismatch: CatalogRowCheck.Mismatch, stored: CatalogRowCheck.Found,
                          newCopy: Bool = false) -> String {
        if newCopy {
            // Codex #145 F2: a record this session created is not in the catalog at all.
            return "the catalog changed under you: \(record.filename) — a new copy of a content in the catalog: \(mismatch.words); "
                + "this new record is NOT in the catalog and is not saved; relaunch, then rescan its folder to add it again"
        }
        var parts = "(not compared)"
        if case .row(let row) = stored, let fresh = try? VideoRecord(loaded: row) {
            parts = differingParts(stored: fresh, current: record)
        }
        return "the catalog changed under you: \(record.filename) — \(mismatch.words); it differs from this session in: \(parts); "
            + "this session's edit of it was not saved; relaunch to see the catalog's values, then redo the edit"
    }

    /// The parts of the record that differ between the store and memory,
    /// in words — the commit's own comparison (CatalogRecordDiff).
    private static func differingParts(stored: VideoRecord, current: VideoRecord) -> String {
        guard let s = try? CatalogRecordDTO(record: stored, migrationLoadedAt: 0),
              let c = try? CatalogRecordDTO(record: current, migrationLoadedAt: 0) else { return "(could not be compared)" }
        let diff = CatalogRecordDiff(stored: s, current: c)
        let flags: [(Bool, String)] = [(diff.file, "file facts"), (diff.marker, "removal marker"), (diff.archiveCopy, "archive copy"),
                                       (diff.backups, "backups"), (diff.footageDecisions, "footage decisions"),
                                       (diff.duplicate, "duplicate analysis"), (diff.soundPrint, "sound print"), (diff.pair, "pair")]
        var names = flags.filter(\.0).map(\.1)
        names += diff.knowledge.map(\.rawValue)
        names += diff.derived.map { "derived \($0.rawValue)" }
        return names.isEmpty ? "nothing the store compares" : names.joined(separator: ", ")
    }
}
