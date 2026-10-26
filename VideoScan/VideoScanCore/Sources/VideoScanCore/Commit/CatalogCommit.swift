// CatalogCommit.swift
// ONE commit of changed records into catalog.sqlite (cutover B2, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §3 and §10 "B2-lite"). The app's
// committer decides WHICH records changed (CatalogChangeDetector) and takes
// their Sendable snapshots on the main actor; this runs everything else in
// ONE `repository.write(as: door)` — or, for the app's committer (B2.2),
// ONE `repository.writeBlocking(as: door)` on the main actor:
//
//   first the PURGES (B2.1 gap 3): each id the app no longer holds gets the
//     purge marker on its row (tombstone first, never a DELETE) or its
//     pending row dropped — before any insert, so a live path a purged row
//     held is free for the record that replaced it;
//   per record, in its own SAVEPOINT (one refused row never undoes its
//   neighbours, and never blocks the next commit's other rows):
//     map the snapshot (the importer's own mapping, CatalogRecordDTO) →
//     no whole-file digest: DEFERRED (a `files` row needs one, contract
//       §e.2) and HELD in `pending_rows` (B2.1 gap 1) so a relaunch keeps it;
//     read the stored row back the way a load does, as a DTO →
//     diff (CatalogRecordDiff), the shared curated fields restricted to the
//       ones THIS record changed since its own baseline (B2.1, codex P1-1)
//       → unchanged: nothing written; else write what differs
//       (CatalogCommitBody). Items for one id run in order, so an
//       intermediate removal-marker revision (B2.1 gap 2) lands before the
//       final one, each with its own tombstone.
//   then the Master Archive designation (GH #167's guard: a set designation
//   becomes none only after Clear) — a refusal there refuses the commit.
//   Nothing landed and no designation change → the body throws on purpose so
//   no empty generation is committed.
//
// Outcomes (each named, none reported as success unless rows landed):
//   .committed(generation, rows)   ≥ 1 row, a held row, a purge or the
//                                  designation landed; rows that were
//                                  deferred / partial / refused say why
//   .nothingWritten(rows)          every row was unchanged, already held,
//                                  deferred or refused — no generation
//   .refused(words, rows)          the store said no (read-only, "reopen the
//                                  catalog", an engine refusal outside a row,
//                                  the designation guard, a row another writer
//                                  changed since this session saw it — the
//                                  per-row lock, codex #143) — nothing changed
//   .generationMismatch            another writer committed first — nothing
//                                  changed
//
// (For Rick: a unit of work — the caller builds the change list, this
// applies it inside one transaction and reports per item.)

import Foundation

public enum CatalogCommit {

    /// What the committer believes the store holds for a row it submits
    /// (codex #143, the per-row lock): checked INSIDE the transaction before
    /// anything is written; any mismatch refuses the whole commit.
    public enum Expectation: Sendable, Equatable {
        /// A `files` row whose per-row parts hash to this lock (CatalogRowLock).
        case row(lock: CatalogRowLock.Value)
        /// Held in `pending_rows` (no whole-file hash yet): no `files` row,
        /// and the held payload the one this session last stored or loaded —
        /// its `CatalogRowLock.ofPending` lock (codex #145 F1: existence
        /// alone let another writer's changed payload be replaced).
        case pending(lock: CatalogRowLock.Value)
    }

    /// One changed record: its id, its snapshot, the fingerprint the
    /// detector computed for that snapshot (the new baseline if it lands),
    /// the shared curated values the record last agreed with the store on,
    /// and what the store is expected to hold for it now.
    public struct Item: Sendable {
        public var id: UUID
        public var snapshot: VideoRecordDTO
        public var fingerprint: CatalogChangeDetector.Fingerprint
        /// nil = unknown (a record this session never saw stored): its
        /// shared fields are compared with the store, as before B2.1.
        public var sharedBaseline: CatalogSharedCurated?
        /// nil = a record this session created (never stored): no check.
        public var expected: Expectation?

