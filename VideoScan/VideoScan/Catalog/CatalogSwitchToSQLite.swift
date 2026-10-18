// CatalogSwitchToSQLite.swift
// Catalog ▸ "Switch Catalog to SQLite…" (cutover B2, docs/design/
// catalog_cutover_f_prime_2026_10_17.md §7 and §10 "Flip"). One sentence:
// re-import the latest catalog.json, then mark catalog.sqlite as the
// catalog, so the next launch opens it and catalog.json is never written
// again.
//
// The steps, each refusing before it changes anything:
//   0. ready?  no switch yet (no `catalog.cutover`), catalog.sqlite beside
//      the catalog holds a FINISHED, comparator-ok import (the rehearsal),
//      the app is writable, no Import to SQLite is running; then every
//      accepted edit is FLUSHED to catalog.json (B2.1, codex P1-4) so the
//      import reads them;
//   1. MOVE the rehearsal aside — catalog.sqlite (+ -wal, -shm),
//      catalog.highwater, catalog.highwater.log — into a new dated folder in
//      the same directory (`catalog-sqlite-rehearsal-<yyyyMMdd-HHmmss>/`):
//      a rename on one volume, never a delete; a folder that already exists
//      refuses;
//   2. run the EXISTING one-job import in commit mode (Audit Catalog,
//      Verify Catalog, gate, rows, sidecars, comparator — the MFO job; this
//      file does not duplicate it) and await it: anything but `.imported`
//      stops here, the rehearsal stays in its folder, no latch;
//   3. in ONE main-actor turn: an edit accepted while the import ran and
//      not yet saved stops the switch (it is flushed to catalog.json first,
//      so nothing is lost; codex P1-4); else freeze catalog.json (read-only
//      for the rest of the session — no edit can be saved to it after this
//      point). Then read catalog.json ONCE and prove it is the file that was
//      imported: its SHA-256 equals `import_runs.source_sha256` of the run
//      just made — an edit saved between the import and the freeze would
//      otherwise be left behind; a mismatch un-freezes and stops, no latch;
//   4. move the Master Archive designation into `catalog_state` (one
//      commit through the door `cutover`, GH #167's guard) — the designation
//      decoded from THOSE SAME BYTES, the ones the importer hashed (codex
//      P1-5), never a copy taken before the import;
//   5. write `catalog.cutover` (atomic publish, F_FULLFSYNC) — ONLY now;
//   6. the person quits; the next launch opens catalog.sqlite (B1's rule).
//
// Outcomes: done (latch written) · notReady(words) · failed(words: what
// happened, where the rehearsal files are, that no latch was written).
// START / OUTCOME lines through the model's one sink.
//
// (For Rick: a little state machine whose only irreversible step is the
// last one — a 200-byte file — and every earlier step leaves the catalog
// exactly as it was, plus a folder of moved-aside files.)

import AppKit
import CryptoKit
import SwiftUI
import VideoScanCore

/// The sheet's item.
struct CatalogSwitchRequest: Identifiable, Equatable {
    let id = UUID()
}

enum CatalogSwitchPhase: Equatable {
    case confirming
    case running(String)
    case done(String)
    case failed(String)
}

/// What the import step reports back to the switch.
enum CatalogSwitchImportResult: Equatable {
    case imported
    case notImported(String)
}

// MARK: - The flow (pure steps + one async run)

enum CatalogSwitch {

    static let rehearsalPrefix = "catalog-sqlite-rehearsal-"

    /// The files a rehearsal import leaves beside the catalog.
    static func rehearsalFiles(in folder: URL) -> [URL] {
        let db = folder.appendingPathComponent(CatalogAuthority.databaseFileName)
        return [db, URL(fileURLWithPath: db.path + "-wal"), URL(fileURLWithPath: db.path + "-shm"),
                CatalogHighWater.url(besideDatabaseAt: db), CatalogHighWaterLedger.url(besideDatabaseAt: db)]
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func rehearsalFolder(in folder: URL, at date: Date) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return folder.appendingPathComponent(rehearsalPrefix + formatter.string(from: date), isDirectory: true)
    }

