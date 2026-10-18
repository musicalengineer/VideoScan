// CatalogLoad.swift
// The Core half of a SQLite load (cutover B1, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §2): the one-time display pass,
// then ONE read snapshot of every `files` row as `CatalogLoadedRow` values
// plus the counts Catalog Status shows. No SQL here (it is in Store/), no
// VideoRecord here (the app builds those on the main actor from the rows).
//
// The display pass. After the import the display tables are empty; the
// first load derives them from `knowledge_sources` (DisplayValueDerivation)
// and writes them in ONE `write(as: .migrate)`. It runs only while the
// tables are empty, so it happens once. If it cannot be written (a
// read-only store, an engine refusal) the load REFUSES with the store's
// words rather than show a catalog with every star, date and name missing.
//
// Memory: the snapshot holds one `CatalogLoadedRow` per `files` row
// (≈ the size of the record it becomes; the derived text dominates). The
// app turns them into records and drops the snapshot, so the peak is about
// twice the loaded catalog for the length of that loop.
//
// (For Rick: `async` functions here are coroutines that suspend while the
// store's own queue does the SQLite work; nothing blocks a thread.)

import Foundation

public enum CatalogLoad {

    /// What the display pass did.
    public enum DisplayPass: Sendable, Equatable {
        /// The tables already hold rows: nothing to do.
        case alreadyFilled
        /// No curated evidence hangs on a digest: nothing to write.
        case nothingToFill
        case filled(rows: Int, conflicts: Int, unreadable: Int, generation: Int)
    }

    /// Why a load refused, in words for the person.
    public enum Failure: Error, Equatable, Sendable {
        case displayPassRefused(String)
        case readFailed(String)

        public var words: String {
            switch self {
            case .displayPassRefused(let w): return "the curated values could not be prepared for display: \(w)"
            case .readFailed(let w): return "the catalog could not be read: \(w)"
            }
        }
    }

    public struct Snapshot: Sendable {
        public var rows: [CatalogLoadedRow]
        public var counts: CatalogLoadCounts
        public var displayPass: DisplayPass
        /// The generation the rows were read at.
        public var generation: Int
    }

    /// Display pass, then one snapshot of every row.
    public static func read(_ repository: any CatalogRepository) async throws -> Snapshot {
        let pass = try await fillDisplayTablesIfEmpty(repository)
        do {
            return try await repository.read { reader in
                var rows: [CatalogLoadedRow] = []
                try reader.loadedRows { rows.append($0) }
                return Snapshot(rows: rows, counts: try reader.loadCounts(), displayPass: pass, generation: reader.generation)
            }
        } catch {
            throw Failure.readFailed(String(describing: error))
        }
    }

    /// The one-time pass: derive the display rows from the evidence and
    /// write them, only while the display tables are empty.
    public static func fillDisplayTablesIfEmpty(_ repository: any CatalogRepository) async throws -> DisplayPass {
        let evidence: (empty: Bool, sources: [DisplayValueDerivation.Source])
        do {
            evidence = try await repository.read { reader in
                guard try reader.displayTablesEmpty() else { return (false, []) }
                var sources: [DisplayValueDerivation.Source] = []
                try reader.displaySources { sources.append($0) }
                return (true, sources)
            }
        } catch {
            throw Failure.readFailed(String(describing: error))
        }
        guard evidence.empty else { return .alreadyFilled }
        let rows = DisplayValueDerivation.derive(sources: evidence.sources)
        guard rows.rowCount > 0 else { return .nothingToFill }
        let outcome = await repository.write(as: .migrate) { tx in
            guard try tx.displayTablesEmpty() else { throw DisplayPassRace() }
            try tx.insertDisplayRows(rows)
        }
        switch outcome {
        case .committed(let generation):
            return .filled(rows: rows.rowCount, conflicts: rows.conflictCount, unreadable: rows.unreadable, generation: generation)
        case .refused(let reason):
            throw Failure.displayPassRefused(reason)
        case .generationMismatch(let expected, let found):
            throw Failure.displayPassRefused("another writer committed generation \(found) (this session expected \(expected)) — reopen the catalog")
        }
    }

    /// The tables filled between the read and the write: write nothing.
    private struct DisplayPassRace: Error, CustomStringConvertible {
        var description: String { "the display tables were filled by another writer meanwhile" }
    }
}
