// PreviewServiceForwarderTests.swift
// GH #337 slice 1: the preview pane's state moved off VideoScanModel into
// PreviewService (an @Observable @MainActor store); the model keeps
// computed forwarders. These tests pin what the move must NOT change:
//
//   - every formerly-@Published property still fires the MODEL's
//     objectWillChange, whether written through the forwarder or by the
//     service's own logic (clearPreview, stopFilmstrip, …) — so the 73
//     views and the Combine observers of the model refresh as before;
//   - SwiftUI's observation also sees those reads (a mounted view that
//     observes the model re-renders on a service-internal change);
//   - the forwarders read and write the service's storage (one source of
//     truth, no shadow copy left on the model);
//   - the owner hooks are wired from the model's init (records for the
//     sweep, the MissingDependency alert);
//   - formerly plain vars stay silent (no new invalidations);
//   - no retain cycle: the model and its service are both released.

import AppKit
import Combine
import Foundation
import Observation
import SwiftUI
import Testing
@testable import VideoScan

@Suite("PreviewService forwarders keep the model's observation contract (#337 slice 1)")
@MainActor
struct PreviewServiceForwarderTests {

    private static func image() -> NSImage {
        NSImage(cgImage: PreviewTestImages.twoTone(), size: NSSize(width: 64, height: 64))
    }

    private static func ready(_ path: String) -> PreviewFilmstripState {
        .ready(path: path, frames: [PreviewFilmstrip.Frame(offsetSeconds: 0.5,
                                                           image: PreviewTestImages.twoTone())])
    }

    /// Count the model's objectWillChange sends across `body`.
    private func sends(on model: VideoScanModel, _ body: () -> Void) -> Int {
        var n = 0
        let token = model.objectWillChange.sink { n += 1 }
        body()
        token.cancel()
        return n
    }

    // MARK: objectWillChange — one per write, exactly like @Published

    @Test("each moved property written through the forwarder fires model.objectWillChange once")
    func forwarderWritesFireTheModel() {
        let model = VideoScanModel()
        #expect(sends(on: model) { model.previewImage = Self.image() } == 1)
        #expect(sends(on: model) { model.previewFilename = "a.mkv" } == 1)
        #expect(sends(on: model) { model.previewOfflineVolumeName = "Gone" } == 1)
        #expect(sends(on: model) { model.previewUnavailable = true } == 1)
        #expect(sends(on: model) { model.filmstripState = Self.ready("/v/a.mkv") } == 1)
        #expect(sends(on: model) { model.previewSweepSettings.enabled = true } == 1)
        // Same value again: @Published announced it anyway; so does the bridge.
        #expect(sends(on: model) { model.previewUnavailable = true } == 1)
    }

    @Test("writes made by the service's own logic fire model.objectWillChange")
    func serviceInternalWritesFireTheModel() {
        let model = VideoScanModel()
        model.filmstripState = Self.ready("/v/a.mkv")
        #expect(sends(on: model) { model.previewService.stopFilmstrip() } == 1)
        guard case .idle = model.filmstripState else {
            Issue.record("stopFilmstrip left \(model.filmstripState)")
            return
        }
        model.previewImage = Self.image()
        model.previewFilename = "a.mkv"
        // clearPreview writes previewImage, previewFilename,
        // previewOfflineVolumeName and previewUnavailable — four sends,
        // exactly as four @Published writes did.
        #expect(sends(on: model) { model.previewService.clearPreview() } == 4)
        #expect(model.previewImage == nil)
        #expect(model.previewFilename.isEmpty)
    }

    @Test("formerly plain vars stay silent (no new invalidations)")
    func bookkeepingIsSilent() {
        let model = VideoScanModel()
        let n = sends(on: model) {
            model.previewRequestPath = "/v/a.mkv"
            model.filmstripTaskPath = "/v/a.mkv"
            model.filmstripTaskIsInteractive = true
            model.filmstripLatestProgress = (1, 2)
            model.filmstripRunID = UUID()
            model.filmstripFailedPaths.insert("/v/a.mkv")
        }
        #expect(n == 0)
    }

    // MARK: SwiftUI observation

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test("observation of a model forwarder fires on a service-internal change")
    func trackingThroughTheForwarder() {
        let model = VideoScanModel()
        let flag = Flag()
        withObservationTracking { _ = model.filmstripState } onChange: { flag.set() }
        model.filmstripState = Self.ready("/v/a.mkv")
        #expect(flag.isSet)

        let flag2 = Flag()
        withObservationTracking { _ = model.previewUnavailable } onChange: { flag2.set() }
        model.previewService.previewUnavailable = true
        #expect(flag2.isSet)
    }

    /// Mirrors the production shape: a view holding the model as an
    /// environment object and reading a preview property in its body.
    private struct PaneProbe: View {
        @EnvironmentObject var model: VideoScanModel
        let seen: (Bool) -> Void
        var body: some View {
            seen(model.previewUnavailable)
            return Text(model.previewUnavailable ? "NO PREVIEW" : "preview")
        }
    }

