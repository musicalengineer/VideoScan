// CatalogImporter.swift
// Step D′ of docs/design/catalog_sqlite_migration_2026_10_16.md §10a — the
// job that moves the frozen catalog.json into SQLite. Rick's sentence:
// "import every verified row of the JSON catalog into SQLite, quarantine the
// rest with their words, lose nothing, and prove it with a comparator before
// the transaction commits."
//
// Shape:
//   * inputs are FILES (the frozen catalog, the integrity report, the audit
//     marker, the sidecars), read through the importer's own Decodable
//     mirrors (VideoRecordJSON, ImportSidecarsJSON*) — never the app's
//     VideoRecord class (CatalogImporterSensorTests);
//   * run-level refusals (ImportGate.runLevelRefusals) and the empty-target
//     check happen BEFORE anything is written;
//   * then ONE write transaction on the repository: the row pass
//     (+Rows), the relation pass, the sidecar pass (+Sidecars), the
//     comparator over an INDEPENDENT re-decode of every input file
//     (+Comparator), and the finish of the import run. `.ok` commits;
//     a miss throws, the store rolls back, and the outcome names every miss;
//   * the JSON files are never written; the database is the only output.
//
// Memory (worst case, 100k rows): the catalog is decoded TWICE — once for
// the row pass, once for the comparator — but never both at once: the row
// pass runs in its own function and releases its decode before the
// comparator reads the file again. Peak ≈ one decoded catalog (≈ 2–3 KB per
// row: the typed mirror plus its raw object) + the comparator's two sides
// (ordinal-keyed landings, knowledge keys, derived keys — small per row) +
// the per-row facts map (id → digest, file id, path; ≈ 250 bytes per row).
// Nothing is O(rows²). Measured by CatalogImporterScaleTests.
//
// Outcomes (playbook §7: every case named, no `default:` at the caller):
//   .imported(reconciliation)   committed; the §f line is in the value
//   .refused([RunRefusal])      a gate said no; nothing was written
//   .rolledBack([Miss])         the comparator found a miss; the store rolled
//                               back; the database is as empty as before
//   .failed(words)              the store or a file said no (read-only
//                               folder, a row the DDL refuses, a damaged
//                               sidecar); nothing committed
//
// (For Rick: an `actor` ≈ a class with an implicit mutex; the write body is
// a synchronous callback the store runs on its own queue, so everything it
// needs is copied into a value (`ImportPlan`) first.)

import CryptoKit
import Foundation

