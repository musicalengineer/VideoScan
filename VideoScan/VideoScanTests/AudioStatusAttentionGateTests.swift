// AudioStatusAttentionGateTests.swift — the two new stored sound words
// (DECISIONS 2026-11-27 item 2, schema v1.16 `v12_audio_status`):
//   "attention"  — a reference movie / a sound that needs rebuilding: every
//                  gate refuses it EXACTLY as "damaged"; the row is orange,
//                  never red;
//   "unverified" — a pre-fix "ok" withdrawn (#518): every reader treats it
//                  as NEVER verified, whatever date or note sits beside it.
// Dimensions:
//   logic      StoredAudioStatus parses every word; the writer stores
//              "attention" for the two troubles and "damaged" for real damage;
//              the tint;
//   gates      a parity table over EVERY reader of the status (grep
//              audioVerifyStatus): readiness (audio, sound standing, the
//              no-usable-sound floor, warnings), the copy-family keeper choice
//              and its cautions, Repair…'s damaged-audio set, Archive Angel's
//              needs / Checks outcome / reusable diagnosis, File Journey —
//              "attention" answers as "damaged", "unverified" as "" does;
//   isolation  poisoned stored words ("Damaged", " ok", "withdrawn", "garbage")
//              fail closed: never verified, never shown as damage, no tint;
//   scale      100k records through the shared reading inside a budget;
//   truth      the row shows "not verified" for a withdrawn verdict (Archive
//              Angel's sound line, readiness warning, File Journey).
// Media: N/A — no decode path is new; the reconfigured-pass detection runs on
// real media in SoundLevelsRemeasure's media tests.

import Foundation
import SwiftUI
import Testing
@testable import VideoScan
import VideoScanCore

private typealias S = MasterArchiveTestSupport

/// A catalog row with a stored sound verdict (and a dated, noted one when
/// asked — the "unverified" case carries both, and they must not count).
@MainActor
private func row(_ status: String, note: String = "", dated: Bool = true, path: String = "/Volumes/X/clip.mov") -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.isPlayable = "Yes"
    r.audioChannels = "2"
    r.audioVerifyStatus = status
    r.audioVerifyNote = note
    r.audioVerifyDate = dated && !status.isEmpty ? Date(timeIntervalSince1970: 1_800_000_000) : nil
    return r
}

private let referenceNote = "Reference movie — the picture and sound are stored in other files, so this file alone does not play"
private let withdrawnNote = StoredAudioStatus.unverifiedWords

/// Every reader's answer for one record, as one comparable value.
@MainActor
private struct Answers: Equatable {
    let audio: ArchiveReadiness.Audio
    let sound: ArchiveReadiness.SoundStanding
    let lacksUsableSound: Bool
    let inRepairDamagedSet: Bool
    let angelNeeds: [ArchiveAngelNeed]
    let angelCheck: ArchiveAngelCheckOutcome
    let familyCautions: [String]
    let reusesCachedDiagnosis: Bool

    init(_ r: VideoRecord) {
        let readiness = ArchiveReadiness.assess(record: r)
        audio = readiness.audio
        sound = readiness.sound
        lacksUsableSound = ArchiveReadiness.lacksUsableSound(streamTypeRaw: r.streamTypeRaw, audioVerifyStatus: r.audioVerifyStatus,
                                                             audioVerifyNote: r.audioVerifyNote)
        inRepairDamagedSet = !CatalogRowMenuRules.damagedAudio([r]).isEmpty
        angelNeeds = ArchiveAngelStatusWords.needs(ArchiveAngelRowFacts.make(record: r, evidence: nil, kind: .ready))
        angelCheck = ArchiveAngelChecks.verdictOutcome((r.audioVerifyStatus, r.audioVerifyNote))
        familyCautions = CopyFamilyAssessor.assess([CopyFamilyInput(fullPath: r.fullPath, durationSeconds: 60,
                                                                    audioVerifyStatus: r.audioVerifyStatus)]).cautions
        reusesCachedDiagnosis = ArchiveAngelAudioOutcome.reusableDiagnosis(
            storedStatus: r.audioVerifyStatus, cached: S.soundDiagnosis(channels: [-20, -21]), standing: readiness.sound) != nil
    }
}

@MainActor
@Suite("Stored sound words 'attention' and 'unverified' — every gate and reader")
struct AudioStatusAttentionGateTests {

    // MARK: Logic

