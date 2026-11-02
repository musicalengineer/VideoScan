import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - #401 (P0, 2026-10-30 / strict 2026-11-02): a scan location owns only its own volume's files
//
// Rick's report: the Ultra's ~/Movies location showed "9 files in the
// catalog" while the folder held none. All 9 rows were on the M4's boot disk
// ("M4drive") at the same path /Users/rickb/Movies; the location list came
// over from the M4. The counts and the removal scope matched by path alone.
//
// The first cut (2026-10-30) let the PATH decide whenever either side's
// volume was unknown, so an unmounted location still showed another disk's
// files. The rule is now strict (`VolumeIdentity.agree`): a location shows a
// file only when both name the same volume, or neither names one. A location
// is told its volume by its mount, else by the volume it was last seen on
// (`CatalogScanTarget.volumeUUID`), else — a legacy entry — by its rows when
// they are unanimous (`ScanTargetVolume.resolve`).
//
// Dimensions: logic (counts, removal plan, the four agree cases, memory vs
// rows); scale (100k rows × 20 targets, budget, resolver included); isolation
// (garbage memory, disagreeing rows, rows without evidence); sensor (the
// pane and the planner resolve through the one function; no path-only walk
// is back); truth: the figure a location shows is the number of files
// evidenced on its volume.

private let m4 = "A7A2B888-442A-42FC-B548-4FE8FE93F6C8"      // M4drive
private let ultra = "D72BF055-A608-4961-BEDD-66F772C8EDFA"   // UltraDrive
private let movies = "/Users/rickb/Movies"

private func rec(_ path: String, volume: String?) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.sizeBytes = 1_000_000
    r.streamTypeRaw = StreamType.videoAndAudio.rawValue
    if let volume { r.scanContext.volumeUUID = volume }
    return r
}

/// The 2026-10-30 catalog shape: 9 live files on the M4 under ~/Movies.
private func m4Movies(_ dir: String = movies) -> [VideoRecord] {
    (1...9).map { rec("\(dir)/clip\($0).mov", volume: m4) }
}
private func ultraMovies(_ dir: String = movies) -> [VideoRecord] {
    (1...3).map { rec("\(dir)/own\($0).mov", volume: ultra) }
}

/// A path no mount table has: `ScanTargetVolume.uuid(forPath:)` is nil, so
/// only memory or rows can tell the location its volume.
private func offlinePath() -> String { "/Volumes/NoSuch-\(UUID().uuidString.prefix(8))/Movies" }

@Suite("Scan location volume (#401)")
struct ScanLocationVolumeTests {

    let ultraMoviesTarget = UUID()

    // MARK: Truth — a location on volume B shows none of volume A's files

    @Test func filesOnAnotherVolumeAreNotCountedUnderTheSamePath() {
        let buckets = VolumeMediaTally.compute(
            m4Movies(), targets: [(ultraMoviesTarget, movies)], targetVolumes: [ultraMoviesTarget: ultra])
        let b = buckets[ultraMoviesTarget]
        #expect(b?.liveFiles == 0)
        #expect(b?.liveBytes == 0)
        #expect(b?.history.isEmpty == true)
    }

    @Test func deleteMenuCountIsZeroForAnotherVolumesFiles() {
        let facts = ScanTargetRecordFacts.project(
            m4Movies(), targets: [(ultraMoviesTarget, movies)], targetVolumes: [ultraMoviesTarget: ultra])
        #expect(facts[ultraMoviesTarget]?.records == 0)
        #expect(facts[ultraMoviesTarget]?.signaturePlan.candidates == 0)
        #expect(facts[ultraMoviesTarget]?.signaturePlan.alreadyHashed == 0)
    }

    /// The data-risk half: removing the Ultra's ~/Movies location must not
    /// claim the M4's rows, nor report them as "kept, covered by another".
    @Test func removalScopeNeverClaimsAnotherVolumesFiles() {
        let scope = TargetRemovalScope(root: movies, allTargetRoots: [movies], volumeUUID: ultra)
        for r in m4Movies() {
            #expect(scope.claims(r) == false)
            #expect(scope.isUnderRoot(r) == false)
        }
    }

