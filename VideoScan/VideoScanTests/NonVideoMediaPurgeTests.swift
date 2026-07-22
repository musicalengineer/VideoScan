import Foundation
import Testing
@testable import VideoScan

// MARK: - Non-Video Media Purge — extension×volume classification tests (2026-07-21)
//
// Authored by feature-dev as the initial pin for the REDESIGNED unified purge
// dialog: a PURE EXTENSION CHECKLIST (NonVideoMediaPurge + purgeNonVideoMedia).
// The testing agent owns the suite from here. These use a synthetic-record
// harness — no real catalog, and the store-touching tests inject a temp
// CatalogStore.
//
// Dimensions covered:
//   • Logic — record → offered/excluded by extension; label map.
//   • Extension×volume scoping — a .cr3 on volume A is counted for A and
//     excluded when A is deselected; purging {.m4a}×{Music} removes only
//     Music-volume m4a and spares other volumes + other extensions.
//   • Paired-count accuracy — an extension with some pairGroupID-set records
//     reports the right "(N paired)".
//   • Media matrix — video containers / Avid essence are NEVER offered and
//     never removed (a .mov survives any extension selection).
//   • Scale — 100k records, most candidates in ONE dominant extension×volume
//     cell → classify within a tight budget; toggling is O(cells). Guards the
//     copy-on-write O(N²) regression QA caught.
//   • Isolation — removal runs through an injected temp CatalogStore.

@MainActor
private func rec(fullPath: String,
                 streamType: StreamType = .audioOnly,
                 ext: String = "",
                 pairGroupID: UUID? = nil) -> VideoRecord {
    let r = VideoRecord()
    r.streamTypeRaw = streamType.rawValue
    r.fullPath = fullPath
    r.filename = (fullPath as NSString).lastPathComponent
    r.directory = (fullPath as NSString).deletingLastPathComponent
    r.ext = ext.isEmpty ? (fullPath as NSString).pathExtension : ext
    r.pairGroupID = pairGroupID
    return r
}

@Suite(.serialized) @MainActor
struct NonVideoMediaPurgeClassificationTests {

    // MARK: Logic — offered vs excluded, sort order, labels

    @Test func offeredExtensionsExcludeVideoAndExtensionless() {
        let records = [
            rec(fullPath: "/Volumes/A/photo.cr3"),
            rec(fullPath: "/Volumes/A/song.mp3"),
            rec(fullPath: "/Volumes/A/clip.mov"),          // video container — excluded
            rec(fullPath: "/Volumes/A/essence.mxf"),       // Avid essence — excluded
            rec(fullPath: "/Volumes/A/orphan"),            // extensionless — excluded
        ]
        let c = NonVideoMediaPurge.classify(records: records)
        #expect(Set(c.extensions) == ["cr3", "mp3"])
        #expect(!c.extensions.contains("mov"))
        #expect(!c.extensions.contains("mxf"))
        #expect(!c.extensions.contains(""))
    }

    @Test func extensionsSortByCountDescending() {
        var records: [VideoRecord] = []
        for i in 0..<5 { records.append(rec(fullPath: "/Volumes/A/j\(i).jpg")) }
        for i in 0..<3 { records.append(rec(fullPath: "/Volumes/A/m\(i).mp3")) }
        for i in 0..<1 { records.append(rec(fullPath: "/Volumes/A/w\(i).wav")) }
        let c = NonVideoMediaPurge.classify(records: records)
        #expect(c.extensions == ["jpg", "mp3", "wav"])
    }

    @Test func labelMapAndFallback() {
        #expect(NonVideoMediaPurge.label(forExtension: "cr3") == "Canon RAW photo")
        #expect(NonVideoMediaPurge.label(forExtension: "jpeg") == "JPEG photo")
        #expect(NonVideoMediaPurge.label(forExtension: "m4a") == "AAC audio")
        #expect(NonVideoMediaPurge.label(forExtension: "aac") == "audio")
        #expect(NonVideoMediaPurge.label(forExtension: "flac") == "audio")
        // Case-insensitive.
        #expect(NonVideoMediaPurge.label(forExtension: "MP3") == "MP3 audio")
        // Unmapped → "(.ext)" fallback.
        #expect(NonVideoMediaPurge.label(forExtension: "xyz") == "(.xyz)")
    }

    // MARK: Extension×volume scoping

