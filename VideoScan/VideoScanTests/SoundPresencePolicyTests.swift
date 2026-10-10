// SoundPresencePolicyTests.swift
// LOGIC (CLAUDE.md feature-test checklist, 1) for the 2026-10-10 bug: Verify
// and Get Info called Thanksgiving2009-DVD.m2v (picture only, 2009) fine.
//
//   * The policy's truth table — sound present / absent × dated before
//     1980 / 1980 or later / undated × known A/V half yes / no — every
//     cell, with the exact words a person reads.
//   * The record bridge — the date comes from the shared RecordDateResolver
//     (your date › the file's stamp › best guess › the name), the pair from
//     a live audio-only partner only.
//   * Check Media — the Sound track row and the headline follow the policy;
//     a file WITH sound keeps the sound pass's own row.
//   * Get Info's display guard — a stale "Looks healthy" card never reads
//     as fine for a post-1980 picture with no sound.
//   * SoundCopyFinder.decide — archive copy first, never an offline drive,
//     the Combine offer only for a same-folder sound file of the same
//     length, "may be" when the picture's length was never measured.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - The truth table

@Suite("Sound presence — policy truth table")
struct SoundPresencePolicyTruthTableTests {

    enum DateCase: String, CaseIterable, Sendable { case before1980, from1980, unknown }

    static func context(_ d: DateCase, pair: Bool) -> SoundPresenceContext {
        let year: Int? = switch d {
        case .before1980: 1968
        case .from1980: 2009
        case .unknown: nil
        }
        return SoundPresenceContext(recordedYear: year, yearSource: .userDate,
                                    soundPartnerName: pair ? "test_clip_A01.mxf" : nil)
    }

    /// All 12 cells: sound × date × pair.
    @Test(arguments: [true, false], DateCase.allCases)
    func everyCell(hasSound: Bool, date: DateCase) {
        for pair in [true, false] {
            let p = SoundPresencePolicy.assess(hasPicture: true, hasSound: hasSound, context: Self.context(date, pair: pair))
            let label = "sound=\(hasSound) date=\(date) pair=\(pair)"
            if hasSound {
                #expect(p == .notApplicable, "\(label): a file with sound is the sound pass's business")
                #expect(p.verdict == nil && p.headline == nil, "\(label)")
                continue
            }
            if pair {
                #expect(p == .videoHalfOfPair(soundFile: "test_clip_A01.mxf"), "\(label)")
                #expect(p.verdict == .ok, "\(label): a known A/V half never reads as broken")
                #expect(p.headline == "Video half of a pair — its sound is in test_clip_A01.mxf", "\(label)")
                continue
            }
            switch date {
            case .before1980:
                #expect(p == .silentFilmEra(year: 1968, source: .userDate), "\(label)")
                #expect(p.verdict == .ok, "\(label): silent film before 1980 is normal")
                #expect(p.headline == "Silent (normal for film before 1980)", "\(label)")
                #expect(p.sentence == "Silent (normal for film before 1980). Dated 1968, from your date.", "\(label)")
            case .from1980:
                #expect(p == .noSound(year: 2009, source: .userDate), "\(label)")
                #expect(p.verdict == .warning, "\(label)")
                #expect(p.headline == "No sound — this copy has no audio track", "\(label)")
                #expect(p.sentence == "No sound — this copy has no audio track. It dates from 2009 (from your date), "
                        + "and home video after 1980 normally has sound.", "\(label)")
                #expect(!p.fix.isEmpty, "\(label)")
            case .unknown:
                #expect(p == .noSound(year: nil, source: .none), "\(label)")
                #expect(p.verdict == .warning, "\(label): undated is treated as after 1980")
                #expect(p.reason == "Its date is unknown, so it is treated as after 1980, when home video normally has sound.",
                        "\(label): and the words say so")
            }
        }
    }

    @Test func theCutoffIsExactly1980() {
        func at(_ y: Int) -> SoundPresence {
            SoundPresencePolicy.assess(hasPicture: true, hasSound: false,
                                       context: SoundPresenceContext(recordedYear: y, yearSource: .embedded))
        }
        #expect(at(1979).verdict == .ok)
        #expect(at(1980).verdict == .warning, "1980 itself is 'newer than 1980' territory — home video")
    }

    @Test func noPictureIsNotThisRulesBusiness() {
        for sound in [true, false] {
            #expect(SoundPresencePolicy.assess(hasPicture: false, hasSound: sound, context: .unknown) == .notApplicable)
        }
    }

    @Test func everySourceHasFamilyWords() {
        let sources: [RecordDateResolution.Source] = [.userDate, .embedded, .inferred, .filename, .none]
        #expect(sources.map(SoundPresencePolicy.words(for:)) ==
                ["your date", "the date stored in the file", "the catalog's best guess", "its name", "nowhere — it is undated"])
    }
}

