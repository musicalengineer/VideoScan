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
// Two modes (app wiring, 2026-10-17). `.commit` is the import. `.dryRun`
// runs the IDENTICAL flow — gate, one transaction, rows, sidecars,
// comparator, finish — against a database in a scratch folder the importer
// creates for the run, then ALWAYS rolls the transaction back (by throwing
// `ImportAbort.dryRunPassed` from inside the body) and removes the scratch
// folder. Nothing at `inputs.databaseURL` is touched by a dry run; a gate
// refusal or a comparator miss reads exactly as it would in a real run.
// A `.commit` writes a STAGING folder beside `inputs.databaseURL` and
// publishes it there only when imported, verified and permitted (+Staging,
// codex 2026-10-17 round 2 P1): no other outcome ever creates the target.
//
// Stop (the MFO row's Stop button): `stopRequested` is asked BEFORE the
// target opens and at each phase boundary inside the transaction (after
// the rows, after the sidecars, after the comparator). A raised flag throws
// `ImportAbort.stopped`, the store rolls back, the outcome is `.stopped` —
// never `.imported`. Between those boundaries the body runs to the next one.
//
// Memory (worst case, 100k rows): the catalog is decoded TWICE — once for
// the row pass, once for the comparator — but never both at once: the row
// pass runs in its own function and releases its decode before the
// comparator reads the file again. Peak ≈ one decoded catalog (≈ 2–3 KB per
// row: the typed mirror plus its raw object) + the comparator's two sides
// (ordinal-keyed landings, knowledge keys, derived keys — small per row) +
// the per-row facts map (id → digest, file id, path; ≈ 250 bytes per row).
// A dry run adds its quarantine sample: at most `quarantineSampleCap` (200)
// short rows. Nothing is O(rows²). Measured by CatalogImporterScaleTests.
//
// Outcomes (playbook §7: every case named, no `default:` at the caller):
//   .imported(reconciliation)   committed; the §f line is in the value
//   .dryRunPassed(report)       the dry run reached the finish and rolled
//                               back by design; the report carries the §f
//                               line and the first quarantine words
//   .refused([RunRefusal])      a gate said no; nothing was written
//   .rolledBack([Miss])         the comparator found a miss; the store rolled
//                               back; the database is as empty as before
//   .stopped                    Stop was requested; the store rolled back (or
//                               the target never opened); nothing written
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
        public static let catalogFileName = CatalogDDL.ImportSourceFile.catalog.rawValue
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

    /// Commit, or prove and roll back. (For Rick: a two-valued enum, not a
    /// Bool, so the call site reads `mode: .dryRun`.)
    public enum Mode: Sendable, Equatable {
        case dryRun
        case commit
    }

    /// One quarantined row as the dry run reports it (the detail view's
    /// "first 200 quarantine words").
    public struct QuarantineSample: Sendable, Equatable {
        public var ordinal: Int
        public var jsonRowID: String
        public var reasonCode: String
        public var words: String

        public init(ordinal: Int, jsonRowID: String, reasonCode: String, words: String) {
            self.ordinal = ordinal
            self.jsonRowID = jsonRowID
            self.reasonCode = reasonCode
            self.words = words
        }
    }

    /// What a passed dry run hands back: the §f line it would have committed
    /// and the first `quarantineSampleCap` quarantined rows, in file order.
    public struct DryRunReport: Sendable, Equatable {
        public var reconciliation: ImportReconciliation
        public var quarantineSample: [QuarantineSample]

        public init(reconciliation: ImportReconciliation, quarantineSample: [QuarantineSample]) {
            self.reconciliation = reconciliation
            self.quarantineSample = quarantineSample
        }
    }

    /// How many quarantine rows a dry run carries out (bounded memory).
    public static let quarantineSampleCap = 200

    public enum Outcome: Sendable, Equatable {
        case imported(ImportReconciliation)
        case dryRunPassed(DryRunReport)
        case refused([ImportGate.RunRefusal])
        case rolledBack([ImportComparator.Miss])
        case stopped
        case failed(String)
    }

    /// One line for the console / catalog.log / videoscan.log; the app wires
    /// the sink, Core only speaks through it.
    public typealias Sink = @Sendable (String) -> Void

    /// "Has Stop been pressed?" — asked before the target opens and at each
    /// phase boundary of the transaction. nil = never.
    public typealias StopCheck = @Sendable () -> Bool

    /// Commit mode: "may the staged set become catalog.sqlite now?" — asked
    /// ONCE, after the commit, the close and the staged verify, immediately
    /// before the first publish rename. false = Stop won: nothing is
    /// published, the outcome is `.stopped` (codex 2026-10-17 P1 fence,
    /// +Staging). nil = `stopRequested` is not raised. The app passes an
    /// atomic claim, so Stop and publish cannot both win.
    public typealias PublishPermit = @Sendable () -> Bool

    /// Test seam: runs on the SQLite side the comparator is about to check,
    /// after every row is written and before `compare` (a real row cannot be
    /// deleted — every evidence table refuses it by trigger — so the seam
    /// drops it from the comparator's VIEW instead).
    typealias ComparatorSeam = @Sendable (inout ImportComparator.SQLiteSide) -> Void

    /// Test seam: runs before each read of the frozen catalog inside the
    /// transaction (a file that changes under the import must be refused).
    typealias DecodeSeam = @Sendable () -> Void

    /// Test seam: runs between the outer empty-target check and the write
    /// transaction (codex D′ #7: a write that lands in that window must be
    /// caught by the check repeated INSIDE the transaction).
    typealias PreTransactionSeam = @Sendable () async -> Void

    private let repository: any CatalogRepository
    private let sink: Sink
    private var comparatorSeam: ComparatorSeam?
    private var decodeSeam: DecodeSeam?
    private var preTransactionSeam: PreTransactionSeam?
    /// The run id of the last `run` (the tests read the rows by it).
    public private(set) var lastRunID: String?
    /// Where the last dry run put its database — removed when the run ended
    /// (the tests check that it is gone).
    public private(set) var lastDryRunScratch: URL?
    /// Where the last commit run staged its database (+Staging): published
    /// and emptied on `.imported`, kept otherwise until the next import moves it aside.
    public private(set) var lastStagingFolder: URL?

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

    func injectPreTransactionSeam(_ seam: PreTransactionSeam?) {
        preTransactionSeam = seam
    }

    // MARK: - Run

    public func run(_ inputs: Inputs, environment: Environment = Environment(), mode: Mode = .commit,
                    stopRequested: StopCheck? = nil, publishPermit: PublishPermit? = nil) async -> Outcome {
        let runID = UUID().uuidString
        lastRunID = runID
        let startedAt = Int64(Date().timeIntervalSince1970)
        let target = Self.target(for: mode, inputs: inputs, runID: runID)
        if mode == .dryRun { lastDryRunScratch = target.deletingLastPathComponent() }
        if mode == .commit { lastStagingFolder = target.deletingLastPathComponent() }
        sink("START import\(mode == .dryRun ? " (dry run)" : "") \(inputs.catalogURL.path) → \(target.path) (run \(runID))")
        var outcome = await runSteps(inputs, environment: environment, mode: mode, target: target,
                                     stopRequested: stopRequested, runID: runID, startedAt: startedAt)
        // The staging folder exists only once the run got past its refusals
        // (+Staging `prepare`); from then on every outcome lands through it.
        if mode == .commit, FileManager.default.fileExists(atPath: target.deletingLastPathComponent().path) {
            outcome = await ImportStaging.land(outcome, staging: target, target: inputs.databaseURL, repository: repository,
                                               permit: publishPermit ?? { stopRequested?() != true }, sink: sink)
        }
        if mode == .dryRun { Self.removeScratch(target.deletingLastPathComponent()) }
        sink(Self.outcomeLine(outcome))
        return outcome
    }

    /// A dry run's database lives in a scratch folder of its own (never the
    /// inputs' target); a commit's is STAGED beside the inputs' target and
    /// published onto it only when imported (+Staging, codex 2026-10-17 P1).
    private static func target(for mode: Mode, inputs: Inputs, runID: String) -> URL {
        switch mode {
        case .commit:
            return ImportStaging.database(target: inputs.databaseURL, runID: runID)
        case .dryRun:
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("videoscan-import-dryrun-\(runID)", isDirectory: true)
                .appendingPathComponent(Inputs.databaseFileName)
        }
    }

    /// Scratch only: the dry run's own folder (database, high-water files,
    /// WAL) — nothing else is ever removed here.
    private static func removeScratch(_ folder: URL) {
        guard folder.lastPathComponent.hasPrefix("videoscan-import-dryrun-") else { return }
        try? FileManager.default.removeItem(at: folder)
    }

    private func runSteps(_ inputs: Inputs, environment: Environment, mode: Mode, target: URL,
                          stopRequested: StopCheck?, runID: String, startedAt: Int64) async -> Outcome {
        let gate: ImportGateFiles
        do {
            gate = try ImportGateFiles.load(inputs)
        } catch let abort as ImportAbort {
            return abort.outcome
        } catch {
            return .failed(Self.words(error))
        }
        let refusals = ImportGate.runLevelRefusals(gate.runInput(environment: environment))
        if !refusals.isEmpty { return .refused(refusals) }
        if stopRequested?() == true { return .stopped }
        if mode == .dryRun {
            do {
                try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                return .failed("the dry run's scratch folder could not be made: \(error.localizedDescription)")
            }
        } else if let early = await ImportStaging.prepare(target: inputs.databaseURL, staging: target,
                                                          repository: repository, sink: sink) {
            return early
        }
        switch await repository.open(at: target) {
        case .readWrite: break
        case .readOnly(let reason): return .failed("the target opened read-only: \(reason)")
        case .refused(let reason): return .failed("the target did not open: \(reason)")
        }
        let plan = ImportPlan(inputs: inputs, gate: gate, runID: runID, startedAt: startedAt, mode: mode,
                              stopRequested: stopRequested, seam: comparatorSeam, decodeSeam: decodeSeam, sink: sink)
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
        await preTransactionSeam?()
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
        case .dryRunPassed(let report): return "OUTCOME dry run passed — nothing written · " + report.reconciliation.line
        case .refused(let refusals): return "OUTCOME refused · " + refusals.map(\.words).joined(separator: " · ")
        case .rolledBack(let misses): return "OUTCOME rolled back · \(misses.count) miss(es) · " + misses.prefix(5).map(\.words).joined(separator: " · ")
        case .stopped: return "OUTCOME stopped · nothing written"
        case .failed(let words): return "OUTCOME failed · " + words
        }
    }
}

