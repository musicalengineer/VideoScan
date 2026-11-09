// ArchiveAngelFloorFiresCharacterizationTests.swift
// CHARACTERIZATION ONLY (refactor/angel-floorfires, 2026-11-08): pins what
// `ArchiveAngelScorer.floorFires` answers today for every rule kind, so the
// split of that switch into its concepts (where the file lives / is it
// material / what a person or the machine judged) can be shown to change
// nothing. Written and seen green on the unchanged code first.
//
// The pins:
//   1. a clean candidate passes every kind (floors and signals alike);
//   2. one candidate per floor: the FULL row of verdicts across every kind
//      (so a kind routed to the wrong group, or a group's default swallowing
//      a kind, shows as a changed row, not just a changed cell);
//   3. the boundaries each floor's comparison draws (<, >=, guards);
//   4. thresholds come from the policy passed in, never a global;
//   5. a signal kind (or `.match`) in the floors list never rejects, even a
//      candidate every floor rejects.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("ArchiveAngelScorer.floorFires — characterization (every kind, every floor)")
struct ArchiveAngelFloorFiresCharacterizationTests {

    typealias Kind = AngelRuleKind
    typealias R = ArchiveAngelRejection

    static let now = Date(timeIntervalSince1970: 1_790_000_000)   // 2026-09
    static let policy = AngelRecommendationPolicy.builtIn

    /// Passes every floor: a 10-minute, playable, sound-bearing video on an
    /// online workspace drive, unrated, no junk, no history.
    static func clean() -> ArchiveAngelCandidate {
        ArchiveAngelCandidate(filename: "Christmas 1994.mov", fullPath: "/Volumes/Tapes/1994/Christmas 1994.mov",
                              sizeBytes: 2_000_000_000, durationSeconds: 600)
    }

    /// Every kind's verdict on `c` (nil cells dropped).
    static func row(_ c: ArchiveAngelCandidate,
                    policy p: AngelRecommendationPolicy = policy) -> [Kind: R] {
        var out: [Kind: R] = [:]
        for kind in Kind.allCases {
            if let r = ArchiveAngelScorer.floorFires(kind, c, policy: p, now: now) { out[kind] = r }
        }
        return out
    }

    static func with(_ edit: (inout ArchiveAngelCandidate) -> Void) -> ArchiveAngelCandidate {
        var c = clean()
        edit(&c)
        return c
    }

    // MARK: 1

    @Test func cleanCandidatePassesEveryKind() {
        #expect(Self.row(Self.clean()).isEmpty)
    }

    // MARK: 2 — one candidate per floor, the whole row

    @Test func eachFloorFiresAloneWithItsOwnReason() {
        let cases: [(String, ArchiveAngelCandidate, [Kind: R])] = [
            ("on the master archive", Self.with { $0.isOnMasterArchive = true }, [.onMasterArchive: .alreadyArchived]),
            ("angel working copy", Self.with { $0.isAngelWorkingCopy = true }, [.angelWorkingCopy: .angelWorkingCopy]),
            ("byte copy archived", Self.with { $0.hasArchivedDuplicate = true }, [.archivedCopy: .duplicateArchived]),
            ("footage original archived", Self.with { $0.archivedFootageOriginal = true },
             [.archivedCopy: .footageOriginalArchived]),
            ("live photo motion", Self.with { $0.filename = "JPEGVideoComplement_0001.mov" },
             [.livePhotoMotion: .livePhotoMotion]),
            ("recent phone clip", Self.with { $0.deviceModel = "iPhone 12"; $0.captureDate = Self.now.addingTimeInterval(-86_400) },
             [.recentPhoneClip: .recentPhoneClip]),
            ("app cache by name", Self.with { $0.filename = "Cache-30.mov"; $0.fullPath = "/Volumes/Tapes/Cache-30.mov" },
             [.appCache: .appCache]),
            ("derivative", Self.with { $0.derivativeOfOriginal = "Christmas 1994.dv" },
             [.derivativeOfOriginal: .derivativeOfOriginal]),
            ("too short", Self.with { $0.durationSeconds = 30 }, [.tooShort: .tooShort]),
            ("proxy stream", Self.with { $0.sizeBytes = 1_000_000 }, [.proxyStream: .proxyStream]),
            ("marked junk", Self.with { $0.mediaDisposition = .confirmedJunk }, [.markedJunk: .junk]),
            ("suspected junk", Self.with { $0.mediaDisposition = .suspectedJunk }, [.suspectedJunk: .suspectedJunk]),
            ("junk score", Self.with { $0.junkScore = 9 }, [.junkScore: .suspectedJunk]),
            ("volume offline", Self.with { $0.volumeOnline = false }, [.volumeOffline: .volumeOffline]),
            ("resting", Self.with { c in
                c.attention.skipped = (1...3).map { Self.now.addingTimeInterval(Double(-$0) * 86_400) }
            }, [.resting: .resting]),
            ("paired half", Self.with { $0.isPairedHalf = true }, [.pairedHalf: .pairedHalf]),
            ("not playable", Self.with { $0.isPlayable = "No (unsupported codec)" }, [.notPlayable: .notPlayable]),
            ("damaged sound", Self.with { $0.audioVerifyStatus = "damaged" }, [.noSound: .noSound]),
            // Video without sound is a video (notVideo passes) with no sound.
            ("video only", Self.with { $0.streamTypeRaw = StreamType.videoOnly.rawValue }, [.noSound: .noSound]),
            // Audio only: not a video AND no usable sound (the noSound floor
            // reads "not video+audio" as lacking sound).
            ("audio only", Self.with { $0.streamTypeRaw = StreamType.audioOnly.rawValue },
             [.notVideo: .notVideo, .noSound: .noSound]),
        ]
        for (name, c, expected) in cases {
            #expect(Self.row(c) == expected, "\(name)")
        }
    }

