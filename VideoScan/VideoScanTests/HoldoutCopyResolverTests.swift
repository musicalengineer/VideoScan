import Testing
import Foundation
@testable import VideoScan

// MARK: - HoldoutCopyResolverTests
//
// Pins the offline-copy preview resolution for the blind holdout review
// (feature/holdout-offline-copy-preview, Rick 2026-07-30).
//
// The resolver's job: a pending holdout row whose recorded file is
// offline (unmounted volume or missing file) should be REVIEWABLE, not
// hidden, whenever a BYTE-IDENTICAL copy exists on a mounted volume. It
// wraps OnlineCopyFinder.sameContentCopies (strong identity only:
// partialMD5+size, or Avid UMID+streamType, or duplicateGroupID) plus a
// fullPath → record index, and injects `isLive` so the whole thing is
// pure logic — no disk, no VolumeReachability. Row identity and answer
// write-back are untouched; the copy is preview-only.
//
// The dangerous regressions here mirror OnlineCopyFinder's: a FALSE
// positive (previewing the wrong file) silently defeats blind review.
// So the negative tests (different-size hash match, name+size-only,
// stale-catalog copy that isn't actually live) carry as much weight as
// the positives.
//
// Swift Testing note (vs the C++/GoogleTest ecosystem Rick knows):
// `#expect(x == y)` is the analog of `EXPECT_EQ(x, y)` — a soft check
// that records a failure but lets the test body continue. There is no
// separate ASSERT_* here; use `#require` (throws) when a later line
// can't run without the value. `@Test func` replaces the TEST() macro;
// the suite is just a struct, and each test gets a fresh instance.

struct HoldoutCopyResolverTests {

    // Same builder shape as OnlineCopyFinderTests — reused verbatim so
    // the two suites can't drift on how a VideoRecord fixture is spelled.
    private func record(path: String,
                        md5: String = "",
                        size: Int64 = 0,
                        umid: String = "",
                        streamType: String = "video+audio",
                        dupGroup: UUID? = nil,
                        purged: Bool = false,
                        setAside: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.directory = (path as NSString).deletingLastPathComponent
        r.filename = (path as NSString).lastPathComponent
        r.partialMD5 = md5
        r.sizeBytes = size
        r.materialPackageUMID = umid
        r.streamTypeRaw = streamType
        r.duplicateGroupID = dupGroup
        if purged { r.purgedAt = Date() }
        if setAside { r.setAsideReason = "user set aside" }
        return r
    }

    /// A liveness closure that treats any path under one of `mounted` as
    /// live — the pure-logic stand-in for "mounted volume + file present".
    private func liveUnder(_ mounted: String...) -> (String) -> Bool {
        { path in mounted.contains(where: { path.hasPrefix($0) }) }
    }

    // MARK: - Logic

    @Test func offlineOriginalWithOneLiveCopyReturnsCopy() {
        let original = record(path: "/Volumes/RicksBackups/clip.mov", md5: "abc", size: 100)
        let copy = record(path: "/Volumes/LaCieWorkspace/clip.mov", md5: "abc", size: 100)
        let resolver = HoldoutCopyResolver(records: [original, copy])
        let live = resolver.liveCopy(for: original.fullPath,
                                     isLive: liveUnder("/Volumes/LaCieWorkspace/"))
        #expect(live == "/Volumes/LaCieWorkspace/clip.mov")
    }

    @Test func multipleCopiesReturnsFirstLiveInDeterministicOrder() {
        // Three same-content copies; the two live ones sort as
        // "/Volumes/AAA/..." < "/Volumes/ZZZ/..." within the hash tier.
        // The FIRST live one in that path-sorted order must win, stably.
        let original = record(path: "/Volumes/RicksBackups/clip.mov", md5: "abc", size: 100)
        let liveEarly = record(path: "/Volumes/AAA/clip.mov", md5: "abc", size: 100)
        let liveLate = record(path: "/Volumes/ZZZ/clip.mov", md5: "abc", size: 100)
        let offlineCopy = record(path: "/Volumes/Shelf/clip.mov", md5: "abc", size: 100)
        let resolver = HoldoutCopyResolver(records: [original, liveLate, offlineCopy, liveEarly])

        let isLive = liveUnder("/Volumes/AAA/", "/Volumes/ZZZ/")
        let first = resolver.liveCopy(for: original.fullPath, isLive: isLive)
        #expect(first == "/Volumes/AAA/clip.mov")

        // Determinism: repeated calls (and a re-built resolver over the
        // same records in a different array order) yield the same answer.
        #expect(resolver.liveCopy(for: original.fullPath, isLive: isLive) == first)
        let reordered = HoldoutCopyResolver(records: [liveEarly, original, offlineCopy, liveLate])
        #expect(reordered.liveCopy(for: original.fullPath, isLive: isLive) == first)
    }