    @Test func sameVolumeFilesAreUnchanged() {
        let all = ultraMovies() + m4Movies()
        let b = VolumeMediaTally.compute(all, targets: [(ultraMoviesTarget, movies)],
                                         targetVolumes: [ultraMoviesTarget: ultra])[ultraMoviesTarget]
        #expect(b?.liveFiles == 3)
        #expect(ScanTargetRecordFacts.project(all, targets: [(ultraMoviesTarget, movies)],
                                              targetVolumes: [ultraMoviesTarget: ultra])[ultraMoviesTarget]?.records == 3)
        let scope = TargetRemovalScope(root: movies, allTargetRoots: [movies], volumeUUID: ultra)
        #expect(all.filter(scope.claims).count == 3)
    }

    // MARK: The four `agree` cases (strict, 2026-11-02)

    /// RED on the 2026-10-30 cut (9 files): a location that cannot name
    /// its volume never shows a file that names another disk.
    @Test func unknownLocationNeverShowsAFileThatNamesAnotherDisk() {
        let b = VolumeMediaTally.compute(m4Movies(), targets: [(ultraMoviesTarget, movies)])[ultraMoviesTarget]
        #expect(b?.liveFiles == 0)
        #expect(b?.history.isEmpty == true)
        #expect(ScanTargetRecordFacts.project(m4Movies(), targets: [(ultraMoviesTarget, movies)])[ultraMoviesTarget]?.records == 0)
        let unknown = TargetRemovalScope(root: movies, allTargetRoots: [movies])
        #expect(m4Movies().filter(unknown.claims).isEmpty)
        #expect(m4Movies().filter(unknown.isUnderRoot).isEmpty)
    }

    /// RED on the 2026-10-30 cut: a location that knows its volume never
    /// shows a file that cannot say it is there.
    @Test func knownLocationNeverShowsAFileWithoutEvidence() {
        let noEvidence = [rec("\(movies)/old.mov", volume: nil)]
        #expect(VolumeMediaTally.compute(noEvidence, targets: [(ultraMoviesTarget, movies)],
                                         targetVolumes: [ultraMoviesTarget: ultra])[ultraMoviesTarget]?.liveFiles == 0)
        #expect(ScanTargetRecordFacts.project(noEvidence, targets: [(ultraMoviesTarget, movies)],
                                              targetVolumes: [ultraMoviesTarget: ultra])[ultraMoviesTarget]?.records == 0)
        let known = TargetRemovalScope(root: movies, allTargetRoots: [movies], volumeUUID: ultra)
        #expect(noEvidence.filter(known.claims).isEmpty)
    }

    /// No volume evidence anywhere (a pre-provenance catalog, test
    /// fixtures): nothing claims the file is elsewhere; the path rule
    /// stands, exactly as before #401.
    @Test func noEvidenceAnywhereKeepsThePathRule() {
        let noEvidence = [rec("\(movies)/old.mov", volume: nil)]
        #expect(VolumeMediaTally.compute(noEvidence, targets: [(ultraMoviesTarget, movies)])[ultraMoviesTarget]?.liveFiles == 1)
        #expect(ScanTargetRecordFacts.project(noEvidence, targets: [(ultraMoviesTarget, movies)])[ultraMoviesTarget]?.records == 1)
        let unknown = TargetRemovalScope(root: movies, allTargetRoots: [movies])
        #expect(noEvidence.filter(unknown.claims).count == 1)
    }

    /// Brief test (3): a location with no mounted volume shows its history
    /// by UUID — its own disk's rows at the path, none of the other disk's.
    @Test func offlineLocationShowsItsHistoryByUUID() {
        let all = m4Movies() + ultraMovies()
        let b = VolumeMediaTally.compute(all, targets: [(ultraMoviesTarget, movies)],
                                         targetVolumes: [ultraMoviesTarget: ultra])[ultraMoviesTarget]
        #expect(b?.liveFiles == 3)
        #expect(b?.history.count == 3)
        #expect(b?.history.allSatisfy { $0.evidencedVolumeUUID == ultra } == true)
        #expect(ScanTargetRecordFacts.project(all, targets: [(ultraMoviesTarget, movies)],
                                              targetVolumes: [ultraMoviesTarget: ultra])[ultraMoviesTarget]?.records == 3)
        let scope = TargetRemovalScope(root: movies, allTargetRoots: [movies], volumeUUID: ultra)
        #expect(all.filter(scope.claims).count == 3)
        #expect(m4Movies().filter(scope.claims).isEmpty)
    }

    /// A file moved between drives keeps its old scan volume; its fixity
    /// stamp says where it is now (6 such live rows on 2026-10-30). It must
    /// stay counted on the drive it is on.
    @Test func movedFileWithStaleScanVolumeStaysOnItsNewDrive() {
        let projects = UUID()
        let r = rec("/Volumes/Projects/a.mov", volume: m4)
        r.contentFixity = ContentFixity(
            digest: "ab", byteCount: 1,
            stamp: FileIdentityStamp(device: 1, inode: 2, size: 1, mtimeNs: 3, volumeUUID: ultra))
        #expect(VolumeMediaTally.compute([r], targets: [(projects, "/Volumes/Projects")],
                                         targetVolumes: [projects: ultra])[projects]?.liveFiles == 1)
    }

    /// Codex #184 P1: a location nested under a location on ANOTHER drive.
    /// The other location does not cover this drive's file, so the Delete
    /// count and the removal plan must both own it (the #1393 contract).
    @Test func nestedDifferentVolumesMatchRemovalCount() {
        let parent = UUID(), child = UUID()
        let root = "/Volumes/Projects"
        let r = rec(root + "/a.mov", volume: ultra)
        let facts = ScanTargetRecordFacts.project(
            [r], targets: [(parent, "/Volumes"), (child, root)],
            targetVolumes: [parent: m4, child: ultra])
        let scope = TargetRemovalScope(
            root: root, allTargets: [("/Volumes", m4), (root, ultra)], volumeUUID: ultra)
        #expect(facts[child]?.records == 1)
        #expect([r].filter(scope.claims).count == 1)
        // Same drive nested: the parent covers it, neither owns it (unchanged).
        let sameDrive = TargetRemovalScope(
            root: root, allTargets: [("/Volumes", ultra), (root, ultra)], volumeUUID: ultra)
        #expect([r].filter(sameDrive.claims).isEmpty)
        #expect(ScanTargetRecordFacts.project(
            [r], targets: [(parent, "/Volumes"), (child, root)],
            targetVolumes: [parent: ultra, child: ultra])[child]?.records == 0)
    }

    // MARK: How a location is told its volume (ScanTargetVolume.resolve)

    /// Memory outranks rows: an offline location last seen on the Ultra is
    /// the Ultra's, whatever disk the rows at its path name.
    @Test func offlineLocationIsToldByItsMemory() {
        let id = UUID(), path = offlinePath()
        let volumes = ScanTargetVolume.resolve([(id, path, ultra)], records: m4Movies(path))
        #expect(volumes[id] == ultra)
        // Memory is normalized like every other reading of the identity.
        #expect(ScanTargetVolume.resolve([(id, path, ultra.lowercased())], records: [])[id] == ultra)
    }

    /// A legacy entry (never seen mounted on this build) is told by its
    /// rows when they are unanimous — a nested child by its own rows.
    @Test func legacyOfflineLocationIsToldByUnanimousRows() {
        let parent = UUID(), child = UUID(), path = offlinePath()
        let rows = m4Movies(path) + m4Movies(path + "/2019")
        let volumes = ScanTargetVolume.resolve(
            [(parent, path, nil), (child, path + "/2019", nil)], records: rows)
        #expect(volumes[parent] == m4)
        #expect(volumes[child] == m4)
    }

    /// Isolation: rows that disagree, rows without evidence, no rows, and
    /// garbage memory all leave the location unknown — never a guess.
    @Test func legacyOfflineLocationWithDisagreeingRowsIsUnknown() {
        let id = UUID(), path = offlinePath()
        #expect(ScanTargetVolume.resolve([(id, path, nil)], records: m4Movies(path) + ultraMovies(path))[id] == nil)
        #expect(ScanTargetVolume.resolve([(id, path, nil)], records: [rec("\(path)/x.mov", volume: nil)])[id] == nil)
        #expect(ScanTargetVolume.resolve([(id, path, nil)], records: [])[id] == nil)
        #expect(ScanTargetVolume.resolve([(id, path, "00000000-0000-0000-0000-000000000000")],
                                         records: m4Movies(path) + ultraMovies(path))[id] == nil)
        // A sibling's rows are not this location's ("/Volumes/X" vs "/Volumes/X2").
        #expect(ScanTargetVolume.resolve([(id, path, nil)], records: m4Movies(path + "2"))[id] == nil)
    }

    /// The mount outranks memory and rows: the P0 shape — ~/Movies is
    /// mounted on the Ultra while every row at that path names the M4.
    @Test func mountedLocationIsToldByItsMount() {
        let id = UUID()
        let volumes = VolumeIdentity.$resolverOverride.withValue({ _ in ultra }) {
            ScanTargetVolume.resolve([(id, movies, m4)], records: m4Movies())
        }
        #expect(volumes[id] == ultra)
    }

    /// Codex #210 F3, the rule itself with injected mount tables: the
    /// deepest mount point containing the path decides, and only a LOCAL
    /// one says yes — a share under /Volumes, a share mounted inside the
    /// home folder, and a path on "/" itself.
    @Test func localityIsDecidedByTheDeepestMountPoint() {
        let mounted: Set<String> = ["/", "/Volumes/Projects", "/Volumes/NAS", "/Users/rickb/Shares/office", "/System/Volumes/Data"]
        let local: Set<String> = ["/", "/Volumes/Projects", "/System/Volumes/Data"]
        #expect(ScanTargetVolume.isOnLocalMount("/Volumes/Projects/a.mov", mounted: mounted, local: local))
        #expect(ScanTargetVolume.isOnLocalMount("/Volumes/Projects", mounted: mounted, local: local))
        #expect(!ScanTargetVolume.isOnLocalMount("/Volumes/NAS/a.mov", mounted: mounted, local: local), "an SMB share under /Volumes")
        #expect(!ScanTargetVolume.isOnLocalMount("/Users/rickb/Shares/office/x", mounted: mounted, local: local), "a share inside the home folder")
        #expect(ScanTargetVolume.isOnLocalMount("/Users/rickb/Shares", mounted: mounted, local: local), "its parent is on the boot disk")
        #expect(ScanTargetVolume.isOnLocalMount("/System/Volumes/Data/x", mounted: mounted, local: local))
        #expect(!ScanTargetVolume.isOnLocalMount("/Volumes/Projects2/a.mov", mounted: ["/", "/Volumes/Projects"], local: ["/Volumes/Projects"]),
                "a sibling mount name is not the mount; the path is on '/', which is not in the local set here")
        #expect(!ScanTargetVolume.isOnLocalMount("/anything", mounted: [], local: []), "an empty table says nothing")
    }

    // MARK: Scale

    /// The pass runs inside the coalesced recompute on the main actor; the
    /// volume check and the resolver must not change its cost class.
    @Test func hundredThousandRowsTwentyTargetsWithinBudget() {
        let targets = (0..<20).map { (UUID(), "/Volumes/V\($0)") }
        var vols: [UUID: String] = [:]
        for (i, t) in targets.enumerated() { vols[t.0] = i.isMultiple(of: 2) ? ultra : m4 }
        let records = (0..<100_000).map { i in
            rec("/Volumes/V\(i % 20)/f\(i).mov", volume: i.isMultiple(of: 3) ? m4 : ultra)
        }
        let start = Date()
        _ = VolumeMediaTally.compute(records, targets: targets, targetVolumes: vols)
        _ = ScanTargetRecordFacts.project(records, targets: targets, targetVolumes: vols)
        // Twenty legacy offline locations told by 100k rows in one pass.
        let resolved = ScanTargetVolume.resolve(targets.map { ($0.0, $0.1, nil) }, records: records)
        let elapsed = Date().timeIntervalSince(start)
        #expect(resolved.isEmpty, "every root mixes both disks: unknown, not a guess")
        #expect(elapsed < PerformanceLane.debugCeiling(seconds: 10.0))
    }
}