    /// Step 0, read-only. nil = ready; else the words.
    static func notReadyWords(folder: URL) async -> String? {
        if FileManager.default.fileExists(atPath: folder.appendingPathComponent(CatalogAuthority.latchFileName).path) {
            return "the catalog was already switched to SQLite (\(CatalogAuthority.latchFileName) is there)"
        }
        let db = folder.appendingPathComponent(CatalogAuthority.databaseFileName)
        guard FileManager.default.fileExists(atPath: db.path) else {
            return "there is no \(CatalogAuthority.databaseFileName) beside the catalog — run Import to SQLite… first"
        }
        switch await lastImport(at: db) {
        case .success(nil): return "\(CatalogAuthority.databaseFileName) holds no finished import checked by the comparator — run Import to SQLite… again"
        case .success: return nil
        case .failure(let words): return words.text
        }
    }

    struct Words: Error { let text: String }

    /// The newest finished import in the database at `db` (opened and closed here).
    static func lastImport(at db: URL) async -> Result<CatalogRow.FinishedImport?, Words> {
        let repository = GRDBCatalogRepository()
        if case .refused(let reason) = await repository.open(at: db) {
            await repository.close()
            return .failure(Words(text: "\(CatalogAuthority.databaseFileName) would not open: \(reason)"))
        }
        // Closed (awaited) before returning: the next step renames these files.
        let result: Result<CatalogRow.FinishedImport?, Words>
        do {
            result = .success(try await repository.read { try $0.lastFinishedImport() })
        } catch {
            result = .failure(Words(text: "\(CatalogAuthority.databaseFileName) could not be read: \(error)"))
        }
        await repository.close()
        return result
    }

    /// Step 1: MOVE (rename) the rehearsal files into a NEW dated folder.
    /// Returns the folder, or the words (and which files already moved).
    static func moveRehearsalAside(folder: URL, now: Date) -> Result<URL, Words> {
        let destination = rehearsalFolder(in: folder, at: now)
        guard !FileManager.default.fileExists(atPath: destination.path) else {
            return .failure(Words(text: "\(destination.lastPathComponent) already exists — nothing was moved"))
        }
        do {
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: false)
        } catch {
            return .failure(Words(text: "could not make \(destination.path): \(error.localizedDescription) — nothing was moved"))
        }
        var moved: [String] = []
        for file in rehearsalFiles(in: folder) {
            do {
                // moveItem is a rename on one volume and refuses an existing target.
                try FileManager.default.moveItem(at: file, to: destination.appendingPathComponent(file.lastPathComponent))
                moved.append(file.lastPathComponent)
            } catch {
                return .failure(Words(text: "could not move \(file.lastPathComponent) (\(error.localizedDescription)); "
                                      + "already moved into \(destination.path): \(moved.isEmpty ? "nothing" : moved.joined(separator: ", "))"))
            }
        }
        return .success(destination)
    }

    /// What the switch proves and moves, read from catalog.json ONCE: its
    /// SHA-256 and the Master Archive designation those bytes carry (as
    /// catalog_state stores it). Memory: the file is mapped, not copied;
    /// the decoder walks it once to find the one key (transient, about the
    /// file's size — a one-time step of the switch).
    struct ImportedSource: Equatable {
        let sha256: String
        let designationJSON: String?
    }

    static func importedSource(at url: URL) -> Result<ImportedSource, Words> {
        let data: Data
        do {
            data = try Data(contentsOf: url, options: .mappedIfSafe)
        } catch {
            return .failure(Words(text: "catalog.json could not be read: \(error.localizedDescription)"))
        }
        let sha = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        struct Header: Decodable { let masterArchive: MasterArchiveDesignation? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let header = try decoder.decode(Header.self, from: data)
            return .success(ImportedSource(sha256: sha, designationJSON: CatalogCommitter.json(header.masterArchive)))
        } catch {
            return .failure(Words(text: "catalog.json's Master Archive designation could not be read: \(error)"))
        }
    }

    /// The latch's content: when, which run, which bytes.
    static func latchData(_ run: CatalogRow.FinishedImport, at date: Date) -> Data {
        let iso = ISO8601DateFormatter().string(from: date)
        let text = #"{"switchedAt":"\#(iso)","importRun":"\#(run.runID)","sourceSHA256":"\#(run.sourceSHA256)","sourceGeneration":\#(run.sourceGeneration)}"#
        return Data((text + "\n").utf8)
    }
}

// MARK: - Running it