public actor CatalogImporter {

    // MARK: - Inputs and outcomes

    /// Where the frozen files are. The three gate files are required
    /// (contract §f); the sidecars are imported when present.
    public struct Inputs: Sendable, Equatable {
        public var catalogURL: URL
        public var integrityURL: URL
        public var auditURL: URL
        public var eventsURL: URL?
        public var ignoredURL: URL?
        public var ledgerURL: URL?
        public var backfillURL: URL?
        /// The target database (catalog.sqlite); its folder takes the high-water files.
        public var databaseURL: URL

        public init(catalogURL: URL, integrityURL: URL, auditURL: URL, eventsURL: URL? = nil, ignoredURL: URL? = nil,
                    ledgerURL: URL? = nil, backfillURL: URL? = nil, databaseURL: URL) {
            self.catalogURL = catalogURL
            self.integrityURL = integrityURL
            self.auditURL = auditURL
            self.eventsURL = eventsURL
            self.ignoredURL = ignoredURL
            self.ledgerURL = ledgerURL
            self.backfillURL = backfillURL
            self.databaseURL = databaseURL
        }

        /// The gate files' names beside catalog.json (contract §f "Inputs").
        public static let integrityFileName = "integrity-latest.json"
        public static let auditFileName = "catalog-audit.json"
        public static let databaseFileName = "catalog.sqlite"

        /// The conventional layout: every file beside catalog.json, the ledger
        /// under `ledger/`, the database as `catalog.sqlite` in `databaseFolder`.
        public static func beside(catalogURL: URL, databaseFolder: URL) -> Inputs {
            let folder = catalogURL.deletingLastPathComponent()
            func optional(_ name: String) -> URL? {
                let url = folder.appendingPathComponent(name)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
            return Inputs(catalogURL: catalogURL,
                          integrityURL: folder.appendingPathComponent(integrityFileName),
                          auditURL: folder.appendingPathComponent(auditFileName),
                          eventsURL: optional(CatalogDDL.ImportSourceFile.eventsDecisions.rawValue),
                          ignoredURL: optional(CatalogDDL.ImportSourceFile.ignoredContent.rawValue),
                          ledgerURL: optional("ledger/" + CatalogDDL.ImportSourceFile.mediaLedger.rawValue),
                          backfillURL: optional(CatalogDDL.ImportSourceFile.fullHashBackfill.rawValue),
                          databaseURL: databaseFolder.appendingPathComponent(databaseFileName))
        }
    }

    /// What the app knows that the files do not (contract §f run-level refusals).
    public struct Environment: Sendable, Equatable {
        public var openDeleteDuplicatesPlans: [String]
        public var openAngelBatches: [String]
        public var runningWriters: [String]

        public init(openDeleteDuplicatesPlans: [String] = [], openAngelBatches: [String] = [], runningWriters: [String] = []) {
            self.openDeleteDuplicatesPlans = openDeleteDuplicatesPlans
            self.openAngelBatches = openAngelBatches
            self.runningWriters = runningWriters
        }
    }

    public enum Outcome: Sendable, Equatable {
        case imported(ImportReconciliation)
        case refused([ImportGate.RunRefusal])
        case rolledBack([ImportComparator.Miss])
        case failed(String)
    }

    /// One line for the console / catalog.log / videoscan.log; the app wires
    /// the sink, Core only speaks through it.
    public typealias Sink = @Sendable (String) -> Void

    /// Test seam: runs on the SQLite side the comparator is about to check,
    /// after every row is written and before `compare` (a real row cannot be
    /// deleted — every evidence table refuses it by trigger — so the seam
    /// drops it from the comparator's VIEW instead).
    typealias ComparatorSeam = @Sendable (inout ImportComparator.SQLiteSide) -> Void

    /// Test seam: runs before each read of the frozen catalog inside the
    /// transaction (a file that changes under the import must be refused).
    typealias DecodeSeam = @Sendable () -> Void

    private let repository: any CatalogRepository
    private let sink: Sink
    private var comparatorSeam: ComparatorSeam?
    private var decodeSeam: DecodeSeam?
    /// The run id of the last `run` (the tests read the rows by it).
    public private(set) var lastRunID: String?

    public init(repository: any CatalogRepository, sink: @escaping Sink) {
        self.repository = repository
        self.sink = sink
    }

    func injectComparatorSeam(_ seam: ComparatorSeam?) {
        comparatorSeam = seam
    }

    func injectDecodeSeam(_ seam: DecodeSeam?) {
        decodeSeam = seam
    }

    // MARK: - Run

    public func run(_ inputs: Inputs, environment: Environment = Environment()) async -> Outcome {
        let runID = UUID().uuidString
        lastRunID = runID
        let startedAt = Int64(Date().timeIntervalSince1970)
        sink("START import \(inputs.catalogURL.path) → \(inputs.databaseURL.path) (run \(runID))")
        let outcome = await runSteps(inputs, environment: environment, runID: runID, startedAt: startedAt)
        sink(Self.outcomeLine(outcome))
        return outcome
    }

    private func runSteps(_ inputs: Inputs, environment: Environment, runID: String, startedAt: Int64) async -> Outcome {
        let gate: ImportGateFiles
        do {
            gate = try ImportGateFiles.load(inputs)
        } catch {
            return .failed(Self.words(error))
        }
        let refusals = ImportGate.runLevelRefusals(gate.runInput(environment: environment))
        if !refusals.isEmpty { return .refused(refusals) }
        switch await repository.open(at: inputs.databaseURL) {
        case .readWrite: break
        case .readOnly(let reason): return .failed("the target opened read-only: \(reason)")
        case .refused(let reason): return .failed("the target did not open: \(reason)")
        }
        let plan = ImportPlan(inputs: inputs, gate: gate, runID: runID, startedAt: startedAt, seam: comparatorSeam,
                              decodeSeam: decodeSeam, sink: sink)
        let outcome = await importIntoOpenTarget(plan)
        await repository.close()
        return outcome
    }

    /// The target must be EMPTY (contract §10a D′: one import, into a fresh
    /// database); then the one transaction.
    private func importIntoOpenTarget(_ plan: ImportPlan) async -> Outcome {
        do {
            let counts = try await repository.read { try $0.recordCounts() }
            if !counts.isEmpty { return .refused([.targetNotEmpty(counts)]) }
        } catch {
            return .failed(Self.words(error))
        }
        return await transact(plan)
    }

    /// ONE write. The body's result travels out through a locked box (the
    /// closure is `@Sendable` and may not write captured variables).
    private func transact(_ plan: ImportPlan) async -> Outcome {
        let box = ImportResultBox()
        let written = await repository.write(as: .importRun) { transaction in
            do {
                box.set(.success(try plan.run(transaction)))
            } catch let abort as ImportAbort {
                box.set(.failure(abort))
                throw abort
            } catch {
                let abort = ImportAbort.failed(Self.words(error))
                box.set(.failure(abort))
                throw abort
            }
        }
        switch (written, box.result) {
        case (.committed, .success(let reconciliation)?):
            return .imported(reconciliation)
        case (_, .failure(let abort)?):
            return abort.outcome
        case (.refused(let reason), _):
            return .failed(reason)
        case (.generationMismatch(let expected, let found), _):
            return .failed("another writer advanced the catalog (expected generation \(expected), found \(found))")
        case (.committed, nil):
            return .failed("the import committed without a result — this is a bug")
        }
    }

    // MARK: - Words

    static func words(_ error: Error) -> String {
        if let abort = error as? ImportAbort { return abort.words }
        if let refusal = error as? ImportFailure { return refusal.words }
        return String(describing: error)
    }

    static func outcomeLine(_ outcome: Outcome) -> String {
        switch outcome {
        case .imported(let r): return "OUTCOME imported · " + r.line
        case .refused(let refusals): return "OUTCOME refused · " + refusals.map(\.words).joined(separator: " · ")
        case .rolledBack(let misses): return "OUTCOME rolled back · \(misses.count) miss(es) · " + misses.prefix(5).map(\.words).joined(separator: " · ")
        case .failed(let words): return "OUTCOME failed · " + words
        }
    }
}

// MARK: - How a run ends inside the transaction

/// Thrown inside the write body to roll it back with a named outcome.
enum ImportAbort: Error {
    case refused([ImportGate.RunRefusal])
    case rolledBack([ImportComparator.Miss])
    case failed(String)

    var outcome: CatalogImporter.Outcome {
        switch self {
        case .refused(let r): return .refused(r)
        case .rolledBack(let m): return .rolledBack(m)
        case .failed(let w): return .failed(w)
        }
    }

    var words: String {
        switch self {
        case .refused(let r): return r.map(\.words).joined(separator: " · ")
        case .rolledBack(let m): return m.map(\.words).joined(separator: " · ")
        case .failed(let w): return w
        }
    }
}

/// A file or a row the importer cannot use, in words (becomes `.failed`).
struct ImportFailure: Error {
    let words: String
}

/// The body's result, crossing from the store's queue back to the actor.
/// (For Rick: a mutex around one optional.)
final class ImportResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Result<ImportReconciliation, ImportAbort>?

    var result: Result<ImportReconciliation, ImportAbort>? { lock.withLock { stored } }

    func set(_ result: Result<ImportReconciliation, ImportAbort>) {
        lock.withLock { stored = result }
    }
}

