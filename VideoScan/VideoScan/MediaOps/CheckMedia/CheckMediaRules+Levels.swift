import Foundation

// MARK: - Check Media — full tier rows: sound levels, colour, timecode
//
// Pure. Sound levels come from the continuity pass (SoundLevels.swift);
// colour compares the header's labels with signalstats' luma range from the
// picture decode (PictureSignals.swift); timecode reads header tags.

extension CheckMediaRules {

    static let soundPassMissing = "the sound pass did not run"

    /// The level rows, from the one sound pass.
    static func levelChecks(_ continuity: Result<SoundContinuityReport, CheckMediaSkip>?,
                            facts: MediaFacts) -> [MediaCheck] {
        let kinds: [MediaCheckKind] = [.loudness, .dcOffset, .channels, .clipping]
        guard facts.audio != nil else {
            return kinds.map { .notRun($0, because: "this file has no sound track") }
        }
        let levels: SoundLevelReport
        switch continuity {
        case .success(let r)?: levels = r.levels
        case .failure(let skip)?: return kinds.map { .notRun($0, because: skip.reason) }
        case nil: return kinds.map { .notRun($0, because: soundPassMissing) }
        }
        return [checkLoudness(levels), checkDCOffset(levels), checkChannels(levels), checkClipping(levels)]
    }

    // Loudness (EBU R128).
    static func checkLoudness(_ l: SoundLevelReport) -> MediaCheck {
        guard let i = l.loudness.integratedLUFS else {
            return .notRun(.loudness, because: "the loudness meter gave no reading")
        }
        let peak = l.loudness.truePeakDBFS
        var evidence = [MediaEvidence("Integrated", String(format: "%.1f LUFS", i))]
        if let lra = l.loudness.rangeLU { evidence.append(MediaEvidence("Range", String(format: "%.1f LU", lra))) }
        if let peak { evidence.append(MediaEvidence("True peak", String(format: "%.1f dBTP", peak))) }
        let accessFix = "When making an access copy, normalise to about −16 LUFS with a −1 dBTP ceiling."
        if let peak, peak > 0 {
            return MediaCheck(kind: .loudness, verdict: .warning,
                              sentence: String(format: "Peaks go over full scale between samples (true peak %+.1f dBTP) — some players will crackle.", peak),
                              evidence: evidence, fix: accessFix)
        }
        if i < -36 {
            return MediaCheck(kind: .loudness, verdict: .warning,
                              sentence: String(format: "Very quiet: %.0f LUFS (films sit near −23, phone videos near −16).", i),
                              evidence: evidence, fix: accessFix)
        }
        return MediaCheck(kind: .loudness, verdict: .ok,
                          sentence: String(format: "%.0f LUFS overall — a normal listening level.", i), evidence: evidence)
    }

    // Sound centred on zero (DC offset).
    static let dcOffsetLimit = 0.01   // 1 % of full scale ≈ −40 dBFS

    static func checkDCOffset(_ l: SoundLevelReport) -> MediaCheck {
        guard !l.dcOffsets.isEmpty else { return .notRun(.dcOffset, because: "no samples were decoded") }
        let evidence = l.dcOffsets.enumerated().map { index, o in
            MediaEvidence(channelName(index, of: l.dcOffsets.count), String(format: "%+.3f %%", o * 100))
        }
        if let (index, worst) = l.dcOffsets.enumerated().max(by: { abs($0.1) < abs($1.1) }), abs(worst) > dcOffsetLimit {
            return MediaCheck(kind: .dcOffset, verdict: .warning,
                              sentence: String(format: "The sound sits off-centre (%.1f %% of full scale on the %@) — thumps at cuts, less headroom.",
                                               abs(worst) * 100, channelName(index, of: l.dcOffsets.count).lowercased()),
                              evidence: evidence,
                              fix: "Harmless for keeping. A high-pass filter in an access copy removes it.")
        }
        return MediaCheck(kind: .dcOffset, verdict: .ok, sentence: "The sound is centred on zero.", evidence: evidence)
    }

