// ArchiveSoundMarkTests.swift
// The Archive tab's yellow "no sound" mark (Rick 2026-10-23): every archived
// video dated 1980 or later (or undated) should have sound; before 1980
// silence is normal.
//
//   LOGIC   the policy's silent-track cells (date × pair × measured), the
//           exact cutoff, and that "not measured" is never read as silent.
//   TRUTH   the mark comes only from a stored FULL Verify measurement for
//           the file's current size; a quick card, a stale card, or an old
//           card without the field draws nothing. A date change after the
//           check is judged live, never from the stored row.
//   CARD    Verify's Sound row follows the policy for a silent track, keeps
//           the measured levels as evidence, never softens a Problem; the
//           new card field survives encode/decode and old cards decode nil.
//   SCALE   100k records judged inside the time budget.
//   (Media matrix: the measurement is the existing Verify levels pass,
//   covered by its own matrix; this change adds no decode.)

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func record(_ name: String, stream: StreamType = .videoAndAudio, year: String? = nil,
                    size: Int64 = 1_000) -> VideoRecord {
    let r = VideoRecord()
    r.filename = name
    r.fullPath = "/Volumes/test_Archive/\(name)"
    r.directory = "/Volumes/test_Archive"
    r.streamTypeRaw = stream.rawValue
    r.sizeBytes = size
    if let year { r.userDate = year }
    return r
}

private func card(tier: MediaReportCard.Tier = .full, size: Int64 = 1_000, silent: Bool?) -> MediaReportCard {
    var c = MediaReportCard(tier: tier, checkedAt: Date(timeIntervalSince1970: 1_800_000_000), fileSizeBytes: size,
                            headline: "x", checks: [])
    c.soundMeasuredSilent = silent
    return c
}

@Suite("Archive sound mark — policy, silent track")
struct ArchiveSoundMarkPolicyTests {

    private func silent(_ year: Int?, partner: String? = nil) -> SoundPresence {
        SoundPresencePolicy.assess(hasPicture: true, hasSound: true, soundMeasuredSilent: true,
                                   context: SoundPresenceContext(recordedYear: year, yearSource: .userDate,
                                                                 soundPartnerName: partner))
    }

    @Test func before1980ASilentTrackIsNormal() {
        #expect(silent(1965) == .silentFilmEra(year: 1965, source: .userDate))
        #expect(silent(1979).verdict == .ok)
    }

    @Test func from1980ASilentTrackIsAWarningWithItsOwnWords() {
        let p = silent(1980)
        #expect(p == .silentTrack(year: 1980, source: .userDate))
        #expect(p.isWarning)
        #expect(p.headline == "No sound — the sound track is silent")
        #expect(p.sentence == "No sound — the sound track is silent. It dates from 1980 (from your date), "
                + "and home video after 1980 normally has sound.")
        #expect(p.fix == SoundPresencePolicy.silentTrackFix)
    }

    @Test func undatedIsTreatedAsAfter1980() {
        #expect(silent(nil) == .silentTrack(year: nil, source: .none))
        #expect(silent(nil).isWarning)
    }

    @Test func aKnownSoundPartnerExcusesASilentTrack() {
        #expect(silent(1995, partner: "test_A01.wav") == .videoHalfOfPair(soundFile: "test_A01.wav"))
    }

    @Test func soundThatWasHeardOrNeverMeasuredIsNotApplicable() {
        let ctx = SoundPresenceContext(recordedYear: 1995, yearSource: .userDate)
        #expect(SoundPresencePolicy.assess(hasPicture: true, hasSound: true, soundMeasuredSilent: false, context: ctx)
                == .notApplicable)
        #expect(SoundPresencePolicy.assess(hasPicture: true, hasSound: true, context: ctx) == .notApplicable,
                "the default is 'not measured silent'")
        #expect(SoundPresencePolicy.assess(hasPicture: false, hasSound: true, soundMeasuredSilent: true, context: ctx)
                == .notApplicable, "no picture: not this rule's business")
    }

    @Test func theNoTrackCellsAreUnchanged() {
        let p = SoundPresencePolicy.assess(hasPicture: true, hasSound: false, soundMeasuredSilent: true,
                                           context: SoundPresenceContext(recordedYear: 2009, yearSource: .userDate))
        #expect(p == .noSound(year: 2009, source: .userDate), "no track stays 'no audio track', whatever the flag")
        #expect(p.fix == SoundPresencePolicy.noSoundFix)
    }
}

