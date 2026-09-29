// HalliePhotoImport.swift
// "Choose from Photos…" worker (2026-08-25, codex #663/#675).
//
// Three things the first cut got wrong, all fixed here:
//   * `loadTransferable(type: Data.self)` allocated the WHOLE Photos asset
//     before any size check. Now Photos hands us a FILE, we stat it, and
//     only a file under the cap is read — with a bounded read that also
//     refuses a file that grew while we were looking.
//   * A view `Task {}` cancelling did not cancel the detached worker —
//     `Task.checkCancellation()` inside the worker saw only its own flag.
//     `run` bridges cancellation explicitly with a cancellation handler.
//   * The store snapshot and archive write ran on the main actor.
//
// Pure enough to test: the loader is injected, so a test can hand it a
// file it prepared, or one that blocks until cancelled.

import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Photos → a temporary file we own. `FileRepresentation` makes Photos
/// export to disk instead of materialising `Data` in our process.
struct HalliePickedPhotoFile: Transferable, Sendable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            let scratch = FileManager.default.temporaryDirectory
                .appendingPathComponent("hallie-photo-import", isDirectory: true)
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            let ext = received.file.pathExtension.isEmpty ? "jpg" : received.file.pathExtension
            let copy = scratch.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return HalliePickedPhotoFile(url: copy)
        }
    }
}

enum HalliePhotoImport {

    enum Failure: LocalizedError, Equatable {
        case nothingPicked
        case notARegularFile
        case tooLarge(bytes: Int)

        var errorDescription: String? {
            switch self {
            case .nothingPicked: return "Nothing was picked."
            case .notARegularFile: return "Photos handed over something that is not a regular image file."
            case .tooLarge(let bytes):
                return FamilyAssetStore.StoreError.imageTooLarge(bytes: bytes).errorDescription
            }
        }
    }

    /// Import the picked photo into `folder`. Runs detached; cancelling
    /// the CALLING task cancels the worker (verified by test), and the
    /// result is then `.failure(CancellationError)`.
    static func run(
        load: @escaping @Sendable () async throws -> HalliePickedPhotoFile?,
        configuration: FamilyAssetConfiguration,
        folder: URL,
        maxBytes: Int = FamilyAssetStore.maxImportBytes
    ) async -> Result<URL, Error> {
        let worker = Task.detached(priority: .userInitiated) { () throws -> URL in
            guard let picked = try await load() else { throw Failure.nothingPicked }
            defer { try? FileManager.default.removeItem(at: picked.url) }
            try Task.checkCancellation()
            let data = try boundedRead(picked.url, maxBytes: maxBytes)
            try Task.checkCancellation()
            let ext = picked.url.pathExtension.lowercased()
            return try configuration.makeStore()
                .importPersonPhoto(data, fileExtension: ext, into: folder)
        }
        return await withTaskCancellationHandler {
            await worker.result
        } onCancel: {
            worker.cancel()
        }
    }

    /// stat first, then read at most `maxBytes + 1` so a file that is (or
    /// becomes) too large is refused without ever being held whole.
    static func boundedRead(_ url: URL, maxBytes: Int) throws -> Data {
        var sb = stat()
        guard lstat(url.path, &sb) == 0, (sb.st_mode & S_IFMT) == S_IFREG else {
            throw Failure.notARegularFile
        }
        guard sb.st_size <= maxBytes else { throw Failure.tooLarge(bytes: Int(sb.st_size)) }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw Failure.tooLarge(bytes: data.count) }
        return data
    }
}