    private final class Seen {
        var last: Bool?
        var count = 0
    }

    private static func pump(_ seconds: TimeInterval) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    }

    @Test("a mounted view observing the model re-renders when the service changes state")
    func mountedViewRefreshes() {
        let model = VideoScanModel()
        let seen = Seen()
        let host = NSHostingView(rootView: PaneProbe(seen: { seen.last = $0; seen.count += 1 })
            .environmentObject(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.orderOut(nil)
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        Self.pump(0.2)
        #expect(seen.last == false, "the probe never rendered")

        // A write made by the service's own logic, not via the forwarder.
        model.previewService.previewUnavailable = true
        let end = Date().addingTimeInterval(3)
        while seen.last != true, Date() < end { Self.pump(0.05) }
        #expect(seen.last == true, "the view did not refresh on a PreviewService change")
    }

    // MARK: One source of truth

    @Test("forwarders read and write the service's storage")
    func forwardersShareStorage() {
        let model = VideoScanModel()
        let svc = model.previewService
        model.previewFilename = "x.mov"
        #expect(svc.previewFilename == "x.mov")
        svc.previewOfflineVolumeName = "Offline Drive"
        #expect(model.previewOfflineVolumeName == "Offline Drive")
        model.previewRequestPath = "/v/x.mov"
        #expect(svc.previewRequestPath == "/v/x.mov")
        #expect(model.thumbnailCache === svc.thumbnailCache)
        #expect(model.thumbnailFailureStore === svc.thumbnailFailureStore)
        #expect(model.previewDiskCache === svc.previewDiskCache)
        #expect(model.previewSweep === svc.previewSweep)
        #expect(model.thumbnailPrecacher === svc.thumbnailPrecacher)
        #expect(model.thumbnailCache.totalCostLimit == ThumbnailCachePolicy.costLimitBytes)
    }

    @Test("invalidateThumbnailCacheEntry drops the entry from the shared cache")
    func invalidateGoesToTheService() {
        let model = VideoScanModel()
        model.storePrecachedThumbnail(PreviewTestImages.twoTone(), forPath: "/v/a.mov")
        #expect(model.previewService.thumbnailCache.object(forKey: "/v/a.mov") != nil)
        model.invalidateThumbnailCacheEntry(forPath: "/v/a.mov")
        #expect(model.previewService.thumbnailCache.object(forKey: "/v/a.mov") == nil)
    }

    // MARK: Owner hooks wired in init

    @Test("the sweep's candidate list reads the model's records through the host hook")
    func sweepCandidatesComeFromModelRecords() throws {
        let model = VideoScanModel()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewServiceForwarder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func record(_ name: String, _ type: StreamType) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = dir.appendingPathComponent(name).path
            r.filename = name
            r.streamTypeRaw = type.rawValue
            r.durationSeconds = 4
            return r
        }
        model.records = [record("a.mov", .videoAndAudio), record("b.wav", .audioOnly),
                         record("c.mov", .videoOnly)]
        let paths = model.previewService.previewSweepCandidates().map(\.path)
        #expect(paths == [model.records[0].fullPath, model.records[2].fullPath])
    }

    @Test("a missing tool raises the MODEL's alert through the host hook")
    func missingDependencyReachesTheModel() {
        let model = VideoScanModel()
        let missing = MissingDependency(displayName: "ffmpeg", context: "play filmstrip preview",
                                        installHint: "brew install ffmpeg", searchedPaths: ["/simulated"])
        let r = VideoRecord()
        r.fullPath = "/v/a.mkv"
        r.container = "Matroska / WebM"
        r.videoCodec = "ffv1"
        r.durationSeconds = 8
        model.previewService.requestFilmstrip(for: r, dependencyCheck: { missing })
        #expect(model.missingDependency == missing)
    }

    @Test("static forwarders hand back the renderer's constants")
    func staticForwarders() {
        #expect(VideoScanModel.avfPreviewDeadlineSeconds == PreviewFrameRenderer.avfPreviewDeadlineSeconds)
        #expect(VideoScanModel.ffmpegPreviewDeadlineSeconds == PreviewFrameRenderer.ffmpegPreviewDeadlineSeconds)
        #expect(VideoScanModel.avfPreviewDeadlineSeconds == 8)
        #expect(VideoScanModel.ffmpegPreviewDeadlineSeconds == 15)
        #expect(VideoScanModel.dedupedCandidateTimes(offsets: [1, 1, 2]).count == 2)
    }

    // MARK: Lifetime

    @Test("no retain cycle: the model and its PreviewService are both released", .timeLimit(.minutes(1)))
    func modelAndServiceAreReleased() async throws {
        weak var weakModel: VideoScanModel?
        weak var weakService: PreviewService?
        do {
            let model = VideoScanModel()
            weakModel = model
            weakService = model.previewService
            model.previewImage = Self.image()
        }
        let deadline = ContinuousClock.now + .seconds(20)
        while weakModel != nil || weakService != nil, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(weakModel == nil, "the model was never released")
        #expect(weakService == nil, "PreviewService outlived its model — a host hook holds it")
    }
}
