// P0TruthRemainingTests.swift
// GH #327, the five items left open on 2026-10-19, with Rick's rulings of
// 2026-10-23. Each drives the REAL surface over the shared fixture catalog
// (P0TruthFixture.swift) and asserts the WORDS shown, not only a Bool:
//
//   1. Promote/Tidy worklists — a sampled `v1:` match may still HIDE a
//      file, but it is "possibly archived (sampled)" wherever shown and
//      NEVER counts toward an archived figure (size line, folder line,
//      People rows, Has Master Copy, the search banner, Compare Media).
//   2. Preservation ladder — a sampled signature is "Sampled signature —
//      not verified"; only a whole-file SHA-256 earns "Signed".
//   3. Find Similar Footage — sampled equality never makes role "copy".
//   4. People-tab picks — a pick is never re-found by its sampled hash.
//   5. Sound copy — "exact copy" only when the full digests are equal.
//   + a source sensor pinning each fix to its one door.
//
// RED RUN: these tests were run (2026-10-23) against the pre-fix surfaces,
// with item 1's new predicates stubbed to the old (sampled) answer — every
// test below failed there; see the commit message for the counts.
//
// (For Rick: `#expect` ≈ EXPECT_* (keeps going); `#require` ≈ ASSERT_*.)

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@Suite("P0 truth regressions — the remaining #327 items (Rick 2026-10-23)", .serialized)
@MainActor
struct P0TruthRemainingTests {

    // MARK: 1. Hide on a sampled match, never count it

