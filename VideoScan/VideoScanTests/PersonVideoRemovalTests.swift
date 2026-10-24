// PersonVideoRemovalTests.swift
// People tab ▸ right-click a video ▸ "Remove from Donna's Page" /
// "Donna Isn't in This Video" (Rick 2026-10-23).
//
//   LOGIC     the words; every name the person is known by; a confirmed tag
//             goes, a face match becomes Rejected; removing a pick keeps tags.
//   TRUTH     a row that stands for a source AND its archive copy changes
//             both, so the row cannot come straight back from the other one.
//   ISOLATION another person's tags on the same video are untouched.
//   SCALE     a person with 10k tagged videos, untagged in budget.
//   (Media matrix: not applicable — tags are catalog metadata, no file I/O.)

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("People tab — take a video off a person")
struct PersonVideoRemovalTests {

    private func rec(_ name: String) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = "/Volumes/test_T/\(name)"
        r.filename = name
        r.directory = "/Volumes/test_T"
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        return r
    }

    private func donna() -> POIProfile {
        var p = POIProfile(name: "Donna", referencePath: "")
        p.aliases = ["Donna Breen", "donna", "  "]
        return p
    }

    private func model(_ recs: [VideoRecord]) -> VideoScanModel {
        let m = VideoScanModel()
        m.records = recs
        m.searchIndex.rebuild(records: recs)
        return m
    }

    @Test func theWords() {
        #expect(PersonVideoRemovalAction.removeFromPage.title("Donna") == "Remove from Donna\u{2019}s Page")
        #expect(PersonVideoRemovalAction.notInVideo.title("Donna") == "Donna Isn\u{2019}t in This Video")
        #expect(PersonVideoRemovalAction.removeFromPage.help("Donna").contains("Tags for Donna stay"))
        #expect(PersonVideoRemovalAction.notInVideo.help("Donna").contains("No file is changed"))
    }

    @Test func everyNameOnceInOrder() {
        #expect(PersonVideoRemoval.names(of: donna()) == ["Donna", "Donna Breen"],
                "display name = name here; the lowercase alias and the blank one collapse")
    }

    @Test func aRowStandsForItsSourceAndItsCopyEachOnce() {
        let a = rec("a.mov"), s = rec("s.mov"), c = rec("c.mov")
        #expect(PersonVideoRemoval.records(a, source: nil, copy: nil).map(\.filename) == ["a.mov"])
        #expect(PersonVideoRemoval.records(c, source: s, copy: nil).map(\.filename) == ["c.mov", "s.mov"])
        #expect(PersonVideoRemoval.records(s, source: nil, copy: c).map(\.filename) == ["s.mov", "c.mov"])
        #expect(PersonVideoRemoval.records(a, source: a, copy: a).count == 1)
    }

    @Test func isntInThisVideoClearsConfirmedAndRejectsAFaceMatchUnderEveryName() {
        let confirmed = rec("confirmed.mov")
        confirmed.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        let byFace = rec("face.mov")
        byFace.detectedPeople = ["Donna Breen"]
        byFace.suspectedPeople = ["Donna"]
        let m = model([confirmed, byFace])
        let keys = PersonVideos.tagKeys(for: donna())

        PersonVideoRemoval.untag([confirmed, byFace], profile: donna(), model: m)

        for r in [confirmed, byFace] {
            #expect(PersonVideos.tier(of: r, keys: keys) == nil, "\(r.filename) no longer lists Donna")
        }
        #expect(confirmed.rejectedPeople.isEmpty, "removing your own confirmation is not a rejection")
        #expect(byFace.rejectedPeople.contains { $0.caseInsensitiveCompare("Donna Breen") == .orderedSame },
                "a face match is recorded as wrong so a scan does not re-add it")
        #expect(m.searchIndex.paths(forPersonNamesExactly: keys).isEmpty, "the People page's index agrees now")
    }

    @Test func aFoldedSourceAndCopyAreBothUntagged() {
        let source = rec("source.mov"), copy = rec("1987-xx-xx_copy.mov")
        for r in [source, copy] { r.detectedPeople = ["Donna"] }
        let m = model([source, copy])
        PersonVideoRemoval.untag(PersonVideoRemoval.records(copy, source: source, copy: nil), profile: donna(), model: m)
        let keys = PersonVideos.tagKeys(for: donna())
        #expect(PersonVideos.tier(of: source, keys: keys) == nil, "the source would otherwise bring the row back")
        #expect(PersonVideos.tier(of: copy, keys: keys) == nil)
    }

    /// Codex P1 (2026-10-24): an archive copy whose `derivedFrom` names a
    /// source nobody has, and a catalog source with the SAME whole-file
    /// SHA-256. The People page folds the source into the copy by digest
    /// (provenArchivedCopy), so removal must reach the source too — for
    /// the tags and for an old pick saved under the source's id/path.
    @Test func aSourceFoldedByDigestIsReachedToo() {
        let digest = String(repeating: "a1", count: 32)
        let stamp = FileIdentityStamp(device: 1, inode: 2, size: 4_096, mtimeNs: 3)
        let source = rec("source_by_digest.mov")
        source.sizeBytes = 4_096
        source.contentFixity = ContentFixity(digest: digest, byteCount: 4_096, stamp: stamp)
        let copy = rec("1988-xx-xx_copy.mov")
        copy.sizeBytes = 4_096
        copy.derivedFrom = UUID()   // a source row this catalog does not have
        copy.derivationKind = ArchivePromotion.derivationKind
        copy.archiveFixity = ArchiveFixity(digest: digest, verifiedAt: Date(), sizeBytes: 4_096)
        for r in [source, copy] { r.detectedPeople = ["Donna"] }
        let m = model([source, copy])
        #expect(PersonVideos.rows(for: donna(), in: m).map(\.id) == [copy.id], "precondition: one folded row")

        let recs = PersonVideoRemoval.rowRecords(copy, in: m)
        #expect(recs.contains { $0 === source }, "the digest-folded source belongs to the row")

        var picks: [FeaturedVideo] = [FeaturedVideo(recordID: source.id, path: source.fullPath, filename: source.filename,
                                                    contentHash: nil, addedAt: Date(), fullDigest: nil, sizeBytes: nil)]
        _ = FeaturedVideos.apply(recs, on: false, to: &picks)
        #expect(picks.isEmpty, "an old pick saved under the source is removed from the copy's row")

        PersonVideoRemoval.untag(recs, profile: donna(), model: m)
        m.searchIndex.rebuild(records: m.records)
        #expect(PersonVideos.rows(for: donna(), in: m).isEmpty, "the row does not come back from the source")
    }

    /// Codex round 2 (2026-10-24): removal must follow the page's own
    /// identity order (id, then path + size, then whole-file SHA-256). A
    /// pick of video A, renamed, whose OLD path now holds video B, still
    /// shows A; taking B off the page must leave A's pick alone.
    @Test func aReusedPathNeverRemovesAnotherVideosPick() {
        let a = rec("reused.mov")
        var picks = [FeaturedVideo(recordID: a.id, path: a.fullPath, filename: a.filename,
                                   contentHash: nil, addedAt: Date())]
        a.fullPath = "/Volumes/test_T/renamed-A.mov"
        let b = rec("reused.mov")
        b.detectedPeople = ["Donna"]
        let m = model([a, b])
        #expect(FeaturedVideos.resolve(picks, in: m).videos.map(\.id) == [a.id], "precondition: the pick shows A")
        #expect(PersonVideos.rows(for: donna(), in: m).map(\.id) == [b.id], "precondition: B is tagged")

        FeaturedVideos.removePicks(resolvingTo: PersonVideoRemoval.rowRecords(b, in: m), from: &picks, in: m)
        #expect(picks.map(\.recordID) == [a.id], "A's pick survives taking B off the page")

        FeaturedVideos.removePicks(resolvingTo: PersonVideoRemoval.rowRecords(a, in: m), from: &picks, in: m)
        #expect(picks.isEmpty, "taking A off removes A's pick")
    }

    @Test func anotherPersonOnTheSameVideoIsUntouched() {
        let r = rec("both.mov")
        r.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date()),
                                   ConfirmedTag(name: "Dan", confirmedAt: Date())]
        r.detectedPeople = ["Donna", "Rick"]
        let m = model([r])
        PersonVideoRemoval.untag([r], profile: donna(), model: m)
        #expect(r.confirmedByUserPeople.map(\.name) == ["Dan"])
        #expect(r.detectedPeople == ["Rick"])
        #expect(!r.rejectedPeople.contains("Dan") && !r.rejectedPeople.contains("Rick"))
    }

    @Test func removeFromPageDropsOnlyThePick() {
        let r = rec("pick.mov")
        r.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        var picks: [FeaturedVideo] = []
        _ = FeaturedVideos.apply([r], on: true, to: &picks)
        #expect(FeaturedVideos.isFeatured(r, in: picks))
        // The pick half of both actions (the disk write is FeaturedVideos.set, its own tests).
        #expect(FeaturedVideos.apply([r], on: false, to: &picks) == 1)
        #expect(!FeaturedVideos.isFeatured(r, in: picks))
        #expect(r.confirmedByUserPeople.map(\.name) == ["Donna"], "the tag stays: it moves to 'More videos tagged'")
    }

    @Test func scale10kTaggedVideosInBudget() {
        let recs = (0..<10_000).map { i -> VideoRecord in
            let r = rec("v\(i).mov")
            r.detectedPeople = ["Donna"]
            return r
        }
        let m = model(recs)
        let elapsed = ContinuousClock().measure {
            PersonVideoRemoval.untag(recs, profile: donna(), model: m)
        }
        #expect(recs.allSatisfy { $0.detectedPeople.isEmpty })
        #expect(elapsed < .seconds(3), "10k records untagged in \(elapsed) (Debug budget 3 s)")
    }
}
