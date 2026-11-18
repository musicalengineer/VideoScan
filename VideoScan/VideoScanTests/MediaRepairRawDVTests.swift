// MediaRepairRawDVTests.swift
// GH #484 — "Repair Now: the combined pass's Rebuild sound step fails
// outright on a raw DV file ('fps 60000 is too large')".
//
// THE BUG (found 2026-11-18; reproduced here on generated raw DV):
//   Repair's one-pass write (MediaRepairRecipe.ffmpegArgs) read a raw DV
//   source with no input-side `-r`. The dv demuxer reports a 1/60000 picture
//   time base (avg_frame_rate 60000/1), and the QuickTime muxer refuses that
//   rate at trailer-write ("fps 60000 is too large", ffmpeg exit 234): the
//   rebuild of a raw DV file's sound never produced a copy.
//   The same pass, where it DID write raw DV to QuickTime (Remove repeated
//   frames: the picture re-encoded, the sound copied), had GH #482's defect:
//   a tape whose sound runs fast was stored whole and its tail not played.
//
// THE CONTRACT (pinned below): a pass that rewrites a raw DV file applies the
// dedicated jobs' two raw-DV rules — the PROBED rate before `-i`, and the
// sound packets' timestamps made contiguous after the encoder — so the copy
//   - is written and published (.mov), the original untouched;
//   - keeps the picture packet for packet where the pass copies it;
//   - stores every sample the original decodes, in order, and PLAYS every
//     sample it stores;
// and Repair's proof refuses any rewritten copy that would not play all the
// sound it stores (nothing published, the copy kept unpublished).

import Foundation
import Testing
@testable import VideoScan

@Suite("Repair Now — raw DV (GH #484)", .serialized)
struct MediaRepairRawDVTests {

    typealias Media = UnlockedDVMedia
    typealias F = RepairFixtures
    private let fm = FileManager.default

    /// Every frame holds the most a frame can (BalanceAudioUnlockedDVTests' `fast`).
    static func fast(_ frame: Int) -> Int { 1620 }

    static func cadence(_ name: String) -> ((Int) -> Int)? {
        switch name {
        case "fast": return fast
        case "slow": return { _ in 1584 }
        default: return nil   // locked: ffmpeg's own dv muxer cadence
        }
    }

