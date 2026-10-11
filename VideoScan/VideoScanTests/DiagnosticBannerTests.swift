// DiagnosticBannerTests.swift
// "No sound" as a flag Rick can't miss, and Repair… as its one door
// (Rick 2026-10-10).
//
//   LOGIC   the banner from a card: sound / no sound / may-be / pair half /
//           pre-1980; the Get Info guard over a stale card; the multi-file
//           count chip; the Repair prefill carrying the candidate into the
//           plan, the selection and the recipe (ticked ONLY on a measured
//           length match; a may-be is unticked with "run a full Verify
//           first"); the add-sound proof on tallies.
//   The real-ffmpeg media matrix and the Verify → Repair sensor are in
//   DiagnosticBannerMediaTests.swift.

import Foundation
import SwiftUI
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Shared values

enum DiagnosticBannerFixtures {

    static let pictureID = UUID()

    static func candidate(_ name: String = "Thanksgiving2009-Blu-ray.ac3", seconds: Double = 5422,
                          path: String? = nil) -> SoundCopyCandidate {
        SoundCopyCandidate(id: UUID(), filename: name, fullPath: path ?? "/Volumes/RAID/Thanksgiving/\(name)",
                           volume: "RAID", durationSeconds: seconds, isArchiveCopy: false,
                           electionKey: DuplicateKeeperPolicy.ElectionKey(availability: 2, precedence: 1,
                                                                          humanMetadata: 0, technical: 0, path: ""),
                           relation: "sound file")
    }

    /// A same-folder sound file: measured (length delta) or a may-be (nil).
    static func pair(delta: Double?, audio: SoundCopyCandidate = candidate()) -> SoundPairCandidate {
        SoundPairCandidate(audio: audio, sameFolder: true, sameFootage: false, sameNameStart: true, lengthDelta: delta)
    }

    /// A Verify card whose Sound track row is what SoundPresencePolicy
    /// writes for `presence` (the CheckMediaRules row), or a sound-pass row.
    static func card(_ presence: SoundPresence?) -> MediaReportCard {
        let soundRow: MediaCheck
        if let presence, let verdict = presence.verdict, let sentence = presence.sentence {
            soundRow = MediaCheck(kind: .sound, verdict: verdict, sentence: sentence, fix: presence.fix)
        } else {
            soundRow = MediaCheck(kind: .sound, verdict: .ok, sentence: "The sound plays at a healthy level on every channel.")
        }
        return MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1, headline: "",
                               checks: [MediaCheck(kind: .decode, verdict: .ok, sentence: "Every frame decoded cleanly."),
                                        soundRow])
    }

    static let noSound2009 = SoundPresence.noSound(year: 2009, source: .filename)
}

// MARK: - The banner from a card

@Suite("Diagnostic banner — No sound from a card")
struct DiagnosticBannerNoSoundTests {

    typealias F = DiagnosticBannerFixtures

    @Test func aFileWithSoundGetsNoBanner() {
        #expect(DiagnosticBanner.noSound(recordID: F.pictureID, card: F.card(nil), advice: nil) == nil)
    }

    @Test func noSoundIsAYellowWarningWithTheSymbolHeadlineAndRepair() throws {
        let b = try #require(DiagnosticBanner.noSound(recordID: F.pictureID, card: F.card(F.noSound2009), advice: nil))
        #expect(b.severity == .warning)
        #expect(b.symbol == "speaker.slash.fill")
        #expect(b.headline == "No sound")
        #expect(b.nextStep == "No matching sound found yet \u{2014} Repair\u{2026} can look for one.")
        #expect(b.action == .repair(MediaRepairPrefill(recordID: F.pictureID, soundSource: nil)))
        #expect(b.action?.title == "Repair\u{2026}")
        #expect(DiagnosticSeverity.warning.tint == .yellow)
        #expect(DiagnosticSeverity.warning.symbolColor == .black, "never yellow-on-white text: black symbol on the yellow badge")
    }

