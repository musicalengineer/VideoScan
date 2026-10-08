import Foundation

// MARK: - Check Media — full tier rows from the packet census (2026-10-07)
//
// Pure: PacketCensusReport (+ the header facts) → one MediaCheck per row.
// Every packet was listed, so these are whole-file answers, not samples:
// the full Layout row REPLACES the quick tier's sampled one on the card
// (`merging(_:with:)`).

/// A measured value, or the "not run" row explaining its absence.
/// (An enum with payloads ≈ a C++ std::variant<T, MediaCheck>.)
enum CheckMeasured<T> {
    case value(T)
    case notRun(MediaCheck)
}

extension CheckMediaRules {

    static func measured<T>(_ r: Result<T, CheckMediaSkip>?, _ kind: MediaCheckKind,
                            missing: String) -> CheckMeasured<T> {
        switch r {
        case .success(let v)?: return .value(v)
        case .failure(let skip)?: return .notRun(.notRun(kind, because: skip.reason))
        case nil: return .notRun(.notRun(kind, because: missing))
        }
    }

    /// Full rows replace quick rows of the same kind in place; the rest
    /// are appended in order. One row per kind, always.
    static func merging(_ quick: [MediaCheck], with full: [MediaCheck]) -> [MediaCheck] {
        var rows = quick
        for row in full {
            if let at = rows.firstIndex(where: { $0.kind == row.kind }) { rows[at] = row } else { rows.append(row) }
        }
        return rows
    }

    static let censusMissing = "the packet listing did not run"

    static func censusChecks(_ census: Result<PacketCensusReport, CheckMediaSkip>?,
                             facts: MediaFacts) -> [MediaCheck] {
        var rows = [checkPacketTiming(census), checkKeyframes(census, facts: facts),
                    checkDataRate(census, facts: facts), checkSync(census, facts: facts),
                    checkTimecode(facts)]
        if let layout = checkFullLayout(census) { rows.append(layout) }
        return rows
    }

    // Layout, every sound packet. nil keeps the quick tier's sample.
    static func checkFullLayout(_ census: Result<PacketCensusReport, CheckMediaSkip>?) -> MediaCheck? {
        guard case .success(let c)? = census, let l = c.layout, l.soundPackets >= 20 else { return nil }
        let share = percentText(l.farShare)
        let evidence = [MediaEvidence("Sound packets checked", V.groupedInt(l.soundPackets)),
                        MediaEvidence("More than \(V.sizeText(layoutApartBytes)) from the picture",
                                      "\(V.groupedInt(l.farApart)) (\(share))"),
                        MediaEvidence("Farthest", V.sizeText(l.maxDistance))]
        let tail = ": players reading from a spinning disk will stutter. The sound itself may be fine."
        if l.farShare >= 0.95 {
            return MediaCheck(kind: .layout, verdict: .problem,
                              sentence: "All the sound is stored away from its picture (up to \(V.sizeText(l.maxDistance)) apart)" + tail,
                              evidence: evidence, fix: layoutFix)
        }
        if l.farShare >= 0.05 {
            return MediaCheck(kind: .layout, verdict: .problem,
                              sentence: "\(share) of the sound is stored more than \(V.sizeText(layoutApartBytes)) from its picture" + tail,
                              evidence: evidence, fix: layoutFix)
        }
        if l.farApart > 0 {
            return MediaCheck(kind: .layout, verdict: .warning,
                              sentence: "A little of the sound (from \(V.timecode(l.firstFarAt ?? 0))) is stored far from its picture — a slow drive may stutter there.",
                              evidence: evidence, fix: layoutFix)
        }
        return MediaCheck(kind: .layout, verdict: .ok,
                          sentence: "Every sound packet is stored beside its picture (at most \(V.sizeText(l.maxDistance)) apart).",
                          evidence: evidence)
    }

    // Timing, every packet.
    static func checkPacketTiming(_ census: Result<PacketCensusReport, CheckMediaSkip>?) -> MediaCheck {
        let c: PacketCensusReport
        switch measured(census, .packetTiming, missing: censusMissing) {
        case .notRun(let row): return row
        case .value(let v): c = v
        }
        let streams = [("Picture", c.video), ("Sound", c.audio)].compactMap { name, t in t.map { (name, $0) } }
        guard !streams.isEmpty else { return .notRun(.packetTiming, because: "no picture or sound packets were listed") }
        let evidence = streams.map { name, t in
            MediaEvidence("\(name) packets",
                          "\(V.groupedInt(t.packets)), \(t.backwards.occurrences) out of order, \(t.gaps.occurrences) gaps")
        }
        if let (name, t) = streams.first(where: { $0.1.backwards.occurrences >= 1 }) {
            return MediaCheck(kind: .packetTiming, verdict: .problem,
                              sentence: "\(V.groupedInt(t.backwards.occurrences)) \(name.lowercased()) packets go back in time (at \(t.backwards.timesText)) — players skip or stall there.",
                              evidence: evidence,
                              fix: "Re-wrap (copy, no re-encode) to rebuild the timestamps; keep this copy until the new one plays right.")
        }
        if let (name, t) = streams.first(where: { $0.1.gaps.occurrences >= 1 }) {
            return MediaCheck(kind: .packetTiming, verdict: .warning,
                              sentence: "The \(name.lowercased()) has \(V.groupedInt(t.gaps.occurrences)) gap\(t.gaps.occurrences == 1 ? "" : "s") (largest \(String(format: "%.1f", t.largestGapSeconds)) s, at \(t.gaps.timesText)).",
                              evidence: evidence,
                              fix: "Play across the gap; if picture or sound drops out there, look for another copy.")
        }
        return MediaCheck(kind: .packetTiming, verdict: .ok,
                          sentence: "Every packet is in order, with no gaps.", evidence: evidence)
    }

