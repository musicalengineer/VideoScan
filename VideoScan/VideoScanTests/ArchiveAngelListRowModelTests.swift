// ArchiveAngelListRowModelTests.swift
// The senior-friendly Archive Angel list (Rick 2026-09-24): status words
// instead of letter grades, the row's Promote route, the Play button's
// player choice, and the row-model build at 10,000 rows under a budget.
// All pure — no model, no UI, no files.

import Foundation
import Testing
@testable import VideoScan

private func facts(_ kind: ArchiveAngelRecommendationClass,
                   audio: ArchiveReadiness.Audio = .verifiedOK,
                   audioStatus: String = "ok",
                   date: ArchiveReadiness.DateState = .known,
                   video: String = "") -> ArchiveAngelRowFacts {
    var f = ArchiveAngelRowFacts(id: UUID(), filename: "Tape 12.mov", fullPath: "/Volumes/X/Tape 12.mov", kind: kind)
    f.audio = audio
    f.audioVerifyStatus = audioStatus
    f.date = date
    f.videoVerifyStatus = video
    f.videoVerifyNote = video == "broken" ? "Broken video — 40% of frames undecodable" : ""
    return f
}

@Suite("Archive Angel list — status words")
struct ArchiveAngelStatusWordsTests {

    @Test func readyWithNothingMissingIsReadyToArchive() {
        let f = facts(.ready)
        #expect(ArchiveAngelStatusWords.needs(f).isEmpty)
        #expect(ArchiveAngelStatusWords.words(f) == "Ready to archive")
    }

    @Test func needsDateClassSaysNeedsADate() {
        #expect(ArchiveAngelStatusWords.words(facts(.needsDate, date: .undated)) == "Needs a date")
        // The class alone is enough, whatever readiness thinks of the date.
        #expect(ArchiveAngelStatusWords.words(facts(.needsDate, date: .lowConfidence)) == "Needs a date")
    }

    @Test func worthALookSaysNeedsALook() {
        #expect(ArchiveAngelStatusWords.words(facts(.worthALook)) == "Needs a look")
    }

    @Test func unverifiedAudioNeedsAudioChecked() {
        let f = facts(.ready, audio: .notVerified, audioStatus: "")
        #expect(ArchiveAngelStatusWords.needs(f) == [.audioCheck])
        #expect(ArchiveAngelStatusWords.words(f) == "Needs audio checked")
    }

    @Test func damagedAudioNeedsAudioRepair() {
        var f = facts(.ready, audio: .verifiedProblem("Damaged audio — invalid codec"), audioStatus: "damaged")
        f.audioVerifyNote = "Damaged audio — invalid codec"
        #expect(ArchiveAngelStatusWords.needs(f) == [.audioRepair(note: "Damaged audio — invalid codec")])
        #expect(ArchiveAngelStatusWords.words(f) == "Needs audio repair")
    }

    @Test func brokenVideoNeedsVideoRepairAndAWarningNeedsALook() {
        #expect(ArchiveAngelStatusWords.words(facts(.ready, video: "broken")) == "Needs video repair")
        #expect(ArchiveAngelStatusWords.words(facts(.ready, video: "warning")) == "Needs a look")
    }

    @Test func noAudioTrackIsNotANeed() {
        #expect(ArchiveAngelStatusWords.words(facts(.ready, audio: .noAudioTrack, audioStatus: "")) == "Ready to archive")
    }

    @Test func twoNeedsJoinWithAndRepairsFirst() {
        let f = facts(.needsDate, audio: .notVerified, audioStatus: "")
        #expect(ArchiveAngelStatusWords.words(f) == "Needs a date and audio checked")
        let g = facts(.needsDate, video: "broken")
        #expect(ArchiveAngelStatusWords.words(g) == "Needs video repair and a date")
    }

    @Test func threeOrMoreNeedsSayAndMore() {
        let f = facts(.worthALook, audio: .notVerified, audioStatus: "", date: .undated, video: "broken")
        #expect(ArchiveAngelStatusWords.words(f) == "Needs video repair, a date and more")
    }

    @Test func everyClassHasWordsAndNoLetterGrade() {
        for kind in ArchiveAngelRecommendationClass.allCases {
            let w = ArchiveAngelStatusWords.words(facts(kind))
            #expect(!w.isEmpty, "\(kind)")
            #expect(!w.contains("grade"), "\(kind): \(w)")
            #expect(w.range(of: #"\b[ABCDX]\b"#, options: .regularExpression) == nil, "\(kind): \(w)")
        }
        #expect(ArchiveAngelStatusWords.words(facts(.prepared)) == "Prepared — waiting for your review")
        #expect(ArchiveAngelStatusWords.words(facts(.promoted)) == "Already in the archive")
        #expect(ArchiveAngelStatusWords.words(facts(.anotherCopy)) == "Another copy is the one to keep")
    }

    @Test func nonRecommendedClassesHaveNoNeeds() {
        for kind in [ArchiveAngelRecommendationClass.notNow, .excluded, .anotherCopy, .prepared, .promoted] {
            #expect(ArchiveAngelStatusWords.needs(facts(kind, audio: .notVerified, audioStatus: "")).isEmpty, "\(kind)")
        }
    }
}

@Suite("Archive Angel list — promote route")
struct ArchiveAngelPromoteRouteTests {