    @Test func aMeasuredMatchNamesTheFileAndCarriesIt() throws {
        let p = F.pair(delta: 0.03)
        let b = try #require(DiagnosticBanner.noSound(recordID: F.pictureID, card: F.card(F.noSound2009),
                                                      advice: .combine(p)))
        #expect(b.nextStep == "Its sound is probably Thanksgiving2009-Blu-ray.ac3 (same folder, same length). Use Repair\u{2026} to add it.")
        #expect(b.action == .repair(MediaRepairPrefill(recordID: F.pictureID, soundSource: .measured(p))))
    }

    @Test func aMaybeAsksForAFullVerifyFirst() throws {
        let p = F.pair(delta: nil)
        let b = try #require(DiagnosticBanner.noSound(recordID: F.pictureID, card: F.card(F.noSound2009),
                                                      advice: .maybeCombine(p)))
        #expect(b.nextStep.hasPrefix("Its sound may be Thanksgiving2009-Blu-ray.ac3 (same folder, length not measured yet)."))
        #expect(b.nextStep.contains("Run a full Verify first"))
        #expect(!b.nextStep.contains("probably"))
        #expect(b.action == .repair(MediaRepairPrefill(recordID: F.pictureID, soundSource: .maybe(p))))
    }

    @Test func pairHalfAndPre1980GetNoBanner() {
        let pair = F.card(.videoHalfOfPair(soundFile: "test_A01.mxf"))
        let film = F.card(.silentFilmEra(year: 1972, source: .userDate))
        #expect(DiagnosticBanner.noSound(recordID: F.pictureID, card: pair, advice: nil) == nil)
        #expect(DiagnosticBanner.noSound(recordID: F.pictureID, card: film, advice: nil) == nil)
        #expect(DiagnosticBanner.noSound(recordID: F.pictureID, card: film,
                                         presence: .silentFilmEra(year: 1972, source: .userDate), advice: nil) == nil)
    }

    /// Get Info over a card written before the rule (no no-sound row):
    /// the live assessment still raises the banner.
    @Test func theLiveAssessmentWinsOverAStaleCard() {
        let stale = MediaReportCard(tier: .full, checkedAt: Date(), fileSizeBytes: 1,
                                    headline: CheckMediaRules.fullPassHeadline,
                                    checks: [.notRun(.sound, because: "this file has no sound track")])
        #expect(DiagnosticBanner.noSound(recordID: F.pictureID, card: stale, advice: nil) == nil)
        #expect(DiagnosticBanner.noSound(recordID: F.pictureID, card: stale, presence: F.noSound2009, advice: nil) != nil)
        #expect(DiagnosticBanner.noSound(recordID: F.pictureID, card: nil, presence: F.noSound2009, advice: nil) != nil,
                "never verified: still flagged")
    }

    @Test func aCopyWithSoundIsNamedAndRepairStillLooks() throws {
        let watch = F.candidate("Thanksgiving2009-ProRes.mov")
        let b = try #require(DiagnosticBanner.noSound(recordID: F.pictureID, card: F.card(F.noSound2009),
                                                      advice: .watch(watch)))
        #expect(b.nextStep.contains("Thanksgiving2009-ProRes.mov (RAID)"))
        #expect(b.action == .repair(MediaRepairPrefill(recordID: F.pictureID, soundSource: nil)),
                "a copy to watch is not a sound file to add; the Repair sheet looks itself")
    }

    @Test func verdictsMapToSeverities() {
        #expect(DiagnosticSeverity(verdict: .problem) == .error)
        #expect(DiagnosticSeverity(verdict: .warning) == .warning)
        #expect(DiagnosticSeverity(verdict: .ok) == nil)
        #expect(DiagnosticSeverity(verdict: .notRun(reason: "x")) == nil)
    }
}

// MARK: - The Verify job's count chip

@Suite("Diagnostic banner — Verify job count")
struct NoSoundSummaryTests {

    typealias F = DiagnosticBannerFixtures

    static func item(_ outcome: CheckMediaItem.Outcome) -> CheckMediaItem {
        CheckMediaItem(id: UUID(), filename: "test_clip", outcome: outcome)
    }