    @Test func extensionVolumeScopingCountsAndUnion() {
        let a1 = rec(fullPath: "/Volumes/VolA/dcim/p1.cr3")
        let a2 = rec(fullPath: "/Volumes/VolA/dcim/p2.cr3")
        let b1 = rec(fullPath: "/Volumes/VolB/dcim/p3.cr3")
        let bMp3 = rec(fullPath: "/Volumes/VolB/music/s.mp3")
        let c = NonVideoMediaPurge.classify(records: [a1, a2, b1, bMp3])

        // .cr3 counted per volume.
        #expect(c.extensionCount("cr3", volumeKeys: ["VolA"]) == 2)
        #expect(c.extensionCount("cr3", volumeKeys: ["VolB"]) == 1)
        #expect(c.extensionCount("cr3", volumeKeys: ["VolA", "VolB"]) == 3)
        // Deselect VolA → its .cr3 drop out.
        #expect(c.extensionCount("cr3", volumeKeys: ["VolB"]) == 1)

        // Per-volume count scoped to selected extensions.
        #expect(c.volumeCount("VolB", extensions: ["cr3"]) == 1)
        #expect(c.volumeCount("VolB", extensions: ["cr3", "mp3"]) == 2)
        #expect(c.volumeCount("VolB", extensions: ["mp3"]) == 1)

        // candidateIDs union scopes to selected cells only.
        let idsA = c.candidateIDs(extensions: ["cr3"], volumeKeys: ["VolA"])
        #expect(idsA == [a1.id, a2.id])
        #expect(!idsA.contains(b1.id))
        let idsAll = c.candidateIDs(extensions: ["cr3", "mp3"], volumeKeys: ["VolA", "VolB"])
        #expect(idsAll.count == 4)

        // Total across selection.
        #expect(c.totalCount(extensions: ["cr3", "mp3"], volumeKeys: ["VolA", "VolB"]) == 4)
        #expect(c.totalCount(extensions: ["mp3"], volumeKeys: ["VolA"]) == 0)
    }

    // MARK: Paired-count accuracy

    @Test func pairedCountReportsPairedRecordsOnly() {
        let group = UUID()
        let p1 = rec(fullPath: "/Volumes/Music/a1.wav", pairGroupID: group)
        let p2 = rec(fullPath: "/Volumes/Music/a2.wav", pairGroupID: UUID())
        let plain = rec(fullPath: "/Volumes/Music/a3.wav")
        let c = NonVideoMediaPurge.classify(records: [p1, p2, plain])
        #expect(c.extensionCount("wav", volumeKeys: ["Music"]) == 3)
        #expect(c.extensionPairedCount("wav", volumeKeys: ["Music"]) == 2)

        // Paired count is volume-scoped like the row count.
        let onOther = rec(fullPath: "/Volumes/Other/b.wav", pairGroupID: UUID())
        let c2 = NonVideoMediaPurge.classify(records: [p1, plain, onOther])
        #expect(c2.extensionPairedCount("wav", volumeKeys: ["Music"]) == 1)
        #expect(c2.extensionPairedCount("wav", volumeKeys: ["Music", "Other"]) == 2)
        #expect(c2.extensionPairedCount("wav", volumeKeys: ["Other"]) == 1)
    }

    @Test func pairedViaPairedWithLinkIsCounted() {
        let a = rec(fullPath: "/Volumes/Pairs/a.wav")
        let b = rec(fullPath: "/Volumes/Pairs/b.wav")
        a.pairedWith = b   // direct link, no group id
        let c = NonVideoMediaPurge.classify(records: [a, b])
        #expect(c.extensionPairedCount("wav", volumeKeys: ["Pairs"]) == 1)
    }

    // MARK: Media matrix — video/essence never offered, never removed

    @Test func videoContainersNeverOfferedNorRemoved() {
        let mov = rec(fullPath: "/Volumes/Fam/clip.mov", streamType: .videoAndAudio)
        let mxf = rec(fullPath: "/Volumes/Avid/essence.mxf", streamType: .ffprobeFailed)
        let wav = rec(fullPath: "/Volumes/Fam/loop.wav")
        let c = NonVideoMediaPurge.classify(records: [mov, mxf, wav])
        // Only .wav offered.
        #expect(c.extensions == ["wav"])
        // Even if a caller passes "mov"/"mxf", nothing maps to them.
        #expect(c.candidateIDs(extensions: ["mov", "mxf"], volumeKeys: ["Fam", "Avid"]).isEmpty)
        // Selecting ALL offered extensions never includes the video containers.
        let all = Set(c.extensions)
        let ids = c.candidateIDs(extensions: all, volumeKeys: Set(c.volumeKeys))
        #expect(!ids.contains(mov.id))
        #expect(!ids.contains(mxf.id))
        #expect(ids.contains(wav.id))
    }

