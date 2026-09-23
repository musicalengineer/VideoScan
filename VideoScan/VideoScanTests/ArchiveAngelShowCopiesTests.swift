// ArchiveAngelShowCopiesTests.swift
// Archive Angel ▸ Show Copies… (Consolidation S4) — the read-only view that
// replaced the Promote Helper's Assess Copies job.
//
//   LOGIC      family discovery (group ∪ lineage ∪ content signature ∪
//              archive links; purged records never join; strangers never
//              join) — ported from AssessCopiesFamilyTests / the Helper
//              lifecycle suite's "unrelated recordings" negative case.
//   FAÇADE     copies(of:) / showCopies(of:): nil + a console line for a
//              gone record; asking again REPLACES the sheet (one at a
//              time — the Helper's rule 3, "never a pile", as sheet state).
//   READ-ONLY  a Show Copies changes no record and posts no catalog mutation.
//   MEDIA      DV · MTS pair · ProRes · Live Photo · a copy on an offline
//              volume. Show Copies reads catalog METADATA only (codecs,
//              container, content signature, volume facts) — it never opens
//              a media file — so the fixtures are catalog records shaped the
//              way the scanner writes them for each format; no ffmpeg
//              fixture is needed (a sensor below pins "opens no media").
//   SCALE      100k records, one Show Copies under budget (Debug).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
private func vr(_ path: String, video: String = "dvvideo", audio: String = "pcm_s16le",
                container: String = "", hash: String = "", seconds: Double = 600,
                make: String? = nil, size: Int64 = 10_000_000) -> VideoRecord {
    let r = VideoRecord()
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.fullPath = path
    r.ext = (path as NSString).pathExtension.lowercased()
    r.container = container
    r.videoCodec = video
    r.audioCodec = audio
    r.durationSeconds = seconds
    r.contentHash = hash
    r.originMake = make
    r.sizeBytes = size
    return r
}

@MainActor
private func target(_ path: String, reachable: Bool = true) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.isReachable = reachable
    return t
}

@Suite("Archive Angel — Show Copies… (read-only)", .serialized)
@MainActor
struct ArchiveAngelShowCopiesTests {

    private func model(_ label: String) throws -> (VideoScanModel, URL) {
        let sb = try MasterArchiveTestSupport.makeSandbox("angel-showcopies-\(label)")
        let model = MasterArchiveTestSupport.makeModel(sb)
        model.previewSweep.stop()
        model.archiveAngel.sweep.stop()
        return (model, sb.root)
    }

    // MARK: Logic — family discovery (ported from AssessCopiesFamilyTests)

    @Test("the family follows the duplicate group, lineage (transitive) and the content signature; purged and strangers stay out")
    func familyFollowsGroupLineageAndSignature() throws {
        let (model, root) = try model("family")
        defer { try? FileManager.default.removeItem(at: root) }
        let g = UUID()
        let seed = vr("/Volumes/A/seed.dv"); seed.duplicateGroupID = g; seed.contentHash = "v1:abc"
        let twin = vr("/Volumes/B/twin.dv"); twin.duplicateGroupID = g
        let child = vr("/Volumes/A/seed_access.mov", video: "hevc", audio: "aac"); child.derivedFrom = twin.id
        let grandchild = vr("/Volumes/A/seed_access_clip.mov", video: "hevc", audio: "aac"); grandchild.derivedFrom = child.id
        let hashTwin = vr("/Volumes/C/other name.dv"); hashTwin.contentHash = "v1:abc"
        let stranger = vr("/Volumes/C/stranger.dv")
        let purged = vr("/Volumes/C/purged.dv"); purged.duplicateGroupID = g; purged.purgedAt = Date()
        model.records = [seed, twin, child, grandchild, hashTwin, stranger, purged]
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/B"), target("/Volumes/C")]

        let family = ArchiveAngelCopyFamily.collect(seed: seed, catalog: model)
        #expect(Set(family.map(\.id)) == [seed.id, twin.id, child.id, grandchild.id, hashTwin.id])
        #expect(family.map(\.fullPath) == family.map(\.fullPath).sorted(), "listed in path order, as the Helper did")

        let inputs = ArchiveAngelCopyFamily.projectInputs(family, catalog: model)
        #expect(inputs.count == 5)
        let a = CopyFamilyAssessor.assess(inputs)
        #expect(a.recommendedRepresentation?.instances.count == 3)          // seed, twin, hashTwin
        #expect(a.representations.contains { $0.role == .accessCopy })
    }