    @Test func countsOnlyCheckedFilesWithTheNoSoundRow() {
        let items = [Self.item(.checked(F.card(F.noSound2009))), Self.item(.checked(F.card(nil))),
                     Self.item(.checked(F.card(F.noSound2009))), Self.item(.failed("unreadable")),
                     Self.item(.checked(F.card(.silentFilmEra(year: 1970, source: .userDate))))]
        let s = NoSoundSummary(items)
        #expect(s == NoSoundSummary(affected: 2, total: 5))
        #expect(s.chipText == "2 of 5 have no sound")
        #expect(items.filter { $0.banner != nil }.count == 2, "each affected item has its own banner")
    }

    @Test func singularAndNone() {
        #expect(NoSoundSummary(affected: 1, total: 5).chipText == "1 of 5 has no sound")
        #expect(NoSoundSummary(affected: 0, total: 5).chipText == nil)
        #expect(NoSoundSummary([Self.item(.waiting), Self.item(.cancelled)]).chipText == nil)
    }
}

// MARK: - Repair… carries the candidate

@Suite("Repair add sound — prefill, plan and recipe")
struct MediaRepairAddSoundPlanTests {

    typealias F = DiagnosticBannerFixtures

    private func offer(_ source: MediaRepairSoundSource?) -> MediaRepairOffer? {
        MediaRepairPlan.offers(for: F.card(F.noSound2009), sound: MediaRepairSoundFacts(), originalProtected: false,
                               soundSource: source).first { $0.fix == .addSound }
    }

