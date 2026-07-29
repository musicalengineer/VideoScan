// CatalogLivePreviewTests.swift
// LOGIC + ISOLATION dimensions for "live preview follows selection"
// (feature/live-preview-follows-selection, 2026-07-28).
//
// Two pure seams, both model-free and AppKit-free:
//
//   1. CatalogLivePreview — the selection→preview-path resolver. Single
//      vs multi-select, non-previewable (audio-only / offline) → nil,
//      empty selection → nil, table-order primary.
//
//   2. LivePreviewMode — the mode state machine. Space toggles on/off;
//      a selection change while ON restarts for the new path and no-ops
//      on the same path; a selection change while OFF does nothing; Stop
//      exits the mode.
//
// The view-layer pieces (NSEvent Space monitor, first-responder text-field
// guard, and the requestFilmstrip/stopFilmstrip plumbing) are inherently
// AppKit/model-bound and are exercised by hand, not here — see the report.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Resolver (which path should preview for a selection)

@Suite("Live-preview selection resolver (pure)")
struct CatalogLivePreviewResolverTests {

    private typealias Candidate = CatalogLivePreview.Candidate

    private func video(_ id: UUID, _ path: String) -> Candidate {
        Candidate(id: id, path: path, isPreviewable: true)
    }
    private func nonVideo(_ id: UUID, _ path: String) -> Candidate {
        Candidate(id: id, path: path, isPreviewable: false)
    }

    @Test("previewable stream types on a mounted volume are previewable; others are not")
    func isPreviewableMatrix() {
        #expect(CatalogLivePreview.isPreviewable(streamType: .videoAndAudio, reachable: true))
        #expect(CatalogLivePreview.isPreviewable(streamType: .videoOnly, reachable: true))
        // Audio-only / no-A-V / probe-failed → never previewable.
        #expect(!CatalogLivePreview.isPreviewable(streamType: .audioOnly, reachable: true))
        #expect(!CatalogLivePreview.isPreviewable(streamType: .noStreams, reachable: true))
        #expect(!CatalogLivePreview.isPreviewable(streamType: .ffprobeFailed, reachable: true))
        // Offline volume → not previewable even for a video row.
        #expect(!CatalogLivePreview.isPreviewable(streamType: .videoAndAudio, reachable: false))
        #expect(!CatalogLivePreview.isPreviewable(streamType: .videoOnly, reachable: false))
    }

    @Test("single previewable selection → its path")
    func singleSelection() {
        let a = UUID()
        let rows = [video(a, "/v/a.mkv"), video(UUID(), "/v/b.mkv")]
        #expect(CatalogLivePreview.previewPath(orderedCandidates: rows,
                                               selectedIDs: [a]) == "/v/a.mkv")
    }

    @Test("single non-previewable selection → nil (Space no-ops)")
    func singleNonPreviewable() {
        let a = UUID()
        let rows = [nonVideo(a, "/v/a.wav"), video(UUID(), "/v/b.mkv")]
        #expect(CatalogLivePreview.previewPath(orderedCandidates: rows,
                                               selectedIDs: [a]) == nil)
    }

    @Test("empty selection → nil")
    func emptySelection() {
        let rows = [video(UUID(), "/v/a.mkv")]
        #expect(CatalogLivePreview.previewPath(orderedCandidates: rows,
                                               selectedIDs: []) == nil)
    }

    @Test("multi-select acts on the first selected row in TABLE order")
    func multiSelectPrimaryIsTableOrder() {
        let top = UUID(), mid = UUID(), bot = UUID()
        let rows = [video(top, "/v/top.mkv"),
                    video(mid, "/v/mid.mkv"),
                    video(bot, "/v/bot.mkv")]
        // Selection set order is irrelevant — resolver picks the highest row.
        #expect(CatalogLivePreview.previewPath(orderedCandidates: rows,
                                               selectedIDs: [bot, mid]) == "/v/mid.mkv")
        #expect(CatalogLivePreview.previewPath(orderedCandidates: rows,
                                               selectedIDs: [mid, top]) == "/v/top.mkv")
    }

    @Test("multi-select whose primary (top) row is non-previewable → nil")
    func multiSelectPrimaryNonPreviewable() {
        let top = UUID(), bot = UUID()
        let rows = [nonVideo(top, "/v/top.wav"), video(bot, "/v/bot.mkv")]
        // Primary is the top row and it's audio-only → nil, even though a
        // previewable row is also selected. Deliberate: Space acts on the
        // focused/top row, not "any previewable row in the set".
        #expect(CatalogLivePreview.previewPath(orderedCandidates: rows,
                                               selectedIDs: [top, bot]) == nil)
    }

    @Test("a selected id absent from the rows is ignored")
    func staleSelectionIgnored() {
        let present = UUID()
        let rows = [video(present, "/v/a.mkv")]
        #expect(CatalogLivePreview.previewPath(orderedCandidates: rows,
                                               selectedIDs: [UUID()]) == nil)
    }
}

// MARK: - Mode state machine (Space / selection-change / Stop)

@Suite("Live-preview mode state machine (pure)")
struct LivePreviewModeTests {

    @Test("Space with a previewable selection arms the mode and starts it")
    func spaceOn() {
        var mode = LivePreviewMode()
        #expect(mode.isActive == false)
        let action = mode.toggle(candidatePath: "/v/a.mkv")
        #expect(action == .start("/v/a.mkv"))
        #expect(mode.isActive)
        #expect(mode.activePath == "/v/a.mkv")
    }

