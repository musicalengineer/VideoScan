import Testing
import Foundation
@testable import VideoScan

@Suite("Archivist portrait loops — discovery beside the still")
struct ArchivistPortraitLoopsTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("portrait-loops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    @Test func noClipsMeansStillPortrait() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let still = d.appendingPathComponent("hallie.jpeg")
        try Data([0xFF, 0xD8]).write(to: still)
        let loops = ArchivistPortraitLoops.discover(besideImageAt: still.path)
        #expect(!loops.hasVideo)
    }

    @Test func idleListeningThinkingAreFoundByStemAndFallBackToIdle() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        let still = d.appendingPathComponent("hallie.jpeg")
        try Data([0xFF, 0xD8]).write(to: still)
        try Data().write(to: d.appendingPathComponent("hallie-idle.mp4"))
        try Data().write(to: d.appendingPathComponent("hallie-thinking.mov"))
        try Data().write(to: d.appendingPathComponent("other-listening.mp4"))   // different stem: ignored
        let loops = ArchivistPortraitLoops.discover(besideImageAt: still.path)
        #expect(loops.hasVideo)
        #expect(loops.idle?.lastPathComponent == "hallie-idle.mp4")
        #expect(loops.thinking?.lastPathComponent == "hallie-thinking.mov")
        #expect(loops.listening == nil, "listening falls back to idle at play time")
    }
}