@Suite("Archive sound mark — truth: only a stored full measurement marks")
struct ArchiveSoundMarkTruthTests {

    @Test func aFullCardMeasuredSilentMarksAPost1980Video() {
        let r = record("1987-xx-xx_test_Birthday.mov", year: "1987")
        r.mediaReportCard = card(silent: true)
        #expect(r.measuredSoundPresence == .silentTrack(year: 1987, source: .userDate))
    }

    @Test func aPre1980SilentVideoIsNotMarked() {
        let r = record("1965-xx-xx_test_Reel.mov", year: "1965")
        r.mediaReportCard = card(silent: true)
        #expect(!r.measuredSoundPresence.isWarning)
    }

    @Test func noMeasurementIsNeverSilence() {
        let r = record("1999-xx-xx_test_Clip.mov", year: "1999")
        #expect(r.measuredSoundPresence == .notApplicable, "no card")
        r.mediaReportCard = card(silent: nil)
        #expect(r.measuredSoundPresence == .notApplicable, "a card saved before the field existed")
        r.mediaReportCard = card(tier: .quick, silent: true)
        #expect(r.measuredSoundPresence == .notApplicable, "a quick card never decoded the sound")
        r.mediaReportCard = card(size: 2_000, silent: true)
        #expect(r.measuredSoundPresence == .notApplicable, "a card for another size is stale")
        r.mediaReportCard = card(silent: false)
        #expect(r.measuredSoundPresence == .notApplicable, "measured sound")
    }

    @Test func aDateChangeAfterTheCheckIsJudgedLive() {
        let r = record("test_Reel.mov", year: "1985")
        r.mediaReportCard = card(silent: true)
        #expect(r.measuredSoundPresence.isWarning)
        r.userDate = "1972"
        #expect(!r.measuredSoundPresence.isWarning, "re-dated before 1980: silence is now normal, no re-Verify")
    }

    @Test func aPost1980VideoWithNoTrackIsMarkedFromTheCatalogAlone() {
        let r = record("2004-xx-xx_test_DVD.m2v", stream: .videoOnly, year: "2004")
        #expect(r.measuredSoundPresence == .noSound(year: 2004, source: .userDate))
    }

    @Test func aSourceRowIsJudgedByItsArchiveCopy() {
        let source = record("test_src.mov", year: "1990")
        let copy = record("1990-xx-xx_test_src.mov", year: "1990")
        copy.mediaReportCard = card(silent: true)
        #expect(ArchiveSoundMark.judged(source, copy: copy) === copy)
        #expect(ArchiveSoundMark.judged(source, copy: copy).measuredSoundPresence.isWarning)
        #expect(ArchiveSoundMark.judged(copy, copy: nil) === copy)
    }
}

@Suite("Archive sound mark — Verify card")
struct ArchiveSoundMarkCardTests {

    private static func facts() -> MediaFacts {
        var f = MediaFacts()
        f.streams = [MediaStreamFacts(index: 0, kind: .video), MediaStreamFacts(index: 1, kind: .audio)]
        return f
    }

    private static let silentRow = MediaCheck(kind: .sound, verdict: .warning, sentence: "The sound track is silent.",
                                              evidence: [MediaEvidence("Left", "−72 dB average, −61 dB peak")])