/// What the switch needs from the app (a seam: tests pass a scripted import).
struct CatalogSwitchEnvironment {
    var folder: URL
    var catalogURL: URL
    var now: () -> Date = Date.init
    var runImport: @MainActor () async -> CatalogSwitchImportResult
    /// true = freeze catalog.json for the session; false = undo the freeze.
    var freezeJSON: @MainActor (Bool) -> Void
    /// Save every accepted edit to catalog.json now (the JSON path's
    /// saveNow); false = it did not reach disk.
    var flushJSON: @MainActor () -> Bool = { true }
    /// An accepted edit not yet saved to catalog.json.
    var hasUnsavedJSON: @MainActor () -> Bool = { false }
    var sink: @MainActor (String) -> Void
    var progress: @MainActor (String) -> Void = { _ in }
    /// Step 0's app half: words when the app cannot start the import now
    /// (a job running, a read-only session) — checked BEFORE anything moves.
    var busyWords: @MainActor () -> String? = { nil }
}

@MainActor
enum CatalogSwitchRun {

    /// Steps 0–5. Returns `.done` only when the latch was written.
    static func run(_ env: CatalogSwitchEnvironment) async -> CatalogSwitchPhase {
        env.sink("Catalog store: START Switch Catalog to SQLite — move the rehearsal aside, import catalog.json again, then switch")
        if let words = env.busyWords() { return fail(env, words) }
        if let words = await CatalogSwitch.notReadyWords(folder: env.folder) { return fail(env, words) }
        guard env.flushJSON() else {
            return fail(env, "catalog.json could not be saved before the import (see the catalog store's words above) — nothing was moved")
        }
        env.progress("Moving the rehearsal catalog.sqlite aside…")
        let aside: URL
        switch CatalogSwitch.moveRehearsalAside(folder: env.folder, now: env.now()) {
        case .failure(let words): return fail(env, words.text)
        case .success(let folder): aside = folder
        }
        env.sink("Catalog store: moved the rehearsal into \(aside.path) (moved, not deleted)")
        env.progress("Importing catalog.json (Audit, Verify, import — see Media File Operations)…")
        if case .notImported(let words) = await env.runImport() {
            return fail(env, "the import did not finish: \(words). The rehearsal is in \(aside.path); nothing was switched")
        }
        return await finish(env, aside: aside)
    }

    /// Steps 3–5, after `.imported`.
    private static func finish(_ env: CatalogSwitchEnvironment, aside: URL) async -> CatalogSwitchPhase {
        // One main-actor turn: no edit can slip between the check and the freeze.
        if env.hasUnsavedJSON() {
            let saved = env.flushJSON()
            return fail(env, "an edit was made while the import ran"
                        + (saved ? " (it is saved in catalog.json)" : " (it could NOT be saved — see the catalog store's words)")
                        + " — run Switch again; nothing was switched")
        }
        env.freezeJSON(true)
        let db = env.folder.appendingPathComponent(CatalogAuthority.databaseFileName)
        guard case .success(let made?) = await CatalogSwitch.lastImport(at: db) else {
            env.freezeJSON(false)
            return fail(env, "the new \(CatalogAuthority.databaseFileName) holds no finished import — nothing was switched")
        }
        let catalogURL = env.catalogURL
        let source: CatalogSwitch.ImportedSource
        switch await Task.detached(operation: { CatalogSwitch.importedSource(at: catalogURL) }).value {
        case .failure(let words):
            env.freezeJSON(false)
            return fail(env, "\(words.text) — nothing was switched")
        case .success(let read):
            source = read
        }
        guard source.sha256 == made.sourceSHA256 else {
            env.freezeJSON(false)
            return fail(env, "catalog.json changed after the import (an edit was saved meanwhile) — run Switch again; nothing was switched")
        }
        if let words = await seedDesignation(source.designationJSON, db: db) {
            env.freezeJSON(false)
            return fail(env, "the Master Archive designation could not be moved into catalog.sqlite: \(words) — nothing was switched")
        }
        do {
            try AtomicFilePublish.write(CatalogSwitch.latchData(made, at: env.now()),
                                        to: env.folder.appendingPathComponent(CatalogAuthority.latchFileName),
                                        durability: .fullFsync, createIntermediates: false)
        } catch {
            env.freezeJSON(false)
            return fail(env, "\(CatalogAuthority.latchFileName) could not be written (\(error.localizedDescription)) — nothing was switched")
        }
        let words = "catalog.sqlite is now the catalog (import \(made.runID), catalog.json generation \(made.sourceGeneration)). "
            + "catalog.json is frozen. Quit VideoScan and open it again to start on catalog.sqlite."
        env.sink("Catalog store: OUTCOME switched — " + words)
        return .done(words)
    }