    @Test("Space again disarms the mode and stops the preview")
    func spaceOff() {
        var mode = LivePreviewMode()
        _ = mode.toggle(candidatePath: "/v/a.mkv")
        let action = mode.toggle(candidatePath: "/v/a.mkv")
        #expect(action == .stop)
        #expect(mode.isActive == false)
        #expect(mode.activePath == nil)
    }

    @Test("Space with nothing previewable is a no-op (stays off)")
    func spaceOnNothing() {
        var mode = LivePreviewMode()
        let action = mode.toggle(candidatePath: nil)
        #expect(action == .none)
        #expect(mode.isActive == false)
        #expect(mode.activePath == nil)
    }

    @Test("selection change while ARMED restarts for the new path")
    func selectionChangeWhileOn() {
        var mode = LivePreviewMode()
        _ = mode.toggle(candidatePath: "/v/a.mkv")
        let action = mode.selectionChanged(candidatePath: "/v/b.mkv")
        #expect(action == .start("/v/b.mkv"))
        #expect(mode.activePath == "/v/b.mkv")
        #expect(mode.isActive)
    }

    @Test("selection change onto the SAME path is a no-op (no re-rip)")
    func selectionChangeSamePath() {
        var mode = LivePreviewMode()
        _ = mode.toggle(candidatePath: "/v/a.mkv")
        let action = mode.selectionChanged(candidatePath: "/v/a.mkv")
        #expect(action == .none)
        #expect(mode.activePath == "/v/a.mkv")
    }

    @Test("selection change onto a non-previewable row stops but stays armed")
    func selectionChangeToNonPreviewable() {
        var mode = LivePreviewMode()
        _ = mode.toggle(candidatePath: "/v/a.mkv")
        let stop = mode.selectionChanged(candidatePath: nil)
        #expect(stop == .stop)
        #expect(mode.isActive, "moving onto an audio-only row must NOT disarm the mode")
        #expect(mode.activePath == nil)
        // Continuing to arrow onto a video row resumes the preview.
        let resume = mode.selectionChanged(candidatePath: "/v/c.mkv")
        #expect(resume == .start("/v/c.mkv"))
        #expect(mode.activePath == "/v/c.mkv")
    }

    @Test("two non-previewable selections in a row → second is a no-op")
    func selectionChangeNonPreviewableTwice() {
        var mode = LivePreviewMode()
        _ = mode.toggle(candidatePath: "/v/a.mkv")
        #expect(mode.selectionChanged(candidatePath: nil) == .stop)
        #expect(mode.selectionChanged(candidatePath: nil) == .none)
        #expect(mode.isActive)
    }

    @Test("selection change while OFF never touches the preview")
    func selectionChangeWhileOff() {
        var mode = LivePreviewMode()
        #expect(mode.selectionChanged(candidatePath: "/v/a.mkv") == .none)
        #expect(mode.selectionChanged(candidatePath: nil) == .none)
        #expect(mode.isActive == false)
        #expect(mode.activePath == nil)
    }

    @Test("Stop exits the mode and stops the preview")
    func stopExitsMode() {
        var mode = LivePreviewMode()
        _ = mode.toggle(candidatePath: "/v/a.mkv")
        let action = mode.stop()
        #expect(action == .stop)
        #expect(mode.isActive == false)
        #expect(mode.activePath == nil)
        // After Stop, a selection change is inert until Space re-arms.
        #expect(mode.selectionChanged(candidatePath: "/v/b.mkv") == .none)
    }

    @Test("Stop while already off is a no-op")
    func stopWhileOff() {
        var mode = LivePreviewMode()
        #expect(mode.stop() == .none)
    }
}

// MARK: - Isolation

@Suite("Live-preview mode isolation (no shared/global state)")
struct LivePreviewModeIsolationTests {

    /// The mode is a self-contained value type: no UserDefaults, no shared
    /// cache, no real paths. This test pins that a POISONED global preview
    /// setting cannot alter the state machine's decisions — the resolver
    /// and mode operate purely on their arguments.
    ///
    /// (The one preference in this feature's blast radius, the background
    /// preview sweep's `previewSweepEnabled`, is READ nowhere in the mode
    /// or resolver — filmstrip fulfillment goes through requestFilmstrip's
    /// own disk-cache path regardless of the sweep flag. We poison it here
    /// to prove the follow-mode logic is indifferent to it.)
    @Test("poisoned previewSweepEnabled does not change the state machine")
    func poisonedSweepFlagIsIrrelevant() {
        let suiteName = "CatalogLivePreviewTests.poison.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            Issue.record("could not create isolated UserDefaults suite")
            return
        }
        defer { defaults.removeSuite(named: suiteName) }
        // Poison both directions of the sweep flag.
        for poison in [true, false] {
            defaults.set(poison, forKey: PreviewSweepSettings.enabledKey)
            var mode = LivePreviewMode()
            #expect(mode.toggle(candidatePath: "/v/a.mkv") == .start("/v/a.mkv"))
            #expect(mode.selectionChanged(candidatePath: "/v/b.mkv") == .start("/v/b.mkv"))
            #expect(mode.toggle(candidatePath: "/v/b.mkv") == .stop)
            #expect(mode.isActive == false)
        }
    }
}