        public init(id: UUID, snapshot: VideoRecordDTO, fingerprint: CatalogChangeDetector.Fingerprint,
                    sharedBaseline: CatalogSharedCurated? = nil, expected: Expectation? = nil) {
            self.id = id
            self.snapshot = snapshot
            self.fingerprint = fingerprint
            self.sharedBaseline = sharedBaseline
            self.expected = expected
        }
    }

    /// The catalog-level designation this commit carries.
    public enum Designation: Sendable, Equatable {
        /// Not part of this commit.
        case leave
        /// What the app holds now (JSON text, nil = none), and whether the
        /// person cleared it (the only way a set designation may go).
        case current(json: String?, clearAuthorized: Bool)
    }

    public struct Plan: Sendable {
        public var door: CatalogWriter
        public var items: [Item]
        public var designation: Designation
        /// Ids the app no longer holds (B2.1 gap 3): purged, never deleted.
        public var purges: [UUID]
        /// purged id → the id of the record that REPLACES it (a rescan's
        /// fresh instance, a job output landing at the path) — said by the
        /// door that made the swap, never inferred (P0 2026-10-22, codex
        /// #123). Such a purge lands only when its replacement is stored or
        /// held; a purge with no entry is a plain removal ("gone from disk",
        /// Delete All) and runs on its own, as before.
        public var replacements: [UUID: UUID]
        /// Unix seconds stamped on what this commit writes.
        public var now: Int64

        public init(door: CatalogWriter, items: [Item], designation: Designation = .leave, purges: [UUID] = [],
                    replacements: [UUID: UUID] = [:], now: Int64 = Int64(Date().timeIntervalSince1970)) {
            self.door = door
            self.items = items
            self.designation = designation
            self.purges = purges
            self.replacements = replacements
            self.now = now
        }
    }

    /// What happened to one record (or one purged id).
    public enum Landing: Sendable, Equatable {
        /// Written. `curated`: the shared curated fields it wrote (the app
        /// copies them to the other records of the same content); `notes`:
        /// analysis the store could not hold that is rebuildable (duplicates).
        case written(curated: [CatalogDDL.KnowledgeField], notes: [String])
        /// Written, but a part the store refused was left out (a derived
        /// kind — codex B2 P2-7): the record stays CHANGED in the app and is
        /// sent again; `words` say what is missing.
        case partial(curated: [CatalogDDL.KnowledgeField], words: [String])
        /// The store already holds exactly this.
        case unchanged
        /// Not storable yet — the words say what it waits for.
        case deferred(String)
        /// The store refused this row — the engine's words.
        case refused(String)
        /// A purge (B2.1 gap 3): what happened to the id.
        case removed(CatalogRow.PurgeLanding)

        /// Something of this row reached the store in this commit.
        public var landed: Bool {
            switch self {
            case .written, .partial, .removed(.purged), .removed(.pendingPurged): return true
            case .unchanged, .deferred, .refused, .removed: return false
            }
        }

        /// The shared curated fields this row wrote (empty unless written).
        public var wroteShared: Set<CatalogDDL.KnowledgeField> {
            switch self {
            case .written(let curated, _), .partial(let curated, _): return Set(curated)
            case .unchanged, .deferred, .refused, .removed: return []
            }
        }

        /// Everything the record holds is in the store (its baseline may move).
        public var isComplete: Bool {
            switch self {
            case .written, .unchanged: return true
            case .partial, .deferred, .refused, .removed: return false
            }
        }
    }

