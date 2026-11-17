// BalancedCopyProofHardeningTests.swift
// Codex review #298 (2026-11-16) BLOCKED BalancedCopyProof with eight
// findings, five of them ways to a false PROVEN. Each test here is one of
// those reproductions, built with real ffmpeg media (tones and test
// patterns only), seen RED on the engine as reviewed and green after it —
// and green again on the engine rebuilt 2026-11-17 to compare WHAT PLAYS,
// where most of them are now refused by the decoded frames themselves.
//
// A false "the same" can cost a family recording; "not the same" and
// "could not check" only cost keeping the original. So every test below
// asserts a refusal, and — where the reproduction depends on it — first
// asserts, by another road, that the damaged copy really does agree with
// the original in everything the FIRST proof compared (so the test cannot
// pass for the wrong reason).

import Foundation
import os
import Testing
@testable import VideoScan
import VideoScanCore

/// Fixture helpers for the hardening and coverage suites.
enum BalancedCopyProofLab {

    typealias Media = BalancedCopyProofMedia

    /// A 2-second file with any picture and sound arguments. `video` nil =
    /// sound only.
    static func make(_ name: String, in dir: URL, video: [String]? = ["-c:v", "prores_ks", "-profile:v", "0"],
                     audio: [String] = ["-c:a", "pcm_s16le"], channels: String = Media.leftOnly,
                     extra: [String] = [], seconds: Int = 2) throws -> String {
        let out = dir.appendingPathComponent(name).path
        var args: [String] = []
        if video != nil { args += ["-f", "lavfi", "-i", "testsrc=duration=\(seconds):size=320x240:rate=25"] }
        args += ["-f", "lavfi", "-i", "aevalsrc=\(channels):s=48000:d=\(seconds)"]
        try BalanceAudioTestMedia.runFFmpeg(args + (video ?? []) + audio + extra, output: out)
        return out
    }