    /// Step 4: the designation into catalog_state (nil = done).
    private static func seedDesignation(_ json: String?, db: URL) async -> String? {
        guard let json else { return nil }
        let repository = GRDBCatalogRepository()
        let opened = await repository.open(at: db)
        guard opened == .readWrite else {
            await repository.close()
            return "the database opened as \(opened)"
        }
        let outcome = await CatalogCommit.run(CatalogCommit.Plan(door: .cutover, items: [],
                                                                 designation: .current(json: json, clearAuthorized: false)),
                                              on: repository)
        await repository.close()
        switch outcome {
        case .committed, .nothingWritten: return nil
        case .refused(let words, _): return words
        case .generationMismatch(let expected, let found): return "generation \(found), expected \(expected)"
        }
    }

    private static func fail(_ env: CatalogSwitchEnvironment, _ words: String) -> CatalogSwitchPhase {
        env.sink("Catalog store: OUTCOME not switched — " + words)
        return .failed(words)
    }
}

// MARK: - The app's environment

extension VideoScanModel {

    /// The switch with the real import job, the real freeze and the one sink.
    func catalogSwitchEnvironment(center: MediaFileOperationsCenter) -> CatalogSwitchEnvironment {
        let catalogURL = URL(fileURLWithPath: catalogStore.fileLocation)
        let wasReadOnly = (store: catalogStore.isReadOnly, model: isReadOnly)
        return CatalogSwitchEnvironment(
            folder: catalogURL.deletingLastPathComponent(), catalogURL: catalogURL,
            runImport: { [weak self] in
                guard let self else { return .notImported("the catalog went away") }
                return await Self.runImportJob(center.startedByUser { $0.startImportToSQLite(model: self, mode: .commit) })
            },
            freezeJSON: { [weak self] freeze in
                guard let self else { return }
                self.catalogStore.isReadOnly = freeze || wasReadOnly.store
                self.isReadOnly = freeze || wasReadOnly.model
            },
            flushJSON: { [weak self] in
                guard let self else { return false }
                // The JSON path on purpose: before the switch catalog.json is the catalog.
                return self.catalogStore.saveNow(records: self.records)
            },
            hasUnsavedJSON: { [weak self] in self?.catalogStore.hasUnsavedChanges ?? false },
            sink: { [weak self] line in self?.catalogAuthorityNote(line) },
            progress: { [weak self] line in self?.catalogCutover.switchPhase = .running(line) },
            busyWords: { [weak self] in
                if self?.isReadOnly ?? true { return "this session is read-only — nothing can be imported" }
                if let running = center.jobs.first(where: { $0.state.isActive }) {
                    return "\(running.title) is running — wait for it to finish (the import refuses to start beside it); nothing was moved"
                }
                return nil
            })
    }

    /// Await the one-job import; `.imported` only for a finished commit run
    /// that produced its database.
    static func runImportJob(_ job: ImportToSQLiteJob) async -> CatalogSwitchImportResult {
        await job.task?.value
        switch job.state {
        case .finished where job.databaseURL != nil: return .imported
        case .finished(let summary): return .notImported(summary)
        case .failed(let message): return .notImported(message)
        case .cancelled, .cancelling: return .notImported("it was stopped")
        case .running: return .notImported("it did not finish")
        }
    }
}

// MARK: - Menu items

struct CatalogSwitchMenuItems: View {
    let model: VideoScanModel
    @ObservedObject var cutover: CatalogCutoverState
    let isReadOnly: Bool