    private func route(_ f: ArchiveAngelRowFacts) -> ArchiveAngelPromoteRoute {
        ArchiveAngelListRowBuilder.row(f).route
    }

    @Test func readyGoesStraightToPromote() {
        #expect(route(facts(.ready)) == .direct)
        #expect(ArchiveAngelPromoteRoute.direct.buttonTitle == "Promote to Archive")
    }

    @Test func anythingThatNeedsWorkGoesThroughPrepare() {
        #expect(route(facts(.ready, audio: .notVerified, audioStatus: "")) == .prepare, "Ready class but audio unchecked")
        #expect(route(facts(.ready, video: "broken")) == .prepare)
        #expect(route(facts(.needsDate, date: .undated)) == .prepare)
        #expect(route(facts(.worthALook)) == .prepare)
        #expect(ArchiveAngelPromoteRoute.prepare.buttonTitle == "Prepare to Archive")
        #expect(ArchiveAngelPromoteRoute.prepare.help.contains("prepares"))
    }

    @Test func notRecommendedIsUnavailableWithAReason() {
        for kind in [ArchiveAngelRecommendationClass.notNow, .excluded, .anotherCopy, .prepared, .promoted] {
            guard case .unavailable(let why) = route(facts(kind)) else {
                Issue.record("\(kind) should be unavailable"); continue
            }
            #expect(!why.isEmpty)
        }
    }

    @Test func rowCarriesWordsReadinessAndRouteTogether() {
        let row = ArchiveAngelListRowBuilder.row(facts(.ready))
        #expect(row.isReady)
        #expect(row.statusWords == "Ready to archive")
        #expect(row.route == .direct)
        let other = ArchiveAngelListRowBuilder.row(facts(.needsDate, date: .undated))
        #expect(!other.isReady)
        #expect(other.route == .prepare)
    }
}

@Suite("Archive Angel list — Play picks the player")
struct ArchiveAngelPlayerChoiceTests {

    private func decide(_ ext: String, _ v: String = "h264", _ a: String = "aac", vlc: Bool = true) -> ArchiveAngelPlayerChoice.Decision {
        ArchiveAngelPlayerChoice.decide(filename: "clip.\(ext.lowercased())", ext: ext, videoCodec: v, audioCodec: a, hasVLC: vlc)
    }

    @Test func movAndMp4WithQuickTimeCodecsPlayInQuickTime() {
        #expect(decide("MOV").choice == .quickTime)
        #expect(decide("mp4").choice == .quickTime)
        #expect(decide("m4v", "prores", "pcm_s16le").choice == .quickTime)
        #expect(decide("MOV").sentence.contains("QuickTime Player"))
    }

    @Test func containersQuickTimeCannotOpenGoToVLC() {
        for ext in ["mkv", "avi", "dv", "mxf", "flv", "wmv", "vob", "mpg", "mpeg", "ts", "ogg", "webm"] {
            let d = decide(ext)
            #expect(d.choice == .vlc, "\(ext)")
            #expect(d.sentence.contains("QuickTime can't open .\(ext) files"), "\(ext): \(d.sentence)")
        }
    }

    @Test func unknownExtensionIsNotPlayableSoVLC() {
        #expect(decide("xyz").choice == .vlc)
        #expect(decide("", "", "").choice == .vlc)
    }

    @Test func aMovWithACodecQuickTimeCannotPlayGoesToVLCAndSaysWhy() {
        let d = decide("mov", "dvvideo", "pcm_s16le")
        #expect(d.choice == .vlc)
        #expect(d.sentence.contains("dvvideo"))
        #expect(decide("mov", "h264", "ac3").choice == .vlc, "QuickTime would open it silent")
    }

    @Test func vlcMissingIsSaidNotHidden() {
        let d = decide("mkv", vlc: false)
        #expect(d.choice == .systemDefault)
        #expect(d.sentence.contains("VLC is not installed"))
        // QuickTime-playable files never need VLC.
        #expect(decide("mov", vlc: false).choice == .quickTime)
    }
}

@Suite("Archive Angel list — row models at scale")
struct ArchiveAngelListRowScaleTests {

    @Test func tenThousandRowsBuildInsideTheBudget() {
        let kinds: [ArchiveAngelRecommendationClass] = [.ready, .needsDate, .worthALook]
        var input: [ArchiveAngelRowFacts] = []
        input.reserveCapacity(10_000)
        for i in 0..<10_000 {
            var f = ArchiveAngelRowFacts(id: UUID(), filename: "clip \(i).mov", fullPath: "/Volumes/X/clip \(i).mov",
                                         kind: kinds[i % 3])
            f.audio = i % 2 == 0 ? .verifiedOK : .notVerified
            f.date = i % 5 == 0 ? .undated : .known
            f.videoVerifyStatus = i % 7 == 0 ? "broken" : ""
            input.append(f)
        }
        let clock = ContinuousClock()
        var rows: [ArchiveAngelListRow] = []
        let elapsed = clock.measure { rows = ArchiveAngelListRowBuilder.rows(input) }
        #expect(rows.count == 10_000)
        #expect(rows.map(\.id) == input.map(\.id), "order preserved")
        #expect(elapsed < .milliseconds(500), "10k row models took \(elapsed)")
        print("[aa-list] 10k row models in \(elapsed)")
    }
}
