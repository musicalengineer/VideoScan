// IgnoredContentTests.swift
// Content-keyed ignore list (Rick 2026-09-11): set-aside / removed content
// is never re-ingested under a new path, and Tidy learns two categories.
//
// Five dimensions (CLAUDE.md feature-test checklist):
//   Logic     — store round-trip, key fallback, dedupe, the override;
//               writers add (Tidy apply, Remove from Catalog) and remove
//               (Put Back, Undo); the scan gate; Tidy's "Junk that came
//               back" (retroactive) and "Copies of archived media" (dry
//               run, count + bytes).
//   Scale     — 100k records + 100k-entry store through the plan builder
//               under a budget; 100k store lookups under a budget.
//   Isolation — the store directory is injected; under a test host the
//               DEFAULT directory is a scratch folder, and a model-level
//               write leaves the real App Support file untouched.
//   Media     — N/A (no probing is touched; the gate is pure metadata).
//   Sensor    — junkThatCameBackIsCaughtAtProductionScale: a set-aside
//               record's content re-appearing at a NEW path is (a) skipped
//               at scan and (b) listed by Tidy if it somehow got in.
// The end-to-end pipeline shape (startTarget → gate → merge) lives in
// RescanPreservationTests (sensor_setAsideContentAtNewPathIsNotReingested).

import Foundation
import Testing
@testable import VideoScan

// MARK: - Fixtures

private func tempDir(_ label: String) -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_ignored_content_\(label)_\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@MainActor
private func rec(
    _ filename: String,
    dir: String = "/Volumes/T/media",
    md5: String = "",
    size: Int64 = 1_000_000,
    stream: StreamType = .videoAndAudio,
    setAside: String? = nil,
    purged: Bool = false
) -> VideoRecord {
    let r = VideoRecord()
    r.filename = filename
    r.ext = (filename as NSString).pathExtension.uppercased()
    r.streamTypeRaw = stream.rawValue
    r.directory = dir
    r.fullPath = dir + "/" + filename
    r.sizeBytes = size
    r.partialMD5 = md5
    r.setAsideReason = setAside
    if purged { r.purgedAt = Date(timeIntervalSince1970: 1_000_000) }
    return r
}

/// A model whose store lives in a throwaway directory (belt and braces —
/// the default is already a scratch folder under a test host).
@MainActor
private func makeModel(_ label: String) -> VideoScanModel {
    let model = VideoScanModel()
    model.ignoredContentStore = IgnoredContentStore(directory: tempDir(label))
    return model
}

// MARK: - Store logic

@Suite("Ignored content — store")
struct IgnoredContentStoreTests {