// MARK: - The planner and the memory, on the model

@Suite(.serialized) @MainActor
struct ScanLocationVolumeModelTests {

    private func makeModel() throws -> (VideoScanModel, URL) {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("scan-location-volume-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()
        model.records = []
        return (model, tmp)
    }

    /// A real, existing folder under `tmp`: reachable by rule (not under
    /// /Volumes) and present on disk, so `ScanTargetVolume.uuid(forPath:)`
    /// reaches `VolumeIdentity.uuid`, which the task-local seam answers.
    private func mounted(_ tmp: URL, _ name: String) throws -> String {
        let dir = tmp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    /// Brief test (1), the data-risk half on the model: the removal plan
    /// for a location on volume B removes nothing of volume A's, even when
    /// the location is offline and only its memory names B.
    @Test func removalPlanForAnOfflineLocationRemovesOnlyItsOwnDisk() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = offlinePath()
        let target = CatalogScanTarget(searchPath: path)
        target.volumeUUID = ultra
        model.scanTargets = [target]
        let theirs = m4Movies(path), mine = ultraMovies(path)
        model.records = theirs + mine

        let plan = model.planTargetRemoval(for: target)
        #expect(plan.count == 3)
        #expect(plan.recordIDs == Set(mine.map(\.id)))
        #expect(plan.keptCoveredByOtherTargets == 0, "another disk's rows are not 'kept, covered by another target'")

        let result = model.deleteCatalogForTarget(target, plan: plan)
        #expect(result == .applied(removed: 3, snapshotPath: nil))
        #expect(Set(model.records.map(\.id)) == Set(theirs.map(\.id)), "the M4's rows survive untouched")
    }

    /// A legacy offline location whose rows name two disks is unknown: the
    /// guarded removal refuses rather than guesses — nothing is removed.
    @Test func removalPlanForALegacyLocationWithDisagreeingRowsRemovesNothing() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = offlinePath()
        let target = CatalogScanTarget(searchPath: path)
        model.scanTargets = [target]
        model.records = m4Movies(path) + ultraMovies(path)

        let plan = model.planTargetRemoval(for: target)
        #expect(plan.recordIDs.isEmpty)
        #expect(plan.keptCoveredByOtherTargets == 0)
        let outcome = model.removeCatalogRecords(underTargetRoot: path, action: "reset")
        #expect(outcome.removed == 0)
        #expect(model.records.count == 12)
    }

