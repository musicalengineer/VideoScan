import Foundation
import Testing
@testable import VideoScan

// The name-folder → uuid-folder migration (docs/people_uuid_folders_design.md).
//
// Dimension 2 (scale), 4 (isolation) and 5 (sensors) of the feature-test
// checklist, plus the 12-folder fixture that exercises every classification
// branch. Every test builds its own temp root; the per-process test store is
// touched only by `listAllMigratesALegacyFolderInTheProcessStore`, which
// cleans up after itself. Backups land beside each temp root, never in
// Application Support.

@Suite("People uuid migration", .serialized)
struct POIUUIDMigrationTests {

    // MARK: - Fixture helpers

    private struct Root {
        let url: URL
        var backups: URL { url.deletingLastPathComponent().appendingPathComponent("backups", isDirectory: true) }
        func cleanup() { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func folder(_ name: String) -> URL { url.appendingPathComponent(name, isDirectory: true) }
    }

    private func makeRoot() throws -> Root {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("poi-uuid-migration-\(UUID().uuidString)", isDirectory: true)
        let root = base.appendingPathComponent("POI", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Root(url: root)
    }

    /// A legacy (name-keyed) folder with profile.json + `photos` random photos.
    @discardableResult
    private func writeLegacy(_ root: Root, folder: String, name: String, uuid: UUID?,
                             photos: Int = 3, extra: [String: Any] = [:]) throws -> URL {
        let dir = root.folder(folder)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var json: [String: Any] = ["name": name, "referencePath": dir.path, "aliases": ["Nick \(name)"]]
        if let uuid { json["uuid"] = uuid.uuidString }
        for (k, v) in extra { json[k] = v }
        try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("profile.json"))
        for i in 0..<photos {
            try Data((0..<256).map { _ in UInt8.random(in: 0...255) })
                .write(to: dir.appendingPathComponent("photo_\(i).jpg"))
        }
        return dir
    }

