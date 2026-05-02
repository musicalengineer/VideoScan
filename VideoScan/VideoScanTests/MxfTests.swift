import Testing
import Foundation
@testable import VideoScan

// MARK: - MXF Header Parser Tests

struct MxfBinaryHelperTests {

    @Test func readU16BE() {
        let data = Data([0x01, 0x02])
        #expect(MxfHeaderParser.readU16BE(data: data, pos: 0) == 0x0102)
    }

    @Test func readU32BE() {
        let data = Data([0xDE, 0xAD, 0xBE, 0xEF])
        #expect(MxfHeaderParser.readU32BE(data: data, pos: 0) == 0xDEADBEEF)
    }

    @Test func readU64BE() {
        let data = Data([0x00, 0x00, 0x00, 0x00, 0xDE, 0xAD, 0xBE, 0xEF])
        #expect(MxfHeaderParser.readU64BE(data: data, pos: 0) == 0x00000000DEADBEEF)
    }

    @Test func readU32BEAtOffset() {
        let data = Data([0xFF, 0xFF, 0x00, 0x00, 0x00, 0x01])
        #expect(MxfHeaderParser.readU32BE(data: data, pos: 2) == 1)
    }

    @Test func readBERShortForm() {
        let data = Data([0x42])
        let result = MxfHeaderParser.readBER(data: data, pos: 0)
        #expect(result != nil)
        #expect(result!.0 == 0x42)
        #expect(result!.1 == 1)
    }

    @Test func readBERLongForm() {
        let data = Data([0x82, 0x01, 0x00])
        let result = MxfHeaderParser.readBER(data: data, pos: 0)
        #expect(result != nil)
        #expect(result!.0 == 256)
        #expect(result!.1 == 3)
    }

    @Test func readBEREmptyData() {
        let data = Data()
        #expect(MxfHeaderParser.readBER(data: data, pos: 0) == nil)
    }
}

struct MxfCodecIdentificationTests {

    @Test func identifyDNxHD() {
        let ul = "060e2b340401010a00000000037100xx"
        #expect(MxfHeaderParser.identifyCodec(ul: ul) == "DNxHD")
    }

    @Test func identifyH264() {
        let ul = "060e2b340401010a0000000004010203"
        #expect(MxfHeaderParser.identifyCodec(ul: ul) == "H.264")
    }

    @Test func identifyUncompressed() {
        let ul = "060e2b340401010a0401020100000000"
        #expect(MxfHeaderParser.identifyCodec(ul: ul) == "Uncompressed")
    }

    @Test func identifyAvidUncompressed() {
        let ul = "060e2b340401010e0000000000000000"
        #expect(MxfHeaderParser.identifyCodec(ul: ul) == "Avid Uncompressed")
    }

    @Test func unknownCodecIncludesPrefix() {
        let ul = "060e2b340401010a9999999999999999"
        let result = MxfHeaderParser.identifyCodec(ul: ul)
        #expect(result.hasPrefix("Unknown ("))
    }
}

struct MxfPixelLayoutTests {

    @Test func rgbaLayout() {
        let data = Data([0x52, 8, 0x47, 8, 0x42, 8, 0x41, 8, 0x00, 0x00])
        let result = MxfHeaderParser.decodePixelLayout(data: data, pos: 0, len: data.count)
        #expect(result == "RGBA 8+8+8+8")
    }

    @Test func yuvLayout() {
        let data = Data([0x59, 10, 0x42, 10, 0x52, 10, 0x00, 0x00])
        let result = MxfHeaderParser.decodePixelLayout(data: data, pos: 0, len: data.count)
        #expect(result == "YBR 10+10+10")
    }

    @Test func emptyLayout() {
        let data = Data([0x00, 0x00])
        let result = MxfHeaderParser.decodePixelLayout(data: data, pos: 0, len: data.count)
        #expect(result.isEmpty)
    }

    @Test func parseNonexistentFile() {
        let result = MxfHeaderParser.parse(fileAt: "/nonexistent/file.mxf")
        #expect(result == nil)
    }
}

// MARK: - MXF Metadata Struct Tests

struct MxfMetadataTests {

    @Test func defaultValues() {
        let m = MxfHeaderParser.MxfMetadata()
        #expect(m.width == 0)
        #expect(m.height == 0)
        #expect(m.codecLabel.isEmpty)
        #expect(m.hasVideo == false)
        #expect(m.hasAudio == false)
        #expect(m.audioChannels == 0)
        #expect(m.durationSeconds == 0)
    }
}

// MARK: - MXF Header Parser with Real MXF Files

struct MxfParserIntegrationTests {

    static let fixturesDir: String = {
        let thisFile = #filePath
        let repoRoot = URL(fileURLWithPath: thisFile)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        return repoRoot.appendingPathComponent("tests/fixtures/videos").path
    }()

    @Test func parseMXFVideoAudio() {
        let path = "\(Self.fixturesDir)/test_video_audio.mxf"
        _ = MxfHeaderParser.parse(fileAt: path)
    }

    @Test func parseMXFVideoOnly() {
        let path = "\(Self.fixturesDir)/test_video_only.mxf"
        let result = MxfHeaderParser.parse(fileAt: path)
        if let meta = result {
            #expect(meta.audioChannels == 0, "Video-only MXF should have no audio channels")
        }
    }
}

// MARK: - AvbParser Tests

struct AvbParserTests {

    @Test func parseNonexistentFile() {
        let result = AvbParser.parse(fileAt: "/nonexistent/file.avb")
        #expect(result.clips.isEmpty)
        #expect(!result.errors.isEmpty)
    }

    @Test func scanEmptyDirectory() {
        let tmpDir = NSTemporaryDirectory() + "avb_test_\(UUID().uuidString)"
        FileManager.default.createFile(atPath: tmpDir, contents: nil)
        defer { try? FileManager.default.removeItem(atPath: tmpDir) }
        let results = AvbParser.scanDirectory(tmpDir)
        #expect(results.isEmpty)
    }

    @Test func parseEmptyData() {
        let tmpPath = NSTemporaryDirectory() + "test_\(UUID().uuidString).avb"
        FileManager.default.createFile(atPath: tmpPath, contents: Data([0x00, 0x01, 0x02]))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        let result = AvbParser.parse(fileAt: tmpPath)
        #expect(result.clips.isEmpty)
    }
}

// MARK: - AvbClip / AvbTrack Tests

struct AvbDataModelTests {

    @Test func avbTrackProperties() {
        let track = AvbTrack(
            index: 1,
            mediaKind: "picture",
            startPos: 0,
            length: 900,
            sourceClipMobID: "urn:smpte:umid:test",
            sourceTrackID: 1
        )
        #expect(track.index == 1)
        #expect(track.mediaKind == "picture")
        #expect(track.length == 900)
    }

    @Test func avbBinResultProperties() {
        let result = AvbBinResult(
            filePath: "/test/bin.avb",
            binName: "TestBin",
            creatorVersion: "22.0",
            lastSave: nil,
            clips: [],
            errors: []
        )
        #expect(result.binName == "TestBin")
        #expect(result.clips.isEmpty)
        #expect(result.errors.isEmpty)
    }
}
