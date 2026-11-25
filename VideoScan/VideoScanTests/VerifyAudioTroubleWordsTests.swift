// VerifyAudioTroubleWordsTests.swift
// Rick 2026-11-25 ("fix the wording — it helps when looking through vast
// numbers of files"): on the 1,043-file corpus sample 55 files read
// audio=damaged, but 36 were only QuickTime REFERENCE MOVIES (the picture and
// sound live in other files) and 7 were an old sound codec Apple can't play
// that ffmpeg decodes (Rebuild Audio Track fixes it). Neither is damage.
//
// What moves: the WORDS (the stored note, the Verify Audio sheet headline,
// the Check Media Sound row, the Archive Angel sound line, the corpus word)
// and therefore the `notes:damaged` batch-delete query, which these files
// leave. What does not move: the stored status ("damaged" — the schema's only
// not-ok value), so readiness, the copy-family survivor pick, the red row and
// the Promote sound gate treat both exactly as before. Nothing moves IN to
// any healthy or delete set.
//
// Pure: values in, values out. No file, no subprocess, no model.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias S = MasterArchiveTestSupport
private typealias G = PromoteSoundGate

private let referenceWords =
    "Reference movie — the picture and sound are stored in other files; this file alone does not play"
private let rebuildWords =
    "Sound needs rebuilding — qdm2 does not play on Apple; Repair… ▸ Rebuild Audio Track fixes it"

/// A reference movie as the probe reports it: no audio stream of its own,
/// the dref finding alone, nothing decoded.
private func referenceMovie() -> AudioVerifyDiagnosis {
    var d = S.soundDiagnosis(channels: [], audioStreams: 0)
    d.findings = [.referenceMovie(referencedPaths: ["/Avid MediaFiles/x — on drive “Media250”"])]
    return d
}

/// An old codec that ffmpeg decoded in full (levels measured, stereo).
private func needsRebuild(_ extra: [AudioVerifyFinding] = []) -> AudioVerifyDiagnosis {
    S.soundDiagnosis(channels: [-18, -20], extraFindings: [.unsupportedCodec(codec: "qdm2", decodable: true)] + extra)
}

private func shortAudio() -> AudioVerifyDiagnosis {
    S.soundDiagnosis(channels: [-18, -20], extraFindings: [.durationMismatch(audioSeconds: 60, videoSeconds: 600)])
}

/// A catalog row carrying what Verify Audio's one writer stores for `d`.
@MainActor
private func storedRow(_ d: AudioVerifyDiagnosis) -> VideoRecord {
    let r = VideoRecord()
    #expect(VerifyAudioJob.write(d, onto: r, at: Date(timeIntervalSince1970: 1_800_000_000)))
    return r
}

@Suite("Verify Audio words — a reference movie and a sound that needs rebuilding are not 'damaged'")
@MainActor
struct VerifyAudioTroubleWordsTests {

    // MARK: The stored note (the catalog tooltip, the notes: query, Media Info)

    @Test("a reference movie's note says what it is, and never 'damaged'")
    func referenceMovieNote() {
        let note = referenceMovie().persistedNote
        #expect(note == referenceWords)
        #expect(!note.lowercased().contains("damaged"), "\(note)")
    }

    @Test("an old codec ffmpeg decodes reads as repairable: needs rebuilding, with the fix named")
    func needsRebuildNote() {
        #expect(needsRebuild().persistedNote == rebuildWords)
        // Honest states beside it follow, as before.
        #expect(needsRebuild([.silentAudio]).persistedNote == rebuildWords + "; silent audio")
        #expect(!needsRebuild().persistedNote.lowercased().contains("damaged"))
    }

    @Test("real damage still reads damaged, and outranks a needs-rebuild codec beside it")
    func realDamageUnchanged() {
        #expect(shortAudio().persistedNote == "Damaged audio — audio shorter than video (60s vs 600s)")
        let both = needsRebuild([.durationMismatch(audioSeconds: 60, videoSeconds: 600)])
        #expect(both.persistedNote == "Damaged audio — invalid codec (qdm2); audio shorter than video (60s vs 600s)")
    }

    // MARK: Out of the batch-delete query, nothing in

    @Test("`notes:damaged` (the #128 batch-delete find) no longer lists them; it still lists real damage")
    func batchDeleteQuery() {
        #expect(!pfRecordMatchesQuery(storedRow(referenceMovie()), query: "notes:damaged"))
        #expect(!pfRecordMatchesQuery(storedRow(needsRebuild()), query: "notes:damaged"))
        #expect(pfRecordMatchesQuery(storedRow(shortAudio()), query: "notes:damaged"))
        // And each has its own find.
        #expect(pfRecordMatchesQuery(storedRow(referenceMovie()), query: "notes:reference"))
        #expect(pfRecordMatchesQuery(storedRow(needsRebuild()), query: "notes:rebuilding"))
    }