    // Keyframes.
    static func checkKeyframes(_ census: Result<PacketCensusReport, CheckMediaSkip>?, facts: MediaFacts) -> MediaCheck {
        guard facts.video != nil else { return .notRun(.keyframes, because: noPicture) }
        let k: KeyframeTally
        switch measured(census, .keyframes, missing: censusMissing) {
        case .notRun(let row): return row
        case .value(let c):
            guard let tally = c.keyframes, tally.packets > 0 else { return .notRun(.keyframes, because: "no picture packets were listed") }
            k = tally
        }
        let evidence = [MediaEvidence("Keyframes", "\(V.groupedInt(k.keyframes)) of \(V.groupedInt(k.packets)) frames"),
                        MediaEvidence("Longest gap", String(format: "%.1f s", k.longestGapSeconds))]
        let fix = "Fine to keep as the original; make viewing copies with a keyframe every second or two."
        if k.keyframes == k.packets {
            return MediaCheck(kind: .keyframes, verdict: .ok,
                              sentence: "Every frame is a keyframe (an editing codec such as DV, ProRes or DNxHD).", evidence: evidence)
        }
        if k.keyframes <= 1, k.packets > 300 {
            return MediaCheck(kind: .keyframes, verdict: .warning,
                              sentence: "Only the first frame is a keyframe — seeking will be very slow and some editors refuse the file.",
                              evidence: evidence, fix: fix)
        }
        if k.longestGapSeconds > 10 {
            return MediaCheck(kind: .keyframes, verdict: .warning,
                              sentence: "Keyframes are up to \(String(format: "%.0f", k.longestGapSeconds)) s apart (at \(V.timecode(k.longestGapAt ?? 0))) — seeking jumps or stalls.",
                              evidence: evidence, fix: fix)
        }
        let every = (facts.video?.durationSeconds ?? facts.durationSeconds ?? 0) / Double(max(k.keyframes, 1))
        return MediaCheck(kind: .keyframes, verdict: .ok,
                          sentence: "A keyframe about every \(String(format: "%.1f", every)) s — seeking works.", evidence: evidence)
    }

    // Data rate over time.
    static func checkDataRate(_ census: Result<PacketCensusReport, CheckMediaSkip>?, facts: MediaFacts) -> MediaCheck {
        guard let video = facts.video else { return .notRun(.dataRate, because: noPicture) }
        let rate: DataRateTally
        switch measured(census, .dataRate, missing: censusMissing) {
        case .notRun(let row): return row
        case .value(let c):
            guard let r = c.dataRate, let _ = r.spread else { return .notRun(.dataRate, because: "the picture is under 3 s long") }
            rate = r
        }
        let spread = rate.spread ?? (0, 0, 0)
        let evidence = [MediaEvidence("Per second", "lowest \(V.bitrateText(spread.low)), median \(V.bitrateText(spread.median)), highest \(V.bitrateText(spread.high))")]
        let empty = rate.emptySeconds
        // A slideshow (under 2 fps) legitimately has seconds with no frame.
        if empty.occurrences >= 1, video.avgFrameRate >= 2 {
            return MediaCheck(kind: .dataRate, verdict: .warning,
                              sentence: "\(V.groupedInt(empty.occurrences)) whole second\(empty.occurrences == 1 ? "" : "s") carry no picture at all (at \(empty.timesText)) — the picture stops there.",
                              evidence: evidence,
                              fix: "Watch those moments. If the picture freezes or jumps there, look for another copy.")
        }
        return MediaCheck(kind: .dataRate, verdict: .ok,
                          sentence: "Picture data arrives every second, at \(V.bitrateText(spread.median)) typically.", evidence: evidence)
    }

    // Sound and picture start together.
    static func checkSync(_ census: Result<PacketCensusReport, CheckMediaSkip>?, facts: MediaFacts) -> MediaCheck {
        guard facts.video != nil, facts.audio != nil else {
            return .notRun(.sync, because: "it needs both a picture and a sound track")
        }
        let c: PacketCensusReport
        switch measured(census, .sync, missing: censusMissing) {
        case .notRun(let row): return row
        case .value(let v): c = v
        }
        guard let vs = c.video?.firstSeconds, let a = c.audio?.firstSeconds,
              let ve = c.video?.endSeconds, let ae = c.audio?.endSeconds else {
            return .notRun(.sync, because: "the start times could not be read")
        }
        let start = a - vs
        let evidence = [MediaEvidence("Sound starts", String(format: "%+.3f s from the picture", start)),
                        MediaEvidence("Sound ends", String(format: "%+.3f s from the picture", ae - ve))]
        let words = start > 0 ? "after" : "before"
        if abs(start) >= 0.5 {
            return MediaCheck(kind: .sync, verdict: abs(start) >= 5 ? .problem : .warning,
                              sentence: "The sound starts \(String(format: "%.1f", abs(start))) s \(words) the picture — voices may be out of step.",
                              evidence: evidence,
                              fix: "Play a moment with speech. If it is off all the way through, a re-wrap with an offset fixes it (no re-encode).")
        }
        return MediaCheck(kind: .sync, verdict: .ok,
                          sentence: "Sound and picture start within \(Int((abs(start) * 1000).rounded())) ms of each other.",
                          evidence: evidence)
    }
}
