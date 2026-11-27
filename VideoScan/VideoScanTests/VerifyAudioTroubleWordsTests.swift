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
// leave. Since schema v1.16 (DECISIONS 2026-11-27) the stored status moves
// too: "attention" (orange) for the two, "damaged" (red) for real damage —
// and every gate (readiness, the no-usable-sound floor, the copy-family
// survivor pick, the Promote sound gate) refuses "attention" exactly as
// "damaged" (StoredAudioStatus.refusesLikeDamage). Nothing moves IN to any
// healthy or delete set.
//
// Pure: values in, values out. No file, no subprocess, no model.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private typealias S = MasterArchiveTestSupport
private typealias G = PromoteSoundGate

private let referenceWords =
    "Reference movie — the picture and sound are stored in other files, so this file alone does not play"
private let rebuildWords =
    "Sound needs rebuilding — qdm2 does not play on Apple (Repair… ▸ Rebuild Audio Track fixes it)"

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
    #expect(VerifyAudioJob.write(d, onto: r, at: Date(timeIntervalSince1970: 1_800_000_000)) == .stored)
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

    @Test("SAFETY: a reference movie / a sound that needs rebuilding is stored 'attention', real damage 'damaged' — both not ok, and readiness and the no-usable-sound floor refuse both")
    func storedStatusIsAttentionOrDamaged() {
        for (d, word) in [(referenceMovie(), "attention"), (needsRebuild(), "attention"), (shortAudio(), "damaged")] {
            #expect(d.verdict == .damaged && d.persistedStatus == word, "\(d.findings)")
            #expect(d.findings.contains(where: VerifyAudioRules.isDamage))
            let r = storedRow(d)
            #expect(r.audioVerifyStatus == word)
            #expect(StoredAudioStatus(r.audioVerifyStatus).refusesLikeDamage)
            #expect(ArchiveReadiness.lacksUsableSound(streamTypeRaw: StreamType.videoAndAudio.rawValue,
                                                      audioVerifyStatus: r.audioVerifyStatus,
                                                      audioVerifyNote: r.audioVerifyNote))
            #expect(ArchiveAngelAudioOutcome.from(d) == .damaged(d.persistedNote))
        }
    }

    @Test("SAFETY: Promote's sound gate refuses both exactly as before — sound-damaged, whatever the owner's tag or tick")
    func promoteGateStillRefuses() {
        let cases: [(AudioVerifyDiagnosis, String, AudioTrouble)] = [
            (referenceMovie(), "the picture and sound are stored in other files, so this file alone does not play", .referenceMovie),
            (needsRebuild(), "qdm2 does not play on Apple (Repair… ▸ Rebuild Audio Track fixes it)", .needsRebuild),
        ]
        for (d, words, trouble) in cases {
            #expect(G.finding(from: d) == .damaged(words, trouble: trouble))
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

    // MARK: The words table and legacy notes as shown

    @Test("the one table: every own detail is free of the em dash and the '; ' separator, and leads stay distinct")
    func wordsTableKeepsTheSeparatorRule() {
        for trouble in AudioTrouble.allCases {
            if let detail = trouble.ownDetail(codec: "qdm2") {
                #expect(!detail.contains("—") && !detail.contains(";"), "\(trouble): \(detail)")
            }
        }
        #expect(Set(AudioTrouble.allCases.map(\.noteLead)).count == AudioTrouble.allCases.count)
        #expect(VerifyAudioRules.damagedNotePrefix == "Damaged audio — ")
    }

    @Test("legacy notes and card sentences are SHOWN in today's words; real damage and today's notes are shown as stored")
    func legacyDisplay() {
        #expect(AudioTrouble.displayNote("Damaged audio — reference movie, media missing") == referenceWords)
        // A legacy codec note is shown as stored: today's incomplete decode stores the same words (Codex #372 closing).
        #expect(AudioTrouble.displayNote("Damaged audio — invalid codec (qdm2); silent audio")
                == "Damaged audio — invalid codec (qdm2); silent audio")
        let realDamage = "Damaged audio — invalid codec (qdm2); audio shorter than video (60s vs 600s)"
        #expect(AudioTrouble.displayNote(realDamage) == realDamage, "real damage beside an old codec stays damaged")
        for asStored in [referenceWords, rebuildWords, "silent audio", "", "Damaged audio — audio shorter than video (2s vs 10s)"] {
            #expect(AudioTrouble.displayNote(asStored) == asStored)
        }
        // Check Media rows and headlines stored before the change.
        #expect(AudioTrouble.displaySoundSentence("The sound is damaged: invalid codec (qdm2).")
                == "The sound is damaged: invalid codec (qdm2).")
        #expect(AudioTrouble.displaySoundSentence("Damaged sound: The sound is damaged: reference movie, media missing.")
                == referenceWords + ".")
        let damagedRow = "The sound is damaged: audio shorter than video (60s vs 600s)."
        #expect(AudioTrouble.displaySoundSentence(damagedRow) == damagedRow)
        #expect(AudioTrouble.displaySoundSentence("Damaged sound: " + damagedRow) == "Damaged sound: " + damagedRow)
        #expect(AudioTrouble.displaySoundSentence("The sound track is silent.") == "The sound track is silent.")
        // Shown, never stored: `notes:damaged` still finds a legacy row until it is verified again.
        let legacy = VideoRecord()
        legacy.audioVerifyStatus = "damaged"
        legacy.audioVerifyNote = "Damaged audio — reference movie, media missing"
        #expect(pfRecordMatchesQuery(legacy, query: "notes:damaged"))
    }

    @Test("Promote's refusal: real damage keeps its words; the Angel's row label no longer says damaged for any kind")
    func promoteWordsPerKind() {
        let real = G.decide(finding: G.finding(from: shortAudio()), mark: .absent, soundPartnerName: nil,
                            recordedYear: nil, digestPrefix: "", ownerAcceptsUnchecked: false)
        guard case .refuse(.damaged, let detail, let log) = real else { Issue.record("\(real)"); return }
        #expect(detail == "Not promoted — the sound is damaged: audio shorter than video (60s vs 600s). Right-click ▸ Repair… shows the fix. Nothing was copied.")
        #expect(log == "damaged sound (audio shorter than video (60s vs 600s)); nothing written")
        let ref = G.decide(finding: G.finding(from: referenceMovie()), mark: .absent, soundPartnerName: nil,
                           recordedYear: nil, digestPrefix: "", ownerAcceptsUnchecked: false)
        guard case .refuse(.damaged, let refDetail, _) = ref else { Issue.record("\(ref)"); return }
        #expect(refDetail.hasPrefix("Not promoted — this is a reference movie: "))
        #expect(ArchiveAngelPromoter.soundRefusalWords(code: "sound-damaged", detail: refDetail)
                == "Sound not usable as it stands — " + refDetail)
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

