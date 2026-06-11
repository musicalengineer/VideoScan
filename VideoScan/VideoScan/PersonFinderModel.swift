// PersonFinderModel.swift
// Drives multi-volume person-finding scans inside the VideoScan app.
// Each ScanJob represents one search target (volume or folder).

import Foundation
@preconcurrency import AVFoundation
import Vision
import CoreImage
import CoreGraphics
import CoreML
import SwiftUI
import Combine
import os

/// Logger for the personfinder code path. Streamed remotely via:
///   log stream --process VideoScan \
///     --predicate 'subsystem == "Rick-Breen.VideoScan"' --style compact
///
/// Named `osLog` (not `log`) because there's a local `log = PersistentLog(...)`
/// inside runJob that would otherwise shadow this. In-app console
/// (job.appendLog) is for the user; this Logger is for the agent watching
/// remotely. Most failure paths log to both.
// Module-wide logger — used by Compilation extension and (in step 6) JobLifecycle extension.
let osLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "personfinder"
)

let perfLog = Logger(
    subsystem: "Rick-Breen.VideoScan",
    category: "perf"
)
let signpostLog = OSSignposter(
    subsystem: "Rick-Breen.VideoScan",
    category: "perf"
)

// Value types (FramePerfAccumulator, RecognitionEngine, PersonFinderSettings,
// POIProfile, ScanJobStatus, Compilation{Mode,Settings,Status}, ReferenceFace,
// ReferenceLoadFailure, ClipResult, CompiledOutput, pfVideoResult, pfSegment)
// live in PersonFinderTypes.swift.

// MARK: - Scan Job

// Task fields and timer methods are internal so PersonFinderModel+JobLifecycle.swift can manage task lifecycle from across files.
@MainActor
final class ScanJob: ObservableObject, Identifiable {
    let id: UUID
    @Published var searchPath: String

    /// Per-job person assignment — nil means use global person.
    @Published var assignedProfile: POIProfile?
    var assignedFaces: [ReferenceFace] = []
    /// ArcFace reference embeddings, computed once per job and reused
    /// across every video. Empty until the first scan video populates it.
    /// Why caching: `pfRunArcFaceEngine` previously called
    /// `arcfaceLoadReferenceEmbeddings` per VIDEO — wasted work AND
    /// multiplied concurrent MLModel.prediction() calls by N-references
    /// per video, which hit the MLE5BindEmptyMemoryObjectToPort race
    /// even with per-call MLModel instances.
    var assignedArcFaceEmbeddings: [[Float]] = []
    var personLabel: String { assignedProfile?.name ?? "" }

    /// Per-job engine override — nil means use profile's engine or global default.
    @Published var assignedEngine: RecognitionEngine?
    /// Resolved engine: job override > profile > global default
    var effectiveEngine: RecognitionEngine {
        if let e = assignedEngine { return e }
        if let p = assignedProfile, let e = RecognitionEngine(rawValue: p.engine) { return e }
        return .vision
    }

    @Published var status: ScanJobStatus = .idle
    @Published var progress: Double = 0.0
    @Published var currentFile: String = ""
    @Published var videosTotal: Int = 0
    @Published var videosScanned: Int = 0
    @Published var videosWithHits: Int = 0
    @Published var clipsFound: Int = 0
    @Published var presenceSecs: Double = 0.0
    @Published var results: [ClipResult] = []
    @Published var consoleLines: [String] = []
    @Published var compiledVideoPaths: [CompiledOutput] = []
    @Published var elapsedSecs: Double = 0.0

    /// Wall-clock time the job last transitioned to a terminal state
    /// (.done, .paused, .cancelled). Used to sort done rows newest-first
    /// in the jobs list. nil while the job is still active or fresh-idle.
    @Published var completedAt: Date?

    /// True when a terminal job didn't scan everything in its search path —
    /// e.g. user paused and quit, or stopped mid-scan. Drives the UI's
    /// "Search Interrupted" yellow label vs the green "Search Complete".
    var wasInterrupted: Bool {
        status.isTerminal && videosTotal > 0 && videosScanned < videosTotal
    }