    @Test("key: content key when hashed, name key as fallback, nothing for empty files")
    func keys() {
        #expect(IgnoredContentKey.lookupKey(partialMD5: "abc", sizeBytes: 10, filename: "A.MOV")
                == .content(partialMD5: "abc", sizeBytes: 10))
        #expect(IgnoredContentKey.lookupKey(partialMD5: "", sizeBytes: 10, filename: "A.MOV")
                == .name(filenameLower: "a.mov", sizeBytes: 10))
        #expect(IgnoredContentKey.lookupKey(partialMD5: "abc", sizeBytes: 0, filename: "A.MOV") == nil,
                "a zero-size file must never match anything")
        #expect(IgnoredContentKey.lookupKey(partialMD5: "", sizeBytes: 10, filename: "") == nil)
        #expect(IgnoredContentKey.indexKeys(partialMD5: "abc", sizeBytes: 10, filename: "A.MOV")
                == [.content(partialMD5: "abc", sizeBytes: 10), .name(filenameLower: "a.mov", sizeBytes: 10)],
                "an entry is indexed under BOTH keys it can form")
    }

    @Test("add / lookup / dedupe / the override")
    @MainActor
    func addLookupRemove() {
        let store = IgnoredContentStore(directory: tempDir("add"))
        #expect(store.add(partialMD5: "m1", sizeBytes: 100, filename: "Junk.mov", reason: "unlinked-audio",
                          samplePath: "/Volumes/Old/Junk.mov", now: Date(timeIntervalSince1970: 1)))
        #expect(store.count == 1)
        // Same content, other name → known (content key).
        #expect(store.reason(partialMD5: "m1", sizeBytes: 100, filename: "renamed.mov") == "unlinked-audio")
        // Hash-less rescan of the same file → known (name key fallback).
        #expect(store.reason(partialMD5: "", sizeBytes: 100, filename: "JUNK.MOV") == "unlinked-audio")
        // Different size → not known.
        #expect(store.reason(partialMD5: "m1", sizeBytes: 101, filename: "Junk.mov") == nil)
        #expect(!store.contains(partialMD5: "zz", sizeBytes: 100, filename: "other.mov"))
        // Dedupe: the original entry (reason, date) stands.
        #expect(!store.add(partialMD5: "m1", sizeBytes: 100, filename: "Junk.mov", reason: "still-image",
                           samplePath: "/x", now: Date(timeIntervalSince1970: 2)))
        #expect(store.count == 1)
        #expect(store.entries[0].reason == "unlinked-audio")
        #expect(store.entries[0].addedAt == Date(timeIntervalSince1970: 1))
        #expect(store.entries[0].friendlyReason == "Audio with no matching video")
        // The override — by content.
        let r0 = store.revision
        #expect(store.remove(partialMD5: "m1", sizeBytes: 100, filename: "whatever.mov") == 1)
        #expect(store.isEmpty)
        #expect(store.revision != r0)
        #expect(store.reason(partialMD5: "m1", sizeBytes: 100, filename: "Junk.mov") == nil)
        #expect(store.reason(partialMD5: "", sizeBytes: 100, filename: "junk.mov") == nil,
                "removing by content drops the name key too")
        // …and by id.
        store.add(partialMD5: "", sizeBytes: 5, filename: "a.wav", reason: "removed-by-user", samplePath: "/a")
        let id = store.entries[0].id
        #expect(store.remove(id: id))
        #expect(!store.remove(id: id))
        #expect(store.isEmpty)
    }

    @Test("round-trips through disk atomically; wrong version / malformed → empty; empty list is written")
    @MainActor
    func roundTripAndPoison() async throws {
        let dir = tempDir("rt")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = IgnoredContentStore(directory: dir)
        let at = Date(timeIntervalSince1970: 1_700_000_000)
        store.add(partialMD5: "m1", sizeBytes: 100, filename: "Junk.mov", reason: "live-photo-complement",
                  samplePath: "/Volumes/Old/Junk.mov", now: at)
        store.add(partialMD5: "", sizeBytes: 7, filename: "scratch.wav", reason: "unlinked-audio",
                  samplePath: "/Volumes/Old/scratch.wav", now: at)
        #expect(await store.save())
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: dir.path))?
            .filter { $0.hasSuffix(".tmp") } ?? []
        #expect(leftovers.isEmpty, "no temp file left behind: \(leftovers)")

        let again = IgnoredContentStore(directory: dir)
        #expect(await again.load())
        #expect(again.entries == store.entries)
        #expect(again.reason(partialMD5: "m1", sizeBytes: 100, filename: "x") == "live-photo-complement")
        #expect(again.reason(partialMD5: "", sizeBytes: 7, filename: "SCRATCH.wav") == "unlinked-audio")

        // Wrong store version → ignored.
        var poisoned = try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as! [String: Any]
        poisoned["storeVersion"] = 99
        try JSONSerialization.data(withJSONObject: poisoned).write(to: store.fileURL)
        let v99 = IgnoredContentStore(directory: dir)
        #expect(await v99.load() == false)
        #expect(v99.isEmpty)

        // Malformed → ignored.
        try Data("{not json".utf8).write(to: store.fileURL)
        let bad = IgnoredContentStore(directory: dir)
        #expect(await bad.load() == false)
        #expect(bad.isEmpty)

        // The LAST entry being put back must reach disk: an empty list saves.
        let emptied = IgnoredContentStore(directory: dir)
        #expect(await emptied.save())
        let reloaded = IgnoredContentStore(directory: dir)
        #expect(await reloaded.load())
        #expect(reloaded.isEmpty)

        // Missing directory → save creates it.
        let deeper = IgnoredContentStore(directory: dir.appendingPathComponent("deeper/still"))
        #expect(await deeper.save())
    }

    @Test("index snapshot: first reason wins; lookups mirror the store")
    func indexSnapshot() {
        var index = IgnoredContentIndex()
        #expect(index.isEmpty)
        index.add(partialMD5: "m1", sizeBytes: 10, filename: "a.mov", reason: "still-image")
        index.add(partialMD5: "m1", sizeBytes: 10, filename: "a.mov", reason: "music-format")
        #expect(index.reason(partialMD5: "m1", sizeBytes: 10, filename: "zzz") == "still-image")
        #expect(index.reason(partialMD5: "", sizeBytes: 10, filename: "A.MOV") == "still-image")
        #expect(index.reason(partialMD5: "m2", sizeBytes: 10, filename: "a.mov") == nil,
                "a hashed lookup uses the content key only — a different hash is different content")
        #expect(index.keyCount == 2)
    }
}

