// CompareFilmstripTests.swift
// Compare Media's frames over the sound (2026-10-22) — LOGIC: the
// positions (same fractions both sides), the slot a landed frame takes,
// the cache key, what blocks a strip, the byte-identical all-green paint,
// the card's length. The real-media half (media matrix, shared-cache
// isolation, offline/missing/cancel) is CompareFilmstripMediaTests.swift.

import AppKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Compare filmstrip — positions, paint, length")
struct CompareFilmstripLogicTests {

    @Test("eight centered fractions: 1/16, 3/16 … 15/16")
    func fractions() {
        let f = CompareFilmstripPlan.fractions()
        #expect(f.count == 8)
        let expected: [Double] = [1, 3, 5, 7, 9, 11, 13, 15].map { (n: Double) -> Double in n / 16 }
        #expect(f == expected)
        #expect(CompareFilmstripPlan.fractions(count: 0).isEmpty)
    }

    @Test("both sides take the SAME fractions of their own length, always 8 slots, even for a short file")
    func sameFractionsBothSides() {
        let a = CompareFilmstripPlan.offsets(durationSeconds: 1176)
        let b = CompareFilmstripPlan.offsets(durationSeconds: 2280)
        #expect(a.count == 8 && b.count == 8)
        for i in 0..<8 { #expect(abs(a[i] / 1176 - b[i] / 2280) < 1e-12) }
        #expect(abs(a[0] - 1176.0 / 16) < 1e-9 && abs(a[7] - 1176.0 * 15 / 16) < 1e-9)
        // The preview pane's planner dedupes a short file; this one must not.
        #expect(CompareFilmstripPlan.offsets(durationSeconds: 0.4).count == 8)
    }

    @Test("an unplannable length gives no slots (never a trap)")
    func unplannable() {
        for d in [0, -3, Double.nan, Double.infinity, 1e12] {
            #expect(CompareFilmstripPlan.offsets(durationSeconds: d).isEmpty, "\(d)")
        }
    }

    @Test("a landed frame takes the nearest planned slot (AVF reports CMTime-rounded times)")
    func slots() {
        let o = CompareFilmstripPlan.offsets(durationSeconds: 80)   // 5, 15 … 75
        #expect(CompareFilmstripPlan.slot(forOffset: 5.0008, in: o) == 0)
        #expect(CompareFilmstripPlan.slot(forOffset: 74.99, in: o) == 7)
        #expect(CompareFilmstripPlan.slot(forOffset: 31, in: o) == 3)
        #expect(CompareFilmstripPlan.slot(forOffset: .nan, in: o) == nil)
        #expect(CompareFilmstripPlan.slot(forOffset: 3, in: []) == nil)
    }

    @Test("the cache key never equals a thumbnail's bare-path key and changes with the file's signature")
    func cacheKey() {
        let path = "/Volumes/X/a.mov"
        let k1 = PreviewDiskCache.cacheKey(path: path, mtime: 100, size: 10)
        let k2 = PreviewDiskCache.cacheKey(path: path, mtime: 101, size: 10)
        let key = CompareFilmstripPlan.cacheKey(signatureKey: k1, offsetSeconds: 12.5)
        #expect(key != path && key.hasSuffix("#compare-12500"))
        #expect(key != CompareFilmstripPlan.cacheKey(signatureKey: k2, offsetSeconds: 12.5))
        #expect(key != CompareFilmstripPlan.cacheKey(signatureKey: k1, offsetSeconds: 37.5))
    }

    @Test("what blocks a strip, in the order a person says it; render errors read as words, a cancel says nothing")
    func blockers() {
        let o = [1.0]
        #expect(CompareFilmstripPlan.blocker(hasPicture: false, offsets: o, volumeMounted: false) == .noPicture)
        #expect(CompareFilmstripPlan.blocker(hasPicture: true, offsets: [], volumeMounted: false) == .lengthUnknown)
        #expect(CompareFilmstripPlan.blocker(hasPicture: true, offsets: o, volumeMounted: false) == .driveOffline)
        #expect(CompareFilmstripPlan.blocker(hasPicture: true, offsets: o, volumeMounted: true) == nil)
        #expect(CompareFilmstripPlan.blank(for: CancellationError()) == nil)
        #expect(CompareFilmstripPlan.blank(for: PreviewFrameError.ffmpegUnavailable) == .noFFmpeg)
        #expect(CompareFilmstripPlan.blank(for: PreviewFrameError.noFrameProduced) == .unreadable)
        #expect(CompareFilmstripBlank.driveOffline.words == "drive offline" && CompareFilmstripBlank.fileMissing.words == "file missing")
    }

    @Test("an audio-only or no-stream record has no picture; video-only and A/V do")
    @MainActor func hasPicture() {
        func request(_ type: StreamType) -> CompareFilmstripRequest {
            let r = VideoRecord(); r.fullPath = "/tmp/x.mxf"; r.streamTypeRaw = type.rawValue; r.durationSeconds = 10
            return CompareFilmstripRequest(record: r)
        }
        #expect(!request(.audioOnly).hasPicture && !request(.noStreams).hasPicture)
        #expect(request(.videoOnly).hasPicture && request(.videoAndAudio).hasPicture)
    }

    // MARK: Byte-identical paint

    @Test("byte-identical files: every audible second green; a partial stored match is flagged stale")
    func identicalPaintsAllGreen() {
        let active = [true, true, false, true, true, true, false, true]
        let p = SoundStripPaint(active: active, matched: 2..<5, durationSeconds: 8, identicalBytes: true)
        #expect(p.matched == 0..<8 && p.fingerprintStale)
        let bins = SoundStripBins(active: active, matched: p.matched, durationSeconds: 8)
        for s in 0..<8 where active[s] { #expect(bins.anyMatched(s, s + 1), "second \(s) would paint orange") }
    }

    @Test("byte-identical with a match that already covers every audible second: no stale note")
    func identicalFullCoverageNotStale() {
        let active = [false, true, true, true, false]
        // Silent ends left out of the stored match are not a stale print.
        #expect(!SoundStripPaint(active: active, matched: 1..<4, durationSeconds: 5, identicalBytes: true).fingerprintStale)
        #expect(SoundStripPaint(active: active, matched: nil, durationSeconds: 5, identicalBytes: true).fingerprintStale,
                "no stored match at all while sound is there = stale")
        #expect(!SoundStripPaint(active: [false, false], matched: nil, durationSeconds: 2, identicalBytes: true).fingerprintStale,
                "silence has nothing to match")
    }

