import Testing
import SwiftUI
import VideoScanCore
@testable import VideoScan

// GH #273 sensor (2026-10-05): the Archive card menu now carries "Make a
// Copy / People tab ▸" (with ShowInPeopleTabMenu). An earlier build of that
// menu crashed the app at launch on the Archive Timeline; a clean build did
// not reproduce it. This mounts the REAL ArchiveView over a sandboxed Master
// Archive with promoted videos and lays it out, every test run, so a real
// code defect here fails a test instead of a launch.
@Suite("Archive Timeline — card menus lay out (#273)", .serialized)
@MainActor
struct ArchiveTimelineMenuLayoutTests {
    @Test func archiveViewLaysOutWithTheFollowUpMenus() async throws {
        let sb = try MasterArchiveTestSupport.makeSandbox("menu273")
        defer { sb.cleanup() }
        let model = MasterArchiveTestSupport.makeModel(sb)
        try MasterArchiveTestSupport.initialize(model, in: sb)
        var ids: [UUID] = []
        for i in 0..<3 {
            let url = sb.sources.appendingPathComponent("Menu\(i).mov")
            _ = try MasterArchiveTestSupport.writeBlob(at: url, bytes: 4096, seed: UInt64(i + 1))
            let rec = MasterArchiveTestSupport.makeRecord(path: url.path, userDate: "199\(i)")
            model.records.append(rec)
            ids.append(rec.id)
        }
        // N1008-T-Archive-F9: the promote result is REQUIRED. If it failed
        // there would be no archived cards, the card menu (and its
        // archived-only "Make a Copy" branch) would never be built, and the
        // layout below would test nothing.
        let job = try #require(await MasterArchiveTestSupport.promote(model, ids: ids))
        guard case .finished = job.state else { Issue.record("promote did not finish: \(job.state)"); return }
        #expect(model.records.filter { model.isArchiveCopy($0) }.count == 3,
                "the Timeline needs 3 archived cards to lay out their menus")
        let host = NSHostingView(rootView: ArchiveView()
            .environmentObject(model)
            .environmentObject(MediaFileOperationsCenter()))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        // A crash sensor by design (#273): reaching here is the pass. The
        // cards must still be there after layout (the view did not drop them).
        #expect(model.records.filter { model.isArchiveCopy($0) }.count == 3)
    }
}