// MARK: - Writers + scan gate

@MainActor
@Suite("Ignored content — writers and scan gate")
struct IgnoredContentWriterTests {

    @Test("Remove from Catalog remembers the content; Put Back forgets it (the override)")
    func removeThenPutBack() {
        let model = makeModel("rm")
        let a = rec("tape.mov", md5: "m1", size: 100)
        let b = rec("other.mov", md5: "m2", size: 200)
        model.records = [a, b]
        #expect(model.removeFromCatalog(recordIDs: [a.id]) == 1)
        #expect(a.setAsideReason == "removed-by-user")
        #expect(model.ignoredContentStore.count == 1)
        #expect(model.ignoredContentStore.reason(partialMD5: "m1", sizeBytes: 100, filename: "copy.mov")
                == "removed-by-user")
        #expect(model.ignoredContentStore.entries[0].samplePath == "/Volumes/T/media/tape.mov")
        let rev = model.ignoredContentRevision
        #expect(model.restoreSetAsideRecords(ids: [a.id]) == 1)
        #expect(a.setAsideReason == nil)
        #expect(model.ignoredContentStore.isEmpty, "Put Back in Catalog is the override")
        #expect(model.ignoredContentRevision != rev)
    }

    @Test("Tidy apply remembers every row with its reason; Undo forgets the batch")
    func tidyApplyAndUndo() async {
        let model = makeModel("tidy")
        let still = rec("IMG_1.cr3", md5: "s1", size: 10, stream: .videoOnly)
        let music = rec("song.mp3", md5: "u1", size: 20, stream: .audioOnly)
        let video = rec("family.mov", md5: "v1", size: 30)
        model.records = [still, music, video]
        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.rows.count == 2)
        #expect(model.applyTidyCatalog(plan) == 2)
        #expect(model.ignoredContentStore.count == 2)
        #expect(model.ignoredContentStore.reason(partialMD5: "s1", sizeBytes: 10, filename: "x") == "still-image")
        #expect(model.ignoredContentStore.reason(partialMD5: "u1", sizeBytes: 20, filename: "x") == "music-format")
        #expect(model.ignoredContentStore.reason(partialMD5: "v1", sizeBytes: 30, filename: "x") == nil)
        #expect(model.undoLastTidyCatalog())
        #expect(model.ignoredContentStore.isEmpty, "Undo is the override for the whole batch")
        // A second apply re-remembers (no stale dedupe state after removal).
        let plan2 = await model.computeTidyCatalogPlan()
        #expect(model.applyTidyCatalog(plan2) == 2)
        #expect(model.ignoredContentStore.count == 2)
    }

    @Test("the sheet's Put back removes one entry and logs; a bogus id is a no-op")
    func sheetPutBack() {
        let model = makeModel("sheet")
        let a = rec("tape.mov", md5: "m1", size: 100)
        model.records = [a]
        model.removeFromCatalog(recordIDs: [a.id])
        let id = model.ignoredContentStore.entries[0].id
        #expect(!model.putBackIgnoredContent(id: UUID()))
        #expect(model.putBackIgnoredContent(id: id))
        #expect(model.ignoredContentStore.isEmpty)
        // The record itself stays set aside — the override is about the
        // NEXT scan, not the existing row (that is Put Back in Catalog).
        #expect(a.setAsideReason == "removed-by-user")
    }

    @Test("scan gate: ignored content at a NEW path is dropped; a known path is always admitted; empty store is a passthrough")
    func scanGate() {
        let model = makeModel("gate")
        let old = rec("junk.mov", dir: "/Volumes/Old", md5: "j1", size: 100)
        let active = rec("keep.mov", dir: "/Volumes/Old", md5: "k1", size: 200)
        model.records = [old, active]

        // Empty store: everything passes, no work.
        let fresh0 = [rec("junk.mov", dir: "/Volumes/New", md5: "j1", size: 100)]
        #expect(model.applyIgnoredContentGate(targetRecords: fresh0, volName: "New").admitted.count == 1)

        model.removeFromCatalog(recordIDs: [old.id])
        // A fresh probe of the SAME content at a NEW path: dropped.
        let copy = rec("junk-copy.mov", dir: "/Volumes/New/deeper", md5: "j1", size: 100)
        // A fresh probe at the ORIGINAL (known) path: admitted — the merge
        // and rescan preservation own that row.
        let samePath = rec("junk.mov", dir: "/Volumes/Old", md5: "j1", size: 100)
        // An ACTIVE record's content re-seen at its own path: admitted.
        let activeAgain = rec("keep.mov", dir: "/Volumes/Old", md5: "k1", size: 200)
        // Hash-less rescan of the ignored content, same name + size: dropped.
        let noHash = rec("JUNK.MOV", dir: "/Volumes/New/nohash", md5: "", size: 100)
        // Unrelated new file: admitted.
        let stranger = rec("new.mov", dir: "/Volumes/New", md5: "n1", size: 300)
        let out = model.applyIgnoredContentGate(
            targetRecords: [copy, samePath, activeAgain, noHash, stranger], volName: "New")
        #expect(out.ignored == 2)
        #expect(out.admitted.map(\.filename) == ["junk.mov", "keep.mov", "new.mov"])
    }
}

