// BalancedCopyProofCodex310Tests.swift
// GH #483 items 1–2 — the Codex #310 leftovers: two things a file can hold
// that the proof did not NAME for the file that holds it.
//   1. A QuickTime edit list that plays the same stored second twice hides
//      stored picture WITHOUT shortening the played length, so "stored
//      length > played length" never fires.
//   2. Closed captions (CEA-608/708 in ATSC A53 SEI) ride inside the H.264
//      picture packets. They are not a track, and the decoded pixels do not
//      show them, so a copy whose packets lost them still decoded the same.
// The proof gates a future Trash offer, so each must be named for the file
// that holds it ("— not compared with the other file"), never left for the
// reader to infer from an ownerless "encoding" difference.
//
// Fixtures are generated here with ffmpeg (test patterns, tones, and caption
// bytes written by hand) into per-test scratch — never real media.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

extension QuickTimePatch {
    /// `movie` with its PICTURE track's single edit (D long, from media
    /// time M) replaced by two edits of D/2 from M: the first half plays
    /// twice, the second half is stored and never played, and the played
    /// length is the stored length. `moov` must be last (ffmpeg's default),
    /// so growing it moves no chunk offset.
    static func repeatingFirstHalf(of movie: Data) throws -> Data {
        var data = movie
        guard let moov = atoms(data, from: 0, to: data.count).first(where: { $0.type == "moov" }),
              moov.offset + moov.size == data.count else { throw NotThatFile() }
        for trak in atoms(data, from: moov.offset + 8, to: moov.offset + moov.size) where trak.type == "trak" {
            let mdia = try child("mdia", of: trak, in: data)
            let hdlr = try child("hdlr", of: mdia, in: data)
            guard String(bytes: data[hdlr.offset + 16..<hdlr.offset + 20], encoding: .isoLatin1) == "vide" else { continue }
            let edts = try child("edts", of: trak, in: data)
            let elst = try child("elst", of: edts, in: data)
            guard data[elst.offset + 8] == 0, uint32(data, at: elst.offset + 12) == 1 else { throw NotThatFile() }
            let half = uint32(data, at: elst.offset + 16) / 2
            let mediaTime = uint32(data, at: elst.offset + 20)
            let rate = uint32(data, at: elst.offset + 24)
            for offset in [moov.offset, trak.offset, edts.offset, elst.offset] {
                data.replaceSubrange(offset..<offset + 4, with: bytes(uint32(data, at: offset) + 12))
            }
            data.replaceSubrange(elst.offset + 12..<elst.offset + 20, with: bytes(2) + bytes(half))
            data.insert(contentsOf: bytes(half) + bytes(mediaTime) + bytes(rate), at: elst.offset + 28)
            return data
        }
        throw NotThatFile()
    }

    /// The PICTURE track of `movie` (whose `moov` is last) with what Codex
    /// #394 wrote: a `ctts` of (12 frames, 0), (1 frame, 19456), (37 frames, 0)
    /// and ONE edit of 2 s from media time 0. In a 25 fps, 1/12800 track the
    /// 13th frame's composition time is 12×512 + 19456 = 25600 ticks = 2.0 s:
    /// outside the edit. Its packet is still read in file order and decoded,
    /// then dropped — 50 packets read, 49 frames shown, the played length 2 s.
    static func hidingThirteenthFrame(of movie: Data) throws -> Data {
        var data = movie
        guard var moov = atoms(data, from: 0, to: data.count).first(where: { $0.type == "moov" }),
              moov.offset + moov.size == data.count else { throw NotThatFile() }
        let movieScale = uint32(data, at: try child("mvhd", of: moov, in: data).offset + 20)
        for found in atoms(data, from: moov.offset + 8, to: moov.offset + moov.size) where found.type == "trak" {
            var trak = found
            let mdia = try child("mdia", of: trak, in: data)
            let hdlr = try child("hdlr", of: mdia, in: data)
            guard String(bytes: data[hdlr.offset + 16..<hdlr.offset + 20], encoding: .isoLatin1) == "vide" else { continue }
            let minf = try child("minf", of: mdia, in: data)
            let stbl = try child("stbl", of: minf, in: data)
            guard (try? child("ctts", of: stbl, in: data)) == nil else { throw NotThatFile() }
            let ctts = bytes(40) + Array("ctts".utf8) + bytes(0) + bytes(3) + [12, 0, 1, 19456, 37, 0].flatMap(bytes)
            for offset in [moov.offset, trak.offset, mdia.offset, minf.offset, stbl.offset] {
                data.replaceSubrange(offset..<offset + 4, with: bytes(uint32(data, at: offset) + 40))
            }
            data.insert(contentsOf: ctts, at: stbl.offset + stbl.size)
            moov.size += 40
            trak.size += 40
            let elst = bytes(28) + Array("elst".utf8) + bytes(0) + bytes(1) + bytes(2 * movieScale) + bytes(0) + bytes(0x10000)
            if let edts = try? child("edts", of: trak, in: data) {
                let old = try child("elst", of: edts, in: data)
                for offset in [moov.offset, trak.offset, edts.offset] {
                    data.replaceSubrange(offset..<offset + 4, with: bytes(uint32(data, at: offset) + 28 - old.size))
                }
                data.replaceSubrange(old.offset..<old.offset + old.size, with: elst)
            } else {
                let tkhd = try child("tkhd", of: trak, in: data)
                for offset in [moov.offset, trak.offset] {
                    data.replaceSubrange(offset..<offset + 4, with: bytes(uint32(data, at: offset) + 36))
                }
                data.insert(contentsOf: bytes(36) + Array("edts".utf8) + elst, at: tkhd.offset + tkhd.size)
            }
            return data
        }
        throw NotThatFile()
    }