    // Compilation state (separate from scan lifecycle)
    @Published var compilationStatus: CompilationStatus = .idle
    @Published var compilationProgress: Double = 0.0
    @Published var compilationPhase: String = ""
    @Published var compilationClipsTotal: Int = 0
    @Published var compilationClipsDone: Int = 0
    var compilationTask: Task<Void, Never>?

    /// Raw recognition results preserved for on-demand compilation.
    /// Plain @MainActor storage (was nonisolated(unsafe)): every writer
    /// runs inside MainActor.run (JobLifecycle) and every reader is a
    /// @MainActor method (startCompilation snapshots these into values
    /// before hopping to its detached task), so the escape hatch was
    /// unnecessary — 2026-06-11 concurrency-hygiene pass.
    var recognitionResults: [pfVideoResult] = []
    var recognitionOutputDir: String = ""

    // Live frame preview — three values that always change together,
    // packed into one @Published so each per-frame update fires a single
    // SwiftUI invalidation instead of three. Coords are Vision normalized,
    // bottom-left origin (matches the producer side).
    struct LivePreview: Equatable {
        var frame: CGImage?
        var matched: [CGRect] = []
        var unmatched: [CGRect] = []
    }
    @Published var livePreview: LivePreview = .init()

    // Best feature-print distance seen across all videos (lower = closer match)
    @Published var bestDist: Float = .greatestFiniteMagnitude

    /// Display rate for live preview — adjustable in realtime from UI.
    /// Read by the scan loop each frame; not part of the snapshot settings.
    /// Lock-backed (was nonisolated(unsafe) leaning on ARM64 atomicity —
    /// Swift's data-race model needs real synchronization regardless of
    /// ISA): written from MainActor UI, read from the scan loop's
    /// @Sendable previewRateFn closures off-main.
    /// OSAllocatedUnfairLock ≈ a C++ member `std::mutex` guarding one int,
    /// with `withLock` ≈ std::lock_guard — non-reentrant, no allocation
    /// per access. `nonisolated` opts these out of the class's @MainActor
    /// so any thread may touch them; safety comes from the lock itself.
    private nonisolated let _previewRate = OSAllocatedUnfairLock(initialState: 5)
    nonisolated var previewRate: Int {
        get { _previewRate.withLock { $0 } }
        set { _previewRate.withLock { $0 = newValue } }
    }

    var scanTask: Task<Void, Never>?
    var timerTask: Task<Void, Never>?
    fileprivate var taskStarted: Date?
    /// True when this job was reconstructed from a persisted descriptor
    /// on app launch and the user paused it before the previous quit.
    /// resumeJob uses this to choose its strategy: in-process paused jobs
    /// (this flag false) release the pauseGate to let the still-running
    /// scanTask continue between videos; from-disk paused jobs (this flag
    /// true) have no live scanTask, so resume re-invokes startJob and lets
    /// the per-video PersonFinderCache lookup skip files already scanned.
    var wasRestoredFromDisk: Bool = false
    /// Wall time accumulated across pauses. elapsedSecs = accumulatedElapsed +
    /// (taskStarted ? now - taskStarted : 0). Reset on startElapsedTimer.
    fileprivate var accumulatedElapsed: TimeInterval = 0

    /// Buffer for appendLog batching — lines accumulate here and flush to the
    /// @Published `consoleLines` array once per `consoleFlushIntervalSec`.
    /// Cuts per-line SwiftUI invalidations to per-batch (typically ~5× fewer
    /// re-renders on the RTFD window's console pane during chatty scans).
    private var pendingConsoleLines: [String] = []
    private var consoleFlushScheduled: Bool = false
    private static let consoleFlushIntervalSec: Double = 0.200

    /// Cooperative pause gate — tasks check this between videos
    let pauseGate = PauseGate()

    /// Persistent log file for this scan job — crash-safe, immediate writes.
    /// Plain @MainActor storage (was nonisolated(unsafe)): assigned in
    /// runJob (MainActor) and read only by appendLog (MainActor); the
    /// scan loop reaches it via the async logFn closure, which awaits
    /// onto the main actor first — 2026-06-11 concurrency-hygiene pass.
    var persistentLog: PersistentLog?

