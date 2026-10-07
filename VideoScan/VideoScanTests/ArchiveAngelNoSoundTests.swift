// ArchiveAngelNoSoundTests.swift
// Rick 2026-10-06: the Archive Angel recommended a video-only DV export (no
// sound track at all) as "Ready" for the archive — grade A, 126 points,
// "Ready — no sound track". Bad or missing sound is the one thing that ruins
// a keeper (ArchiveReadiness), so the Angel must never RECOMMEND a file
// with:
//   • no audio stream (video-only, any container, with or without an
//     extension),
//   • a sound track Verify Audio found silent or missing,
//   • damaged audio (Verify Audio's "damaged" status),
// unless the policy explicitly allows silent footage (switch the `noSound`
// floor off). A correlated video-only HALF says "combine first" (the
// existing `pairedHalf` floor, which runs before `noSound`). A sound track
// that is simply not checked yet stays recommended — Prepare checks it —
// but is never "Ready" (row: "Needs audio checked").
//
// LOGIC dimension — records projected the way the sweep projects them
// (ArchiveAngelCandidate(record:…) over ArchiveReadiness.assess), no I/O.
// The SCALE row (100k candidates through the floor under a time budget) is
// at the bottom. The MEDIA row is ArchiveAngelNoSoundMediaMatrixTests.
//
// (For Rick: `#require` ≈ ASSERT that aborts this test; `#expect` ≈ EXPECT
// that records a failure and carries on.)

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel — never recommends a file without usable sound")
@MainActor
struct ArchiveAngelNoSoundTests {

    // MARK: Fixtures

    /// A record that passes every OTHER floor: 30 min, playable, a big file
    /// (no proxy-stream floor), a neutral path (no app-cache floor).
    static func record(_ stream: StreamType, ext: String = "mov",
                       audioVerifyStatus: String = "", audioVerifyNote: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.filename = ext.isEmpty ? "test_untitled-video-only" : "test_clip.\(ext)"
        r.fullPath = "/Volumes/TestVol/Projects/" + r.filename
        r.ext = ext.uppercased()
        r.streamTypeRaw = stream.rawValue
        r.isPlayable = "Yes"
        r.videoCodec = stream == .audioOnly ? "" : "dvvideo"
        r.audioCodec = stream == .videoAndAudio || stream == .audioOnly ? "pcm_s16le" : ""
        r.durationSeconds = 1_800
        r.sizeBytes = 6_000_000_000
        r.audioVerifyStatus = audioVerifyStatus
        r.audioVerifyNote = audioVerifyNote
        if !audioVerifyStatus.isEmpty { r.audioVerifyDate = Date(timeIntervalSince1970: 1_790_000_000) }
        return r
    }

    /// The sweep's projection (ArchiveAngelCandidate.project minus the
    /// model lookups): readiness assessed from the record.
    static func candidate(_ r: VideoRecord) -> ArchiveAngelCandidate {
        ArchiveAngelCandidate(record: r, facts: nil, readiness: ArchiveReadiness.assess(record: r),
                              archivedCopyExists: false, isOnMasterArchive: false,
                              volumeName: "TestVol", volumeOnline: true)
    }

    /// The `noSound` rejection — nil before the fix (it did not exist).
    static func noSound() throws -> ArchiveAngelRejection {
        try #require(ArchiveAngelRejection.named("noSound"), "the noSound floor's rejection exists")
    }

    // MARK: Red → green: the bug

    @Test("video-only (the 10/6 bug): rejected for no sound, never recommended")
    func videoOnlyRejected() throws {
        let c = Self.candidate(Self.record(.videoOnly))
        #expect(ArchiveAngelScorer.hardFloor(c) == (try Self.noSound()))
    }

    @Test("extensionless video-only export: rejected the same way")
    func extensionlessVideoOnlyRejected() throws {
        let c = Self.candidate(Self.record(.videoOnly, ext: ""))
        #expect(ArchiveAngelScorer.hardFloor(c) == (try Self.noSound()))
    }