    /// `movie` (`moov` last) with an ATSC caption SEI (CEA-608 in ITU-T T.35
    /// "GA94") appended to its HEVC picture's `hvcC` as one more prefix-SEI
    /// array: captions in the decoder configuration, in no packet (Codex #394).
    static func captionInHvcC(of movie: Data) throws -> Data {
        var data = movie
        guard let moov = atoms(data, from: 0, to: data.count).first(where: { $0.type == "moov" }),
              moov.offset + moov.size == data.count else { throw NotThatFile() }
        for trak in atoms(data, from: moov.offset + 8, to: moov.offset + moov.size) where trak.type == "trak" {
            let mdia = try child("mdia", of: trak, in: data)
            let hdlr = try child("hdlr", of: mdia, in: data)
            guard String(bytes: data[hdlr.offset + 16..<hdlr.offset + 20], encoding: .isoLatin1) == "vide" else { continue }
            let minf = try child("minf", of: mdia, in: data)
            let stbl = try child("stbl", of: minf, in: data)
            let stsd = try child("stsd", of: stbl, in: data)
            let entry = Atom(type: "", offset: stsd.offset + 16, size: uint32(data, at: stsd.offset + 16))
            // A visual sample entry's boxes follow its 86-byte header.
            let hvcC = try child("hvcC", of: entry, in: data, skipping: 86)
            // NAL header (type 39, layer 0, tid 1), payload type 4, size 17, then the T.35 caption payload and the stop bit.
            let sei: [UInt8] = [0x4E, 0x01, 0x04, 17, 0xB5, 0x00, 0x31] + Array("GA94".utf8)
                + [0x03, 0xC2, 0xFF, 0xFC, 0x94, 0x2C, 0xFC, 0x80, 0x80, 0xFF, 0x80]
            let array: [UInt8] = [39, 0, 1, 0, UInt8(sei.count)] + sei
            for offset in [moov.offset, trak.offset, mdia.offset, minf.offset, stbl.offset, stsd.offset, entry.offset, hvcC.offset] {
                data.replaceSubrange(offset..<offset + 4, with: bytes(uint32(data, at: offset) + array.count))
            }
            data[hvcC.offset + 8 + 22] += 1  // numOfArrays
            data.insert(contentsOf: array, at: hvcC.offset + hvcC.size)
            return data
        }
        throw NotThatFile()
    }
}

/// H.264 whose every picture carries closed captions the ATSC way: an SEI
/// message (ITU-T T.35, provider "GA94") holding two CEA-608 byte pairs.
enum CaptionedH264 {
    /// One caption SEI as an Annex-B NAL unit. No two zero bytes in a row,
    /// so no emulation prevention is needed.
    static let captionSEI: [UInt8] = [0, 0, 0, 1, 0x06, 0x04, 17, 0xB5, 0x00, 0x31] + Array("GA94".utf8)
        + [0x03, 0xC2, 0xFF, 0xFC, 0x94, 0x2C, 0xFC, 0x80, 0x80, 0xFF, 0x80]

    /// `stream` (Annex B) with `captionSEI` before the first slice of every
    /// picture (slice NAL 1 or 5 whose first_mb_in_slice is 0).
    static func withCaptions(_ stream: Data) -> Data {
        let b = [UInt8](stream)
        var out: [UInt8] = []
        out.reserveCapacity(b.count + b.count / 10)
        var copied = 0, i = 0
        while i + 4 < b.count {
            guard b[i] == 0, b[i + 1] == 0, b[i + 2] == 1 else { i += 1; continue }
            let type = b[i + 3] & 0x1F
            if type == 1 || type == 5, b[i + 4] & 0x80 != 0 {
                let start = i > 0 && b[i - 1] == 0 ? i - 1 : i
                out += b[copied..<start]
                out += captionSEI
                copied = start
            }
            i += 3
        }
        out += b[copied...]
        return Data(out)
    }

    /// A 2-second left-only original: captioned H.264 + 16-bit PCM, in
    /// `ext` ("mov", or "mp4" — whose PCM is ISO `ipcm`).
    static func original(_ name: String, ext: String, in dir: URL) throws -> String {
        let plain = dir.appendingPathComponent("plain.h264").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=duration=2:size=320x240:rate=25", "-c:v", "libx264", "-preset", "ultrafast",
             "-pix_fmt", "yuv420p", "-bsf:v", "h264_mp4toannexb", "-f", "h264"], output: plain)
        let captioned = dir.appendingPathComponent("captioned.h264")
        try withCaptions(try Data(contentsOf: URL(fileURLWithPath: plain))).write(to: captioned)
        let out = dir.appendingPathComponent("\(name).\(ext)").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-r", "25", "-i", captioned.path, "-f", "lavfi", "-i", "aevalsrc=\(BalancedCopyProofMedia.leftOnly):s=48000:d=2",
             "-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "pcm_s16le"], output: out)
        return out
    }
}

@Suite("Balanced copy proof — GH #483: hidden picture behind a repeating edit list; closed captions inside the picture", .serialized)
struct BalancedCopyProofCodex310Tests {

    typealias Proof = BalancedCopyProof
    typealias Media = BalancedCopyProofMedia
    typealias Lab = BalancedCopyProofLab
    private let fm = FileManager.default

    private static let longGOP = ["-c:v", "libx264", "-preset", "veryfast", "-bf", "2", "-g", "250", "-pix_fmt", "yuv420p"]

    /// How many SEI-borne caption frames FFmpeg's decoder exports, by another road (ffprobe -show_frames).
    private func captionedFrames(of path: String) async -> Int {
        await Lab.output(ToolLocator.ffprobePath,
                         ["-v", "error", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=pts:frame_side_data",
                          "-of", "compact", path])
            .split(separator: "\n").filter { $0.contains("Closed Captions") }.count
    }

