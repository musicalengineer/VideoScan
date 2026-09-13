import Foundation
import Testing
@testable import VideoScan

/// Review probes for the 2026-09-12 rename fix: sequences the design doc calls
/// "fail closed" are pinned here at the production seam (POIStorage.storeDir,
/// a per-process temp dir under a test host). Probes never call
/// `saveRenaming` on a path that would reach `POIProfile.delete(name:)`,
/// because that retires into the real ~/dev/VideoScan/.trash.
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

    /// A crash between "publish destination" and "soft-retire source" leaves
    /// two live folders with one UUID. Pins what the app then sees: both
    /// enumerate (ids are name-based, so no ForEach collision), both keep
    /// every photo, and renaming one back onto the other is refused, not merged.
    @Test func twoLiveFoldersAfterCrashBetweenPublishAndRetire() throws {
        try requireSandbox()
        let stem = "probe-\(UUID().uuidString.prefix(8))"
        let oldName = stem + "-old", newName = stem + "-new"
        let oldFolder = POIStorage.folder(for: oldName), newFolder = POIStorage.folder(for: newName)
        defer {
            try? FileManager.default.removeItem(at: oldFolder)
            try? FileManager.default.removeItem(at: newFolder)
        }
        var profile = POIProfile(name: oldName, referencePath: oldFolder.path)
        try profile.save()
        let bytes = Data([1, 2, 3])
        try bytes.write(to: oldFolder.appendingPathComponent("portrait.jpg"))
        // The crash: the destination is published, the retirement never happens.
        profile.name = newName
        let warning = try POIProfileFileStore.save(
            id: profile.uuid, destination: newFolder, previous: oldFolder,
            retire: { _ in throw CocoaError(.fileWriteUnknown) },
            write: { url, folder in
                var staged = profile
                staged.referencePath = folder.path
                try JSONEncoder().encode(staged).write(to: url, options: .atomic)
            })
        #expect(warning != nil)

        let listed = POIProfile.listAll().filter { $0.uuid == profile.uuid }
        #expect(listed.count == 2)
        #expect(Set(listed.map(\.id)).count == 2)
        // Compare resolved paths: storeDir is /var/..., enumeration yields /private/var/...
        let resolved = { (path: String) in URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        #expect(Set(listed.map { resolved($0.referencePath) })
                == [resolved(oldFolder.path), resolved(newFolder.path)])

        var back = try #require(listed.first { $0.name == newName })
        back.name = oldName
        #expect(throws: POIProfileFileStore.Failure.occupiedDestination) {
            _ = try back.saveRenaming(from: newName)
        }
        #expect(try Data(contentsOf: oldFolder.appendingPathComponent("portrait.jpg")) == bytes)
        #expect(try Data(contentsOf: newFolder.appendingPathComponent("portrait.jpg")) == bytes)
        #expect(FileManager.default.fileExists(atPath: oldFolder.appendingPathComponent("profile.json").path))
        #expect(FileManager.default.fileExists(atPath: newFolder.appendingPathComponent("profile.json").path))
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
