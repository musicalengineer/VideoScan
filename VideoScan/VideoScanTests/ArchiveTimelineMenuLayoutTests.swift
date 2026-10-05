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
        _ = await MasterArchiveTestSupport.promote(model, ids: ids)
        let host = NSHostingView(rootView: ArchiveView()
            .environmentObject(model)
            .environmentObject(MediaFileOperationsCenter()))
        host.frame = NSRect(x: 0, y: 0, width: 1400, height: 900)
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(150))
        }
        #expect(host.fittingSize.width >= 0)
    }
}