// MARK: - The gate files, decoded once before anything is written

/// The frozen catalog's header and hash plus every other input file,
/// decoded through the importer's own mirrors. The catalog's ROWS are not
/// here: they are decoded inside the transaction (twice, independently).
struct ImportGateFiles: Sendable {
    let catalogSHA256: String
    let catalogVersion: Int
    let catalogGeneration: Int
    let report: IntegrityReportJSON
    let audit: AuditMarkerJSON?
    let events: EventsDecisionsJSON?
    let ignored: IgnoredContentJSON?
    let ledger: LedgerLinesJSON?
    let backfill: BackfillMarkerJSON?

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ inputs: CatalogImporter.Inputs) throws -> ImportGateFiles {
        let catalogData = try bytes(inputs.catalogURL, "catalog.json")
        let header = JSONCatalogHeader.probe(at: inputs.catalogURL) ?? (version: 1, generation: 0)
        let report = try IntegrityReportJSON.decode(try bytes(inputs.integrityURL, "integrity-latest.json"))
        let audit = try optional(inputs.auditURL, "catalog-audit.json", AuditMarkerJSON.decode)
        return ImportGateFiles(
            catalogSHA256: sha256(of: catalogData), catalogVersion: header.version, catalogGeneration: header.generation,
            report: report, audit: audit,
            events: try optional(inputs.eventsURL, "events-decisions.json", EventsDecisionsJSON.decode),
            ignored: try optional(inputs.ignoredURL, "ignored-content.json", IgnoredContentJSON.decode),
            ledger: try optional(inputs.ledgerURL, "media-ledger.jsonl") { LedgerLinesJSON.decode($0) },
            backfill: try optional(inputs.backfillURL, "fullhash-backfill.json", BackfillMarkerJSON.decode))
    }

    private static func bytes(_ url: URL, _ name: String) throws -> Data {
        do {
            return try Data(contentsOf: url)
        } catch {
            throw ImportFailure(words: "\(name) could not be read at \(url.path): \(error.localizedDescription)")
        }
    }

    /// A sidecar that is absent is nil; one that is present but damaged is a
    /// failure in words (never silently empty).
    private static func optional<T>(_ url: URL?, _ name: String, _ decode: (Data) throws -> T) throws -> T? {
        guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            return try decode(try bytes(url, name))
        } catch let failure as ImportFailure {
            throw failure
        } catch {
            throw ImportFailure(words: "\(name) could not be decoded: \(error)")
        }
    }

    func runInput(environment: CatalogImporter.Environment) -> ImportGate.RunInput {
        ImportGate.RunInput(catalogVersion: catalogVersion, catalogGeneration: catalogGeneration, catalogSHA256: catalogSHA256,
                            report: report.facts, audit: audit?.facts, duplicateEventIDs: events?.duplicateEventIDs ?? [],
                            openDeleteDuplicatesPlans: environment.openDeleteDuplicatesPlans,
                            openAngelBatches: environment.openAngelBatches, runningWriters: environment.runningWriters)
    }
}