    @Test("Worklists (isArchived hides; isProvenArchived counts): a sampled match hides the file but is 'possibly archived (sampled)' and never in an archived count")
    func sampledMatchHidesButNeverCounts() throws {
        let catalog = try P0TruthFixtureCatalog.build("r1_counts")
        defer { catalog.cleanup() }
        let (source, copy) = try P0TruthRegressionTests.sampledPair(catalog)
        let linked = try catalog.require(.deadLinkSource)
        let model = catalog.model

        // Hiding stays (Rick's ruling): the to-do view still drops it.
        #expect(model.isArchived(source) && !model.pfNotYetArchived(source), "the worklist still hides a sampled match")
        #expect(!model.isProvenArchived(source), "a sampled match is not proven")
        #expect(model.isPossiblyArchivedSampled(source))
        #expect(model.isProvenArchived(linked) && !model.isPossiblyArchivedSampled(linked), "positive control: the promote link")

        // The Catalog's size line (ARCHIVED), through the projection the pane runs.
        let root = model.masterArchiveRootPath
        let entries = CatalogSizeTotals.projectDeferringArchivePath(model.records) { model.isProvenArchivedExceptPath($0) }
        let counted = Set(entries.filter { e in
            e.isArchived || e.archivePathToCheck.map { VideoScanModel.isInsideMasterArchive(path: $0, root: root) } == true
        }.map(\.id))
        #expect(!counted.contains(source.id), "ARCHIVED counted \(source.filename) on a sampled match")
        #expect(counted.contains(linked.id) && counted.contains(copy.id))
        #expect(CatalogSizeTotals.compute(entries, archiveRoot: root).archivedCount == counted.count)

        // The footage-folder line's archived count.
        #expect(!model.footageFolderRow(source).isArchived, "the folder line counts a sampled match as archived")
        #expect(model.footageFolderRow(linked).isArchived)

        // People rows: no green "In the Archive", the hedged words instead.
        let row = PersonVideos.row(source, tier: .tagged, in: model)
        #expect(!row.isArchived, "People row says 'In the Archive' on a sampled match")
        #expect(row.isPossiblyArchived)
        #expect(PersonVideoRow.possiblyArchivedWords == "Possibly archived (sampled)")
        let linkedRow = PersonVideos.row(linked, tier: .tagged, in: model)
        #expect(linkedRow.isArchived && !linkedRow.isPossiblyArchived)

        // Show ▸ Has Master Copy (and Hallie's citation chip, which reads it).
        #expect(!model.pfHasMasterCopy(source), "Has Master Copy lists a sampled match")
        #expect(model.pfHasMasterCopy(linked))

        // The search banner: both hits hidden, one of them only possibly.
        let split = CatalogShowingSummary.splitArchivedHits([source, linked]) { !model.pfNotYetArchived($0) }
        let sampled = split.archived.filter { model.isPossiblyArchivedSampled($0) }.count
        #expect(split.archived.count == 2 && sampled == 1, "hidden \(split.archived.count), sampled-only \(sampled)")
        #expect(CatalogShowingSummary.archivedHitsMessage(count: 2, sampled: sampled)
                == "1 match is already in the Archive; 1 more is possibly archived (sampled) — not yet verified.")
        #expect(CatalogShowingSummary.archivedHitsMessage(count: 1, sampled: 1)
                == "1 match is possibly archived (sampled) — not yet verified.")
        #expect(CatalogShowingSummary.archivedHitsMessage(count: 3) == "3 matches are already in the Archive.")

        // Compare Media's "archive" fact.
        var side = RelatedEvidence.Side(isArchived: model.isProvenArchived(source))
        side.isPossiblyArchivedSampled = model.isPossiblyArchivedSampled(source)
        #expect(CompareMediaWords.archiveWords(side) == "possibly archived (sampled)", "\(CompareMediaWords.archiveWords(side))")
        #expect(CompareMediaWords.archiveWords(RelatedEvidence.Side(isArchived: true)) == "content archived")
    }

    // MARK: 2. Signed = a whole-file SHA-256

    @Test("Preservation ladder (PreservationChecklist.contentSignature): a sampled v1: signature is 'Sampled signature — not verified'; only a whole-file SHA-256 is 'Signed'")
    func sampledSignatureIsNeverSigned() throws {
        let catalog = try P0TruthFixtureCatalog.build("r2_signed")
        defer { catalog.cleanup() }
        let source = try catalog.require(.sampledMatchSource)
        #expect(source.contentHash.hasPrefix("v1:") && source.contentFixity == nil, "fixture: sampled only")

        let signed = PreservationChecklist.steps(for: source)[1]
        #expect(signed.kind == .signed)
        #expect(!signed.done, "a sampled signature ticked Signed")
        #expect(signed.title == "Sampled signature — not verified", Comment(rawValue: signed.title))
        #expect(signed.todo.contains("Fill In Full Hashes"), Comment(rawValue: signed.todo))
        let journeyStep = catalog.model.makeFileJourney(for: source).preservation.first { $0.kind == .signed }
        #expect(journeyStep?.title == "Sampled signature — not verified", "the File Journey sheet's ladder")

        // Control: the whole-file SHA-256 earns "Signed".
        source.contentFixity = try Self.fullFixity(source)
        let proven = PreservationChecklist.steps(for: source)[1]
        #expect(proven.done && proven.title == "Signed", "\(proven.title)=\(proven.done)")
        // No signature at all: "Signed", open, the ordinary todo.
        let bare = PreservationChecklist.steps(for: VideoRecord())[1]
        #expect(!bare.done && bare.title == "Signed")
    }

    // MARK: 3. Find Similar Footage — no "copy" from sampled equality

    @Test("Find Similar Footage (FootageGrouping.assembleGroup): two files with only an equal sampled signature are grouped, never role 'copy'")
    func sampledEqualityIsNeverRoleCopy() {
        let a = FootageInput(filename: "Picnic-1992.mov", fullPath: "/Volumes/A/Picnic-1992.mov", durationSeconds: 600,
                             sizeBytes: 4096, contentHash: "v1:0123456789abcdef", videoCodec: "h264")
        var b = a
        b.id = UUID()
        b.fullPath = "/Volumes/B/Picnic-1992.mov"
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let r = FootageGrouping.run([a, b], now: now)
        let roles = [a, b].compactMap { r.memberships[$0.id]?.role }
        #expect(roles.count == 2, "the pair is still one group (Likely): \(roles)")
        #expect(!roles.contains(.copy), "sampled equality asserted 'copy': \(roles)")
        #expect(roles.contains(.related), "the hedged role: \(roles)")
        let evidence = [a, b].flatMap { r.memberships[$0.id]?.evidence ?? [] }
        #expect(evidence.contains { $0.contains("same sampled signature") && $0.contains("not yet verified") }, "\(evidence)")
        #expect(FootageGrouping.algorithmVersion >= 4, "stored answers with the old 'copy' role must be rewritten")

        // Control: current, equal whole-file digests are a copy.
        var fa = a, fb = b
        fa.fixityDigest = String(repeating: "ab", count: 32); fa.fixityFresh = true
        fb.fixityDigest = fa.fixityDigest; fb.fixityFresh = true
        let proven = FootageGrouping.run([fa, fb], now: now)
        let provenRoles: [FootageRole] = [fa, fb].compactMap { proven.memberships[$0.id]?.role }
        #expect(provenRoles.contains(.copy), "\(provenRoles)")
    }

    // MARK: 4. People-tab picks — never re-found by a sampled hash

    @Test("People tab picks (FeaturedVideos.resolve / matches): a pick is re-found by id, path + size, or the full SHA-256 — never by its sampled hash")
    func featuredPickIsNeverRefoundBySampledHash() throws {
        let catalog = try P0TruthFixtureCatalog.build("r4_featured")
        defer { catalog.cleanup() }
        let (source, copy) = try P0TruthRegressionTests.sampledPair(catalog)
        let model = catalog.model

        // The pick's row was renamed AND re-scanned: its id and path are stale.
        let stale = FeaturedVideo(recordID: UUID(), path: source.fullPath + ".gone", filename: source.filename,
                                  contentHash: source.contentHash, addedAt: P0TruthFixtureCatalog.cataloguedDate)
        let lost = FeaturedVideos.resolve([stale], in: model)
        #expect(lost.videos.isEmpty, "bound to \(lost.videos.map(\.filename)) by a sampled hash")
        #expect(lost.missing == 1, "reported not found")
        #expect(!FeaturedVideos.matches(stale, copy), "'on Donna's page' claimed for other bytes")
        #expect(!FeaturedVideos.matches(stale, source), "a sampled hash is no identity, even for the right file")

        // Path + size: a different file now at the pick's path is not the pick.
        let atPath = FeaturedVideo(recordID: UUID(), path: source.fullPath, filename: source.filename,
                                   contentHash: nil, addedAt: P0TruthFixtureCatalog.cataloguedDate,
                                   fullDigest: nil, sizeBytes: source.sizeBytes + 1)
        #expect(FeaturedVideos.resolve([atPath], in: model).videos.isEmpty, "path alone bound a file of another size")
        var samePath = atPath
        samePath.sizeBytes = source.sizeBytes
        #expect(FeaturedVideos.resolve([samePath], in: model).videos.map(\.id) == [source.id], "path + size is identity")

        // The full SHA-256 re-finds it, and a new pick stores it.
        source.contentFixity = try Self.fullFixity(source)
        var digestPick = stale
        digestPick.fullDigest = VideoScanModel.storedFullDigest(source)
        #expect(FeaturedVideos.resolve([digestPick], in: model).videos.map(\.id) == [source.id])
        #expect(FeaturedVideos.matches(digestPick, source) && !FeaturedVideos.matches(digestPick, copy))
        var picks: [FeaturedVideo] = []
        _ = FeaturedVideos.apply([source], on: true, to: &picks)
        #expect(picks.first?.fullDigest == VideoScanModel.storedFullDigest(source) && picks.first?.sizeBytes == source.sizeBytes)
    }

    // MARK: 5. Sound copy — "exact copy" needs equal full digests

    @Test("Sound copy (SoundCopyFinder.members): a duplicate group alone is not 'exact copy' — the full digests must be equal")
    func exactCopyNeedsEqualFullDigests() throws {
        let catalog = try P0TruthFixtureCatalog.build("r5_sound")
        defer { catalog.cleanup() }
        let picture = try catalog.require(.sampledOnlyA)
        let withSound = try catalog.require(.sampledOnlyB)
        picture.streamTypeRaw = StreamType.videoOnly.rawValue
        let group = UUID()
        picture.duplicateGroupID = group
        withSound.duplicateGroupID = group

        let offered = SoundCopyFinder.gather(for: picture, model: catalog.model).copiesWithSound
        #expect(!offered.contains { $0.relation == "exact copy" }, "a duplicate group alone said 'exact copy': \(offered.map(\.relation))")
        #expect(!offered.contains { $0.id == withSound.id }, "offered \(withSound.filename) as this footage with sound")

        // Control: equal whole-file SHA-256s (the bytes ARE identical).
        picture.contentFixity = try Self.fullFixity(picture)
        withSound.contentFixity = try Self.fullFixity(withSound)
        let proven = SoundCopyFinder.gather(for: picture, model: catalog.model).copiesWithSound
        #expect(proven.contains { $0.id == withSound.id && $0.relation == "exact copy" }, "\(proven.map(\.relation))")
    }

    // MARK: Source sensor

    @Test("Source sensor (#327 remaining): counts ask isProvenArchived; Signed, footage 'copy', pick re-find and 'exact copy' ask a whole-file digest")
    func eachRemainingSurfaceAsksTheProof() throws {
        typealias T = P0TruthRegressionTests
        // Item 1 — every archived COUNT or badge asks the proven predicate.
        let counts: [(file: String, function: String, proven: String)] = [
            ("VideoScan/Catalog/CatalogView+ScanTargetsPane.swift", "func scheduleSizeTotals()", "isProvenArchivedExceptPath("),
            ("VideoScan/Catalog/FootageFoldersSnapshot.swift", "func footageFolderRow(", "isProvenArchived("),
            ("VideoScan/People/PersonVideosSection.swift", "static func row(", "isProvenArchived("),
            ("VideoScan/Events/VideoScanModel+RelatedEvidence.swift", "func relatedAnswer(", "isProvenArchived("),
            ("VideoScan/Catalog/CatalogContent+Promote.swift", "func pfHasMasterCopy(", "provenArchivedCopy(of:"),
        ]
        for site in counts {
            let body = try T.body(of: site.function, in: site.file)
            try #require(!body.isEmpty, "\(site.function) moved out of \(site.file) — update the sensor")
            #expect(body.contains { $0.contains(site.proven) }, "\(site.function) must count through \(site.proven)")
            let sampled = body.filter { $0.contains("isArchived(") || $0.contains("isArchivedExceptPath(")
                || T.asksSampledArchivedCopy($0) }
            #expect(sampled.isEmpty, "\(site.function) counts a sampled match as archived: \(sampled)")
        }
        // Item 2 — Signed never reads the sampled contentHash.
        let signature = try T.body(of: "static func contentSignature(of", in: "VideoScan/Archive/PreservationChecklist.swift")
        try #require(!signature.isEmpty, "contentSignature moved — update the sensor")
        #expect(!signature.contains { $0.contains("hasContentSignature") || $0.contains("contentHash") },
                "Signed reads the sampled signature: \(signature)")
        // Item 3 — the footage "copy" role comes from proven bytes.
        let assemble = try T.body(of: "static func assembleGroup(", in: "VideoScan/FootageGroups/FootageGrouping.swift")
        try #require(!assemble.isEmpty, "assembleGroup moved — update the sensor")
        #expect(assemble.contains { $0.contains("identicalToOriginal: xs[i].sameBytes(as:") }, "role 'copy' must ask sameBytes(as:)")
        #expect(!assemble.contains { $0.contains("probablySameBytes") })
        // Item 4 — a pick is never found by a contentHash equality.
        for function in ["static func matches(", "static func resolve(_ picks"] {
            let body = try T.body(of: function, in: "VideoScan/People/FeaturedVideos.swift")
            try #require(!body.isEmpty, "\(function) moved — update the sensor")
            #expect(!body.contains { $0.contains("contentHash") }, "\(function) reads the sampled hash: \(body)")
        }
        // Item 5 — "exact copy" sits behind the full-digest equality.
        let members = try T.body(of: "static func members(of rec", in: "VideoScan/MediaOps/SoundCopyFinder.swift")
        try #require(!members.isEmpty, "SoundCopyFinder.members moved — update the sensor")
        #expect(members.contains { $0.contains("storedFullDigest(") }, "'exact copy' must compare whole-file digests")
    }
}

extension P0TruthRemainingTests {

    /// A whole-file SHA-256 ContentFixity of the row's real bytes.
    static func fullFixity(_ r: VideoRecord) throws -> ContentFixity {
        let digest = try #require(P0TruthFixtureCatalog.sha256(ofFile: r.fullPath), "no bytes at \(r.fullPath)")
        return ContentFixity(digest: digest, byteCount: r.sizeBytes,
                             stamp: FileIdentityStamp(device: 1, inode: 1, size: r.sizeBytes, mtimeNs: 1),
                             computedAt: P0TruthFixtureCatalog.cataloguedDate)
    }
}