// MARK: - Tidy categories

@MainActor
@Suite("Tidy Catalog — junk that came back + copies of archived media")
struct TidyIgnoredContentCategoryTests {

    @Test("Junk that came back: store entries, set-aside rows and purged tombstones all count; the original reason is kept")
    func junkThatCameBack() async {
        let model = makeModel("junk")
        // (1) explicit store entry
        model.ignoredContentStore.add(partialMD5: "e1", sizeBytes: 11, filename: "old-still.cr3",
                                      reason: "still-image", samplePath: "/gone")
        let fromStore = rec("clip.mov", dir: "/Volumes/LaCie/a", md5: "e1", size: 11)
        // (2) set-aside row elsewhere in the catalog (retroactive)
        let setAside = rec("scratch.wav", dir: "/Volumes/Old", md5: "s1", size: 22, stream: .audioOnly,
                           setAside: "unlinked-audio")
        let fromSetAside = rec("scratch-copy.wav", dir: "/Volumes/LaCie/b", md5: "s1", size: 22,
                               stream: .audioOnly)
        // (3) purged tombstone (retroactive, reason removed-by-user)
        let purged = rec("bad.mov", dir: "/Volumes/Old", md5: "p1", size: 33, purged: true)
        let fromPurged = rec("bad (1).mov", dir: "/Volumes/LaCie/c", md5: "p1", size: 33)
        // (4) purged EXTRA COPY from Delete Duplicates: its keeper is NOT junk
        let extra = rec("keeper.mov", dir: "/Volumes/Old", md5: "d1", size: 44, purged: true)
        extra.duplicateDisposition = .extraCopy
        let keeper = rec("keeper.mov", dir: "/Volumes/LaCie/d", md5: "d1", size: 44)
        // (5) fallback key: neither side hashed, same name + size
        let noHashSetAside = rec("Song.MP3", dir: "/Volumes/Old", size: 55, stream: .audioOnly,
                                 setAside: "music-format")
        let noHashCopy = rec("song.mp3", dir: "/Volumes/LaCie/e", size: 55, stream: .audioOnly)
        // (6) plain video — untouched
        let video = rec("family.mov", dir: "/Volumes/LaCie/f", md5: "v1", size: 66)
        model.records = [fromStore, setAside, fromSetAside, purged, fromPurged, extra, keeper,
                         noHashSetAside, noHashCopy, video]

        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.junkCameBackCount == 4)
        let back = plan.rows.filter(\.cameBack)
        #expect(back.count == 4)
        func reason(_ name: String) -> CatalogScopePolicy.SetAsideReason? {
            back.first { $0.filename == name }?.reason
        }
        #expect(reason("clip.mov") == .stillImage)
        #expect(reason("scratch-copy.wav") == .unlinkedAudio)
        #expect(reason("bad (1).mov") == .removedByUser)
        #expect(reason("song.mp3") == .musicFormat, "hash-less content matches by name + size")
        #expect(!back.contains { $0.filename == "keeper.mov" }, "a dup-delete keeper is not junk")
        #expect(!back.contains { $0.filename == "family.mov" })
        // Junk-first: the music copy is NOT double counted as music.
        #expect(plan.musicCount == 0)
        #expect(plan.rows.count == 4)
        #expect(plan.examined == 6, "10 records − 2 set-aside − 2 purged: tombstones are not candidates")
        // Dry run mutates nothing.
        #expect(model.records.filter { $0.setAsideReason != nil }.count == 2)
        #expect(model.ignoredContentStore.count == 1)

