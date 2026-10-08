import Foundation

// MARK: - Check Media — pure rules, full tier + the card (Rick 2026-10-07)
//
// The full tier reads what the existing engines already decided — the
// Verify Video decode (with Check Media's signal filters riding along)
// and the Verify Audio levels pass — so a full check and a Verify job can
// never disagree about the same file. Then the headline: one sentence over
// all the rows, chosen from the most serious one.

extension CheckMediaRules {

    // MARK: The full tier

    static func fullChecks(_ i: CheckMediaFullInputs, facts: MediaFacts) -> [MediaCheck] {
        [checkDecode(i.video), checkBlack(i.signals, facts: facts), checkFreeze(i.signals, facts: facts),
         checkSound(i.audio, facts: facts), checkSoundContinuity(i.continuity, facts: facts),
         checkInterlace(i.signals, facts: facts)]
    }

    // 9. Every frame decodes.
    static func checkDecode(_ result: Result<VideoVerifyDiagnosis, CheckMediaSkip>?) -> MediaCheck {
        guard let result else { return .notRun(.decode, because: noPicture) }
        let diagnosis: VideoVerifyDiagnosis
        switch result {
        case .failure(let skip): return .notRun(.decode, because: skip.reason)
        case .success(let d): diagnosis = d
        }
        let decodeFindings = V.checkDecode(diagnosis.decode, totalSeconds: diagnosis.facts.videoDurationSeconds)
        var evidence: [MediaEvidence] = []
        if let d = diagnosis.decode {
            evidence.append(MediaEvidence("Decode complaints", V.groupedInt(d.errorCount)))
            evidence += d.sampleErrors.prefix(3).map { MediaEvidence("Example", $0) }
        }
        if let first = decodeFindings.first, case .decodeSkipped(let reason) = first {
            return .notRun(.decode, because: reason)
        }
        let worst = decodeFindings.map(V.severity).max() ?? .info
        guard worst > .info else {
            let partial = decodeFindings.first.map { "; \(V.noteFragment(for: $0))" } ?? ""
            return MediaCheck(kind: .decode, verdict: .ok,
                              sentence: "Every frame decoded cleanly\(partial).", evidence: evidence)
        }
        return MediaCheck(kind: .decode, verdict: verdict(worst),
                          sentence: "Decoding found: \(decodeFindings.map(V.noteFragment(for:)).joined(separator: "; ")).",
                          evidence: evidence, fix: V.recommendation(for: decodeFindings))
    }

    // 10. / 11. Black and frozen stretches.
    static func checkBlack(_ s: MediaSignalScan?, facts: MediaFacts) -> MediaCheck {
        stretchCheck(.black, seconds: s?.blackSeconds, stretches: s?.blackStretches,
                     facts: facts, noun: "black", fix: "If it should show something, look for another copy.")
    }

    static func checkFreeze(_ s: MediaSignalScan?, facts: MediaFacts) -> MediaCheck {
        stretchCheck(.freeze, seconds: s?.freezeSeconds, stretches: s?.freezeStretches,
                     facts: facts, noun: "frozen", fix: "Watch the frozen stretches; a tape dropout or a stuck encoder looks like this.")
    }

    /// Shared shape of the two "how much of it is X" checks: ≥ 95 % is a
    /// Problem, ≥ 50 % a Warning, anything less is just reported.
    private static func stretchCheck(_ kind: MediaCheckKind, seconds: Double?, stretches: Int?,
                                     facts: MediaFacts, noun: String, fix: String) -> MediaCheck {
        guard facts.video != nil else { return .notRun(kind, because: noPicture) }
        guard let seconds, let stretches else {
            return .notRun(kind, because: "the full decode did not run")
        }
        let total = facts.video?.durationSeconds ?? facts.durationSeconds ?? 0
        let share = total > 0 ? seconds / total : 0
        let evidence = [MediaEvidence("Stretches", V.groupedInt(stretches)),
                        MediaEvidence("Total", V.durationText(seconds))]
        if share >= 0.95 {
            return MediaCheck(kind: kind, verdict: .problem,
                              sentence: "The picture is \(noun) the whole way through.", evidence: evidence, fix: fix)
        }
        if share >= 0.5 {
            return MediaCheck(kind: kind, verdict: .warning,
                              sentence: "The picture is \(noun) for \(percentText(share)) of its length.", evidence: evidence, fix: fix)
        }
        let words = stretches == 0 ? "No \(noun) stretches." : "\(stretches) short \(noun) stretch\(stretches == 1 ? "" : "es") — normal between scenes."
        return MediaCheck(kind: kind, verdict: .ok, sentence: words, evidence: evidence)
    }

