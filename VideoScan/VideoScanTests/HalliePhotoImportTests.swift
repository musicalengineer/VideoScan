import Foundation
import Testing
@testable import VideoScan

// HalliePhotoImport (codex #675): behavioural proof that cancelling the
// caller cancels the worker, and that a file is never read whole past the
// cap.
@Suite("Hallie photo import worker", .serialized)
struct HalliePhotoImportTests {
    private let fileManager = FileManager.default

    private func fixture() throws -> (base: URL, configuration: FamilyAssetConfiguration, folder: URL) {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("HalliePhotoImportTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let roots = FamilyAssetStore.Roots(
            assets: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            thumbnailCache: base.appendingPathComponent("support/thumbs", isDirectory: true))
        let configuration = FamilyAssetConfiguration(roots: roots, access: .readWrite, legacyGEDCOMDirectory: nil)
        let folder = try configuration.makeStore().folderForPhotoRequest(
            person: FamilyAssetPerson(name: "Judson Lamb", birthYear: 1846))
        return (base, configuration, folder)
    }

    /// The loader blocks until it is cancelled — like a Photos export of
    /// a large asset. Cancelling the task that awaits `run` must unblock
    /// it with CancellationError and leave the folder empty.
    @Test func cancellingTheCallerCancelsTheDetachedWorker() async throws {
        let (_, configuration, folder) = try fixture()
        let started = Signal()
        let task = Task {
            await HalliePhotoImport.run(
                load: { () async throws -> HalliePickedPhotoFile? in
                    await started.fire()
                    try await Task.sleep(nanoseconds: 30_000_000_000)   // 30 s — must not elapse
                    return nil
                },
                configuration: configuration,
                folder: folder)
        }
        await started.wait()
        task.cancel()
        let outcome = await task.value
        guard case .failure(let error) = outcome else {
            Issue.record("expected failure, got \(outcome)")
            return
        }
        #expect(error is CancellationError, "got \(error)")
        #expect(try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func oversizedFileIsRefusedByStatBeforeAnyRead() async throws {
        let (base, configuration, folder) = try fixture()
        let big = base.appendingPathComponent("big.jpg")
        // Sparse: 1 byte past the cap costs nothing to create.
        let handle = try FileHandle(forWritingTo: { fileManager.createFile(atPath: big.path, contents: nil); return big }())
        try handle.seek(toOffset: UInt64(FamilyAssetStore.maxImportBytes))
        try handle.write(contentsOf: Data([0]))
        try handle.close()
        let outcome = await HalliePhotoImport.run(
            load: { HalliePickedPhotoFile(url: big) },
            configuration: configuration, folder: folder)
        guard case .failure(let error) = outcome else { Issue.record("expected failure"); return }
        #expect(error as? HalliePhotoImport.Failure == .tooLarge(bytes: FamilyAssetStore.maxImportBytes + 1))
        #expect(try fileManager.contentsOfDirectory(atPath: folder.path).isEmpty)
    }

    @Test func boundedReadRefusesSymlinksAndReadsAtMostCapPlusOne() throws {
        let (base, _, _) = try fixture()
        let real = base.appendingPathComponent("real.bin")
        try Data(repeating: 7, count: 1000).write(to: real)
        let link = base.appendingPathComponent("link.bin")
        try fileManager.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: HalliePhotoImport.Failure.notARegularFile) {
            try HalliePhotoImport.boundedRead(link, maxBytes: 5000)
        }
        #expect(try HalliePhotoImport.boundedRead(real, maxBytes: 5000).count == 1000)
        #expect(throws: HalliePhotoImport.Failure.tooLarge(bytes: 1000)) {
            try HalliePhotoImport.boundedRead(real, maxBytes: 999)
        }
    }

    /// A one-shot latch so the test cancels only after the loader is
    /// genuinely blocked inside the worker.
    private actor Signal {
        private var fired = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func fire() { fired = true; waiters.forEach { $0.resume() }; waiters = [] }
        func wait() async {
            if fired { return }
            await withCheckedContinuation { waiters.append($0) }
        }
    }
}