        // CSV names the category.
        let csv = VideoScanModel.tidyPlanCSV(plan)
        #expect(csv.contains("Junk that came back — Photos and camera images,clip.mov"))

        // Apply: set aside with the ORIGINAL reason; every row remembered.
        #expect(model.applyTidyCatalog(plan) == 4)
        #expect(fromStore.setAsideReason == "still-image")
        #expect(fromPurged.setAsideReason == "removed-by-user")
        #expect(model.ignoredContentStore.count == 4, "1 existing (deduped) + 3 new")
        #expect(model.ignoredContentStore.reason(partialMD5: "p1", sizeBytes: 33, filename: "x") == "removed-by-user")
        // Idempotent: nothing left to tidy.
        let second = await model.computeTidyCatalogPlan()
        #expect(second.rows.isEmpty)
    }

    @Test("Copies of archived media: count + bytes, dry run only, archive-managed rows excluded")
    func copiesOfArchivedMedia() async {
        let model = makeModel("arch")
        let root = "/Volumes/TestArchive/Breen_Family_Archive"
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive", rootPath: root)
        // Promote link: source outside, copy inside (derivationKind archivePromotion).
        let source = rec("wedding.mov", dir: "/Volumes/LaCie/tapes", md5: "w1", size: 1_000)
        let copy = rec("wedding.mov", dir: root + "/1980s/1985", md5: "w1", size: 1_000)
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.derivedFrom = source.id
        // Fingerprint only: a plain record inside the root (no promote
        // record, no content hash) and an identical file outside.
        let inside = rec("reunion.mov", dir: root + "/1990s/1992", md5: "r1", size: 2_000)
        let outside = rec("reunion-backup.mov", dir: "/Volumes/MyBook/old", md5: "r1", size: 2_000)
        // Content hash on the promoted copy, another original elsewhere.
        copy.contentHash = "h-w"
        let staging = rec("wedding-staging.mov", dir: "/Volumes/Projects/stage", md5: "w9", size: 1_000)
        staging.contentHash = "h-w"
        // Unrelated active video, and a record inside the root that is a
        // still (still classified — Tidy's existing behavior) but never a
        // "copy of archived media" (it IS archived).
        let other = rec("other.mov", dir: "/Volumes/LaCie/x", md5: "o1", size: 4_000)
        let insideStill = rec("IMG_9.cr3", dir: root + "/photos", md5: "i1", size: 8_000, stream: .videoOnly)
        model.records = [source, copy, inside, outside, staging, other, insideStill]

        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.archivedCopyCount == 3, "source (promote link) + outside (fingerprint) + staging (content hash)")
        #expect(plan.archivedCopyBytes == 1_000 + 2_000 + 1_000)
        // DRY RUN ONLY: no rows for them, nothing set aside on apply.
        #expect(plan.rows.map(\.filename) == ["IMG_9.cr3"])
        #expect(plan.junkCameBackCount == 0)
        model.applyTidyCatalog(plan)
        #expect(source.setAsideReason == nil)
        #expect(outside.setAsideReason == nil)
        #expect(staging.setAsideReason == nil)

        // No Master Archive designated → the tally is zero (no false alarms).
        let plain = makeModel("noarch")
        plain.records = [rec("a.mov", md5: "a", size: 1), rec("b.mov", dir: "/Volumes/Y", md5: "a", size: 1)]
        let p2 = await plain.computeTidyCatalogPlan()
        #expect(p2.archivedCopyCount == 0 && p2.archivedCopyBytes == 0)
    }

    @Test("archive-managed rows are never 'junk that came back'")
    func archiveRowsNeverJunk() async {
        let model = makeModel("archjunk")
        let root = "/Volumes/TestArchive/Breen_Family_Archive"
        model.masterArchive = MasterArchiveDesignation(targetPath: "/Volumes/TestArchive", rootPath: root)
        let tomb = rec("clip.mov", dir: "/Volumes/Old", md5: "c1", size: 10, purged: true)
        let archived = rec("clip.mov", dir: root + "/1970s/1975", md5: "c1", size: 10)
        model.records = [tomb, archived]
        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.junkCameBackCount == 0)
        #expect(plan.rows.isEmpty)
    }

    @Test("existing Tidy tallies still partition the rows with the new category")
    func tallyOracle() async {
        let model = makeModel("oracle")
        let tomb = rec("x.mov", dir: "/Volumes/Old", md5: "x1", size: 5, purged: true)
        model.records = [
            tomb,
            rec("x-copy.mov", md5: "x1", size: 5),
            rec("IMG_1.cr3", md5: "a", size: 1, stream: .videoOnly),
            rec("song.mp3", md5: "b", size: 2, stream: .audioOnly),
            rec("jpegvideocomplement_1.mov", md5: "c", size: 3),
            rec("lonely.wav", dir: "/Volumes/T/other", md5: "d", size: 4, stream: .audioOnly),
        ]
        let plan = await model.computeTidyCatalogPlan()
        #expect(plan.stillCount + plan.musicCount + plan.unlinkedAudioCount
                + plan.livePhotoComplementCount + plan.junkCameBackCount == plan.rows.count)
        #expect(plan.junkCameBackCount == plan.rows.filter(\.cameBack).count)
        #expect(plan.rows.count == 5)
    }
}

