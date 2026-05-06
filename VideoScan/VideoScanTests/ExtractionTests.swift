import Testing
import Foundation
@testable import VideoScan

// MARK: - FilesystemWalker Tests

@Suite("FilesystemWalker - Sync Byte Detection")
struct FilesystemWalkerSyncTests {

    @Test("MPEG-TS sync byte 0x47 at offset 0 is detected")
    func mpegTSSyncAtZero() throws {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).ts"
        var data = Data(count: 188)
        data[0] = 0x47
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(FilesystemWalker.isMpegTS(URL(fileURLWithPath: path)))
    }

    @Test("MPEG-TS sync byte 0x47 at offset 4 (BDA style) is detected")
    func mpegTSSyncAtFour() throws {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).ts"
        var data = Data(count: 192)
        data[4] = 0x47
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(FilesystemWalker.isMpegTS(URL(fileURLWithPath: path)))
    }

    @Test("Non-TS file is rejected")
    func notMpegTS() throws {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).ts"
        let data = Data([0x00, 0x00, 0x00, 0x00, 0x00, 0xFF, 0xFF])
        try data.write(to: URL(fileURLWithPath: path))
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!FilesystemWalker.isMpegTS(URL(fileURLWithPath: path)))
    }

    @Test("Missing file returns false")
    func missingFile() {
        #expect(!FilesystemWalker.isMpegTS(URL(fileURLWithPath: "/nonexistent_\(UUID()).ts")))
    }

    @Test("Empty file returns false")
    func emptyFile() throws {
        let path = NSTemporaryDirectory() + "test_\(UUID().uuidString).ts"
        FileManager.default.createFile(atPath: path, contents: Data())
        defer { try? FileManager.default.removeItem(atPath: path) }

        #expect(!FilesystemWalker.isMpegTS(URL(fileURLWithPath: path)))
    }
}