    @Test func topLocationsRecomputeWithSelection() {
        let a1 = rec(fullPath: "/Volumes/VolA/loops/a1.wav")
        let a2 = rec(fullPath: "/Volumes/VolA/loops/a2.wav")
        let b1 = rec(fullPath: "/Volumes/VolB/samples/b1.wav")
        let c = NonVideoMediaPurge.classify(records: [a1, a2, b1])
        let both = c.topLocations(extensions: ["wav"], volumeKeys: ["VolA", "VolB"])
        #expect(both.total == 3)
        #expect(both.trees.first?.path == "/Volumes/VolA/loops")
        #expect(both.trees.first?.count == 2)
        let onlyB = c.topLocations(extensions: ["wav"], volumeKeys: ["VolB"])
        #expect(onlyB.total == 1)
        #expect(onlyB.trees.count == 1)
        #expect(onlyB.trees.first?.path == "/Volumes/VolB/samples")
    }

    // MARK: Scale — 100k records, SINGLE-DOMINANT extension×volume cell
    //
    // The real worst case (and the O(N²) trap QA caught) is tens of thousands
    // of ONE extension collapsing into ONE volume bucket — a samples drive
    // where every .wav maps to key "Dominant" and one directory. An even split
    // spreads the accumulation across cells and can pass at ~5s while the real
    // catalog is far slower, so we deliberately funnel almost all candidates
    // into a single cell: if the amortized-O(1) append regresses to
    // COW-per-append, this one cell is O(k²) with k≈90k and the budget blows
    // out immediately.
    @Test func classifyOneHundredKWithinBudget() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        // 10k video files (excluded — never offered) to prove exclusion at
        // scale doesn't cost accuracy.
        for i in 0..<10_000 {
            records.append(rec(fullPath: "/Volumes/Dominant/video/clip\(i).mov",
                               streamType: .videoAndAudio))
        }
        // 90k .wav ALL in one volume bucket, one directory → one matrix cell
        // accumulating ~90k ids. This is the O(N²) tripwire.
        for i in 0..<90_000 {
            records.append(rec(fullPath: "/Volumes/Dominant/loops/s\(i).wav"))
        }
        #expect(records.count == 100_000)

        let start = Date()
        let c = NonVideoMediaPurge.classify(records: records)
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 2.0, "classify(100k, single-cell) took \(elapsed)s")

        #expect(c.extensions == ["wav"])        // .mov never offered
        #expect(c.volumeKeys == ["Dominant"])
        #expect(c.extensionCount("wav", volumeKeys: ["Dominant"]) == 90_000)
        #expect(c.candidateIDs(extensions: ["wav"], volumeKeys: ["Dominant"]).count == 90_000)

        // Toggling is O(cells), not O(records): a batch of re-sums is instant.
        let toggleStart = Date()
        for _ in 0..<1_000 {
            _ = c.totalCount(extensions: ["wav"], volumeKeys: ["Dominant"])
        }
        let toggleElapsed = Date().timeIntervalSince(toggleStart)
        #expect(toggleElapsed < 0.5, "1000 re-sums took \(toggleElapsed)s")
    }
}

// MARK: - Isolation — removal through an injected temp CatalogStore

@Suite(.serialized) @MainActor
struct NonVideoMediaPurgeRemovalTests {