    init(searchPath: String, id: UUID = UUID()) {
        self.id = id
        self.searchPath = searchPath
    }

    func appendLog(_ line: String) {
        persistentLog?.write(line)  // disk write is immediate — crash-safe
        pendingConsoleLines.append(line)
        scheduleConsoleFlush()
    }

    /// Schedule a single flush of pendingConsoleLines into the @Published
    /// consoleLines array. Idempotent — multiple appendLog calls within the
    /// flush window coalesce into one publish.
    private func scheduleConsoleFlush() {
        if consoleFlushScheduled { return }
        consoleFlushScheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(Self.consoleFlushIntervalSec * 1000)))
            self?.flushConsoleLines()
        }
    }

    /// Synchronously drain pendingConsoleLines into the @Published
    /// `consoleLines` array. Production code lets the 200ms timer do this
    /// automatically (preserves the batching win on chatty scans); tests and
    /// other synchronous consumers can call this directly when they need an
    /// immediate view of recently-logged lines without waiting for the timer.
    func flushConsoleLines() {
        consoleFlushScheduled = false
        guard !pendingConsoleLines.isEmpty else { return }
        consoleLines.append(contentsOf: pendingConsoleLines)
        pendingConsoleLines.removeAll(keepingCapacity: true)
        if consoleLines.count > 2000 {
            consoleLines.removeFirst(consoleLines.count - 2000)
        }
    }

    func reset() {
        scanTask?.cancel(); timerTask?.cancel()
        compilationTask?.cancel()
        Task { await pauseGate.resume() }  // release any waiters
        status = .idle; progress = 0; currentFile = ""
        videosTotal = 0; videosScanned = 0; videosWithHits = 0
        clipsFound = 0; presenceSecs = 0
        results = []; consoleLines = []
        pendingConsoleLines.removeAll(keepingCapacity: false)
        consoleFlushScheduled = false
        compiledVideoPaths = []; elapsedSecs = 0
        compilationStatus = .idle; compilationProgress = 0
        compilationPhase = ""; compilationClipsTotal = 0; compilationClipsDone = 0
        recognitionResults = []; recognitionOutputDir = ""
        livePreview = .init()
        bestDist = .greatestFiniteMagnitude
        scanTask = nil; timerTask = nil; compilationTask = nil; taskStarted = nil
        accumulatedElapsed = 0
    }

    func finalizeResults(_ filtered: [ClipResult]) {
        results = filtered
        videosWithHits = filtered.count
        // High-level narration to videoscan.log — matches the "Starting search…"
        // line emitted in startJobAfterLoad.
        let personName = assignedProfile?.name ?? "(global)"
        let volumeName = URL(fileURLWithPath: searchPath).lastPathComponent
        let elapsed = taskStarted.map { Int(Date().timeIntervalSince($0)) } ?? 0
        appLog.write("Finished search for \(personName) on \(volumeName): \(filtered.count) video(s) with hits in \(elapsed)s")
    }

    func startElapsedTimer() {
        taskStarted = Date()
        accumulatedElapsed = 0
        timerTask = Task { [weak self] in
            while !Task.isCancelled {
                // 1 Hz is enough for the displayed "elapsed 0:01:23" — the
                // earlier 2 Hz tick was overkill and contributed a steady
                // background of @Published invalidations to every observer
                // of the ScanJob (ScanJobRow, RTFD window, etc.). With 4
                // concurrent jobs the prior rate produced ~240 extra
                // invalidations per 30 s window.
                try? await Task.sleep(for: .seconds(1))
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    let live = self.taskStarted.map { Date().timeIntervalSince($0) } ?? 0
                    self.elapsedSecs = self.accumulatedElapsed + live
                }
            }
        }
    }

    /// Freeze the wall-clock contribution into the accumulator so the next
    /// timer tick reads "paused elapsed = accumulator + 0". pauseJob calls this.
    func pauseElapsedTimer() {
        if let s = taskStarted {
            accumulatedElapsed += Date().timeIntervalSince(s)
            taskStarted = nil
        }
    }

    /// Resume wall-clock counting from the current accumulator.
    func resumeElapsedTimer() {
        if taskStarted == nil { taskStarted = Date() }
    }

    func stopElapsedTimer() {
        timerTask?.cancel()
        if let s = taskStarted { accumulatedElapsed += Date().timeIntervalSince(s) }
        elapsedSecs = accumulatedElapsed
        taskStarted = nil
        // Drain any buffered console lines so the final state shown to the
        // user reflects everything that was logged, not just up to the last
        // scheduled flush.
        flushConsoleLines()
    }
}