    // MARK: Item 1 — a repeating edit list

    /// The pictures of item 1: all-intra ProRes (the job's copy plays the same), H.264 with a keyframe
    /// at the repeat, and long-GOP H.264 with B-frames (for both of which ffmpeg's copy does NOT play
    /// the same — the proof must then simply never say "the same").
    private static func pictureArgs(_ video: String) -> [String] {
        switch video {
        case "prores": return ["-c:v", "prores_ks", "-profile:v", "0"]
        case "h264": return ["-c:v", "libx264", "-preset", "veryfast", "-bf", "0", "-g", "25", "-pix_fmt", "yuv420p"]
        default: return longGOP
        }
    }

    @Test("ITEM 1 (media): a QuickTime original whose edit list plays its first second twice — stored length = played length — names the hidden picture for the ORIGINAL whenever the pair plays the same",
          .timeLimit(.minutes(3)), arguments: ["prores", "h264", "longGOP"])
    func repeatingEditListNamesHiddenPicture(_ video: String) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("repeat_\(video)")
        defer { try? fm.removeItem(at: dir) }
        let whole = try Lab.make("whole.mov", in: dir, video: Self.pictureArgs(video))
        let original = dir.appendingPathComponent("test_repeats.mov").path
        try QuickTimePatch.repeatingFirstHalf(of: try Data(contentsOf: URL(fileURLWithPath: whole)))
            .write(to: URL(fileURLWithPath: original))

        // By another road: 50 frames stored, 50 played, the same two seconds both ways — no length tells.
        #expect(await Lab.playedFrames(of: original) == "50")
        #expect(await Lab.entry("duration", of: original, stream: "v:0") == "2.000000")
        let stored = await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-ignore_editlist", "1", "-select_streams", "v:0",
                                                                "-show_entries", "stream=nb_frames,duration", "-of", "csv=p=0", original])
        #expect(stored == "2.000000,50")
        // … but the packets a player is given go back to the start of the file half way (long-GOP:
        // ffmpeg also lists each edit's hidden tail, flagged discard, so there are more than 50).
        let positions = await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                                   "packet=pos", "-of", "csv=p=0", original])
            .split(separator: "\n").compactMap { Int($0) }
        #expect(positions.count >= 50 && zip(positions, positions.dropFirst()).contains { $1 <= $0 })

        let balanced = try await Media.balance(original)
        let outcome = await Proof.measure(original: original, balanced: balanced)
        guard outcome.playsTheSame else {
            #expect(video != "prores", "the job's all-intra copy of what plays should play the same: \(outcome)")
            return
        }
        let hidden = outcome.differences.filter { $0.what.contains("hidden picture") }
        #expect(hidden.map(\.heldBy) == [.original], "the second second is stored only in the original and never compared: \(outcome.differences)")
        #expect(hidden.first?.what.hasPrefix("hidden picture in the edit list (stream 0)") == true, "\(hidden)")
        #expect(hidden.allSatisfy { $0.what.hasSuffix(" — not compared with the other file") })
        #expect(!outcome.isProven)
    }

    // MARK: Item 2 — closed captions inside the picture packets

    @Test("ITEM 2 (media): captioned H.264 whose copy's packets LOST the caption SEI — every decoded frame the same — names the closed captions for the ORIGINAL",
          .timeLimit(.minutes(3)), arguments: ["mp4", "mov"])
    func lostCaptionsAreNamedForTheOriginal(_ ext: String) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("captions_\(ext)")
        defer { try? fm.removeItem(at: dir) }
        let original = try CaptionedH264.original("test_captioned", ext: ext, in: dir)
        #expect(await captionedFrames(of: original) == 50, "every picture of the fixture carries captions")
        let balanced = try await Media.balance(original)
        #expect(await captionedFrames(of: balanced) == 50, "the job stream-copies the picture: the captions survive")
        let stripped = try Media.derive("stripped_balanced", from: balanced,
                                        ["-map", "0", "-c", "copy", "-bsf:v", "filter_units=remove_types=6"])
        // By another road: the same pictures, and no captions left.
        #expect(await captionedFrames(of: stripped) == 0)
        func shown(_ path: String) async -> String {
            await Lab.output(ToolLocator.ffmpegPath, ["-v", "error", "-i", path, "-map", "0:v:0", "-f", "hash", "-hash", "sha256", "-"])
        }
        let pixels = await shown(original)
        let strippedPixels = await shown(stripped)
        #expect(pixels.hasPrefix("SHA256=") && strippedPixels == pixels)

        let outcome = await Proof.measure(original: original, balanced: stripped)
        guard outcome.playsTheSame else {
            Issue.record("the pictures and the sound play the same: \(outcome)")
            return
        }
        let captions = outcome.differences.filter { $0.what.contains("closed captions") }
        #expect(captions.map(\.heldBy) == [.original], "the captions are only in the original's packets: \(outcome.differences)")
        #expect(captions.map(\.kind) == [.captions], "found by the decode pass, so named as captions")
        #expect(Proof.logLine(original: original, balanced: stripped, outcome: outcome)
            .contains("[closed captions] the original holds closed captions (CEA-608/708) inside picture stream 0's packets"))
        #expect(captions.allSatisfy { $0.what.hasSuffix(" — not compared with the other file") })

        // The faithful copy carries the captions inside identical packets: compared byte for byte, nothing to name.
        let faithful = await Proof.measure(original: original, balanced: balanced)
        #expect(faithful.playsTheSame && faithful.evidence?.streams.first?.packetIdentical == true, "\(faithful)")
        #expect(!faithful.differences.contains { $0.what.contains("closed captions") }, "\(faithful.differences)")
        #expect(faithful.evidence?.streams.first?.captioned == true, "the decode pass found the captions")
        #expect(Proof.logLine(original: original, balanced: balanced, outcome: faithful)
            .contains("closed captions inside them compared byte for byte"))
        // A picture with no captions at all, packets stripped of their other SEI: the original's other data is named.
        let plainDir = try Media.scratch("nocaptions_\(ext)")
        defer { try? fm.removeItem(at: plainDir) }
        let plainOriginal = try Lab.make("test_plain.\(ext)", in: plainDir,
                                         video: ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p"])
        let plainCopy = try Media.derive("stripped_balanced", from: try await Media.balance(plainOriginal),
                                         ["-map", "0", "-c", "copy", "-bsf:v", "filter_units=remove_types=6"])
        let plain = await Proof.measure(original: plainOriginal, balanced: plainCopy)
        #expect(plain.differences.filter { $0.heldBy == .original && $0.kind == .encoding }.map(\.what)
                == ["whatever picture stream 0's packets carry besides the picture (FFmpeg found no closed captions in its frames)"
                    + " — not compared with the other file"], "\(plain)")
    }
}

