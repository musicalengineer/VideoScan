import Testing
import Foundation
@testable import VideoScan

@Suite("ScanJobsStorage")
struct ScanJobsStorageTests {

    // MARK: - Helpers

    private func makeSandbox() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanjobs_test_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func sampleDescriptor(
        id: UUID = UUID(),
        personName: String = "Donna",
        searchPath: String = "/Volumes/TestDrive",
        engine: String = "arcface",
        threshold: Float = 0.4,
        // Integer-second precision so iso8601 JSON round-trip preserves exact
        // value — Date() default would carry sub-second precision that .iso8601
        // strips, breaking strict equality checks.
        completedAt: Date = Date(timeIntervalSince1970: 1_750_000_000),
        videosWithHits: Int = 5
    ) -> PersistedJobDescriptor {
        PersistedJobDescriptor(
            id: id,
            personName: personName,
            profileFolderName: "donna",
            searchPath: searchPath,
            engine: engine,
            threshold: threshold,
            referencePath: "/Users/rickb/Library/Application Support/VideoScan/POI/donna",
            referenceFilenames: ["donna_1990.heic", "donna_2005.heic"],
            completedAt: completedAt,
            videosScanned: 240,
            videosTotal: 240,
            videosWithHits: videosWithHits,
            clipsFound: videosWithHits * 3,
            presenceSecs: Double(videosWithHits) * 12.5,
            elapsedSecs: 38.2
        )
    }

    // MARK: - Positive: round-trip

    @Test("Save then listAll returns the same descriptor")
    func roundTripSingle() throws {
        let dir = makeSandbox()
        let descriptor = sampleDescriptor()

        try ScanJobsStorage.save(descriptor, directory: dir)
        let loaded = ScanJobsStorage.listAll(in: dir)

        #expect(loaded.count == 1)
        #expect(loaded[0] == descriptor)
    }

