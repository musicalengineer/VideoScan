import Testing
import Foundation
@testable import VideoScan

// Validates that the test-isolation seams in ScanJobsStorage and
// PersonFinderModel actually fire under XCTest / Swift Testing.
//
// Why a dedicated suite: these aren't tests of a feature — they're tests
// of the test harness itself. If any of these fail, every other test that
// goes through the production save path silently pollutes the real
// ~/Library/Application Support/VideoScan/scan_jobs/ directory. A failing
// name here points straight at the broken invariant.
@Suite("Test isolation guards")
struct TestIsolationTests {

    // MARK: - storeDir redirection

    @Test("storeDir under test routes to per-PID sandbox, not Application Support")
    func storeDirUnderTestRedirectsToSandbox() {
        let dir = ScanJobsStorage.storeDir.path

        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!.path
        #expect(!dir.hasPrefix(appSupport),
                "storeDir leaked into Application Support: \(dir)")

        let pidMarker = "VideoScanTests-\(ProcessInfo.processInfo.processIdentifier)"
        #expect(dir.contains(pidMarker),
                "storeDir missing per-PID sandbox marker '\(pidMarker)': \(dir)")

        var isDir: ObjCBool = false
        #expect(FileManager.default.fileExists(atPath: dir, isDirectory: &isDir) && isDir.boolValue,
                "storeDir didn't materialize on disk: \(dir)")
    }

    // MARK: - Production save() doesn't escape sandbox

    @Test("save() through the no-arg wrapper leaves Application Support untouched")
    func productionSaveDoesNotPolluteApplicationSupport() throws {
        let realScanJobs = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("VideoScan", isDirectory: true)
            .appendingPathComponent("scan_jobs", isDirectory: true)

        let before = (try? FileManager.default
            .contentsOfDirectory(atPath: realScanJobs.path).count) ?? 0

        let descriptor = PersistedJobDescriptor(
            id: UUID(),
            personName: "IsolationCanary",
            profileFolderName: nil,
            searchPath: "/tmp/isolation-canary",
            engine: "vision",
            threshold: 0.5,
            referencePath: "/tmp/isolation-canary/refs",
            referenceFilenames: [],
            completedAt: Date(),
            videosScanned: 0,
            videosTotal: 0,
            videosWithHits: 0,
            clipsFound: 0,
            presenceSecs: 0,
            elapsedSecs: 0
        )
        try ScanJobsStorage.save(descriptor)

        let after = (try? FileManager.default
            .contentsOfDirectory(atPath: realScanJobs.path).count) ?? 0
        #expect(after == before,
                "Production save() escaped sandbox and wrote to Application Support (was \(before), now \(after))")

        #expect(ScanJobsStorage.listAll().contains(where: { $0.id == descriptor.id }),
                "save() didn't land in the sandbox storeDir either — listAll() can't find it")
    }

    // MARK: - PersonFinderModel.init skips restoreSessionFromDisk under test

    @MainActor
    @Test("PersonFinderModel.init() does not auto-restore descriptors under test")
    func personFinderModelInitDoesNotRestoreFromDisk() throws {
        // Plant a descriptor through the production save path. Without the
        // init-time guard this would surface in jobs as a phantom .done entry.
        let descriptor = PersistedJobDescriptor(
            id: UUID(),
            personName: "RestoreCanary",
            profileFolderName: nil,
            searchPath: "/tmp/restore-canary",
            engine: "vision",
            threshold: 0.5,
            referencePath: "/tmp/restore-canary/refs",
            referenceFilenames: [],
            completedAt: Date(),
            videosScanned: 1,
            videosTotal: 1,
            videosWithHits: 0,
            clipsFound: 0,
            presenceSecs: 0,
            elapsedSecs: 0
        )
        try ScanJobsStorage.save(descriptor)

        // Confirm the descriptor really is on disk (otherwise the next
        // assertion is vacuously true and tells us nothing).
        #expect(ScanJobsStorage.listAll().contains(where: { $0.id == descriptor.id }),
                "Precondition failed: descriptor not on disk, can't validate skip")

        let model = PersonFinderModel()
        #expect(model.jobs.isEmpty,
                "PersonFinderModel restored \(model.jobs.count) descriptor(s) from disk under test — restoreSessionFromDisk guard is broken")
    }
}
