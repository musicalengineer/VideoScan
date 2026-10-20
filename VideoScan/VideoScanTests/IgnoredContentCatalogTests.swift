// IgnoredContentCatalogTests.swift
// The ignore list lives in catalog.sqlite (2026-10-19): `ignored_content`
// plus v1.11's `ignored_content_put_back`; IgnoredContentCatalogBacking.swift
// and IgnoredContentJSONImport.swift. On Rick's catalog ~41 ignore decisions
// existed only in ignored-content.json after the cutover.
//
// Dimensions (CLAUDE.md feature-test checklist):
//   LOGIC      the import plan: new by id, already there, a CONFLICT (same
//              id, other content) is a finding never a replacement, an
//              imported row the file lacks is a finding (kept ignored), a
//              repeated id in the file counts once; counts verified.
//   TRUTH      end to end on catalog.sqlite: the cutover's rows + the file's
//              newer entries → launch → the list holds every entry; the
//              import line says counts in = out; a person ignores one and
//              puts one back → rows in catalog.sqlite (a put-back row, never
//              a DELETE) and ignored-content.json is byte-identical; a
//              relaunch imports nothing (idempotent) and reads the same list.
//   ISOLATION  a read-only session refuses the import AND the save — the
//              file's entries are honoured in memory, nothing is written; a
//              poisoned (other-version) file imports nothing and leaves the
//              table as it is; under a test host the store is re-homed
//              beside the test's catalog, never the shared scratch folder.
//   SCALE      100k entries imported, then a 100k-entry diff saved — budgets.
//   SENSOR     under catalog.sqlite the store never writes the JSON file
//              (`saveOffMain` only on the JSON path), and the import never
//              infers a put-back.
//   MEDIA      N/A — no media is opened.
//
// Suites (filter by SUITE): IgnoredContentImportPlanTests ·
// IgnoredContentCatalogTruthTests · IgnoredContentCatalogScaleTests ·
// IgnoredContentCatalogSensorTests
// Synthetic names only.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let icNow = Date(timeIntervalSince1970: 1_760_850_000)   // 2026-10-19

private func entry(_ n: Int, reason: String = "removed-by-user") -> IgnoredContentEntry {
    IgnoredContentEntry(id: UUID(uuidString: String(format: "CCCCCCCC-0000-4000-8000-%012d", n)) ?? UUID(), partialMD5: "md5-\(n)",
                        sizeBytes: Int64(1_000 + n), filename: "test_synthetic_junk_\(n).mov", reason: reason,
                        addedAt: icNow.addingTimeInterval(Double(n)), samplePath: "/Volumes/Synthetic/test_synthetic_junk_\(n).mov")
}

private func reading(_ e: IgnoredContentEntry, seq: Int64, imported: Bool = false, putBack: Bool = false) -> CatalogRow.IgnoredReading {
    CatalogRow.IgnoredReading(seq: seq, entry: IgnoredContentCatalogRows.row(e), imported: imported, putBack: putBack)
}

private func writeJSON(_ entries: [IgnoredContentEntry], to folder: URL, version: Int = IgnoredContentFile.currentVersion) throws {
    var file = IgnoredContentFile(savedAt: icNow, entries: entries)
    file.storeVersion = version
    let enc = JSONEncoder()
    enc.dateEncodingStrategy = .iso8601
    enc.outputFormatting = [.sortedKeys]
    try enc.encode(file).write(to: folder.appendingPathComponent(IgnoredContentStore.filename), options: .atomic)
}

// MARK: - LOGIC: the plan

@Suite("Ignored content in catalog.sqlite — the import plan")
struct IgnoredContentImportPlanTests {

    @Test("new by id, already there, a conflict is a finding (never a replacement), an imported row the file lacks is a finding")
    func planSortsEveryEntry() {
        var changed = entry(2)
        changed.reason = "junk"
        let file = IgnoredContentFile(savedAt: icNow, entries: [entry(1), changed, entry(3), entry(3)])
        let rows = [reading(entry(1), seq: 1, imported: true), reading(entry(2), seq: 2, imported: true),
                    reading(entry(9), seq: 3, imported: true), reading(entry(8), seq: 4, imported: true, putBack: true),
                    reading(entry(7), seq: 5)]
        let plan = IgnoredContentJSONImportPlan(file: file, rows: rows)
        #expect(plan.newEntries.map(\.id) == [entry(3).id], "a repeated id in the file counts once")
        #expect(plan.alreadyThere == 1)
        #expect(plan.conflicts.map(\.id) == [entry(2).id])
        #expect(plan.missingFromFile == [entry(9).filename], "put back or app-written rows are not findings")
        let findings = IgnoredContentJSONImportWords.findings(plan)
        #expect(findings.count == 2)
        #expect(findings[0].contains("FINDING — test_synthetic_junk_2.mov") && findings[0].contains("never a replacement"))
        #expect(findings[1].contains("stays ignored"))
    }