    private static func diagnosis(_ channels: [AudioChannelLevels]) -> AudioVerifyDiagnosis {
        var d = AudioVerifyDiagnosis(findings: [], shape: AudioVerifyShape(), balanceAnalysis: nil)
        let shape = AudioBalanceStreamShape(
            videoCodec: "h264", totalStreams: 2, videoStreams: 1, audioStreams: 1, audioCodec: "aac",
            audioChannels: channels.count, audioBitRate: nil, durationSeconds: 60,
            audioStreamInfos: [AudioBalanceStreamInfo(absoluteIndex: 1, codec: "aac", channels: channels.count, bitRate: nil)])
        d.balanceAnalysis = AudioBalanceAnalysis(
            classification: .trueStereo,
            measurements: AudioBalanceMeasurements(channels: channels, differenceRMSDBFS: nil),
            shape: shape, programStreamCount: 1, programStreamIndex: 1, droppedStreamIndices: [])
        d.balanceAnalysis?.levelsComplete = true
        return d
    }

    @Test func theMeasurementIsReadFromTheLevelsPassAtTheAppsFloor() {
        func measured(_ rms: [Double]) -> Bool? {
            let d = Self.diagnosis(rms.map { AudioChannelLevels(rmsDBFS: $0, peakDBFS: $0 + 10) })
            return CheckMediaRules.soundMeasuredSilent(CheckMediaFullInputs(audio: .success(d)))
        }
        #expect(measured([-.infinity, -.infinity]) == true)
        #expect(measured([-68, -70]) == true, "the CapeCod −68 dB case: below the −60 floor")
        #expect(measured([-68, -20]) == false, "one channel with sound is sound")
        #expect(measured([]) == nil, "no channels: not measured")
        #expect(CheckMediaRules.soundMeasuredSilent(CheckMediaFullInputs(audio: .failure(CheckMediaSkip(reason: "x"))))
                == nil)
        #expect(CheckMediaRules.soundMeasuredSilent(CheckMediaFullInputs()) == nil)
    }

    @Test func post1980TheRowIsAWarningAndKeepsTheLevels() throws {
        let checks = CheckMediaRules.applyingSoundPresence([Self.silentRow], facts: Self.facts(), soundMeasuredSilent: true,
                                                           context: SoundPresenceContext(recordedYear: 1991, yearSource: .filename))
        let row = try #require(checks.first)
        #expect(row.verdict == .warning)
        #expect(row.sentence.hasPrefix(SoundPresencePolicy.silentTrackTitle))
        #expect(row.evidence.contains(MediaEvidence("Left", "−72 dB average, −61 dB peak")), "the measurement stays")
        #expect(row.evidence.contains(MediaEvidence("Dated", "1991 (its name)")))
        #expect(!CheckMediaRules.isNoSoundRow(row), "not the no-track row: no sound-copy lookup for a present track")
    }

    @Test func before1980TheRowIsOK() throws {
        let checks = CheckMediaRules.applyingSoundPresence([Self.silentRow], facts: Self.facts(), soundMeasuredSilent: true,
                                                           context: SoundPresenceContext(recordedYear: 1962, yearSource: .userDate))
        let row = try #require(checks.first)
        #expect(row.verdict == .ok)
        #expect(row.sentence == "Silent (normal for film before 1980). Dated 1962, from your date.")
    }

    @Test func damagedSoundIsNeverSoftened() {
        let damaged = MediaCheck(kind: .sound, verdict: .problem, sentence: "The sound is damaged: x.")
        let checks = CheckMediaRules.applyingSoundPresence([damaged], facts: Self.facts(), soundMeasuredSilent: true,
                                                           context: SoundPresenceContext(recordedYear: 1962, yearSource: .userDate))
        #expect(checks == [damaged])
    }

    @Test func notMeasuredLeavesTheSoundPassRow() {
        let ok = MediaCheck(kind: .sound, verdict: .ok, sentence: "The sound plays at a healthy level on every channel.")
        for flag in [nil, false] as [Bool?] {
            #expect(CheckMediaRules.applyingSoundPresence([ok], facts: Self.facts(), soundMeasuredSilent: flag,
                                                          context: .unknown) == [ok])
        }
    }

    /// Codex P0-1 (2026-10-24): the astats parser fills a channel whose
    /// RMS line is missing or unreadable with −∞. That is a parse gap, not
    /// a measurement, and must never become "measured silent".
    @Test func aChannelWhoseLoudnessWasNeverReadIsNotMeasured() {
        func measured(_ stderr: String) -> Bool? {
            let channels = AstatsOutputParser.perChannelLevels(fromStderr: stderr)
            return CheckMediaRules.soundMeasuredSilent(CheckMediaFullInputs(audio: .success(Self.diagnosis(channels))))
        }
        let p = "[Parsed_astats_0 @ 0x1] "
        #expect(measured(p + "Channel: 1\n" + p + "Peak level dB: -4.0\n") == nil, "no RMS line")
        #expect(measured(p + "Channel: 1\n" + p + "Peak level dB: -4.0\n" + p + "RMS level dB: garbled\n") == nil,
                "an unreadable RMS value")
        #expect(measured(p + "Channel: 2\n" + p + "Peak level dB: -inf\n" + p + "RMS level dB: -inf\n") == nil,
                "channel 1 was never reported")
        #expect(measured(p + "Channel: 1\n" + p + "Peak level dB: -inf\n" + p + "RMS level dB: -inf\n") == true,
                "an explicit -inf is real digital silence")
        #expect(measured(p + "Channel: 1\n" + p + "Peak level dB: -50\n" + p + "RMS level dB: -66.2\n") == true)
    }

    /// Codex round 2 (2026-10-24), P0-2: "nan" parses as a Double but is
    /// not a level; never silence.
    @Test func nanIsNotAMeasurement() {
        let p = "[Parsed_astats_0 @ 0x1] "
        let channels = AstatsOutputParser.perChannelLevels(fromStderr: p + "Channel: 1\n" + p + "RMS level dB: nan\n")
        #expect(CheckMediaRules.soundMeasuredSilent(CheckMediaFullInputs(audio: .success(Self.diagnosis(channels)))) == nil)
    }

    /// Codex round 2, P0-1: the levels pass measured EVERY audio stream and
    /// every declared channel, or the file is not measured — a silent stream
    /// 0 beside an unreadable stream 1 is not "measured silent".
    @Test func aPartialMultiStreamMeasurementIsNotSilence() {
        let silent = AudioChannelLevels(rmsDBFS: -.infinity, peakDBFS: -.infinity)
        let gap = AudioChannelLevels(rmsDBFS: -.infinity, peakDBFS: -.infinity, rmsMeasured: false)
        #expect(!AudioBalanceProbe.levelsComplete(perStream: [[silent, silent], [gap, gap]], declaredChannels: [2, 2]),
                "stream 1 never reported RMS")
        #expect(!AudioBalanceProbe.levelsComplete(perStream: [[silent]], declaredChannels: [2]),
                "a declared trailing channel is missing")
        #expect(!AudioBalanceProbe.levelsComplete(perStream: [[silent, silent]], declaredChannels: [2, 2]),
                "a declared stream was never measured")
        #expect(!AudioBalanceProbe.levelsComplete(perStream: [], declaredChannels: []), "nothing measured")
        #expect(AudioBalanceProbe.levelsComplete(perStream: [[silent, silent], [silent]], declaredChannels: [2, 0]),
                "every stream, every declared channel (0 = unknown count)")
        var d = Self.diagnosis([silent, silent])
        d.balanceAnalysis?.levelsComplete = false
        #expect(CheckMediaRules.soundMeasuredSilent(CheckMediaFullInputs(audio: .success(d))) == nil,
                "an incomplete levels pass is not stored as silence")
    }

    /// Codex round 2, P0-3: Verify's own Sound row never calls an
    /// unmeasured channel "silent".
    @Test func verifysSoundRowNeverCallsAGapSilent() throws {
        let p = "[Parsed_astats_0 @ 0x1] "
        let channels = AstatsOutputParser.perChannelLevels(fromStderr: p + "Channel: 1\n" + p + "Peak level dB: -4.0\n")
        let row = CheckMediaRules.checkSound(.success(Self.diagnosis(channels)), facts: Self.facts())
        #expect(!row.sentence.lowercased().contains("silent"), "\(row.sentence)")
        #expect(!row.evidence.contains { $0.value == "silent" }, "\(row.evidence)")
        #expect(row.verdict != .ok && row.verdict != .warning, "not measured is not a verdict: \(row.verdict)")
    }

    /// Codex round 2, P1-4: a Problem card is never hidden behind the
    /// yellow no-sound banner.
    @Test func aProblemCardIsNotHiddenByTheNoSoundBanner() {
        let card = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1_000, headline: "The picture is damaged.",
                                   checks: [MediaCheck(kind: .decode, verdict: .problem, sentence: "The picture is damaged.")])
        #expect(DiagnosticBanner.noSound(recordID: UUID(), card: card, presence: .silentTrack(year: 1990, source: .userDate),
                                         advice: nil) == nil)
        let warnOnly = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1_000, headline: "x", checks: [])
        #expect(DiagnosticBanner.noSound(recordID: UUID(), card: warnOnly, presence: .silentTrack(year: 1990, source: .userDate),
                                         advice: nil) != nil, "without a Problem the banner still shows")
    }

    @Test func theFieldRoundTripsAndOldCardsDecodeNil() throws {
        let enc = JSONEncoder(), dec = JSONDecoder()
        let c = card(silent: true)
        #expect(try dec.decode(MediaReportCard.self, from: enc.encode(c)).soundMeasuredSilent == true)
        var old = try #require(try JSONSerialization.jsonObject(with: enc.encode(card(silent: nil))) as? [String: Any])
        old.removeValue(forKey: "soundMeasuredSilent")
        let decoded = try dec.decode(MediaReportCard.self, from: JSONSerialization.data(withJSONObject: old))
        #expect(decoded.soundMeasuredSilent == nil)
    }
}

