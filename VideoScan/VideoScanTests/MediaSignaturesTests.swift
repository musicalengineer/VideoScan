// MediaSignaturesTests.swift
// Unit tests for the magic-byte content sniff that gates extensionless /
// unknown-extension scan candidates before ffprobe (discovery-completeness
// feature, 2026-07-02).
//
// Red/green: the whole suite fails to COMPILE at 3628e07 (MediaSignatures is
// new API) — same convention as the ScanMergeScopeTests tripwire tests.
//
// The positive cases are hand-built headers per signature (no fixtures, no
// ffmpeg); the negatives are the junk shapes the sniff exists to reject
// (zeros, plain text, JPEG stills). The t1-v case — a truncated Avid/
// QuickTime export whose header is a 'wide' atom followed by 'mdat' and
// zeros, no moov — MUST pass the sniff: it is real (damaged) media whose
// fate belongs to ffprobe + the junk gate, and the audit must see it as
// probe-rejected, not sniff-rejected.

import Testing
import Foundation
@testable import VideoScan

@Suite("MediaSignatures — magic-byte sniff")
struct MediaSignaturesTests {

    // MARK: - Header builders

    /// 4-byte big-endian atom size + fourcc, padded — a minimal QuickTime opener.
    private func qtHeader(fourcc: String, pad: Int = 24) -> Data {
        var d = Data([0x00, 0x00, 0x00, 0x14])
        d.append(fourcc.data(using: .ascii)!)
        d.append(Data(repeating: 0x11, count: pad))
        return d
    }

    /// The t1-v stub shape: 'wide' atom (size 8), then an 'mdat' header whose
    /// size claims the rest of the file, then zeros. No moov — ffprobe fails.
    static func t1vStubData(totalSize: Int = 4096) -> Data {
        var d = Data([0x00, 0x00, 0x00, 0x08])
        d.append("wide".data(using: .ascii)!)
        var mdatSize = UInt32(totalSize - 8).bigEndian
        withUnsafeBytes(of: &mdatSize) { d.append(contentsOf: $0) }
        d.append("mdat".data(using: .ascii)!)
        d.append(Data(repeating: 0, count: max(0, totalSize - d.count)))
        return d
    }

    // MARK: - Positive signatures

    @Test("QuickTime atoms open a movie", arguments: ["ftyp", "moov", "mdat", "wide", "free", "skip", "pnot"])
    func quickTimeAtoms(fourcc: String) {
        #expect(MediaSignatures.match(header: qtHeader(fourcc: fourcc)) == "quicktime-atom(\(fourcc))")
    }

    @Test func t1vStubPassesSniff() {
        // The 4 KB truncated stub is (damaged) MEDIA to the sniff — ffprobe
        // and the junk gate decide its catalog fate, not the sniff.
        #expect(MediaSignatures.match(header: Self.t1vStubData().prefix(MediaSignatures.sniffLength)) != nil)
    }

    @Test func riffAndAiff() {
        #expect(MediaSignatures.match(header: "RIFF\u{04}\u{00}\u{00}\u{00}AVI LIST".data(using: .ascii)!) == "riff")
        #expect(MediaSignatures.match(header: "RIFF\u{04}\u{00}\u{00}\u{00}WAVEfmt ".data(using: .ascii)!) == "riff")
        #expect(MediaSignatures.match(header: "FORM\u{00}\u{00}\u{00}\u{08}AIFFCOMM".data(using: .ascii)!) == "aiff")
        // FORM with a non-audio form type is NOT media.
        #expect(MediaSignatures.match(header: "FORM\u{00}\u{00}\u{00}\u{08}ILBMBODY".data(using: .ascii)!) == nil)
    }

    @Test func mxfPartitionPack() {
        var d = Data([0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02, 0x01, 0x01, 0x02])
        d.append(Data(repeating: 0, count: 16))
        #expect(MediaSignatures.match(header: d) == "mxf")
    }

    @Test func ebmlMatroska() {
        #expect(MediaSignatures.match(header: Data([0x1A, 0x45, 0xDF, 0xA3, 0x01, 0x00, 0x00, 0x00])) == "ebml")
    }

