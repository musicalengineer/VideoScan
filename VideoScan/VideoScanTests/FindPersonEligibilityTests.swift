import Testing
import Foundation
@testable import VideoScan

// MARK: - Find & Tag eligibility prefilter pins (Rick's spec, 2026-08-03)
//
// "Only video files > 10 seconds — no audio-only, junk, cover art,
// FCP/iMovie internals, purged leftovers." These tests ARE that spec;
// codex extends coverage, but the dictated rules get pinned the day
// they're dictated.

@MainActor
@Suite("FindPerson eligibility prefilter")
struct FindPersonEligibilityTests {

    private func video(_ path: String = "/Volumes/T/clip.mov",
                       seconds: Double = 60,
                       stream: StreamType = .videoAndAudio) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.streamTypeRaw = stream.rawValue
        r.durationSeconds = seconds
        return r
    }

    @Test func healthyVideoIsEligible() {
        #expect(FindPersonJob.skipReason(for: video()) == nil)
        #expect(FindPersonJob.skipReason(for: video(seconds: 10)) == nil)   // boundary: ≥10 passes
        #expect(FindPersonJob.skipReason(for: video(stream: .videoOnly)) == nil)
    }

    @Test func nonVideoStreamsAreSkipped() {
        #expect(FindPersonJob.skipReason(for: video(stream: .audioOnly)) == .notVideo)
        #expect(FindPersonJob.skipReason(for: video(stream: .noStreams)) == .notVideo)
        #expect(FindPersonJob.skipReason(for: video(stream: .ffprobeFailed)) == .notVideo)
    }

    @Test func junkDispositionsAreSkipped() {
        let suspected = video(); suspected.mediaDisposition = .suspectedJunk
        let confirmed = video(); confirmed.mediaDisposition = .confirmedJunk
        #expect(FindPersonJob.skipReason(for: suspected) == .junk)
        #expect(FindPersonJob.skipReason(for: confirmed) == .junk)
    }

    @Test func shortAndUnprobedClipsAreSkipped() {
        #expect(FindPersonJob.skipReason(for: video(seconds: 9.9)) == .tooShort)
        #expect(FindPersonJob.skipReason(for: video(seconds: 0)) == .tooShort)  // never probed
    }

    @Test func editorBundleInternalsAreSkipped() {
        for path in [
            "/Users/r/Movies/Old.fcpbundle/Cape/Render Files/x.mov",
            "/Users/r/Movies/iMovie Library.imovielibrary/thesky/clip.mov",
            "/Users/r/Pictures/Photos Library.photoslibrary/originals/a.mov",
        ] {
            #expect(FindPersonJob.skipReason(for: video(path)) == .bundleInternal,
                    "expected bundleInternal for \(path)")
        }
    }

    @Test func purgedSetAsideAndSupersededAreSkipped() {
        let purged = video(); purged.purgedAt = Date()
        let aside = video(); aside.setAsideReason = "dup"
        let superseded = video(); superseded.supersededByID = UUID()
        #expect(FindPersonJob.skipReason(for: purged) == .purgedOrRetired)
        #expect(FindPersonJob.skipReason(for: aside) == .purgedOrRetired)
        #expect(FindPersonJob.skipReason(for: superseded) == .purgedOrRetired)
    }

    /// Priority pin: a junk-marked audio file reports notVideo (the
    /// structural reason wins) — breakdown counts stay stable.
    @Test func structuralReasonWinsOverDisposition() {
        let r = video(stream: .audioOnly); r.mediaDisposition = .confirmedJunk
        #expect(FindPersonJob.skipReason(for: r) == .notVideo)
    }
}