// MARK: - The record bridge

@Suite("Sound presence — record bridge")
struct SoundPresenceRecordBridgeTests {

    static func videoOnly(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/test_V/\(name)"
        r.directory = "/Volumes/test_V"
        r.streamTypeRaw = StreamType.videoOnly.rawValue
        return r
    }

    @Test func theM2vReadsAsNoSoundDatedByItsName() {
        // The real file's catalog row: no user / embedded / inferred date,
        // so the year comes from "Thanksgiving2009" in its name.
        let r = Self.videoOnly("Thanksgiving2009-DVD.m2v")
        #expect(r.soundPresenceContext.recordedYear == 2009)
        #expect(r.soundPresenceContext.yearSource == .filename)
        #expect(r.catalogSoundPresence == .noSound(year: 2009, source: .filename))
        #expect(r.catalogSoundPresence.sentence ==
                "No sound — this copy has no audio track. It dates from 2009 (from its name), "
                + "and home video after 1980 normally has sound.")
    }

    @Test func yourDateWinsAndAPre1980DateMakesSilentFilmNormal() {
        let r = Self.videoOnly("test_reel_7.mov")
        r.userDate = "1968"
        #expect(r.catalogSoundPresence == .silentFilmEra(year: 1968, source: .userDate))
    }

    @Test func undatedIsTreatedAsAfter1980() {
        let r = Self.videoOnly("test_clip.mov")
        #expect(r.catalogSoundPresence == .noSound(year: nil, source: .none))
    }

    @Test func aLiveAudioOnlyPartnerMakesItAPairHalf() {
        let v = Self.videoOnly("test_V01.mxf")
        let a = VideoRecord()
        a.filename = "test_A01.mxf"
        a.streamTypeRaw = StreamType.audioOnly.rawValue
        v.pairedWith = a
        a.pairedWith = v
        #expect(v.catalogSoundPresence == .videoHalfOfPair(soundFile: "test_A01.mxf"))
        // A removed partner is not a sound anyone can play.
        a.purgedAt = Date()
        #expect(v.catalogSoundPresence.isWarning, "a purged partner does not excuse the missing sound")
    }

    @Test func aFileWithSoundIsNotApplicable() {
        let r = Self.videoOnly("test_ok.mp4")
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        #expect(r.catalogSoundPresence == .notApplicable)
    }
}

// MARK: - Check Media and Get Info

@Suite("Sound presence — Verify card and Get Info guard")
struct SoundPresenceCardTests {

    static func facts(sound: Bool) -> MediaFacts {
        var f = MediaFacts()
        f.streams = [MediaStreamFacts(index: 0, kind: .video)]
        if sound { f.streams.append(MediaStreamFacts(index: 1, kind: .audio)) }
        return f
    }

    static let healthyFullRows: [MediaCheck] = [
        MediaCheck(kind: .decode, verdict: .ok, sentence: "Every frame decoded cleanly."),
        .notRun(.sound, because: "this file has no sound track"),
    ]

    @Test func noSoundRowReplacesTheNotRunSoundRow() throws {
        let checks = CheckMediaRules.applyingSoundPresence(
            Self.healthyFullRows, facts: Self.facts(sound: false),
            context: SoundPresenceContext(recordedYear: 2009, yearSource: .filename))
        let row = try #require(checks.first { $0.kind == .sound })
        #expect(row.verdict == .warning)
        #expect(row.sentence.hasPrefix("No sound — this copy has no audio track."))
        #expect(row.evidence.contains(MediaEvidence("Dated", "2009 (its name)")))
        #expect(checks.count == Self.healthyFullRows.count, "replaced, not added")
        #expect(CheckMediaRules.isNoSoundRow(row))
    }