    /// Every regular file and symlink under `root`: relative path → bytes
    /// (a symlink contributes its target path). Order-independent.
    private func manifest(of root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let fm = FileManager.default
        // String enumeration yields paths RELATIVE to root, which sidesteps
        // /var vs /private/var vs /System/Volumes/Data spellings of temp.
        guard let walker = fm.enumerator(atPath: root.path) else { return out }
        for case let rel as String in walker {
            let path = root.appendingPathComponent(rel).path
            let type = try fm.attributesOfItem(atPath: path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink {
                out[rel] = Data(try fm.destinationOfSymbolicLink(atPath: path).utf8)
            } else if type == .typeRegular {
                out[rel] = try Data(contentsOf: URL(fileURLWithPath: path))
            }
        }
        return out
    }

    private func json(at folder: URL) throws -> [String: Any] {
        let data = try Data(contentsOf: folder.appendingPathComponent("profile.json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// The 12-folder fixture from the design note. Returns the ids that
    /// matter to the assertions.
    private struct Fixture {
        var ordinary: [(folder: String, uuid: UUID)] = []
        var noUUIDFolder = "nouuid"
        var malformedFolder = "malformed"
        var symlinkFolder = "linked"
        var twinUUID = UUID()
        var twins = ["twin_a", "twin_b"]
        var alreadyUUID = UUID()
    }

    private func buildFixture(in root: Root) throws -> Fixture {
        var f = Fixture()
        for (folder, name) in [("rick", "Rick"), ("donna", "Donna"), ("renée", "Renée"),
                               ("josé_maría", "José María"), ("李小龙", "李小龙"), ("aunt_beth", "Aunt Beth")] {
            let id = UUID()
            try writeLegacy(root, folder: folder, name: name, uuid: id)
            f.ordinary.append((folder, id))
        }
        try writeLegacy(root, folder: f.noUUIDFolder, name: "No Uuid", uuid: nil,
                        extra: ["futureKey": ["kept": true]])
        let malformed = root.folder(f.malformedFolder)
        try FileManager.default.createDirectory(at: malformed, withIntermediateDirectories: true)
        try Data("{ this is not json".utf8).write(to: malformed.appendingPathComponent("profile.json"))
        try Data([9, 9, 9]).write(to: malformed.appendingPathComponent("photo_0.jpg"))
        try FileManager.default.createSymbolicLink(at: root.folder(f.symlinkFolder),
                                                   withDestinationURL: root.folder("rick"))
        for twin in f.twins {
            try writeLegacy(root, folder: twin, name: "Twin", uuid: f.twinUUID)
        }
        try writeLegacy(root, folder: POIStorage.folderName(for: f.alreadyUUID), name: "Already", uuid: f.alreadyUUID)
        return f
    }

    // MARK: - The fixture

    @Test func twelveFolderFixtureMigratesSkipsAndAudits() throws {
        let root = try makeRoot()
        defer { root.cleanup() }
        let f = try buildFixture(in: root)
        let before = try manifest(of: root.url)
        let foldersBefore = try FileManager.default.contentsOfDirectory(atPath: root.url.path).count

        let outcome = POIStorage.migrateToUUIDFoldersIfNeeded(root: root.url, backupParent: root.backups)
        guard case .ran(let report) = outcome else {
            Issue.record("expected .ran, got \(outcome)"); return
        }

        // Mapping: the six ordinary folders + the one that needed a uuid.
        #expect(report.mapping.count == 7)
        for (folder, id) in f.ordinary {
            #expect(report.mapping[folder] == POIStorage.folderName(for: id))
            let moved = root.folder(POIStorage.folderName(for: id))
            #expect(FileManager.default.fileExists(atPath: moved.path))
            #expect(!FileManager.default.fileExists(atPath: root.folder(folder).path))
            let json = try json(at: moved)
            #expect(json["referencePath"] as? String == moved.path)
            #expect(json["legacyFolderName"] as? String == folder)
            #expect(json["uuid"] as? String == id.uuidString)
            // Every photo byte followed the folder.
            for i in 0..<3 {
                #expect(try Data(contentsOf: moved.appendingPathComponent("photo_\(i).jpg"))
                        == before["\(folder)/photo_\(i).jpg"])
            }
        }
        // The uuid-less profile was given one, in its folder name and its JSON,
        // and the key this build does not know survived the rewrite.
        let mintedName = try #require(report.mapping[f.noUUIDFolder])
        let minted = try #require(POIStorage.uuid(fromFolderName: mintedName))
        let mintedJSON = try json(at: root.folder(mintedName))
        #expect(mintedJSON["uuid"] as? String == minted.uuidString)
        #expect((mintedJSON["futureKey"] as? [String: Any])?["kept"] as? Bool == true)

        // Skips, with reasons, and nothing deleted.
        let reasons = Dictionary(report.skipped.map { ($0.folder, $0.reason) }, uniquingKeysWith: { a, _ in a })
        #expect(reasons[f.malformedFolder] == POIStorage.UUIDMigrationSkip.malformedJSON)
        #expect(reasons["twin_a"] == POIStorage.UUIDMigrationSkip.duplicateUUID)
        #expect(reasons["twin_b"] == POIStorage.UUIDMigrationSkip.duplicateUUID)
        #expect(report.skipped.first { $0.folder == "twin_a" }?.detail.contains("twin_b") == true)
        #expect(!report.complete)
        #expect(report.mapping[f.symlinkFolder] == nil, "a symlink is never renamed")
        #expect(report.mapping[POIStorage.folderName(for: f.alreadyUUID)] == nil, "already keyed by uuid: untouched")
        #expect(try Data(contentsOf: root.folder(f.malformedFolder).appendingPathComponent("profile.json"))
                == Data("{ this is not json".utf8))
        #expect(try Data(contentsOf: root.folder(f.malformedFolder).appendingPathComponent("photo_0.jpg")) == Data([9, 9, 9]))
        for twin in f.twins { #expect(FileManager.default.fileExists(atPath: root.folder(twin).path)) }
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: root.folder(f.symlinkFolder).path)) != nil)
        #expect(FileManager.default.fileExists(atPath: root.folder(POIStorage.folderName(for: f.alreadyUUID)).path))
        // The audit file is the only addition to the directory.
        let foldersAfter = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
            .filter { $0 != POIStorage.uuidMigrationFileName }.count
        #expect(foldersAfter == foldersBefore)
        #expect(report.foldersBefore == report.foldersAfter)

        // Backup: taken before the first rename, byte-identical to the fixture.
        let backupPath = try #require(report.backupPath)
        #expect(backupPath.hasPrefix(root.backups.standardizedFileURL.path))
        let backupManifest = try manifest(of: URL(fileURLWithPath: backupPath))
        let missing = Set(before.keys).subtracting(backupManifest.keys)
        let added = Set(backupManifest.keys).subtracting(before.keys)
        let changed = before.filter { backupManifest[$0.key] != nil && backupManifest[$0.key] != $0.value }.keys
        #expect(backupManifest == before,
                "backup differs — missing: \(missing.sorted()) added: \(added.sorted()) changed: \(changed.sorted())")
        #expect(report.backupMethod == "clonefile" || report.backupMethod?.hasPrefix("copy") == true)

