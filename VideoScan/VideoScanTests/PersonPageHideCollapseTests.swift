// PersonPageHideCollapseTests.swift
// People tab ▸ a person's page (Rick 2026-10-24):
//   A. "Remove from <name>'s Page" on EVERY row — a neutral hide, by
//      whole-file SHA-256, with "N hidden — Show" ▸ "Put Back".
//   B. One row per piece of footage — copies (whole-file digest), lineage
//      (derivedFrom) and the person's "same footage" answer collapse into
//      one row led by the keeper, "+N versions" under it.
//
//   LOGIC      hide leaves tags/face matches; hide drops a pick; put back
//              restores; a folded source + archive copy hides both.
//   TRUTH      no collapse on a sampled-hash duplicate group, on an equal
//              length alone, or across a "not the same" answer.
//   PERSIST    a hide survives a reload and a stale ordinary profile save.
//   ISOLATION  a hide list naming unknown digests, and an unreadable row.
//   SCALE      100k records, a person in 2k with lineage: the whole page
//              in the People page's budget (PersonVideosTests: 500 ms).
//   SENSOR     the collapse never walks the catalog and never reads the
//              machine's unconfirmed likeness pairs.
//   (Media matrix: not applicable — catalog and profile metadata only, no
//   file is opened.)
// Synthetic fixtures only (sandbox POI store under the test host).

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("People page — neutral hide and one row per footage")
struct PersonPageHideCollapseTests {

    // MARK: Fixtures

    private func rec(_ name: String, digest: String? = nil, size: Int64 = 4_096, seconds: Double = 600,
                     detected: [String] = [], confirmed: [String] = [], year: String? = "1984",
                     from parent: VideoRecord? = nil, kind: String? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/Volumes/test_T/\(name)"
        r.filename = name
        r.directory = "/Volumes/test_T"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.sizeBytes = size
        r.durationSeconds = seconds
        r.detectedPeople = detected
        r.confirmedByUserPeople = confirmed.map { ConfirmedTag(name: $0, confirmedAt: Date()) }
        r.userDate = year
        if let digest {
            r.contentFixity = ContentFixity(digest: digest, byteCount: size,
                                            stamp: FileIdentityStamp(device: 1, inode: UInt64.random(in: 1...1_000_000),
                                                                     size: size, mtimeNs: 3))
        }
        if let parent {
            r.derivedFrom = parent.id
            r.derivationKind = kind ?? "transcode"
        }
        return r
    }

    private func digest(_ c: Character) -> String { String(repeating: String(c), count: 64) }

    private func model(_ recs: [VideoRecord]) -> VideoScanModel {
        let m = VideoScanModel()
        m.records = recs
        m.searchIndex.rebuild(records: recs)
        return m
    }

    /// A saved test person (sandbox store), fresh each test.
    private func savedPerson() throws -> POIProfile {
        let p = POIProfile(name: "Testperson\(UUID().uuidString.prefix(6))", referencePath: "")
        try p.save()
        return p
    }

    private func onDisk(_ p: POIProfile) throws -> POIProfile {
        try #require(POIProfile.listAll().first { $0.uuid == p.uuid })
    }

    private func page(_ p: POIProfile, _ m: VideoScanModel) throws -> PersonVideoPage {
        PersonVideos.page(for: try onDisk(p), in: m)
    }

    private func shownIDs(_ page: PersonVideoPage) -> Set<UUID> {
        Set((page.picks + page.taggedWithMaybes).flatMap(\.rows).map(\.id))
    }

    private func hiddenIDs(_ page: PersonVideoPage) -> Set<UUID> {
        Set(page.hidden.flatMap(\.rows).map(\.id))
    }

    // MARK: A — the neutral hide

    @Test func everyRowOffersTheHideAndTheWordsAreNeutral() {
        #expect(PersonVideoRemovalAction.putBackOnPage.title("Dana") == "Put Back on Dana\u{2019}s Page")
        let help = PersonVideoRemovalAction.removeFromPage.help("Dana")
        #expect(help.contains("Tags for Dana stay") && help.contains("put back"))
        #expect(!help.lowercased().contains("isn\u{2019}t"), "a hide makes no claim about who is in it")
    }