    @Test func noCopiesReturnsNil() {
        let original = record(path: "/Volumes/RicksBackups/lonely.mov", md5: "abc", size: 100)
        let resolver = HoldoutCopyResolver(records: [original])
        #expect(resolver.liveCopy(for: original.fullPath, isLive: { _ in true }) == nil)
        #expect(resolver.copyCandidates(for: original.fullPath).isEmpty)
    }

    @Test func copiesExistButNoneLiveReturnsNil() {
        let original = record(path: "/Volumes/RicksBackups/clip.mov", md5: "abc", size: 100)
        let copy1 = record(path: "/Volumes/Shelf/clip.mov", md5: "abc", size: 100)
        let copy2 = record(path: "/Volumes/ColdStore/clip.mov", md5: "abc", size: 100)
        let resolver = HoldoutCopyResolver(records: [original, copy1, copy2])
        // isLive false for everything → no reviewable copy.
        #expect(resolver.liveCopy(for: original.fullPath, isLive: { _ in false }) == nil)
        // ...but the candidates ARE enumerated (liveness is the caller's job).
        #expect(resolver.copyCandidates(for: original.fullPath).count == 2)
    }

    @Test func originalNotInCatalogReturnsNil() {
        // We can only strong-match a path we have a record for. An
        // unknown original can't be resolved (sweep keeps it hidden).
        let known = record(path: "/Volumes/LaCieWorkspace/clip.mov", md5: "abc", size: 100)
        let resolver = HoldoutCopyResolver(records: [known])
        #expect(resolver.liveCopy(for: "/Volumes/RicksBackups/ghost.mov",
                                  isLive: { _ in true }) == nil)
        #expect(resolver.copyCandidates(for: "/Volumes/RicksBackups/ghost.mov").isEmpty)
    }

    // MARK: - Logic: match tiers

    @Test func partialMD5PlusSizeMatchResolves() {
        let original = record(path: "/Volumes/RicksBackups/a.mov", md5: "h1", size: 42)
        let copy = record(path: "/Volumes/LaCieWorkspace/a.mov", md5: "h1", size: 42)
        let resolver = HoldoutCopyResolver(records: [original, copy])
        #expect(resolver.liveCopy(for: original.fullPath,
                                  isLive: liveUnder("/Volumes/LaCieWorkspace/"))
                == "/Volumes/LaCieWorkspace/a.mov")
    }

    @Test func umidPlusStreamTypeMatchResolves() {
        // Avid MXF: the video-only file finds its video-only copy by
        // shared material-package UMID; the audio sibling (same UMID,
        // different streamType) must NOT be offered as the preview.
        let original = record(path: "/Volumes/RicksBackups/clip_v.mxf",
                              umid: "U1", streamType: "video-only")
        let audioSibling = record(path: "/Volumes/LaCieWorkspace/clip_a.mxf",
                                  umid: "U1", streamType: "audio-only")
        let videoCopy = record(path: "/Volumes/LaCieWorkspace/clip_v.mxf",
                               umid: "U1", streamType: "video-only")
        let resolver = HoldoutCopyResolver(records: [original, audioSibling, videoCopy])
        let live = resolver.liveCopy(for: original.fullPath,
                                     isLive: liveUnder("/Volumes/LaCieWorkspace/"))
        #expect(live == "/Volumes/LaCieWorkspace/clip_v.mxf")
        #expect(resolver.copyCandidates(for: original.fullPath)
                == ["/Volumes/LaCieWorkspace/clip_v.mxf"])   // audio sibling excluded
    }

    @Test func duplicateGroupIDMatchResolves() {
        let g = UUID()
        let original = record(path: "/Volumes/RicksBackups/clip.mov", dupGroup: g)
        let copy = record(path: "/Volumes/LaCieWorkspace/clip_copy.mov", dupGroup: g)
        let unrelated = record(path: "/Volumes/LaCieWorkspace/other.mov", dupGroup: UUID())
        let resolver = HoldoutCopyResolver(records: [original, copy, unrelated])
        #expect(resolver.liveCopy(for: original.fullPath,
                                  isLive: liveUnder("/Volumes/LaCieWorkspace/"))
                == "/Volumes/LaCieWorkspace/clip_copy.mov")
    }

    @Test func partialMD5MatchWithDifferentSizeDoesNotResolve() {
        // Strong identity requires size too — a hash match at a different
        // byte count is not the same file.
        let original = record(path: "/Volumes/RicksBackups/clip.mov", md5: "h1", size: 100)
        let notReally = record(path: "/Volumes/LaCieWorkspace/clip.mov", md5: "h1", size: 999)
        let resolver = HoldoutCopyResolver(records: [original, notReally])
        #expect(resolver.liveCopy(for: original.fullPath, isLive: { _ in true }) == nil)
        #expect(resolver.copyCandidates(for: original.fullPath).isEmpty)
    }

    // Blindness-critical negative: NO name+size fallback. Two files with
    // the same filename and same byte count but DIFFERENT content hashes
    // must never be treated as copies — that's exactly the wrong-preview
    // failure the feature was designed to avoid.
    @Test func sameNameSameSizeDifferentHashDoesNotResolve() {
        let original = record(path: "/Volumes/RicksBackups/IMG_0532.MOV", md5: "hashA", size: 100)
        let impostor = record(path: "/Volumes/LaCieWorkspace/IMG_0532.MOV", md5: "hashB", size: 100)
        let resolver = HoldoutCopyResolver(records: [original, impostor])
        #expect(resolver.liveCopy(for: original.fullPath, isLive: { _ in true }) == nil)
        #expect(resolver.copyCandidates(for: original.fullPath).isEmpty)
    }

    @Test func purgedAndSetAsideRecordsNeverResolveAsCopyTarget() {
        // Mirror OnlineCopyFinder: a purged or set-aside record is not a
        // valid preview target even if its content matches.
        let original = record(path: "/Volumes/RicksBackups/clip.mov", md5: "abc", size: 100)
        let purgedCopy = record(path: "/Volumes/LaCieWorkspace/purged.mov",
                                md5: "abc", size: 100, purged: true)
        let setAsideCopy = record(path: "/Volumes/LaCieWorkspace/aside.mov",
                                  md5: "abc", size: 100, setAside: true)
        let resolver = HoldoutCopyResolver(records: [original, purgedCopy, setAsideCopy])
        #expect(resolver.copyCandidates(for: original.fullPath).isEmpty)
        #expect(resolver.liveCopy(for: original.fullPath, isLive: { _ in true }) == nil)
    }

    // MARK: - Isolation
    //
    // The catalog is a snapshot; the disk is live. A record the catalog
    // knows can be missing on disk RIGHT NOW. `isLive` is the only source
    // of truth for "usable now", and a stale catalog entry must never win.

    @Test func catalogKnownCopyThatIsNotLiveIsSkipped() {
        // Only one copy, and the catalog has it — but isLive says its
        // file is gone. Result must be nil (not the stale path).
        let original = record(path: "/Volumes/RicksBackups/clip.mov", md5: "abc", size: 100)
        let staleCopy = record(path: "/Volumes/LaCieWorkspace/clip.mov", md5: "abc", size: 100)
        let resolver = HoldoutCopyResolver(records: [original, staleCopy])
        // Volume mounted for OTHER paths, but this specific file is missing.
        let isLive: (String) -> Bool = { $0 != "/Volumes/LaCieWorkspace/clip.mov" }
        #expect(resolver.liveCopy(for: original.fullPath, isLive: isLive) == nil)
        // The candidate is still enumerated — the skip is a liveness
        // decision, not a catalog one.
        #expect(resolver.copyCandidates(for: original.fullPath)
                == ["/Volumes/LaCieWorkspace/clip.mov"])
    }

    @Test func staleCopySkippedButLiveSiblingStillWins() {
        // Two catalog copies; the alphabetically-first is stale (missing
        // on disk), the second is live → resolver falls through to the
        // live one rather than returning nil or the stale path.
        let original = record(path: "/Volumes/RicksBackups/clip.mov", md5: "abc", size: 100)
        let staleFirst = record(path: "/Volumes/AAA/clip.mov", md5: "abc", size: 100)
        let liveSecond = record(path: "/Volumes/BBB/clip.mov", md5: "abc", size: 100)
        let resolver = HoldoutCopyResolver(records: [original, staleFirst, liveSecond])
        let isLive: (String) -> Bool = { $0 == "/Volumes/BBB/clip.mov" }
        #expect(resolver.liveCopy(for: original.fullPath, isLive: isLive)
                == "/Volumes/BBB/clip.mov")
    }

    // MARK: - Sensor (regression)

    // regression: a pending holdout row on an unmounted volume, WITH a
    // byte-identical copy on a mounted volume, was being hidden behind
    // "reconnect the drive" instead of previewed via the live copy. This
    // is Rick's real scenario in miniature — 5 pending rows on the
    // unmounted /Volumes/RicksBackups/, each with a verified copy on the
    // mounted /Volumes/LaCieWorkspace/. The resolver MUST return the copy
    // path (so the row stays reviewable), never nil. If this ever returns
    // nil again, offline-with-a-live-copy rows have gone dark.
    @Test func regression_offlineRowWithLiveCopyIsReviewableNotHidden() {
        let original = record(path: "/Volumes/RicksBackups/2010/IMG_0532.MOV",
                              md5: "deadbeef", size: 8_675_309)
        let liveCopy = record(path: "/Volumes/LaCieWorkspace/2010/IMG_0532.MOV",
                              md5: "deadbeef", size: 8_675_309)
        let resolver = HoldoutCopyResolver(records: [original, liveCopy])

        // The original's OWN volume is offline (isLive false for its path),
        // the copy's volume is mounted (isLive true).
        let isLive = liveUnder("/Volumes/LaCieWorkspace/")
        #expect(isLive(original.fullPath) == false)         // original offline
        let resolved = resolver.liveCopy(for: original.fullPath, isLive: isLive)
        #expect(resolved == "/Volumes/LaCieWorkspace/2010/IMG_0532.MOV")
        #expect(resolved != nil, "offline row with a live byte-identical copy must be reviewable")
    }
}

