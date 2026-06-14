import Testing
import Foundation
@testable import VideoScan

struct DerivedFileNamingTests {

    private func fixedTimestamp() -> Date {
        // 2026-06-14 14:30:45 local time.
        var c = DateComponents()
        c.year = 2026; c.month = 6; c.day = 14
        c.hour = 14; c.minute = 30; c.second = 45
        return Calendar.current.date(from: c)!
    }

    @Test("derivedFileURL builds <stem>.vs.<codec>.<timestamp>.<ext>")
    func basicShape() {
        let src = URL(fileURLWithPath: "/Volumes/LaCie/family/thanksgiving_1998.mov")
        let url = derivedFileURL(
            source: src,
            codec: "hevc",
            ext: "mp4",
            timestamp: fixedTimestamp()
        )
        #expect(url.lastPathComponent == "thanksgiving_1998.vs.hevc.20260614-143045.mp4")
        #expect(url.deletingLastPathComponent().path == "/Volumes/LaCie/family")
    }

    @Test("derivedFileURL with purpose segment lands between vs and codec")
    func withPurpose() {
        let src = URL(fileURLWithPath: "/v/donna_birthday.mov")
        let url = derivedFileURL(
            source: src,
            codec: "prores422",
            purpose: "archive",
            ext: "mov",
            timestamp: fixedTimestamp()
        )
        #expect(url.lastPathComponent == "donna_birthday.vs.archive.prores422.20260614-143045.mov")
    }

    @Test("empty purpose is treated as nil")
    func emptyPurposeOmitted() {
        let src = URL(fileURLWithPath: "/v/clip.mov")
        let url = derivedFileURL(
            source: src,
            codec: "hevc",
            purpose: "",
            timestamp: fixedTimestamp()
        )
        #expect(url.lastPathComponent == "clip.vs.hevc.20260614-143045.mp4")
    }

    @Test("preserves source directory")
    func preservesDirectory() {
        let src = URL(fileURLWithPath: "/Users/rick/A B C/odd dir/clip.mov")
        let url = derivedFileURL(
            source: src,
            codec: "hevc",
            timestamp: fixedTimestamp()
        )
        #expect(url.deletingLastPathComponent().path == "/Users/rick/A B C/odd dir")
    }

    @Test("captions/transcript sidecar shape")
    func sidecarShape() {
        let src = URL(fileURLWithPath: "/v/xmas_2003.mp4")
        let captions = derivedFileURL(
            source: src,
            codec: "qwen2vl",
            purpose: "captions",
            ext: "srt",
            timestamp: fixedTimestamp()
        )
        let transcript = derivedFileURL(
            source: src,
            codec: "whisper-v3",
            purpose: "transcript",
            ext: "json",
            timestamp: fixedTimestamp()
        )
        #expect(captions.lastPathComponent == "xmas_2003.vs.captions.qwen2vl.20260614-143045.srt")
        #expect(transcript.lastPathComponent == "xmas_2003.vs.transcript.whisper-v3.20260614-143045.json")
    }
}