// MARK: - Person Finder Model

@MainActor
final class PersonFinderModel: ObservableObject {
    @Published var jobs: [ScanJob] = []
    @Published var settings = PersonFinderSettings.restored() {
        didSet { settings.save() }
    }
    /// UI state preserved across tab switches (model outlives the view).
    @Published var selectedJobID: UUID?
    @Published var expandedJobIDs = Set<UUID>()

    /// Optional reference to DashboardState for publishing Vision/ANE metrics.
    weak var dashboard: DashboardState?

    /// Binding wrapper that auto-saves settings on every write.
    /// Use `model.settingsBinding.threshold` etc. in SwiftUI controls.
    /// @Observable kills didSet, so we explicitly save here.
    var settingsBinding: Binding<PersonFinderSettings> {
        Binding(
            get: { self.settings },
            set: { self.settings = $0; $0.save() }
        )
    }
    var referenceFaces: [ReferenceFace] = []
    var referenceSources: [String] = []     // display labels for each loaded source folder/file

    /// Optional sink invoked at the end of every scan that produced presence
    /// matches. The app wires this to VideoScanModel.applyDetectedPeople so
    /// successful runs append the POI's name to each matched VideoRecord's
    /// `detectedPeople` (or `suspectedPeople`) list — the catalog learns
    /// "Donna is in this file" with a confidence tier.
    ///
    /// `@MainActor` on the closure type: the writeback mutates catalog state
    /// which is MainActor-bound, and the annotation makes the closure type
    /// implicitly Sendable so it can be captured into a detached Task that
    /// drives the cache-restore path without triggering Swift 6 isolation
    /// errors.
    ///
    /// Two match arrays carry the confidence tier split, done inside
    /// PersonFinderModel (which knows the engine + threshold) before the
    /// sink fires: confirmed = bestDistance ≤ threshold − margin, suspected
    /// = within margin of threshold. Catalog routes them to the right field.
    ///
    /// Closure form (not a delegate) keeps PersonFinderModel decoupled from
    /// VideoScanModel — unit tests still construct PersonFinderModel() in
    /// isolation without dragging in catalog wiring.
    var onScanComplete: (
        @MainActor (
            _ personLabel: String,
            _ confirmed: [pfVideoResult],
            _ suspected: [pfVideoResult]
        ) -> Void
    )?

    /// Name of the person being actively scanned — set at scan start, cleared when all jobs finish.
    @Published var scanningPersonName: String?
    /// The person that will be assigned to newly created jobs.
    @Published var selectedPersonForNewJobs: POIProfile?
    var referenceLoadError: String?
    @Published var referenceLoadFailures: [ReferenceLoadFailure] = []
    var isLoadingReference: Bool = false

    var referenceFeaturePrints: [VNFeaturePrintObservation] { referenceFaces.map(\.featurePrint) }
    var referencePhotoCount: Int { referenceFaces.count }

    init() {
        let floorGB = ScanPerformanceSettings.restored().memoryFloorGB
        Task { await MemoryPressureMonitor.shared.setFloorGB(floorGB) }
        // Restore previously-completed searches so the user doesn't lose
        // context across app launches (issue #89). Results table rehydrates
        // in the background from the existing PersonFinderCache.
        //
        // Skip under tests: any test in the same process that exercises the
        // production save() path leaves descriptors in the test temp dir,
        // and subsequent `PersonFinderModel()` calls would pick them up as
        // stray jobs. Tests that specifically need to verify the restore
        // flow can call `restoreSessionFromDisk()` explicitly.
        if !Self.isRunningTests {
            restoreSessionFromDisk()
        }
    }