    @Test("StoredAudioStatus reads every stored word; only 'damaged' and 'attention' refuse; only 'ok' is verified")
    func theReading() {
        let table: [(String, StoredAudioStatus, refuses: Bool, verified: Bool, tint: StoredAudioStatus.Tint)] = [
            ("", .neverVerified, false, false, .none),
            ("ok", .ok, false, true, .none),
            ("damaged", .damaged, true, false, .damaged),
            ("attention", .attention, true, false, .attention),
            ("unverified", .unverified, false, false, .none),
        ]
        for (word, status, refuses, verified, tint) in table {
            let s = StoredAudioStatus(word)
            #expect(s == status, "\(word)")
            #expect(s.refusesLikeDamage == refuses, "\(word)")
            #expect(s.isVerifiedOK == verified, "\(word)")
            #expect(s.tint == tint, "\(word)")
        }
        #expect(StoredAudioStatus.unverified.readsAsNeverVerified)
        #expect(!StoredAudioStatus.attention.readsAsNeverVerified)
        #expect(CatalogDDL.AudioCheckStatus.allCases.map(\.rawValue)
                == [StoredAudioStatus.okWord, StoredAudioStatus.damagedWord, StoredAudioStatus.attentionWord, StoredAudioStatus.unverifiedWord],
                "the app's words are the schema's CHECK list")
    }

    @Test("the writer stores 'attention' for a reference movie and a fully decoded needs-rebuild codec; 'damaged' for short audio and for an old codec whose decode came up short")
    func theWriterChoosesTheWord() {
        var reference = S.soundDiagnosis(channels: [], audioStreams: 0)
        reference.findings = [.referenceMovie(referencedPaths: ["/Avid MediaFiles/x"])]
        let rebuild = S.soundDiagnosis(channels: [-18, -20], extraFindings: [.unsupportedCodec(codec: "qdm2", decodable: true)])
        let short = S.soundDiagnosis(channels: [-18, -20], extraFindings: [.durationMismatch(audioSeconds: 60, videoSeconds: 600)])
        let rebuildShort = S.soundDiagnosis(channels: [-18, -20], shortDecode: AudioShortDecode(missingSeconds: 540, statedSeconds: 600),
                                            extraFindings: [.unsupportedCodec(codec: "qdm2", decodable: true)])
        #expect(reference.persistedStatus == "attention")
        #expect(rebuild.persistedStatus == "attention")
        #expect(short.persistedStatus == "damaged")
        #expect(rebuildShort.persistedStatus == "damaged", "needs rebuilding is only promised after a complete decode (Codex #372)")
        for d in [reference, rebuild, short, rebuildShort] {
            let r = VideoRecord()
            #expect(VerifyAudioJob.write(d, onto: r, at: Date()) == .stored)
            #expect(StoredAudioStatus(r.audioVerifyStatus).refusesLikeDamage)
        }
    }

    @Test("the row tint: 'attention' is orange (never red), 'damaged' red, 'unverified' as never verified")
    func theTint() {
        #expect(row("attention", note: referenceNote).rowColor == Color.orange.opacity(0.18))
        #expect(row("attention", note: referenceNote).filenameColor == .orange)
        #expect(row("damaged").rowColor == Color.red.opacity(0.15))
        #expect(row("damaged").filenameColor == .red)
        #expect(row("unverified", note: withdrawnNote).rowColor == row("").rowColor)
        #expect(row("unverified", note: withdrawnNote).filenameColor == row("").filenameColor)
        // Orange survives a softer disposition, like red does.
        let junk = row("attention", note: referenceNote)
        junk.mediaDisposition = .suspectedJunk
        #expect(junk.filenameColor == .orange)
    }

    // MARK: Gates — the parity table

    @Test("GATES: 'attention' gets EXACTLY the answers 'damaged' gets, from every reader (same note)")
    func attentionRefusesEverywhereDamagedDid() {
        let attention = Answers(row("attention", note: referenceNote))
        let damaged = Answers(row("damaged", note: referenceNote))
        #expect(attention == damaged)
        // …and those answers are refusals.
        #expect(attention.lacksUsableSound)
        #expect(attention.inRepairDamagedSet)
        #expect(attention.angelNeeds.contains(.audioRepair(note: referenceNote)))
        #expect(attention.angelCheck == .damaged(note: referenceNote))
        if case .refusable = attention.sound {} else { Issue.record("Promote's forecast does not refuse: \(attention.sound)") }
        #expect(attention.familyCautions.contains { $0.contains("problem with the sound") })
    }

    @Test("GATES: 'unverified' (dated, with its note) gets EXACTLY the answers a never-verified record gets — except Archive Angel Checks, which names the withdrawal")
    func unverifiedIsNeverVerified() {
        let unverified = Answers(row("unverified", note: withdrawnNote))
        let never = Answers(row("", dated: false))
        #expect(unverified.audio == never.audio)
        #expect(unverified.audio == .notVerified)
        #expect(unverified.sound == never.sound)
        #expect(unverified.sound == .notChecked)
        #expect(unverified.lacksUsableSound == never.lacksUsableSound)
        #expect(unverified.inRepairDamagedSet == never.inRepairDamagedSet)
        #expect(unverified.angelNeeds == never.angelNeeds)
        #expect(unverified.angelNeeds.contains(.audioCheck))
        #expect(unverified.familyCautions == never.familyCautions)
        #expect(unverified.familyCautions.contains { $0.contains("has not been verified") })
        #expect(!unverified.reusesCachedDiagnosis && !never.reusesCachedDiagnosis, "Prepare verifies again")
        guard case .failed(let why) = unverified.angelCheck else { Issue.record("\(unverified.angelCheck)"); return }
        #expect(why.contains("withdrawn"))
    }

    @Test("GATES: the keeper choice prefers a verified ok copy over an unverified one exactly as over a never-verified one")
    func keeperChoiceTreatsUnverifiedAsNeverVerified() {
        func pick(_ other: String) -> String? {
            let a = CopyFamilyInput(fullPath: "/Volumes/A/clip.mov", durationSeconds: 60, audioVerifyStatus: "ok")
            let b = CopyFamilyInput(fullPath: "/Volumes/B/clip.mov", durationSeconds: 60, audioVerifyStatus: other)
            return CopyFamilyAssessor.recommendedInstance([b, a])?.fullPath
        }
        #expect(pick("unverified") == "/Volumes/A/clip.mov")
        #expect(pick("unverified") == pick(""))
        #expect(pick("attention") == pick("damaged"))
    }

    // MARK: Truth — the UI says "not verified"

    @Test("TRUTH: a withdrawn verdict reads as not verified in the readiness warning, Archive Angel's sound line and File Journey")
    func theUISaysNotVerified() {
        let r = row("unverified", note: withdrawnNote)
        let readiness = ArchiveReadiness.assess(record: r)
        #expect(readiness.warnings.contains { $0.lowercased().contains("not checked") }, "\(readiness.warnings)")
        #expect(!readiness.warnings.contains { $0.contains("checked out") })
        let words = FileJourneyBuilder.verifyWords("Sound check", status: StoredAudioStatus(r.audioVerifyStatus).journeyWord, note: r.audioVerifyNote)
        #expect(words.hasPrefix("Sound check: withdrawn — "), "\(words)")
        #expect(words.contains("not verified"))
        #expect(!words.hasPrefix("Sound check: ok"))
    }

    // MARK: Isolation — poisoned words fail closed

    @Test("ISOLATION: a stored word this build cannot read is never verified, never damage, no tint — and the readers say 'check it'", arguments: ["Damaged", " ok", "ok ", "withdrawn", "garbage", "Attention", "UNVERIFIED"])
    func poisonedWordsFailClosed(_ word: String) {
        let s = StoredAudioStatus(word)
        #expect(s == .unreadable(word))
        #expect(!s.isVerifiedOK && !s.refusesLikeDamage && s.readsAsNeverVerified && s.tint == .none)
        let poisoned = Answers(row(word, note: "silent audio"))
        let never = Answers(row("", dated: false))
        #expect(poisoned.audio == .notVerified, "\(word): \(poisoned.audio)")
        #expect(poisoned.sound == never.sound)
        #expect(poisoned.inRepairDamagedSet == false)
        #expect(poisoned.angelNeeds == never.angelNeeds)
        #expect(!poisoned.reusesCachedDiagnosis)
        #expect(row(word).rowColor == row("").rowColor)
    }

    // MARK: Scale

    @Test("SCALE: 100k records through the shared reading (sound facts + the Repair set + tint tier) inside 3 s")
    func aHundredThousandRecords() {
        let words = ["", "ok", "damaged", "attention", "unverified", "garbage"]
        let records = (0..<100_000).map { n -> VideoRecord in
            let r = VideoRecord()
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.audioVerifyStatus = words[n % words.count]
            return r
        }
        let clock = ContinuousClock()
        let start = clock.now
        var refused = 0, verified = 0, orange = 0
        for r in records {
            let facts = ArchiveReadiness.soundFacts(streamTypeRaw: r.streamTypeRaw, isPlayable: "Yes",
                                                    audioVerifyStatus: r.audioVerifyStatus, audioVerifyDate: nil,
                                                    audioVerifyNote: "", audioChannels: "2", mark: .absent)
            if case .refusable = facts.sound { refused += 1 }
            if facts.audio == .verifiedOK { verified += 1 }
            if StoredAudioStatus(r.audioVerifyStatus).tint == .attention { orange += 1 }
        }
        let damagedSet = CatalogRowMenuRules.damagedAudio(records).count
        let elapsed = clock.now - start
        print("[audio-status] 100k records read in \(elapsed)")
        #expect(elapsed < .seconds(3), "\(elapsed)")
        #expect(refused == 33_334 && damagedSet == 33_334, "damaged + attention: \(refused), \(damagedSet)")
        #expect(verified == 16_667, "only ok")
        #expect(orange == 16_667)
    }
}