    @Test("a pair that is not byte-identical paints the stored match as is")
    func differentBytesPassThrough() {
        let p = SoundStripPaint(active: [true, true, true], matched: 1..<2, durationSeconds: 3, identicalBytes: false)
        #expect(p.matched == 1..<2 && !p.fingerprintStale)
        #expect(SoundStripPaint(active: [true], matched: nil, durationSeconds: 1, identicalBytes: false).matched == nil)
    }

    @Test("byte-identical, duration longer than the map: the green range covers the whole strip")
    func identicalCoversDuration() {
        let p = SoundStripPaint(active: [true, true], matched: 0..<2, durationSeconds: 10, identicalBytes: true)
        #expect(p.matched == 0..<10 && !p.fingerprintStale)
    }

    // MARK: Length

    @Test("the card's length uses the catalog table's formatter: 1175.6 s reads 00:19:35 in both")
    func lengthMatchesTable() {
        #expect(CompareMediaWords.length(1175.6) == "00:19:35")
        #expect(CompareMediaWords.length(1175.6) == Formatting.duration(1175.6))
        #expect(CompareMediaWords.length(.nan) == "00:00:00" && CompareMediaWords.length(-4) == "00:00:00")
        #expect(CompareMediaWords.length(3725) == "01:02:05")
    }
}