    @Test func hidingATaggedRowLeavesTagsAndFaceMatchesUntouched() throws {
        let p = try savedPerson()
        let tagged = rec("tagged.mov", digest: digest("a"), confirmed: [p.name])
        let byFace = rec("face.mov", digest: digest("b"), detected: [p.name])
        let m = model([tagged, byFace])
        #expect(shownIDs(try page(p, m)) == [tagged.id, byFace.id], "precondition")

        PersonVideoRemoval.perform(.removeFromPage, recs: [byFace], profile: p, model: m)

        let after = try page(p, m)
        #expect(shownIDs(after) == [tagged.id])
        #expect(hiddenIDs(after) == [byFace.id], "listed under 'N hidden — Show'")
        #expect(byFace.detectedPeople == [p.name], "the face match stays")
        #expect(byFace.rejectedPeople.isEmpty, "no rejection is recorded")
        #expect(tagged.confirmedByUserPeople.map(\.name) == [p.name])
        #expect(try onDisk(p).hiddenVideos.map(\.fullDigest) == [digest("b")], "stored by whole-file SHA-256")
    }

    @Test func hidingAPickDropsThePickAndKeepsTheTag() throws {
        let p = try savedPerson()
        let r = rec("pick.mov", digest: digest("c"), confirmed: [p.name])
        let m = model([r])
        FeaturedVideos.set([r], on: true, for: p.uuid)
        #expect(try page(p, m).picks.map(\.id) == [r.id], "precondition: a pick")

        PersonVideoRemoval.perform(.removeFromPage, recs: [r], profile: p, model: m)

        let after = try page(p, m)
        #expect(after.picks.isEmpty && after.taggedWithMaybes.isEmpty, "not on the page at all")
        #expect(try onDisk(p).featuredVideos.isEmpty, "the pick is dropped")
        #expect(hiddenIDs(after) == [r.id])
        #expect(r.confirmedByUserPeople.map(\.name) == [p.name], "the tag stays")
    }

    @Test func putBackRestoresTheRow() throws {
        let p = try savedPerson()
        let r = rec("back.mov", digest: digest("d"), detected: [p.name])
        let m = model([r])
        PersonVideoRemoval.perform(.removeFromPage, recs: [r], profile: p, model: m)
        #expect(hiddenIDs(try page(p, m)) == [r.id], "precondition: hidden")

        PersonVideoRemoval.perform(.putBackOnPage, recs: [r], profile: p, model: m)

        let after = try page(p, m)
        #expect(shownIDs(after) == [r.id])
        #expect(after.hidden.isEmpty)
        #expect(try onDisk(p).hiddenVideos.isEmpty)
    }