// MARK: - The plan the transaction runs

/// Everything the write body needs, by value. `run` is the whole import in
/// order; each pass is its own extension file.
struct ImportPlan: Sendable {
    let inputs: CatalogImporter.Inputs
    let gate: ImportGateFiles
    let runID: String
    let startedAt: Int64
    let seam: CatalogImporter.ComparatorSeam?
    let decodeSeam: CatalogImporter.DecodeSeam?
    let sink: CatalogImporter.Sink

    /// The audit marker is required by the gate; by the time the plan runs it is there.
    var audit: AuditMarkerJSON { gate.audit ?? AuditMarkerJSON(startedAt: CatalogJSONDate(unixSeconds: 0), finishedAt: nil,
                                                               outcome: "", partial: true, counts: [:], marked: 0, rows: nil,
                                                               savedGeneration: nil) }

    func run(_ tx: any CatalogTransaction) throws -> ImportReconciliation {
        try tx.insertImportRun(importRun())
        let rows = try rowPass(tx)                      // decode #1 lives and dies in here
        try relationPass(tx, rows)
        let sidecars = try sidecarPass(tx, rows)
        try comparatorPass(tx)                          // decode #2, independent
        var reconciliation = try tx.importReconciliation(run: runID)
        reconciliation.membersListed = sidecars.membersListed
        reconciliation.ledgerUnparseable = gate.ledger?.unparseable.count ?? 0
        try tx.finishImportRun(runID, counters: CatalogRow.ImportCounters(
            rowsBefore: reconciliation.rowsBefore, rowsMain: reconciliation.rowsMain,
            rowsQuarantine: reconciliation.rowsQuarantine, digestsSeen: reconciliation.digests,
            knowledgeRows: reconciliation.knowledgeRows), finishedAt: Int64(Date().timeIntervalSince1970))
        return reconciliation
    }

    private func importRun() -> CatalogRow.ImportRun {
        CatalogRow.ImportRun(
            runID: runID, startedAt: startedAt, sourceSHA256: gate.catalogSHA256, sourceGeneration: gate.catalogGeneration,
            integrityRunID: gate.report.runID, auditRunStartedAt: audit.startedAt.unixSeconds,
            auditRunFinishedAt: audit.finishedAt?.unixSeconds ?? audit.startedAt.unixSeconds,
            auditGeneration: audit.savedGeneration ?? gate.catalogGeneration,
            integrityStartedAt: gate.report.startedAt.unixSeconds,
            integrityGeneration: gate.report.snapshotGeneration ?? gate.catalogGeneration)
    }

    /// The frozen file, read again and hashed against the gate's hash BEFORE
    /// it is decoded (a catalog that changes under the import is refused).
    func decodeCatalog() throws -> CatalogFileJSON {
        decodeSeam?()
        let data: Data
        do {
            data = try Data(contentsOf: inputs.catalogURL)
        } catch {
            throw ImportFailure(words: "catalog.json could not be read: \(error.localizedDescription)")
        }
        let now = ImportGateFiles.sha256(of: data)
        guard now == gate.catalogSHA256 else {
            throw ImportAbort.refused([.catalogChangedDuringImport(before: gate.catalogSHA256, after: now)])
        }
        do {
            return try CatalogFileJSON.decode(data)
        } catch {
            throw ImportFailure(words: "catalog.json could not be decoded: \(error)")
        }
    }
}