    @Test func theHeadlineNamesTheMissingSoundNotHealthy() {
        let checks = CheckMediaRules.applyingSoundPresence(Self.healthyFullRows, facts: Self.facts(sound: false), context: .unknown)
        let headline = CheckMediaRules.noSoundHeadline(warnings: checks.filter { $0.verdict == .warning })
        #expect(headline == "No sound — this copy has no audio track.")
        let withOther = checks + [MediaCheck(kind: .aspect, verdict: .warning, sentence: "odd shape")]
        #expect(CheckMediaRules.noSoundHeadline(warnings: withOther.filter { $0.verdict == .warning })
                == "No sound — this copy has no audio track. Also to look at: shape of the picture.")
    }

    @Test func aFileWithSoundKeepsTheSoundPassRow() {
        let row = MediaCheck(kind: .sound, verdict: .ok, sentence: "The sound plays at a healthy level on every channel.")
        let checks = CheckMediaRules.applyingSoundPresence([row], facts: Self.facts(sound: true), context: .unknown)
        #expect(checks == [row])
    }

    @Test func pairHalfAndSilentFilmAreOKWithTheReason() throws {
        let pair = CheckMediaRules.applyingSoundPresence(Self.healthyFullRows, facts: Self.facts(sound: false),
                                                         context: SoundPresenceContext(soundPartnerName: "test_A01.mxf"))
        #expect(pair.first { $0.kind == .sound }?.verdict == .ok)
        #expect(pair.first { $0.kind == .sound }?.sentence.hasPrefix("Video half of a pair — its sound is in test_A01.mxf") == true)
        let film = CheckMediaRules.applyingSoundPresence(Self.healthyFullRows, facts: Self.facts(sound: false),
                                                         context: SoundPresenceContext(recordedYear: 1972, yearSource: .userDate))
        #expect(film.first { $0.kind == .sound }?.sentence == "Silent (normal for film before 1980). Dated 1972, from your date.")
    }

    /// Get Info over a card saved BEFORE the fix (the real m2v's card says
    /// "Looks healthy"): the live policy wins over the stale all-clear.
    @Test func getInfoNeverShowsAStaleHealthyCardForANoSoundFile() {
        let stale = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1,
                                    headline: CheckMediaRules.fullPassHeadline, checks: Self.healthyFullRows)
        #expect(stale.verdict == .ok, "the bug: not-run sound rows rank below OK")
        let presence = SoundPresence.noSound(year: 2009, source: .filename)
        #expect(SoundPresencePolicy.displayHeadline(card: stale, presence: presence) == "No sound — this copy has no audio track.")
        #expect(SoundPresencePolicy.displayVerdict(card: stale, presence: presence) == .warning)
        // A worse card keeps its own words; a file with sound is untouched.
        let broken = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1, headline: "Cut short",
                                     checks: [MediaCheck(kind: .truncation, verdict: .problem, sentence: "cut")])
        #expect(SoundPresencePolicy.displayHeadline(card: broken, presence: presence) == "Cut short")
        #expect(SoundPresencePolicy.displayHeadline(card: stale, presence: .notApplicable) == CheckMediaRules.fullPassHeadline)
        #expect(SoundPresencePolicy.displayHeadline(card: stale, presence: .silentFilmEra(year: 1970, source: .userDate))
                == CheckMediaRules.fullPassHeadline, "pre-1980 film is fine")
    }

    @Test func theMeasuredPictureLengthComesFromTheCensus() {
        var tally = StreamTimingTally()
        tally.packets = 10
        tally.firstSeconds = 0.5
        tally.endSeconds = 5422.9
        let full = CheckMediaFullInputs(census: .success(PacketCensusReport(video: tally)))
        #expect(CheckMediaRules.measuredPictureSeconds(full) == 5422.4)
        #expect(CheckMediaRules.measuredPictureSeconds(CheckMediaFullInputs()) == nil)
    }
}

// MARK: - SoundCopyFinder.decide

@Suite("Sound copy finder — decide")
struct SoundCopyFinderDecideTests {

    static func key(_ precedence: Int, availability: Int = 2) -> DuplicateKeeperPolicy.ElectionKey {
        DuplicateKeeperPolicy.ElectionKey(availability: availability, precedence: precedence,
                                          humanMetadata: 0, technical: 0, path: "")
    }

