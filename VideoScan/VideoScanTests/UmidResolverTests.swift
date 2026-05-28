import Testing
import Foundation
@testable import VideoScan

// MARK: - UmidResolverTests
//
// Covers VideoScanModel.findSubstitutes(for:) — the substitute-file
// resolver that finds catalog records sharing a MaterialPackage UMID.
// Used by Combine + future operations to swap an offline source for a
// reachable byte-identical copy on another volume.
//
// Step 2 of [[project_archive_combine_pipeline_order]].

@MainActor
struct UmidResolverTests {

    private func makeRecord(name: String, path: String, umid: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = path
        r.materialPackageUMID = umid
        return r
    }

    // The exact form ffprobe emits, captured verbatim from a real Avid MXF.
    private let sampleUMID = "0x060A2B340101010101010F00130000004B9428AB29070371060E2B347F7F2A80"

    @Test
    func emptyUMIDReturnsNoSubstitutes() {
        let model = VideoScanModel()
        let lonely = makeRecord(name: "a.mxf", path: "/V1/a.mxf", umid: "")
        let other = makeRecord(name: "b.mxf", path: "/V2/b.mxf",
                               umid: "0xSOMETHINGELSE")
        model.records = [lonely, other]

        // A record with no UMID must never be matched to anything — even
        // if some hypothetical bug populated `other` with an empty UMID,
        // the resolver must not collapse two unrelated unscanned records
        // into "the same media".
        #expect(model.findSubstitutes(for: lonely).isEmpty)
    }

    @Test
    func sameUMIDOnDifferentPathReturnsMatch() {
        let model = VideoScanModel()
        let onMacPro = makeRecord(name: "X.mxf",
                                  path: "/Volumes/MacPro/Avid/X.mxf",
                                  umid: sampleUMID)
        let copyOnMyBook = makeRecord(name: "X.mxf",
                                      path: "/Volumes/MyBook3Terabytes/AvidBackup/X.mxf",
                                      umid: sampleUMID)
        model.records = [onMacPro, copyOnMyBook]

        let subs = model.findSubstitutes(for: onMacPro)
        #expect(subs.count == 1)
        #expect(subs.first?.fullPath == copyOnMyBook.fullPath)
    }

    @Test
    func multipleCopiesAllReturned() {
        let model = VideoScanModel()
        let primary = makeRecord(name: "X.mxf", path: "/V1/X.mxf", umid: sampleUMID)
        let copyA   = makeRecord(name: "X.mxf", path: "/V2/X.mxf", umid: sampleUMID)
        let copyB   = makeRecord(name: "X.mxf", path: "/V3/X.mxf", umid: sampleUMID)
        let unrelated = makeRecord(name: "Y.mxf", path: "/V4/Y.mxf",
                                   umid: "0xDIFFERENT")
        model.records = [primary, copyA, copyB, unrelated]

        let subs = model.findSubstitutes(for: primary)
        let paths = Set(subs.map(\.fullPath))
        #expect(subs.count == 2)
        #expect(paths == ["/V2/X.mxf", "/V3/X.mxf"])
    }

    @Test
    func selfIsExcluded() {
        // Defensive: even if the records array somehow contains the
        // source record itself (which it normally does — we own it),
        // findSubstitutes must not return it as its own substitute.
        let model = VideoScanModel()
        let rec = makeRecord(name: "X.mxf", path: "/V1/X.mxf", umid: sampleUMID)
        model.records = [rec]

        #expect(model.findSubstitutes(for: rec).isEmpty)
    }

    @Test
    func differentUMIDSDoNotMatch() {
        let model = VideoScanModel()
        let a = makeRecord(name: "A.mxf", path: "/V1/A.mxf", umid: sampleUMID)
        let b = makeRecord(name: "B.mxf", path: "/V2/B.mxf",
                           umid: "0xCOMPLETELYDIFFERENT")
        model.records = [a, b]

        #expect(model.findSubstitutes(for: a).isEmpty)
        #expect(model.findSubstitutes(for: b).isEmpty)
    }

    @Test
    func umidSurvivesCatalogRoundtrip() throws {
        // Encoding/decoding contract: the new field must serialize and
        // deserialize losslessly so a re-scan to populate UMIDs persists
        // across app relaunches.
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_umid_roundtrip_\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = CatalogStore(directory: dir)
        let rec = makeRecord(name: "donna_rock.mxf",
                             path: "/Volumes/MacPro/X.mxf",
                             umid: sampleUMID)
        store.saveNow(records: [rec])

        let reloaded = CatalogStore(directory: dir).load()
        #expect(reloaded.first?.materialPackageUMID == sampleUMID,
                "materialPackageUMID must survive save/load roundtrip")
    }
}