    /// The hide is in profile.json: a fresh load sees it, and an ordinary
    /// save of a copy taken BEFORE the hide (the People tab's in-memory
    /// profile) never erases it.
    @Test func aHideSurvivesAReloadAndAStaleSave() throws {
        let p = try savedPerson()
        let r = rec("persist.mov", digest: digest("e"), detected: [p.name])
        let noDigest = rec("nodigest.mov", detected: [p.name])
        let m = model([r, noDigest])
        PersonVideoRemoval.perform(.removeFromPage, recs: [r, noDigest], profile: p, model: m)

        var stale = p                     // predates the hide
        stale.notes = "edited after the hide"
        try stale.save()

        let back = try onDisk(p)
        #expect(back.notes == "edited after the hide", "the edit landed")
        #expect(back.hiddenVideos.count == 2, "and the hides survived it")
        #expect(back.hiddenVideos.contains { $0.fullDigest == nil && $0.recordID == noDigest.id },
                "a file with no full digest is hidden by record id")
        let decoded = try JSONDecoder().decode(POIProfile.self, from: JSONEncoder().encode(back))
        #expect(decoded.hiddenVideos == back.hiddenVideos, "round-trips through profile.json")
        #expect(hiddenIDs(PersonVideos.page(for: decoded, in: model([r, noDigest]))) == [r.id, noDigest.id])
    }

    /// The row folding a source into its Master Archive copy hides BOTH,
    /// so neither brings the row back.
    @Test func aFoldedSourceAndArchiveCopyAreBothHidden() throws {
        let p = try savedPerson()
        let d = digest("f")
        let source = rec("source.mov", digest: d, detected: [p.name])
        let copy = rec("1984-xx-xx_copy.mov", detected: [p.name])
        copy.derivedFrom = UUID()   // a source row this catalog does not have
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.archiveFixity = ArchiveFixity(digest: d, verifiedAt: Date(), sizeBytes: 4_096)
        let m = model([source, copy])
        #expect(PersonVideos.rows(for: try onDisk(p), in: m).map(\.id) == [copy.id], "precondition: one folded row")

        PersonVideoRemoval.perform(.removeFromPage, recs: [copy], profile: p, model: m)

        let hides = PersonPageHides.Lookup(try onDisk(p).hiddenVideos)
        for r in [source, copy] {
            #expect(hides.hides(PersonVideos.row(r, tier: .foundByFace, in: m)), "\(r.filename) is hidden")
        }
        #expect(try page(p, m).taggedWithMaybes.isEmpty)
    }

    /// ISOLATION: entries naming digests and ids nobody has, plus one
    /// unreadable row, are ignored — nothing hidden, nothing lost.
    @Test func aHideListOfUnknownsIsIgnoredAndKept() throws {
        let p = try savedPerson()
        let r = rec("visible.mov", digest: digest("1"), detected: [p.name])
        let url = POIStorage.folder(for: p).appendingPathComponent("profile.json")
        var obj = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        obj["hiddenVideos"] = [
            ["fullDigest": digest("9"), "recordID": UUID().uuidString, "filename": "gone.mov", "hiddenAt": 0],
            ["recordID": UUID().uuidString, "filename": "gone-too.mov", "hiddenAt": 0],
            ["recordID": "not-a-uuid", "fullDigest": 42],
        ]
        try JSONSerialization.data(withJSONObject: obj).write(to: url)

        let page = PersonVideos.page(for: try onDisk(p), in: model([r]))
        #expect(shownIDs(page) == [r.id])
        #expect(page.hidden.isEmpty, "an unknown digest hides nothing and is not counted")

        var loaded = try onDisk(p)
        #expect(loaded.hiddenVideos.count == 2 && loaded.hiddenVideosQuarantined.count == 1)
        loaded.notes = "ordinary edit"
        try loaded.save()
        let back = try onDisk(p)
        #expect(back.hiddenVideos.count == 2 && back.hiddenVideosQuarantined.count == 1,
                "the unreadable row is kept verbatim, not dropped")
    }

    // MARK: B — one row per piece of footage

    /// Lineage: two edits of a raw transfer the person is NOT tagged in,
    /// and an edit of an edit, are one piece of footage; the original-most,
    /// longest file leads. An unrelated video of the same length stays its
    /// own row (duration alone never groups).
    @Test func aDerivedFromChainCollapsesUnderTheKeeper() throws {
        let p = try savedPerson()
        let raw = rec("raw.dv", seconds: 5_600)                                      // not on the page
        let improved = rec("raw_Improved.mov", digest: digest("2"), seconds: 5_590, detected: [p.name], from: raw)
        let edit = rec("raw-vs-edit.mov", digest: digest("3"), seconds: 5_000, detected: [p.name], from: raw)
        let edit2 = rec("raw-vs-edit_02.mov", digest: digest("4"), seconds: 5_000, detected: [p.name], from: edit)
        let stranger = rec("other-1984.mov", digest: digest("5"), seconds: 5_590, detected: [p.name])
        let m = model([raw, improved, edit, edit2, stranger])

        let tagged = try page(p, m).tagged
        #expect(tagged.count == 2, "\(tagged.map(\.lead.title))")
        let footage = try #require(tagged.first { $0.fileCount > 1 })
        #expect(footage.lead.id == improved.id, "the longest original leads")
        #expect(Set(footage.versions.map(\.id)) == [edit.id, edit2.id])
        #expect(footage.versionsWords == "+2 versions")
        #expect(tagged.contains { $0.lead.id == stranger.id && $0.versions.isEmpty }, "same length, no evidence: apart")
        #expect(PersonVideoPage.countWords(tagged) == "2 videos · 4 files")
    }

    @Test func byteCopiesCollapseAndTheArchivedFileLeads() {
        let d = digest("6")
        let onDrive = FootageFolders.Row(digest: d, sizeBytes: 9, durationSeconds: 60, volume: "LaCie")
        let inArchive = FootageFolders.Row(digest: d, sizeBytes: 9, durationSeconds: 60, isArchived: true,
                                           isArchiveFile: true, volume: "FamilyArchive")
        let groups = PersonVideoFamilies.groups(.init(rows: [onDrive, inArchive], pageIDs: [onDrive.id, inArchive.id]))
        #expect(groups.groupOf[onDrive.id] != nil && groups.groupOf[onDrive.id] == groups.groupOf[inArchive.id])
        #expect(groups.rank[inArchive.id] == 0, "the archived original leads")
    }

    @Test func aConfirmedSameFootagePairCollapses() throws {
        let p = try savedPerson()
        let ffv1 = rec("thanksgiving.mkv", digest: digest("7"), detected: [p.name])
        let h264 = rec("thanksgiving_cleaned.mov", digest: digest("8"), detected: [p.name])
        let m = model([ffv1, h264])
        #expect(try page(p, m).tagged.count == 2, "precondition: no evidence yet")

        _ = m.setFootageDecision(.same, between: ffv1.id, and: h264.id)

        let tagged = try page(p, m).tagged
        #expect(tagged.count == 1 && tagged[0].fileCount == 2)
    }

    /// TRUTH: a "not the same" answer keeps a group apart even when its
    /// files are linked by lineage; a duplicate group with no whole-file
    /// digest (it may come from a sampled hash) never collapses anything.
    @Test func notTheSameAndSampledGroupsNeverCollapse() throws {
        let p = try savedPerson()
        let a = rec("a.mov", digest: digest("a"), detected: [p.name])
        let b = rec("b.mov", digest: digest("b"), detected: [p.name], from: a)
        let group = UUID()
        let c = rec("c.mov", detected: [p.name]), d = rec("d.mov", detected: [p.name])
        c.duplicateGroupID = group
        d.duplicateGroupID = group
        let m = model([a, b, c, d])
        #expect(try page(p, m).tagged.count == 3, "precondition: a+b collapse; c, d apart")

        _ = m.setFootageDecision(.notSame, between: a.id, and: b.id)

        #expect(try page(p, m).tagged.count == 4, "the person's 'not the same' wins")
    }

    // MARK: Scale

    /// 100k records; the person in 2k of them, each pair made from one
    /// untagged raw (1k pieces of footage), and 1k hide entries of which
    /// 100 hit. The whole page builds in the People page's budget.
    @Test func hundredThousandRecordsPageInBudget() throws {
        var p = POIProfile(name: "Scaleperson", referencePath: "")
        var records: [VideoRecord] = []
        records.reserveCapacity(101_000)
        var raw = rec("raw0.dv", seconds: 3_000)
        for i in 0..<100_000 {
            if i % 100 == 0 {                       // one untagged raw per 100 records
                raw = rec("raw\(i).dv", seconds: 3_000)
                records.append(raw)
            }
            if i % 50 == 0 {                        // two edits of each raw are tagged
                records.append(rec("v\(i).mov", digest: String(format: "%064x", i), seconds: Double(2_000 + i % 7),
                                   detected: ["Scaleperson"], year: String(1980 + i % 40), from: raw))
            } else {
                records.append(rec("x\(i).mov", detected: i % 7 == 0 ? ["Someone"] : []))
            }
        }
        p.hiddenVideos = (0..<1_000).map { k in
            HiddenVideo(fullDigest: k < 100 ? String(format: "%064x", (k + 1) * 50) : digest("z") + "\(k)",
                        recordID: UUID(), filename: "", hiddenAt: Date())
        }
        let m = model(records)
        let clock = ContinuousClock()
        var built = PersonVideoPage.empty
        let loadBefore = TimingBudget.sampleLoad()
        let elapsed = clock.measure { built = PersonVideos.page(for: p, in: m) }
        let files = (built.tagged + built.hidden).reduce(0) { $0 + $1.fileCount }
        #expect(files == 2_000, "every tagged file is on the page once")
        #expect(built.hidden.reduce(0) { $0 + $1.fileCount } == 100)
        #expect(built.tagged.count + built.hidden.count < 1_100, "pairs collapse: \(built.tagged.count) rows")
        // GH #378: through the one budget rule (sanitizer-, load- and
        // nightly-aware), never a raw `elapsed < budget`.
        expectWithinTimingBudget("People page for one person, 100k records + 1k hides", measured: elapsed,
                                 budget: .milliseconds(500), loadBefore: loadBefore)
    }
}

// MARK: - Sensor

@Suite("People page — collapse and hide sensor")
struct PersonPageCollapseSensorTests {
    /// The collapse reads only proven evidence and never walks the catalog.
    @Test func collapseUsesOnlyProvenEvidence() throws {
        let src = try SourceTree.appSource(named: "PersonVideoFamilies.swift")
        #expect(!src.contains(".records"), "never iterate the catalog")
        #expect(!src.contains("footageLikeness"), "the machine's unconfirmed pairs are never evidence")
        #expect(!src.contains("contentHash"), "a sampled hash is never identity")
        #expect(src.contains("row.duplicateGroupID = nil"), "the duplicate-group copy leg is dropped")
        let hides = try SourceTree.appSource(named: "PersonPageHides.swift")
        #expect(!hides.contains("contentHash"), "a hide is never keyed on the sampled hash")
        #expect(!hides.contains("setPerson"), "a hide never touches tags")
    }
}
