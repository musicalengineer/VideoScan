import Testing
import Foundation
@testable import VideoScan

// Rick 2026-08-18: Hallie Mae's slow walk through four angle stills.
// Two halves: (1) discovering the frames beside the chosen portrait,
// (2) the pure cycle math (which frame, how faded, when she holds).

@Suite("Archivist angle frames — discovery beside the portrait")
struct ArchivistAngleFrameDiscoveryTests {
    private func tmp() throws -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("angle-frames-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func touch(_ dir: URL, _ name: String) throws {
        try Data([0x89, 0x50]).write(to: dir.appendingPathComponent(name))
    }

    @Test func contiguousAnglesBesideStemAreFoundInOrder() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "hallie.png")
        for n in 1...4 { try touch(d, "hallie-angle\(n).png") }
        try touch(d, "other-angle1.png")     // different stem: ignored
        let urls = ArchivistChatWindow.angleFrameURLs(besideImageAt: d.appendingPathComponent("hallie.png").path)
        #expect(urls.map(\.lastPathComponent) == ["hallie-angle1.png", "hallie-angle2.png", "hallie-angle3.png", "hallie-angle4.png"])
    }

    @Test func discoveryStopsAtTheFirstGap() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "hallie.png")
        try touch(d, "hallie-angle1.png")
        try touch(d, "hallie-angle2.png")
        try touch(d, "hallie-angle4.png")   // 3 missing → 4 never reached
        let urls = ArchivistChatWindow.angleFrameURLs(besideImageAt: d.appendingPathComponent("hallie.png").path)
        #expect(urls.map(\.lastPathComponent) == ["hallie-angle1.png", "hallie-angle2.png"])
    }

    @Test func aLoneAngleIsNotACycle() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "hallie.png")
        try touch(d, "hallie-angle1.png")
        #expect(ArchivistChatWindow.angleFrameURLs(besideImageAt: d.appendingPathComponent("hallie.png").path).isEmpty)
    }

    @Test func portraitWhoseOwnStemIsFrameOneCollectsItsSiblings() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        for n in 1...4 { try touch(d, "HallieMaeAngles-\(n).png") }
        try touch(d, "HallieMaeAngles-5.jpeg")   // wrong extension: not part of the set
        let urls = ArchivistChatWindow.angleFrameURLs(besideImageAt: d.appendingPathComponent("HallieMaeAngles-1.png").path)
        #expect(urls.map(\.lastPathComponent) == (1...4).map { "HallieMaeAngles-\($0).png" })
    }

    @Test func aPortraitNumberedOtherThanOneIsJustAPortrait() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        for n in 1...4 { try touch(d, "HallieMaeAngles-\(n).png") }
        // Picking frame 2 as the portrait: not the head of a set, and there
        // is no "HallieMaeAngles-2-angle1.png" → no cycle.
        #expect(ArchivistChatWindow.angleFrameURLs(besideImageAt: d.appendingPathComponent("HallieMaeAngles-2.png").path).isEmpty)
    }

    @Test func nothingBesideThePortraitMeansEmpty() throws {
        let d = try tmp(); defer { try? FileManager.default.removeItem(at: d) }
        try touch(d, "hallie.png")
        #expect(ArchivistChatWindow.angleFrameURLs(besideImageAt: d.appendingPathComponent("hallie.png").path).isEmpty)
        #expect(ArchivistChatWindow.angleFrameURLs(besideImageAt: d.appendingPathComponent("missing.png").path).isEmpty)
    }
}

@Suite("Archivist angle cycle — pure motion math")
struct ArchivistAngleCycleTests {
    // Four frames, front = index 2 (HallieMaeAngles-3), defaults otherwise.
    let cycle = ArchivistAngleCycle(frameCount: 4, frontFrameIndex: 2)
    let origin: TimeInterval = 1_000

    @Test func startsOnTheFrontFrameWithNoFade() {
        let s = cycle.sample(at: origin, origin: origin, holdSince: nil)
        #expect(s.visibleIndex == 2)
        #expect(s.alpha == 1)
        #expect(s.top.scale == 1.0)
        let later = cycle.sample(at: origin + 5, origin: origin, holdSince: nil)
        #expect(later.visibleIndex == 2)
        #expect(later.alpha == 1, "no crossfade during the very first dwell")
    }

    @Test func walksRoundFromTheFrontOneDwellAtATime() {
        // dwell k shows (front + k) mod 4 → 2, 3, 0, 1, 2 …
        for (k, expected) in [0: 2, 1: 3, 2: 0, 3: 1, 4: 2] {
            let mid = origin + (Double(k) + 0.5) * cycle.dwell
            let s = cycle.sample(at: mid, origin: origin, holdSince: nil)
            #expect(s.visibleIndex == expected, "dwell \(k)")
            #expect(s.alpha == 1, "mid-dwell is fully settled (k=\(k))")
        }
    }

