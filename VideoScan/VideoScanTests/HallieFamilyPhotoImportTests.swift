// HallieFamilyPhotoImportTests.swift
// "Choose from Photos…" on Hallie's photo-request card saves through the
// hardened store (Rick 2026-08-24). Isolation: temp roots only.

import Foundation
import Testing
@testable import VideoScan

@Suite("Family photo import from Photos — hardened store path")
struct HallieFamilyPhotoImportTests {
    private let fileManager = FileManager.default
    private let pngBytes = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!

    private func temporaryStore() throws -> (base: URL, store: FamilyAssetStore) {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HalliePhotoImport-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        return (base, FamilyAssetStore(
            root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true)))
    }

    @Test func importsARealImageIntoThePersonFolderAndItIsThenFound() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let person = FamilyAssetPerson(name: "Isaac Damon")
        let folder = try store.folderForPhotoRequest(person: person)
        let saved = try store.importPersonPhoto(pngBytes, fileExtension: "png", into: folder)
        #expect(saved.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL)
        #expect(saved.lastPathComponent.contains("from-Photos"))
        #expect(store.photoURLs(for: person).contains { $0.standardizedFileURL == saved.standardizedFileURL })
        // A second import never overwrites the first.
        let again = try store.importPersonPhoto(pngBytes, fileExtension: "png", into: folder)
        #expect(again != saved)
        #expect(store.photoURLs(for: person).count == 2)
    }

    @Test func rejectsNonImagesBeforeTheyReachTheArchive() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let folder = try store.folderForPhotoRequest(person: FamilyAssetPerson(name: "Isaac Damon"))
        #expect(throws: (any Error).self) {
            try store.importPersonPhoto(Data("not an image".utf8), fileExtension: "png", into: folder)
        }
        #expect(throws: (any Error).self) {
            try store.importPersonPhoto(pngBytes, fileExtension: "exe", into: folder)
        }
        let contents = (try? fileManager.contentsOfDirectory(atPath: folder.path)) ?? []
        #expect(contents.isEmpty)
    }

    @Test func refusesFoldersOutsidePeopleAndReadOnlyStores() throws {
        let (base, store) = try temporaryStore()
        defer { try? fileManager.removeItem(at: base) }
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try fileManager.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        #expect(throws: (any Error).self) {
            try store.importPersonPhoto(pngBytes, fileExtension: "png", into: elsewhere)
        }
        let readOnly = FamilyAssetStore(
            root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true),
            access: .readOnly)
        let folder = try store.folderForPhotoRequest(person: FamilyAssetPerson(name: "Isaac Damon"))
        #expect(throws: (any Error).self) {
            try readOnly.importPersonPhoto(pngBytes, fileExtension: "png", into: folder)
        }
    }
}