/// Codex P0-2 (2026-10-24): Get Info must judge a measured-silent track
/// against the CURRENT date, as the Archive mark does — in both directions —
/// and must never soften damaged sound.
@MainActor
@Suite("Archive sound mark — Get Info agrees")
struct ArchiveSoundMarkGetInfoTests {

    private func fullCard(soundRow: MediaCheck, silent: Bool = true) -> MediaReportCard {
        var c = MediaReportCard(tier: .full, checkedAt: Date(timeIntervalSince1970: 1_800_000_000), fileSizeBytes: 1_000,
                                headline: soundRow.verdict == .ok ? "Looks healthy." : soundRow.sentence,
                                checks: [MediaCheck(kind: .decode, verdict: .ok, sentence: "Every frame decoded cleanly."),
                                         soundRow])
        c.soundMeasuredSilent = silent
        return c
    }

    private static let okSilentFilmRow = MediaCheck(kind: .sound, verdict: .ok,
                                                    sentence: "Silent (normal for film before 1980). Dated 1975, from your date.")
    private static let warnSilentRow = MediaCheck(kind: .sound, verdict: .warning,
                                                  sentence: "No sound — the sound track is silent. It dates from 1990 (from your date), "
                                                  + "and home video after 1980 normally has sound.")

    private func shown(_ r: VideoRecord) -> (SoundPresence, MediaCheckVerdict, String) {
        let presence = CheckMediaRules.getInfoSoundPresence(record: r, probed: nil)
        let card = r.mediaReportCard ?? MediaReportCard(tier: .quick, checkedAt: Date(), fileSizeBytes: 0,
                                                        headline: "no card", checks: [])
        return (presence, SoundPresencePolicy.displayVerdict(card: card, presence: presence),
                SoundPresencePolicy.displayHeadline(card: card, presence: presence))
    }

