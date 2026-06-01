import Testing
import Foundation
@testable import VideoScan

// MARK: - VolumesPendingSelectionTests
//
// Sanity coverage for `VideoScanModel.pendingVolumesSelectionID` — the
// @Published UUID slot that the Catalog tab's double-click handler writes
// to before calling openWindow(id: "volumes"). VolumesWindow reads this on
// appear (and via .onChange) to focus the right target.
//
// This is the wiring the Catalog volume-table double-click depends on.
// See ContentView.swift > openVolumesEditor(for:) and
// VolumesWindow.swift > honorPendingSelection().
//
// Hermetic — no filesystem, no UI.

@Suite(.serialized) @MainActor
struct VolumesPendingSelectionTests {

    @Test("pendingVolumesSelectionID starts nil")
    func defaultIsNil() {
        let model = VideoScanModel()
        #expect(model.pendingVolumesSelectionID == nil)
    }

    @Test("pendingVolumesSelectionID round-trips an arbitrary UUID")
    func roundTripUUID() {
        let model = VideoScanModel()
        let id = UUID()
        model.pendingVolumesSelectionID = id
        #expect(model.pendingVolumesSelectionID == id)
    }

    @Test("pendingVolumesSelectionID can be cleared back to nil")
    // VolumesWindow.honorPendingSelection() clears the slot after consuming
    // it — make sure assigning nil after a real UUID actually clears.
    func canBeCleared() {
        let model = VideoScanModel()
        model.pendingVolumesSelectionID = UUID()
        model.pendingVolumesSelectionID = nil
        #expect(model.pendingVolumesSelectionID == nil)
    }

    @Test("pendingVolumesSelectionID accepts overwrite to a different UUID")
    // Two consecutive double-clicks on different rows must end up with
    // the most recent selection — there is no merging or queuing.
    func overwriteReplaces() {
        let model = VideoScanModel()
        let first = UUID()
        let second = UUID()
        model.pendingVolumesSelectionID = first
        model.pendingVolumesSelectionID = second
        #expect(model.pendingVolumesSelectionID == second)
        #expect(model.pendingVolumesSelectionID != first)
    }
}