// MARK: - Scale

@MainActor
@Suite("Ignored content — scale")
struct IgnoredContentScaleTests {

    @Test("100k records + 100k-entry store through the Tidy plan within budget")
    func hundredKPlan() async {
        let model = makeModel("scale")
        let store = model.ignoredContentStore
        for i in 0..<100_000 {
            store.add(partialMD5: "ignored-\(i)", sizeBytes: Int64(1_000 + i), filename: "junk\(i).mov",
                      reason: i % 2 == 0 ? "live-photo-complement" : "removed-by-user", samplePath: "/gone/\(i)")
        }
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        for i in 0..<100_000 {
            // Every other record is a copy of ignored content under a new path.
            if i % 2 == 0 {
                catalog.append(rec("copy\(i).mov", dir: "/Volumes/LaCie/\(i % 100)",
                                   md5: "ignored-\(i)", size: Int64(1_000 + i)))
            } else {
                catalog.append(rec("tape\(i).mov", dir: "/Volumes/V\(i % 20)/tapes",
                                   md5: "tape-\(i)", size: Int64(5_000_000 + i)))
            }
        }
        model.records = catalog
        let start = ContinuousClock.now
        let plan = await model.computeTidyCatalogPlan()
        let elapsed = start.duration(to: .now)
        #expect(plan.junkCameBackCount == 50_000)
        #expect(plan.rows.count == 50_000)
        #expect(plan.archivedCopyCount == 0)
        #expect(elapsed < .seconds(15), "100k records × 100k-entry store dry run took \(elapsed) — budget 15s")
    }