    @Test func redatedFrom1975To1990GetInfoWarnsLikeTheArchive() {
        let r = record("test_reel.mov", year: "1990")
        r.mediaReportCard = fullCard(soundRow: Self.okSilentFilmRow)
        let (presence, verdict, headline) = shown(r)
        #expect(presence == r.measuredSoundPresence, "Get Info and the Archive mark ask the same question")
        #expect(presence.isWarning)
        #expect(verdict == .warning)
        #expect(headline == "No sound — the sound track is silent.")
    }

    @Test func redatedFrom1990To1975GetInfoNoLongerWarns() {
        let r = record("test_reel.mov", year: "1975")
        r.mediaReportCard = fullCard(soundRow: Self.warnSilentRow)
        let (presence, verdict, headline) = shown(r)
        #expect(!presence.isWarning)
        #expect(verdict == .ok, "the stale silent-track warning is judged with today's date")
        #expect(headline == "Silent (normal for film before 1980).")
    }

    @Test func damagedSoundIsNeverSoftenedByARedate() {
        let r = record("test_reel.mov", year: "1975")
        r.mediaReportCard = fullCard(soundRow: MediaCheck(kind: .sound, verdict: .problem, sentence: "The sound is damaged: x."))
        #expect(shown(r).1 == .problem)
    }