    @Test("NEGATIVE: unrelated recordings never join each other's family, from either side")
    func unrelatedRecordingsStayApart() throws {
        let (model, root) = try model("unrelated")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = vr("/Volumes/A/wedding.mov", video: "h264", audio: "aac", hash: "h-wedding")
        let b = vr("/Volumes/A/graduation.mov", video: "h264", audio: "aac", hash: "h-graduation")
        model.records = [a, b]
        #expect(ArchiveAngelCopyFamily.collect(seed: a, catalog: model).map(\.id) == [a.id])
        #expect(ArchiveAngelCopyFamily.collect(seed: b, catalog: model).map(\.id) == [b.id])
    }

    @Test("the Master Archive copy and its promotion source are the same recording")
    func archiveLinksJoinTheFamily() throws {
        let (model, root) = try model("archive-links")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = vr("/Volumes/A/Clip 01.dv")
        let copy = vr("/Volumes/FamilyArchive/1997/1997-xx-xx_Clip-01.dv")
        copy.derivedFrom = source.id
        copy.derivationKind = ArchivePromotion.derivationKind
        model.records = [source, copy]
        #expect(model.isArchiveCopy(copy))
        let fromCopy = ArchiveAngelCopyFamily.collect(seed: copy, catalog: model)
        #expect(Set(fromCopy.map(\.id)) == [source.id, copy.id])
        let inputs = ArchiveAngelCopyFamily.projectInputs(fromCopy, catalog: model)
        #expect(inputs.first { $0.id == copy.id }?.isArchiveCopy == true)
        #expect(inputs.first { $0.id == source.id }?.isArchiveCopy == false)
    }

    // MARK: Façade

    @Test("copies(of:) answers the family's assessment; a gone record answers nil")
    func facadeAnswers() throws {
        let (model, root) = try model("facade")
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = vr("/Volumes/A/tape.dv", hash: "v1:tape")
        let twin = vr("/Volumes/B/tape.dv", hash: "v1:tape")
        model.records = [seed, twin]
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/B")]
        let req = try #require(model.archiveAngel.copies(of: seed.id))
        #expect(req.seedID == seed.id)
        #expect(req.seedFilename == "tape.dv")
        #expect(req.familyCount == 2)
        #expect(req.assessment.headline == "2 locations → 1 distinct representation")
        #expect(req.assessment.recommendedRepresentation?.role == .originalSource)
        #expect(model.archiveAngel.copies(of: UUID()) == nil)
    }

    @Test("showCopies(of:) presents ONE sheet: asking again replaces it (the Helper's never-a-pile rule, as sheet state)")
    func showCopiesReplaces() throws {
        let (model, root) = try model("present")
        defer { try? FileManager.default.removeItem(at: root) }
        let a = vr("/Volumes/A/a.dv", hash: "h-a"), b = vr("/Volumes/A/b.dv", hash: "h-b")
        model.records = [a, b]
        let presenter = model.archiveAngel.showCopiesPresenter
        #expect(presenter.request == nil)
        model.archiveAngel.showCopies(of: a.id)
        #expect(presenter.request?.seedID == a.id)
        model.archiveAngel.showCopies(of: b.id)
        #expect(presenter.request?.seedID == b.id, "the second ask replaces the first")
        model.archiveAngel.showCopies(of: UUID())
        #expect(presenter.request == nil, "a record that is gone shows nothing")
    }

    // MARK: Read-only

