import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

// MARK: - #401 (P0, 2026-10-30): a scan location owns only its own volume's files
//
// Rick's report: the Ultra's ~/Movies location showed "9 files in the
// catalog" while the folder held none. All 9 rows were on the M4's boot disk
// ("M4drive") at the same path /Users/rickb/Movies; the location list came
// over from the M4. The counts and the removal scope matched by path alone.
//
// Dimensions: logic (counts, removal plan, unknown-volume fallback, a moved
// file with a stale scan volume); scale (100k rows × 20 targets, budget);
// isolation N/A beyond pure values (no filesystem, no defaults); truth: the
// figure a location shows is the number of files evidenced on its volume.

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
private func m4Movies() -> [VideoRecord] { (1...9).map { rec("\(movies)/clip\($0).mov", volume: m4) } }

@Suite("Scan location volume (#401)")
struct ScanLocationVolumeTests {

    let ultraMovies = UUID()

    @Test func filesOnAnotherVolumeAreNotCountedUnderTheSamePath() {
        let buckets = VolumeMediaTally.compute(
            m4Movies(), targets: [(ultraMovies, movies)], targetVolumes: [ultraMovies: ultra])
        let b = buckets[ultraMovies]
        #expect(b?.liveFiles == 0)
        #expect(b?.liveBytes == 0)
        #expect(b?.history.isEmpty == true)
    }

    @Test func deleteMenuCountIsZeroForAnotherVolumesFiles() {
        let facts = ScanTargetRecordFacts.project(
            m4Movies(), targets: [(ultraMovies, movies)], targetVolumes: [ultraMovies: ultra])
        #expect(facts[ultraMovies]?.records == 0)
        #expect(facts[ultraMovies]?.signaturePlan.candidates == 0)
        #expect(facts[ultraMovies]?.signaturePlan.alreadyHashed == 0)
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
        let own = (1...3).map { rec("\(movies)/own\($0).mov", volume: ultra) }
        let all = own + m4Movies()
        let b = VolumeMediaTally.compute(all, targets: [(ultraMovies, movies)],
                                         targetVolumes: [ultraMovies: ultra])[ultraMovies]
        #expect(b?.liveFiles == 3)
        #expect(ScanTargetRecordFacts.project(all, targets: [(ultraMovies, movies)],
                                              targetVolumes: [ultraMovies: ultra])[ultraMovies]?.records == 3)
        let scope = TargetRemovalScope(root: movies, allTargetRoots: [movies], volumeUUID: ultra)
        #expect(all.filter(scope.claims).count == 3)
    }

    /// Unknown on either side: the path decides, exactly as before #401
    /// (an unmounted target, a record with no volume evidence).
    @Test func unknownVolumeFallsBackToThePath() {
        let noEvidence = [rec("\(movies)/old.mov", volume: nil)]
        #expect(VolumeMediaTally.compute(noEvidence, targets: [(ultraMovies, movies)],
                                         targetVolumes: [ultraMovies: ultra])[ultraMovies]?.liveFiles == 1)
        #expect(VolumeMediaTally.compute(m4Movies(), targets: [(ultraMovies, movies)])[ultraMovies]?.liveFiles == 9)
        let unmounted = TargetRemovalScope(root: movies, allTargetRoots: [movies])
        #expect(m4Movies().filter(unmounted.claims).count == 9)
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

    /// Scale: the pass runs inside the coalesced recompute on the main
    /// actor; the volume check must not change its cost class.
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
        #expect(Date().timeIntervalSince(start) < 10.0)
    }
}