    private var databaseBeside: Bool {
        let folder = URL(fileURLWithPath: model.catalogStore.fileLocation).deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: folder.appendingPathComponent(CatalogAuthority.databaseFileName).path)
            && !FileManager.default.fileExists(atPath: folder.appendingPathComponent(CatalogAuthority.latchFileName).path)
    }

    var body: some View {
        Button("Switch Catalog to SQLite…") {
            cutover.switchPhase = .confirming
            cutover.switchRequest = CatalogSwitchRequest()
        }
        .disabled(isReadOnly || cutover.isSQLiteAuthority || !databaseBeside)
        .help("Import catalog.json once more, then make catalog.sqlite the catalog. Enabled once Import to SQLite… has made catalog.sqlite; the sheet checks it holds a finished, comparator-checked import.")
        .accessibilityIdentifier("catalog.menu.switchToSQLite")

        Button("Reopen SQLite Catalog") {
            Task { await cutover.reopen() }
        }
        .disabled(cutover.blockedReason == nil)
        .help(cutover.blockedReason.map { "Saving to catalog.sqlite stopped: \($0). Reopen to try again." } ?? "Saving to catalog.sqlite is working.")
        .accessibilityIdentifier("catalog.menu.reopenSQLite")

        CatalogAdoptMenuItem(cutover: cutover)
    }
}

// MARK: - The sheet

struct CatalogSwitchSheetHost: ViewModifier {
    let model: VideoScanModel
    @ObservedObject var cutover: CatalogCutoverState
    @Environment(\.mediaFileOperationsCenterReference) private var center

    func body(content: Content) -> some View {
        content
            .sheet(item: $cutover.switchRequest) { _ in
                CatalogSwitchSheet(cutover: cutover).environmentObject(model)
            }
            .sheet(item: $cutover.adoptRequest) { request in
                CatalogAdoptSheet(cutover: cutover, request: request)
            }
            .onAppear {
                // B2.1 gap 1: held rows get Fill In Full Hashes, scoped to them.
                guard let center else { return }
                cutover.attachDigestJobs { [weak model, weak center] ids in
                    guard let model, let center else { return }
                    center.startFullHashBackfill(model: model, scopedTo: ids)
                }
            }
    }
}

struct CatalogSwitchSheet: View {
    @ObservedObject var cutover: CatalogCutoverState
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.mediaFileOperationsCenterReference) private var center
    @State private var notReady: String?
    @State private var checked = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Switch Catalog to SQLite").font(.title2.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Label("The rehearsal catalog.sqlite and its two high-water files are MOVED into a dated folder beside the catalog (catalog-sqlite-rehearsal-…). Nothing is deleted.", systemImage: "folder")
                Label("Import to SQLite runs once more on the latest catalog.json: Audit Catalog, Verify Catalog, the import, the comparator. It shows in Media File Operations.", systemImage: "checkmark.shield")
                Label("Only when it imports: catalog.json is frozen (read-only from then on, kept as it is), the Master Archive designation moves into catalog.sqlite, and catalog.cutover is written.", systemImage: "lock.shield")
                Label("Then quit VideoScan and open it again: it opens catalog.sqlite, and every save goes there.", systemImage: "arrow.clockwise")
            }
            .font(.system(size: 12)).foregroundStyle(.secondary).labelStyle(.titleAndIcon)
            .fixedSize(horizontal: false, vertical: true)
            phaseView
            buttons
        }
        .padding(20)
        .frame(width: 580)
        .task {
            let folder = URL(fileURLWithPath: model.catalogStore.fileLocation).deletingLastPathComponent()
            notReady = await CatalogSwitch.notReadyWords(folder: folder)
            checked = true
        }
        .accessibilityIdentifier("sheet.switchToSQLite")
    }

    @ViewBuilder private var phaseView: some View {
        switch cutover.switchPhase {
        case .confirming:
            if let notReady { Text("Not ready: \(notReady)").foregroundStyle(.red).font(.system(size: 12)) }
        case .running(let line):
            HStack { ProgressView().controlSize(.small); Text(line).font(.system(size: 12)) }
        case .done(let words):
            Text(words).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        case .failed(let words):
            Text(words).foregroundStyle(.red).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Spacer()
            switch cutover.switchPhase {
            case .confirming, .failed:
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Switch") { start() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!checked || notReady != nil || center == nil || cutover.switchPhase != .confirming)
            case .running:
                Button("Close") { dismiss() }
            case .done:
                Button("Later") { dismiss() }
                Button("Quit VideoScan") { NSApp.terminate(nil) }.buttonStyle(.borderedProminent)
            }
        }
    }

    private func start() {
        guard let center else { return }
        let environment = model.catalogSwitchEnvironment(center: center)
        cutover.switchPhase = .running("Checking catalog.sqlite…")
        Task { @MainActor in
            cutover.switchPhase = await CatalogSwitchRun.run(environment)
        }
    }
}
