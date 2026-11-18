// BalancedCopyProofCorpusFindingsTests.swift
// What the proof's first runs over REAL tapes found (M4 corpus, 2026-11-18,
// 8 one-sided files; counts and codec words only ever left that machine),
// reproduced here on generated media and pinned.
//
// FINDING 1 — "the original was not read to the end" on three raw DV tapes
// (19 min, 60 min, 60 min). Evidence: every packet listed was read, zero
// decode errors, every frame folded; the picture decoded to exactly
// frames × 1001/30000 s and the header "stated" 17 µs and 33 µs less.
// Raw DV has no header: ffprobe ESTIMATES the length from the bit rate, in
// ticks of 1/60000 s, and the estimate falls one tick short by ~19 minutes
// and two by an hour. The engine held the decode to that estimate with one
// tick of slack. An estimate is not a statement: a raw DV picture's length is
// now UNSTATED (as its sound's already was), kept only to budget the decode's
// time. Whole-read for raw DV rests on what it always rested on besides:
// packets read == packets listed, no decode error, every frame folded, a
// clean exit — and the copy's QuickTime header, which does state a length.
//
// FINDING 2 — "picture configuration differs" on DV inside QuickTime with
// big-endian PCM. Evidence: ONE display field differs — colour range,
// "tv" in the original, unstated in the copy. An Avid `ACLR` atom states the
// range; FFmpeg's QuickTime muxer has nowhere to write a range for DV on a
// stream copy (measured: `-color_range` on the output is not written). A YUV
// picture whose range is unstated is displayed limited-range by FFmpeg — the
// same pixels the same way. So: stated `tv` against unstated (either way
// round, YUV formats only) is a NAMED difference held by the file that
// states it; `pc` against anything else is still refused.

import Foundation
import Testing
@testable import VideoScan

/// Byte-level edits to a small QuickTime file ffmpeg wrote (32-bit atom
/// sizes, `moov` after `mdat`, so no chunk offset moves).
enum QuickTimePatch {
    struct Atom {
        var type: String
        var offset: Int
        var size: Int
    }
    struct NotThatFile: Error {}

    static func uint32(_ data: Data, at offset: Int) -> Int {
        data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
    }
    static func bytes(_ value: Int) -> [UInt8] { [24, 16, 8, 0].map { UInt8((value >> $0) & 0xFF) } }

    static func atoms(_ data: Data, from start: Int, to end: Int) -> [Atom] {
        var out: [Atom] = []
        var at = start
        while at + 8 <= end {
            let size = uint32(data, at: at)
            guard size >= 8, at + size <= end else { break }
            out.append(Atom(type: String(bytes: data[at + 4..<at + 8], encoding: .isoLatin1) ?? "", offset: at, size: size))
            at += size
        }
        return out
    }
    static func child(_ type: String, of parent: Atom, in data: Data, skipping header: Int = 8) throws -> Atom {
        guard let found = atoms(data, from: parent.offset + header, to: parent.offset + parent.size).first(where: { $0.type == type })
        else { throw NotThatFile() }
        return found
    }

    /// `movie` with an Avid colour-range atom (`ACLR`; 1 = video range,
    /// 2 = full range) appended to its picture's sample description — what
    /// an Avid QuickTime export carries.
    static func addingAvidColourRange(_ range: UInt8, to movie: Data) throws -> Data {
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
            let entry = stsd.offset + 16
            let entrySize = uint32(data, at: entry)
            for offset in [moov.offset, trak.offset, mdia.offset, minf.offset, stbl.offset, stsd.offset, entry] {
                data.replaceSubrange(offset..<offset + 4, with: bytes(uint32(data, at: offset) + 24))
            }
            let atom = bytes(24) + Array("ACLRACLR0001".utf8) + [0, 0, 0, range] + [0, 0, 0, 0]
            data.insert(contentsOf: atom, at: entry + entrySize)
            return data
        }
        throw NotThatFile()
    }
}

@Suite("Balanced copy proof — what real tapes found (corpus 2026-11-18)", .serialized)
struct BalancedCopyProofCorpusFindingsTests {

    typealias Proof = BalancedCopyProof
    typealias Table = BalancedCopyProofDecisionTests
    typealias Media = BalancedCopyProofMedia
    private let fm = FileManager.default

