// CatalogCommit.swift
// ONE commit of changed records into catalog.sqlite (cutover B2, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §3 and §10 "B2-lite"). The app's
// committer decides WHICH records changed (CatalogChangeDetector) and takes
// their Sendable snapshots on the main actor; this runs everything else in
// ONE `repository.write(as: door)`:
//
//   per record, in its own SAVEPOINT (one refused row never undoes its
//   neighbours, and never blocks the next commit's other rows):
//     map the snapshot (the importer's own mapping, CatalogRecordDTO) →
//     no whole-file digest: DEFERRED (a `files` row needs one, contract
//       §e.2 — the scan's hashing is batch B3) — nothing written;
//     read the stored row back the way a load does, as a DTO →
//     diff (CatalogRecordDiff) → unchanged: nothing written;
//     else write what differs (CatalogCommitBody).
//   then the Master Archive designation (GH #167's guard: a set designation
//   becomes none only after Clear) — a refusal there refuses the commit.
//   Nothing landed and no designation change → the body throws on purpose so
//   no empty generation is committed.
//
// Outcomes (each named, none reported as success unless rows landed):
//   .committed(generation, rows)   ≥ 1 row or the designation landed; rows
//                                  that were deferred/refused say why
//   .nothingWritten(rows)          every row was unchanged, deferred or
//                                  refused — no generation
//   .refused(words, rows)          the store said no (read-only, "reopen the
//                                  catalog", an engine refusal outside a row,
//                                  the designation guard) — nothing changed
//   .generationMismatch            another writer committed first — nothing
//                                  changed
//
// (For Rick: a unit of work — the caller builds the change list, this
// applies it inside one transaction and reports per item.)

import Foundation

public enum CatalogCommit {

    /// One changed record: its id, its snapshot, and the fingerprint the
    /// detector computed for that snapshot (the new baseline if it lands).
    public struct Item: Sendable {
        public var id: UUID
        public var snapshot: VideoRecordDTO
        public var fingerprint: CatalogChangeDetector.Fingerprint

        public init(id: UUID, snapshot: VideoRecordDTO, fingerprint: CatalogChangeDetector.Fingerprint) {
            self.id = id
            self.snapshot = snapshot
            self.fingerprint = fingerprint
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
        /// Unix seconds stamped on what this commit writes.
        public var now: Int64

        public init(door: CatalogWriter, items: [Item], designation: Designation = .leave,
                    now: Int64 = Int64(Date().timeIntervalSince1970)) {
            self.door = door
            self.items = items
            self.designation = designation
            self.now = now
        }
    }

    /// What happened to one record.
    public enum Landing: Sendable, Equatable {
        /// Written. `curated`: the curated fields it wrote (the app copies
        /// them to the other records of the same content); `notes`: derived
        /// kinds or analysis the store could not hold (regenerable).
        case written(curated: [CatalogDDL.KnowledgeField], notes: [String])
        /// The store already holds exactly this.
        case unchanged
        /// Not storable yet — the words say what it waits for.
        case deferred(String)
        /// The store refused this row — the engine's words.
        case refused(String)

        public var landed: Bool {
            if case .written = self { return true }
            return false
        }
    }

    public struct RowResult: Sendable, Equatable {
        public var id: UUID
        public var fingerprint: CatalogChangeDetector.Fingerprint
        public var digest: String?
        public var landing: Landing
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
}