    // MARK: 3 — boundaries

    @Test func archivedCopyPrefersTheByteCopyReason() {
        let both = Self.with { $0.hasArchivedDuplicate = true; $0.archivedFootageOriginal = true }
        #expect(ArchiveAngelScorer.floorFires(.archivedCopy, both, policy: Self.policy, now: Self.now) == .duplicateArchived)
    }

    @Test func tooShortIsStrictlyUnderTheMinimum() {
        let minimum = Self.policy.weights.minimumDurationSeconds
        let at = Self.with { $0.durationSeconds = minimum }
        let under = Self.with { $0.durationSeconds = minimum.nextDown }
        #expect(ArchiveAngelScorer.floorFires(.tooShort, at, policy: Self.policy, now: Self.now) == nil)
        #expect(ArchiveAngelScorer.floorFires(.tooShort, under, policy: Self.policy, now: Self.now) == .tooShort)
    }

    @Test func junkScoreFiresAtTheFloor() {
        let floor = Self.policy.weights.junkFloor
        let at = Self.with { $0.junkScore = floor }
        let under = Self.with { $0.junkScore = floor - 1 }
        #expect(ArchiveAngelScorer.floorFires(.junkScore, at, policy: Self.policy, now: Self.now) == .suspectedJunk)
        #expect(ArchiveAngelScorer.floorFires(.junkScore, under, policy: Self.policy, now: Self.now) == nil)
    }

    @Test func proxyStreamNeedsADurationAndASizeAndIsStrictlyUnderTheRate() {
        let kbps = Self.policy.weights.minimumAverageKilobitsPerSecond
        // size such that size*8/600/1000 == kbps exactly
        let atRate = Int64(kbps * 1000 * 600 / 8)
        let at = Self.with { $0.sizeBytes = atRate }
        let under = Self.with { $0.sizeBytes = atRate - 1 }
        let noDuration = Self.with { $0.sizeBytes = 1; $0.durationSeconds = 0 }
        let noSize = Self.with { $0.sizeBytes = 0 }
        #expect(ArchiveAngelScorer.floorFires(.proxyStream, at, policy: Self.policy, now: Self.now) == nil)
        #expect(ArchiveAngelScorer.floorFires(.proxyStream, under, policy: Self.policy, now: Self.now) == .proxyStream)
        #expect(ArchiveAngelScorer.floorFires(.proxyStream, noDuration, policy: Self.policy, now: Self.now) == nil)
        #expect(ArchiveAngelScorer.floorFires(.proxyStream, noSize, policy: Self.policy, now: Self.now) == nil)
    }

    @Test func recentPhoneClipNeedsAPhoneAndARecentOrUnknownDate() {
        let undated = Self.with { $0.deviceModel = "iPad Pro"; $0.captureDate = nil }
        let old = Self.with { $0.deviceModel = "iPhone 4"; $0.captureDate = Self.now.addingTimeInterval(-20 * 365 * 86_400) }
        let photosLibrary = Self.with { $0.fullPath = "/Users/x/Pictures/Photos Library.photoslibrary/originals/a.mov" }
        let camcorder = Self.with { $0.deviceModel = "Sony DCR-TRV900"; $0.captureDate = Self.now }
        #expect(ArchiveAngelScorer.floorFires(.recentPhoneClip, undated, policy: Self.policy, now: Self.now) == .recentPhoneClip)
        #expect(ArchiveAngelScorer.floorFires(.recentPhoneClip, old, policy: Self.policy, now: Self.now) == nil)
        #expect(ArchiveAngelScorer.floorFires(.recentPhoneClip, photosLibrary, policy: Self.policy, now: Self.now) == .recentPhoneClip)
        #expect(ArchiveAngelScorer.floorFires(.recentPhoneClip, camcorder, policy: Self.policy, now: Self.now) == nil)
    }

    @Test func appCacheByFolderAndAPersonsNameIsNot() {
        let folder = Self.with { $0.fullPath = "/Volumes/Tapes/iMovie Cache/clip.mov" }
        let named = Self.with { $0.filename = "Cache Cod 1998.mov"; $0.fullPath = "/Volumes/Tapes/Cache Cod 1998.mov" }
        #expect(ArchiveAngelScorer.floorFires(.appCache, folder, policy: Self.policy, now: Self.now) == .appCache)
        #expect(ArchiveAngelScorer.floorFires(.appCache, named, policy: Self.policy, now: Self.now) == nil)
    }