    @Test func theProbedPathCarriesTheMeasurementToo() {
        let r = record("test_reel.mov", year: "1990")
        r.mediaReportCard = fullCard(soundRow: Self.okSilentFilmRow)
        var f = MediaFacts()
        f.streams = [MediaStreamFacts(index: 0, kind: .video), MediaStreamFacts(index: 1, kind: .audio)]
        #expect(CheckMediaRules.getInfoSoundPresence(record: r, probed: f) == .silentTrack(year: 1990, source: .userDate))
    }

    @Test func aNoTrackFileKeepsItsOwnWords() {
        let r = record("test_dvd.m2v", stream: .videoOnly, year: "2004")
        r.mediaReportCard = fullCard(soundRow: .notRun(.sound, because: "this file has no sound track"), silent: false)
        #expect(shown(r).2 == "No sound — this copy has no audio track.")
    }
}

/// Codex round 2, P1-6: every app surface asks the MEASURED answer; the
/// unmeasured `catalogSoundPresence` is only the bridge's building block.
@Suite("Archive sound mark — one question everywhere")
struct ArchiveSoundMarkOneQuestionTests {
    @Test func noAppSurfaceAsksTheUnmeasuredPresence() throws {
        let appRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("VideoScan")
        let files = try #require(FileManager.default.enumerator(at: appRoot, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
        try #require(files.count > 100, "the app source folder moved (\(files.count) files)")
        let stray = try files.flatMap { url in
            try String(contentsOf: url, encoding: .utf8).split(separator: "\n", omittingEmptySubsequences: false)
                .enumerated().filter { $0.element.contains(".catalogSoundPresence")
                    && !$0.element.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .map { "\(url.lastPathComponent):\($0.offset + 1)" }
        }
        #expect(stray.isEmpty, "use measuredSoundPresence (stored measurement + live date): \(stray)")
    }
}

@Suite("Archive sound mark — scale")
struct ArchiveSoundMarkScaleTests {

    @Test func hundredThousandRowsInsideTheBudget() {
        let rows: [VideoRecord] = (0..<100_000).map { i in
            // One name for all: a number in the name could be read as a year.
            let r = record("test_clip.mov", year: i % 3 == 0 ? "1975" : (i % 3 == 1 ? "1992" : nil))
            r.mediaReportCard = card(silent: i % 2 == 0)
            return r
        }
        let clock = ContinuousClock()
        var warnings = 0
        let elapsed = clock.measure {
            for r in rows where r.measuredSoundPresence.isWarning { warnings += 1 }
        }
        // Even rows are silent; of those, years 1992 and undated warn (2 of every 3).
        let expected = (0..<100_000).filter { $0 % 2 == 0 && $0 % 3 != 0 }.count
        #expect(warnings == expected)
        #expect(elapsed < .seconds(3), "100k rows judged in \(elapsed) (Debug budget 3 s)")
    }
}