// MARK: - Reviewer RED tests (2026-11-25, fix/audio-damaged-wording @ 662ed5c28)

@Suite("Verify Audio words — reviewer findings")
@MainActor
struct VerifyAudioTroubleWordsReviewTests {

    /// Pins VerifyAudioProbe.swift:348 (`referenceMovieNote`) and :508
    /// (`troubleLead` for needsRebuild): the stored note is "fragments
    /// joined with '; '" (note(for:) :486), and ArchiveReadiness.swift:321
    /// and :395 split it on ";". A lead that carries its own "; " turns one
    /// finding into two fragments — the same rule the em-dash comment keeps
    /// for the prefix.
    @Test("REVIEW: a self-naming lead is ONE '; '-fragment, as every finding is")
    func leadsDoNotCarryTheFragmentSeparator() {
        for d in [referenceMovie(), needsRebuild(), needsRebuild([.silentAudio])] {
            let pieces = d.persistedNote.split(separator: ";")
            #expect(pieces.count == d.findings.count, "\(d.persistedNote)")
        }
    }

    /// Pins PromoteSoundGate.swift:233 (and ArchiveAngelPromoter.swift:262,
    /// which wraps it as "Needs repair: sound damaged — …"): the same file
    /// the catalog now calls a reference movie / a sound that needs
    /// rebuilding is refused at Promote as "the sound is damaged". The
    /// refusal (code .damaged) must stand; only the words are wrong.
    @Test("REVIEW: Promote's refusal words do not call a reference movie or a needs-rebuild codec damaged")
    func promoteRefusalWordsFollowTheTrouble() {
        for d in [referenceMovie(), needsRebuild()] {
            let decision = G.decide(finding: G.finding(from: d), mark: .absent, soundPartnerName: nil,
                                    recordedYear: 1975, digestPrefix: "abc", ownerAcceptsUnchecked: false)
            guard case .refuse(let code, let detail, _) = decision else {
                Issue.record("must refuse: \(decision)"); continue
            }
            #expect(code == .damaged)
            #expect(!detail.lowercased().contains("damaged"), "\(detail)")
        }
    }