    @Test("100k store lookups are O(1): under 1 s")
    func hundredKLookups() {
        let store = IgnoredContentStore(directory: tempDir("lookup"))
        for i in 0..<100_000 {
            store.add(partialMD5: "h\(i)", sizeBytes: Int64(i + 1), filename: "f\(i).mov",
                      reason: "removed-by-user", samplePath: "/p/\(i)")
        }
        #expect(store.count == 100_000)
        let clock = ContinuousClock()
        var hits = 0
        let elapsed = clock.measure {
            for i in 0..<100_000 where store.contains(partialMD5: "h\(i)", sizeBytes: Int64(i + 1), filename: "z") {
                hits += 1
            }
            for i in 0..<100_000 where store.contains(partialMD5: "", sizeBytes: Int64(i + 1), filename: "F\(i).MOV") {
                hits += 1
            }
        }
        #expect(hits == 200_000)
        #expect(elapsed < .seconds(1), "200k lookups took \(elapsed) — budget 1s")
    }
}

// MARK: - Isolation

@Suite("Ignored content — isolation")
struct IgnoredContentIsolationTests {

    private static var realFile: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("VideoScan/ignored-content.json")
    }

    @Test("under a test host the DEFAULT store directory is a scratch folder, never App Support")
    @MainActor
    func defaultDirectoryIsScratch() {
        #expect(TestEnvironment.isTestHost)
        let dir = IgnoredContentStore.defaultDirectory.path
        #expect(!dir.contains("Application Support"), "default directory was \(dir)")
        #expect(dir.hasPrefix(NSTemporaryDirectory()) || dir.hasPrefix("/private" + NSTemporaryDirectory()))
        let model = VideoScanModel()
        #expect(!model.ignoredContentStore.directory.path.contains("Application Support"))
        #expect(!model.ignoredContentStore.fileURL.path.contains("Application Support"))
    }

    @Test("a model-level write never touches the real App Support file")
    @MainActor
    func realFileUntouched() async throws {
        let real = Self.realFile
        let fm = FileManager.default
        let before = try? fm.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        let existedBefore = fm.fileExists(atPath: real.path)

        let model = VideoScanModel()          // DEFAULT directory on purpose
        let a = rec("tape.mov", md5: "iso", size: 9)
        model.records = [a]
        model.removeFromCatalog(recordIDs: [a.id])
        #expect(await model.ignoredContentStore.save())
        #expect(fm.fileExists(atPath: model.ignoredContentStore.fileURL.path))

        let after = try? fm.attributesOfItem(atPath: real.path)[.modificationDate] as? Date
        #expect(fm.fileExists(atPath: real.path) == existedBefore, "test created or removed the REAL file")
        #expect(after == before, "test modified the REAL file")
    }
}

// MARK: - Sensor

@MainActor
@Suite("Ignored content — sensor")
struct IgnoredContentSensorTests {

