import Foundation

// MARK: - Check Media — "Sound stored beside picture" (Rick 2026-10-07)
//
// Quick tier, index-only in spirit: a few short packet windows, never the
// whole file. Asks one physical question: for the same moment, how far
// apart in the FILE are the sound and the picture stored?
//
// Motivating case (read-only calibration, never modified):
//   BrocktonChristmas2010.mov — 41.5 GB DNxHD 220 + pcm_s24be. Every
//   picture packet sits at the front of the file and every sound packet
//   at the end (41 GB apart). The sound itself is perfect, but a player
//   reading from a spinning disk seeks between the two ends for every
//   buffer refill and the sound starves → stutter. A quick check called it
//   healthy; this check is the fix.
//
// Measures per window (start / middle / end, each ~5 s of picture):
//   * separation — the median byte distance between each sound packet and
//     the picture packet nearest it in time (signed: + = sound after);
//   * longest run — in FILE order, the longest stretch (seconds) of one
//     stream before the other appears.
// Both are taken only over the time BOTH streams' windows cover —
// otherwise a shorter audio window looks like a long run of picture
// (seen on a healthy ffmpeg mp4 during calibration).
//
// Memory: ≤ 300 + ~250 short rows per window while measuring; the result
// keeps three numbers per window.

/// One window's verdict-ready numbers.
struct MediaLayoutMeasure: Sendable, Equatable {
    var startSeconds: Double
    /// Median (sound byte − nearest-in-time picture byte). + = sound later.
    var separationBytes: Int64
    /// Longest file-order stretch of one stream, in seconds of its own time.
    var longestRunSeconds: Double

    var distanceBytes: Int64 { abs(separationBytes) }

    /// nil when the two streams don't share at least 0.2 s in this window
    /// (e.g. the sound ends before the picture) — nothing to compare.
    static func measure(video: [MediaPacketRow], audio: [MediaPacketRow]) -> MediaLayoutMeasure? {
        let v = located(video), a = located(audio)
        guard let vFirst = v.first?.pts, let vLast = v.last?.pts,
              let aFirst = a.first?.pts, let aLast = a.last?.pts else { return nil }
        let lo = max(vFirst, aFirst), hi = min(vLast, aLast)
        guard hi - lo >= 0.2 else { return nil }
        let vIn = v.filter { (lo...hi).contains($0.pts) }
        let aIn = a.filter { (lo...hi).contains($0.pts) }
        guard !vIn.isEmpty, !aIn.isEmpty else { return nil }
        return MediaLayoutMeasure(startSeconds: lo,
                                  separationBytes: medianSeparation(audio: aIn, video: vIn),
                                  longestRunSeconds: longestRun(video: vIn, audio: aIn))
    }

    /// A packet with a known time and file position. (A tuple-like value
    /// type ≈ a C++ POD struct.)
    struct Located: Equatable {
        var pts: Double
        var pos: Int64
    }

    /// Packets with both pts and pos, sorted by time.
    static func located(_ rows: [MediaPacketRow]) -> [Located] {
        rows.compactMap { r in
            guard let pts = r.pts, let pos = r.pos else { return nil }
            return Located(pts: pts, pos: pos)
        }.sorted { $0.pts < $1.pts }
    }

    /// For each sound packet, the picture packet nearest in time
    /// (binary search; `video` sorted by pts); the median signed distance.
    static func medianSeparation(audio: [Located], video: [Located]) -> Int64 {
        let distances = audio.map { a -> Int64 in
            a.pos - nearest(to: a.pts, in: video).pos
        }.sorted()
        return distances[distances.count / 2]
    }

    private static func nearest(to t: Double, in sorted: [Located]) -> Located {
        var lo = 0, hi = sorted.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sorted[mid].pts < t { lo = mid + 1 } else { hi = mid }
        }
        guard lo > 0, abs(sorted[lo - 1].pts - t) <= abs(sorted[lo].pts - t) else { return sorted[lo] }
        return sorted[lo - 1]
    }

    /// File order, grouped into runs of the same stream; the longest run's
    /// time span.
    static func longestRun(video: [Located], audio: [Located]) -> Double {
        let merged = (video.map { ($0, true) } + audio.map { ($0, false) }).sorted { $0.0.pos < $1.0.pos }
        var longest = 0.0
        var runIsVideo: Bool?
        var runLo = 0.0, runHi = 0.0
        for (packet, isVideo) in merged {
            if isVideo != runIsVideo {
                runIsVideo = isVideo
                runLo = packet.pts
                runHi = packet.pts
            }
            runLo = min(runLo, packet.pts)
            runHi = max(runHi, packet.pts)
            longest = max(longest, runHi - runLo)
        }
        return longest
    }
}