    /// Pins ArchiveAngelReadinessExplanation.swift:329-330: a row verified
    /// BEFORE this branch still stores "Damaged audio — reference movie,
    /// media missing" / "Damaged audio — invalid codec (qdm2)", and nothing
    /// re-verifies it, so the Sound line keeps saying "Damaged" for exactly
    /// the files the change was for until Rick re-runs Verify Audio.
    @Test("REVIEW: a legacy stored note for a reference movie / old codec does not read 'Damaged'")
    func legacyNotesReadInTheirOwnWords() {
        // The legacy "invalid codec" half of this finding was superseded by Codex #372 closing: that note is also
        // today's incomplete-decode (real damage) note, so it is shown as stored (legacyCodecNoteIsNeutral).
        for legacy in ["Damaged audio — reference movie, media missing"] {
            var f = ArchiveAngelRowFacts(id: UUID(), filename: "a.mov", fullPath: "/Volumes/X/a.mov", kind: .ready)
            f.audioVerifyStatus = "damaged"
            f.audioVerifyNote = legacy
            f.audio = .verifiedProblem(legacy)
            let value = ArchiveAngelReadinessExplanation.make(f).facts.first { $0.label == "Sound" }?.value ?? ""
            #expect(!value.lowercased().contains("damaged"), "\(value)")
        }
    }
}

// MARK: - Codex #372

/// QDM2 whose levels pass ran but decoded only 60 of 600 stated seconds
/// (Codex #372 P0's input): the finding is still `.unsupportedCodec(decodable:
/// true)`, but nothing says a rebuild would recover the missing 540 s.
private func shortDecodedOldCodec() -> AudioVerifyDiagnosis {
    S.soundDiagnosis(channels: [-18, -20], levelsComplete: false,
                     shortDecode: AudioShortDecode(missingSeconds: 540, statedSeconds: 600),
                     extraFindings: [.unsupportedCodec(codec: "qdm2", decodable: true)])
}

@Suite("Verify Audio words — Codex #372")
@MainActor
struct VerifyAudioTroubleWordsCodexTests {

    @Test("P0: 'needs rebuilding' only for a COMPLETE decode; an incomplete one keeps today's damaged words and notes:damaged")
    func incompleteDecodeNeverPromisesRebuild() throws {
        let d = shortDecodedOldCodec()
        #expect(d.levelsPass != .complete, "fixture: the decode came up short")
        #expect(d.verdict == .damaged && d.persistedStatus == "damaged", "stored status unchanged")
        #expect(d.trouble == .damaged)
        #expect(d.persistedNote == "Damaged audio — invalid codec (qdm2)", "\(d.persistedNote)")
        #expect(!d.persistedNote.contains("fixes it"))
        #expect(pfRecordMatchesQuery(storedRow(d), query: "notes:damaged"))
        // Promote's words: damaged, no repair promise (code unchanged).
        let decision = G.decide(finding: G.finding(from: d), mark: .absent, soundPartnerName: nil,
                                recordedYear: nil, digestPrefix: "", ownerAcceptsUnchecked: false)
        guard case .refuse(let code, let detail, _) = decision else { Issue.record("\(decision)"); return }
        #expect(code == .damaged)
        #expect(detail.contains("the sound is damaged") && !detail.contains("fixes it"), "\(detail)")
        // Check Media's row says damaged too.
        let row = CheckMediaRules.checkSound(.success(d), facts: try CheckMediaFixtures.healthy().facts)
        #expect(row.verdict == .problem && row.sentence.hasPrefix("The sound is damaged: "), "\(row.sentence)")
        // Closing pass: a fresh incomplete-decode note is indistinguishable from a legacy one, so where it is
        // SHOWN it stays damaged too (tooltip, Angel line, Check Media row and headline).
        #expect(AudioTrouble.displayNote(d.persistedNote).hasPrefix("Damaged audio — "), "\(AudioTrouble.displayNote(d.persistedNote))")
        #expect(AudioTrouble.displaySoundSentence(row.sentence).hasPrefix("The sound is damaged: "),
                "\(AudioTrouble.displaySoundSentence(row.sentence))")
        // The same codec decoded in full still reads as repairable.
        #expect(needsRebuild().trouble == .needsRebuild)
    }

    @Test("P0 + closing: a legacy 'invalid codec' note is shown as stored — it cannot be told from today's incomplete decode")
    func legacyCodecNoteIsNeutral() {
        let stored = "Damaged audio — invalid codec (qdm2)"
        #expect(AudioTrouble.displayNote(stored) == stored)
        #expect(!AudioTrouble.displayNote(stored).contains("fixes it"))
        #expect(AudioTrouble.displaySoundSentence("The sound is damaged: invalid codec (qdm2).")
                == "The sound is damaged: invalid codec (qdm2).")
        #expect(AudioTrouble.displaySoundSentence("Damaged sound: The sound is damaged: invalid codec (qdm2).")
                == "Damaged sound: The sound is damaged: invalid codec (qdm2).")
        // The legacy reference-movie note still reads as one (a dref is not a decode question).
        #expect(AudioTrouble.displayNote("Damaged audio — reference movie, media missing") == referenceWords)
    }
}