    /// A legacy offline location whose rows are unanimous removes exactly
    /// those rows (the pre-#401 count, now by UUID).
    @Test func removalPlanForALegacyLocationWithUnanimousRowsRemovesThem() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = offlinePath()
        let target = CatalogScanTarget(searchPath: path)
        model.scanTargets = [target]
        model.records = m4Movies(path) + m4Movies(movies)   // nine here, nine elsewhere
        let plan = model.planTargetRemoval(for: target)
        #expect(plan.count == 9)
        #expect(plan.recordIDs == Set(model.records.prefix(9).map(\.id)))
    }

    // MARK: Codex 2026-11-02 (cycle #209), three P1s on the planner and the memory

    /// Codex F1: two registrations of one path, each remembering a different
    /// disk. The plan for the SECOND must use ITS memory, not the first's —
    /// and equal the Delete menu's count for it.
    @Test func duplicatePathPlannerUsesSelectedTargetsVolume() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = offlinePath()
        let first = CatalogScanTarget(searchPath: path), second = CatalogScanTarget(searchPath: path)
        first.volumeUUID = m4
        second.volumeUUID = ultra
        model.scanTargets = [first, second]
        let theirs = m4Movies(path), mine = ultraMovies(path)
        model.records = theirs + mine

        let plan = model.planTargetRemoval(for: second)
        #expect(plan.recordIDs == Set(mine.map(\.id)), "the second registration removes only the Ultra's rows")
        #expect(model.planTargetRemoval(for: first).recordIDs == Set(theirs.map(\.id)))
        let volumes = ScanTargetVolume.resolve(model.scanTargets.map { ($0.id, $0.searchPath, $0.volumeUUID) },
                                               records: model.records)
        let facts = ScanTargetRecordFacts.project(model.records,
                                                  targets: model.scanTargets.map { ($0.id, $0.searchPath) },
                                                  targetVolumes: volumes)
        #expect(facts[second.id]?.records == plan.count, "shown count == planned count")
    }

    /// Codex F2: Browse… to a folder on another disk must not carry the old
    /// path's memory along. The new mount is learned at the repoint; an
    /// offline new path leaves the location unknown, so mixed rows under
    /// it are never removed on the strength of the old disk's identity.
    @Test func browseToAnotherDiskDropsTheOldPathsMemory() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Real folders under the test's temp dir: reachable (not /Volumes)
        // and existing, so the mount tier answers through the seam.
        let moviesDir = try mounted(tmp, "Movies"), picturesDir = try mounted(tmp, "Pictures")
        let target = CatalogScanTarget(searchPath: moviesDir)
        target.volumeUUID = m4
        model.scanTargets = [target]

        // Mounted new path on disk B: learned at the repoint.
        let moved = VolumeIdentity.$resolverOverride.withValue({ _ in ultra }) {
            model.repointScanTarget(target, to: picturesDir)
        }
        #expect(moved)
        #expect(target.volumeUUID == ultra, "the new mount is learned, the old memory dropped")

        // Offline new path: nothing known; the rows decide, and mixed rows
        // leave the location unknown — the plan removes nothing.
        let offline = offlinePath()
        #expect(model.repointScanTarget(target, to: offline))
        #expect(target.volumeUUID == nil, "an offline new path keeps no memory of the old one")
        model.records = m4Movies(offline) + ultraMovies(offline)
        #expect(model.planTargetRemoval(for: target).recordIDs.isEmpty)
    }

    /// Codex F3: learning a different disk between the confirmation and
    /// the apply must invalidate the confirmed plan — the revision moves,
    /// the apply refuses with a fresh plan, nothing is removed.
    @Test func volumeLearningInvalidatesConfirmedRemoval() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let moviesDir = try mounted(tmp, "Movies")
        let target = CatalogScanTarget(searchPath: moviesDir)
        model.scanTargets = [target]
        let aRows = m4Movies(moviesDir), bRows = ultraMovies(moviesDir)
        model.records = aRows + bRows

        // The mount says disk A: the plan is A's nine rows.
        let plan = VolumeIdentity.$resolverOverride.withValue({ _ in m4 }) {
            model.planTargetRemoval(for: target)
        }
        #expect(plan.recordIDs == Set(aRows.map(\.id)))

        // The drive is swapped under the same path; a reachability refresh
        // (the probe callback's path, no mount notification) learns disk B.
        let before = model.catalogMutationRevision
        VolumeIdentity.$resolverOverride.withValue({ _ in ultra }) {
            model.refreshTargetReachability()
        }
        #expect(target.volumeUUID == ultra)
        #expect(model.catalogMutationRevision != before, "learning a disk is a catalog-shape change")

        let result = VolumeIdentity.$resolverOverride.withValue({ _ in ultra }) {
            model.deleteCatalogForTarget(target, plan: plan)
        }
        guard case .refusedStale(let current) = result else {
            Issue.record("expected .refusedStale, got \(result)")
            return
        }
        #expect(current.recordIDs == Set(bRows.map(\.id)), "the fresh plan is disk B's rows")
        #expect(model.records.count == 12, "nothing removed")
    }

    // MARK: Codex 2026-11-02 closing pass (cycle #210)

    /// Codex #210 F1: a SELECTED target whose memory is unknown is not a
    /// bare root — it must never take another registration's memory. With
    /// mixed rows under the path it is unknown and owns nothing, through
    /// the plan, the Delete count, reset and the unplanned delete.
    @Test func selectedTargetWithUnknownMemoryNeverBorrowsAnother() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let path = offlinePath()
        let first = CatalogScanTarget(searchPath: path), second = CatalogScanTarget(searchPath: path)
        first.volumeUUID = m4
        second.volumeUUID = nil
        model.scanTargets = [first, second]
        model.records = m4Movies(path) + ultraMovies(path)

        #expect(model.planTargetRemoval(for: second).recordIDs.isEmpty, "unknown owns nothing; the M4's memory is not hers")
        let volumes = ScanTargetVolume.resolve(model.scanTargets.map { ($0.id, $0.searchPath, $0.volumeUUID) },
                                               records: model.records)
        #expect(ScanTargetRecordFacts.project(model.records,
                                              targets: model.scanTargets.map { ($0.id, $0.searchPath) },
                                              targetVolumes: volumes)[second.id]?.records == 0)
        model.resetTarget(second)
        #expect(model.records.count == 12, "reset of an unknown location removes nothing")
        model.deleteCatalogForTarget(second)
        #expect(model.records.count == 12, "unplanned delete of an unknown location removes nothing")
    }

    /// Codex #210 F2: a confirmation expires when the location's identity
    /// changes, even when the record set is the same (here: empty) — the
    /// plan carries the disk it was made for.
    @Test func identityChangeIsRefusedEvenWithAnEmptyPlan() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let moviesDir = try mounted(tmp, "Movies")
        let target = CatalogScanTarget(searchPath: moviesDir)
        target.phase = .cataloged
        model.scanTargets = [target]
        model.records = []

        let plan = VolumeIdentity.$resolverOverride.withValue({ _ in m4 }) { model.planTargetRemoval(for: target) }
        #expect(plan.recordIDs.isEmpty)
        VolumeIdentity.$resolverOverride.withValue({ _ in ultra }) { model.refreshTargetReachability() }
        let result = VolumeIdentity.$resolverOverride.withValue({ _ in ultra }) {
            model.deleteCatalogForTarget(target, plan: plan)
        }
        guard case .refusedStale = result else {
            Issue.record("expected .refusedStale, got \(result)")
            return
        }
        #expect(target.phase == .cataloged, "a refused plan leaves target state untouched")
    }

    /// The refresh learns a mounted location's volume from its mount,
    /// re-learns a swapped drive, and leaves an offline location's memory
    /// alone.
    @Test func refreshRemembersTheMountedVolume() throws {
        let (model, tmp) = try makeModel()
        defer { try? FileManager.default.removeItem(at: tmp) }
        let mounted = CatalogScanTarget(searchPath: movies)      // reachable by rule (not /Volumes)
        let offline = CatalogScanTarget(searchPath: offlinePath())
        offline.volumeUUID = m4
        model.scanTargets = [mounted, offline]
        #expect(mounted.volumeUUID == nil)

        let learned = VolumeIdentity.$resolverOverride.withValue({ _ in ultra }) {
            model.rememberScanTargetVolumes()
        }
        #expect(learned == 1)
        #expect(mounted.volumeUUID == ultra)
        #expect(offline.volumeUUID == m4, "an offline location keeps what it knew")

        let again = VolumeIdentity.$resolverOverride.withValue({ _ in ultra }) {
            model.rememberScanTargetVolumes()
        }
        #expect(again == 0, "nothing changed: nothing to persist")

        let swapped = VolumeIdentity.$resolverOverride.withValue({ _ in m4 }) {
            model.rememberScanTargetVolumes()
        }
        #expect(swapped == 1)
        #expect(mounted.volumeUUID == m4, "a different disk at the same path re-learns")
    }

    /// The memory survives a relaunch: persisted beside the other per-path
    /// fields, restored to the same location, absent key → nil.
    @Test func rememberedVolumeRoundTripsThroughUserDefaults() {
        let prefix = "ScanLocationVolumeTests.\(UUID().uuidString)."
        let keys = ["dates", "phases", "roles", "trust", "fs", "tech", "year", "cap", "notes",
                    "retAt", "retRsn", "retWit", "paths", "vol"].map { prefix + $0 }
        defer { for k in keys { UserDefaults.standard.removeObject(forKey: k) } }
        let t = CatalogScanTarget(searchPath: offlinePath())
        t.volumeUUID = ultra
        let other = CatalogScanTarget(searchPath: offlinePath())
        ScanTargetPersistence.persistPaths([t, other], key: prefix + "paths")
        ScanTargetPersistence.persistMetadata(
            [t, other],
            savedDatesKey: prefix + "dates", savedPhasesKey: prefix + "phases", savedRolesKey: prefix + "roles",
            savedTrustKey: prefix + "trust", savedFilesystemKey: prefix + "fs", savedMediaTechKey: prefix + "tech",
            savedPurchaseYearKey: prefix + "year", savedCapacityKey: prefix + "cap", savedNotesKey: prefix + "notes",
            savedRetiredAtKey: prefix + "retAt", savedRetiredReasonKey: prefix + "retRsn",
            savedRetiredWitnessesKey: prefix + "retWit", savedVolumeUUIDKey: prefix + "vol")
        #expect(UserDefaults.standard.dictionary(forKey: prefix + "vol") as? [String: String] == [t.searchPath: ultra])

        let restored = ScanTargetPersistence.restore(
            existing: [], savedTargetsKey: prefix + "paths",
            savedDatesKey: prefix + "dates", savedPhasesKey: prefix + "phases", savedRolesKey: prefix + "roles",
            savedTrustKey: prefix + "trust", savedFilesystemKey: prefix + "fs", savedMediaTechKey: prefix + "tech",
            savedPurchaseYearKey: prefix + "year", savedCapacityKey: prefix + "cap", savedNotesKey: prefix + "notes",
            savedRetiredAtKey: prefix + "retAt", savedRetiredReasonKey: prefix + "retRsn",
            savedRetiredWitnessesKey: prefix + "retWit", savedVolumeUUIDKey: prefix + "vol")
        #expect(restored.first { $0.searchPath == t.searchPath }?.volumeUUID == ultra)
        #expect(restored.first { $0.searchPath == other.searchPath }?.volumeUUID == nil)
    }
}