    @Test("listAll returns descriptors sorted newest-first")
    func listAllSortedNewestFirst() throws {
        let dir = makeSandbox()
        let older = sampleDescriptor(completedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let newer = sampleDescriptor(completedAt: Date(timeIntervalSince1970: 1_800_000_000))
        let middle = sampleDescriptor(completedAt: Date(timeIntervalSince1970: 1_750_000_000))

        try ScanJobsStorage.save(older, directory: dir)
        try ScanJobsStorage.save(newer, directory: dir)
        try ScanJobsStorage.save(middle, directory: dir)

        let loaded = ScanJobsStorage.listAll(in: dir)
        #expect(loaded.count == 3)
        #expect(loaded[0].id == newer.id)
        #expect(loaded[1].id == middle.id)
        #expect(loaded[2].id == older.id)
    }

    @Test("Multiple descriptors with same person but different searchPath persist independently")
    func multipleSearchPaths() throws {
        let dir = makeSandbox()
        let d1 = sampleDescriptor(searchPath: "/Volumes/A")
        let d2 = sampleDescriptor(searchPath: "/Volumes/B")

        try ScanJobsStorage.save(d1, directory: dir)
        try ScanJobsStorage.save(d2, directory: dir)

        let loaded = ScanJobsStorage.listAll(in: dir)
        let paths = Set(loaded.map(\.searchPath))
        #expect(paths == ["/Volumes/A", "/Volumes/B"])
    }

    // MARK: - Re-save semantics

    @Test("Re-saving with same id replaces, does not duplicate")
    func resaveReplaces() throws {
        let dir = makeSandbox()
        let id = UUID()
        let first = sampleDescriptor(id: id, videosWithHits: 3)
        let second = sampleDescriptor(id: id, completedAt: first.completedAt.addingTimeInterval(60), videosWithHits: 8)

        try ScanJobsStorage.save(first, directory: dir)
        try ScanJobsStorage.save(second, directory: dir)

        let loaded = ScanJobsStorage.listAll(in: dir)
        #expect(loaded.count == 1, "Re-save with same id must replace, not duplicate")
        #expect(loaded[0].videosWithHits == 8)
    }

    // MARK: - Delete

    @Test("Delete removes the matching descriptor and only that one")
    func deleteRemovesOnlyMatching() throws {
        let dir = makeSandbox()
        let keep = sampleDescriptor()
        let toss = sampleDescriptor()

        try ScanJobsStorage.save(keep, directory: dir)
        try ScanJobsStorage.save(toss, directory: dir)
        #expect(ScanJobsStorage.listAll(in: dir).count == 2)

        let removed = ScanJobsStorage.delete(id: toss.id, directory: dir)
        #expect(removed == true)
        let after = ScanJobsStorage.listAll(in: dir)
        #expect(after.count == 1)
        #expect(after[0].id == keep.id)
    }

    @Test("Delete returns false when id is not present")
    func deleteMissingReturnsFalse() {
        let dir = makeSandbox()
        let removed = ScanJobsStorage.delete(id: UUID(), directory: dir)
        #expect(removed == false)
    }

    // MARK: - enforceLimit

    @Test("enforceLimit is a no-op when count is under the cap")
    func enforceLimitUnderCap() throws {
        let dir = makeSandbox()
        for i in 0..<5 {
            try ScanJobsStorage.save(
                sampleDescriptor(completedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + i * 60))),
                directory: dir
            )
        }
        let removed = ScanJobsStorage.enforceLimit(keep: 10, directory: dir)
        #expect(removed == 0)
        #expect(ScanJobsStorage.listAll(in: dir).count == 5)
    }

    @Test("enforceLimit at exactly the cap is a no-op")
    func enforceLimitAtCap() throws {
        let dir = makeSandbox()
        for i in 0..<10 {
            try ScanJobsStorage.save(
                sampleDescriptor(completedAt: Date(timeIntervalSince1970: Double(1_700_000_000 + i * 60))),
                directory: dir
            )
        }
        let removed = ScanJobsStorage.enforceLimit(keep: 10, directory: dir)
        #expect(removed == 0)
        #expect(ScanJobsStorage.listAll(in: dir).count == 10)
    }

    @Test("enforceLimit trims oldest entries beyond the cap")
    func enforceLimitTrimsOldest() throws {
        let dir = makeSandbox()
        var ids: [(UUID, Date)] = []
        for i in 0..<13 {
            let when = Date(timeIntervalSince1970: Double(1_700_000_000 + i * 60))
            let d = sampleDescriptor(completedAt: when)
            ids.append((d.id, when))
            try ScanJobsStorage.save(d, directory: dir)
        }
        let removed = ScanJobsStorage.enforceLimit(keep: 10, directory: dir)
        #expect(removed == 3, "13 entries minus cap of 10 → 3 should be evicted")

        let remaining = ScanJobsStorage.listAll(in: dir)
        #expect(remaining.count == 10)
        // The 3 oldest IDs (lowest completedAt) must be gone.
        let oldestIds = Set(ids.sorted { $0.1 < $1.1 }.prefix(3).map(\.0))
        let remainingIds = Set(remaining.map(\.id))
        #expect(remainingIds.isDisjoint(with: oldestIds))
    }

    @Test("enforceLimit with keep=0 removes everything")
    func enforceLimitKeepZero() throws {
        let dir = makeSandbox()
        for _ in 0..<3 {
            try ScanJobsStorage.save(sampleDescriptor(), directory: dir)
        }
        let removed = ScanJobsStorage.enforceLimit(keep: 0, directory: dir)
        #expect(removed == 3)
        #expect(ScanJobsStorage.listAll(in: dir).isEmpty)
    }

    // MARK: - Negative: missing directory / corrupt file

    @Test("listAll on a directory that doesn't exist returns empty, never crashes")
    func listAllMissingDirectory() {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scanjobs_nonexistent_\(UUID().uuidString)", isDirectory: true)
        // Deliberately do NOT create the directory.
        let loaded = ScanJobsStorage.listAll(in: url)
        #expect(loaded.isEmpty)
    }

    @Test("Corrupt JSON file is skipped, valid files still load")
    func corruptFileSkipped() throws {
        let dir = makeSandbox()
        let goodDescriptor = sampleDescriptor()
        try ScanJobsStorage.save(goodDescriptor, directory: dir)

        // Inject a corrupt JSON file alongside the good one.
        let garbage = dir.appendingPathComponent("20260101T000000Z__\(UUID().uuidString).json")
        try Data("{ not real JSON ".utf8).write(to: garbage)

        let loaded = ScanJobsStorage.listAll(in: dir)
        #expect(loaded.count == 1, "Corrupt file must not prevent loading the valid file")
        #expect(loaded[0].id == goodDescriptor.id)
    }

    @Test("Non-JSON files in the directory are ignored, not crashed on")
    func nonJsonFilesIgnored() throws {
        let dir = makeSandbox()
        try ScanJobsStorage.save(sampleDescriptor(), directory: dir)

        // Drop a non-JSON file in the store dir.
        try Data("hello".utf8).write(to: dir.appendingPathComponent("README.txt"))

        let loaded = ScanJobsStorage.listAll(in: dir)
        #expect(loaded.count == 1)
    }

    // MARK: - makeDescriptor extraction (lifecycle helper)

    @Test("makeDescriptor uses arcfaceThreshold when engine is .arcface")
    @MainActor
    func makeDescriptorArcFaceThreshold() {
        let job = ScanJob(searchPath: "/Volumes/T")
        job.assignedEngine = .arcface
        var settings = PersonFinderSettings.restored()
        settings.recognitionEngine = .arcface
        settings.threshold = 0.55
        settings.arcfaceThreshold = 0.42
        settings.personName = "Donna"
        let d = PersonFinderModel.makeDescriptor(from: job, settings: settings)
        #expect(abs(d.threshold - 0.42) < 1e-6, "ArcFace job must pick arcfaceThreshold, not the Vision threshold")
        #expect(d.engine == RecognitionEngine.arcface.rawValue)
    }

    @Test("makeDescriptor uses vision threshold when engine is not arcface")
    @MainActor
    func makeDescriptorVisionThreshold() {
        let job = ScanJob(searchPath: "/Volumes/T")
        job.assignedEngine = .vision
        var settings = PersonFinderSettings.restored()
        settings.recognitionEngine = .vision
        settings.threshold = 0.55
        settings.arcfaceThreshold = 0.42
        settings.personName = "Donna"
        let d = PersonFinderModel.makeDescriptor(from: job, settings: settings)
        #expect(abs(d.threshold - 0.55) < 1e-6, "Vision job must pick the vision threshold, not arcfaceThreshold")
    }

    @Test("makeDescriptor falls back to '(global)' when no profile and settings.personName empty")
    @MainActor
    func makeDescriptorGlobalFallback() {
        let job = ScanJob(searchPath: "/Volumes/T")
        var settings = PersonFinderSettings.restored()
        settings.personName = ""
        let d = PersonFinderModel.makeDescriptor(from: job, settings: settings)
        #expect(d.personName == "(global)")
        #expect(d.profileFolderName == nil)
    }

    @Test("makeDescriptor preserves partial-scan stats (paused/cancelled mid-flight)")
    @MainActor
    func makeDescriptorPartialStats() throws {
        // Simulates a paused-mid-scan job: videosScanned < videosTotal.
        // The descriptor must preserve this gap so the restored row shows
        // partial progress and the next Start click resumes (cache fills
        // in the already-done videos near-instantly).
        let job = ScanJob(searchPath: "/Volumes/T")
        job.videosScanned = 47
        job.videosTotal = 120
        job.videosWithHits = 12
        job.clipsFound = 34
        job.presenceSecs = 180.5
        let settings = PersonFinderSettings.restored()
        let d = PersonFinderModel.makeDescriptor(from: job, settings: settings)
        #expect(d.videosScanned == 47)
        #expect(d.videosTotal == 120)
        #expect(d.videosWithHits == 12)
        #expect(d.clipsFound == 34)
        #expect(abs(d.presenceSecs - 180.5) < 1e-6)

        // Round-trip through disk to confirm partial stats survive JSON.
        let dir = makeSandbox()
        try ScanJobsStorage.save(d, directory: dir)
        let loaded = ScanJobsStorage.listAll(in: dir)
        #expect(loaded.first?.videosScanned == 47)
        #expect(loaded.first?.videosTotal == 120)
    }

    @Test("makeDescriptor preserves job.id so re-save replaces in place")
    @MainActor
    func makeDescriptorPreservesJobID() {
        let fixedID = UUID()
        let job = ScanJob(searchPath: "/Volumes/T", id: fixedID)
        let settings = PersonFinderSettings.restored()
        let d = PersonFinderModel.makeDescriptor(from: job, settings: settings)
        #expect(d.id == fixedID, "Descriptor id must equal job.id so re-save updates in place")
    }

    // MARK: - Jobs list partition (active vs history)

    @Test("splitJobs returns empty active+terminal for empty input")
    @MainActor
    func splitJobsEmpty() {
        let (active, terminal) = PersonFinderView.splitJobs([])
        #expect(active.isEmpty)
        #expect(terminal.isEmpty)
    }

    @Test("splitJobs treats idle/scanning/paused as active, done/cancelled as terminal")
    @MainActor
    func splitJobsCategorization() {
        let idle = ScanJob(searchPath: "/a")
        idle.status = .idle
        let scanning = ScanJob(searchPath: "/b")
        scanning.status = .scanning
        let paused = ScanJob(searchPath: "/c")
        paused.status = .paused
        let done = ScanJob(searchPath: "/d")
        done.status = .done
        let cancelled = ScanJob(searchPath: "/e")
        cancelled.status = .cancelled

        let (active, terminal) = PersonFinderView.splitJobs([idle, scanning, paused, done, cancelled])
        let activePaths = Set(active.map(\.searchPath))
        let terminalPaths = Set(terminal.map(\.searchPath))
        // Paused intentionally stays with active — Rick treats it as
        // work-in-flight in the UI, not as historical.
        #expect(activePaths == ["/a", "/b", "/c"])
        #expect(terminalPaths == ["/d", "/e"])
    }

    @Test("splitJobs sorts terminal jobs newest-first by completedAt")
    @MainActor
    func splitJobsTerminalSort() {
        let older = ScanJob(searchPath: "/older")
        older.status = .done
        older.completedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let newer = ScanJob(searchPath: "/newer")
        newer.status = .done
        newer.completedAt = Date(timeIntervalSince1970: 1_800_000_000)

        let middle = ScanJob(searchPath: "/middle")
        middle.status = .done
        middle.completedAt = Date(timeIntervalSince1970: 1_750_000_000)

        let (_, terminal) = PersonFinderView.splitJobs([older, newer, middle])
        #expect(terminal.map(\.searchPath) == ["/newer", "/middle", "/older"])
    }

    @Test("splitJobs puts jobs with nil completedAt at the bottom of history")
    @MainActor
    func splitJobsNilCompletedAt() {
        let withDate = ScanJob(searchPath: "/dated")
        withDate.status = .done
        withDate.completedAt = Date(timeIntervalSince1970: 1_700_000_000)

        let noDate = ScanJob(searchPath: "/undated")
        noDate.status = .done
        // completedAt left nil

        let (_, terminal) = PersonFinderView.splitJobs([noDate, withDate])
        #expect(terminal.first?.searchPath == "/dated")
        #expect(terminal.last?.searchPath == "/undated")
    }

    // MARK: - makeJob (restore-from-descriptor regression coverage)

    @Test("makeJob restores assignedEngine from descriptor — effectiveEngine matches what actually ran")
    @MainActor
    func makeJobRestoresEngineArcFace() {
        // Descriptor stores engine as RecognitionEngine.rawValue, so the
        // string is the human-readable form, not the case name.
        let d = sampleDescriptor(engine: RecognitionEngine.arcface.rawValue)
        let job = PersonFinderModel.makeJob(from: d)
        // Without explicit assignedEngine restore, effectiveEngine would
        // fall through to the (nil) profile.engine and then to .vision,
        // silently showing the wrong algorithm in the summary. This test
        // is the regression guard for that bug.
        #expect(job.effectiveEngine == .arcface)
        #expect(job.assignedEngine == .arcface)
    }

    @Test("makeJob restores assignedEngine for vision too")
    @MainActor
    func makeJobRestoresEngineVision() {
        let d = sampleDescriptor(engine: RecognitionEngine.vision.rawValue)
        let job = PersonFinderModel.makeJob(from: d)
        #expect(job.effectiveEngine == .vision)
        #expect(job.assignedEngine == .vision)
    }

    @Test("makeJob preserves the descriptor's id so re-save updates in place")
    @MainActor
    func makeJobPreservesID() {
        let fixedID = UUID()
        let d = sampleDescriptor(id: fixedID)
        let job = PersonFinderModel.makeJob(from: d)
        #expect(job.id == fixedID)
    }

    @Test("makeJob sets status to .done and copies summary stats")
    @MainActor
    func makeJobCopiesSummaryStats() {
        let d = sampleDescriptor(videosWithHits: 17)
        let job = PersonFinderModel.makeJob(from: d)
        #expect(job.status == .done)
        #expect(job.videosWithHits == 17)
        #expect(job.videosScanned == d.videosScanned)
        #expect(job.videosTotal == d.videosTotal)
        #expect(job.completedAt == d.completedAt)
        #expect(abs(job.elapsedSecs - d.elapsedSecs) < 1e-6)
    }

    @Test("makeJob preserves partial-scan stats — wasInterrupted reads true")
    @MainActor
    func makeJobInterruptedRoundTrip() {
        // Simulates restore of a paused-then-quit search.
        var d = sampleDescriptor()
        d = PersistedJobDescriptor(
            id: d.id, personName: d.personName,
            profileFolderName: d.profileFolderName, searchPath: d.searchPath,
            engine: d.engine, threshold: d.threshold,
            referencePath: d.referencePath, referenceFilenames: d.referenceFilenames,
            completedAt: d.completedAt,
            videosScanned: 50, videosTotal: 120,
            videosWithHits: d.videosWithHits, clipsFound: d.clipsFound,
            presenceSecs: d.presenceSecs, elapsedSecs: d.elapsedSecs
        )
        let job = PersonFinderModel.makeJob(from: d)
        #expect(job.wasInterrupted == true)
    }

    // MARK: - wasInterrupted

    @Test("wasInterrupted is false when scan is active")
    @MainActor
    func interruptedFalseWhenActive() {
        let job = ScanJob(searchPath: "/x")
        job.status = .scanning
        job.videosScanned = 50
        job.videosTotal = 100
        #expect(job.wasInterrupted == false)
    }

    @Test("wasInterrupted is false when scan completed fully")
    @MainActor
    func interruptedFalseWhenComplete() {
        let job = ScanJob(searchPath: "/x")
        job.status = .done
        job.videosScanned = 100
        job.videosTotal = 100
        #expect(job.wasInterrupted == false)
    }

    @Test("wasInterrupted is true for a done job that didn't reach the total (resumed/restored)")
    @MainActor
    func interruptedTrueForPartialDone() {
        let job = ScanJob(searchPath: "/x")
        job.status = .done
        job.videosScanned = 50
        job.videosTotal = 100
        #expect(job.wasInterrupted == true)
    }

    @Test("wasInterrupted is true for cancelled with partial progress")
    @MainActor
    func interruptedTrueForPartialCancelled() {
        let job = ScanJob(searchPath: "/x")
        job.status = .cancelled
        job.videosScanned = 25
        job.videosTotal = 100
        #expect(job.wasInterrupted == true)
    }

    @Test("wasInterrupted is false when videosTotal is 0 (no work was attempted)")
    @MainActor
    func interruptedFalseWhenTotalZero() {
        let job = ScanJob(searchPath: "/x")
        job.status = .cancelled
        job.videosScanned = 0
        job.videosTotal = 0
        #expect(job.wasInterrupted == false)
    }

    // MARK: - Filename format

    @Test("Filename has sortable timestamp prefix and UUID")
    func filenameFormat() {
        let id = UUID()
        let when = Date(timeIntervalSince1970: 1_700_000_000)
        let d = sampleDescriptor(id: id, completedAt: when)
        let name = ScanJobsStorage.filename(for: d)
        #expect(name.hasSuffix(".json"))
        #expect(name.contains(id.uuidString))
        // Verify the timestamp prefix sorts correctly relative to a later time.
        let later = sampleDescriptor(completedAt: when.addingTimeInterval(3600))
        let laterName = ScanJobsStorage.filename(for: later)
        #expect(name < laterName, "Earlier timestamp must sort before later timestamp")
    }
}