// MARK: - ConfirmPersonSheetSweepMergeTests
//
// Pins ConfirmPersonSheet.mergeSweepResult — the pure set-algebra that
// combines the offline-sweep verdict with the per-row backstop flags and
// then removes anything the sweep resolved to a live copy. QA flagged
// this merge as the likeliest future regression site (2026-07-30): the
// tempting "simplify to a plain union" edit would silently re-hide rows
// the sweep just made reviewable.
//
// Contract (from the impl / call site):
//   excluded == offline.union(backstop).subtracting(resolved.keys)
//   resolved passes through unchanged.
// The subtraction is applied to the WHOLE union, so a resolved path is
// removed from `excluded` no matter which input put it there — offline,
// backstop, or both. Resolution is authoritative because it statted a
// live byte-identical copy.
//
// mergeSweepResult is `nonisolated static` (internal) → reachable under
// @testable import with no main-actor hop and no disk. The sibling
// `sweepOfflinePaths` is deliberately NOT tested here: it is `private`
// (unreachable even under @testable) AND it does real FileManager /
// VolumeReachability.currentMountedRoots() stats, so a hermetic unit test
// would require faking real mounts — out of scope. See the note in the
// task report.

struct ConfirmPersonSheetSweepMergeTests {

    private func merge(offline: Set<String>,
                       backstop: Set<String>,
                       resolved: [String: String])
    -> (excluded: Set<String>, resolved: [String: String]) {
        ConfirmPersonSheet.mergeSweepResult(offline: offline,
                                            backstop: backstop,
                                            resolved: resolved)
    }