    /// `UnlockedDVMedia.generate`'s tape with a picture that changes every
    /// frame (`testsrc2`: `testsrc` encoded as DV repeats every other picture
    /// to mpdecimate, so Remove repeated frames would halve it). The AAUX
    /// rewrite is that helper's, by its own constants.
    static func tape(in dir: URL, name: String, seconds: Int = 4, samplesPerFrame: ((Int) -> Int)?) throws -> String {
        let out = dir.appendingPathComponent("test_rawdv_\(name).dv")
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc2=duration=\(seconds):size=720x480:rate=30000/1001",
             "-f", "lavfi", "-i", "aevalsrc=\(BalancedCopyProofMedia.leftOnly):s=48000:d=\(seconds)",
             "-map", "0:v:0", "-map", "1:a:0", "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-c:a", "pcm_s16le"],
            output: out.path)
        guard let samplesPerFrame else { return out.path }
        var bytes = try Data(contentsOf: out)
        let frames = bytes.count / Media.frameBytes
        try #require(frames > 0 && bytes.count == frames * Media.frameBytes, "not whole NTSC DV frames")
        for frame in 0..<frames {
            let at = frame * Media.frameBytes + Media.sourcePackOffset
            try #require(bytes[at] == 0x50, "frame \(frame) has no AAUX source pack where one is expected")
            let field = samplesPerFrame(frame) - Media.minimumSamples
            try #require((0...40).contains(field))
            bytes[at + 1] = (bytes[at + 1] & 0xC0) | UInt8(field)
        }
        try bytes.write(to: out)
        return out.path
    }

    /// One Repair Now run of `fixes` on `source`, the output named as the sheet names it.
    static func repair(_ source: String, fixes: [MediaRepairFix], seconds: Double = 4,
                       tools: MediaRepairEngine.Tools = .located) async -> (MediaRepairOutcome, URL) {
        let src = URL(fileURLWithPath: source)
        let recipe = MediaRepairRecipe(fixes: fixes, balance: nil)
        let out = F.repairedURL(for: src, ext: recipe.fileExtension(sourceExtension: src.pathExtension, audioCodec: "pcm_s16le"))
        let request = MediaRepairRequest(sourcePath: source, sourceSizeBytes: F.size(src), sourceDurationSeconds: seconds,
                                         output: out, recipe: recipe, outputProtectionNote: nil, archiveCheck: nil)
        return (await MediaRepairEngine.run(request, tools: tools, control: nil, progress: { _, _ in }), out)
    }

    /// The original's sound as it decodes (at its probed rate), and the copy's
    /// as it is STORED and as it PLAYS — channel `channel`, 16-bit.
    private func sound(_ channel: Int, original: String, copy: String, in dir: URL) throws -> (source: Data, stored: Data, played: Data) {
        (try Media.channel(channel, of: original, in: dir, inputArgs: ["-r", "30000/1001"]),
         try Media.channel(channel, of: copy, in: dir, inputArgs: ["-ignore_editlist", "1"]),
         try Media.channel(channel, of: copy, in: dir))
    }

    // MARK: The regression (red before the fix)

    @Test("REGRESSION #484: Rebuild sound on a raw DV file writes the copy — picture packet for packet, every sample the original decodes stored AND played, the original untouched",
          .timeLimit(.minutes(3)),
          arguments: ["locked", "fast", "slow"])
    func rebuildSoundOnRawDV(_ cadence: String) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("repair_rawdv_\(cadence)")
        defer { try? fm.removeItem(at: dir) }
        let original = try Self.tape(in: dir, name: cadence, samplesPerFrame: Self.cadence(cadence))
        let before = try CleanupTestMedia.fingerprint(original)

        let (outcome, out) = await Self.repair(original, fixes: [.rebuildAudio])
        guard case .repaired(let url, let proof) = outcome else {
            Issue.record("\(cadence): expected repaired, got \(outcome)")
            return
        }
        #expect(url == out && url.pathExtension == "mov")
        #expect(proof.contains("pcm_s24le"), "\(proof)")
        #expect(!F.hasPartialOrKept(dir), "\(F.listing(dir))")

        for channel in [0, 1] {
            let s = try sound(channel, original: original, copy: url.path, in: dir)
            #expect(s.source.count > 2 * 48_000 * 3)
            #expect(s.stored == s.source, "\(cadence) ch\(channel): the copy stores \(s.stored.count / 2) samples, the original decodes \(s.source.count / 2)")
            #expect(s.played == s.stored, "\(cadence) ch\(channel): the copy PLAYS \(s.played.count / 2) of the \(s.stored.count / 2) samples it stores")
        }
        let sourcePackets = await Media.picturePackets(of: original)
        #expect(!sourcePackets.isEmpty)
        #expect(await Media.picturePackets(of: url.path) == sourcePackets)
        #expect(try CleanupTestMedia.fingerprint(original) == before)
    }

    @Test("REGRESSION #484 (#482's defect on Repair's road): Remove repeated frames on a raw DV tape whose sound runs fast — the copy PLAYS every sample it stores, and they are the original's",
          .timeLimit(.minutes(3)),
          arguments: [[MediaRepairFix.removeRepeatedFrames], [.removeRepeatedFrames, .rebuildAudio]])
    func removeRepeatedFramesOnRawDV(_ fixes: [MediaRepairFix]) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("repair_rawdv_rrf_\(fixes.count)")
        defer { try? fm.removeItem(at: dir) }
        let original = try Self.tape(in: dir, name: "fast", samplesPerFrame: Self.fast)
        let before = try CleanupTestMedia.fingerprint(original)

        let (outcome, _) = await Self.repair(original, fixes: fixes)
        guard case .repaired(let url, _) = outcome else {
            Issue.record("\(fixes): expected repaired, got \(outcome)")
            return
        }
        for channel in [0, 1] {
            let s = try sound(channel, original: original, copy: url.path, in: dir)
            #expect(s.stored == s.source, "\(fixes) ch\(channel): the copy does not store the original's samples")
            #expect(s.played == s.stored, "\(fixes) ch\(channel): the copy PLAYS \(s.played.count / 2) of the \(s.stored.count / 2) samples it stores")
        }
        #expect(try CleanupTestMedia.fingerprint(original) == before)
    }

    // MARK: Repair's proof refuses a copy that hides stored sound

    @Test("SENSOR #484: Repair's proof refuses a rewritten copy that would not play all the sound it stores — kept unpublished, nothing at the target name, the original untouched",
          .timeLimit(.minutes(3)))
    func aCopyWithAnUnplayedTailIsNotPublished() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("repair_rawdv_hidden")
        defer { try? fm.removeItem(at: dir) }
        let original = try Self.tape(in: dir, name: "fast", samplesPerFrame: Self.fast)
        let before = try CleanupTestMedia.fingerprint(original)
        // An ffmpeg that writes as Repair did before the fix: the same arguments
        // with the timestamp rewrite (`-bsf:a <filter>`) taken back out.
        let tools = dir.appendingPathComponent("tools", isDirectory: true)
        try fm.createDirectory(at: tools, withIntermediateDirectories: true)
        let old = tools.appendingPathComponent("ffmpeg")
        try """
        #!/bin/sh
        skip=0
        for a do
          shift
          if [ "$skip" = 1 ]; then skip=0; continue; fi
          if [ "$a" = "-bsf:a" ]; then skip=1; continue; fi
          set -- "$@" "$a"
        done
        exec "\(ToolLocator.ffmpegPath)" "$@"
        """.write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: old.path)

        let (outcome, out) = await Self.repair(original, fixes: [.removeRepeatedFrames],
                                               tools: .init(ffmpeg: old.path, ffprobe: ToolLocator.ffprobePath))
        guard case .failed(let why, let kept?) = outcome else {
            Issue.record("a copy with an unplayed tail was not refused: \(outcome)")
            return
        }
        #expect(why.contains("the repaired copy would not play all the sound it stores"), "\(why)")
        #expect(why.contains("so it was not saved under its name"), "\(why)")
        #expect(kept.lastPathComponent.contains(".vs-kept."))
        #expect(!fm.fileExists(atPath: out.path))
        #expect(try CleanupTestMedia.fingerprint(original) == before)
    }

    // MARK: Pure rules (the argument vectors)

    static let setts = "setts=ts=if(N\\,PREV_OUTPTS+PREV_OUTDURATION\\,PTS)"

    @Test("SENSOR #484: the source rules — raw DV gets the probed `-r` and the sound-timestamp rewrite (the dedicated jobs' own functions); every other container gets nothing")
    func sourceRulesTable() {
        let ntsc = MediaRepairSourceRules(containerFormat: "dv", rFrameRate: "30000/1001")
        #expect(ntsc.inputArgs == ["-r", "30000/1001"])
        #expect(ntsc.soundTimestampArgs == ["-bsf:a", Self.setts])
        #expect(ntsc.soundTimestampArgs == BalanceAudioFix.soundTimestampArgs(containerFormat: "dv"))
        #expect(MediaRepairSourceRules(containerFormat: "dv", rFrameRate: "25/1").inputArgs == ["-r", "25/1"])
        // No believable rate: no `-r` (ffmpeg then refuses; nothing is published) — the dedicated jobs' rule.
        for rate in ["0/0", nil, "", "x"] as [String?] {
            let r = MediaRepairSourceRules(containerFormat: "dv", rFrameRate: rate)
            #expect(r.inputArgs.isEmpty && r.soundTimestampArgs == ["-bsf:a", Self.setts], "\(String(describing: rate))")
        }
        for other in ["mov,mp4,m4a,3gp,3g2,mj2", "matroska,webm", "mxf", "avi", "mpeg", "mpegts", ""] {
            #expect(MediaRepairSourceRules(containerFormat: other, rFrameRate: "30000/1001") == .none, "\(other)")
        }
        let summary = MediaRepairStreamSummary(streams: [], durationSeconds: 4,
                                               picture: MediaRepairPictureFacts(codec: "dvvideo", rFrameRate: "30000/1001"),
                                               containerFormat: "dv")
        #expect(MediaRepairSourceRules(summary: summary) == ntsc)
        #expect(MediaRepairSourceRules(summary: MediaRepairStreamSummary(streams: [], durationSeconds: 4, containerFormat: "dv"))
                == MediaRepairSourceRules(containerFormat: "dv", rFrameRate: nil))
        #expect(MediaRepairCommand.summaryArgs(input: "/x").contains { $0.hasPrefix("format=duration,format_name:") })
    }

    @Test("SENSOR #484: the combined pass's vector — raw DV: `-r` before `-i`, the rewrite after the sound's encoder; every other container's vector byte for byte as before; the remux and the add-sound mux never take the rules")
    func combinedPassArguments() {
        let dv = MediaRepairSourceRules(containerFormat: "dv", rFrameRate: "30000/1001")
        let rebuild = MediaRepairRecipe(fixes: [.rebuildAudio], balance: nil)
        let tail = ["-map_metadata", "0", "-map_chapters", "0", "-progress", "pipe:2", "/out/t_repaired.mov"]
        #expect(rebuild.ffmpegArgs(input: "/in/t.dv", output: "/out/t_repaired.mov", picture: nil, source: dv)
                == ["-hide_banner", "-nostdin", "-y", "-r", "30000/1001", "-i", "/in/t.dv", "-map", "0:v:0?", "-map", "0:a:0?",
                    "-c:v", "copy", "-c:a", "pcm_s24le", "-bsf:a", Self.setts] + tail)
        // Every other container: the vector of before the fix, literally.
        let before = ["-hide_banner", "-nostdin", "-y", "-i", "/in/t.mp4", "-map", "0:v:0?", "-map", "0:a:0?",
                      "-c:v", "copy", "-c:a", "pcm_s24le"] + tail
        #expect(rebuild.ffmpegArgs(input: "/in/t.mp4", output: "/out/t_repaired.mov", picture: nil, source: .none) == before)
        #expect(rebuild.ffmpegArgs(input: "/in/t.mp4", output: "/out/t_repaired.mov", picture: nil) == before)
        // Remove repeated frames (sound copied): the rewrite follows `-c:a copy`.
        let plan = MediaRepairPicturePlan(rateText: "30000/1001", rate: 30000.0 / 1001, rateSource: "", pixelFormat: "yuv420p",
                                          reducesColourDetail: false, tagArgs: [], sampleAspectRatio: nil)
        let rrf = MediaRepairRecipe(fixes: [.removeRepeatedFrames], balance: nil)
        #expect(rrf.ffmpegArgs(input: "/in/t.dv", output: "/out/t_repaired.mov", picture: plan, source: dv)
                == ["-hide_banner", "-nostdin", "-y", "-r", "30000/1001", "-i", "/in/t.dv", "-map", "0:v:0?", "-map", "0:a?"]
                + plan.encodeArgs + ["-c:a", "copy", "-bsf:a", Self.setts] + tail)
        // The lossless remux keeps raw DV as raw DV: no rules. The add-sound mux is Combine's.
        let remux = MediaRepairRecipe(fixes: [.remux], balance: nil)
        #expect(remux.ffmpegArgs(input: "/in/t.dv", output: "/o.dv", picture: nil, source: dv)
                == MediaRepairCommand.remuxArgs(input: "/in/t.dv", output: "/o.dv"))
        let add = MediaRepairRecipe(fixes: [.addSound], balance: nil, soundFile: "/in/s.wav")
        #expect(add.ffmpegArgs(input: "/in/t.dv", output: "/o.mov", picture: nil, source: dv)
                == MediaRepairRecipe.addSoundArgs(picture: "/in/t.dv", sound: "/in/s.wav", output: "/o.mov"))
        #expect(MediaRepairEngine.rewritesSource(rebuild) && MediaRepairEngine.rewritesSource(rrf))
        #expect(!MediaRepairEngine.rewritesSource(remux) && !MediaRepairEngine.rewritesSource(add))
    }

    // MARK: Media matrix — nothing changes for any other container

    @Test("MATRIX #484: Rebuild sound on every container of the matrix — the preflight asks nothing of the container (the vector of before), the copy is published and plays all it stores",
          .timeLimit(.minutes(3)),
          arguments: RepairFixtures.Container.allCases)
    func rebuildOnTheMatrix(_ container: RepairFixtures.Container) async throws {
        let dir = try F.makeDir("rawdv_matrix_\(container.rawValue)")
        defer { try? fm.removeItem(at: dir) }
        let src = try F.make(container, in: dir)
        let before = try F.sha256(src)
        let recipe = MediaRepairRecipe(fixes: [.rebuildAudio], balance: nil)
        let out = F.repairedURL(for: src, ext: recipe.fileExtension(sourceExtension: container.ext, audioCodec: ""))
        let req = F.request(source: src, output: out, fixes: [.rebuildAudio])
        let preflight = await MediaRepairEngine.preflight(req, tools: .located, control: nil, progress: { _, _ in })
        #expect(preflight == .go(picture: nil, source: .none), "\(container): \(preflight)")
        let outcome = await F.run(req)
        guard case .repaired(let url, _) = outcome else {
            Issue.record("\(container): expected repaired, got \(outcome)")
            return
        }
        #expect(try await MediaRepairProbe.unplayedSoundFailure(path: url.path, control: nil) == nil)
        #expect(try F.sha256(src) == before)
        #expect(!F.hasPartialOrKept(dir))
    }

    @Test("MATRIX #484: raw DV with NO sound — Remove repeated frames still writes (the sound rewrite has nothing to touch)",
          .timeLimit(.minutes(3)))
    func rawDVWithoutSound() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("repair_rawdv_silent")
        defer { try? fm.removeItem(at: dir) }
        let original = dir.appendingPathComponent("test_rawdv_nosound.dv").path
        try BalanceAudioTestMedia.runFFmpeg(
            ["-f", "lavfi", "-i", "testsrc2=duration=3:size=720x480:rate=30000/1001", "-c:v", "dvvideo", "-pix_fmt", "yuv411p", "-an"],
            output: original)
        let (outcome, _) = await Self.repair(original, fixes: [.removeRepeatedFrames], seconds: 3)
        guard case .repaired(let url, _) = outcome else {
            Issue.record("expected repaired, got \(outcome)")
            return
        }
        #expect(url.pathExtension == "mov")
    }

    // MARK: DV inside AVI

    /// `dvPath`'s frames as a TYPE 1 DV AVI: one interleaved `iavs` stream,
    /// which ffmpeg reads through the same dv demuxer as raw DV (1/60000
    /// picture time base, sound stamped by its sample count) — but whose
    /// container probes as "avi". ffmpeg cannot write one; built by hand
    /// (RIFF: hdrl/avih, strl/strh+strf DVINFO, movi of `00dc` chunks, idx1).
    static func typeOneAVI(from dvPath: String, to out: String) throws {
        let raw = try Data(contentsOf: URL(fileURLWithPath: dvPath))
        let frames = raw.count / Media.frameBytes
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func chunk(_ id: String, _ body: Data) -> Data {
            Data(id.utf8) + le32(UInt32(body.count)) + body + (body.count % 2 == 1 ? Data([0]) : Data())
        }
        func list(_ kind: String, _ body: Data) -> Data { chunk("LIST", Data(kind.utf8) + body) }
        var avih = Data()
        for v: UInt32 in [33_367, 3_600_000, 0, 0x10, UInt32(frames), 0, 1, UInt32(Media.frameBytes), 720, 480, 0, 0, 0, 0] {
            avih += le32(v)
        }
        var strh = Data("iavsdvsd".utf8) + le32(0) + le16(0) + le16(0)
        for v: UInt32 in [0, 1001, 30_000, 0, UInt32(frames), UInt32(Media.frameBytes), 0xFFFF_FFFF, 0] { strh += le32(v) }
        strh += le16(0) + le16(0) + le16(720) + le16(480)
        let hdrl = list("hdrl", chunk("avih", avih) + list("strl", chunk("strh", strh) + chunk("strf", Data(count: 32))))
        var movi = Data(), idx = Data()
        var offset: UInt32 = 4
        for f in 0..<frames {
            let frame = raw.subdata(in: f * Media.frameBytes..<(f + 1) * Media.frameBytes)
            movi += chunk("00dc", frame)
            idx += Data("00dc".utf8) + le32(0x10) + le32(offset) + le32(UInt32(frame.count))
            offset += UInt32(8 + frame.count)
        }
        let body = Data("AVI ".utf8) + hdrl + list("movi", movi) + chunk("idx1", idx)
        try (Data("RIFF".utf8) + le32(UInt32(body.count)) + body).write(to: URL(fileURLWithPath: out))
    }

    @Test("DV-in-AVI #484: type 1 (the dv demuxer under an \"avi\" name) gets no raw-DV rules — a fast tape's rewritten copy would hide its tail, so Repair's proof REFUSES it (kept unpublished); a locked one and type 2 are repaired whole",
          .timeLimit(.minutes(3)),
          arguments: ["type1-fast", "type1-locked", "type2-fast"])
    func dvInsideAVI(_ shape: String) async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("repair_avi_\(shape)")
        defer { try? fm.removeItem(at: dir) }
        let fast = shape.hasSuffix("fast")
        let cadence: ((Int) -> Int)? = fast ? { Self.fast($0) } : nil
        let dv = try Self.tape(in: dir, name: fast ? "fast" : "locked", samplesPerFrame: cadence)
        let original = dir.appendingPathComponent("test_\(shape).avi").path
        if shape.hasPrefix("type1") {
            try Self.typeOneAVI(from: dv, to: original)
        } else {
            try BalanceAudioTestMedia.runFFmpeg(["-r", "30000/1001", "-i", dv, "-map", "0", "-c", "copy"], output: original)
        }
        try fm.removeItem(atPath: dv)
        let summary = try await MediaRepairProbe.summary(path: original, control: nil)
        #expect(summary.containerFormat == "avi")
        #expect(MediaRepairSourceRules(summary: summary) == .none)
        let before = try CleanupTestMedia.fingerprint(original)

        let (outcome, out) = await Self.repair(original, fixes: [.rebuildAudio])
        if shape == "type1-fast" {
            guard case .failed(let why, let kept?) = outcome else {
                Issue.record("expected the proof to refuse the hidden tail, got \(outcome)")
                return
            }
            #expect(why.contains("the repaired copy would not play all the sound it stores ("), "\(why)")
            #expect(kept.lastPathComponent.contains(".vs-kept.") && !fm.fileExists(atPath: out.path))
        } else {
            guard case .repaired(let url, _) = outcome else {
                Issue.record("\(shape): expected repaired, got \(outcome)")
                return
            }
            let source = try Media.channel(0, of: original, in: dir)
            #expect(try Media.channel(0, of: url.path, in: dir) == source)
            #expect(try Media.channel(0, of: url.path, in: dir, inputArgs: ["-ignore_editlist", "1"]) == source)
        }
        #expect(try CleanupTestMedia.fingerprint(original) == before)
    }

    // MARK: Isolation — a header that can't be read

    @Test("ISOLATION #484: a rewriting pass on a file whose header can't be read is REFUSED before any write (the proof could never read it either)",
          .timeLimit(.minutes(2)))
    func unreadableHeaderIsRefusedBeforeAnyWrite() async throws {
        let dir = try F.makeDir("rawdv_garbage")
        defer { try? fm.removeItem(at: dir) }
        let src = dir.appendingPathComponent("test_garbage.dv")
        try Data((0..<200_000).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) }).write(to: src)
        let listing = F.listing(dir)
        let (outcome, _) = await Self.repair(src.path, fixes: [.rebuildAudio])
        guard case .refused(let why) = outcome else {
            Issue.record("expected refused, got \(outcome)")
            return
        }
        #expect(why.hasPrefix("The original's header couldn't be read"), "\(why)")
        #expect(why.hasSuffix("Nothing was written."))
        #expect(F.listing(dir) == listing)
    }

    // MARK: Truth — what the proof engines say about the copy

    /// Each decoded picture's SHA-256, in order (`inputArgs` before `-i`).
    private static func decodedPictures(of path: String, inputArgs: [String] = []) async -> [String] {
        let listing = await ProcessRunner.runProcess(
            executable: ToolLocator.ffmpegPath,
            arguments: ["-v", "error"] + inputArgs + ["-i", path, "-map", "0:v:0", "-f", "framehash", "-hash", "sha256", "-"],
            deadlineSeconds: 120)
        return (listing.stdout ?? "").split(separator: "\n").filter { !$0.hasPrefix("#") }.compactMap {
            $0.split(separator: ",").last.map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    @Test("TRUTH #484: the rebuilt copy's picture AS PLAYED is the original's, frame for frame; the balanced-copy proof is not this pair's (it names the sound format change, s16 → s24, and claims nothing)",
          .timeLimit(.minutes(3)))
    func whatTheProofsSay() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try BalanceAudioTestMedia.makeScratchDir("repair_rawdv_truth")
        defer { try? fm.removeItem(at: dir) }
        let original = try Self.tape(in: dir, name: "locked", samplesPerFrame: nil)
        let (outcome, _) = await Self.repair(original, fixes: [.rebuildAudio])
        guard case .repaired(let url, _) = outcome else {
            Issue.record("expected repaired, got \(outcome)")
            return
        }
        let played = await Self.decodedPictures(of: original, inputArgs: ["-r", "30000/1001"])
        #expect(played.count == (try Data(contentsOf: URL(fileURLWithPath: original)).count / Media.frameBytes))
        #expect(await Self.decodedPictures(of: url.path) == played)

        let measured = await BalancedCopyProof.measurement(original: original, balanced: url.path)
        guard case .notProven(.soundFormatChanged(let what)) = measured.outcome else {
            Issue.record("expected the proof to name the sound format change, got \(measured.outcome)")
            return
        }
        #expect(what.contains("pcm_s16le") && what.contains("pcm_s24le"), "\(what)")
    }
}
