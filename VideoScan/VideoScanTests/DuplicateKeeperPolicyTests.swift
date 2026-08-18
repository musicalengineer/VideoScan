import Foundation
import Testing
@testable import VideoScan

// MARK: - Duplicate keeper election policy (2026-08-18)
//
// Pins the keeper election introduced after two findings:
//   * 8/14 — 2,027 high-confidence groups elected a shelved OFFLINE drive
//     as Keep with the live master as Extra (byte-verify can't catch it).
//   * 8/17 — Rick: "LaCie = 2009 Cheesegrater originals; Crucials =
//     scratch" — volume precedence the technical scorer never saw, and a
//     delete could remove the metadata-bearing copy.
//
// Dimensions (CLAUDE.md feature-test checklist): Logic, Scale, Sensor.
// The election is pure (DuplicateKeeperPolicy + DuplicateDetector.
// electKeeper), so no media fixtures or global state are involved here;
// the carry-over half lives in DuplicateKeeperCarryOverTests.

// MARK: Fixtures

/// A byte-identical twin factory: everything the technical scorer looks
/// at is equal unless the caller overrides it, so any keeper difference
/// comes from the policy under test.
private func twin(_ path: String,
                  playable: Bool = true,
                  resolution: String = "1920x1080",
                  size: Int64 = 3_000_000_000) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    r.sizeBytes = size
    r.durationSeconds = 61.5
    r.duration = Formatting.duration(61.5)
    r.partialMD5 = "feedfacecafebeef"
    r.resolution = resolution
    r.videoCodec = "prores"
    r.audioCodec = "pcm_s16le"
    r.audioChannels = "2"
    r.audioSampleRate = "48000 Hz"
    r.isPlayable = playable ? "Yes" : ""
    return r
}

private func facts(role: VolumeRole = .workspace,
                   reachable: Bool = true,
                   retired: Bool = false,
                   master: Bool = false) -> DuplicateKeeperPolicy.VolumeFacts {
    DuplicateKeeperPolicy.VolumeFacts(role: role, isReachable: reachable,
                                      isRetired: retired, isMasterArchive: master)
}

private func keeperPath(_ records: [VideoRecord]) -> String? {
    records.first { $0.duplicateDisposition == .keep }?.fullPath
}

// MARK: - Logic

@Suite("DuplicateKeeperPolicy — election")
struct DuplicateKeeperElectionTests {

    /// THE 8/14 strand: an unplugged shelf drive must never be Keep over
    /// a live copy — even when the shelf drive is FIRST in Rick's list.
    @Test func onlineVolumeBeatsOfflineVolumeEvenWhenOfflineIsListedFirst() {
        let policy = DuplicateKeeperPolicy(
            precedence: ["ShelfDrive", "LiveDrive"],
            facts: ["/Volumes/ShelfDrive": facts(reachable: false),
                    "/Volumes/LiveDrive": facts()])
        let shelf = twin("/Volumes/ShelfDrive/1994/xmas.mov")
        let live = twin("/Volumes/LiveDrive/1994/xmas.mov")

        let summary = DuplicateDetector.analyze(records: [shelf, live], keeperPolicy: policy)

        #expect(summary.groups == 1)
        #expect(keeperPath([shelf, live]) == live.fullPath)
        #expect(shelf.duplicateDisposition == .extraCopy)
    }

    /// Retired ranks below merely-offline: both are strands, but a retired
    /// drive is by definition not coming back.
    @Test func offlineBeatsRetired() {
        let policy = DuplicateKeeperPolicy(
            precedence: [],
            facts: ["/Volumes/Retired": facts(reachable: false, retired: true),
                    "/Volumes/Offline": facts(reachable: false)])
        let retired = twin("/Volumes/Retired/a.mov")
        let offline = twin("/Volumes/Offline/a.mov")
        _ = DuplicateDetector.analyze(records: [retired, offline], keeperPolicy: policy)
        #expect(keeperPath([retired, offline]) == offline.fullPath)
    }