    // regression: a plain `offline.union(backstop)` (dropping the
    // .subtracting(resolved.keys)) would silently re-hide a row the sweep
    // resolved to a live copy. This pins that a path present in BOTH
    // `offline` AND `resolved.keys` is NOT excluded — the exact
    // "someone simplifies back to a union" guard.
    @Test func regression_resolvedPathInOfflineIsRemovedFromExcluded() {
        let m = merge(
            offline: ["/Volumes/RicksBackups/a.mov", "/Volumes/RicksBackups/b.mov"],
            backstop: [],
            resolved: ["/Volumes/RicksBackups/a.mov": "/Volumes/LaCieWorkspace/a.mov"])
        #expect(!m.excluded.contains("/Volumes/RicksBackups/a.mov"),
                "a resolved path must never remain in the offline-excluded set")
        #expect(m.excluded == ["/Volumes/RicksBackups/b.mov"])
        // resolved rides through untouched.
        #expect(m.resolved == ["/Volumes/RicksBackups/a.mov": "/Volumes/LaCieWorkspace/a.mov"])
    }

    // regression: a backstop-flagged path with no resolution must stay
    // hidden — the merge must carry backstop flags into `excluded`, not
    // drop them.
    @Test func regression_backstopInsertedPathWithoutResolutionStaysExcluded() {
        let m = merge(
            offline: ["/Volumes/RicksBackups/a.mov"],
            backstop: ["/Volumes/RicksBackups/late.mov"],
            resolved: [:])
        #expect(m.excluded == ["/Volumes/RicksBackups/a.mov", "/Volumes/RicksBackups/late.mov"])
    }

    // regression: resolution is authoritative over the backstop too — a
    // path the per-row backstop optimistically flagged AND the sweep
    // resolved to a live copy must NOT be excluded, because the impl
    // subtracts resolved.keys from the whole union. If this ever fails,
    // the impl stopped applying the subtraction across the backstop set
    // and the finding must be flagged, not asserted away.
    @Test func regression_backstopFlaggedButResolvedIsNotExcluded() {
        let m = merge(
            offline: [],
            backstop: ["/Volumes/RicksBackups/a.mov"],
            resolved: ["/Volumes/RicksBackups/a.mov": "/Volumes/LaCieWorkspace/a.mov"])
        #expect(m.excluded.isEmpty,
                "resolution must win over an optimistic backstop flag")
        #expect(m.resolved == ["/Volumes/RicksBackups/a.mov": "/Volumes/LaCieWorkspace/a.mov"])
    }

    @Test func emptyInputsProduceEmptyExcludedAndResolved() {
        let m = merge(offline: [], backstop: [], resolved: [:])
        #expect(m.excluded.isEmpty)
        #expect(m.resolved.isEmpty)
    }

    // General contract oracle: for arbitrary-ish inputs, the result must
    // equal the stated set expression exactly (excluded) and pass resolved
    // through byte-for-byte.
    @Test func matchesSetAlgebraContractExactly() {
        let offline: Set<String> = ["/o1", "/o2", "/shared"]
        let backstop: Set<String> = ["/b1", "/shared", "/resolvedBoth"]
        let resolved: [String: String] = [
            "/o2": "/live/o2",              // resolved, was in offline
            "/resolvedBoth": "/live/rb",    // resolved, was in backstop
            "/orphanResolved": "/live/x",   // resolved but in neither set
        ]
        let m = merge(offline: offline, backstop: backstop, resolved: resolved)
        #expect(m.excluded == offline.union(backstop).subtracting(resolved.keys))
        // Spot the intent: only unresolved members of the union survive.
        #expect(m.excluded == ["/o1", "/shared", "/b1"])
        // A resolved key that was in NEITHER set doesn't invent an entry.
        #expect(!m.excluded.contains("/orphanResolved"))
        #expect(m.resolved == resolved)
    }
}
