import Foundation
import VideoScanCore

// MARK: - Check Media — a picture with no sound track (Rick 2026-10-10)
//
// The bug: Verify called Thanksgiving2009-DVD.m2v (picture only, 2009)
// "Looks healthy". Every sound row said "Not checked — this file has no
// sound track", and a not-run row ranks BELOW OK, so the worst-wins
// headline fell through to the full-pass sentence.
//
// The fix: the "Sound track" row asks SoundPresencePolicy (VideoScanCore,
// the one rule) whenever the probe found a picture and no sound. After
// 1980 or undated → Warning "No sound — this copy has no audio track";
// a known A/V half or pre-1980 film → OK, with the reason in the sentence.
// The row carries the verdict, so the card's worst-wins verdict, the
// headline, the MFO summary, the log line and Get Info all follow from
// one place.

extension CheckMediaRules {

    /// `checks` with the Sound track row decided by the policy when the
    /// file has a picture and no sound track; unchanged otherwise (a file
    /// WITH sound keeps the levels/damage verdict the sound pass wrote).
    static func applyingSoundPresence(_ checks: [MediaCheck], facts: MediaFacts,
                                      soundMeasuredSilent: Bool? = nil,
                                      context: SoundPresenceContext) -> [MediaCheck] {
        if soundMeasuredSilent == true, facts.audio != nil {
            return applyingSilentTrack(checks, facts: facts, context: context)
        }
        guard let row = soundPresenceRow(facts: facts, context: context) else { return checks }
        guard checks.contains(where: { $0.kind == .sound }) else { return checks + [row] }
        return checks.map { $0.kind == .sound ? row : $0 }
    }

    /// A sound track that is there but measured silent (2026-10-23): the
    /// policy decides the Sound row — before 1980 OK ("Silent (normal for
    /// film before 1980)"), else Warning. The measured channel levels stay
    /// as evidence. A Problem row (damaged sound) is never softened.
    private static func applyingSilentTrack(_ checks: [MediaCheck], facts: MediaFacts,
                                            context: SoundPresenceContext) -> [MediaCheck] {
        let presence = SoundPresencePolicy.assess(hasPicture: facts.video != nil, hasSound: true,
                                                  soundMeasuredSilent: true, context: context)
        guard let verdict = presence.verdict, let sentence = presence.sentence,
              let existing = checks.first(where: { $0.kind == .sound }),
              existing.verdict.rank < MediaCheckVerdict.problem.rank else { return checks }
        var evidence = existing.evidence
        evidence.append(datedEvidence(context))
        let row = MediaCheck(kind: .sound, verdict: verdict, sentence: sentence, evidence: evidence, fix: presence.fix)
        return checks.map { $0.kind == .sound ? row : $0 }
    }

    /// Get Info's answer: the probe's streams once it has read the header,
    /// else the catalog's stream type — with the stored full-Verify sound
    /// measurement and the CURRENT date, the same question the Archive mark
    /// asks (Codex P0 2026-10-24). O(1).
    @MainActor
    static func getInfoSoundPresence(record: VideoRecord, probed: MediaFacts?) -> SoundPresence {
        guard let f = probed else { return record.measuredSoundPresence }
        return SoundPresencePolicy.assess(hasPicture: f.video != nil, hasSound: f.audio != nil,
                                          soundMeasuredSilent: record.soundMeasuredSilent,
                                          context: record.soundPresenceContext)
    }

    /// What the full check MEASURED on the sound track: true when every
    /// channel sits below the program floor, false when one carries sound,
    /// nil when not measured — no channels, or any channel whose RMS the
    /// levels pass never reported (a parse gap is not silence; Codex P0
    /// 2026-10-24).
    static func soundMeasuredSilent(_ full: CheckMediaFullInputs) -> Bool? {
        guard case .success(let d)? = full.audio, let analysis = d.balanceAnalysis, analysis.levelsComplete,
              case let channels = analysis.measurements.channels, !channels.isEmpty,
              channels.allSatisfy(\.rmsMeasured) else { return nil }
        return !channels.contains(where: AudioBalanceClassifier.carriesProgram)
    }

    private static func datedEvidence(_ context: SoundPresenceContext) -> MediaEvidence {
        if let year = context.recordedYear {
            return MediaEvidence("Dated", "\(year) (\(SoundPresencePolicy.words(for: context.yearSource)))")
        }
        return MediaEvidence("Dated", "unknown — treated as after 1980")
    }

    /// The policy's Sound track row, or nil when the file has sound (or no
    /// picture). Known from the header alone, so the quick tier says it too.
    static func soundPresenceRow(facts: MediaFacts, context: SoundPresenceContext) -> MediaCheck? {
        let presence = SoundPresencePolicy.assess(hasPicture: facts.video != nil, hasSound: facts.audio != nil,
                                                  context: context)
        guard let verdict = presence.verdict, let sentence = presence.sentence else { return nil }
        var evidence = [MediaEvidence("Sound tracks", "none")]
        evidence.append(datedEvidence(context))
        if let partner = context.soundPartnerName {
            evidence.append(MediaEvidence("Sound partner", partner))
        }
        return MediaCheck(kind: .sound, verdict: verdict, sentence: sentence, evidence: evidence, fix: presence.fix)
    }

    /// True for the policy's no-sound Warning row.
    static func isNoSoundRow(_ c: MediaCheck) -> Bool {
        c.kind == .sound && c.verdict == .warning && c.sentence.hasPrefix(SoundPresencePolicy.noSoundTitle)
    }

    /// The card carries the policy's no-sound Warning row. O(rows).
    static func hasNoSoundRow(_ card: MediaReportCard) -> Bool {
        card.checks.contains(where: isNoSoundRow)
    }

    /// The headline when the no-sound row is the most serious thing on the
    /// card (no Problem rows): it names the missing sound first, then any
    /// other warnings. nil when there is no such row.
    static func noSoundHeadline(warnings: [MediaCheck]) -> String? {
        guard warnings.contains(where: isNoSoundRow) else { return nil }
        let others = warnings.filter { !isNoSoundRow($0) }
        guard !others.isEmpty else { return SoundPresencePolicy.noSoundTitle + "." }
        let titles = others.prefix(3).map { $0.kind.title.lowercased() }.joined(separator: ", ")
        return SoundPresencePolicy.noSoundTitle + ". Also to look at: \(titles)."
    }

    /// The picture's length as the full check's packet census measured it
    /// (first to last picture packet), when there is one. nil for the quick
    /// tier or when the census did not run.
    static func measuredPictureSeconds(_ full: CheckMediaFullInputs) -> Double? {
        guard case .success(let census)? = full.census, let v = census.video,
              let first = v.firstSeconds, let end = v.endSeconds, end > first else { return nil }
        return end - first
    }
}