    @Test("SAFETY: the stored status stays 'damaged' (not ok) — readiness and the no-usable-sound floor read them as before")
    func storedStatusDoesNotMove() {
        for d in [referenceMovie(), needsRebuild(), shortAudio()] {
            #expect(d.verdict == .damaged && d.persistedStatus == "damaged", "\(d.findings)")
            #expect(d.findings.contains(where: VerifyAudioRules.isDamage))
            let r = storedRow(d)
            #expect(r.audioVerifyStatus == "damaged")
            #expect(ArchiveReadiness.lacksUsableSound(streamTypeRaw: StreamType.videoAndAudio.rawValue,
                                                      audioVerifyStatus: r.audioVerifyStatus,
                                                      audioVerifyNote: r.audioVerifyNote))
            #expect(ArchiveAngelAudioOutcome.from(d) == .damaged(d.persistedNote))
        }
    }

    @Test("SAFETY: Promote's sound gate refuses both exactly as before — sound-damaged, whatever the owner's tag or tick")
    func promoteGateStillRefuses() {
        let cases: [(AudioVerifyDiagnosis, String)] = [(referenceMovie(), "reference movie, media missing"),
                                                       (needsRebuild(), "invalid codec (qdm2)")]
        for (d, words) in cases {
            #expect(G.finding(from: d) == .damaged(words))
            for mark in [G.Mark.absent, .accepted, .notTiedToTheseBytes] {
                for tick in [false, true] {
                    let decision = G.decide(finding: G.finding(from: d), mark: mark, soundPartnerName: nil,
                                            recordedYear: 1975, digestPrefix: "abc", ownerAcceptsUnchecked: tick)
                    guard case .refuse(let code, _, _) = decision else {
                        Issue.record("\(words): must refuse (mark \(mark), tick \(tick)): \(decision)"); continue
                    }
                    #expect(code == .damaged && code.rawValue == "sound-damaged")
                }
            }
        }
    }

    // MARK: The Verify Audio sheet's headline

    @Test("the sheet's headline: only real damage says damaged; real damage outranks the rest in a mixed list")
    func sheetHeadline() {
        #expect(referenceMovie().trouble == .referenceMovie)
        #expect(needsRebuild().trouble == .needsRebuild)
        #expect(shortAudio().trouble == .damaged)
        #expect(needsRebuild([.durationMismatch(audioSeconds: 60, videoSeconds: 600)]).trouble == .damaged)
        #expect(S.soundDiagnosis(channels: [-18, -20]).trouble == nil)
        #expect(S.soundDiagnosis(channels: [-18, -20], extraFindings: [.unsupportedCodec(codec: "aac", decodable: false)])
            .trouble == nil, "a failed levels pass is could-not-check, never trouble (GH #468)")
        for trouble in AudioTrouble.allCases {
            #expect(trouble.sheetHeadline.lowercased().contains("damaged") == (trouble == .damaged), "\(trouble)")
        }
        #expect(AudioTrouble.needsRebuild.sheetHeadline.contains("Rebuild Audio Track"))
    }

    // MARK: Check Media's Sound row and the card headline

    @Test("Check Media: the Sound row stays a Problem (Repair… keeps Rebuild on offer) but says what it is")
    func checkMediaSoundRow() throws {
        let quick = try CheckMediaFixtures.healthy()
        let rebuild = CheckMediaRules.checkSound(.success(needsRebuild()), facts: quick.facts)
        #expect(rebuild.verdict == .problem)
        #expect(rebuild.sentence == rebuildWords + ".")
        #expect(!rebuild.sentence.lowercased().contains("damaged"))
        let headline = CheckMediaRules.headline(checks: [rebuild], quick: quick, tier: .full)
        #expect(!headline.lowercased().contains("damaged"), "\(headline)")
        let offer = MediaRepairPlan.offer(for: rebuild, sound: MediaRepairSoundFacts(diagnosis: needsRebuild()),
                                          originalProtected: false)
        #expect(offer?.fix == .rebuildAudio)

        let reference = CheckMediaRules.checkSound(.success(referenceMovie()), facts: quick.facts)
        #expect(reference.verdict == .problem)
        #expect(reference.sentence == referenceWords + ".")
        #expect(!CheckMediaRules.headline(checks: [reference], quick: quick, tier: .full).lowercased().contains("damaged"))

        let damaged = CheckMediaRules.checkSound(.success(shortAudio()), facts: quick.facts)
        #expect(damaged.verdict == .problem)
        #expect(damaged.sentence == "The sound is damaged: audio shorter than video (60s vs 600s).")
        #expect(CheckMediaRules.headline(checks: [damaged], quick: quick, tier: .full).lowercased().contains("damaged"))
    }

    // MARK: Archive Angel's Sound line

    @Test("Archive Angel's Sound line does not prefix 'Damaged' onto a reference movie or a needs-rebuild note")
    func archiveAngelSoundLine() {
        func sound(_ d: AudioVerifyDiagnosis) -> String? {
            var f = ArchiveAngelRowFacts(id: UUID(), filename: "a.mov", fullPath: "/Volumes/X/a.mov", kind: .ready)
            f.audioVerifyStatus = d.persistedStatus
            f.audioVerifyNote = d.persistedNote
            f.audio = .verifiedProblem(d.persistedNote)
            return ArchiveAngelReadinessExplanation.make(f).facts.first { $0.label == "Sound" }?.value
        }
        #expect(sound(referenceMovie()) == referenceWords)
        #expect(sound(needsRebuild()) == rebuildWords)
        #expect(sound(shortAudio()) == "Damaged — audio shorter than video (60s vs 600s)")
    }
}