    private func layout(of path: String) async throws -> Proof.FileLayout {
        let run = await ProcessRunner.runProcess(executable: ToolLocator.ffprobePath, arguments: Proof.layoutArgs(input: path),
                                                 stdoutLimitBytes: 1 << 20, deadlineSeconds: 60)
        try #require(run.exitCode == 0)
        return try #require(Proof.layout(fromProbeJSON: Data((run.stdout ?? "").utf8)))
    }

    // MARK: Finding 1 — a raw DV picture's length is an estimate

    @Test("FINDING 1 (parse): raw DV states no length for its picture or its sound — ffprobe's figure is kept as an ESTIMATE, for the time budget only; every other container's stated length stands")
    func rawDVLengthsAreEstimates() throws {
        // The numbers of a real one-hour tape: 108,015 frames = 3604.100500 s; ffprobe says 3604.100467.
        let dv = try #require(Proof.layout(fromProbeJSON: Data("""
        {"streams":[
          {"index":0,"codec_type":"video","codec_name":"dvvideo","time_base":"1/60000","duration":"3604.100467",
           "width":720,"height":480,"pix_fmt":"yuv411p"},
          {"index":1,"codec_type":"audio","codec_name":"pcm_s16le","sample_fmt":"s16","sample_rate":"48000","channels":2,
           "time_base":"1/14112000","duration":"3604.100467"}],
         "format":{"format_name":"dv"}}
        """.utf8)))
        #expect(dv.carried[0].statedSeconds == nil, "an estimate from the bit rate is not a stated length")
        #expect(dv.sound[0].statedSeconds == nil)
        #expect(dv.estimatedSeconds == 3604.100467)
        // The decode that was refused: every packet read, 108,015 frames, two ticks longer than the estimate.
        var read = Proof.ReadReport()
        read.streams = [0: Proof.StreamRead(packets: 108_015, decodeErrors: 0), 1: Proof.StreamRead(packets: 108_015, decodeErrors: 0)]
        (read.muxed, read.folded) = ([0: 108_015, 1: 108_015, 2: 3605], [0: 108_015, 1: 108_015, 2: 3605])
        read.pictures[0] = Proof.PictureRead(frames: 108_015, sha256: Table.framesHash, firstSeconds: 0, endSeconds: 3604.1005)
        read.soundSegments = [Proof.SoundSegment(start: 0, samples: 173_001_095)]
        var counted = dv
        counted.carried[0].packets = 108_015
        counted.sound[0].packets = 108_015
        #expect(Proof.readShortfall(counted, read: read, kept: counted.sound[0]) == nil)
        // What still refuses a raw DV read: a packet short, a decode error, a frame lost on the way.
        var short = read
        short.streams[0]?.packets = 108_014
        #expect(Proof.readShortfall(counted, read: short, kept: counted.sound[0]) == .packetCount(stream: 0, read: 108_014, listed: 108_015))
        var lost = read
        lost.folded[0] = 108_014
        #expect(Proof.readShortfall(counted, read: lost, kept: counted.sound[0]) != nil)
        // The time budget still knows how long the tape is: twice its length, not the 300 s floor.
        #expect(Proof.decodeDeadlineSeconds(bytes: 12_961_800_000, layout: dv) == 2 * 3604.100467)

        // QuickTime states its lengths; nothing changes there.
        let mov = try #require(Proof.layout(fromProbeJSON: Data("""
        {"streams":[{"index":0,"codec_type":"video","codec_name":"dvvideo","time_base":"1/30000","duration":"3604.100500",
                     "width":720,"height":480,"pix_fmt":"yuv411p"}],
         "format":{"format_name":"mov,mp4,m4a,3gp,3g2,mj2"}}
        """.utf8)))
        #expect(mov.carried[0].statedSeconds == 3604.1005 && mov.estimatedSeconds == nil)
        var movRead = Proof.ReadReport()
        movRead.streams = [0: Proof.StreamRead(packets: 108_015, decodeErrors: 0)]
        (movRead.muxed, movRead.folded) = ([0: 108_015], [0: 108_015])
        movRead.pictures[0] = Proof.PictureRead(frames: 108_014, sha256: Table.framesHash, firstSeconds: 0, endSeconds: 3604.067133)
        var movCounted = mov
        movCounted.carried[0].packets = 108_015
        #expect(Proof.readShortfall(movCounted, read: movRead, kept: nil)
                == .pictureLength(stream: 0, decodedSeconds: 3604.067133, statedSeconds: 3604.1005))
    }

    @Test("FINDING 1 (truth): ffprobe's length for a raw DV file IS an estimate — exact for a 3-minute tape, a tick short at 19 minutes, two at an hour (header reads of sparse files; nothing is decoded)",
          .timeLimit(.minutes(2)),
          arguments: [(5855, 0), (34_458, 1), (108_015, 2)])
    func ffprobeEstimatesRawDVLength(_ frames: Int, _ ticksShort: Int) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("dv_estimate_\(frames)")
        defer { try? fm.removeItem(at: dir) }
        // Two real seconds of raw DV, then a hole out to `frames` frames: the file's SIZE is all the estimate reads.
        let seed = try Media.original(in: dir, .rawDV)
        let head = try Data(contentsOf: URL(fileURLWithPath: seed))
        let sparse = dir.appendingPathComponent("test_sparse_\(frames).dv")
        try head.write(to: sparse)
        let handle = try FileHandle(forWritingTo: sparse)
        try handle.truncate(atOffset: UInt64(frames) * 120_000)
        try handle.close()

        let run = await ProcessRunner.runProcess(
            executable: ToolLocator.ffprobePath,
            arguments: ["-v", "error", "-select_streams", "v:0", "-show_entries", "stream=duration,time_base", "-of", "csv=p=0", sparse.path],
            deadlineSeconds: 60)
        let fields = (run.stdout ?? "").split(whereSeparator: { $0 == "," || $0.isNewline }).map(String.init)
        try #require(run.exitCode == 0 && fields.count >= 2, "\(run.stdout ?? "") \(run.stderr)")
        #expect(fields[0] == "1/60000")
        let estimated = try #require(Double(fields[1]))
        let exact = Double(frames) * 1001 / 30_000
        let short = ((exact - estimated) * 60_000).rounded()
        #expect(Int(short) == ticksShort, "\(frames) frames: ffprobe says \(estimated), the frames make \(exact)")

        // And the engine does not take it for a statement.
        let layout = try await layout(of: sparse.path)
        #expect(layout.containerWords == ["dv"] && layout.carried.first?.statedSeconds == nil)
        // (The longest of its streams' figures: the sound's is the same estimate in a finer time base.)
        let kept = try #require(layout.estimatedSeconds)
        #expect(kept >= estimated && kept - estimated < 0.0001, "\(kept) against \(estimated)")
    }

    // MARK: Finding 2 — a colour range stated on one side only

    private func facts(pixelFormat: String = "yuv411p", original: String, copy: String) -> Proof.Facts {
        Table.facts {
            $0.original.carried[0].configuration.pixelFormat = pixelFormat
            $0.balanced.carried[0].configuration.pixelFormat = pixelFormat
            $0.original.carried[0].configuration.colorRange = original
            $0.balanced.carried[0].configuration.colorRange = copy
        }
    }

    @Test("FINDING 2 (decision table): a YUV picture's colour range stated `tv` in one file and unstated in the other is displayed the same — SAME CONTENT, named for the file that states it; full range against anything else is still NOT THE SAME")
    func colourRangeStatedOnOneSide() {
        // The corpus pair: the original states tv, the copy nothing.
        let lost = Proof.decide(facts(original: "tv", copy: ""))
        #expect(lost.differences == [Proof.Difference(
            kind: .playback, heldBy: .original,
            what: "a colour range tag on picture stream 0 (tv, limited range); the balanced copy states none, "
                + "which FFmpeg displays in the same range")], "\(lost)")
        #expect(lost.playsTheSame && !lost.isProven, "a named difference is never PROVEN")
        // The other way round: the copy states it.
        let gained = Proof.decide(facts(original: "", copy: "tv"))
        #expect(gained.differences == [Proof.Difference(
            kind: .playback, heldBy: .balancedCopy,
            what: "a colour range tag on picture stream 0 (tv, limited range); the original states none, "
                + "which FFmpeg displays in the same range")], "\(gained)")
        // Both state it, or neither: nothing to name.
        #expect(Proof.decide(facts(original: "tv", copy: "tv")).isProven)
        #expect(Proof.decide(facts(original: "", copy: "")).isProven)

        // FULL range against limited or unstated changes what is shown: refused, in every direction.
        for (original, copy) in [("pc", ""), ("", "pc"), ("pc", "tv"), ("tv", "pc")] {
            let outcome = Proof.decide(facts(original: original, copy: copy))
            #expect(outcome == .notProven(.pictureConfigurationDiffers(
                "picture stream 0: colour range \(original.isEmpty ? "none" : original) → \(copy.isEmpty ? "none" : copy)")),
                    "\(original) → \(copy): \(outcome)")
        }
        // Only where FFmpeg's default for an unstated range IS limited: not full-range YUV, not RGB, not grey.
        for format in ["yuvj420p", "rgb24", "gray", "gbrp10le", "pal8"] {
            let outcome = Proof.decide(facts(pixelFormat: format, original: "tv", copy: ""))
            #expect(outcome == .notProven(.pictureConfigurationDiffers("picture stream 0: colour range tv → none")), "\(format): \(outcome)")
        }
        // A word that is not a range is not unstated.
        #expect(!Proof.decide(facts(original: "tv", copy: "unknown")).playsTheSame)
        // The tag never hides another display difference.
        let alsoWidth = Proof.decide(Table.facts {
            $0.original.carried[0].configuration.pixelFormat = "yuv411p"
            $0.balanced.carried[0].configuration.pixelFormat = "yuv411p"
            $0.balanced.carried[0].configuration.colorRange = ""
            $0.balanced.carried[0].configuration.colorSpace = "bt709"
        })
        #expect(alsoWidth == .notProven(.pictureConfigurationDiffers("picture stream 0: colour space none → bt709")))
        // The evidence list is still every field the two headers state differently, this one included.
        var copy = Table.picture()
        copy.colorRange = ""
        #expect(Table.picture().displayDifferences(from: copy).map(\.name) == ["colour range"])
    }

    @Test("FINDING 2 (media): DV in QuickTime with an Avid colour-range atom, balanced by the job's own render — `tv` is the SAME CONTENT with the tag named for the original; a FULL-range atom is NOT THE SAME",
          .timeLimit(.minutes(3)),
          arguments: [UInt8(1), UInt8(2)])
    func avidColourRangeAtom(_ range: UInt8) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("aclr_\(range)")
        defer { try? fm.removeItem(at: dir) }
        // DV picture + big-endian 16-bit PCM in QuickTime (the corpus pair's shape), then the atom.
        let plain = dir.appendingPathComponent("plain.mov").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc=duration=2:size=720x480:rate=30000/1001", "-f", "lavfi",
             "-i", "aevalsrc=\(Media.leftOnly):s=48000:d=2", "-map", "0:v:0", "-map", "1:a:0",
             "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16be"], output: plain)
        let original = dir.appendingPathComponent("test_proof_aclr.mov").path
        try QuickTimePatch.addingAvidColourRange(range, to: Data(contentsOf: URL(fileURLWithPath: plain)))
            .write(to: URL(fileURLWithPath: original))
        try fm.removeItem(atPath: plain)
        let stated = range == 1 ? "tv" : "pc"
        #expect(try await layout(of: original).carried.first?.configuration.colorRange == stated, "the fixture must state \(stated)")

        let balanced = try await Media.balance(original)
        #expect(try await layout(of: balanced).carried.first?.configuration.colorRange.isEmpty == true,
                "FFmpeg's QuickTime muxer writes no colour range for DV: if this fails, the job can carry it and should")

        let outcome = await Proof.measure(original: original, balanced: balanced)
        if range == 1 {
            guard case .sameContent(let evidence, let differs) = outcome else {
                Issue.record("expected the same content with the tag named, got \(outcome)")
                return
            }
            #expect(differs.contains(Proof.Difference(
                kind: .playback, heldBy: .original,
                what: "a colour range tag on picture stream 0 (tv, limited range); the balanced copy states none, "
                    + "which FFmpeg displays in the same range")), "\(differs)")
            #expect(evidence.streams.first?.packetIdentical == true && (evidence.streams.first?.frames ?? 0) >= 59)
            #expect(Proof.logLine(original: original, balanced: balanced, outcome: outcome)
                .contains("[playback instructions] the original holds a colour range tag on picture stream 0 (tv, limited range)"))
        } else {
            #expect(outcome == .notProven(.pictureConfigurationDiffers("picture stream 0: colour range pc → none")), "\(outcome)")
        }
    }
}