    @Test("verified: every file id in the table and the table grew by exactly the appended entries")
    func verification() {
        let file = IgnoredContentFile(savedAt: icNow, entries: [entry(1), entry(2)])
        let before = [reading(entry(1), seq: 1)]
        let plan = IgnoredContentJSONImportPlan(file: file, rows: before)
        let ids = Set(file.entries.map(\.id))
        #expect(plan.verified(fileIDs: ids, before: 1, after: before + [reading(entry(2), seq: 2)]))
        #expect(!plan.verified(fileIDs: ids, before: 1, after: before), "a missing entry is not verified")
        #expect(!plan.verified(fileIDs: ids, before: 1, after: before + [reading(entry(2), seq: 2), reading(entry(5), seq: 3)]))
    }
}

// MARK: - TRUTH + ISOLATION on catalog.sqlite

@MainActor
private func launchWithIgnoredFile(_ scene: CutoverScene, extra: [IgnoredContentEntry],
                                   version: Int = IgnoredContentFile.currentVersion) async throws -> [IgnoredContentEntry] {
    try await scene.importCatalog()                       // the cutover carries the fixture's two entries
    let fixture = try #require(await IgnoredContentStore.loadOffMain(scene.folder.appendingPathComponent(IgnoredContentStore.filename)))
    let all = fixture.entries + extra
    try writeJSON(all, to: scene.folder, version: version)   // Rick kept ignoring after the cutover
    try scene.writeLatch()
    scene.model.records = scene.model.loadCatalogAtLaunch()
    _ = await scene.model.ignoredContentStore.load()
    return all
}

@MainActor
private func tableRows(_ model: VideoScanModel) async throws -> [CatalogRow.IgnoredReading] {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { reader in
        var out: [CatalogRow.IgnoredReading] = []
        try reader.ignoredRows { out.append($0) }
        return out
    }
}

@Suite("Ignored content in catalog.sqlite — truth end to end", .serialized)
@MainActor
struct IgnoredContentCatalogTruthTests {

    @Test("TRUTH: the file's newer entries are imported (counts in = out); ignore + put back write rows, never the JSON; a relaunch imports nothing")
    func importWriteRelaunch() async throws {
        let scene = try CutoverScene.make("ic_truth"); defer { scene.cleanup() }
        let extra = (1...3).map { entry($0) }
        let all = try await launchWithIgnoredFile(scene, extra: extra)
        let store = scene.model.ignoredContentStore
        #expect(store.directory.standardizedFileURL == scene.folder.standardizedFileURL, "re-homed beside the test's catalog")
        #expect(store.catalog != nil)
        #expect(Set(store.entries.map(\.id)) == Set(all.map(\.id)))
        let rows = try await tableRows(scene.model)
        #expect(rows.count == all.count)
        #expect(rows.filter(\.imported).count == 2 && rows.filter { !$0.imported }.count == 3)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Ignored content: OUTCOME imported ignored-content.json into catalog.sqlite — 5 entries in the file: 3 appended, 2 already there"),
                "\(log.suffix(800))")
        #expect(log.contains("verified (counts in = counts out)"))

