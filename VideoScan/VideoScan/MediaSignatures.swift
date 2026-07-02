// MediaSignatures.swift
// Cheap magic-byte content sniff for extensionless / unknown-extension scan
// candidates (discovery-completeness feature, 2026-07-02).
//
// Why: "Scan Files With No Extension" and the new "Scan Unrecognized File
// Types" options admit files the extension allowlist can't vouch for. Running
// ffprobe (a subprocess) on every such file is what produced the ~4.9k-junk-
// probe sweeps of backup drives. This sniff reads the first few hundred bytes
// and answers "could this plausibly be a media container?" — sniff-passes go
// to ffprobe exactly as before (ffprobe stays the arbiter), sniff-fails skip
// the subprocess entirely and are counted in the discovery audit.
//
// Scope guard: files with KNOWN media extensions are NEVER sniffed — the
// probe engine consults `needsSniff` first, so normal scans see zero
// behavior change.
//
// Design: `match(header:)` is a pure function over bytes (unit-testable with
// hand-built headers, no filesystem); `sniff(path:)` is the thin I/O wrapper.
// A signature match is deliberately PERMISSIVE (e.g. any RIFF form, a lone
// 'wide' atom): false positives just cost one ffprobe run, while a false
// negative would silently hide real family media — so signatures err open.
//
// Memory: one 264-byte stack buffer per sniffed file; nothing retained.

import Darwin
import Foundation

enum MediaSignatures {

    /// Bytes read by `sniff(path:)`. 264 covers the deepest probe below —
    /// the MPEG-TS sync-byte check at offset 188 (and BDAV at 192).
    static let sniffLength = 264

    /// Verdict of the file-level sniff.
    enum Verdict: Equatable {
        /// A media signature matched (name is for logs/diagnostics only).
        case media(signature: String)
        /// The header was readable and matched nothing — skip ffprobe.
        case noMediaSignature
        /// The file could not be opened/read. NOT a rejection: the probe
        /// engine must fall through to ffprobe so its existence check can
        /// produce the "File not found" trail the volume-unmount abort
        /// accounting depends on (ProbeGroupAbortAccountingTests).
        case unreadable
    }

    /// QuickTime/ISO-BMFF atom types that legitimately open a movie file.
    /// Includes 'wide'/'free'/'skip' padding atoms — Avid/legacy QuickTime
    /// exports (the t1-v/t2-v shape) often start with them.
    private static let quickTimeAtoms: Set<String> = [
        "ftyp", "moov", "mdat", "wide", "free", "skip", "pnot"
    ]

    /// MXF KLV partition-pack key prefix (SMPTE universal label).
    private static let mxfPartitionPack: [UInt8] = [
        0x06, 0x0E, 0x2B, 0x34, 0x02, 0x05, 0x01, 0x01, 0x0D, 0x01, 0x02
    ]

    /// Whether a file with `pathExtension` (lowercased) must pass the sniff
    /// before ffprobe. Known media extensions never sniff — the allowlist
    /// already vouches for them and ffprobe handles damage diagnosis.
    static func needsSniff(pathExtension ext: String,
                           videoExtensions: Set<String>,
                           audioExtensions: Set<String>) -> Bool {
        if ext.isEmpty { return true }
        return !videoExtensions.contains(ext) && !audioExtensions.contains(ext)
    }

    /// Zero-based byte view over the header with the two probe primitives
    /// every signature check needs. (Data SLICES keep their parent's indices;
    /// copying to [UInt8] makes byte 0 the start of the file, always.)
    private struct Header {
        let b: [UInt8]
        init(_ data: Data) { b = [UInt8](data) }
        var count: Int { b.count }
        func ascii(_ range: Range<Int>) -> String? {
            guard range.upperBound <= b.count else { return nil }
            return String(bytes: b[range], encoding: .ascii)
        }
        func hasPrefix(_ bytes: [UInt8]) -> Bool {
            guard b.count >= bytes.count else { return false }
            return Array(b[0..<bytes.count]) == bytes
        }
    }

    /// Pure signature matcher over the first bytes of a file. Returns the
    /// matched signature's name, or nil when nothing matches.
    static func match(header: Data) -> String? {
        let h = Header(header)
        return matchContainer(h) ?? matchStream(h)
    }