    // 12. Sound track: Verify Audio's verdict + per-channel levels.
    static func checkSound(_ result: Result<AudioVerifyDiagnosis, CheckMediaSkip>?, facts: MediaFacts) -> MediaCheck {
        guard facts.audio != nil else { return .notRun(.sound, because: "this file has no sound track") }
        guard let result else { return .notRun(.sound, because: "the sound pass did not run") }
        let diagnosis: AudioVerifyDiagnosis
        switch result {
        case .failure(let skip): return .notRun(.sound, because: skip.reason)
        case .success(let d): diagnosis = d
        }
        let channels = diagnosis.balanceAnalysis?.measurements.channels ?? []
        let evidence = channels.enumerated().map { index, c in
            MediaEvidence(channelName(index, of: channels.count), levelText(c))
        }
        if diagnosis.persistedStatus == "damaged" {
            return MediaCheck(kind: .sound, verdict: .problem,
                              sentence: "The sound is damaged: \(diagnosis.persistedNote.replacingOccurrences(of: VerifyAudioRules.damagedNotePrefix, with: "")).",
                              evidence: evidence,
                              fix: "Right-click ▸ Repair Damaged Audio where offered, or look for another copy.")
        }
        if !diagnosis.isHealthy {
            return MediaCheck(kind: .sound, verdict: .warning,
                              sentence: "The sound plays, but: \(diagnosis.persistedNote).",
                              evidence: evidence,
                              fix: "Get Media Info ▸ Sound Details… shows the fix on offer (for example Balance Audio).")
        }
        return levelsCheck(channels, evidence: evidence)
    }

    /// Silent / clipping from the astats per-channel levels.
    private static func levelsCheck(_ channels: [AudioChannelLevels], evidence: [MediaEvidence]) -> MediaCheck {
        if !channels.isEmpty, !channels.contains(where: AudioBalanceClassifier.carriesProgram) {
            return MediaCheck(kind: .sound, verdict: .warning,
                              sentence: "The sound track is silent.", evidence: evidence,
                              fix: "Look for the matching sound (Find Matching Audio) or another copy with sound.")
        }
        if channels.contains(where: { $0.peakDBFS.isFinite && $0.peakDBFS >= -0.1 }) {
            return MediaCheck(kind: .sound, verdict: .warning,
                              sentence: "The sound reaches full scale, so loud parts may be clipped (distorted).",
                              evidence: evidence,
                              fix: "Listen to the loudest part. Clipping can't be undone; prefer a quieter copy if one exists.")
        }
        return MediaCheck(kind: .sound, verdict: .ok,
                          sentence: channels.isEmpty ? "The sound checked out." : "The sound plays at a healthy level on every channel.",
                          evidence: evidence)
    }

    static func channelName(_ index: Int, of count: Int) -> String {
        guard count == 2 else { return count == 1 ? "Sound" : "Channel \(index + 1)" }
        return index == 0 ? "Left" : "Right"
    }

    /// "−18 dB average, −1 dB peak" / "silent".
    static func levelText(_ c: AudioChannelLevels) -> String {
        guard c.rmsDBFS.isFinite else { return "silent" }
        let peak = c.peakDBFS.isFinite ? String(format: ", %.0f dB peak", c.peakDBFS) : ""
        return String(format: "%.0f dB average", c.rmsDBFS) + peak
    }