// MARK: - Source sensors

@Suite("Scan location volume (#401) — sensors")
struct ScanLocationVolumeSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    /// The pane's recompute and the removal planner are told each
    /// location's volume by the ONE resolver, rows included — not by the
    /// mount alone, not by the reachable subset.
    @Test func thePaneAndThePlannerResolveThroughTheOneFunction() throws {
        let pane = try code("CatalogView+ScanTargetsPane.swift")
        #expect(pane.contains("ScanTargetVolume.resolve("))
        #expect(pane.contains("$0.volumeUUID) }, records: model.records)"))
        #expect(!pane.contains("targets.filter(\\.isReachable).map"), "the reachable-only resolution is back")
        let planner = try code("VideoScanModel+DeleteScanTarget.swift")
        #expect(planner.contains("let volumes = ScanTargetVolume.resolve(ask, records: records)"))
        #expect(!planner.contains("mayBeSameVolume"), "the lenient rule is back")
    }

    /// The context menu's signature coverage reads the cached, volume-aware
    /// projection; the path-only walk over `model.records` is gone.
    @Test func signatureCoverageReadsTheProjection() throws {
        let pane = try code("CatalogView+ScanTargetsPane.swift")
        let start = try #require(pane.range(of: "func signatureCoverage(for target: CatalogScanTarget)"))
        let end = try #require(pane.range(of: "private func recomputeVolumeAggregates() {",
                                          range: start.upperBound..<pane.endIndex))
        let body = String(pane[start.upperBound..<end.lowerBound])
        #expect(body.contains("scanTargetFacts[target.id]?.signaturePlan"))
        #expect(!body.contains("model.records"), "an O(records) walk is back in a context menu")
        #expect(!body.contains("isUnder("), "the path-only scope is back")
    }

    /// Codex #210 F3: telling a location its mounted volume runs on the
    /// main actor (reachability refresh, Browse…). It must classify
    /// local-vs-network from the in-kernel mount table (`getmntinfo`,
    /// MNT_NOWAIT), never through `statfs` on the path — a hung share
    /// would block before the guard could refuse it.
    @Test func mountedVolumeLookupNeverTouchesStatfs() throws {
        let src = try code("VideoScanModel+DeleteScanTarget.swift")
        let start = try #require(src.range(of: "enum ScanTargetVolume {"))
        let end = try #require(src.range(of: "struct TargetRemovalPlan", range: start.upperBound..<src.endIndex))
        let body = String(src[start.upperBound..<end.lowerBound])
        #expect(body.contains("currentLocalMountedRoots()"))
        for forbidden in ["isNetworkVolume(", "mountInfo(", "statfs("] {
            #expect(!body.contains(forbidden), Comment(rawValue: "\(forbidden) can block on a hung share"))
        }
    }

    /// Every production reading of the volume rule goes through `agree`;
    /// the lenient `mayBeSameVolume` no longer exists anywhere.
    @Test func theLenientRuleIsGone() throws {
        for file in ["VolumeMediaTally.swift", "ScanTargetRecordFacts.swift", "VideoScanModel+DeleteScanTarget.swift"] {
            let src = try code(file)
            #expect(src.contains("VolumeIdentity.agree("), Comment(rawValue: file))
            #expect(!src.contains("mayBeSameVolume"), Comment(rawValue: file))
        }
    }
}