    // Left and right.
    static func checkChannels(_ l: SoundLevelReport) -> MediaCheck {
        let evidence = l.correlation.map { [MediaEvidence("Correlation", String(format: "%+.2f", $0))] } ?? []
        switch l.channels {
        case .notEnough:
            return .notRun(.channels, because: l.channelCount < 2 ? "the sound has one channel" : "too little sound to compare")
        case .identical:
            return MediaCheck(kind: .channels, verdict: .ok,
                              sentence: "Both channels carry the same sound (mono stored as stereo).", evidence: evidence)
        case .inverted:
            return MediaCheck(kind: .channels, verdict: .warning,
                              sentence: "One channel is wired backwards (inverted): played in mono, the sound cancels out.",
                              evidence: evidence,
                              fix: "Re-wrap with that channel inverted back (no picture re-encode); keep this copy until the fix sounds right.")
        case .independent:
            return MediaCheck(kind: .channels, verdict: .ok,
                              sentence: "Left and right carry their own sound.", evidence: evidence)
        }
    }

    // Clipped stretches.
    static func checkClipping(_ l: SoundLevelReport) -> MediaCheck {
        let runs = l.clipRuns
        let evidence = [MediaEvidence("Clipped stretches", runs.occurrences < 1 ? "0" : "\(V.groupedInt(runs.occurrences)) at \(runs.timesText)")]
        if runs.occurrences >= 1 {
            return MediaCheck(kind: .clipping, verdict: .warning,
                              sentence: "\(V.groupedInt(runs.occurrences)) clipped stretch\(runs.occurrences == 1 ? "" : "es"): loud moments are flat-topped and distorted.",
                              evidence: evidence,
                              fix: "Clipping can't be undone; prefer another copy if one exists.")
        }
        return MediaCheck(kind: .clipping, verdict: .ok, sentence: "No clipped stretches.", evidence: evidence)
    }

    // MARK: Colour labels

    /// 8 / 10 / 12 — the luma code range signalstats reports in.
    static func lumaBitDepth(_ v: MediaStreamFacts?) -> Int {
        if let b = v?.bitsPerRawSample, b >= 8 { return b }
        let fmt = v?.pixelFormat ?? ""
        if fmt.contains("12") { return 12 }
        return fmt.contains("10") ? 10 : 8
    }

    static func checkColour(_ facts: MediaFacts, signals: MediaSignalScan?) -> MediaCheck {
        guard let v = facts.video else { return .notRun(.colour, because: noPicture) }
        let labels = v.colour
        var evidence = [MediaEvidence("Labelled", labelWords(labels))]
        if let luma = signals?.luma, luma.frames > 0 {
            evidence.append(MediaEvidence("Luma used", "\(luma.darkest)–\(luma.brightest) (\(lumaBitDepth(v))-bit)"))
        }
        if let finding = colourLabelFinding(v, evidence: evidence) ?? colourRangeFinding(v, luma: signals?.luma, evidence: evidence) {
            return finding
        }
        let sentence = labels.isLabelled
            ? "The colour labels match the picture."
            : "Not labelled — players assume the usual colours for its size, which suit this picture."
        return MediaCheck(kind: .colour, verdict: .ok, sentence: sentence, evidence: evidence)
    }

    static func labelWords(_ l: MediaColourLabels) -> String {
        guard l.isLabelled else { return "not labelled" }
        return [("range", l.range), ("matrix", l.matrix), ("primaries", l.primaries), ("transfer", l.transfer)]
            .filter { !$0.1.isEmpty }.map { "\($0.0) \($0.1)" }.joined(separator: ", ")
    }

    /// Header consistency: SD colour maths on an HD picture, or the reverse.
    private static func colourLabelFinding(_ v: MediaStreamFacts, evidence: [MediaEvidence]) -> MediaCheck? {
        let height = v.height ?? 0, matrix = v.colour.matrix
        let sdMatrices: Set<String> = ["smpte170m", "bt470bg"]
        if height >= 720, sdMatrices.contains(matrix) {
            return MediaCheck(kind: .colour, verdict: .warning,
                              sentence: "An HD picture labelled with SD colour maths (\(matrix)) — reds and greens look slightly off.",
                              evidence: evidence, fix: "Re-wrap with BT.709 labels (no re-encode).")
        }
        if height > 0, height < 720, matrix == "bt709" {
            return MediaCheck(kind: .colour, verdict: .warning,
                              sentence: "An SD picture labelled with HD colour maths (bt709) — colours may look slightly off.",
                              evidence: evidence, fix: "Check against another copy; a re-wrap can correct the label.")
        }
        return nil
    }