    @Test func purgeExtensionVolumeScopedRemovesOnlySelectedCells() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-purge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)   // isolated store
        model.scanTargets.removeAll()

        // Target: {.m4a} × {Music}. Everything else must survive.
        let musicM4a1 = rec(fullPath: "/Volumes/Music/iTunes/a.m4a")
        let musicM4a2 = rec(fullPath: "/Volumes/Music/iTunes/b.m4a")
        let musicMp3  = rec(fullPath: "/Volumes/Music/iTunes/c.mp3")       // other ext
        let otherM4a  = rec(fullPath: "/Volumes/Other/x.m4a")             // other volume
        let mov       = rec(fullPath: "/Volumes/Music/clip.mov",
                            streamType: .videoAndAudio)                    // video — never offered

        let doomed    = [musicM4a1, musicM4a2]
        let survivors = [musicMp3, otherM4a, mov]
        model.records = survivors + doomed
        model.searchIndex.rebuild(records: model.records)

        let outcome = model.purgeNonVideoMedia(extensions: ["m4a"], volumeKeys: ["Music"])
        #expect(outcome.removed == doomed.count,
                "expected \(doomed.count) removed, got \(outcome.removed)")
        let paths = Set(model.records.map(\.fullPath))
        for d in doomed { #expect(!paths.contains(d.fullPath)) }
        for s in survivors { #expect(paths.contains(s.fullPath)) }

        // Persisted through the isolated store.
        let reloaded = CatalogStore(directory: tmp).load()
        #expect(reloaded.count == survivors.count)
    }

    @Test func purgeIsLiteralAndRemovesPairedRecords() throws {
        // The redesign: extension-purge is LITERAL — paired records that match
        // ARE removed (the user was shown "(N paired)"). Pin that so a future
        // "protect pairs" keep-rule can't sneak back in silently.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-paired-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()

        let paired = rec(fullPath: "/Volumes/Music/take7.wav", pairGroupID: UUID())
        let plain  = rec(fullPath: "/Volumes/Music/loop.wav")
        model.records = [paired, plain]
        model.searchIndex.rebuild(records: model.records)

        let outcome = model.purgeNonVideoMedia(extensions: ["wav"], volumeKeys: ["Music"])
        #expect(outcome.removed == 2, "literal purge removes paired records too")
        #expect(model.records.isEmpty)
    }

    @Test func purgeVideoExtensionIsANoOp() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-video-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()
        let mov = rec(fullPath: "/Volumes/Fam/clip.mov", streamType: .videoAndAudio)
        let wav = rec(fullPath: "/Volumes/Fam/loop.wav")
        model.records = [mov, wav]
        model.searchIndex.rebuild(records: model.records)

        // Even if a caller asks for "mov", classify never offers it → no-op.
        let outcome = model.purgeNonVideoMedia(extensions: ["mov"], volumeKeys: ["Fam"])
        #expect(outcome.removed == 0)
        #expect(outcome == PurgeOutcome.none)
        #expect(Set(model.records.map(\.fullPath)).contains(mov.fullPath))
    }

    @Test func purgeNothingSelectedIsNoOp() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)
        model.scanTargets.removeAll()
        model.records = [rec(fullPath: "/Volumes/Music/a.wav")]

        #expect(model.purgeNonVideoMedia(extensions: [], volumeKeys: ["Music"]).removed == 0)
        #expect(model.purgeNonVideoMedia(extensions: ["wav"], volumeKeys: []).removed == 0)
        #expect(model.records.count == 1)
    }

    // MARK: Outcome threading — count + recovery-snapshot path
    //
    // The completion dialog needs BOTH the removed count and the recovery-
    // snapshot path. With an INJECTED temp store (not CatalogStore.shared) the
    // snapshot is genuinely written to the temp dir even under XCTest, so we can
    // assert a real, existing path — and that removed == 0 paths report nil.
    @Test func purgeOutcomeReportsCountAndSnapshotPath() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("vs-nonvideo-outcome-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: tmp)   // injected, not shared
        model.scanTargets.removeAll()

        let m1 = rec(fullPath: "/Volumes/Music/samples/one.wav")
        let m2 = rec(fullPath: "/Volumes/Music/samples/two.wav")
        model.records = [m1, m2]
        model.searchIndex.rebuild(records: model.records)

        let outcome = model.purgeNonVideoMedia(extensions: ["wav"], volumeKeys: ["Music"])
        #expect(outcome.removed == 2, "expected 2 removed, got \(outcome.removed)")
        let snapshot = try #require(outcome.snapshotPath,
                                    "non-empty purge must report a recovery snapshot path")
        #expect(FileManager.default.fileExists(atPath: snapshot),
                "reported snapshot must actually exist on disk: \(snapshot)")

        // Already purged → removed == 0 and NO snapshot.
        let noop = model.purgeNonVideoMedia(extensions: ["wav"], volumeKeys: ["Music"])
        #expect(noop.removed == 0)
        #expect(noop.snapshotPath == nil)
        #expect(noop == PurgeOutcome.none)
    }
}