    /// 8/17: precedence-list order beats technical merit for identical
    /// content. The scratch copy is "better" to the old scorer (playable
    /// + higher resolution); the LaCie original still wins.
    @Test func precedenceListOrderWinsOverTechnicalScore() {
        let policy = DuplicateKeeperPolicy(
            precedence: DuplicateKeeperSettings.defaultPrecedence,
            facts: ["/Volumes/LaCieWorkspace": facts(),
                    "/Volumes/CrucialX9": facts()])
        let lacie = twin("/Volumes/LaCieWorkspace/2009/Reel12.mov", playable: false, resolution: "")
        let crucial = twin("/Volumes/CrucialX9/scratch/Reel12.mov", playable: true, resolution: "3840x2160")
        // Precondition: the OLD election really preferred the scratch copy.
        #expect(DuplicateDetector.keeperScore(crucial) > DuplicateDetector.keeperScore(lacie))

        _ = DuplicateDetector.analyze(records: [crucial, lacie], keeperPolicy: policy)

        #expect(keeperPath([crucial, lacie]) == lacie.fullPath)
        #expect(crucial.duplicateDisposition == .extraCopy)
    }

    /// The seed order itself: LaCieWorkspace › … › CrucialX9, and an
    /// unlisted volume falls after every listed one.
    @Test func seedOrderIsRicks8_17Order() {
        let policy = DuplicateKeeperPolicy(precedence: DuplicateKeeperSettings.defaultPrecedence)
        let expected = ["LaCieWorkspace", "MediaExpansion", "FamilyArchive", "Projects",
                        "SanDiskWorkspace", "CrucialX10", "CrucialX9"]
        #expect(DuplicateKeeperSettings.defaultPrecedence == expected)
        let scores = expected.map { policy.precedenceScore(forPath: "/Volumes/\($0)/x.mov", facts: nil) }
        #expect(scores == scores.sorted(by: >), "list order must be strictly decreasing precedence")
        let unlisted = policy.precedenceScore(forPath: "/Volumes/SomeOtherDrive/x.mov", facts: nil)
        #expect(unlisted < (scores.last ?? Int.min))
        let home = policy.precedenceScore(forPath: "/Users/rickb/Movies/x.mov", facts: nil)
        #expect(home < unlisted, "home folder ranks after named volumes unless listed")
    }

    /// A home-folder path CAN be listed, as an absolute path entry.
    @Test func homeFolderCanBeListedByPath() {
        let policy = DuplicateKeeperPolicy(precedence: ["/Users/rickb/Movies", "CrucialX9"])
        #expect(policy.listIndex(forPath: "/Users/rickb/Movies/2020/a.mov") == 0)
        #expect(policy.listIndex(forPath: "/Volumes/CrucialX9/a.mov") == 1)
        #expect(policy.listIndex(forPath: "/Users/rickb/Desktop/a.mov") == nil)
    }

    /// Master Archive is top precedence among online volumes even when
    /// unlisted — it is already excluded from bulk delete, so electing
    /// anything else as Keep would only invite a cross-volume strand.
    @Test func masterArchiveOutranksListedVolumes() {
        let policy = DuplicateKeeperPolicy(
            precedence: ["LaCieWorkspace"],
            facts: ["/Volumes/FamilyArchive": facts(role: .archive, master: true),
                    "/Volumes/LaCieWorkspace": facts()])
        let master = twin("/Volumes/FamilyArchive/Breen_Family_Archive/1990s/a.mov")
        let lacie = twin("/Volumes/LaCieWorkspace/a.mov")
        _ = DuplicateDetector.analyze(records: [lacie, master], keeperPolicy: policy)
        #expect(keeperPath([lacie, master]) == master.fullPath)
    }

    /// Unlisted volumes rank by role: workspace over backup ("never
    /// elected Keep over a live file" — VolumeRole doc).
    @Test func unlistedRoleOrderWorkspaceOverBackup() {
        let policy = DuplicateKeeperPolicy(
            precedence: [],
            facts: ["/Volumes/Work": facts(role: .workspace),
                    "/Volumes/Bak": facts(role: .backup)])
        let bak = twin("/Volumes/Bak/a.mov")
        let work = twin("/Volumes/Work/a.mov")
        _ = DuplicateDetector.analyze(records: [bak, work], keeperPolicy: policy)
        #expect(keeperPath([bak, work]) == work.fullPath)
    }