    @Test func mpegProgramAndElementaryStreams() {
        #expect(MediaSignatures.match(header: Data([0x00, 0x00, 0x01, 0xBA, 0x44, 0x00])) == "mpeg-ps")
        #expect(MediaSignatures.match(header: Data([0x00, 0x00, 0x01, 0xB3, 0x2D, 0x02])) == "mpeg-video")
    }

    @Test func mpegTransportStream() {
        // 0x47 sync at offsets 0 AND 188 (two packet starts).
        var ts = Data(repeating: 0x00, count: 264)
        ts[0] = 0x47
        ts[188] = 0x47
        #expect(MediaSignatures.match(header: ts) == "mpeg-ts")
        // BDAV/AVCHD: 192-byte packets, sync at 4 and 196.
        var bdav = Data(repeating: 0x00, count: 264)
        bdav[4] = 0x47
        bdav[196] = 0x47
        #expect(MediaSignatures.match(header: bdav) == "mpeg-ts-bdav")
        // A single 0x47 with no second sync byte is NOT a transport stream.
        var lone = Data(repeating: 0x00, count: 264)
        lone[0] = 0x47
        #expect(MediaSignatures.match(header: lone) == nil)
    }

    @Test func flvAsfOggRealFlacId3Dv() {
        #expect(MediaSignatures.match(header: "FLV\u{01}\u{05}".data(using: .ascii)!) == "flv")
        #expect(MediaSignatures.match(header: Data([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11, 0xA6, 0xD9])) == "asf")
        #expect(MediaSignatures.match(header: "OggS\u{00}\u{02}".data(using: .ascii)!) == "ogg")
        #expect(MediaSignatures.match(header: ".RMF\u{00}\u{00}\u{00}\u{12}".data(using: .ascii)!) == "realmedia")
        #expect(MediaSignatures.match(header: "fLaC\u{00}\u{00}\u{00}\u{22}".data(using: .ascii)!) == "flac")
        #expect(MediaSignatures.match(header: "ID3\u{04}\u{00}".data(using: .ascii)!) == "id3-audio")
        #expect(MediaSignatures.match(header: Data([0x1F, 0x07, 0x00, 0x3F, 0x51])) == "dv-dif")
    }

    // MARK: - QA fix batch 2026-07-02: ADTS AAC / AC-3 / CAF / RF64