    @Test func crossfadeRampsAtTheHeadOfEachDwell() {
        let head = origin + cycle.dwell            // dwell 1 begins
        let s0 = cycle.sample(at: head, origin: origin, holdSince: nil)
        #expect(s0.top.index == 3 && s0.bottom.index == 2)
        #expect(s0.alpha == 0, "incoming frame starts invisible")
        #expect(s0.visibleIndex == 2, "outgoing frame still shows")
        let sMid = cycle.sample(at: head + cycle.crossfade / 2, origin: origin, holdSince: nil)
        #expect(abs(sMid.alpha - 0.5) < 1e-9, "smoothstep is 0.5 at the midpoint")
        let sEnd = cycle.sample(at: head + cycle.crossfade, origin: origin, holdSince: nil)
        #expect(sEnd.alpha == 1)
        #expect(sEnd.visibleIndex == 3)
        // Monotone: never brightens then dims.
        var last = -1.0
        for i in 0...14 {
            let a = cycle.sample(at: head + cycle.crossfade * Double(i) / 14, origin: origin, holdSince: nil).alpha
            #expect(a >= last - 1e-12); last = a
        }
    }

    @Test func kenBurnsStaysWithinTheAskedForBounds() {
        // Rick 2026-08-18: scale 1.00→1.03, translate ≤ 2% — calm, never bouncy.
        var seenMax = 1.0
        for i in 0..<400 {
            let t = origin + Double(i) * 0.25
            let s = cycle.sample(at: t, origin: origin, holdSince: nil)
            for layer in [s.top, s.bottom] {
                #expect(layer.scale >= 1.0 - 1e-12 && layer.scale <= 1.03 + 1e-12)
                #expect(abs(layer.dx) <= 0.02 + 1e-12)
                #expect(abs(layer.dy) <= 0.02 + 1e-12)
                seenMax = max(seenMax, layer.scale)
            }
        }
        #expect(seenMax > 1.02, "the push-in actually happens")
        // Within a dwell the zoom only grows (no bounce).
        let s1 = cycle.sample(at: origin + 2, origin: origin, holdSince: nil).top.scale
        let s2 = cycle.sample(at: origin + 8, origin: origin, holdSince: nil).top.scale
        #expect(s2 > s1)
    }

    @Test func holdingBringsHerToTheFrontAndKeepsHerThere() {
        // She's mid-way through dwell 2 (frame 0) when the user starts typing.
        let h = origin + 2.5 * cycle.dwell
        let atHold = cycle.sample(at: h, origin: origin, holdSince: h)
        #expect(atHold.bottom.index == 0, "the frame she was on freezes underneath")
        #expect(atHold.top.index == 2 && atHold.alpha == 0)
        #expect(atHold.visibleIndex == 0)
        let settled = cycle.sample(at: h + cycle.crossfade, origin: origin, holdSince: h)
        #expect(settled.visibleIndex == 2 && settled.alpha == 1)
        #expect(settled.bottom.scale == 1.0 && settled.bottom.dx == 0, "Ken Burns eased home")
        // Long after: still front, however long she thinks.
        let much = cycle.sample(at: h + 90, origin: origin, holdSince: h)
        #expect(much.visibleIndex == 2 && much.alpha == 1)
    }

    @Test func holdWhileAlreadyFrontIsSeamless() {
        let h = origin + 3          // dwell 0, front frame
        let s = cycle.sample(at: h + 0.1, origin: origin, holdSince: h)
        #expect(s.top.index == 2 && s.bottom.index == 2)
        #expect(s.alpha == 1, "no fade between identical frames")
    }

    @Test func resumeDelayHoldsFrontThenWalksAgainFromTheFront() {
        // The view sets origin = release + resumeDelay when the hold ends.
        let release = origin + 500
        let newOrigin = release + cycle.resumeDelay
        let during = cycle.sample(at: release + 1, origin: newOrigin, holdSince: nil)
        #expect(during.visibleIndex == 2 && during.alpha == 1 && during.top.scale == 1.0)
        let justAfter = cycle.sample(at: newOrigin + 0.5, origin: newOrigin, holdSince: nil)
        #expect(justAfter.visibleIndex == 2 && justAfter.alpha == 1, "first dwell after resume is the front, no fade")
        let nextDwell = cycle.sample(at: newOrigin + 1.5 * cycle.dwell, origin: newOrigin, holdSince: nil)
        #expect(nextDwell.visibleIndex == 3, "then she turns to the next angle")
    }

    @Test func degenerateInputsFallBackToAStillFront() {
        let one = ArchivistAngleCycle(frameCount: 1, frontFrameIndex: 2)
        #expect(one.sample(at: 5, origin: 0, holdSince: nil) == one.stillFront())
        #expect(one.stillFront().visibleIndex == 0, "front index wraps into range")
        let none = ArchivistAngleCycle(frameCount: 0)
        #expect(none.stillFront().visibleIndex == 0)
        // Reduce Motion path: front frame, neutral, fully opaque.
        let still = cycle.stillFront()
        #expect(still.visibleIndex == 2 && still.alpha == 1 && still.top.scale == 1.0)
    }

    @Test func frontFrameIndexIsAParameter() {
        let c = ArchivistAngleCycle(frameCount: 4, frontFrameIndex: 0)
        #expect(c.sample(at: 0, origin: 0, holdSince: nil).visibleIndex == 0)
        #expect(c.sample(at: 1.5 * c.dwell, origin: 0, holdSince: nil).visibleIndex == 1)
    }
}