    /// Between two equal-precedence volumes the copy carrying Rick's work
    /// (stars, confirmed people, notes) is the keeper.
    @Test func metadataRichRecordWinsAtEqualPrecedence() {
        let policy = DuplicateKeeperPolicy(
            precedence: [],
            facts: ["/Volumes/A": facts(), "/Volumes/B": facts()])
        let bare = twin("/Volumes/A/a.mov")          // sorts FIRST by path
        let rich = twin("/Volumes/B/a.mov")
        rich.starRating = 3
        rich.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        rich.userNotes = "the birthday tape"

        _ = DuplicateDetector.analyze(records: [bare, rich], keeperPolicy: policy)

        #expect(keeperPath([bare, rich]) == rich.fullPath)
        #expect(DuplicateKeeperPolicy.humanMetadataScore(bare) == 0)
        #expect(DuplicateKeeperPolicy.humanMetadataScore(rich) > 0)
    }

    /// The human-metadata score counts only human / human-facing fields —
    /// never machine probe data (identical for a byte-identical twin).
    @Test func humanMetadataScoreIgnoresMachineFields() {
        let r = twin("/Volumes/A/a.mov")
        r.videoCodec = "prores"; r.resolution = "3840x2160"; r.sizeBytes = 9_000_000_000
        r.audioVerifyStatus = "ok"
        #expect(DuplicateKeeperPolicy.humanMetadataScore(r) == 0)

        var s = 0
        r.starRating = 2;              #expect(DuplicateKeeperPolicy.humanMetadataScore(r) > s); s = DuplicateKeeperPolicy.humanMetadataScore(r)
        r.tags = ["Gold"];             #expect(DuplicateKeeperPolicy.humanMetadataScore(r) > s); s = DuplicateKeeperPolicy.humanMetadataScore(r)
        r.originalFullPath = "/Volumes/Old/a.mov"; #expect(DuplicateKeeperPolicy.humanMetadataScore(r) > s); s = DuplicateKeeperPolicy.humanMetadataScore(r)
        r.audioTranscript = "hello";   #expect(DuplicateKeeperPolicy.humanMetadataScore(r) > s); s = DuplicateKeeperPolicy.humanMetadataScore(r)
        r.dossierProcessedAt = Date(); #expect(DuplicateKeeperPolicy.humanMetadataScore(r) > s); s = DuplicateKeeperPolicy.humanMetadataScore(r)
        r.rejectedPeople = ["Anna"];   #expect(DuplicateKeeperPolicy.humanMetadataScore(r) > s)
        // A star rating (THE curation axis, 8/14) is the single heaviest
        // signal: one star outweighs confirmed people + notes + tags.
        let starOnly = twin("/Volumes/A/b.mov"); starOnly.starRating = 1
        let peopleNotesTags = twin("/Volumes/A/c.mov")
        peopleNotesTags.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        peopleNotesTags.userNotes = "n"; peopleNotesTags.tags = ["x"]
        #expect(DuplicateKeeperPolicy.humanMetadataScore(starOnly)
                > DuplicateKeeperPolicy.humanMetadataScore(peopleNotesTags))
    }

    /// Fully tied records (same volume band, no metadata, same technical
    /// score) resolve by path — the SAME winner regardless of input order.
    @Test func tieBreakIsDeterministicByPath() {
        let policy = DuplicateKeeperPolicy.unconfigured
        func run(_ order: [String]) -> String? {
            let recs = order.map { twin($0) }
            _ = DuplicateDetector.analyze(records: recs, keeperPolicy: policy)
            return keeperPath(recs)
        }
        let paths = ["/Volumes/X/clip.mov", "/Volumes/X/sub/clip.mov", "/Volumes/X/aaa/clip.mov"]
        let a = run(paths)
        let b = run(paths.reversed())
        let c = run([paths[1], paths[0], paths[2]])
        #expect(a == "/Volumes/X/aaa/clip.mov", "lexicographically smallest path is the stable keeper")
        #expect(a == b && b == c)
    }

    /// The election key really is lexicographic in the documented order.
    @Test func electionKeyOrderingIsLexicographic() {
        typealias K = DuplicateKeeperPolicy.ElectionKey
        let base = K(availability: 2, precedence: 10, humanMetadata: 0, technical: 0, path: "/b")
        #expect(K(availability: 1, precedence: 999, humanMetadata: 999, technical: 999, path: "/a") < base)
        #expect(K(availability: 2, precedence: 9, humanMetadata: 999, technical: 999, path: "/a") < base)
        #expect(K(availability: 2, precedence: 10, humanMetadata: 1, technical: 0, path: "/z") > base)
        #expect(K(availability: 2, precedence: 10, humanMetadata: 0, technical: 1, path: "/z") > base)
        #expect(K(availability: 2, precedence: 10, humanMetadata: 0, technical: 0, path: "/a") > base,
                "smaller path is the better keeper")
    }

    /// Existing call sites pass no policy: unconfigured == every record
    /// online/unlisted, so grouping and confidence are unchanged and the
    /// existing DuplicateDetectorTests keep passing.
    @Test func unconfiguredPolicyDegradesToTechnicalThenPath() {
        let good = twin("/Volumes/Z/good.mov")
        let bad = twin("/Volumes/A/bad.mov", playable: false, resolution: "")
        _ = DuplicateDetector.analyze(records: [bad, good])
        #expect(keeperPath([bad, good]) == good.fullPath)
    }

    /// Volume-name parsing edge cases.
    @Test func volumeNameParsing() {
        #expect(DuplicateKeeperPolicy.volumeName(forPath: "/Volumes/LaCieWorkspace/a/b.mov") == "LaCieWorkspace")
        #expect(DuplicateKeeperPolicy.volumeName(forPath: "/Volumes/LaCieWorkspace") == "LaCieWorkspace")
        #expect(DuplicateKeeperPolicy.volumeName(forPath: "/Volumes/") == nil)
        #expect(DuplicateKeeperPolicy.volumeName(forPath: "/Users/rickb/Movies/a.mov") == nil)
        // "/Volumes/Drive" must not match "/Volumes/Drive Backup".
        let p = DuplicateKeeperPolicy(precedence: ["Drive"])
        #expect(p.listIndex(forPath: "/Volumes/Drive Backup/a.mov") == nil)
    }

    /// Longest-prefix facts: a subfolder target's role wins over the
    /// volume root's.
    @Test func factsUseLongestMatchingTarget() {
        let policy = DuplicateKeeperPolicy(
            precedence: [],
            facts: ["/Volumes/Big": facts(role: .backup),
                    "/Volumes/Big/Live": facts(role: .workspace)])
        #expect(policy.facts(forPath: "/Volumes/Big/Live/a.mov")?.role == .workspace)
        #expect(policy.facts(forPath: "/Volumes/Big/Other/a.mov")?.role == .backup)
        #expect(policy.facts(forPath: "/Volumes/Elsewhere/a.mov") == nil)
    }
}