    @Test func adtsAacSignature() {
        // ADTS byte 1 layout: 1111 (sync) | ID (1 bit) | layer (2 bits, MUST
        // be 00) | protection_absent (1 bit) — so all four ID/protection
        // combinations are valid ADTS second bytes.
        #expect(MediaSignatures.match(header: Data([0xFF, 0xF1, 0x50, 0x80, 0x1F, 0x3F])) == "adts-aac",
                "MPEG-4 ADTS, no CRC (0xFFF1) — the common shape")
        #expect(MediaSignatures.match(header: Data([0xFF, 0xF0, 0x50, 0x80])) == "adts-aac",
                "MPEG-4 ADTS with CRC (0xFFF0)")
        #expect(MediaSignatures.match(header: Data([0xFF, 0xF9, 0x50, 0x80])) == "adts-aac",
                "MPEG-2 ADTS, no CRC (0xFFF9)")
        #expect(MediaSignatures.match(header: Data([0xFF, 0xF8, 0x50, 0x80])) == "adts-aac",
                "MPEG-2 ADTS with CRC (0xFFF8)")
        // Non-zero LAYER bits are MPEG audio (MP3/MP2) frame sync, not ADTS —
        // the sniff deliberately stays out of the bare-MP3 collision swamp
        // (see the ID3 comment above).
        #expect(MediaSignatures.match(header: Data([0xFF, 0xFB, 0x90, 0x64])) == nil,
                "MPEG-1 Layer III (bare MP3) is NOT ADTS")
        #expect(MediaSignatures.match(header: Data([0xFF, 0xF2, 0x90, 0x64])) == nil,
                "layer bits 01 is not ADTS")
        #expect(MediaSignatures.match(header: Data([0xFF, 0x00, 0x00, 0x00])) == nil,
                "a lone 0xFF is not a sync word")
    }

    @Test func ac3CafAndRf64Signatures() {
        // AC-3 sync word.
        #expect(MediaSignatures.match(header: Data([0x0B, 0x77, 0x1A, 0x2B, 0x40])) == "ac3")
        #expect(MediaSignatures.match(header: Data([0x77, 0x0B, 0x1A, 0x2B])) == nil,
                "byte-swapped 0x77 0x0B is not the raw AC-3 sync")
        // Core Audio Format: 'caff' + file version. (Data(_.utf8): all-ASCII
        // strings, so the bytes equal the .ascii encoding without the
        // force-unwrapped optional.)
        #expect(MediaSignatures.match(header: Data("caff\u{00}\u{01}\u{00}\u{00}desc".utf8)) == "caf")
        #expect(MediaSignatures.match(header: Data("CAFF\u{00}\u{01}\u{00}\u{00}".utf8)) == nil,
                "the CAF magic is lowercase 'caff' — uppercase is not the signature")
        // RF64 (>4 GB Broadcast-WAV) — RIFF-shaped, treated like RIFF.
        var rf64 = Data("RF64".utf8)
        rf64.append(contentsOf: [0xFF, 0xFF, 0xFF, 0xFF])   // size = -1 per spec
        rf64.append(Data("WAVEds64".utf8))
        #expect(MediaSignatures.match(header: rf64) == "rf64")
        #expect(MediaSignatures.match(header: Data("RF63AAAAWAVE".utf8)) == nil)
    }

    // MARK: - Negatives (the junk the sniff exists to reject)

    @Test func negatives() {
        // All zeros — the classic Avid-tree data blob.
        #expect(MediaSignatures.match(header: Data(repeating: 0, count: 264)) == nil)
        // Plain text.
        #expect(MediaSignatures.match(header: "These are scan notes from 1995, not a movie.".data(using: .utf8)!) == nil)
        // JPEG still (FF D8 FF E0 … JFIF) — images are not ffprobe's job.
        #expect(MediaSignatures.match(header: Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46])) == nil)
        // PNG still.
        #expect(MediaSignatures.match(header: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])) == nil)
        // Empty and too-short-for-any-signature headers.
        #expect(MediaSignatures.match(header: Data()) == nil)
        #expect(MediaSignatures.match(header: Data([0x00, 0x00])) == nil)
        // A QuickTime-SIZED header whose fourcc is garbage.
        #expect(MediaSignatures.match(header: qtHeader(fourcc: "junk")) == nil)
    }

    // MARK: - needsSniff scope guard

    @Test func knownMediaExtensionsNeverSniff() {
        let video: Set<String> = ["mov", "mp4", "mxf"]
        let audio: Set<String> = ["wav", "mp3"]
        #expect(!MediaSignatures.needsSniff(pathExtension: "mov", videoExtensions: video, audioExtensions: audio))
        #expect(!MediaSignatures.needsSniff(pathExtension: "wav", videoExtensions: video, audioExtensions: audio))
        #expect(MediaSignatures.needsSniff(pathExtension: "", videoExtensions: video, audioExtensions: audio))
        #expect(MediaSignatures.needsSniff(pathExtension: "videofile", videoExtensions: video, audioExtensions: audio))
    }

    // MARK: - File-level sniff (I/O wrapper)

    @Test func fileSniffVerdicts() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("vs_sniff_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let media = dir.appendingPathComponent("looks-like-media")
        try qtHeader(fourcc: "ftyp").write(to: media)
        #expect(MediaSignatures.sniff(path: media.path) == .media(signature: "quicktime-atom(ftyp)"))

        let junk = dir.appendingPathComponent("junk-blob")
        try Data(repeating: 0, count: 4096).write(to: junk)
        #expect(MediaSignatures.sniff(path: junk.path) == .noMediaSignature)

        let empty = dir.appendingPathComponent("empty")
        try Data().write(to: empty)
        #expect(MediaSignatures.sniff(path: empty.path) == .noMediaSignature)

        // Nonexistent file → .unreadable, NOT a rejection: the probe engine
        // must fall through to ffprobe so vanished files keep producing the
        // "File not found" abort-accounting trail.
        #expect(MediaSignatures.sniff(path: dir.appendingPathComponent("gone").path) == .unreadable)
    }
}