@Suite("Balanced copy proof — Codex #394: a frame outside the edit read in file order; captions in the decoder configuration", .serialized)
struct BalancedCopyProofCodex394Tests {

    typealias Proof = BalancedCopyProof
    typealias Media = BalancedCopyProofMedia
    typealias Lab = BalancedCopyProofLab
    private let fm = FileManager.default

    private func captionedFrames(of path: String) async -> Int {
        await Lab.output(ToolLocator.ffprobePath,
                         ["-v", "error", "-select_streams", "v:0", "-show_frames", "-show_entries", "frame=pts:frame_side_data",
                          "-of", "compact", path])
            .split(separator: "\n").filter { $0.contains("Closed Captions") }.count
    }

    @Test("P1 (media): H.264 whose 13th frame's composition time falls outside a 2 s edit — 50 packets read in rising file order, 49 shown, length unchanged — against a balanced FFV1/MKV copy names the ORIGINAL's hidden picture",
          .timeLimit(.minutes(3)), arguments: ["mov", "mp4"])
    func frameOutsideTheEditIsNamed(_ ext: String) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("hidden13_\(ext)")
        defer { try? fm.removeItem(at: dir) }
        let whole = try Lab.make("whole.\(ext)", in: dir,
                                 video: ["-c:v", "libx264", "-preset", "veryfast", "-bf", "0", "-g", "25", "-pix_fmt", "yuv420p",
                                         "-video_track_timescale", "12800"])
        let original = dir.appendingPathComponent("test_hidden13.\(ext)").path
        try QuickTimePatch.hidingThirteenthFrame(of: try Data(contentsOf: URL(fileURLWithPath: whole)))
            .write(to: URL(fileURLWithPath: original))
        // By another road: 50 stored, 50 packets read in rising file order, 49 shown, still 2 s.
        let counts = await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-select_streams", "v:0", "-count_frames", "-count_packets",
                                                                "-show_entries", "stream=nb_frames,nb_read_frames,nb_read_packets,duration",
                                                                "-of", "csv=p=0", original])
        #expect(counts == "2.000000,50,49,50", "duration, stored, shown, read: \(counts)")
        let positions = await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-select_streams", "v:0", "-show_entries",
                                                                   "packet=pos", "-of", "csv=p=0", original])
            .split(separator: "\n").compactMap { Int($0) }
        #expect(positions.count == 50 && zip(positions, positions.dropFirst()).allSatisfy { $1 > $0 }, "the packets rise")

        let jobCopy = try await Media.balance(original)
        let copy = dir.appendingPathComponent("test_hidden13_balanced_ffv1.mkv").path
        try BalanceAudioTestMedia.runFFmpeg(["-i", original, "-i", jobCopy, "-map", "0:v", "-map", "1:a", "-c:v", "ffv1",
                                             "-c:a", "copy", "-fps_mode", "passthrough"], output: copy)
        let outcome = await Proof.measure(original: original, balanced: copy)
        guard outcome.playsTheSame else {
            Issue.record("the 49 shown frames and the sound play the same: \(outcome)")
            return
        }
        let hidden = outcome.differences.filter { $0.what.contains("hidden picture") }
        #expect(hidden == [Proof.Difference(kind: .playback, heldBy: .original,
                                            what: "hidden picture in the edit list (stream 0): 50 frames stored, 49 shown"
                                                + " — not compared with the other file")], "\(outcome.differences)")
        #expect(!outcome.isProven)
    }

    @Test("P1 (media): HEVC whose caption SEI rides in the hvcC configuration — the copy's configuration lacks it, every packet identical — names the ORIGINAL's captions and never claims them compared",
          .timeLimit(.minutes(3)))
    func captionsInTheConfigurationAreNamed() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("hvcc_captions")
        defer { try? fm.removeItem(at: dir) }
        let plain = try Lab.make("plain.mp4", in: dir,
                                 video: ["-c:v", "libx265", "-preset", "ultrafast", "-x265-params", "log-level=error",
                                         "-tag:v", "hvc1", "-pix_fmt", "yuv420p"])
        let original = dir.appendingPathComponent("test_hvcc_captioned.mp4").path
        try QuickTimePatch.captionInHvcC(of: try Data(contentsOf: URL(fileURLWithPath: plain)))
            .write(to: URL(fileURLWithPath: original))
        let copy = try await Media.balance(plain)
        // By another road: captions in the original only; the same packets; the same pixels.
        #expect(await captionedFrames(of: original) > 0)
        #expect(await captionedFrames(of: copy) == 0)
        #expect(await Lab.packetHash(of: original, stream: "v:0") == (await Lab.packetHash(of: copy, stream: "v:0")))

        let outcome = await Proof.measure(original: original, balanced: copy)
        guard outcome.playsTheSame else {
            Issue.record("the pictures and the sound play the same: \(outcome)")
            return
        }
        #expect(outcome.evidence?.streams.first?.packetIdentical == true, "\(outcome)")
        #expect(outcome.evidence?.streams.first?.captioned == false, "captions not compared")
        let captions = outcome.differences.filter { $0.kind == .captions }
        #expect(captions.map(\.heldBy) == [.original], "\(outcome.differences)")
        #expect(captions.allSatisfy { $0.what.hasSuffix(" — not compared with the other file") })
        let line = Proof.logLine(original: original, balanced: copy, outcome: outcome)
        #expect(!line.contains("compared byte for byte"), "\(line)")
        #expect(line.contains("[closed captions] the original holds closed captions (CEA-608/708) in picture stream 0"))

        // The job's copy of the captioned original: both carry captions. Measured 2026-11-26 (FFmpeg 9.0.2), its mov muxer
        // rewrites hvcC, so the configurations differ and the captions are named for each file, never claimed compared;
        // with the same configuration bytes they would be compared and claimed. Either way: claimed ⇔ nothing named.
        let faithfulCopy = try await Media.balance(original)
        #expect(await captionedFrames(of: faithfulCopy) > 0)
        let faithful = await Proof.measure(original: original, balanced: faithfulCopy)
        func configuration(_ path: String) async -> String {
            await Lab.output(ToolLocator.ffprobePath, ["-v", "error", "-show_data_hash", "sha256", "-select_streams", "v:0",
                                                       "-show_entries", "stream=extradata_hash", "-of", "csv=p=0", path])
        }
        let originalConfiguration = await configuration(original)
        #expect(originalConfiguration.hasPrefix("SHA256:"))
        let sameConfiguration = originalConfiguration == (await configuration(faithfulCopy))
        let named = faithful.differences.filter { $0.kind == .captions }.map(\.heldBy)
        #expect(faithful.playsTheSame && faithful.evidence?.streams.first?.captioned == sameConfiguration, "\(faithful)")
        #expect(named == (sameConfiguration ? [] : [.original, .balancedCopy]), "\(faithful.differences)")
        #expect(Proof.logLine(original: original, balanced: faithfulCopy, outcome: faithful)
            .contains("compared byte for byte") == sameConfiguration)
    }
}