        // The audit file decodes and matches the returned report.
        let onDisk = try #require(POIStorage.readUUIDMigrationReport(root: root.url))
        #expect(onDisk.mapping == report.mapping)
        #expect(onDisk.backupPath == report.backupPath)
        #expect(onDisk.finishedAt != nil)
        #expect(Set(onDisk.skipped.map(\.folder)) == Set(report.skipped.map(\.folder)))
    }

    @Test func secondRunIsANoOpAndTakesNoSecondBackup() throws {
        let root = try makeRoot()
        defer { root.cleanup() }
        _ = try buildFixture(in: root)
        let first = POIStorage.migrateToUUIDFoldersIfNeeded(root: root.url, backupParent: root.backups)
        guard case .ran(let firstReport) = first else { Issue.record("first run should run"); return }
        let after = try manifest(of: root.url)
        let backupsAfterFirst = try FileManager.default.contentsOfDirectory(atPath: root.backups.path)
        #expect(backupsAfterFirst.count == 1)

        // Leftovers (malformed, twins) are still candidates, so the run
        // executes — but nothing moves, nothing is backed up again, and the
        // earlier mapping survives in the audit file.
        let second = POIStorage.migrateToUUIDFoldersIfNeeded(root: root.url, backupParent: root.backups)
        guard case .ran(let secondReport) = second else { Issue.record("second run should report"); return }
        #expect(secondReport.mapping.isEmpty)
        #expect(secondReport.backupPath == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.backups.path).count == 1)
        let audit = try manifest(of: root.url).filter { $0.key != POIStorage.uuidMigrationFileName }
        #expect(audit == after.filter { $0.key != POIStorage.uuidMigrationFileName })
        #expect(POIStorage.readUUIDMigrationReport(root: root.url)?.mapping == firstReport.mapping)

        // A clean store says so outright.
        let clean = try makeRoot()
        defer { clean.cleanup() }
        try writeLegacy(clean, folder: "a", name: "A", uuid: UUID())
        try writeLegacy(clean, folder: "b", name: "B", uuid: UUID())
        guard case .ran = POIStorage.migrateToUUIDFoldersIfNeeded(root: clean.url, backupParent: clean.backups) else {
            Issue.record("clean fixture should migrate"); return
        }
        #expect(POIStorage.migrateToUUIDFoldersIfNeeded(root: clean.url, backupParent: clean.backups) == .notNeeded)
        #expect(POIStorage.migrateToUUIDFoldersIfNeeded(root: clean.url, backupParent: clean.backups) == .notNeeded)
    }