/// The windows the probe measured.
struct MediaLayoutSample: Sendable, Equatable {
    var windows: [MediaLayoutMeasure]

    var worstDistanceBytes: Int64 { windows.map(\.distanceBytes).max() ?? 0 }
    var longestRunSeconds: Double { windows.map(\.longestRunSeconds).max() ?? 0 }
    /// The window with the widest gap (its sign says before/after).
    var worstWindow: MediaLayoutMeasure? { windows.max { $0.distanceBytes < $1.distanceBytes } }
}

extension CheckMediaRules {

    // MARK: Layout thresholds (named so the tests pin them)

    /// Sound more than this far (bytes) from its picture means a seek per
    /// buffer refill: far beyond any player's read-ahead (a few MB to a
    /// few tens of MB), ≈ 2.3 s of DNxHD 220 and ≈ 20 s of 25 Mbit/s HDV.
    /// A sane 0.5–1 s interleave of even 4K ProRes stays under it.
    static let layoutApartBytes: Int64 = 64 << 20
    /// …and that separation holds for at least this long in one stream:
    /// longer than a player's default sound buffer (≈ 1 s), so the sound
    /// runs dry while the picture is still being read.
    static let layoutRunProblemSeconds = 2.0
    /// Long one-stream stretches that stay close in bytes (low bitrate):
    /// players usually cope; worth a look on a slow drive.
    static let layoutRunWarningSeconds = 4.0

    static let layoutFix = "Lossless remux (no re-encode) puts sound and picture side by side."

    // 9. Sound stored beside picture.
    static func checkLayout(_ i: CheckMediaQuickInputs) -> MediaCheck {
        guard i.facts.video != nil, i.facts.audio != nil else {
            return .notRun(.layout, because: "it needs both a picture and a sound track")
        }
        guard let sample = i.layout, let worst = sample.worstWindow else {
            return .notRun(.layout, because: "the sound and picture could not be sampled together")
        }
        let apart = sample.worstDistanceBytes, run = sample.longestRunSeconds
        let evidence = sample.windows.map {
            MediaEvidence("From \(V.timecode($0.startSeconds))",
                          "sound \(V.sizeText($0.distanceBytes)) from its picture, one stream for up to \(String(format: "%.1f", $0.longestRunSeconds)) s")
        }
        if apart > layoutApartBytes, run >= layoutRunProblemSeconds {
            return MediaCheck(kind: .layout, verdict: .problem,
                              sentence: separatedSentence(worst, fileSize: i.facts.sizeBytes ?? 0),
                              evidence: evidence, fix: layoutFix)
        }
        if apart > layoutApartBytes || run >= layoutRunWarningSeconds {
            return MediaCheck(kind: .layout, verdict: .warning,
                              sentence: "Sound and picture are stored in big separate pieces (up to \(V.sizeText(apart)) apart, \(String(format: "%.1f", run)) s at a time) — a fast drive copes; a slow one may stutter.",
                              evidence: evidence, fix: layoutFix)
        }
        return MediaCheck(kind: .layout, verdict: .ok,
                          sentence: "Sound and picture are stored side by side (at most \(V.sizeText(apart)) apart).",
                          evidence: evidence)
    }

    /// "All the sound is stored after all the picture (41 GB apart)…" when
    /// the gap is most of the file; a plainer sentence otherwise.
    static func separatedSentence(_ w: MediaLayoutMeasure, fileSize: Int64) -> String {
        let gap = V.sizeText(w.distanceBytes)
        let tail = ": players reading from a spinning disk will stutter. The sound itself may be fine."
        if fileSize > 0, Double(w.distanceBytes) > 0.5 * Double(fileSize) {
            let order = w.separationBytes > 0 ? "after all the picture" : "before all the picture"
            return "All the sound is stored \(order) (\(gap) apart)" + tail
        }
        return "The sound is stored \(gap) away from its picture" + tail
    }
}