    @Test func aMeasuredCandidateIsTickedAndBecomesTheRecipe() throws {
        let p = F.pair(delta: 0.03)
        let prefill = MediaRepairPrefill(recordID: F.pictureID, advice: .combine(p))
        let o = try #require(offer(prefill.soundSource))
        #expect(o.isAvailable && o.answers == .sound)
        let sel = MediaRepairSelection(offers: [o])
        #expect(sel.chosen == [.addSound], "ticked: a measured length match")
        let recipe = sel.recipe(balance: nil, soundFile: prefill.soundSource?.measured?.audio.fullPath)
        #expect(recipe.applied == [.addSound])
        #expect(recipe.addedSoundPath == p.audio.fullPath)
        #expect(recipe.fileExtension(sourceExtension: "m2v", audioCodec: "") == "mov")
        let args = recipe.ffmpegArgs(input: "/x/test_pic.m2v", output: "/x/test_pic_repaired.mov", picture: nil)
        #expect(args == CombineEngine.buildArgs(videoPath: "/x/test_pic.m2v", audioPath: p.audio.fullPath,
                                                outputPath: "/x/test_pic_repaired.mov", technique: .streamCopy,
                                                withProgress: true, progressPipe: "pipe:2"),
                "the Combine engine's own mux")
        #expect(args.contains("-c:v") && args.contains("copy") && !args.contains("libx264"), "nothing re-encoded")
        #expect(args.last == "/x/test_pic_repaired.mov")
        #expect(MediaRepairSelection.streamLines(recipe, picture: nil)
                .contains("Sound: added from Thanksgiving2009-Blu-ray.ac3 \u{2014} copied exactly, not re-encoded. The sound file is only read."))
    }

    @Test func aMaybeIsShownUntickedWithRunAFullVerifyFirst() throws {
        let o = try #require(offer(.maybe(F.pair(delta: nil))))
        #expect(!o.isAvailable)
        #expect(o.unavailableReason?.contains("run a full Verify first") == true)
        var sel = MediaRepairSelection(offers: [o])
        #expect(sel.chosen.isEmpty)
        sel.set(.addSound, on: true)
        #expect(sel.chosen.isEmpty, "can't be ticked by hand either")
    }

    @Test func nothingFoundOrNotLookedForCannotRun() {
        #expect(offer(.notFound)?.unavailableReason == MediaRepairSoundSource.notFoundReason)
        #expect(offer(nil)?.unavailableReason == MediaRepairSoundSource.notLookedForReason)
        #expect(offer(nil)?.answers == .sound, "still counts for the menu: Repair… opens and looks")
    }

    @Test func addSoundIsItsOwnPass() {
        let both = MediaRepairRecipe(fixes: [.addSound, .remux, .rebuildAudio], balance: nil, soundFile: "/x/test_s.ac3")
        #expect(both.applied == [.addSound])
        #expect(both.skipped.map(\.fix) == [.remux, .rebuildAudio])
        #expect(both.skipped.allSatisfy { $0.reason == MediaRepairRecipe.addSoundAloneReason })
        let noFile = MediaRepairRecipe(fixes: [.addSound, .remux], balance: nil)
        #expect(noFile.applied == [.remux])
        #expect(noFile.skipped.first?.fix == .addSound)
        #expect(noFile.addedSoundPath == nil)
    }

    @Test func moreRepairsNeverAddsSoundToAFileThatHasIt() {
        let r = MediaRepairPlan.allOffers(for: nil, sound: MediaRepairSoundFacts(), hasPicture: true, hasSound: true,
                                          soundSource: .measured(F.pair(delta: 0)))
        #expect(r.first { $0.fix == .addSound }?.unavailableReason == "This file already has sound.")
    }

    @Test func theFreeSpaceCheckCountsTheSoundFile() {
        let recipe = MediaRepairRecipe(fixes: [.addSound], balance: nil, soundFile: "/x/test_s.ac3")
        let need = MediaRepairEngine.requiredFreeBytes(recipe: recipe, sourceBytes: 1_000, durationSeconds: 10,
                                                       addedSoundBytes: 500)
        #expect(need == 1_500 + MediaRepairEngine.headroomBytes)
    }

    @Test func anUnreachableSoundFileIsRefusedBeforeAnyWrite() {
        var facts = MediaRepairPreflightFacts()
        facts.addedSoundExists = false
        let req = MediaRepairRequest(sourcePath: "/x/test_pic.m2v", sourceSizeBytes: 1, sourceDurationSeconds: 1,
                                     output: URL(fileURLWithPath: "/x/test_pic_repaired.mov"),
                                     recipe: MediaRepairRecipe(fixes: [.addSound], balance: nil, soundFile: "/y/test_s.ac3"),
                                     outputProtectionNote: nil, archiveCheck: nil)
        #expect(MediaRepairEngine.refusal(req, facts: facts)?.hasPrefix("The sound file isn't reachable") == true)
    }

    // MARK: The proof, on tallies

    private func tally(_ i: Int, _ type: String, _ codec: String, packets: Int, bytes: Int64, ticks: Int64 = 0) -> MediaStreamTally {
        MediaStreamTally(index: i, codecType: type, codec: codec, secondsPerTick: 1.0 / 90_000, sampleRate: nil,
                         packets: packets, bytes: bytes, durationTicks: ticks)
    }

    @Test func theProofIsThePictureUntouchedPlusTheSoundTrack() {
        // Measured 2026-10-10 on a 6 s m2v + ac3: the same bytes and frames;
        // the sound's ticks differ (1/90000 in the .ac3, 1/44100 in the .mov).
        let pic = [tally(0, "video", "mpeg2video", packets: 180, bytes: 289_955)]
        let snd = [MediaStreamTally(index: 0, codecType: "audio", codec: "ac3", secondsPerTick: 1.0 / 90_000,
                                    sampleRate: 44_100, packets: 173, bytes: 144_612, durationTicks: 542_182)]
        let good = [tally(0, "video", "mpeg2video", packets: 180, bytes: 289_955),
                    MediaStreamTally(index: 1, codecType: "audio", codec: "ac3", secondsPerTick: 1.0 / 44_100,
                                     sampleRate: 44_100, packets: 173, bytes: 144_612, durationTicks: 265_728)]
        guard case .identical = MediaRepairParity.compareAddedSound(picture: pic, sound: snd, output: good) else {
            Issue.record("the measured m2v + ac3 mux must pass"); return
        }
        let changedPicture = [tally(0, "video", "mpeg2video", packets: 179, bytes: 289_955), good[1]]
        let noSound = [good[0]]
        let wrongCodec = [good[0], tally(1, "audio", "aac", packets: 173, bytes: 144_612)]
        let cutSound = [good[0], tally(1, "audio", "ac3", packets: 173, bytes: 144_000)]
        for bad in [changedPicture, noSound, wrongCodec, cutSound] {
            if case .identical = MediaRepairParity.compareAddedSound(picture: pic, sound: snd, output: bad) {
                Issue.record("must fail: \(bad)")
            }
        }
    }
}