    public struct RowResult: Sendable, Equatable {
        public var id: UUID
        public var fingerprint: CatalogChangeDetector.Fingerprint
        public var digest: String?
        public var landing: Landing
        /// Deferred AND held in `pending_rows` (B2.1 gap 1): durable, waiting
        /// for its whole-file digest.
        public var heldPending = false
        /// The removal revision the store gave a record whose purged row
        /// came back (the app sets it on the record so the next change
        /// follows on from it).
        public var adoptedRevision: Int?
        /// A purge the store did NOT apply because the record replacing the
        /// row (`Plan.replacements`) is not stored or held (P0 2026-10-22):
        /// the row stays live. The app keeps the request and sends it again
        /// together with its replacement — never on its own.
        public var keptForReplacement = false
        /// Written rows of a content whose shared sets (tags, people,
        /// attestations) this commit changed: the sets the store ENDS with
        /// (cutover B2.4). nil = no set of the content was written.
        public var settledSets: SettledSets?
        /// The row's per-row lock as the store holds it after this commit
        /// (codex #143): read back inside the transaction for a written or
        /// partial row, the pre-write read for an unchanged one; for a row
        /// held in `pending_rows` (`heldPending`), the lock of the payload the
        /// store now holds (`CatalogRowLock.ofPending`, codex #145 F1). nil
        /// otherwise (refused, removed, a hold that could not be stored).
        public var storedLock: CatalogRowLock.Value?
    }

    public enum Outcome: Sendable, Equatable {
        case committed(generation: Int, rows: [RowResult])
        case nothingWritten(rows: [RowResult])
        case refused(String, rows: [RowResult])
        case generationMismatch(expected: Int, found: Int)
    }

    /// Run `plan` as one write. Never throws: every way it can end is an outcome.
    public static func run(_ plan: Plan, on repository: any CatalogRepository) async -> Outcome {
        let ledger = CatalogCommitLedger()
        let outcome = await repository.write(as: plan.door) { tx in
            try CatalogCommitBody(plan: plan, tx: tx, ledger: ledger).run()
        }
        return result(outcome, ledger)
    }

    /// The same, on the calling thread (cutover B2.2): the app's
    /// CatalogCommitter runs its whole commit in one main-actor turn.
    public static func runBlocking(_ plan: Plan, on repository: any CatalogRepository) -> Outcome {
        let ledger = CatalogCommitLedger()
        let outcome = repository.writeBlocking(as: plan.door) { tx in
            try CatalogCommitBody(plan: plan, tx: tx, ledger: ledger).run()
        }
        return result(outcome, ledger)
    }

    private static func result(_ outcome: CatalogWriteOutcome, _ ledger: CatalogCommitLedger) -> Outcome {
        let rows = ledger.rows
        switch outcome {
        case .committed(let generation):
            return .committed(generation: generation, rows: rows)
        case .generationMismatch(let expected, let found):
            return .generationMismatch(expected: expected, found: found)
        case .refused(let reason):
            return ledger.landedNothingOnPurpose ? .nothingWritten(rows: rows) : .refused(reason, rows: rows)
        }
    }
}

/// What the body did, read by `run` after the write returns (the body runs
/// on the store's queue). (For Rick: a mutex-guarded out-parameter.)
final class CatalogCommitLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [CatalogCommit.RowResult] = []
    private var nothingOnPurpose = false

    var rows: [CatalogCommit.RowResult] { lock.withLock { stored } }
    var landedNothingOnPurpose: Bool { lock.withLock { nothingOnPurpose } }

    func record(_ row: CatalogCommit.RowResult) { lock.withLock { stored.append(row) } }
    func noteNothingLanded() { lock.withLock { nothingOnPurpose = true } }

    /// One written row per content whose shared sets this commit wrote
    /// (cutover B2.4): digest → the row to read the content back through.
    func setWriters(_ fields: Set<CatalogDDL.KnowledgeField>) -> [(digest: String, id: UUID)] {
        lock.withLock {
            var seen = Set<String>()
            return stored.compactMap { row in
                guard let digest = row.digest, !row.landing.wroteShared.isDisjoint(with: fields),
                      seen.insert(digest).inserted else { return nil }
                return (digest, row.id)
            }
        }
    }

    /// Every row of `digest` reports the sets the store ended with.
    func settle(digest: String, _ sets: CatalogCommit.SettledSets) {
        lock.withLock {
            for index in stored.indices where stored[index].digest == digest && stored[index].landing.landed {
                stored[index].settledSets = sets
            }
        }
    }
}
