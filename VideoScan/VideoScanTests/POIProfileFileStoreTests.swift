import Foundation
import Testing
@testable import VideoScan

/// Real filesystem transactions with synthetic assets; never reads the user's POI root.
@Suite
struct POIProfileFileStoreTests {
    private enum InjectedFailure: Error { case write, retire }

    private func withRoot(_ body: (URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("POIProfileFileStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root)
    }

    private func json(_ id: UUID, name: String = "Richard Sr") throws -> Data {
        try JSONSerialization.data(withJSONObject: ["uuid": id.uuidString, "name": name], options: [.sortedKeys])
    }

    private func profile(_ root: URL, _ name: String, id: UUID) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try json(id).write(to: folder.appendingPathComponent("profile.json"), options: .atomic)
        return folder
    }

    private func snapshot(_ folder: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        for relativePath in try FileManager.default.subpathsOfDirectory(atPath: folder.path) {
            let url = folder.appendingPathComponent(relativePath)
            if try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                result[relativePath] = try Data(contentsOf: url)
            }
        }
        return result
    }

    @Test func renamePreservesEveryAssetByteAndWritesFinalReferencePath() throws {
        try withRoot { root in
            let id = UUID()
            let source = try profile(root, "richard", id: id)
            let destination = root.appendingPathComponent("richard sr")
            let assets = ["portrait.jpg", "portrait.tiff", "portrait.heic", "portrait.psd", "nested/scans/letter.bin"]
            for (index, path) in assets.enumerated() {
                let url = source.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data([0, UInt8(index), 255, 128, 13, 10]).write(to: url)
            }
            let before = try snapshot(source).filter { $0.key != "profile.json" }
            var retired = false
            let warning = try POIProfileFileStore.save(id: id, destination: destination, previous: source, retire: { old in
                // A retirement callback must never observe a partial destination.
                let actualAssets = try snapshot(destination).filter { $0.key != "profile.json" }
                #expect(actualAssets == before)
                #expect(old == source)
                retired = true
                try FileManager.default.removeItem(at: old)
            }, write: { stagedJSON, finalFolder in
                #expect(finalFolder == destination)
                #expect(stagedJSON.deletingLastPathComponent() != destination)
                try json(id, name: "Richard Harding Breen Sr").write(to: stagedJSON, options: .atomic)
            })
            #expect(warning == nil)
            #expect(retired)
            #expect(!FileManager.default.fileExists(atPath: source.path))
            let actualAssets = try snapshot(destination).filter { $0.key != "profile.json" }
            #expect(actualAssets == before)
            #expect(try Data(contentsOf: destination.appendingPathComponent("profile.json")) == json(id, name: "Richard Harding Breen Sr"))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["richard sr"])
        }
    }