    /// True when this process is a unit-test host. Mirrors the multi-signal
    /// detection in `CatalogStore.isRunningTests` and `ScanJobsStorage`.
    private static var isRunningTests: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestBundlePath"] != nil { return true }
        if env["SWIFT_TESTING_ENABLED"] != nil { return true }
        if Bundle.allBundles.contains(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            return true
        }
        return false
    }

    // MARK: Job management & core scan pipeline
    // referenceCacheIdentifiers / addJob / loadFacesForJob / removeJob /
    // restoreFromCache / startJob / startJobAfterLoad / stopJob /
    // pauseJob / resumeJob / togglePauseJob / startAll / stopAll /
    // pauseAll / resumeAll / resolveOutputDir / filterByPresence /
    // scanAllVideos / processOneVideo / discoverVideos / runScan
    // moved to PersonFinderModel+JobLifecycle.swift (step 6 of 6 — final).

    var hasActiveJobs: Bool { jobs.contains { $0.status == .scanning } }
    var hasPausedJobs: Bool { jobs.contains { $0.status == .paused } }

    // MARK: - Compilation (on-demand)

    @Published var compilationSettings = CompilationSettings.restored() {
        didSet { compilationSettings.save() }
    }

    // MARK: - Compilation lifecycle
    // startCompilation / cancelCompilation / runCompilation /
    // compileAndCleanup moved to PersonFinderCompilation.swift
    // (step 5 of 6 PersonFinderModel split, bundled with the free-func
    // compilation helpers).

    // MARK: Reference loading

    /// Append reference photos from `path` to the existing pool (does not clear previous loads).
    func loadReference(from path: String? = nil) async {
        let p = path ?? settings.referencePath
        guard !p.isEmpty else { referenceLoadError = "No reference path set."; return }

        isLoadingReference = true
        referenceLoadError = nil

        let largestOnly = settings.largestFaceOnly
        let rejected = Set(settings.rejectedReferenceFiles)
        let (faces, failures, errMsg) = await Task.detached(priority: .userInitiated) {
            pfLoadReferencePhotos(from: p, largestFaceOnly: largestOnly)
        }.value

        // Surface load failures (photos that couldn't produce a face)
        let newFailures = rejected.isEmpty
            ? failures
            : failures.filter { !rejected.contains($0.filename) }
        referenceLoadFailures.append(contentsOf: newFailures)

        if let err = errMsg {
            referenceLoadError = err
        } else {
            let filtered = rejected.isEmpty ? faces : faces.filter { !rejected.contains($0.sourceFilename) }
            referenceFaces.append(contentsOf: filtered)
            let label = (p as NSString).lastPathComponent
            if !referenceSources.contains(label) { referenceSources.append(label) }
            // "N previously removed" was noise — rejected photos are a user
            // choice, not an error condition worth surfacing. Only the "no
            // usable face" count matters (that one signals broken photos).
            if !newFailures.isEmpty {
                referenceLoadError = "\(newFailures.count) photo(s) had no usable face"
            }
        }
        isLoadingReference = false
    }

    func removeReferenceFace(id: UUID) {
        if let face = referenceFaces.first(where: { $0.id == id }) {
            settings.rejectedReferenceFiles.append(face.sourceFilename)
            settings.save()
        }
        referenceFaces.removeAll { $0.id == id }
        if referenceFaces.isEmpty { referenceSources = [] }
        syncRejectionsToProfile()
    }

    func removeReferenceFaces(belowConfidence threshold: Float) {
        let rejected = referenceFaces.filter { $0.confidence < threshold }.map(\.sourceFilename)
        settings.rejectedReferenceFiles.append(contentsOf: rejected)
        settings.save()
        referenceFaces.removeAll { $0.confidence < threshold }
        if referenceFaces.isEmpty { referenceSources = [] }
        syncRejectionsToProfile()
    }

    /// Sync the current rejection list back to the active POI profile on disk.
    private func syncRejectionsToProfile() {
        let name = settings.personName
        guard !name.isEmpty,
              var profile = savedProfiles.first(where: { $0.name.lowercased() == name.lowercased() })
        else { return }
        profile.rejectedFiles = settings.rejectedReferenceFiles
        try? profile.save()
        savedProfiles = POIProfile.listAll()
    }

    func clearReference() {
        referenceFaces = []
        referenceSources = []
        referenceLoadError = nil
        referenceLoadFailures = []
        settings.referencePath = ""
        settings.rejectedReferenceFiles = []
        settings.save()
    }

    // MARK: - POI Profile management

    @Published var savedProfiles: [POIProfile] = POIProfile.listAll()

    func saveCurrentPOI() {
        let cover = POIProfile.bestCoverFilename(from: referenceFaces)
        let profile = settings.toProfile(coverImageFilename: cover)
        guard !profile.name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        try? profile.save()
        savedProfiles = POIProfile.listAll()
        referenceLoadError = nil   // clear stale info messages
    }

    func loadPOI(_ profile: POIProfile) async {
        // Clear current reference state
        referenceFaces = []
        referenceSources = []
        referenceLoadError = nil

        // Apply profile to settings
        settings.applyProfile(profile)
        settings.save()

        // Reload reference photos for this person
        if !settings.referencePath.isEmpty {
            await loadReference()
        }
    }

    /// Save an edited profile back to disk and refresh the gallery.
    /// If the name changed, delete the old file first.
    func updateProfile(_ updated: POIProfile, oldName: String? = nil) {
        if let old = oldName, old.lowercased() != updated.name.lowercased() {
            try? POIProfile.delete(name: old)
        }
        try? updated.save()
        savedProfiles = POIProfile.listAll()

        // If the edited person is the currently active one, sync settings
        if settings.personName.lowercased() == (oldName ?? updated.name).lowercased() {
            settings.applyProfile(updated)
            settings.save()
        }
    }

    // MARK: - Undo state for the most recent delete
    //
    // Session-scope only — not persisted. If Rick wants to recover later
    // he can grep ~/dev/VideoScan/.trash/ manually. Only ONE undo target
    // at a time: deleting B clobbers any pending undo for A (A stays in
    // .trash/ but is no longer one-tap recoverable).

    /// Snapshot of the most recent delete. The banner shows
    /// `"Deleted '<name>'. Undo"`; undo moves trashURL back into storeDir.
    /// Swift's `struct` ≈ C `struct` — value type, cheap to copy.
    struct LastDeletedPOI: Equatable {
        let name: String        // original (unsanitized) name for display
        let trashURL: URL       // exact destination returned by trashPOIFolder
        let timestamp: Date     // when the delete happened, for diagnostics
    }

    /// The banner observes this. nil = no banner shown.
    @Published var lastDeletedPOI: LastDeletedPOI?

    /// Non-destructive error from the most recent undo attempt (e.g. the
    /// user re-created the person and we refuse to overwrite). The banner
    /// surfaces this in place of the default "Deleted '<name>'." message
    /// until the user dismisses.
    @Published var lastUndoError: String?

    /// Move a POI's folder (profile.json + reference photos) into the
    /// project-local .trash/. Any in-progress scan job for this person is
    /// stopped first so its background Task doesn't trip over a vanishing
    /// reference folder mid-scan. Returns true on success.
    ///
    /// Per project policy this never `rm -rf`s — the data lands in
    /// `~/dev/VideoScan/.trash/POI-<name>-<UTC>/` and the user can recover
    /// either via the inline undo banner (session-scope) or by moving the
    /// folder back into `storeDir` manually.
    @discardableResult
    func deletePOI(named name: String) async -> Bool {
        // Swift's `lowercased()` ≈ C's tolower() on the whole string.
        let target = name.lowercased()

        // 1. Cancel any in-flight scan job targeting this person, so its
        //    background Task can't observe a half-vanished folder. We only
        //    stop active jobs; idle/done ones are left untouched.
        for job in jobs where job.assignedProfile?.name.lowercased() == target {
            if job.status.isActive {
                stopJob(job)
            }
        }

        // 2. Move folder to .trash/. Logs to osLog on failure so the agent
        //    watching the remote stream can see why.
        guard let dest = POIStorage.trashPOIFolder(named: name) else {
            osLog.error("deletePOI: failed to move POI \(name, privacy: .public) to .trash/")
            return false
        }
        osLog.info("deletePOI: moved \(name, privacy: .public) → \(dest.path, privacy: .public)")

        // 3. Refresh in-memory gallery. Clear active selection / loaded
        //    reference faces if this was the person being inspected, so the
        //    UI doesn't keep showing photos for a person who's now gone.
        savedProfiles = POIProfile.listAll()
        if settings.personName.lowercased() == target {
            referenceFaces = []
            referenceSources = []
            referenceLoadFailures = []
            settings.referencePath = ""
            settings.rejectedReferenceFiles = []
            settings.save()
        }
        if selectedPersonForNewJobs?.name.lowercased() == target {
            selectedPersonForNewJobs = nil
        }

        // 4. Arm the undo banner. Supersedes any previous pending undo
        //    by design — only one undo target at a time. The previous
        //    target's folder stays in .trash/ but is no longer one-tap
        //    recoverable (matches the spec; manual recovery still works).
        lastDeletedPOI = LastDeletedPOI(name: name, trashURL: dest, timestamp: Date())
        lastUndoError = nil
        return true
    }

    /// Restore the most recently deleted POI. Returns true on success.
    /// Refuses to overwrite a re-created folder — surfaces an error message
    /// in `lastUndoError` instead. Clears `lastDeletedPOI` on success or
    /// when the trash entry vanished (nothing to undo); leaves it set on a
    /// recoverable error so the user can retry after resolving the conflict.
    @discardableResult
    func undoLastDelete() async -> Bool {
        guard let snap = lastDeletedPOI else { return false }
        let result = POIStorage.restorePOIFolder(from: snap.trashURL, named: snap.name)
        switch result {
        case .restored(let dest):
            osLog.info("undoLastDelete: restored \(snap.name, privacy: .public) ← \(dest.path, privacy: .public)")
            savedProfiles = POIProfile.listAll()
            lastDeletedPOI = nil
            lastUndoError = nil
            return true
        case .destinationExists:
            // Non-destructive abort. Leave snap in place so the banner
            // stays up (user can dismiss it manually after they resolve
            // the conflict, e.g. by renaming the new one).
            osLog.error("undoLastDelete: refused — '\(snap.name, privacy: .public)' already exists in storeDir")
            lastUndoError = "Can't undo — '\(snap.name)' was re-created"
            return false
        case .sourceMissing:
            // The trash entry vanished (user emptied .trash/ manually).
            // Nothing to undo — drop the banner.
            osLog.error("undoLastDelete: trash entry missing for \(snap.name, privacy: .public)")
            lastDeletedPOI = nil
            lastUndoError = nil
            return false
        case .ioError:
            osLog.error("undoLastDelete: IO error restoring \(snap.name, privacy: .public)")
            lastUndoError = "Can't undo — file system error moving '\(snap.name)' back"
            return false
        }
    }

    /// Dismiss the undo banner without restoring. The trashed folder
    /// stays in `.trash/` — it's only the one-tap undo affordance that
    /// goes away.
    func dismissUndoBanner() {
        lastDeletedPOI = nil
        lastUndoError = nil
    }

    /// Legacy synchronous shim. Existing call sites use the profile form;
    /// keep them working while the async form is the canonical API. Fire-
    /// and-forget Task — UI updates flow through @Published savedProfiles.
    func deletePOI(_ profile: POIProfile) {
        Task { @MainActor in
            _ = await deletePOI(named: profile.name)
        }
    }

    func reorderProfiles(fromID: String, toID: String) {
        guard fromID != toID,
              let fromIdx = savedProfiles.firstIndex(where: { $0.id == fromID }),
              let toIdx = savedProfiles.firstIndex(where: { $0.id == toID })
        else { return }
        let moving = savedProfiles.remove(at: fromIdx)
        savedProfiles.insert(moving, at: toIdx)
        for i in savedProfiles.indices {
            savedProfiles[i].sortOrder = i
            try? savedProfiles[i].save()
        }
    }

    // MARK: Core scan (nonisolated — runs on cooperative thread pool, NOT on MainActor)
    // Moved to PersonFinderModel+JobLifecycle.swift (step 6 of 6 — final).
    // Methods relocated: resolveOutputDir, filterByPresence, scanAllVideos,
    // processOneVideo, discoverVideos, runScan. The `pfScanLog` private Logger
    // travelled with them (only used inside runScan).
}