    @Test("sound track Verify Audio found SILENT: rejected")
    func silentTrackRejected() throws {
        let c = Self.candidate(Self.record(.videoAndAudio, audioVerifyStatus: "ok",
                                           audioVerifyNote: VerifyAudioRules.noteFragment(for: .silentAudio)))
        #expect(ArchiveAngelScorer.hardFloor(c) == (try Self.noSound()))
    }

    @Test("Verify Audio found NO audio stream on an A/V record: rejected")
    func verifiedNoStreamRejected() throws {
        let c = Self.candidate(Self.record(.videoAndAudio, audioVerifyStatus: "ok",
                                           audioVerifyNote: VerifyAudioRules.noteFragment(for: .noAudioStream)))
        #expect(ArchiveAngelScorer.hardFloor(c) == (try Self.noSound()))
    }

    @Test("DAMAGED audio (with and without a note): rejected")
    func damagedRejected() throws {
        let noted = Self.candidate(Self.record(.videoAndAudio, audioVerifyStatus: "damaged",
                                               audioVerifyNote: VerifyAudioRules.damagedNotePrefix + "audio shorter than video (2s vs 10s)"))
        let bare = Self.candidate(Self.record(.videoAndAudio, audioVerifyStatus: "damaged"))
        #expect(ArchiveAngelScorer.hardFloor(noted) == (try Self.noSound()))
        #expect(ArchiveAngelScorer.hardFloor(bare) == (try Self.noSound()))
    }

    // MARK: What must NOT change

    @Test("healthy verified sound passes; informational notes (surround, two live tracks) pass")
    func healthyPasses() {
        for note in ["", "surround audio (6 channels)", "2 live audio tracks", "mono audio"] {
            let c = Self.candidate(Self.record(.videoAndAudio, audioVerifyStatus: "ok", audioVerifyNote: note))
            #expect(ArchiveAngelScorer.hardFloor(c) == nil, "note \"\(note)\" must not block")
        }
    }

    @Test("UNCHECKED sound stays a candidate (Prepare checks it) but is never Ready")
    func uncheckedIsCandidateNotReady() {
        let r = Self.record(.videoAndAudio)
        #expect(ArchiveAngelScorer.hardFloor(Self.candidate(r)) == nil)
        var f = ArchiveAngelRowFacts(id: r.id, filename: r.filename, fullPath: r.fullPath, kind: .ready)
        f.audio = ArchiveReadiness.assess(record: r).audio
        let needs = ArchiveAngelStatusWords.needs(f)
        #expect(needs == [.audioCheck])
        #expect(!ArchiveAngelStatusWords.isReady(kind: .ready, needs: needs))
        #expect(ArchiveAngelStatusWords.words(f) == "Needs audio checked")
    }

    @Test("audio-only is still 'Not a video' (the safety floor speaks first)")
    func audioOnlyIsNotVideo() {
        #expect(ArchiveAngelScorer.hardFloor(Self.candidate(Self.record(.audioOnly))) == .notVideo)
    }

    @Test("a correlated video-only HALF says 'combine first' (pairedHalf runs before noSound)")
    func pairedHalfSaysCombineFirst() {
        let r = Self.record(.videoOnly)
        r.pairGroupID = UUID()
        let hit = ArchiveAngelScorer.hardFloor(Self.candidate(r))
        #expect(hit == .pairedHalf)
        #expect(hit?.rawValue.contains("combine first") == true)
    }

    // MARK: Policy — silent footage only when the policy says so

    @Test("the policy can allow silent footage: noSound off → video-only passes; it is not a safety floor")
    func policyAllowsSilentFootage() throws {
        var p = AngelRecommendationPolicy.builtIn
        let i = try #require(p.floors.firstIndex { $0.id == "noSound" }, "built-in floor noSound")
        #expect(!AngelPolicyDefaults.safetyFloorIDs.contains("noSound"))
        #expect(!p.floors[i].starExempt, "a star does not make silent footage recommendable")
        p.floors[i].enabled = false
        #expect(p.validationProblems().isEmpty, "switching it off is a valid policy")
        let c = Self.candidate(Self.record(.videoOnly))
        #expect(ArchiveAngelScorer.hardFloor(c, policy: p) == nil)
    }