    // 13. Interlacing: idet vs the field_order label.
    static func checkInterlace(_ s: MediaSignalScan?, facts: MediaFacts) -> MediaCheck {
        guard let video = facts.video else { return .notRun(.interlace, because: noPicture) }
        guard let s else { return .notRun(.interlace, because: "the full decode did not run") }
        guard s.idetJudged >= 50, let share = s.interlacedShare else {
            return .notRun(.interlace, because: "too few frames could be judged")
        }
        let label = video.fieldOrder
        let evidence = [MediaEvidence("Labelled", label.isEmpty ? "—" : label),
                        MediaEvidence("Interlaced frames", "\(V.groupedInt(s.topFieldFirst + s.bottomFieldFirst)) of \(V.groupedInt(s.idetJudged))")]
        if label == "progressive", share > 0.6 {
            return MediaCheck(kind: .interlace, verdict: .warning,
                              sentence: "Labelled progressive, but the picture is interlaced — expect comb lines on a computer screen.",
                              evidence: evidence,
                              fix: "Deinterlace when making an access copy (Transcode ▸ For Archival…).")
        }
        if ["tt", "bb", "tb", "bt"].contains(label), share < 0.1 {
            return MediaCheck(kind: .interlace, verdict: .warning,
                              sentence: "Labelled interlaced, but the picture is progressive — some players will soften it needlessly.",
                              evidence: evidence,
                              fix: "Harmless for watching; a re-wrap can fix the label.")
        }
        return MediaCheck(kind: .interlace, verdict: .ok,
                          sentence: "The interlacing label matches the picture.", evidence: evidence)
    }

    // MARK: The card

    /// The full-tier rows of a quick check: present, honestly "not run".
    static func fullRowsNotRun() -> [MediaCheck] {
        MediaCheckKind.allCases.filter(\.isFullTier).map {
            .notRun($0, because: "quick check only — the full check decodes every frame and listens to every sample")
        }
    }

    /// When the quick tier alone already settles the picture's verdict
    /// (Verify Video would skip its decode as pointless), the diagnosis
    /// Verify Video would have written — so the video verdict fields get
    /// the same value either way. nil when a decode could still change it.
    static func conclusiveVideoDiagnosis(_ q: CheckMediaQuickInputs) -> VideoVerifyDiagnosis? {
        guard q.videoFacts.hasVideo else { return nil }
        let sample = q.packets?.sample
        let pre = V.preDecodeFindings(facts: q.videoFacts, sample: sample)
        guard V.decodeIsPointless(pre) else { return nil }
        let decode = VerifyVideoProbe.skippedAsPointless(q.videoFacts)
        return VideoVerifyDiagnosis(findings: V.findings(facts: q.videoFacts, sample: sample, decode: decode),
                                    facts: q.videoFacts, sample: sample, decode: decode)
    }

    /// ffprobe can't open the file: one Problem row, the rest not run.
    static func unopenableCard(detail: String, sizeBytes: Int64, at date: Date) -> MediaReportCard {
        let reason = "the file can't be opened"
        let rows = MediaCheckKind.allCases.map { kind -> MediaCheck in
            guard kind == .truncation else { return .notRun(kind, because: reason) }
            return MediaCheck(kind: .truncation, verdict: .problem,
                              sentence: "It can't be opened: \(detail).",
                              evidence: [MediaEvidence("File size", V.sizeText(sizeBytes))],
                              fix: V.recommendation(for: [.unopenable(detail: detail)]))
        }
        return MediaReportCard(tier: .quick, checkedAt: date, fileSizeBytes: sizeBytes,
                               headline: "Can't be opened: \(detail).", checks: rows)
    }

    static func card(tier: MediaReportCard.Tier, checks: [MediaCheck],
                     quick: CheckMediaQuickInputs, at date: Date) -> MediaReportCard {
        MediaReportCard(tier: tier, checkedAt: date,
                        fileSizeBytes: quick.facts.sizeBytes ?? quick.videoFacts.fileSizeBytes,
                        headline: headline(checks: checks, quick: quick, tier: tier),
                        checks: checks)
    }