    @Test func restingNeedsEnoughRecentPasses() {
        let twice = Self.with { c in
            c.attention.skipped = (1...2).map { Self.now.addingTimeInterval(Double(-$0) * 86_400) }
        }
        let longAgo = Self.with { c in
            c.attention.skipped = (1...3).map { Self.now.addingTimeInterval(Double(-$0 - 200) * 86_400) }
        }
        #expect(ArchiveAngelScorer.floorFires(.resting, twice, policy: Self.policy, now: Self.now) == nil)
        #expect(ArchiveAngelScorer.floorFires(.resting, longAgo, policy: Self.policy, now: Self.now) == nil)
    }

    @Test func notPlayableReadsTheProbeWordsCaseInsensitively() {
        for (word, fires) in [("no", true), ("NO", true), ("Nope", true), ("Yes (unsupported audio)", true),
                              ("Yes", false), ("", false), ("Unknown", false)] {
            let c = Self.with { $0.isPlayable = word }
            #expect((ArchiveAngelScorer.floorFires(.notPlayable, c, policy: Self.policy, now: Self.now) == .notPlayable) == fires,
                    "\(word)")
        }
    }

    @Test func noSoundReadsTheVerifyAudioNote() {
        let silent = Self.with { $0.audioProblem = VerifyAudioRules.noteFragment(for: .silentAudio) }
        let other = Self.with { $0.audioProblem = "levels low" }
        #expect(ArchiveAngelScorer.floorFires(.noSound, silent, policy: Self.policy, now: Self.now) == .noSound)
        #expect(ArchiveAngelScorer.floorFires(.noSound, other, policy: Self.policy, now: Self.now) == nil)
    }

    // MARK: 4 — the policy's thresholds and switches

    @Test func thresholdsAndSwitchesComeFromThePolicyPassedIn() {
        var w = Self.policy.weights
        w.minimumDurationSeconds = 20
        w.junkFloor = 50
        w.minimumAverageKilobitsPerSecond = 1
        w.excludeLivePhotoMotion = false
        w.excludeRecentPhoneClips = false
        w.recentPhoneClipYears = 1
        let p = Self.policy.with(weights: w)
        #expect(Self.row(Self.with { $0.durationSeconds = 30 }, policy: p).isEmpty)
        #expect(Self.row(Self.with { $0.junkScore = 9 }, policy: p).isEmpty)
        #expect(Self.row(Self.with { $0.sizeBytes = 1_000_000 }, policy: p).isEmpty)
        #expect(Self.row(Self.with { $0.filename = "JPEGVideoComplement_0001.mov" }, policy: p).isEmpty)
        #expect(Self.row(Self.with { $0.deviceModel = "iPhone 12"; $0.captureDate = Self.now }, policy: p).isEmpty)
        // recentPhoneClipYears is read once the switch is on.
        w.excludeRecentPhoneClips = true
        let p2 = Self.policy.with(weights: w)
        let twoYears = Self.with { $0.deviceModel = "iPhone 12"; $0.captureDate = Self.now.addingTimeInterval(-2 * 366 * 86_400) }
        #expect(ArchiveAngelScorer.floorFires(.recentPhoneClip, twoYears, policy: p2, now: Self.now) == nil)
        #expect(ArchiveAngelScorer.floorFires(.recentPhoneClip, twoYears, policy: Self.policy, now: Self.now) == .recentPhoneClip)
    }

    // MARK: 5 — non-floor kinds never reject

    @Test func signalKindsAndMatchNeverRejectEvenWhenEveryFloorWould() {
        let everything = Self.with { c in
            c.isOnMasterArchive = true; c.isAngelWorkingCopy = true; c.hasArchivedDuplicate = true
            c.filename = "JPEGVideoComplement_0001.mov"; c.fullPath = "/Volumes/T/iMovie Cache/JPEGVideoComplement_0001.mov"
            c.deviceModel = "iPhone 12"
            c.derivativeOfOriginal = "x.dv"; c.durationSeconds = 1; c.sizeBytes = 10
            c.mediaDisposition = .confirmedJunk; c.junkScore = 99; c.volumeOnline = false
            c.isPairedHalf = true; c.isPlayable = "no"; c.streamTypeRaw = StreamType.audioOnly.rawValue
            c.attention.skipped = (1...3).map { Self.now.addingTimeInterval(Double(-$0) * 86_400) }
        }
        let floors = AngelRuleSection.floors.allowedKinds.subtracting([.match])
        let row = Self.row(everything)
        #expect(Set(row.keys) == floors.subtracting([.suspectedJunk]),
                "every floor kind fires except suspectedJunk (the disposition is confirmedJunk)")
        for kind in Kind.allCases where !floors.contains(kind) {
            #expect(row[kind] == nil, "\(kind) is not a floor")
        }
    }
}