    @Test func rollbackRestoresTheLegacyNames() throws {
        let root = try makeRoot()
        defer { root.cleanup() }
        let f = try buildFixture(in: root)
        let before = try manifest(of: root.url)
        guard case .ran(let report) = POIStorage.migrateToUUIDFoldersIfNeeded(root: root.url, backupParent: root.backups) else {
            Issue.record("should run"); return
        }
        let restored = try POIStorage.rollbackUUIDMigration(root: root.url)
        #expect(restored == report.mapping.count)
        for (folder, _) in f.ordinary {
            #expect(FileManager.default.fileExists(atPath: root.folder(folder).path))
            let json = try json(at: root.folder(folder))
            #expect(json["referencePath"] as? String == root.folder(folder).path)
            for i in 0..<3 {
                #expect(try Data(contentsOf: root.folder(folder).appendingPathComponent("photo_\(i).jpg"))
                        == before["\(folder)/photo_\(i).jpg"])
            }
        }
        for new in report.mapping.values {
            #expect(!FileManager.default.fileExists(atPath: root.folder(new).path))
        }
        #expect(FileManager.default.fileExists(atPath: root.folder(f.noUUIDFolder).path))
        #expect(POIStorage.readUUIDMigrationReport(root: root.url) == nil, "audit moved aside")
        let aside = try FileManager.default.contentsOfDirectory(atPath: root.url.path)
            .filter { $0.hasPrefix(".uuid-migration-rolledback-") }
        #expect(aside.count == 1)
        // The backup is never touched by rollback.
        #expect(try manifest(of: URL(fileURLWithPath: try #require(report.backupPath))) == before)
    }

    // MARK: - Scale (dimension 2)

    /// 100 profiles × 1,000 files. The rename phase is one rename(2) per
    /// profile and must stay well under a second; the backup clone is
    /// measured and printed (APFS: metadata only), not budgeted tightly.
    @Test func hundredProfilesWithAThousandFilesEachRenameInWellUnderASecond() throws {
        let root = try makeRoot()
        defer { root.cleanup() }
        // One folder built by hand, then cloned 99 times (clonefile is what
        // makes a 100k-file fixture affordable in a unit test).
        let template = root.url.deletingLastPathComponent().appendingPathComponent("template", isDirectory: true)
        try FileManager.default.createDirectory(at: template, withIntermediateDirectories: true)
        let bytes = Data(repeating: 0x42, count: 512)
        for i in 0..<1_000 { try bytes.write(to: template.appendingPathComponent("photo_\(i).jpg")) }
        var ids: [UUID] = []
        for i in 0..<100 {
            let dir = root.folder("person_\(i)")
            #expect(clonefile(template.path, dir.path, 0) == 0, "clonefile of the template")
            let id = UUID()
            ids.append(id)
            let json: [String: Any] = ["name": "Person \(i)", "uuid": id.uuidString, "referencePath": dir.path]
            try JSONSerialization.data(withJSONObject: json).write(to: dir.appendingPathComponent("profile.json"))
        }

        let outcome = POIStorage.migrateToUUIDFoldersIfNeeded(root: root.url, backupParent: root.backups)
        guard case .ran(let report) = outcome else { Issue.record("should run"); return }
        print("[measure] uuid migration 100×1,000 files: rename \(String(format: "%.3f", report.renameSeconds)) s, "
              + "backup \(String(format: "%.3f", report.backupSeconds)) s via \(report.backupMethod ?? "?"), "
              + "total \(String(format: "%.3f", report.elapsedSeconds)) s")
        #expect(report.mapping.count == 100)
        #expect(report.complete)
        #expect(report.renameSeconds < 1.0, "rename phase took \(report.renameSeconds) s")
        #expect(report.elapsedSeconds < 30, "whole migration took \(report.elapsedSeconds) s")
        for id in ids.prefix(5) + ids.suffix(5) {
            let moved = root.folder(POIStorage.folderName(for: id))
            #expect(try FileManager.default.contentsOfDirectory(atPath: moved.path).count == 1_001)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.url.path)
                    .filter { POIStorage.uuid(fromFolderName: $0) != nil }.count == 100)
    }

    // MARK: - Isolation (dimension 4)

    /// A root shaped like the live People store is refused under a test
    /// host before any I/O: nothing renamed, no backup, no audit file.
    @Test func refusesALiveShapedRootUnderTheTestHost() throws {
        try #require(TestEnvironment.isTestHost)
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("poi-uuid-live-shape-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let live = base.appendingPathComponent("Library/Application Support/VideoScan/POI", isDirectory: true)
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let legacy = try writeLegacy(Root(url: live), folder: "dad", name: "Dad", uuid: UUID())
        let before = try manifest(of: base)

        let outcome = POIStorage.migrateToUUIDFoldersIfNeeded(root: live)
        guard case .refused(let why) = outcome else { Issue.record("expected .refused, got \(outcome)"); return }
        #expect(why.contains("live People store"))
        #expect(FileManager.default.fileExists(atPath: legacy.path))
        #expect(try manifest(of: base) == before, "not a byte changed anywhere under the fake home")
        #expect(throws: (any Error).self) { try POIStorage.rollbackUUIDMigration(root: live) }
        #expect(try manifest(of: base) == before)
        // And the per-process test store is not live-shaped, so the real
        // entry point can run for the other tests in this process.
        #expect(throws: Never.self) { try POIProfileFileStore.guardRoot(POIStorage.storeDir) }
    }

    @Test func testHostBackupsStayBesideTheTestStore() throws {
        let root = try makeRoot()
        defer { root.cleanup() }
        let parent = POIStorage.defaultBackupParent(for: root.url)
        #expect(parent.lastPathComponent == "POI-backups")
        #expect(parent.deletingLastPathComponent().path == root.url.deletingLastPathComponent().path)
        // Production shape (not a test host): beside the store itself.
        #expect(POIStorage.defaultBackupParent(for: URL(fileURLWithPath: "/x/VideoScan/POI")).path
                == (TestEnvironment.isTestHost ? "/x/VideoScan/POI-backups" : "/x/VideoScan"))
    }

    // MARK: - Sensors (dimension 5)

    /// SENSOR `migrationNeverDeletesAFolder`: every folder that existed
    /// before is still there under its old or its mapped name, and the
    /// multiset of file contents is unchanged (only the audit file is new).
    @Test func migrationNeverDeletesAFolder() throws {
        let root = try makeRoot()
        defer { root.cleanup() }
        _ = try buildFixture(in: root)
        let namesBefore = Set(try FileManager.default.contentsOfDirectory(atPath: root.url.path))
        // profile.json files are rewritten by the migration (referencePath,
        // legacyFolderName, a minted uuid); every other file must survive
        // byte-for-byte. Filter by NAME — random photo bytes can start with
        // any value, "{" included.
        let contentsBefore = try manifest(of: root.url)
            .filter { !$0.key.hasSuffix("profile.json") }
            .values.sorted { $0.lexicographicallyPrecedes($1) }

        guard case .ran(let report) = POIStorage.migrateToUUIDFoldersIfNeeded(root: root.url, backupParent: root.backups) else {
            Issue.record("should run"); return
        }
        let namesAfter = Set(try FileManager.default.contentsOfDirectory(atPath: root.url.path))
            .subtracting([POIStorage.uuidMigrationFileName])
        for name in namesBefore {
            let expected = report.mapping[name] ?? name
            #expect(namesAfter.contains(expected), "'\(name)' must still exist (as '\(expected)')")
        }
        #expect(namesAfter.count == namesBefore.count)
        let contentsAfter = try manifest(of: root.url)
            .filter { !$0.key.hasSuffix("profile.json") && $0.key != POIStorage.uuidMigrationFileName }
            .values.sorted { $0.lexicographicallyPrecedes($1) }
        #expect(contentsAfter == contentsBefore)
    }

    /// The production entry point: `POIProfile.listAll()` migrates a legacy
    /// folder dropped into the per-process store, heals referencePath and
    /// records the old name.
    @Test func listAllMigratesALegacyFolderInTheProcessStore() throws {
        try #require(TestEnvironment.isTestHost)
        let tag = String(UUID().uuidString.prefix(6))
        let name = "Legacy \(tag)"
        let id = UUID()
        let legacy = POIStorage.legacyFolder(forName: name)
        try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
        let json: [String: Any] = ["name": name, "uuid": id.uuidString, "referencePath": legacy.path, "aliases": ["Leg\(tag)"]]
        try JSONSerialization.data(withJSONObject: json).write(to: legacy.appendingPathComponent("profile.json"))
        try Data([7]).write(to: legacy.appendingPathComponent("photo.jpg"))
        let moved = POIStorage.folder(forUUID: id)
        defer {
            try? FileManager.default.removeItem(at: legacy)
            try? FileManager.default.removeItem(at: moved)
        }

        let listed = POIProfile.listAll().first { $0.uuid == id }
        let profile = try #require(listed)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(FileManager.default.fileExists(atPath: moved.appendingPathComponent("photo.jpg").path))
        #expect(URL(fileURLWithPath: profile.referencePath).standardizedFileURL.path == moved.standardizedFileURL.path)
        #expect(profile.legacyFolderName == legacy.lastPathComponent)
        #expect(profile.displayName == "Leg\(tag)")
        #expect(POIStorage.readUUIDMigrationReport()?.mapping[legacy.lastPathComponent] == profile.id)
    }
}