@Suite("Balanced copy proof — GH #483 rules: positions, stored frames, the caption detector, what is named")
struct BalancedCopyProofCodex310RuleTests {

    typealias Proof = BalancedCopyProof
    typealias Table = BalancedCopyProofDecisionTests

    private static let a = "SHA256:" + String(repeating: "a1", count: 32)

    private func fold(_ lines: [String]) -> (fault: String?, found: [Int: Proof.PacketSequence]) {
        var layout = Proof.FileLayout()
        layout.carried = [Proof.CarriedStream(index: 0, kind: "video", codec: "prores", tag: "apco", timeBase: "1/12800")]
        layout.sound = [Table.sound(1)]
        let ledger = Proof.PacketLedger(layout: layout)
        lines.forEach(ledger.note)
        return (ledger.fault, ledger.sequences)
    }

    // MARK: The packet pass reads each packet's file position

    @Test("POSITIONS: a stream whose packets keep moving forward through the file rises; one that goes back, stays, or states no position does not — per stream, and without touching the digests")
    func positionsRise() throws {
        let rising = fold(["0,0,512,100,36,\(Self.a)", "1,0,1024,4096,136,\(Self.a)", "0,512,512,100,4232,\(Self.a)",
                           "1,1024,1024,4096,4332,\(Self.a)"])
        #expect(rising.fault == nil)
        #expect(rising.found[0]?.positionsRise == true && rising.found[1]?.positionsRise == true,
                "interleaved streams are judged each on its own")
        for (name, second) in [("back to the start", "0,512,512,100,36,\(Self.a)"), ("the same place", "0,512,512,100,100,\(Self.a)"),
                               ("earlier", "0,512,512,100,50,\(Self.a)"), ("not stated", "0,512,512,100,N/A,\(Self.a)")] {
            let found = fold(["0,0,512,100,100,\(Self.a)", second])
            #expect(found.fault == nil && found.found[0]?.positionsRise == false, "\(name)")
            #expect(found.found[1]?.positionsRise == true, "\(name): the sound is not the picture")
            // Positions are not folded: the digests are those of the same packets anywhere in the file.
            let elsewhere = fold(["0,0,512,100,9000,\(Self.a)", "0,512,512,100,9999,\(Self.a)"])
            #expect(elsewhere.found[0]?.positionsRise == true)
            #expect(elsewhere.found[0]?.packetSHA256 == found.found[0]?.packetSHA256)
            #expect(elsewhere.found[0]?.timingSHA256 == found.found[0]?.timingSHA256)
        }
        // A sound packet with no position breaks only the sound's rise.
        let soundNA = fold(["0,0,512,100,36,\(Self.a)", "1,N/A,N/A,4096,N/A,\(Self.a)"])
        #expect(soundNA.fault == nil && soundNA.found[0]?.positionsRise == true && soundNA.found[1]?.positionsRise == false)
        // An empty stream claims nothing against itself.
        #expect(fold([]).found[0]?.positionsRise == true)
        // The request asks for the position, between the size and the hash (ffprobe's own order).
        #expect(Proof.packetArgs(input: "/x.mov").contains("packet=stream_index,pts,duration,size,pos,data_hash"))
        // A line in the old five-field shape is unreadable, not misread.
        let old = "0,0,512,100,\(Self.a)"
        #expect(fold([old]).fault == old)
        // Written into a layout: carried and sound alike; a stream the pass never listed stays unknown.
        var layout = Proof.FileLayout()
        layout.carried = [Proof.CarriedStream(index: 0, kind: "video", codec: "prores", tag: "apco"),
                          Proof.CarriedStream(index: 5, kind: "video", codec: "prores", tag: "apco")]
        layout.sound = [Table.sound(1)]
        let filled = Proof.filled(layout, with: fold(["0,0,512,100,100,\(Self.a)", "0,512,512,100,36,\(Self.a)",
                                                      "1,0,1024,4096,200,\(Self.a)"]).found)
        #expect(filled.carried[0].positionsRise == false && filled.sound[0].positionsRise == true)
        #expect(filled.carried[1].positionsRise == nil)
    }

    @Test("STORED FRAMES: the edit-list-ignoring header read gives each track's stored frame count")
    func storedFramesAreRead() throws {
        var layout = Proof.FileLayout(container: Table.movie)
        layout.carried = [Proof.CarriedStream(index: 0, kind: "video", codec: "prores", tag: "apco")]
        layout.sound = [Table.sound(1)]
        let json = #"{"streams":[{"index":0,"duration":"2.000000","nb_frames":"50"},{"index":1,"duration":"2.000000","nb_frames":"96000"}]}"#
        let full = try #require(Proof.withStoredLengths(layout, fromProbeJSON: Data(json.utf8)))
        #expect(full.carried[0].storedFrames == 50 && full.carried[0].storedSeconds == 2)
        let unstated = #"{"streams":[{"index":0,"duration":"2.000000"},{"index":1,"duration":"2.000000","nb_frames":"N/A"}]}"#
        #expect(try #require(Proof.withStoredLengths(layout, fromProbeJSON: Data(unstated.utf8))).carried[0].storedFrames == nil)
        #expect(Proof.storedArgs(input: "/x.mov").contains("stream=index,duration,nb_frames"))
    }

    // MARK: What is named

    private static let repeatWords = "it plays stored picture more than once or out of order, so picture it stores and never plays cannot be ruled out"

    @Test("ITEM 1 (logic): a QuickTime picture whose packets go back through the file — or whose index stores more frames than were handed to the decoder — is named HIDDEN for the file that holds it; equal lengths prove nothing")
    func hiddenBehindTheEditListIsNamed() {
        let original = Proof.decide(Table.facts { $0.original.carried[0].positionsRise = false })
        #expect(original.differences == [Proof.Difference(
            kind: .playback, heldBy: .original,
            what: "hidden picture in the edit list (stream 0): \(Self.repeatWords) — not compared with the other file")], "\(original)")
        #expect(original.playsTheSame && !original.isProven)
        #expect(Proof.logLine(original: "/o.mov", balanced: "/b.mov", outcome: original)
            .contains("[playback instructions] the original holds hidden picture in the edit list (stream 0)"))
        // The copy's own: named for the copy.
        #expect(Proof.decide(Table.facts { $0.balanced.carried[0].positionsRise = false }).differences.map(\.heldBy) == [.balancedCopy])
        // The sound, the same way.
        #expect(Table.differs(Proof.decide(Table.facts { $0.original.sound[0].positionsRise = false })) == [
            "[playback instructions] the original holds hidden sound in the edit list (stream 1): it plays stored sound more than once "
            + "or out of order, so sound it stores and never plays cannot be ruled out — not compared with the other file"])
        // Frames stored and never handed to the decoder (an empty edit, a cut that keeps the length).
        #expect(Table.differs(Proof.decide(Table.facts { $0.original.carried[0].storedFrames = 60 })) == [
            "[playback instructions] the original holds hidden picture in the edit list (stream 0): 60 frames stored, "
            + "50 shown — not compared with the other file"])
        // Frames read in rising file order and decoded but NOT shown (a composition time outside the edit, Codex #394):
        // stored or read beyond what was shown is named; the decode pass's count is what was shown.
        let shown49: (inout Proof.Facts) -> Void = { $0.originalRead?.pictures[0]?.frames = 49; $0.balancedRead?.pictures[0]?.frames = 49 }
        // `poisoned`: the decode passes' own counts stay as set (`facts` would re-derive them whole).
        let byStored = Proof.decide(Table.poisoned { shown49(&$0); $0.original.carried[0].storedFrames = 50 })
        #expect(byStored.differences.filter { $0.heldBy == .original } == [Proof.Difference(
            kind: .playback, heldBy: .original,
            what: "hidden picture in the edit list (stream 0): 50 frames stored, 49 shown — not compared with the other file")],
                "\(byStored)")
        #expect(byStored.playsTheSame && !byStored.isProven)
        let byRead = Proof.decide(Table.poisoned(shown49))
        #expect(byRead.differences.filter { $0.heldBy == .original }.map(\.what)
                == ["hidden picture in the edit list (stream 0): 50 packets read, 49 frames shown — not compared with the other file"],
                "\(byRead)")
        #expect(byRead.differences.filter { $0.heldBy == .balancedCopy }.map(\.what).first?
            .hasPrefix("hidden picture in the edit list (stream 0): 50 packets read, 49 frames shown") == true, "the copy's own")
        // Not a QuickTime file: frames dropped are not an edit list's (the copy here is Matroska).
        let mkvCopy = Proof.decide(Table.poisoned { shown49(&$0); $0.balanced.container = "matroska,webm"; $0.balanced.sound[0].channelLayout = "" })
        #expect(!mkvCopy.differences.contains { $0.heldBy == .balancedCopy && $0.what.contains("hidden") }, "\(mkvCopy)")
        // Every stored frame handed over, or more (long-GOP lists each edit's tail): nothing to name.
        #expect(Proof.decide(Table.facts { $0.original.carried[0].storedFrames = 50 }).isProven)
        #expect(Proof.decide(Table.facts { $0.original.carried[0].storedFrames = 40 }).isProven)
        // Not read (hand-built, or a pass that never ran): no claim either way.
        #expect(Proof.decide(Table.facts { $0.original.carried[0].positionsRise = nil }).isProven)
        // A container with no edit lists: a position that goes back is not an edit list's (Matroska, AVI, raw DV).
        #expect(Proof.decide(Table.facts {
            $0.original.container = "matroska,webm"
            $0.balanced.container = "matroska,webm"
            $0.original.sound[0].channelLayout = ""
            $0.balanced.sound[0].channelLayout = ""
            $0.original.carried[0].positionsRise = false
        }).isProven)
        // Already named as stored-and-not-played: one difference, not two.
        let both = Proof.decide(Table.facts {
            $0.original.carried[0].storedSeconds = 4
            $0.original.carried[0].positionsRise = false
            $0.original.carried[0].storedFrames = 100
        })
        #expect(both.differences.count == 1 && both.differences[0].what.hasPrefix("stored picture (stream 0)"), "\(both)")
    }

    private static func captioned(original: Set<Int>?, copy: Set<Int>?, packetsDiffer: Bool) -> Proof.Facts {
        var f = Table.facts { if packetsDiffer { $0.balanced.carried[0].packetSHA256 = Table.otherHash } }
        f.originalRead?.captioned = original
        f.balancedRead?.captioned = copy
        return f
    }

    @Test("ITEM 2 (logic): picture packets that are NOT identical name what the original's packets carry besides the picture — as closed captions when the decode found them; identical packets compared them byte for byte")
    func inPacketDataIsNamed() throws {
        let generic = "[encoding] the original holds whatever picture stream 0's packets carry besides the picture "
        let differs = "[encoding] picture stream 0 (prores) is not stored in the same packets (50 in the original, 50 in the balanced copy); every decoded frame is the same"
        #expect(Table.differs(Proof.decide(Self.captioned(original: nil, copy: nil, packetsDiffer: true)))
                == [differs, generic + "(closed captions were not looked for) — not compared with the other file"])
        #expect(Table.differs(Proof.decide(Self.captioned(original: [], copy: [], packetsDiffer: true)))
                == [differs, generic + "(FFmpeg found no closed captions in its frames) — not compared with the other file"])
        let lost = Proof.decide(Self.captioned(original: [0], copy: [], packetsDiffer: true))
        #expect(lost.differences.first == Proof.Difference(
            kind: .captions, heldBy: .original,
            what: "closed captions (CEA-608/708) inside picture stream 0's packets, and whatever else those packets carry besides the "
                + "picture — not compared with the other file"), "\(lost)")
        #expect(lost.differences.map(\.kind) == [.captions, .encoding] && lost.playsTheSame && !lost.isProven)
        #expect(Proof.Difference.Kind.captions.rawValue == "closed captions")
        // Both carry captions in packets that differ: each file holds its own.
        let both = Proof.decide(Self.captioned(original: [0], copy: [0], packetsDiffer: true))
        #expect(both.differences.filter { $0.kind == .captions }.map(\.heldBy) == [.original, .balancedCopy], "\(both)")
        // Captions inside IDENTICAL packets: compared byte for byte — proven, and the evidence says so.
        let compared = Proof.decide(Self.captioned(original: [0], copy: [0], packetsDiffer: false))
        guard case .proven(let evidence) = compared else { Issue.record("\(compared)"); return }
        #expect(evidence.streams.first?.captioned == true && evidence.streams.first?.packetIdentical == true)
        #expect(Proof.logLine(original: "/o.mov", balanced: "/b.mov", outcome: compared)
            .contains("stored packets identical, sha256 \(Table.pictureHash) (50), closed captions inside them compared byte for byte"))
        // Identical packets but the captions not compared (Codex #394): they can ride in the decoder configuration.
        let suffix = " — not compared with the other file"
        let lostInConfig = Proof.decide(Self.captioned(original: [0], copy: [], packetsDiffer: false))
        #expect(lostInConfig.differences == [Proof.Difference(
            kind: .captions, heldBy: .original,
            what: "closed captions (CEA-608/708) in picture stream 0; the balanced copy's frames carry none though the picture "
                + "packets are identical" + suffix)], "\(lostInConfig)")
        #expect(lostInConfig.evidence?.streams.first?.captioned == false)
        #expect(!Proof.logLine(original: "/o", balanced: "/b", outcome: lostInConfig).contains("byte for byte"))
        var configDiffers = Self.captioned(original: [0], copy: [], packetsDiffer: false)
        configDiffers.balanced.carried[0].configuration.extradataSHA256 = "other"
        #expect(Proof.decide(configDiffers).differences.first?.what == "closed captions (CEA-608/708) in picture stream 0; the "
                + "balanced copy's frames carry none though the picture packets are identical (captions can ride in the decoder "
                + "configuration, written differently)" + suffix)
        var bothConfigDiffers = Self.captioned(original: [0], copy: [0], packetsDiffer: false)
        bothConfigDiffers.balanced.carried[0].configuration.extradataSHA256 = "other"
        let bothDiffer = Proof.decide(bothConfigDiffers)
        #expect(bothDiffer.differences.filter { $0.kind == .captions }.map(\.heldBy) == [.original, .balancedCopy], "\(bothDiffer)")
        #expect(bothDiffer.differences.contains { $0.kind == .decoderConfiguration })
        #expect(!Proof.logLine(original: "/o", balanced: "/b", outcome: bothDiffer).contains("byte for byte"))
        let copyNotLooked = Proof.decide(Self.captioned(original: [0], copy: nil, packetsDiffer: false))
        #expect(copyNotLooked.differences.map(\.what) == ["closed captions (CEA-608/708) in picture stream 0; the balanced "
                                                          + "copy's frames were not looked at for captions" + suffix])
        let onlyCopy = Proof.decide(Self.captioned(original: [], copy: [0], packetsDiffer: false))
        #expect(onlyCopy.differences.map(\.heldBy) == [.balancedCopy] && !onlyCopy.isProven, "\(onlyCopy)")
        // No captions, identical packets: nothing said about captions.
        let plain = Proof.decide(Self.captioned(original: [], copy: [], packetsDiffer: false))
        #expect(plain.isProven && !Proof.logLine(original: "/o", balanced: "/b", outcome: plain).contains("captions"))
    }

    @Test("ISOLATION: a hidden picture or lost captions never leaves a pair PROVEN, and with any refusal on top the refusal wins")
    func neverProvenWithHiddenOrLostData() {
        let named: [(String, (inout Proof.Facts) -> Void)] = [
            ("repeat", { $0.original.carried[0].positionsRise = false }),
            ("stored frames", { $0.original.carried[0].storedFrames = 51 }),
            ("captions lost", { $0.balanced.carried[0].packetSHA256 = Table.otherHash; $0.originalRead?.captioned = [0] }),
            ("frame not shown", { $0.originalRead?.pictures[0]?.frames = 49; $0.balancedRead?.pictures[0]?.frames = 49 }),
            ("captions in the configuration", { $0.originalRead?.captioned = [0]; $0.balancedRead?.captioned = [] })
        ]
        for (name, change) in named {
            var f = Table.facts { _ in }
            change(&f)
            let outcome = Proof.decide(f)
            #expect(outcome.playsTheSame && !outcome.isProven && outcome.differences.contains { $0.heldBy == .original }, "\(name): \(outcome)")
            for (poisonName, poison) in Table.poisons {
                var g = f
                poison(&g)
                #expect(!Proof.decide(g).playsTheSame, "\(name) + \(poisonName)")
            }
        }
    }

    // MARK: The caption detector

    @Test("DETECTOR: each picture of a decode pass feeds an A53 caption branch that ends in nullsink — no output stream is added")
    func detectorInTheGraph() {
        let plan = Proof.DecodePlan(pictures: [.init(index: 0, pixelFormat: "yuv420p"), .init(index: 3, pixelFormat: "pal8")],
                                    soundIndex: 1, sampleFormat: "s16", sampleRateHz: 48_000, channels: [0], runTag: "vstag")
        let graph = Proof.decodeFilter(plan)
        #expect(graph.contains("[0:0]format=pix_fmts=yuv420p,split=2[p0][k0]"))
        #expect(graph.contains("[k0]sidedata=mode=select:type=A53_CC,trim=end_frame=1,showinfo@vstagc0,nullsink"))
        #expect(graph.contains("[k3]sidedata=mode=select:type=A53_CC,trim=end_frame=1,showinfo@vstagc3,nullsink"))
        #expect(plan.roles == [.picture(input: 0), .picture(input: 3), .timeline, .channel(0)], "the outputs are unchanged")
        let args = Proof.decodeArgs(input: "/x.mov", inputArgs: [], plan: plan, hashCodec: "pcm_s16le")
        #expect(args.filter { $0 == "-map" }.count == 4)
    }

    private static func log(_ lines: [String]) -> String {
        (lines + ["[in#0/mov @ 0x1] [verbose]   Input stream #0:0 (video): 50 packets read (1 bytes); 50 frames decoded; 0 decode errors;",
                  "[AVIOContext @ 0x2] [verbose] Statistics: 1 bytes read, 0 seeks", "[verbose] Exiting with exit code 0"])
            .joined(separator: "\n")
    }
    private static let frameLine = "[showinfo@vstagc0 @ 0x78f5026040] [info] n:   0 pts:      0 pts_time:0       duration:    512"

    @Test("DETECTOR (log): a frame logged by THIS run's detector marks its picture captioned; config lines, another run's tag, or no tag do not")
    func detectorLogIsRead() throws {
        func captioned(_ lines: [String], tag: String = "vstag") -> Set<Int>?? {
            guard case .success(let report) = Proof.readReport(fromStderr: Self.log(lines), runTag: tag) else { return .none }
            return .some(report.captioned)
        }
        let config = ["[showinfo@vstagc0 @ 0x78f5026040] [info] config in time_base: 1/12800, frame_rate: 25/1",
                      "[showinfo@vstagc0 @ 0x78f5026040] [info] config out time_base: 0/0, frame_rate: 0/0"]
        #expect(captioned(config + [Self.frameLine,
                                    "[showinfo@vstagc0 @ 0x78f5026040] [info]   side data - ATSC A53 Part 4 Closed Captions: (6 bytes)"])
                == .some([0]))
        #expect(captioned(config) == .some([]), "looked for, none found")
        #expect(captioned([Self.frameLine.replacingOccurrences(of: "vstag", with: "vsother")]) == .some([]),
                "another run's detector proves nothing")
        #expect(captioned([Self.frameLine], tag: "") == .some(nil), "no run tag: captions were not looked for")
        #expect(captioned(["[showinfo@vstagcx @ 0x1] [info] n:   0"]) == .none, "a detector line that names no stream refuses the log")
        #expect(captioned([Self.frameLine.replacingOccurrences(of: "[info]", with: "[error]")]) == .none, "loud is loud")
    }

    @Test("SCALE: 100,000 decisions with a hidden picture and lost captions named inside 10 s", .timeLimit(.minutes(1)))
    func decisionsAtScale() {
        var f = Table.facts { $0.balanced.carried[0].packetSHA256 = Table.otherHash; $0.original.carried[0].positionsRise = false }
        f.originalRead?.captioned = [0]
        var named = 0
        let elapsed = ContinuousClock().measure {
            for _ in 0..<100_000 { named += Proof.decide(f).differences.count }
        }
        #expect(named == 300_000)
        #expect(elapsed < .seconds(10), "\(elapsed)")
    }
}