    /// The verdict sentence at the top of the card.
    static func headline(checks: [MediaCheck], quick: CheckMediaQuickInputs,
                         tier: MediaReportCard.Tier) -> String {
        let problems = checks.filter { $0.verdict == .problem }
        if let timing = timingHeadline(problems: problems, quick: quick) { return timing }
        if let first = problems.first { return problemHeadline(first) }
        let warnings = checks.filter { $0.verdict == .warning }
        if !warnings.isEmpty {
            let titles = warnings.prefix(3).map { $0.kind.title.lowercased() }.joined(separator: ", ")
            return "Plays, with \(warnings.count) thing\(warnings.count == 1 ? "" : "s") to look at: \(titles)."
        }
        if checks.allSatisfy({ if case .notRun = $0.verdict { return true }; return false }) {
            return "Couldn't be checked."
        }
        return tier == .quick ? quickPassHeadline : fullPassHeadline
    }

    /// A quick check that found nothing is NOT a clean bill of health
    /// (Rick 2026-10-07: "Looks healthy" was shown for a file whose sound
    /// stutters). Never "fine", "healthy" or "OK" for the quick tier.
    static let quickPassHeadline = MediaReportCard.quickPassHeadline
    /// Only a full check, every row OK or not run (each row says why).
    static let fullPassHeadline =
        "Looks healthy — the full check read the whole file and found nothing wrong."

    /// The duplicate-frame / broken-timing headline (the CapeCod class).
    private static func timingHeadline(problems: [MediaCheck], quick: CheckMediaQuickInputs) -> String? {
        let timingKinds: Set<MediaCheckKind> = [.frameRate, .timestamps, .distinctFrames]
        guard problems.contains(where: { timingKinds.contains($0.kind) }) else { return nil }
        guard let fps = storedFPS(quick), fps > cameraFPS.upperBound else {
            return "Plays, but its timing is broken."
        }
        let factor = fps / V.referenceFPS(quick.videoFacts)
        return "Plays, but its timing is broken: ~\(V.fpsText(roundedForWords(fps))) fps — each real frame is stored ~\(V.factorText(factor)) times."
    }

    /// 59,999.6 → 60,000: two significant figures for a sentence.
    static func roundedForWords(_ x: Double) -> Double {
        guard x >= 100, x.isFinite else { return x }
        let magnitude = pow(10, floor(log10(x)) - 1)
        return (x / magnitude).rounded() * magnitude
    }

    private static func problemHeadline(_ c: MediaCheck) -> String {
        switch c.kind {
        case .truncation: return "Cut short: the file ends before its last frame."
        case .decode: return "Damaged picture: \(c.sentence)"
        case .sound: return "Damaged sound: \(c.sentence)"
        case .audioSamples: return "Plays at the wrong speed: \(c.sentence)"
        case .layout: return "Sound may stutter: \(c.sentence)"
        case .soundContinuity: return "Sound breaks up: \(c.sentence)"
        case .bitrate: return "Plays, but it is a broken encode: \(c.sentence)"
        default: return "Has a problem — \(c.kind.title.lowercased()): \(c.sentence)"
        }
    }

    /// Plain-text card (the MFO detail, the log and the report).
    static func text(of card: MediaReportCard) -> String {
        var lines = [card.displayHeadline, ""]
        for c in card.checks {
            lines.append("[\(c.verdict.word)] \(c.kind.title): \(c.sentence)")
            if !c.evidence.isEmpty {
                lines.append("    " + c.evidence.map { "\($0.label): \($0.value)" }.joined(separator: " · "))
            }
            if !c.fix.isEmpty, c.verdict.rank >= MediaCheckVerdict.warning.rank {
                lines.append("    Fix: \(c.fix)")
            }
        }
        return lines.joined(separator: "\n")
    }
}