    /// The 2026-09-11 finding at production scale: 100k records; a record
    /// set aside; its CONTENT re-appears at a NEW path (another copy on
    /// another volume, a different name). It must be (a) skipped by the
    /// scan gate and (b) — if it got in anyway (older build, hash-less
    /// scan that pre-dated the store) — listed by Tidy as "Junk that came
    /// back" with the original reason. Same-path rescans stay admitted.
    @Test func junkThatCameBackIsCaughtAtProductionScale() async {
        let model = makeModel("sensor")
        var catalog: [VideoRecord] = []
        catalog.reserveCapacity(100_000)
        for i in 0..<100_000 {
            catalog.append(rec("tape\(i).mov", dir: "/Volumes/V\(i % 40)/tapes/\(i % 500)",
                               md5: "tape-\(i)", size: Int64(3_000_000 + i)))
        }
        let junk = rec("jpegvideocomplement_7f3.mov", dir: "/Volumes/MediaExpansion/Photos export",
                       md5: "junk-7f3", size: 4_242)
        catalog.append(junk)
        model.records = catalog

        // Tidy set it aside (the Live Photo rule) → remembered.
        let first = await model.computeTidyCatalogPlan()
        #expect(first.livePhotoComplementCount == 1)
        #expect(model.applyTidyCatalog(first) == 1)
        #expect(junk.setAsideReason == "live-photo-complement")
        #expect(model.ignoredContentStore.count == 1)

        // (a) Scan gate: the same content at a NEW path, new name, other volume.
        let copy = rec("IMG_7f3 (1).mov", dir: "/Volumes/LaCieWorkspace/from_mybook/exports",
                       md5: "junk-7f3", size: 4_242)
        let samePath = rec("jpegvideocomplement_7f3.mov", dir: "/Volumes/MediaExpansion/Photos export",
                           md5: "junk-7f3", size: 4_242)
        let stranger = rec("tape-new.mov", dir: "/Volumes/LaCieWorkspace/new", md5: "fresh", size: 1)
        let start = ContinuousClock.now
        let gate = model.applyIgnoredContentGate(targetRecords: [copy, samePath, stranger], volName: "LaCieWorkspace")
        #expect(gate.ignored == 1)
        #expect(gate.admitted.map(\.filename) == ["jpegvideocomplement_7f3.mov", "tape-new.mov"],
                "the known path is admitted (rescan preservation keeps it set aside); the stranger is admitted")

        // (b) It got in anyway: Tidy lists it, with the ORIGINAL reason.
        model.records.append(copy)
        let second = await model.computeTidyCatalogPlan()
        let elapsed = start.duration(to: .now)
        #expect(second.junkCameBackCount == 1)
        #expect(second.rows.count == 1)
        #expect(second.rows.first?.id == copy.id)
        #expect(second.rows.first?.cameBack == true)
        #expect(second.rows.first?.reason == .livePhotoComplement)
        #expect(second.livePhotoComplementCount == 0, "junk-first: not double counted by the filename rule")
        #expect(elapsed < .seconds(10), "gate + 100k dry run took \(elapsed) — budget 10s")

        // The override: Put Back in Catalog on the original forgets the
        // content — the copy is no longer "junk that came back".
        #expect(model.restoreSetAsideRecords(ids: [junk.id]) == 1)
        #expect(model.ignoredContentStore.isEmpty)
        let third = await model.computeTidyCatalogPlan()
        #expect(third.junkCameBackCount == 0)
        // (Both halves now classify as Live Photo halves by filename —
        // Tidy's existing rule — but neither is "junk that came back".)
        #expect(third.rows.allSatisfy { !$0.cameBack })

        try? await Task.sleep(nanoseconds: 400_000_000)
        let console = model.dashboard.consoleLines.joined(separator: "\n")
        #expect(console.contains("IGNORED 1 file previously set aside (Tidy → Ignored content to put back)"),
                "console: \(console.suffix(600))")
    }
}