    /// File-container formats (boxed/chunked layouts).
    private static func matchContainer(_ h: Header) -> String? {
        // QuickTime / ISO base media (MP4, MOV, 3GP, HEIF-video…): a 32-bit
        // big-endian atom size followed by a known atom fourcc at offset 4.
        if let fourcc = h.ascii(4..<8), quickTimeAtoms.contains(fourcc) {
            return "quicktime-atom(\(fourcc))"
        }
        // RIFF container (AVI, WAV — also WebP etc.; ffprobe arbitrates).
        if h.ascii(0..<4) == "RIFF" { return "riff" }
        // AIFF/AIFC (IFF FORM container).
        if h.ascii(0..<4) == "FORM", let form = h.ascii(8..<12),
           form == "AIFF" || form == "AIFC" {
            return "aiff"
        }
        // MXF KLV partition pack at offset 0 (no run-in — the common case
        // for Avid essence files; run-in variants fall through to ffprobe
        // only if some other signature matches, which is fine: MXF with
        // run-in is rare and its loss here only costs an audit entry).
        if h.hasPrefix(mxfPartitionPack) { return "mxf" }
        // EBML (Matroska / WebM).
        if h.hasPrefix([0x1A, 0x45, 0xDF, 0xA3]) { return "ebml" }
        // ASF/WMV/WMA header GUID (first 8 of 16 bytes is plenty distinctive).
        if h.hasPrefix([0x30, 0x26, 0xB2, 0x75, 0x8E, 0x66, 0xCF, 0x11]) { return "asf" }
        // Ogg (Theora/Vorbis/Opus).
        if h.ascii(0..<4) == "OggS" { return "ogg" }
        // RealMedia — plenty of it in 1990s family archives.
        if h.ascii(0..<4) == ".RMF" { return "realmedia" }
        // FLV.
        if h.hasPrefix([0x46, 0x4C, 0x56]) { return "flv" }
        return nil
    }

    /// Raw stream formats (packetized/frame-sync layouts) + tagged audio.
    private static func matchStream(_ h: Header) -> String? {
        // MPEG program stream (VOB/MPG) pack header.
        if h.hasPrefix([0x00, 0x00, 0x01, 0xBA]) { return "mpeg-ps" }
        // MPEG video elementary stream (sequence header) — raw .m2v-style dumps.
        if h.hasPrefix([0x00, 0x00, 0x01, 0xB3]) { return "mpeg-video" }
        // MPEG transport stream: sync byte 0x47 at consecutive packet starts.
        // Standard 188-byte packets…
        if h.count > 188, h.b[0] == 0x47, h.b[188] == 0x47 { return "mpeg-ts" }
        // …and BDAV/AVCHD 192-byte packets (4-byte timecode prefix).
        if h.count > 196, h.b[4] == 0x47, h.b[196] == 0x47 { return "mpeg-ts-bdav" }
        // FLAC.
        if h.ascii(0..<4) == "fLaC" { return "flac" }
        // MP3 with ID3v2 tag. (Bare MPEG-audio frame sync is too collision-
        // prone for a 0xFF-first-byte test; untagged MP3s almost always
        // carry a .mp3 extension and never reach the sniff.)
        if h.ascii(0..<3) == "ID3" { return "id3-audio" }
        // DV DIF header block (raw DV stream dumps).
        if h.hasPrefix([0x1F, 0x07, 0x00]) { return "dv-dif" }
        return nil
    }

    /// File-level sniff: read the first `sniffLength` bytes and match.
    /// read()-based (like `FilesystemWalker.isMpegTS`) — mmap can SIGBUS on
    /// network volumes that vanish mid-read.
    static func sniff(path: String) -> Verdict {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return .unreadable }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: sniffLength)
        var sawIOError = false
        let total = buf.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            var t = 0
            while t < sniffLength {
                let m = read(fd, base.advanced(by: t), sniffLength - t)
                if m < 0 { sawIOError = true; break }  // I/O error
                if m == 0 { break }                    // EOF — short file
                t += m
            }
            return t
        }
        // An I/O error before ANY bytes arrived → let ffprobe judge (and the
        // existence check produce its not-found trail). A partial-then-error
        // read still sniffs what we got — signatures live in the first bytes.
        if sawIOError && total == 0 { return .unreadable }
        // A readable-but-empty file has no signature by definition.
        if let sig = match(header: Data(buf[0..<total])) {
            return .media(signature: sig)
        }
        return .noMediaSignature
    }
}