    @Test("an override file switches it off BY ID and keeps every other floor")
    func overrideFileByID() throws {
        let json = #"{"schemaVersion": 2, "floors": [{"id": "noSound", "enabled": false}]}"#
        let url = URL(fileURLWithPath: "/test_policy.json")
        guard case .success(let p) = AngelRecommendationPolicy.decodeValidated(from: url, read: { _ in Data(json.utf8) }) else {
            Issue.record("override refused")
            return
        }
        #expect(p.floors.first { $0.id == "noSound" }?.enabled == false)
        #expect(p.floors.count == AngelRecommendationPolicy.builtIn.floors.count)
    }

    @Test("explicit picks (Prepare on a catalog selection) may still take silent film")
    func explicitPicksMayTakeSilentFilm() {
        let p = AngelRecommendationPolicy.builtIn.forExplicitPicks()
        let c = Self.candidate(Self.record(.videoOnly))
        #expect(ArchiveAngelScorer.hardFloor(c, policy: p) == nil)
    }

    // MARK: Classifier + every surface

    @Test("classifier: Excluded with the reason; the row and the Catalog hint are never Ready")
    func classifierAndSurfaces() throws {
        let r = Self.record(.videoOnly)
        r.starRating = 3   // vouched — would be Ready if the floor did not hold
        let c = Self.candidate(r)
        let rejection = ArchiveAngelScorer.hardFloor(c)
        let ev = ArchiveAngelEvidenceRecord(score: 126, lines: [], rejection: rejection, useCount: 0,
                                            lastUsed: nil, computedAt: Date())
        let result = ArchiveAngelRecommendations.classify([c], evidence: [c.id: ev],
                                                          rules: AngelRecommendationPolicy.builtIn.recommend)
        let v = try #require(result.verdicts.first)
        #expect(v.kind == .excluded)
        #expect(v.reasons == [try Self.noSound().rawValue])
        #expect(result.ready.isEmpty && result.needsDate.isEmpty && result.worthALook.isEmpty)
        let hint = ArchiveAngelCatalogHint.make(.init(id: r.id, kind: v.kind, filename: r.filename,
                                                      readiness: ArchiveReadiness.inputs(record: r)))
        #expect(!hint.isReady)
    }

    @Test("the reason reads in family words and points at combining")
    func reasonWords() throws {
        let words = try Self.noSound().rawValue
        #expect(words.hasPrefix("No usable sound"))
        #expect(words.contains("combine"))
    }

    // MARK: Scale (dimension 2) + sensor

    @Test("100k candidates through the floors under budget; every silent one refused", .timeLimit(.minutes(1)))
    func scale100k() throws {
        let noSound = try Self.noSound()
        let kinds: [ArchiveAngelCandidate] = [
            Self.candidate(Self.record(.videoOnly)),
            Self.candidate(Self.record(.videoAndAudio, audioVerifyStatus: "ok", audioVerifyNote: "silent audio")),
            Self.candidate(Self.record(.videoAndAudio, audioVerifyStatus: "damaged")),
            Self.candidate(Self.record(.videoAndAudio, audioVerifyStatus: "ok")),
        ]
        let policy = AngelRecommendationPolicy.builtIn
        let n = 100_000
        var refused = 0, passed = 0
        let start = Date()
        for i in 0..<n {
            switch ArchiveAngelScorer.hardFloor(kinds[i % kinds.count], policy: policy) {
            case noSound?: refused += 1
            case nil: passed += 1
            default: break
            }
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(refused == n / 4 * 3)
        #expect(passed == n / 4)
        #expect(elapsed < 5.0, "100k floor passes took \(elapsed) s")
    }
}