// MARK: - Catalog skip set, person-scan prefilter, video discovery
// Moved to PersonFinderCatalogFilter.swift (step 2 of 6 PersonFinderModel split).

// MARK: - Vision detection pipeline
// Moved to PersonFinderDetection.swift (step 3 of 6 PersonFinderModel split).
// Symbols relocated: pfCIContext, pfLoadReferencePhotos, pfNormalizeFaceCrop,
// pfGenerateFeaturePrint, pfOrientationFromTransform, pfDetectFacesInBuffer,
// pfOrientedCGImage, PFVisionReaderContext, pfOpenVisionVideoReader,
// PFVisionFrameMatch, pfVisionMatchCandidates, pfVisionClusterSegments,
// pfLogMilestones, pfProcessVideo. Dead helper pfDetectFaces(in:) removed.

// MARK: - dlib/Python video processing
// Moved to PersonFinderEngineDispatch.swift (step 4 of 6 PersonFinderModel split).
// Symbols relocated: DlibSegmentJSON, DlibResultJSON, pfDecodeDlibResult,
// pfProcessVideoWithDlib. pfProcessVideoWithDlib widened private → internal
// because its caller PersonFinderModel.runDlib() remains here until step 6.

// MARK: - Clip extraction / compatibility bucketing / compilation
// Moved to PersonFinderCompilation.swift (step 5 of 6 PersonFinderModel
// split, bundled). Symbols relocated:
//   • free funcs/types: pfExtractAllClips, pfExtractClip,
//     pfBuildSortedClipEntries, CompatKey, pfBucket, pfBucketByCompat,
//     pfCompileBuckets, pfStreamCopyConcat, pfMergeBucketsToSingleFile,
//     pfRunFFmpeg, pfStderrBox, pfFileSize, pfExtractYear, pfDecadeLabel,
//     pfClipEntry, pfProbeCompatKey
//   • PersonFinderModel methods (now in `extension PersonFinderModel`):
//     startCompilation, cancelCompilation, runCompilation, compileAndCleanup
// Widenings applied (private → internal): pfBuildSortedClipEntries,
// pfExtractYear, pfClipEntry — to enable PersonFinderBoundaryTests
// coverage of sort/year-extraction contracts.