    static func cand(_ name: String, volume: String, seconds: Double = 5422, archive: Bool = false,
                     precedence: Int = 1, availability: Int = 2) -> SoundCopyCandidate {
        SoundCopyCandidate(id: UUID(), filename: name, fullPath: "/Volumes/\(volume)/\(name)", volume: volume,
                           durationSeconds: seconds, isArchiveCopy: archive,
                           electionKey: key(precedence, availability: availability), relation: "same footage")
    }

    static func input(picture: Double?, copies: [SoundCopyCandidate] = [],
                      folder: [SoundCopyCandidate] = []) -> SoundCopyInput {
        SoundCopyInput(recordID: UUID(), filename: "Thanksgiving2009-DVD.m2v", pictureSeconds: picture,
                       copiesWithSound: copies,
                       soundFiles: folder.map { SoundPairSource(audio: $0, sameFolder: true, sameFootage: false) })
    }

    static let allConnected: (String) -> Bool = { _ in true }

    @Test func theArchiveCopyIsPreferred() {
        let raid = Self.cand("Thanksgiving2009-ProRes.mov", volume: "RAID", precedence: 9)
        let archive = Self.cand("2009-12-02_Thanksgiving2009Sequence.mov", volume: "FamilyArchive", archive: true, precedence: 1)
        let a = SoundCopyFinder.decide(Self.input(picture: nil, copies: [raid, archive]), isConnected: Self.allConnected)
        #expect(a == .watch(archive))
        #expect(a.line == "Watch the copy with sound: 2009-12-02_Thanksgiving2009Sequence.mov (FamilyArchive)")
    }

    @Test func thenTheKeeperPrecedence() {
        let ssd = Self.cand("a.mov", volume: "SSD", precedence: 1)
        let raid = Self.cand("b.mov", volume: "RAID", precedence: 5)
        #expect(SoundCopyFinder.decide(Self.input(picture: nil, copies: [ssd, raid]), isConnected: Self.allConnected) == .watch(raid))
    }

    @Test func neverAnOfflineDrive() {
        let offlineBest = Self.cand("a.mov", volume: "Away", archive: true, precedence: 9)
        let online = Self.cand("b.mov", volume: "Here", precedence: 1)
        let here: (String) -> Bool = { $0.hasPrefix("/Volumes/Here/") }
        #expect(SoundCopyFinder.decide(Self.input(picture: nil, copies: [offlineBest, online]), isConnected: here) == .watch(online))
        let none: (String) -> Bool = { _ in false }
        let a = SoundCopyFinder.decide(Self.input(picture: nil, copies: [offlineBest]), isConnected: none)
        #expect(a == .connect(offlineBest), "named, to connect — never chosen to watch")
        let retired = Self.cand("c.mov", volume: "Gone", precedence: 9, availability: 0)
        #expect(SoundCopyFinder.decide(Self.input(picture: nil, copies: [retired]), isConnected: Self.allConnected) == .none)
    }