    @Test("READ-ONLY: Show Copies changes no record and posts no catalog mutation")
    func readOnly() throws {
        let (model, root) = try model("readonly")
        defer { try? FileManager.default.removeItem(at: root) }
        let seed = vr("/Volumes/A/Christmas 1994.dv", hash: "v1:x")
        seed.userDate = "1994-12-25"; seed.userDateConfidence = "known"
        let twin = vr("/Volumes/B/Christmas 1994.dv", hash: "v1:x")      // no date of its own
        model.records = [seed, twin]
        var posts = 0
        let token = NotificationCenter.default.addObserver(forName: .videoScanCatalogMutated, object: nil, queue: nil) { _ in
            posts += 1
        }
        defer { NotificationCenter.default.removeObserver(token) }
        model.archiveAngel.showCopies(of: twin.id)
        #expect(model.archiveAngel.showCopiesPresenter.request?.familyCount == 2)
        #expect(posts == 0)
        #expect(twin.userDate == nil, "the Helper stamped the family date on promote; Show Copies never writes")
        #expect(seed.userDate == "1994-12-25")
    }

    // MARK: Media matrix (catalog metadata as the scanner writes it per format)

    @Test("MEDIA DV: byte-identical tapes on two drives + an HEVC access copy → the DV is the original")
    func mediaDV() throws {
        let (model, root) = try model("dv")
        defer { try? FileManager.default.removeItem(at: root) }
        let dv1 = vr("/Volumes/A/test_tape.dv", container: "dv", hash: "v1:dv")
        let dv2 = vr("/Volumes/B/test_tape.dv", container: "dv", hash: "v1:dv")
        let access = vr("/Volumes/A/test_tape_access.mov", video: "hevc", audio: "aac", container: "mov")
        access.derivedFrom = dv1.id
        model.records = [dv1, dv2, access]
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/B")]
        let a = try #require(model.archiveAngel.copies(of: access.id)).assessment
        #expect(a.recommendedRepresentation?.role == .originalSource)
        #expect(a.recommendedRepresentation?.videoCodec == "dvvideo")
        #expect(a.recommendedRepresentation?.instances.count == 2)
        #expect(a.representations.contains { $0.role == .accessCopy })
    }

    @Test("MEDIA MTS pair: the same AVCHD clip on two cards is ONE native representation with two locations")
    func mediaMTSPair() throws {
        let (model, root) = try model("mts")
        defer { try? FileManager.default.removeItem(at: root) }
        let card1 = vr("/Volumes/X9/card1/test_00000.MTS", video: "h264", audio: "ac3", container: "mts", hash: "v1:mts")
        let card2 = vr("/Volumes/X10/card2/test_00000.MTS", video: "h264", audio: "ac3", container: "mts", hash: "v1:mts")
        model.records = [card1, card2]
        model.scanTargets = [target("/Volumes/X9"), target("/Volumes/X10")]
        let a = try #require(model.archiveAngel.copies(of: card1.id)).assessment
        #expect(a.representations.count == 1)
        #expect(a.recommendedRepresentation?.role == .originalSource, "AVCHD .mts is camera-native, not an access copy")
        #expect(a.recommendedRepresentation?.instances.count == 2)
        #expect(a.recommendedRepresentation?.instancesByteIdentical == true)
    }

    @Test("MEDIA ProRes: a ProRes made from the DV is the editing derivative, never the original")
    func mediaProRes() throws {
        let (model, root) = try model("prores")
        defer { try? FileManager.default.removeItem(at: root) }
        let dv = vr("/Volumes/A/test_clip.dv", container: "dv", hash: "v1:clip", size: 13_000_000_000)
        let prores = vr("/Volumes/Edit/test_clip.mov", video: "prores", audio: "pcm_s16le", container: "mov",
                        size: 30_000_000_000)
        prores.derivedFrom = dv.id
        model.records = [dv, prores]
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/Edit")]
        let a = try #require(model.archiveAngel.copies(of: prores.id)).assessment
        #expect(a.recommendedRepresentation?.videoCodec == "dvvideo", "bigger never wins alone")
        #expect(a.representations.first { $0.videoCodec == "prores" }?.role == .editingDerivative)
    }