// MARK: - Job management & core scan pipeline
// Moved to PersonFinderModel+JobLifecycle.swift (step 6 of 6 — final).
// Symbols relocated as `extension PersonFinderModel`:
//   • Job management: addJob, loadFacesForJob, removeJob, restoreFromCache
//   • Per-job lifecycle: startJob, startJobAfterLoad, stopJob, pauseJob,
//     resumeJob, togglePauseJob
//   • Bulk lifecycle: startAll, stopAll, pauseAll, resumeAll
//   • Core scan pipeline (nonisolated statics): resolveOutputDir,
//     filterByPresence, scanAllVideos, processOneVideo, discoverVideos,
//     runScan
//   • Private helpers: referenceCacheIdentifiers (static), pfScanLog (Logger)
// Four ScanJob widenings (all fileprivate → internal): scanTask, timerTask,
// startElapsedTimer(), stopElapsedTimer() — see comment near ScanJob.
// Deferred: dispatchEngine() extraction from processOneVideo's inline switch.

// MARK: - Utilities
// pfSanitize / pfFormatDuration / pfFormatBytes moved to PersonFinderCatalogFilter.swift
// (step 2 of 6 PersonFinderModel split).

// MARK: - ArcFace engine dispatch
// pfRunArcFaceEngine moved to PersonFinderEngineDispatch.swift
// (step 4 of 6 PersonFinderModel split).