    /// stdout of one tool run, trimmed.
    static func output(_ tool: String, _ args: [String]) async -> String {
        let result = await ProcessRunner.runProcess(executable: tool, arguments: args, deadlineSeconds: 120)
        return (result.stdout ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One ffprobe stream entry ("width", "start_time", "channel_layout" …).
    static func entry(_ name: String, of path: String, stream: String) async -> String {
        await output(ToolLocator.ffprobePath,
                     ["-v", "error", "-select_streams", stream, "-show_entries", "stream=\(name)",
                      "-of", "default=nw=1:nk=1", path])
    }

    /// SHA-256 over one stream's packets, by the `hash` muxer.
    static func packetHash(of path: String, stream: String) async -> String {
        await output(ToolLocator.ffmpegPath,
                     ["-v", "error", "-i", path, "-map", "0:\(stream)", "-c", "copy", "-f", "hash", "-hash", "sha256", "-"])
    }

    /// SHA-256 over one channel's decoded 16-bit samples.
    static func channelHash(of path: String, channel: Int) async -> String {
        await output(ToolLocator.ffmpegPath,
                     ["-v", "error", "-i", path, "-map", "0:a:0", "-af", "pan=mono|c0=c\(channel)",
                      "-c:a", "pcm_s16le", "-f", "hash", "-hash", "sha256", "-"])
    }

    /// An executable shell script in `dir/tools-<name>/<tool>`.
    static func script(_ name: String, tool: String, in dir: URL, _ body: String) throws -> String {
        let folder = dir.appendingPathComponent("tools-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(tool)
        try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url.path
    }

    /// Where `firstSecondOnlyFFmpeg(in:name:…)` leaves a mark each time it runs.
    static func ranMark(in dir: URL, name: String) -> String { dir.path + "/tools-\(name)/ran" }

    /// A tool that writes every argument it is given, one per line, to
    /// `tools-<name>/arguments` and then does the real work.
    static func recording(_ tool: String, real: String, in dir: URL, name: String) throws -> String {
        try script(name, tool: tool, in: dir, """
        for a in "$@"; do printf '%s\\n' "$a" >> "\(dir.path)/tools-\(name)/arguments"; done
        exec "\(real)" "$@"
        """)
    }

    /// An ffmpeg that reads only the FIRST SECOND of every input and still
    /// exits 0 — a zero-exit partial read. `complaint` is what it prints on
    /// stderr afterwards ("" = it stays silent). Leaves `ranMark` behind.
    static func firstSecondOnlyFFmpeg(in dir: URL, name: String, complaint: String) throws -> String {
        try script(name, tool: "ffmpeg", in: dir, """
        : > "\(ranMark(in: dir, name: name))"
        n=$#
        i=0
        while [ $i -lt $n ]; do
          a="$1"; shift
          if [ "$a" = "-i" ]; then set -- "$@" -t 1 -i; else set -- "$@" "$a"; fi
          i=$((i+1))
        done
        "\(ToolLocator.ffmpegPath)" "$@"
        \(complaint.isEmpty ? ":" : "echo \"\(complaint)\" >&2")
        exit 0
        """)
    }

    static func reason(_ outcome: BalancedCopyProof.Outcome) -> String? {
        if case .couldNotCheck(let why) = outcome { return why }
        return nil
    }

    /// Why, when the outcome is "not the same".
    static func refusal(_ outcome: BalancedCopyProof.Outcome) -> BalancedCopyProof.NotProven? {
        if case .notProven(let why) = outcome { return why }
        return nil
    }

    /// Every named difference as the log writes it.
    static func differs(_ outcome: BalancedCopyProof.Outcome) -> [String] {
        outcome.differences.map(BalancedCopyProof.sentence)
    }

    /// "pts,duration,size,SHA256:…[,flags]" of every packet of one stream —
    /// what the packet pass compares (`flags` adds the discard flag).
    static func packetRows(of path: String, stream: String, flags: Bool = false) async -> String {
        await output(ToolLocator.ffprobePath,
                     ["-v", "error", "-select_streams", stream, "-show_packets", "-show_data_hash", "sha256",
                      "-show_entries", "packet=pts,duration,size,data_hash" + (flags ? ",flags" : ""), "-of", "csv=p=0", path])
    }

    /// Frames a player is given of one stream (decoded, edit list applied).
    static func playedFrames(of path: String, stream: String = "v:0") async -> String {
        await output(ToolLocator.ffprobePath,
                     ["-v", "error", "-select_streams", stream, "-count_frames", "-show_entries", "stream=nb_read_frames",
                      "-of", "default=nw=1:nk=1", path])
    }

    /// A copy of `path` named `name` with one 32-bit field rewritten in
    /// place: the field `offset` bytes after the first occurrence of
    /// `marker` (an atom or chunk name), read and written big- or
    /// little-endian. Returns the new file's path and the old value.
    static func patched(_ path: String, as name: String, after marker: String, offset: Int, littleEndian: Bool = false,
                        _ change: (UInt32) -> UInt32) throws -> (path: String, was: UInt32) {
        var bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let found = try #require(bytes.range(of: Data(marker.utf8)), "no \(marker) in \((path as NSString).lastPathComponent)")
        let field = (found.upperBound + offset)..<(found.upperBound + offset + 4)
        let raw = Array(bytes[field])
        let old = (littleEndian ? raw.reversed() : raw).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        let new = change(old)
        let out = [UInt8(new >> 24), UInt8(new >> 16 & 0xff), UInt8(new >> 8 & 0xff), UInt8(new & 0xff)]
        bytes.replaceSubrange(field, with: littleEndian ? out.reversed() : out)
        let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(name)
        try bytes.write(to: url)
        return (url.path, old)
    }
}

@Suite("Balanced copy proof — Codex #298 reproductions", .serialized)
struct BalancedCopyProofHardeningTests {

    typealias Proof = BalancedCopyProof
    typealias Media = BalancedCopyProofMedia
    typealias Lab = BalancedCopyProofLab
    private let fm = FileManager.default

    /// mov/prores + 16-bit PCM, left only, NO timecode track, and its
    /// balanced copy.
    private func plainPair(_ label: String) async throws -> (dir: URL, original: String, balanced: String) {
        let dir = try Media.scratch(label)
        let original = try Media.original(in: dir, .movProResPCM16)
        let balanced = try await Media.balance(original)
        return (dir, original, balanced)
    }

    // MARK: F1 — the discarded channel

    @Test("F1: a short quiet passage on the 'dead' channel (whole-track RMS under the floor) is NOT PROVEN",
          .timeLimit(.minutes(2)))
    func quietPassageOnTheDiscardedChannelIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("f1burst")
        defer { try? fm.removeItem(at: dir) }
        // Right: 50 ms of an 880 Hz tone peaking at −48 dBFS, silence around
        // it. Over 2 s that is −67 dBFS RMS, so the analyzer calls it dead.
        let original = try Media.original(
            in: dir, .movProResPCM24, channels: "\(Media.tone)|0.004*sin(880*2*PI*t)*gt(t\\,1)*lt(t\\,1.05)")
        let analysis = try await AudioBalanceProbe.analyze(path: original)
        #expect(analysis.classification == .leftOnly, "the fixture must be one the balance job accepts")
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        #expect(!outcome.playsTheSame, "sound the copy does not carry was certified as preserved: \(outcome)")
        guard case .notProven(.discardedChannelNotSilent(let channel, let peak)) = outcome else {
            Issue.record("expected the discarded channel to be the reason, got \(outcome)")
            return
        }
        #expect(channel == 1)
        #expect(abs(peak - -47.96) < 0.2, "0.004 full scale is −47.96 dBFS; measured \(peak)")
        #expect(Proof.logLine(original: original, balanced: balanced, outcome: outcome)
            .hasSuffix("the original's other channel is not silent (peak −48.0 dBFS) — the original is kept"))
    }

    @Test("F1: hiss on the 'dead' channel peaking just over the ceiling (−59.9 dBFS; −64.8 RMS) is NOT PROVEN",
          .timeLimit(.minutes(2)))
    func hissJustOverTheCeilingIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("f1hiss")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .movProResPCM16, channels: "\(Media.tone)|0.001*(2*random(0)-1)")
        #expect(try await AudioBalanceProbe.analyze(path: original).classification == .leftOnly)
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        guard case .notProven(.discardedChannelNotSilent(1, let peak)) = outcome else {
            Issue.record("expected the discarded channel to be the reason, got \(outcome)")
            return
        }
        #expect(peak > Proof.discardedChannelPeakCeilingDBFS && peak < -59.0, "measured \(peak)")
    }

    @Test("F1 PIN (Rick rules on the ceiling): Codex's steady 0.0005 sine peaks at −66 dBFS, UNDER −60 — proven, and the evidence says what was left behind",
          .timeLimit(.minutes(2)))
    func codexQuietSineIsUnderTheCeilingAndTheEvidenceSaysSo() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("f1sine")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.original(in: dir, .movProResPCM24, channels: "\(Media.tone)|0.0005*sin(880*2*PI*t)")
        let balanced = try await Media.balance(original)

        let outcome = await Proof.measure(original: original, balanced: balanced)
        // With the ceiling at −60 dBFS PEAK this pair is still proven: the
        // sine peaks at −66.0. What changed is that the proof now MEASURES
        // the channel and says so. If Rick lowers the ceiling under −66,
        // this test flips to discardedChannelNotSilent — change it then.
        guard case .proven(let evidence) = outcome else {
            Issue.record("the ceiling moved, or the measurement did: \(outcome)")
            return
        }
        let discarded = try #require(evidence.discarded)
        #expect(discarded.channel == 1 && !discarded.isDigitalSilence)
        #expect(abs(discarded.peakDBFS - -66.02) < 0.1, "0.0005 full scale is −66.02 dBFS; measured \(discarded.peakDBFS)")
        #expect(Proof.logLine(original: original, balanced: balanced, outcome: outcome)
            .contains("original right: peak −66.0 dBFS, not in the copy"))
    }

    // MARK: F2 — timing

    @Test("F2: a copy whose sound starts half a second late — same packets, same samples — is NOT PROVEN",
          .timeLimit(.minutes(2)))
    func shiftedSoundIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await plainPair("f2shift")
        defer { try? fm.removeItem(at: dir) }
        let shifted = try Media.derive(
            "shifted_balanced", from: balanced,
            ["-itsoffset", "0.5", "-i", balanced, "-map", "0:v", "-map", "1:a", "-c", "copy", "-write_tmcd", "0"])

        // By another road: only the sound's start moved.
        #expect(await Lab.entry("start_time", of: original, stream: "a:0") == "0.000000")
        #expect(await Lab.entry("start_time", of: shifted, stream: "a:0") == "0.500000")
        let picture = await Lab.packetHash(of: original, stream: "v:0")
        let live = await Lab.channelHash(of: original, channel: 0)
        #expect(picture.hasPrefix("SHA256=") && live.hasPrefix("SHA256="))
        #expect(await Lab.packetHash(of: shifted, stream: "v:0") == picture)
        #expect(await Lab.channelHash(of: shifted, channel: 1) == live)

        let outcome = await Proof.measure(original: original, balanced: shifted)
        #expect(!outcome.playsTheSame, "A/V sync changed and the copy was still the same: \(outcome)")
        #expect(outcome == .notProven(.soundPlacementDiffers(
            "run 1: 96000 samples from sample time 0, in the balanced copy 96000 from 24000")), "\(outcome)")
    }

    @Test("F2: an original whose sound really starts half a second late is still PROVEN against the job's own copy",
          .timeLimit(.minutes(2)))
    func lateSoundOriginalStillProves() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, plain, _) = try await plainPair("f2late")
        defer { try? fm.removeItem(at: dir) }
        let original = try Media.derive(
            "test_late", from: plain,
            ["-itsoffset", "0.5", "-i", plain, "-map", "0:v", "-map", "1:a", "-c", "copy", "-write_tmcd", "0"])
        #expect(await Lab.entry("start_time", of: original, stream: "a:0") == "0.500000")
        let balanced = try await Media.balance(original)
        #expect(await Lab.entry("start_time", of: balanced, stream: "a:0") == "0.500000")

        let outcome = await Proof.measure(original: original, balanced: balanced)
        #expect(outcome.isProven, "the timing rule must pass what Balance Audio really writes: \(outcome)")
        #expect(outcome.evidence?.soundStartSeconds == 0.5, "the evidence says where the sound starts")
    }

    @Test("F2: a QuickTime copy whose edit list plays only the first half of the picture — same bytes otherwise — is NOT PROVEN",
          .timeLimit(.minutes(2)))
    func editListTrimmedCopyIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await plainPair("f2elst")
        defer { try? fm.removeItem(at: dir) }
        // Halve the segment duration of the first track's (the picture's) edit list, in place.
        let (trimmed, duration) = try Lab.patched(balanced, as: "trimmed_balanced.mov", after: "elst", offset: 8) { $0 / 2 }
        #expect(duration > 0)

        #expect(await Lab.entry("duration", of: balanced, stream: "v:0") == "2.000000")
        #expect(await Lab.entry("duration", of: trimmed, stream: "v:0") == "1.000000")
        let outcome = await Proof.measure(original: original, balanced: trimmed)
        #expect(outcome == .notProven(.pictureDiffers(originalIndex: 0, "50 frames play in the original, 25 in the balanced copy")),
                "\(outcome)")
    }

    @Test("F2: a copy whose picture was retimed to half speed — same packets — is NOT PROVEN", .timeLimit(.minutes(2)))
    func retimedPictureIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await plainPair("f2retime")
        defer { try? fm.removeItem(at: dir) }
        let retimed = try Media.derive("retimed_balanced", from: balanced,
                                       ["-map", "0", "-c", "copy", "-bsf:v", "setts=ts=N*1024"])

        #expect(await Lab.entry("r_frame_rate", of: original, stream: "v:0") == "25/1")
        #expect(await Lab.entry("r_frame_rate", of: retimed, stream: "v:0") == "25/2")
        let picture = await Lab.packetHash(of: original, stream: "v:0")
        #expect(picture.hasPrefix("SHA256="))
        #expect(await Lab.packetHash(of: retimed, stream: "v:0") == picture)

        let outcome = await Proof.measure(original: original, balanced: retimed)
        #expect(!outcome.playsTheSame, "the picture plays at half speed and the copy was still the same: \(outcome)")
        guard case .notProven(.pictureDiffers(0, let what)) = outcome else {
            Issue.record("expected the picture's times to be the reason, got \(outcome)")
            return
        }
        #expect(what.hasPrefix("its frames are not the original's, each at the original's time"), "\(what)")
    }

    // MARK: F3 — partial reads

    @Test("F3: Codex's scenario — a one-second copy, and an ffmpeg that reads only one second of the original and says so on stderr — is COULD NOT CHECK",
          .timeLimit(.minutes(2)))
    func zeroExitPartialReadNeverProvesAShortCopy() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await plainPair("f3short")
        defer { try? fm.removeItem(at: dir) }
        let half = try Media.derive("half_balanced", from: balanced,
                                    ["-t", "1", "-map", "0", "-c", "copy", "-write_tmcd", "0"])
        let partial = try Lab.firstSecondOnlyFFmpeg(
            in: dir, name: "noisy", complaint: "[in#0/mov @ 0x0] Error during demuxing: Input/output error")

        let outcome = await Proof.measure(original: original, balanced: half,
                                          tools: Proof.Tools(ffmpeg: partial, ffprobe: ToolLocator.ffprobePath))
        #expect(!outcome.playsTheSame, "a copy holding half the recording was the same: \(outcome)")
        // The halves agree frame for frame — the only thing between this pair and
        // "the same" is that the read is not believed.
        #expect(fm.fileExists(atPath: Lab.ranMark(in: dir, name: "noisy")), "the decode pass was reached")
        #expect(Lab.reason(outcome)?.contains("Error during demuxing: Input/output error") == true, "\(outcome)")
        // With the real ffmpeg the same pair is refused for what it is: half the picture.
        #expect(await Proof.measure(original: original, balanced: half)
                == .notProven(.pictureDiffers(originalIndex: 0, "50 frames play in the original, 25 in the balanced copy")))
    }

    @Test("F3: a zero-exit read with ANYTHING on stderr is COULD NOT CHECK, even for a faithful pair",
          .timeLimit(.minutes(2)))
    func stderrOutputWithExitZeroIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await plainPair("f3noisy")
        defer { try? fm.removeItem(at: dir) }
        let partial = try Lab.firstSecondOnlyFFmpeg(
            in: dir, name: "noisy", complaint: "[in#0/mov @ 0x0] Error during demuxing: Input/output error")

        let outcome = await Proof.measure(original: original, balanced: balanced,
                                          tools: Proof.Tools(ffmpeg: partial, ffprobe: ToolLocator.ffprobePath))
        #expect(fm.fileExists(atPath: Lab.ranMark(in: dir, name: "noisy")), "the decode pass was reached")
        let why = try #require(Lab.reason(outcome), "expected could not check, got \(outcome)")
        #expect(why.contains("Error during demuxing: Input/output error"), "the reason quotes the line: \(why)")
    }

    @Test("F3: a SILENT zero-exit short read of both files is COULD NOT CHECK — the read is held to ffprobe's count",
          .timeLimit(.minutes(2)))
    func silentShortReadIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await plainPair("f3silent")
        defer { try? fm.removeItem(at: dir) }
        let partial = try Lab.firstSecondOnlyFFmpeg(in: dir, name: "silent", complaint: "")

        let outcome = await Proof.measure(original: original, balanced: balanced,
                                          tools: Proof.Tools(ffmpeg: partial, ffprobe: ToolLocator.ffprobePath))
        #expect(fm.fileExists(atPath: Lab.ranMark(in: dir, name: "silent")), "the decode pass was reached")
        let why = try #require(Lab.reason(outcome), "expected could not check, got \(outcome)")
        #expect(why.hasPrefix("the original was not read to the end (stream ") && why.hasSuffix(" packets)"),
                "fewer packets than the packet pass listed: \(why)")
    }

    // MARK: F4 — identity

    @Test("F4: an original reached through a symbolic link that is retargeted mid-run and put back is COULD NOT CHECK",
          .timeLimit(.minutes(2)))
    func symlinkRetargetIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("f4link")
        defer { try? fm.removeItem(at: dir) }
        // A and B: two different left-only recordings of one shape.
        let a = try Lab.make("test_a.mov", in: dir)
        let b = try Lab.make("test_b.mov", in: dir, channels: "0.4*sin(660*2*PI*t)|0")
        let bBalanced = try await Media.balance(b)
        let link = dir.appendingPathComponent("test_link.mov").path
        try fm.createSymbolicLink(atPath: link, withDestinationPath: a)

        // ffprobe: point the link at B, then do the real work.
        let probe = try Lab.script("retarget", tool: "ffprobe", in: dir, """
        /bin/ln -sfn "\(b)" "\(link)"
        exec "\(ToolLocator.ffprobePath)" "$@"
        """)
        // ffmpeg: do the real work; after the copy's pass (the last one) put the link back on A.
        let hasher = try Lab.script("retarget", tool: "ffmpeg", in: dir, """
        "\(ToolLocator.ffmpegPath)" "$@"
        status=$?
        case "$*" in *test_b_balanced*) /bin/ln -sfn "\(a)" "\(link)" ;; esac
        exit $status
        """)
        let stampBefore = FileIdentityStamp.capture(path: a)

        let outcome = await Proof.measure(original: link, balanced: bBalanced,
                                          tools: Proof.Tools(ffmpeg: hasher, ffprobe: probe))
        #expect(Lab.reason(outcome) != nil, "B's hashes were bound to A's stamp: \(outcome)")
        #expect(Lab.reason(outcome)?.hasPrefix("the original is a symbolic link") == true, "\(outcome)")
        #expect(FileIdentityStamp.capture(path: a) == stampBefore, "A itself was never touched")
        // The same B pair, named directly, is a good pair.
        #expect(await Proof.measure(original: b, balanced: bBalanced).isProven)
        // A link in the copy's place is refused the same way.
        let copyLink = dir.appendingPathComponent("test_copy_link.mov").path
        try fm.createSymbolicLink(atPath: copyLink, withDestinationPath: bBalanced)
        let linked = await Proof.measure(original: b, balanced: copyLink)
        #expect(Lab.reason(linked)?.hasPrefix("the balanced copy is a symbolic link") == true, "\(linked)")
    }

    @Test("F4: every tool reads the RESOLVED path; a parent folder re-pointed mid-run is COULD NOT CHECK",
          .timeLimit(.minutes(2)))
    func parentFolderRetargetIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("f4parent")
        defer { try? fm.removeItem(at: dir) }
        let first = dir.appendingPathComponent("first", isDirectory: true)
        let second = dir.appendingPathComponent("second", isDirectory: true)
        try fm.createDirectory(at: first, withIntermediateDirectories: true)
        let original = try Media.original(in: first, .movProResPCM16)
        let balanced = try await Media.balance(original)
        try fm.copyItem(at: first, to: second)
        let via = dir.appendingPathComponent("via").path
        try fm.createSymbolicLink(atPath: via, withDestinationPath: first.path)
        let givenOriginal = via + "/" + (original as NSString).lastPathComponent
        let givenBalanced = via + "/" + (balanced as NSString).lastPathComponent

        // Left alone: proven, and the evidence names where the paths really led.
        guard case .proven(let evidence) = await Proof.measure(original: givenOriginal, balanced: givenBalanced) else {
            Issue.record("a pair reached through a linked folder is still a pair")
            return
        }
        #expect(evidence.originalResolvedPath == SourceTree.canonicalPath(URL(fileURLWithPath: original)))
        #expect(evidence.balancedResolvedPath == SourceTree.canonicalPath(URL(fileURLWithPath: balanced)))
        #expect(evidence.originalStamp == FileIdentityStamp.capture(path: original))

        // Every path any tool is handed is recorded. ffmpeg also re-points
        // the folder link at the twin folder before each of its passes.
        let probe = try Lab.recording("ffprobe", real: ToolLocator.ffprobePath, in: dir, name: "seen")
        let hasher = try Lab.script("seen", tool: "ffmpeg", in: dir, """
        for a in "$@"; do printf '%s\\n' "$a" >> "\(dir.path)/tools-seen/arguments"; done
        /bin/ln -sfn "\(second.path)" "\(via)"
        exec "\(ToolLocator.ffmpegPath)" "$@"
        """)
        let outcome = await Proof.measure(original: givenOriginal, balanced: givenBalanced,
                                          tools: Proof.Tools(ffmpeg: hasher, ffprobe: probe))
        #expect(outcome == .couldNotCheck("a file changed while it was being checked"))

        // Codex #301-5: what the tools were actually given. Six ffprobe runs
        // (per file: its header, what its tracks store, its packets) and two
        // ffmpeg runs, each with ONE file argument: the canonical path under
        // first/, never the given path through the link.
        let seen = try String(contentsOfFile: dir.path + "/tools-seen/arguments", encoding: .utf8)
            .split(separator: "\n").map(String.init)
        let canonicalOriginal = SourceTree.canonicalPath(URL(fileURLWithPath: original))
        let canonicalBalanced = SourceTree.canonicalPath(URL(fileURLWithPath: balanced))
        #expect(canonicalOriginal.contains("/first/") && !canonicalOriginal.contains("/via/"))
        let files = seen.filter { $0.hasSuffix(".mov") }
        #expect(files == [canonicalOriginal, canonicalOriginal, canonicalBalanced, canonicalBalanced,
                          canonicalOriginal, canonicalBalanced, canonicalOriginal, canonicalBalanced],
                "four header reads, two packet passes, two decode passes: \(files)")
        #expect(!seen.contains { $0.contains("/via/") || $0.contains("/second/") }, "a tool was handed a path through the link")
    }

    // MARK: F5 — decoder configuration

    @Test("F5: a copy with the same H.264 packets but a cropped SPS in its extradata is NOT PROVEN",
          .timeLimit(.minutes(2)))
    func croppedDecoderConfigurationIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("f5crop")
        defer { try? fm.removeItem(at: dir) }
        // H.264 with its SPS in the extradata only, and PCM sound (so the
        // lossy-sound rule does not refuse first).
        let original = try Lab.make(
            "test_h264.mov", in: dir,
            video: ["-c:v", "libx264", "-preset", "ultrafast", "-pix_fmt", "yuv420p",
                    "-x264-params", "repeat-headers=0", "-flags", "+global_header"])
        let balanced = try await Media.balance(original)
        #expect(await Proof.measure(original: original, balanced: balanced).isProven,
                "the job's own H.264 + PCM copy is the same")
        let cropped = try Media.derive("cropped_balanced", from: balanced,
                                       ["-map", "0", "-c", "copy", "-bsf:v", "h264_metadata=crop_right=16"])

        // By another road: packet for packet the same, and a narrower picture.
        let packets = await Lab.packetHash(of: original, stream: "v:0")
        #expect(packets.hasPrefix("SHA256="))
        #expect(await Lab.packetHash(of: cropped, stream: "v:0") == packets)
        #expect(await Lab.entry("width", of: original, stream: "v:0") == "320")
        #expect(await Lab.entry("width", of: cropped, stream: "v:0") == "304")

        let outcome = await Proof.measure(original: original, balanced: cropped)
        #expect(!outcome.playsTheSame, "a picture that decodes 16 pixels narrower was the same: \(outcome)")
        #expect(outcome == .notProven(.pictureConfigurationDiffers("picture stream 0: width 320 → 304")), "\(outcome)")
    }

    // MARK: F6 — channel layout

    @Test("F6: two equal channels stored as front-centre + LFE are NOT PROVEN — stereo means left + right",
          .timeLimit(.minutes(2)))
    func wrongChannelLayoutIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await plainPair("f6layout")
        defer { try? fm.removeItem(at: dir) }
        let wrong = try Media.derive(
            "wrong_layout_balanced", from: balanced,
            ["-map", "0", "-c", "copy", "-af", "channelmap=map=0|1:channel_layout=FC+LFE", "-c:a", "pcm_s16le"])

        #expect(await Lab.entry("channel_layout", of: balanced, stream: "a:0") == "stereo")
        #expect(await Lab.entry("channel_layout", of: wrong, stream: "a:0").contains("FC+LFE"))
        let live = await Lab.channelHash(of: original, channel: 0)
        #expect(live.hasPrefix("SHA256="))
        #expect(await Lab.channelHash(of: wrong, channel: 1) == live)

        let outcome = await Proof.measure(original: original, balanced: wrong)
        #expect(!outcome.playsTheSame, "centre + LFE was certified as both sides: \(outcome)")
        #expect(outcome == .notProven(.channelLayoutNotStereo(file: "the balanced copy", layout: "2 channels (FC+LFE)")))
    }

    @Test("F6: Codex's own reproduction — a WAV original and a WAV copy laid out FC+LFE — is NOT PROVEN",
          .timeLimit(.minutes(2)))
    func wrongChannelLayoutInWAVIsRefused() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let dir = try Media.scratch("f6wav")
        defer { try? fm.removeItem(at: dir) }
        let original = try Lab.make("test_original.wav", in: dir, video: nil)
        let wrong = try Media.derive("wrong_layout", from: original,
                                     ["-af", "channelmap=map=0|0:channel_layout=FC+LFE", "-c:a", "pcm_s16le"])
        #expect(await Lab.entry("channel_layout", of: wrong, stream: "a:0").contains("FC+LFE"))

        let outcome = await Proof.measure(original: original, balanced: wrong)
        #expect(!outcome.playsTheSame, "centre + LFE was certified as both sides: \(outcome)")
        #expect(outcome == .notProven(.channelLayoutNotStereo(file: "the balanced copy", layout: "2 channels (FC+LFE)")))
    }

    // MARK: F7 — cancellation

    @Test("F7: a check cancelled while the closing stamps are taken is COULD NOT CHECK, though every hash matched",
          .timeLimit(.minutes(2)))
    func cancellationDuringTheClosingStampsIsCouldNotCheck() async throws {
        try #require(BalanceAudioTestMedia.toolsAvailable)
        let (dir, original, balanced) = try await plainPair("f7cancel")
        defer { try? fm.removeItem(at: dir) }
        let calls = OSAllocatedUnfairLock(initialState: 0)

        // The seam alone changes nothing.
        let watched = Proof.Tools(ffmpeg: ToolLocator.ffmpegPath, ffprobe: ToolLocator.ffprobePath,
                                  afterFinalStamps: { calls.withLock { $0 += 1 } })
        #expect(await Proof.measure(original: original, balanced: balanced, tools: watched).isProven)
        #expect(calls.withLock { $0 } == 1, "the seam runs once, after the closing stamps")

        // Cancel exactly there: both hash passes are done, the stamps match.
        let cancelling = Proof.Tools(ffmpeg: ToolLocator.ffmpegPath, ffprobe: ToolLocator.ffprobePath,
                                     afterFinalStamps: {
                                         calls.withLock { $0 += 1 }
                                         withUnsafeCurrentTask { $0?.cancel() }
                                     })
        let task = Task { await Proof.measure(original: original, balanced: balanced, tools: cancelling) }
        let outcome = await task.value
        #expect(calls.withLock { $0 } == 2, "the check ran to its closing stamps before it was cancelled")
        #expect(outcome == .couldNotCheck("the check was stopped"))
    }
}