    @Test func renamePreservesExternalAndRelativeSymlinks() throws {
        try withRoot { root in
            let id = UUID()
            let source = try profile(root, "old", id: id)
            let destination = root.appendingPathComponent("new")
            let external = root.appendingPathComponent("external.heic")
            let bytes = Data([1, 3, 7, 255])
            try bytes.write(to: external)
            try bytes.write(to: source.appendingPathComponent("original.jpg"))
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("external-link.heic").path, withDestinationPath: external.path)
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("relative-link.jpg").path, withDestinationPath: "original.jpg")
            _ = try POIProfileFileStore.save(id: id, destination: destination, previous: source, retire: { try FileManager.default.removeItem(at: $0) }, write: { path, _ in try json(id).write(to: path) })
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("external-link.heic").path) == external.path)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: destination.appendingPathComponent("relative-link.jpg").path) == "original.jpg")
            #expect(try Data(contentsOf: destination.appendingPathComponent("external-link.heic")) == bytes)
            #expect(try Data(contentsOf: destination.appendingPathComponent("relative-link.jpg")) == bytes)
            #expect(try Data(contentsOf: external) == bytes)
        }
    }

    @Test func absoluteLinkIntoRenamedFolderRemainsReadableAfterRetirement() throws {
        try withRoot { root in
            let id = UUID()
            let source = try profile(root, "old", id: id)
            let destination = root.appendingPathComponent("new")
            let bytes = Data([8, 6, 7, 5, 3, 0, 9])
            try bytes.write(to: source.appendingPathComponent("original.jpg"))
            try FileManager.default.createSymbolicLink(atPath: source.appendingPathComponent("portrait.jpg").path, withDestinationPath: source.appendingPathComponent("original.jpg").path)
            let retiredFolder = root.appendingPathComponent("retired-old")
            _ = try POIProfileFileStore.save(id: id, destination: destination, previous: source, retire: { try FileManager.default.moveItem(at: $0, to: retiredFolder) }, write: { path, _ in try json(id).write(to: path) })
            #expect(try Data(contentsOf: destination.appendingPathComponent("portrait.jpg")) == bytes)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: retiredFolder.appendingPathComponent("portrait.jpg").path) == source.appendingPathComponent("original.jpg").path)
        }
    }

    @Test func differentPersonDestinationCannotBeOverwrittenBySrOrJr() throws {
        try withRoot { root in
            let senior = UUID(), junior = UUID()
            let source = try profile(root, "richard sr", id: senior)
            let destination = try profile(root, "richard", id: junior)
            try Data([42]).write(to: destination.appendingPathComponent("junior.jpg"))
            let beforeSource = try snapshot(source), beforeDestination = try snapshot(destination)
            var wrote = false, retired = false
            #expect(throws: POIProfileFileStore.Failure.self) {
                try POIProfileFileStore.save(id: senior, destination: destination, previous: source, retire: { _ in retired = true }, write: { _, _ in wrote = true })
            }
            #expect(!wrote && !retired)
            #expect(try snapshot(source) == beforeSource)
            #expect(try snapshot(destination) == beforeDestination)
        }
    }

    @Test func sameCanonicalFolderUpdatesWithoutRetiringOrLosingAssets() throws {
        try withRoot { root in
            let id = UUID()
            let source = try profile(root, "richard", id: id)
            let bytes = Data([9, 2, 6])
            try bytes.write(to: source.appendingPathComponent("portrait.jpg"))
            let spelling = source.appendingPathComponent(".", isDirectory: true)
            var retired = false
            let warning = try POIProfileFileStore.save(id: id, destination: spelling, previous: source, retire: { _ in retired = true }, write: { path, final in
                #expect(final == source.standardizedFileURL)
                try json(id, name: "Richard Harding Breen Sr").write(to: path, options: .atomic)
            })
            #expect(warning == nil)
            #expect(!retired)
            #expect(try Data(contentsOf: source.appendingPathComponent("portrait.jpg")) == bytes)
            #expect(try Data(contentsOf: source.appendingPathComponent("profile.json")) == json(id, name: "Richard Harding Breen Sr"))
        }
    }

    @Test(arguments: ["{broken", "{}", "{\"uuid\":\"not-a-uuid\"}"])
    func malformedDestinationIdentityFailsClosed(contents: String) throws {
        try withRoot { root in
            let destination = try profile(root, "richard", id: UUID())
            let bytes = Data(contents.utf8)
            try bytes.write(to: destination.appendingPathComponent("profile.json"))
            var wrote = false
            #expect(throws: POIProfileFileStore.Failure.self) {
                try POIProfileFileStore.save(id: UUID(), destination: destination, retire: { _ in Issue.record("Must not retire") }, write: { _, _ in wrote = true })
            }
            #expect(!wrote)
            #expect(try Data(contentsOf: destination.appendingPathComponent("profile.json")) == bytes)
        }
    }

    @Test func failedStagedWriteLeavesSourceUnchangedAndDestinationAbsent() throws {
        try withRoot { root in
            let id = UUID()
            let source = try profile(root, "old", id: id)
            try Data([10, 20, 30]).write(to: source.appendingPathComponent("portrait.jpg"))
            let before = try snapshot(source)
            let destination = root.appendingPathComponent("new")
            var retired = false
            #expect(throws: InjectedFailure.self) {
                try POIProfileFileStore.save(id: id, destination: destination, previous: source, retire: { _ in retired = true }, write: { path, _ in
                    try Data("partial-new-json".utf8).write(to: path)
                    throw InjectedFailure.write
                })
            }
            #expect(!retired)
            #expect(try snapshot(source) == before)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
            #expect(try FileManager.default.contentsOfDirectory(atPath: root.path) == ["old"])
        }
    }

    @Test func retirementFailureReturnsWarningAndKeepsBothCompleteFolders() throws {
        try withRoot { root in
            let id = UUID()
            let source = try profile(root, "old", id: id)
            try Data([44, 99]).write(to: source.appendingPathComponent("portrait.psd"))
            let before = try snapshot(source)
            let destination = root.appendingPathComponent("new")
            let warning = try POIProfileFileStore.save(id: id, destination: destination, previous: source, retire: { _ in throw InjectedFailure.retire }, write: { path, _ in try json(id).write(to: path) })
            #expect(warning != nil)
            #expect(try snapshot(source) == before)
            let actual = try snapshot(destination)
            #expect(actual == before)
        }
    }

    @Test func occupiedSameUUIDDestinationCannotDiscardNewerAssets() throws {
        try withRoot { root in
            let id = UUID()
            let source = try profile(root, "old", id: id)
            let destination = try profile(root, "new", id: id)
            try Data([50]).write(to: destination.appendingPathComponent("newer.heic"))
            let before = try snapshot(destination)
            #expect(throws: POIProfileFileStore.Failure.self) {
                try POIProfileFileStore.save(id: id, destination: destination, previous: source, retire: { _ in Issue.record("Must not retire") }, write: { _, _ in Issue.record("Must not write") })
            }
            #expect(try snapshot(destination) == before)
            #expect(FileManager.default.fileExists(atPath: source.path))
        }
    }

    @Test(arguments: ["", ".", "..", "../richard", "richard/jr", "/tmp/richard"])
    func rejectsUnsafeFolderComponents(component: String) throws {
        try withRoot { root in
            #expect(throws: POIProfileFileStore.Failure.self) {
                try POIProfileFileStore.folder(component: component, in: root)
            }
        }
    }

    @Test func sourceUUIDMismatchLeavesBothNamesUntouched() throws {
        try withRoot { root in
            let source = try profile(root, "old", id: UUID())
            let destination = root.appendingPathComponent("new")
            let before = try snapshot(source)
            #expect(throws: POIProfileFileStore.Failure.self) {
                try POIProfileFileStore.save(id: UUID(), destination: destination, previous: source, retire: { _ in Issue.record("Must not retire") }, write: { _, _ in Issue.record("Must not write") })
            }
            #expect(try snapshot(source) == before)
            #expect(!FileManager.default.fileExists(atPath: destination.path))
        }
    }

    @Test func missingSourceDoesNotCreateReplacementFolder() throws {
        try withRoot { root in
            let source = root.appendingPathComponent("old"), destination = root.appendingPathComponent("new")
            #expect(throws: POIProfileFileStore.Failure.self) {
                try POIProfileFileStore.save(id: UUID(), destination: destination, previous: source, retire: { _ in Issue.record("Must not retire") }, write: { _, _ in Issue.record("Must not write") })
            }
            let remaining = try FileManager.default.contentsOfDirectory(atPath: root.path)
            #expect(remaining.isEmpty)
        }
    }

    @Test func symlinkFolderCannotRedirectWritesToAnotherPerson() throws {
        try withRoot { root in
            let foreign = try profile(root, "junior", id: UUID())
            try Data([42, 7]).write(to: foreign.appendingPathComponent("portrait.jpg"))
            let before = try snapshot(foreign)
            let alias = root.appendingPathComponent("senior")
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: foreign)
            #expect(throws: POIProfileFileStore.Failure.self) {
                try POIProfileFileStore.save(id: UUID(), destination: alias, retire: { _ in Issue.record("Must not retire") }, write: { _, _ in Issue.record("Must not write") })
            }
            #expect(try snapshot(foreign) == before)
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: alias.path) == foreign.path)
        }
    }

    @Test func directSaveCannotOverwriteDifferentUUID() throws {
        try withRoot { root in
            let destination = try profile(root, "richard", id: UUID())
            let before = try snapshot(destination)
            #expect(throws: POIProfileFileStore.Failure.self) {
                try POIProfileFileStore.save(id: UUID(), destination: destination, retire: { _ in Issue.record("Must not retire") }, write: { _, _ in Issue.record("Must not write") })
            }
            #expect(try snapshot(destination) == before)
        }
    }
}