    @Test("MEDIA Live Photo: the iPhone's HEVC motion .MOV and its backup twin are one native representation")
    func mediaLivePhoto() throws {
        let (model, root) = try model("livephoto")
        defer { try? FileManager.default.removeItem(at: root) }
        let phone = vr("/Volumes/A/Photos/test_IMG_1234.MOV", video: "hevc", audio: "aac", container: "mov",
                       hash: "v1:live", seconds: 2.9, make: "Apple", size: 3_000_000)
        let backup = vr("/Volumes/B/Backup/test_IMG_1234.MOV", video: "hevc", audio: "aac", container: "mov",
                        hash: "v1:live", seconds: 2.9, make: "Apple", size: 3_000_000)
        model.records = [phone, backup]
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/B")]
        let a = try #require(model.archiveAngel.copies(of: phone.id)).assessment
        #expect(a.representations.count == 1)
        #expect(a.recommendedRepresentation?.role == .originalSource, "a device-stamped HEVC is camera-native")
        #expect(a.recommendedInstanceID != nil)
    }

    @Test("MEDIA offline volume: a copy on an unmounted drive is LISTED (offline) and never the recommended copy")
    func mediaOfflineVolume() throws {
        let (model, root) = try model("offline")
        defer { try? FileManager.default.removeItem(at: root) }
        let online = vr("/Volumes/A/test_tape.dv", container: "dv", hash: "v1:tape")
        let offline = vr("/Volumes/OldMyBook/test_tape.dv", container: "dv", hash: "v1:tape")
        offline.humanScoreBoostForTest()
        model.records = [online, offline]
        model.scanTargets = [target("/Volumes/A"), target("/Volumes/OldMyBook", reachable: false)]
        let req = try #require(model.archiveAngel.copies(of: offline.id))
        #expect(req.familyCount == 2, "the offline copy is part of the family")
        let rep = try #require(req.assessment.recommendedRepresentation)
        let offlineInstance = rep.instances.first { $0.id == offline.id }
        #expect(offlineInstance?.isReachable == false)
        #expect(req.assessment.recommendedInstanceID == online.id, "the mounted copy is the one to keep")
    }

    @Test("SENSOR: Show Copies opens no media — its engine and view never name ffprobe, ffmpeg, AVAsset or FileHandle")
    func opensNoMedia() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("VideoScan/ArchiveAngel")
        for file in ["Review/ArchiveAngelShowCopies.swift", "UI/ArchiveAngelShowCopiesView.swift",
                     "Facade/ArchiveAngel+ShowCopies.swift"] {
            let src = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            // Tool names as launched ("ffprobe" / "ffmpeg" string literals),
            // not the StreamType case `.ffprobeFailed` the projection reads.
            for word in ["\"ffprobe", "\"ffmpeg", "ProcessRunner", "AVAsset", "AVURLAsset", "FileHandle", "Process("] {
                #expect(!src.contains(word), "\(file) names \(word)")
            }
        }
    }

    // MARK: Scale

    @Test("SCALE: one Show Copies over a 100k-record catalog — under 2 s (Debug)")
    func scale() throws {
        let (model, root) = try model("scale")
        defer { try? FileManager.default.removeItem(at: root) }
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = vr("/Volumes/S\(i % 7)/f\(i).mov", video: "h264", audio: "aac", hash: "h\(i)")
            if i % 50 == 0 { r.duplicateGroupID = UUID() }
            records.append(r)
        }
        let seed = records[4_242]
        let twin = vr("/Volumes/T/f4242.mov", video: "h264", audio: "aac", hash: seed.contentHash)
        records.append(twin)
        model.records = records
        let clock = ContinuousClock()
        var req: ArchiveAngelShowCopiesRequest?
        let elapsed = clock.measure { req = model.archiveAngel.copies(of: seed.id) }
        let s = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        print("[angel-s4] show copies over 100k: \(String(format: "%.3f", s)) s")
        #expect(req?.familyCount == 2)
        #expect(s < 2, "Show Copies over 100k records took \(s) s")
    }
}

private extension VideoRecord {
    /// A human touch (stars + a note) on the OFFLINE copy, so the offline
    /// test proves reachability outranks human metadata in the election.
    @MainActor func humanScoreBoostForTest() {
        starRating = 3
        notes = "Grandma's copy"
    }
}