// MARK: - Settings persistence (isolation: injected defaults)

@Suite("DuplicateKeeperSettings — persistence")
struct DuplicateKeeperSettingsTests {

    private func scratchDefaults() -> UserDefaults {
        let name = "DupKeeperSettingsTests-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name) ?? .standard
        d.removePersistentDomain(forName: name)
        return d
    }

    @Test func neverSetKeepsSeedOrder() {
        let s = DuplicateKeeperSettings.restored(from: scratchDefaults())
        #expect(s.volumePrecedence == DuplicateKeeperSettings.defaultPrecedence)
    }

    @Test func roundTripsUserOrderIncludingEmpty() {
        let d = scratchDefaults()
        var s = DuplicateKeeperSettings()
        s.volumePrecedence = ["CrucialX9", "/Users/rickb/Movies"]
        s.save(to: d)
        #expect(DuplicateKeeperSettings.restored(from: d).volumePrecedence == ["CrucialX9", "/Users/rickb/Movies"])
        s.volumePrecedence = []
        s.save(to: d)
        #expect(DuplicateKeeperSettings.restored(from: d).volumePrecedence == [],
                "an explicitly emptied list is the user's list, not 'never set'")
    }
}

// MARK: - Scale + sensor

@Suite("DuplicateKeeperPolicy — scale")
struct DuplicateKeeperScaleTests {

