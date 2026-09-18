import Foundation
import Testing
@testable import VideoScan

/// Review probes for the 2026-09-12 rename fix: sequences the design doc calls
/// "fail closed" are pinned here at the production seam (POIStorage.storeDir,
/// a per-process temp dir under a test host). The staging-copy rename is no
/// longer what production does (folders are keyed by uuid; a rename is a
/// JSON write), but POIProfileFileStore.save(previous:) is still the seam
/// bundle/legacy tooling may use, so its probes stay.
@Suite("People rename — review probes", .serialized)
struct POIProfileRenameReviewProbeTests {
    private func requireSandbox() throws {
        try #require(TestEnvironment.isTestHost)
        try #require(POIStorage.storeDir.lastPathComponent.hasPrefix("VideoScanTestPOI-"))
    }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("POIRenameProbe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    /// A crash between "publish destination" and "soft-retire source" of the
    /// PRE-uuid rename (2026-09-12 fix) left two name-keyed folders with one
    /// uuid. Pins what the uuid-keyed store does with that leftover: the
    /// migration skips BOTH (duplicateUUID), both keep every photo, both are
    /// still listed, the audit file names both paths, and nothing is deleted.
    @Test func twoLegacyFoldersWithOneUUIDAreSkippedByTheMigrationNotMerged() throws {
        try requireSandbox()
        let stem = "probe-\(UUID().uuidString.prefix(8))"
        let oldName = stem + "-old", newName = stem + "-new"
        let oldFolder = POIStorage.legacyFolder(forName: oldName)
        let newFolder = POIStorage.legacyFolder(forName: newName)
        defer {
            try? FileManager.default.removeItem(at: oldFolder)
            try? FileManager.default.removeItem(at: newFolder)
        }
        let id = UUID()
        let bytes = Data([1, 2, 3])
        for (folder, name) in [(oldFolder, oldName), (newFolder, newName)] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            var profile = POIProfile(name: name, referencePath: folder.path, uuid: id)
            profile.referencePath = folder.path
            try JSONEncoder().encode(profile).write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
            try bytes.write(to: folder.appendingPathComponent("portrait.jpg"))
        }

        let listed = POIProfile.listAll().filter { $0.uuid == id }
        #expect(listed.count == 2)
        // Compare resolved paths: storeDir is /var/..., enumeration yields /private/var/...
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        #expect(Set(listed.map { resolved($0.referencePath) })
                == [resolved(oldFolder.path), resolved(newFolder.path)])
        #expect(!FileManager.default.fileExists(atPath: POIStorage.folder(forUUID: id).path),
                "neither folder was renamed onto the shared uuid")
        let report = try #require(POIStorage.readUUIDMigrationReport())
        let skipped = report.skipped.filter { $0.reason == POIStorage.UUIDMigrationSkip.duplicateUUID }
        #expect(Set(skipped.map(\.folder)).isSuperset(of: [oldFolder.lastPathComponent, newFolder.lastPathComponent]))
        // The report is shared; other suites' duplicate-uuid skips can be in
        // it (M5, 2026-09-18). Only THIS probe's two entries must name both.
        let ours = skipped.filter { [oldFolder.lastPathComponent, newFolder.lastPathComponent].contains($0.folder) }
        #expect(ours.count == 2)
        #expect(ours.allSatisfy { $0.detail.contains(oldFolder.lastPathComponent) && $0.detail.contains(newFolder.lastPathComponent) })
        #expect(!report.complete)
        #expect(try Data(contentsOf: oldFolder.appendingPathComponent("portrait.jpg")) == bytes)
        #expect(try Data(contentsOf: newFolder.appendingPathComponent("portrait.jpg")) == bytes)
    }

    /// NFC and NFD spellings of "José" are one folder on APFS. Pins that the
    /// store never treats them as a rename: nothing is retired, nothing is
    /// copied, and the write (if any) lands in the same physical folder.
    /// (Observed: URL.standardizedFileURL normalizes to NFD, so the two
    /// spellings compare equal and the save takes the in-place route.)
    @Test func normalizationVariantRenameNeverRetiresOrCopies() throws {
        try withRoot { root in
            let id = UUID()
            let nfd = "jose\u{301}", nfc = "jos\u{e9}"
            let source = root.appendingPathComponent(nfd, isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            let json = try JSONSerialization.data(withJSONObject: ["uuid": id.uuidString, "name": "José"])
            try json.write(to: source.appendingPathComponent("profile.json"), options: .atomic)
            let bytes = Data([7, 7, 7])
            try bytes.write(to: source.appendingPathComponent("portrait.jpg"))
            let destination = root.appendingPathComponent(nfc, isDirectory: true)
            try #require(FileManager.default.fileExists(atPath: destination.path))   // same folder on this volume
            let inode = { (url: URL) -> Int? in
                (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber] as? Int
            }
            var retired = false
            var wroteInto: URL?
            do {
                _ = try POIProfileFileStore.save(id: id, destination: destination, previous: source,
                    retire: { _ in retired = true }, write: { _, final in wroteInto = final })
            } catch let failure as POIProfileFileStore.Failure {
                #expect(failure == .occupiedDestination)   // the other acceptable outcome
            }
            #expect(!retired)
            if let wroteInto { #expect(inode(wroteInto) == inode(source)) }
            #expect(try Data(contentsOf: source.appendingPathComponent("portrait.jpg")) == bytes)
            #expect(try Data(contentsOf: source.appendingPathComponent("profile.json")) == json)
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).count == 1)
        }
    }

    /// The rename copies every byte on the caller's thread (updateProfile
    /// runs on the main actor). Measures a 200-file / 200 MB folder; the
    /// budget is generous on purpose — the number in the log is the finding.
    @Test func renameCopyCostAt200MB() throws {
        try withRoot { root in
            let id = UUID()
            let source = root.appendingPathComponent("big", isDirectory: true)
            try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: ["uuid": id.uuidString, "name": "Big"])
                .write(to: source.appendingPathComponent("profile.json"), options: .atomic)
            var chunk = Data(count: 1 << 20)
            for i in stride(from: 0, to: chunk.count, by: 4096) { chunk[i] = UInt8(truncatingIfNeeded: i) }
            for i in 0..<200 { try chunk.write(to: source.appendingPathComponent("photo_\(i).jpg")) }
            let destination = root.appendingPathComponent("bigger", isDirectory: true)
            let start = Date()
            _ = try POIProfileFileStore.save(id: id, destination: destination, previous: source,
                retire: { try FileManager.default.removeItem(at: $0) },
                write: { url, _ in try Data("{}".utf8).write(to: url) })
            let seconds = Date().timeIntervalSince(start)
            print("[probe] rename of 200 MB / 200 files took \(String(format: "%.3f", seconds)) s")
            #expect(seconds < 10, "rename of 200 MB took \(seconds) s")
            #expect(try FileManager.default.contentsOfDirectory(atPath: destination.path).count == 201)
        }
    }
}