    /// The range label against the luma the picture really uses. YUV only:
    /// RGB pictures (ffv1/png/…) are always full range, whatever the label.
    /// One direction only — see LumaRangeScan for why.
    private static func colourRangeFinding(_ v: MediaStreamFacts, luma: LumaRangeScan?,
                                           evidence: [MediaEvidence]) -> MediaCheck? {
        guard let luma, luma.frames >= 50, isYUV(v.pixelFormat) else { return nil }
        guard v.colour.range == "pc", luma.staysLimited else { return nil }
        return MediaCheck(kind: .colour, verdict: .warning,
                          sentence: "Labelled full range, but the picture only uses the limited range — it will look washed out.",
                          evidence: evidence, fix: "Re-wrap with the range set to limited (tv); no re-encode.")
    }

    static func isYUV(_ pixelFormat: String) -> Bool {
        pixelFormat.hasPrefix("yuv") || pixelFormat.hasPrefix("yuvj") || pixelFormat.hasPrefix("nv")
            || pixelFormat.hasPrefix("uyvy") || pixelFormat.hasPrefix("yuyv") || pixelFormat.hasPrefix("p01")
    }

    // MARK: Timecode

    static func checkTimecode(_ facts: MediaFacts) -> MediaCheck {
        let tagged = facts.streams.filter { !$0.timecode.isEmpty }
        let codes = Array(Set(tagged.map(\.timecode) + [facts.timecode].filter { !$0.isEmpty })).sorted()
        guard !codes.isEmpty else { return .notRun(.timecode, because: "the file carries no timecode") }
        var evidence = tagged.map { MediaEvidence("\($0.kind == .data ? "Timecode track" : $0.kind.rawValue.capitalized)", $0.timecode) }
        if !facts.timecode.isEmpty { evidence.append(MediaEvidence("File", facts.timecode)) }
        let fps = facts.video?.rFrameRate ?? 0
        if let bad = codes.first(where: { !isValidTimecode($0, fps: fps) }) {
            return MediaCheck(kind: .timecode, verdict: .warning,
                              sentence: "The timecode \(bad) isn't a valid time at \(V.fpsText(fps)) fps.",
                              evidence: evidence, fix: "Editors may refuse it; a re-wrap can set a valid timecode.")
        }
        if codes.count > 1 {
            return MediaCheck(kind: .timecode, verdict: .warning,
                              sentence: "The file's timecodes disagree (\(codes.joined(separator: ", "))) — an editor may line it up wrongly.",
                              evidence: evidence, fix: "Note which is right; a re-wrap can set one timecode.")
        }
        if let track = tagged.first(where: { $0.kind == .data }), let td = track.durationSeconds,
           let vd = facts.video?.durationSeconds, abs(td - vd) > 1 {
            return MediaCheck(kind: .timecode, verdict: .warning,
                              sentence: "The timecode track runs \(V.durationText(td)) but the picture runs \(V.durationText(vd)).",
                              evidence: evidence, fix: "Editors may cut it short; a re-wrap rebuilds the track.")
        }
        return MediaCheck(kind: .timecode, verdict: .ok,
                          sentence: "Timecode starts at \(codes[0]) and runs the length of the picture.", evidence: evidence)
    }

    /// HH:MM:SS:FF (or ; for drop-frame, . for some cameras); FF below the
    /// frame rate when it is known.
    static func isValidTimecode(_ s: String, fps: Double) -> Bool {
        let parts = s.split(whereSeparator: { ":;.".contains($0) }).compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        let limits = [24, 60, 60, fps > 0 ? Int(fps.rounded(.up)) : 1_000]
        return zip(parts, limits).allSatisfy { $0 >= 0 && $0 < $1 }
    }
}