    /// The .ac3 case: no copy with sound, the sound file beside it, the
    /// lengths agree (the full Verify measured the picture at 5,422.4 s).
    @Test func combineWithTheSameFolderSoundOfTheSameLength() {
        let ac3 = Self.cand("Thanksgiving2009-Blu-ray.ac3", volume: "SanDiskWorkspace", seconds: 5422.432)
        let short = Self.cand("Thanksgiving2009-intro.wav", volume: "SanDiskWorkspace", seconds: 30)
        let a = SoundCopyFinder.decide(Self.input(picture: 5422.4, folder: [short, ac3]), isConnected: Self.allConnected)
        guard case .combine(let p) = a else { Issue.record("\(a)"); return }
        #expect(p.audio == ac3)
        #expect(a.line == "Combine with its sound (Thanksgiving2009-Blu-ray.ac3) — same folder, same name start, "
                + "same length 1:30:22 (0.03 s apart)")
        #expect(SoundCopyFinder.decide(Self.input(picture: 5422.4, folder: [short]), isConnected: Self.allConnected) == .none,
                "a different length is never offered")
    }

    /// The real m2v before a re-Verify: no length anywhere, so only "may be".
    @Test func unmeasuredPictureOffersOnlyAMaybeBySameNameStart() {
        let ac3 = Self.cand("Thanksgiving2009-Blu-ray.ac3", volume: "SanDiskWorkspace", seconds: 5422.432)
        let other = Self.cand("Christmas2009.wav", volume: "SanDiskWorkspace", seconds: 5422.432)
        let a = SoundCopyFinder.decide(Self.input(picture: nil, folder: [other, ac3]), isConnected: Self.allConnected)
        guard case .maybeCombine(let p) = a else { Issue.record("\(a)"); return }
        #expect(p.audio == ac3 && !p.lengthMatches)
        #expect(a.line == "Its sound may be Thanksgiving2009-Blu-ray.ac3 — same folder, same name start, its sound runs "
                + "1:30:22; this picture's length isn't recorded yet. Run a full Verify… to measure this picture's "
                + "length, then it can be combined")
        #expect(SoundCopyFinder.decide(Self.input(picture: nil, folder: [other]), isConnected: Self.allConnected) == .none)
    }

    // MARK: SoundPairRanker (Rick 2026-10-10: "no audio pair" for the .m2v)

    /// TRUE POSITIVE, the m2v + ac3 shape: same folder, lengths 0.03 s apart.
    @Test func m2vAndItsAc3AreTheTopCandidate() {
        let ac3 = SoundPairSource(audio: Self.cand("Thanksgiving2009-Blu-ray.ac3", volume: "SanDiskWorkspace", seconds: 5422.432),
                                  sameFolder: true, sameFootage: false)
        let footage = SoundPairSource(audio: Self.cand("test_other_take.wav", volume: "RAID", seconds: 5423.0),
                                      sameFolder: false, sameFootage: true)
        let ranked = SoundPairRanker.rank(pictureName: "Thanksgiving2009-DVD.m2v", pictureSeconds: 5422.4,
                                          sources: [footage, ac3])
        #expect(ranked.map(\.audio.filename) == ["Thanksgiving2009-Blu-ray.ac3", "test_other_take.wav"],
                "closer length first")
        #expect(ranked.first?.reason == "same folder, same name start, same length 1:30:22 (0.03 s apart)")
        #expect(ranked[1].reason == "same footage group, same length 1:30:23 (0.60 s apart)")
    }

    /// NEAR MISS: same folder, same name start, a different length.
    @Test func sameFolderDifferentLengthIsNotACandidate() {
        let tolerance = SoundPairRanker.tolerance(5422.4)
        #expect(abs(tolerance - 5.4224) < 0.0001, "0.1 % of a 90-minute picture")
        let near = SoundPairSource(audio: Self.cand("Thanksgiving2009-Blu-ray.ac3", volume: "V",
                                                    seconds: 5422.4 + tolerance + 0.5),
                                   sameFolder: true, sameFootage: false)
        #expect(SoundPairRanker.rank(pictureName: "Thanksgiving2009-DVD.m2v", pictureSeconds: 5422.4, sources: [near]).isEmpty)
        let short = SoundPairSource(audio: Self.cand("a.wav", volume: "V", seconds: 2.0), sameFolder: true, sameFootage: false)
        #expect(SoundPairRanker.rank(pictureName: "b.m2v", pictureSeconds: 2.6, sources: [short]).isEmpty,
                "the half-second floor for short clips")
        let unknownSound = SoundPairSource(audio: Self.cand("Thanksgiving2009.wav", volume: "V", seconds: 0),
                                           sameFolder: true, sameFootage: false)
        #expect(SoundPairRanker.rank(pictureName: "Thanksgiving2009-DVD.m2v", pictureSeconds: 5422.4, sources: [unknownSound]).isEmpty,
                "a sound file of unknown length is never a measured match")
    }

    @Test func aCopyWithSoundBeatsCombining() {
        let copy = Self.cand("x.mov", volume: "RAID")
        let ac3 = Self.cand("Thanksgiving2009-Blu-ray.ac3", volume: "RAID", seconds: 5422.432)
        #expect(SoundCopyFinder.decide(Self.input(picture: 5422.4, copies: [copy], folder: [ac3]),
                                       isConnected: Self.allConnected) == .watch(copy))
    }

    @Test func nameStems() {
        #expect(SoundCopyFinder.nameStem("Thanksgiving2009-DVD.m2v") == "thanksgiving2009")
        #expect(SoundCopyFinder.nameStem("Thanksgiving2009-Blu-ray.ac3") == "thanksgiving2009")
        #expect(SoundCopyFinder.nameStem("A01.wav").isEmpty, "too short to mean anything")
    }
}