        let jsonURL = scene.folder.appendingPathComponent(IgnoredContentStore.filename)
        let frozen = try Data(contentsOf: jsonURL)
        #expect(store.add(partialMD5: "md5-new", sizeBytes: 77, filename: "test_new_junk.mov", reason: "junk",
                          samplePath: "/Volumes/Synthetic/test_new_junk.mov", now: icNow))
        #expect(store.remove(id: extra[0].id))
        #expect(await store.save())
        #expect(try Data(contentsOf: jsonURL) == frozen, "ignored-content.json is never written again")
        let afterWrite = try await tableRows(scene.model)
        #expect(afterWrite.count == all.count + 1, "a new row; the put-back deleted nothing")
        #expect(afterWrite.filter(\.putBack).map(\.entry.entryID) == [extra[0].id.uuidString])
        #expect(await store.save(), "a second save with no change writes nothing and succeeds")

        // Relaunch on the same files: nothing is imported again.
        let again = IgnoredContentStore(directory: scene.folder)
        let committer = try #require(scene.model.catalogCutover.committer)
        again.attachCatalog(IgnoredContentCatalogBacking(committer: committer))
        _ = await again.load()
        #expect(Set(again.entries.map(\.id)) == Set(store.entries.map(\.id)))
        #expect(try await tableRows(scene.model).count == all.count + 1, "idempotent: 0 appended")
    }

    @Test("ISOLATION: a session that may not write (read-only, viewer, held) refuses the import and the save; the file's entries are honoured in memory; nothing is written")
    func refusingSessionWritesNothing() async throws {
        let scene = try CutoverScene.make("ic_ro"); defer { scene.cleanup() }
        _ = try await launchWithIgnoredFile(scene, extra: [])
        let committer = try #require(scene.model.catalogCutover.committer)
        // A second store over a folder whose file carries one entry the table lacks,
        // behind the committer's own read and a refusing door (what a read-only
        // or viewer session's committer answers).
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("test_ic_ro_\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        let fileEntries = scene.model.ignoredContentStore.entries + [entry(1)]
        try writeJSON(fileEntries, to: other)
        let refusing = IgnoredContentCatalogBacking(repository: committer.repository,
                                                    writeRefusal: { "read-only: test viewer" },
                                                    commit: { _, _ in "read-only: test viewer" })
        let store = IgnoredContentStore(directory: other)
        var lines: [String] = []
        store.note = { lines.append($0) }
        store.attachCatalog(refusing)
        _ = await store.load()
        #expect(Set(store.entries.map(\.id)) == Set(fileEntries.map(\.id)), "honoured in memory")
        #expect(try await tableRows(scene.model).count == 2, "only the cutover's two")
        #expect(lines.contains { $0.contains("NOT imported into catalog.sqlite — read-only: test viewer") }, "\(lines)")
        #expect(store.add(partialMD5: "m", sizeBytes: 5, filename: "test_x.mov", reason: "junk", samplePath: "/x", now: icNow))
        #expect(await store.save() == false)
        #expect(store.lastSaveFailure == "read-only: test viewer")
        #expect(try await tableRows(scene.model).count == 2, "nothing written")
        let after = try #require(await IgnoredContentStore.loadOffMain(other.appendingPathComponent(IgnoredContentStore.filename)))
        #expect(after.entries.count == fileEntries.count, "the JSON file is not written either")
    }

    @Test("ISOLATION: a poisoned file (another store version) imports nothing; the table keeps the cutover's rows")
    func poisonedFile() async throws {
        let scene = try CutoverScene.make("ic_poison"); defer { scene.cleanup() }
        _ = try await launchWithIgnoredFile(scene, extra: [entry(1)], version: 99)
        #expect(try await tableRows(scene.model).count == 2)
        #expect(scene.model.ignoredContentStore.count == 2)
        #expect(scene.sandbox.catalogLogText().contains("ignored-content.json is not readable — NOT imported"))
    }
}

// MARK: - SCALE

@Suite("Ignored content in catalog.sqlite — SCALE (100k)", .serialized)
@MainActor
struct IgnoredContentCatalogScaleTests {

    /// 100k entries in the file → one import transaction → read back; then
    /// 100k more ignored in memory and saved as one diff. Budgets (Debug,
    /// M4 Max): import 30 s, diff save 30 s.
    @Test(.timeLimit(.minutes(4)))
    func hundredThousandEntries() async throws {
        let scene = try CutoverScene.make("ic_scale"); defer { scene.cleanup() }
        let clock = ContinuousClock()
        let extra = (1...100_000).map { entry($0) }
        var all: [IgnoredContentEntry] = []
        let importing = try await clock.measure { all = try await launchWithIgnoredFile(scene, extra: extra) }
        let store = scene.model.ignoredContentStore
        #expect(store.count == all.count)
        for n in 100_001...200_000 {
            store.add(partialMD5: "md5-\(n)", sizeBytes: Int64(n), filename: "test_more_\(n).mov", reason: "junk",
                      samplePath: "/Volumes/Synthetic/test_more_\(n).mov", now: icNow)
        }
        var saved = false
        let saving = await clock.measure { saved = await store.save() }
        print("[ignored-catalog] import 100k: \(importing); diff save 100k: \(saving)")
        #expect(saved)
        #expect(try await tableRows(scene.model).count == all.count + 100_000)
        #expect(importing < .seconds(30))
        #expect(saving < .seconds(30))
    }
}

// MARK: - SENSOR

@Suite("Ignored content in catalog.sqlite — sensors")
struct IgnoredContentCatalogSensorTests {

    @Test("under catalog.sqlite the store never writes ignored-content.json; the import never infers a put-back")
    func noJSONWriteNoInferredPutBack() throws {
        let store = try SourceTree.appCode(named: "IgnoredContentStore.swift")
        let save = try #require(store.range(of: "func save() async -> Bool {"))
        let body = String(store[save.upperBound...].prefix(600))
        let catalogBranch = try #require(body.range(of: "if let catalog {"))
        let jsonWrite = try #require(body.range(of: "Self.saveOffMain"))
        #expect(catalogBranch.lowerBound < jsonWrite.lowerBound, "the catalog branch returns before the JSON write")
        #expect(body.contains("return saveToCatalog(catalog)"))
        let importer = try SourceTree.appCode(named: "IgnoredContentJSONImport.swift")
        #expect(!importer.contains("putBackIgnored"), "the import never puts back")
        #expect(!importer.contains("saveOffMain"), "the import never writes the file")
    }
}