    /// 100k-record election with a populated policy (7-entry list, 12
    /// volume facts) stays linear: keys are computed once per member,
    /// never inside the comparator. Budget 2 s (Debug), same shape as
    /// DeleteDuplicatesSafetyTests.planningScale100k. This isolates the
    /// NEW code from the pre-existing pair-building cost of
    /// DuplicateDetector.analyze (GH #104 territory).
    @Test("100k-member keeper election under budget", .timeLimit(.minutes(1)))
    func electionScale100k() {
        var factsMap: [String: DuplicateKeeperPolicy.VolumeFacts] = [:]
        let vols = ["LaCieWorkspace", "MediaExpansion", "FamilyArchive", "Projects", "SanDiskWorkspace",
                    "CrucialX10", "CrucialX9", "MyBook", "RicksBackups", "LACIE500", "Mini2TB", "X"]
        for (i, v) in vols.enumerated() {
            factsMap["/Volumes/\(v)"] = facts(role: i % 3 == 0 ? .workspace : (i % 3 == 1 ? .backup : .unassigned),
                                              reachable: i % 4 != 3, retired: i == 9)
        }
        let policy = DuplicateKeeperPolicy(precedence: DuplicateKeeperSettings.defaultPrecedence, facts: factsMap)

        var component: [VideoRecord] = []
        component.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = twin("/Volumes/\(vols[i % vols.count])/reel\(i % 977)/clip\(i).mov")
            if i % 5 == 0 { r.starRating = 1 + i % 3 }
            if i % 7 == 0 { r.userNotes = "note" }
            component.append(r)
        }

        let start = ContinuousClock.now
        let keeper = DuplicateDetector.electKeeper(from: component, policy: policy)
        let elapsed = start.duration(to: .now)

        #expect(keeper != nil)
        #expect(elapsed < .seconds(2), "100k keeper election exceeded 2 s: \(elapsed)")
        // Sensor: the winner is online, on the top listed volume, and
        // star-rated — never an offline/retired volume, whatever the
        // technical scores say.
        #expect(keeper?.fullPath.hasPrefix("/Volumes/LaCieWorkspace/") == true)
        #expect((keeper?.starRating ?? 0) > 0)
    }

    /// Sensor for the 8/14 strand at scale: 5,000 identical pairs split
    /// across an offline shelf drive and a live drive — every group's
    /// keeper must be the live copy. Runs the full analyze() (pairs are
    /// bucketed by hash so this stays cheap) so the sensor covers the
    /// real entry point, not just electKeeper.
    @Test("no offline keeper across 5k groups", .timeLimit(.minutes(1)))
    func noOfflineKeeperAcross5kGroups() {
        let policy = DuplicateKeeperPolicy(
            precedence: ["Shelf", "Live"],   // shelf listed FIRST on purpose
            facts: ["/Volumes/Shelf": facts(reachable: false), "/Volumes/Live": facts()])
        var records: [VideoRecord] = []
        records.reserveCapacity(10_000)
        for i in 0..<5_000 {
            let s = twin("/Volumes/Shelf/tape\(i).mov"); s.partialMD5 = "h\(i)"; s.sizeBytes = Int64(1_000_000 + i)
            let l = twin("/Volumes/Live/tape\(i).mov");  l.partialMD5 = "h\(i)"; l.sizeBytes = Int64(1_000_000 + i)
            records.append(s); records.append(l)
        }
        let summary = DuplicateDetector.analyze(records: records, keeperPolicy: policy)
        #expect(summary.groups == 5_000)
        let offlineKeepers = records.filter { $0.duplicateDisposition == .keep && $0.fullPath.hasPrefix("/Volumes/Shelf/") }
        #expect(offlineKeepers.isEmpty, "\(offlineKeepers.count) offline keepers — the 8/14 strand is back")
    }
}