// MARK: - How a run ends inside the transaction

/// Thrown inside the write body to roll it back with a named outcome.
enum ImportAbort: Error {
    case refused([ImportGate.RunRefusal])
    case rolledBack([ImportComparator.Miss])
    /// The dry run reached the finish: roll back by design, carry the proof out.
    case dryRunPassed(CatalogImporter.DryRunReport)
    case stopped
    case failed(String)

    var outcome: CatalogImporter.Outcome {
        switch self {
        case .refused(let r): return .refused(r)
        case .rolledBack(let m): return .rolledBack(m)
        case .dryRunPassed(let report): return .dryRunPassed(report)
        case .stopped: return .stopped
        case .failed(let w): return .failed(w)
        }
    }

    var words: String {
        switch self {
        case .refused(let r): return r.map(\.words).joined(separator: " · ")
        case .rolledBack(let m): return m.map(\.words).joined(separator: " · ")
        case .dryRunPassed: return "dry run passed — rolled back by design"
        case .stopped: return "stopped — rolled back"
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
    /// The SHA-256 of every sidecar's bytes as the gate read them (codex D′
    /// #3): the comparator re-reads each file and re-hashes it.
    let sidecarSHA256: [CatalogDDL.ImportSourceFile: String]
    let integritySHA256: String

    static func sha256(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func load(_ inputs: CatalogImporter.Inputs) throws -> ImportGateFiles {
        var reader = GateReader()
        let catalogData = try reader.bytes(inputs.catalogURL, .catalog)
        let header = JSONCatalogHeader.probe(at: inputs.catalogURL) ?? (version: 1, generation: 0)
        let integrityData = try reader.bytes(inputs.integrityURL, name: Inputs.integrityFileName)
        let report = try GateReader.decode(integrityData, Inputs.integrityFileName, IntegrityReportJSON.decode)
        let audit = try reader.optional(inputs.auditURL, .catalogAudit, AuditMarkerJSON.decode)
        let events = try reader.optional(inputs.eventsURL, .eventsDecisions, EventsDecisionsJSON.decode)
        let ignored = try reader.optional(inputs.ignoredURL, .ignoredContent, IgnoredContentJSON.decode)
        let ledger = try reader.optional(inputs.ledgerURL, .mediaLedger) { LedgerLinesJSON.decode($0) }
        let backfill = try reader.optional(inputs.backfillURL, .fullHashBackfill, BackfillMarkerJSON.decode)
        return ImportGateFiles(
            catalogSHA256: sha256(of: catalogData), catalogVersion: header.version, catalogGeneration: header.generation,
            report: report, audit: audit, events: events, ignored: ignored, ledger: ledger, backfill: backfill,
            sidecarSHA256: reader.hashes, integritySHA256: sha256(of: integrityData))
    }

    typealias Inputs = CatalogImporter.Inputs

    /// Reads and hashes each input file once. (For Rick: a tiny accumulator
    /// so `load` stays a list of named reads.)
    struct GateReader {
        var hashes: [CatalogDDL.ImportSourceFile: String] = [:]

        mutating func bytes(_ url: URL, _ file: CatalogDDL.ImportSourceFile) throws -> Data {
            let data = try bytes(url, name: file.rawValue, lines: file == .mediaLedger)
            hashes[file] = ImportGateFiles.sha256(of: data)
            return data
        }

        /// Read, then the duplicate-key pre-pass (codex D′ #2): a key that
        /// occurs twice in one object refuses the run before any decode.
        func bytes(_ url: URL, name: String, lines: Bool = false) throws -> Data {
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw ImportFailure(words: "\(name) could not be read at \(url.path): \(error.localizedDescription)")
            }
            if lines {
                if let found = JSONDuplicateKeyScanner.firstDuplicate(inLines: data) {
                    throw ImportAbort.refused([.duplicateJSONKey(file: name, path: "line \(found.line): \(found.duplicate.path)",
                                                                 key: found.duplicate.key, recordOrdinal: nil)])
                }
            } else if let found = JSONDuplicateKeyScanner.firstDuplicate(in: data) {
                throw ImportAbort.refused([.duplicateJSONKey(file: name, path: found.path, key: found.key,
                                                             recordOrdinal: name == Inputs.catalogFileName ? found.recordOrdinal : nil)])
            }
            return data
        }

        /// A sidecar that is absent is nil; one that is present but damaged is a
        /// failure in words (never silently empty).
        mutating func optional<T>(_ url: URL?, _ file: CatalogDDL.ImportSourceFile, _ decode: (Data) throws -> T) throws -> T? {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            return try Self.decode(try bytes(url, file), file.rawValue, decode)
        }

        static func decode<T>(_ data: Data, _ name: String, _ decode: (Data) throws -> T) throws -> T {
            do {
                return try decode(data)
            } catch let failure as ImportFailure {
                throw failure
            } catch let abort as ImportAbort {
                throw abort
            } catch {
                throw ImportFailure(words: "\(name) could not be decoded: \(error)")
            }
        }
    }

    func runInput(environment: CatalogImporter.Environment) -> ImportGate.RunInput {
        ImportGate.RunInput(catalogVersion: catalogVersion, catalogGeneration: catalogGeneration, catalogSHA256: catalogSHA256,
                            report: report.facts, audit: audit?.facts, duplicateEventIDs: events?.duplicateEventIDs ?? [],
                            openDeleteDuplicatesPlans: environment.openDeleteDuplicatesPlans,
                            openAngelBatches: environment.openAngelBatches, runningWriters: environment.runningWriters,
                            ledgerCorruptLines: ledger?.corruptLines ?? [],
                            sidecarFaults: (events?.faults ?? []) + (ignored?.faults ?? []) + (audit?.faults ?? []))
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
    let mode: CatalogImporter.Mode
    let stopRequested: CatalogImporter.StopCheck?
    let seam: CatalogImporter.ComparatorSeam?
    let decodeSeam: CatalogImporter.DecodeSeam?
    let sink: CatalogImporter.Sink

    /// The audit marker is required by the gate; by the time the plan runs it is there.
    var audit: AuditMarkerJSON { gate.audit ?? AuditMarkerJSON(startedAt: CatalogJSONDate(unixSeconds: 0), finishedAt: nil,
                                                               outcome: "", partial: true, counts: [:], marked: 0, rows: nil,
                                                               savedGeneration: nil) }

    func run(_ tx: any CatalogTransaction) throws -> ImportReconciliation {
        // codex D′ #7: the empty-target check again, now under the writer lock —
        // a write that landed between the outer check and this transaction
        // refuses the import here, and nothing of it is kept.
        let counts = try tx.recordCounts()
        if !counts.isEmpty { throw ImportAbort.refused([.targetNotEmpty(counts)]) }
        try tx.insertImportRun(importRun())
        let rows = try rowPass(tx)                      // decode #1 lives and dies in here
        try stopCheck()
        try relationPass(tx, rows)
        let sidecars = try sidecarPass(tx, rows)
        try stopCheck()
        try comparatorPass(tx)                          // decode #2, independent
        try stopCheck()
        var reconciliation = try tx.importReconciliation(run: runID)
        reconciliation.membersListed = sidecars.membersListed
        reconciliation.ledgerUnparseable = gate.ledger?.trailingPartialOrdinal == nil ? 0 : 1
        reconciliation.auditGenerationByTimeOrder = audit.savedGeneration == nil
        try tx.finishImportRun(runID, counters: CatalogRow.ImportCounters(
            rowsBefore: reconciliation.rowsBefore, rowsMain: reconciliation.rowsMain,
            rowsQuarantine: reconciliation.rowsQuarantine, digestsSeen: reconciliation.digests,
            knowledgeRows: reconciliation.knowledgeRows), finishedAt: Int64(Date().timeIntervalSince1970))
        if mode == .dryRun {
            throw ImportAbort.dryRunPassed(CatalogImporter.DryRunReport(reconciliation: reconciliation,
                                                                        quarantineSample: try quarantineSample(tx)))
        }
        return reconciliation
    }

    /// A phase boundary: Stop pressed → roll back with its own outcome.
    private func stopCheck() throws {
        if stopRequested?() == true { throw ImportAbort.stopped }
    }

    /// The first `quarantineSampleCap` quarantined rows of this run, in
    /// storage (file) order — read through the transaction before the dry
    /// run rolls it back.
    private func quarantineSample(_ tx: any CatalogTransaction) throws -> [CatalogImporter.QuarantineSample] {
        var sample: [CatalogImporter.QuarantineSample] = []
        try tx.quarantineEntries(run: runID) { entry in
            guard sample.count < CatalogImporter.quarantineSampleCap else { return }
            sample.append(CatalogImporter.QuarantineSample(ordinal: entry.ordinal, jsonRowID: entry.jsonRowID,
                                                           reasonCode: entry.reasonCode.rawValue, words: entry.words))
        }
        return sample
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
