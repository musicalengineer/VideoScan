import Testing
import Foundation
@testable import VideoScan

// MARK: - Transcode Tests (Pass C)
//
// Pass C of the MFO verb family (Manager dispatch 2026-06-14):
//   - New `TranscodeJob` mirroring ReformatJob's shape, two presets
//     (Editing → ProRes 422 HQ, Archival → HEVC 10-bit).
//   - Catalog row + Triage context menus get a "Transcode" sub-menu.
//   - Output suffix is `.vs.edit.mov` / `.vs.archive.mov` — lineage
//     marker we can find with `find . -name "*.vs.edit.*"`.
//
// These tests pin the pure args builder (`TranscodeJob.transcodeArgs`)
// so future regressions break loudly:
//   1. Editing args carry ProRes + PCM + the prores_metadata BSF.
//   2. Archival args carry HEVC + AAC + the hvc1 tag + faststart + the
//      color tags.
//   3. NEITHER preset ever uses `-c:a copy` — that's the QDM2-trap that
//      historically produced FCP-unplayable derivatives. Hard-coded
//      audio codecs in both presets guarantee AVFoundation can decode
//      the output.
//   4. Output suffix follows `.vs.edit.mov` / `.vs.archive.mov`.
//
// Per spec: the args helper is the test surface — actually invoking
// ffmpeg is integration-level, out of scope here.

struct TranscodeTests {

    // MARK: - Editing preset

    @Test("editing args contain ProRes 422 HQ codec, PCM audio, 10-bit pix_fmt, prores_metadata BSF")
    func transcodePreset_editingArgsContainProResAndPCM() {
        let args = TranscodeJob.transcodeArgs(
            preset: .editing,
            input: "/tmp/in.mov",
            output: "/tmp/out.vs.edit.mov"
        )

        // Video codec — ProRes via Apple Silicon hardware.
        #expect(args.contains("prores_videotoolbox"),
                "editing preset must use prores_videotoolbox; got: \(args)")
        // Profile 3 = 422 HQ (the FCP timeline default).
        #expect(adjacentPair(args, "-profile:v", "3"),
                "editing preset must specify profile 3 (422 HQ)")
        // Chroma + bit depth that ProRes 422 HQ expects.
        #expect(args.contains("yuv422p10le"),
                "editing preset must use yuv422p10le pix_fmt")
        // Audio: lossless PCM.
        #expect(args.contains("pcm_s24le"),
                "editing preset must use pcm_s24le; got: \(args)")
        // BT.709 color tagging via the prores_metadata bitstream filter
        // — the part that lets FCP read the color space correctly.
        let bsfArg = args.first { $0.hasPrefix("prores_metadata=") }
        #expect(bsfArg != nil,
                "editing preset must apply the prores_metadata BSF for BT.709 tagging")
        #expect(bsfArg?.contains("color_primaries=bt709") == true)
        #expect(bsfArg?.contains("color_trc=bt709") == true)
        #expect(bsfArg?.contains("colorspace=bt709") == true)
        // Progress channel — same as Reformat, parsed by ReformatJob.parseProgressSeconds.
        #expect(adjacentPair(args, "-progress", "pipe:2"))
    }

    @Test("editing LT uses VideoToolbox ProRes profile 1 with PCM audio")
    func transcodePreset_editingLTArgsContainProResAndPCM() {
        let args = TranscodeJob.transcodeArgs(
            preset: .editingLT,
            input: "/tmp/in.mov",
            output: "/tmp/out.vs.edit.mov"
        )

        #expect(args.contains("prores_videotoolbox"))
        #expect(adjacentPair(args, "-profile:v", "1"),
                "editing LT must specify profile 1")
        #expect(args.contains("yuv422p10le"))
        #expect(args.contains("pcm_s24le"))
        #expect(adjacentPair(args, "-hwaccel", "videotoolbox"))
    }

    // MARK: - Archival preset

    @Test("archival args contain HEVC 10-bit codec, AAC audio, hvc1 tag, faststart, BT.709 color tags")
    func transcodePreset_archivalArgsContainHEVCAndAAC() {
        let args = TranscodeJob.transcodeArgs(
            preset: .archival,
            input: "/tmp/in.mov",
            output: "/tmp/out.vs.archive.mov"
        )

        // Video codec — HEVC via Apple Silicon hardware.
        #expect(args.contains("hevc_videotoolbox"),
                "archival preset must use hevc_videotoolbox; got: \(args)")
        // Audio: Apple AudioToolbox AAC encoder.
        #expect(args.contains("aac_at"),
                "archival preset must use aac_at; got: \(args)")
        // 10-bit 4:2:0 — matches VideoToolbox HEVC's preferred input.
        #expect(args.contains("p010le"),
                "archival preset must use p010le pix_fmt")
        // -tag:v hvc1 so QuickTime/AVFoundation decode natively.
        #expect(adjacentPair(args, "-tag:v", "hvc1"),
                "archival preset must tag the stream as hvc1 for AVFoundation native decode")
        // +faststart so streaming/web playback starts immediately.
        let movflagsValue = valueAfter(args, "-movflags")
        #expect(movflagsValue?.contains("+faststart") == true,
                "archival preset must include +faststart in -movflags")
        // BT.709 color tagging — explicit -color_* args (not a BSF).
        #expect(adjacentPair(args, "-color_primaries", "bt709"))
        #expect(adjacentPair(args, "-color_trc", "bt709"))
        #expect(adjacentPair(args, "-colorspace", "bt709"))
        // Progress channel.
        #expect(adjacentPair(args, "-progress", "pipe:2"))
    }

    // MARK: - Never pass-through audio

    @Test("neither preset ever uses -c:a copy (QDM2-trap guard)")
    func transcodePreset_neverPassesThroughAudio() {
        // The historical bug: passing through a dead audio codec like
        // QDM2 silently produced FCP-unplayable derivatives. Every
        // playback preset must hard-code its audio codec (PCM or AAC).
        for preset in [
            TranscodePreset.editingLT,
            TranscodePreset.editing,
            TranscodePreset.archival
        ] {
            let args = TranscodeJob.transcodeArgs(
                preset: preset,
                input: "/tmp/in.mov",
                output: "/tmp/out.mov"
            )
            // We're looking for the literal sequence "-c:a", "copy"
            // anywhere in the vector. Use adjacentPair so a future
            // regression that puts "copy" elsewhere (e.g. as a video
            // codec value) isn't a false positive.
            #expect(!adjacentPair(args, "-c:a", "copy"),
                    "\(preset.rawValue) preset must never pass through audio (regression risk: QDM2 → FCP can't play)")
        }
    }

    // MARK: - Preservation preset (Pass C.1 — FFV1 v3 master)
    //
    // The preservation master is the safety-critical recipe (possible
    // Library of Congress deposit). These tests pin the exact FFV1 v3
    // flag set FADGI/LoC require, prove we DON'T resample (no -pix_fmt,
    // no hardcoded color flags — that would destroy losslessness), and
    // pin the match-source audio decision (PCM → verbatim copy, else
    // FLAC).

    @Test("preservation args contain the FFV1 v3 flag set in order, -map_metadata 0, and an .mkv output")
    func transcodePreset_preservationArgsContainFFV1v3() {
        let args = TranscodeJob.transcodeArgs(
            preset: .preservation,
            input: "/tmp/in.mov",
            output: "/tmp/out.vs.preserve.mkv"
        )

        // The mandatory FFV1 v3 video flag pairs (each is `-flag value`
        // adjacent in the vector).
        #expect(adjacentPair(args, "-c:v", "ffv1"),
                "preservation must encode video as ffv1; got: \(args)")
        #expect(adjacentPair(args, "-level", "3"),
                "preservation must use FFV1 level 3 (the only level FADGI/LoC accept)")
        #expect(adjacentPair(args, "-coder", "1"),
                "preservation must use the range coder (-coder 1)")
        #expect(adjacentPair(args, "-context", "1"),
                "preservation must use the large context model (-context 1)")
        #expect(adjacentPair(args, "-g", "1"),
                "preservation must force GOP 1 (every frame intra)")
        #expect(adjacentPair(args, "-slices", "24"),
                "preservation must split frames into 24 slices")
        #expect(adjacentPair(args, "-slicecrc", "1"),
                "preservation must enable per-slice CRC for bit-rot detection")
        #expect(adjacentPair(args, "-map_metadata", "0"),
                "preservation must carry all source metadata (-map_metadata 0)")

        // Relative ORDER: ffmpeg applies these per output stream and the
        // recipe documents them in this sequence — pin it so a reorder
        // (which could silently change codec init) breaks loudly. We
        // assert the codec selector precedes its tuning flags, the tuning
        // flags precede -map_metadata, and -map_metadata precedes output.
        #expect(orderedFlags(args, ["-c:v", "-level", "-coder", "-context", "-g", "-slices", "-slicecrc", "-map_metadata"]),
                "preservation video flags must appear in the documented order; got: \(args)")

        // -map streams: explicit first video + first audio stream. There
        // are TWO `-map` flags, so adjacentPair (first-occurrence only)
        // can't see the audio map — check each `-map`'s value pairs up
        // with the right stream specifier directly.
        let mapValues = flagValues(args, "-map")
        #expect(mapValues == ["0:v:0", "0:a:0"],
                "preservation must map first video then first audio stream; got -map values: \(mapValues)")

        // Output container is Matroska (.mkv) — QuickTime can't hold FFV1.
        #expect(args.last == "/tmp/out.vs.preserve.mkv",
                "preservation output must be the final arg and end in .mkv; got: \(String(describing: args.last))")
    }

    @Test("preservation args OMIT -pix_fmt and all hardcoded color flags (preserve source pixels exactly)")
    func transcodePreset_preservationOmitsPixFmtAndColorFlags() {
        let args = TranscodeJob.transcodeArgs(
            preset: .preservation,
            input: "/tmp/in.mov",
            output: "/tmp/out.vs.preserve.mkv"
        )

        // -pix_fmt is DELIBERATELY absent: forcing a pixel format would
        // resample the source chroma/depth and destroy losslessness.
        #expect(!args.contains("-pix_fmt"),
                "preservation must NOT force a pix_fmt (would resample and break losslessness); got: \(args)")

        // No hardcoded color flags either — VideoRecord only carries a
        // coarse colorSpace string, so we let ffmpeg propagate the source
        // color metadata rather than risk mislabelling SD home video.
        #expect(!args.contains("-color_primaries"),
                "preservation must NOT hardcode -color_primaries")
        #expect(!args.contains("-color_trc"),
                "preservation must NOT hardcode -color_trc")
        #expect(!args.contains("-colorspace"),
                "preservation must NOT hardcode -colorspace")
        #expect(!args.contains("-color_range"),
                "preservation must NOT hardcode -color_range")
    }

    @Test("preservation with PCM source copies audio verbatim (-c:a copy), not FLAC")
    func transcodePreset_preservationPCMCopiesAudio() {
        let args = TranscodeJob.transcodeArgs(
            preset: .preservation,
            input: "/tmp/in.mov",
            output: "/tmp/out.vs.preserve.mkv",
            sourceAudioIsPCM: true
        )
        // PCM source → verbatim copy is the ONE sanctioned -c:a copy: the
        // source is already uncompressed, so a byte copy is the most
        // faithful possible preservation.
        #expect(adjacentPair(args, "-c:a", "copy"),
                "preservation with PCM source must copy audio verbatim; got: \(args)")
        #expect(!adjacentPair(args, "-c:a", "flac"),
                "preservation with PCM source must NOT re-encode to FLAC; got: \(args)")
    }

    @Test("preservation with non-PCM source re-encodes audio to FLAC, never -c:a copy")
    func transcodePreset_preservationNonPCMUsesFLAC() {
        // Default sourceAudioIsPCM == false → FLAC. This is the path that
        // losslessly decodes legacy/undecodable codecs (QDM2, MP3, AAC)
        // rather than copying a codec a future reader might not open.
        let args = TranscodeJob.transcodeArgs(
            preset: .preservation,
            input: "/tmp/in.mov",
            output: "/tmp/out.vs.preserve.mkv",
            sourceAudioIsPCM: false
        )
        #expect(adjacentPair(args, "-c:a", "flac"),
                "preservation with non-PCM source must re-encode to FLAC; got: \(args)")
        #expect(!adjacentPair(args, "-c:a", "copy"),
                "preservation with non-PCM source must NOT pass through audio; got: \(args)")
    }

    // MARK: - Audio-invariant regression (companion to neverPassesThroughAudio)
    //
    // The original `transcodePreset_neverPassesThroughAudio` covers ONLY
    // editing + archival, and that scope is still exactly right — those
    // are the playback derivatives the QDM2-trap invariant protects.
    // Preservation is the sanctioned exception (PCM-verbatim into a
    // master is the OPPOSITE intent — see TranscodeJob header), so we do
    // NOT widen the original test to include it. Instead this companion
    // pins the FULL invariant across ALL THREE presets: `-c:a copy`
    // appears for `.preservation`+PCM ONLY, and nowhere else.

    @Test("-c:a copy appears ONLY for preservation+PCM, never for editing/archival under any audio source")
    func transcodePreset_copyAudioOnlyForPreservationPCM() {
        // Editing + archival: never -c:a copy, regardless of the PCM flag
        // (they ignore it — pinning that they ignore it is the point).
        for preset in [
            TranscodePreset.editingLT,
            TranscodePreset.editing,
            TranscodePreset.archival
        ] {
            for pcm in [false, true] {
                let args = TranscodeJob.transcodeArgs(
                    preset: preset,
                    input: "/tmp/in.mov",
                    output: "/tmp/out.mov",
                    sourceAudioIsPCM: pcm
                )
                #expect(!adjacentPair(args, "-c:a", "copy"),
                        "\(preset.rawValue) (sourceAudioIsPCM=\(pcm)) must never pass through audio")
            }
        }
        // Preservation: -c:a copy is allowed ONLY when PCM, FLAC otherwise.
        let presPCM = TranscodeJob.transcodeArgs(
            preset: .preservation, input: "/tmp/in.mov",
            output: "/tmp/o.mkv", sourceAudioIsPCM: true)
        #expect(adjacentPair(presPCM, "-c:a", "copy"))

        let presNonPCM = TranscodeJob.transcodeArgs(
            preset: .preservation, input: "/tmp/in.mov",
            output: "/tmp/o.mkv", sourceAudioIsPCM: false)
        #expect(!adjacentPair(presNonPCM, "-c:a", "copy"))
    }

    // MARK: - fileExtension property

    @Test("fileExtension is mov for editing variants/archival and mkv for preservation")
    func transcodePreset_fileExtension() {
        #expect(TranscodePreset.editingLT.fileExtension == "mov",
                "editing LT container must be .mov (ProRes in QuickTime)")
        #expect(TranscodePreset.editing.fileExtension == "mov",
                "editing container must be .mov (ProRes in QuickTime)")
        #expect(TranscodePreset.archival.fileExtension == "mov",
                "archival container must be .mov (HEVC+AAC in QuickTime)")
        #expect(TranscodePreset.preservation.fileExtension == "mkv",
                "preservation container must be .mkv (FFV1+FLAC in Matroska)")
    }

    // MARK: - Output suffix

    // @MainActor: TranscodeJob.init and VideoScanModel.init are both
    // MainActor-isolated; Swift Testing runs tests on a background actor
    // by default, so we hop to the main actor here. (Marking the suite
    // itself MainActor would force the same hop on every test, including
    // the pure args tests above which don't need it.)
    @Test("TranscodeJob preserves the explicitly selected destination")
    @MainActor
    func transcodeOutputSuffix() {
        let recA = VideoRecord()
        recA.fullPath = "/Volumes/Crucial2TB/family/thanksgiving_1998.mov"
        let editingURL = URL(fileURLWithPath: "/Volumes/FastSSD/Edits/thanksgiving_1998.vs.edit.mov")
        let editingJob = TranscodeJob(
            record: recA,
            preset: .editing,
            outputURL: editingURL,
            model: VideoScanModel()
        )
        #expect(editingJob.outputURL.lastPathComponent == "thanksgiving_1998.vs.edit.mov",
                "editing output should be <stem>.vs.edit.mov; got \(editingJob.outputURL.lastPathComponent)")
        #expect(editingJob.outputURL.deletingLastPathComponent().path == "/Volumes/FastSSD/Edits")

        let recB = VideoRecord()
        recB.fullPath = "/Volumes/Crucial2TB/family/thanksgiving_1998.mov"
        let archivalJob = TranscodeJob(
            record: recB,
            preset: .archival,
            outputURL: URL(fileURLWithPath: "/tmp/thanksgiving_1998.vs.archive.mov"),
            model: VideoScanModel()
        )
        #expect(archivalJob.outputURL.lastPathComponent == "thanksgiving_1998.vs.archive.mov",
                "archival output should be <stem>.vs.archive.mov; got \(archivalJob.outputURL.lastPathComponent)")

        let recC = VideoRecord()
        recC.fullPath = "/Volumes/Crucial2TB/family/thanksgiving_1998.mov"
        let preserveJob = TranscodeJob(
            record: recC,
            preset: .preservation,
            outputURL: URL(fileURLWithPath: "/tmp/thanksgiving_1998.vs.preserve.mkv"),
            model: VideoScanModel()
        )
        #expect(preserveJob.outputURL.lastPathComponent == "thanksgiving_1998.vs.preserve.mkv",
                "preservation output should be <stem>.vs.preserve.mkv; got \(preserveJob.outputURL.lastPathComponent)")
    }

    @Test("destination naming and extension enforcement match each preset")
    @MainActor
    func transcodeDestinationNaming() {
        let record = VideoRecord()
        record.fullPath = "/Volumes/SlowHDD/Cape/tape.01.mkv"

        #expect(
            TranscodeDestination.suggestedFilename(for: record, preset: .editing)
                == "tape.01.vs.edit.mov"
        )
        #expect(
            TranscodeDestination.enforcingFileExtension(
                URL(fileURLWithPath: "/Volumes/FastSSD/custom-name.mp4"),
                preset: .editing
            ).path == "/Volumes/FastSSD/custom-name.mov"
        )
        #expect(
            TranscodeDestination.enforcingFileExtension(
                URL(fileURLWithPath: "/Volumes/FastSSD/master.MKV"),
                preset: .preservation
            ).path == "/Volumes/FastSSD/master.MKV"
        )
    }

    // MARK: - compareFrameMD5 (safety-critical lossless proof)
    //
    // The verify core: decode source + master to per-frame MD5 and prove
    // every hash matches. These fixtures use realistic framemd5 lines —
    // `<stream>, <pts>, <dts>, <duration>, <size>, <hash>` — plus the
    // `#`-prefixed header lines ffmpeg emits. The compare must ignore the
    // headers and key entirely on the LAST token (the hash) of each
    // remaining line.
    //
    // Implementation behavior pinned here (read from TranscodeJob.swift,
    // not assumed):
    //   - differing frame COUNTS (output truncated) → `.malformed`
    //     ("frame count mismatch…"), but only AFTER the overlapping
    //     prefix is checked, so a real per-frame divergence in the
    //     prefix still wins and returns `.mismatch`.
    //   - either side empty → `.malformed`.
    //   - both empty → `.malformed` ("both … were empty").

    /// Build a framemd5 body: standard `#` header block + one data line
    /// per hash. (≈ assembling a fixture string from a vector<string>.)
    private func framemd5Body(hashes: [String],
                              header: [String] = ["# software: Lavf",
                                                  "# tb 0: 1/30",
                                                  "# media_type 0: video"]) -> String {
        var lines = header
        for (i, h) in hashes.enumerated() {
            // 0, <pts>, <dts>, 1, 6220800, <hash>
            lines.append("0,        \(i),        \(i),        1,  6220800, \(h)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    @Test("compareFrameMD5: identical streams (incl. identical headers) → .match")
    func compareFrameMD5_identicalMatches() {
        let hashes = ["d41d8cd98f00b204e9800998ecf8427e",
                      "9e107d9d372bb6826bd81d3542a419d6",
                      "0cc175b9c0f1b6a831c399e269772661"]
        let s = framemd5Body(hashes: hashes)
        let o = framemd5Body(hashes: hashes)
        #expect(TranscodeJob.compareFrameMD5(source: s, output: o) == .match)
    }

    @Test("compareFrameMD5: a single divergent middle frame → .mismatch with the right 0-based index and hashes")
    func compareFrameMD5_middleMismatch() {
        let src = ["aaaa0000aaaa0000aaaa0000aaaa0000",
                   "bbbb1111bbbb1111bbbb1111bbbb1111",
                   "cccc2222cccc2222cccc2222cccc2222",
                   "dddd3333dddd3333dddd3333dddd3333"]
        var out = src
        out[2] = "ffffffffffffffffffffffffffffffff" // diverge at frame 2
        let verdict = TranscodeJob.compareFrameMD5(
            source: framemd5Body(hashes: src),
            output: framemd5Body(hashes: out))
        #expect(verdict == .mismatch(frameIndex: 2,
                                     source: "cccc2222cccc2222cccc2222cccc2222",
                                     output: "ffffffffffffffffffffffffffffffff"),
                "expected mismatch at frame 2; got \(verdict)")
    }

    @Test("compareFrameMD5: divergence at the very first frame → .mismatch(frameIndex: 0, …)")
    func compareFrameMD5_firstFrameMismatch() {
        let src = ["1111111111111111aaaa1111aaaa1111",
                   "2222222222222222bbbb2222bbbb2222"]
        var out = src
        out[0] = "0000000000000000dead0000dead0000"
        let verdict = TranscodeJob.compareFrameMD5(
            source: framemd5Body(hashes: src),
            output: framemd5Body(hashes: out))
        #expect(verdict == .mismatch(frameIndex: 0,
                                     source: "1111111111111111aaaa1111aaaa1111",
                                     output: "0000000000000000dead0000dead0000"),
                "expected mismatch at frame 0; got \(verdict)")
    }

    @Test("compareFrameMD5: header/comment lines differ but all hashes match → .match (headers ignored)")
    func compareFrameMD5_headersIgnored() {
        let hashes = ["1234abcd1234abcd1234abcd1234abcd",
                      "5678ef905678ef905678ef905678ef90"]
        // Different software/tb header lines on each side; the hashes are
        // identical, so the verdict must be .match.
        let s = framemd5Body(hashes: hashes,
                             header: ["# software: ffmpeg-git",
                                      "# tb 0: 1/30000",
                                      "# media_type 0: video"])
        let o = framemd5Body(hashes: hashes,
                             header: ["# software: Lavf61.7.100",
                                      "# tb 0: 1/25",
                                      "# stream 0 differs entirely here"])
        #expect(TranscodeJob.compareFrameMD5(source: s, output: o) == .match)
    }

    @Test("compareFrameMD5: truncated output (fewer frames, matching prefix) → .malformed (frame count mismatch)")
    func compareFrameMD5_truncatedOutputMalformed() {
        let src = ["a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0a0",
                   "b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1b1",
                   "c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2c2"]
        let out = Array(src.prefix(2)) // output truncated, prefix matches
        let verdict = TranscodeJob.compareFrameMD5(
            source: framemd5Body(hashes: src),
            output: framemd5Body(hashes: out))
        // Implementation checks the overlapping prefix first (all match),
        // THEN reports the count mismatch as .malformed — NOT .mismatch.
        switch verdict {
        case .malformed(let why):
            #expect(why.contains("frame count mismatch"),
                    "expected a frame-count-mismatch malformed verdict; got: \(why)")
            #expect(why.contains("3") && why.contains("2"),
                    "malformed message should report 3 vs 2 frames; got: \(why)")
        default:
            Issue.record("expected .malformed for truncated output, got \(verdict)")
        }
    }

    @Test("compareFrameMD5: divergence inside the prefix beats a trailing count mismatch → .mismatch")
    func compareFrameMD5_prefixDivergenceBeatsCountMismatch() {
        // Source longer than output AND a real divergence at frame 1.
        // The earliest real divergence must win over the count mismatch.
        let src = ["00aaaa0000aaaa0000aaaa0000aaaa00",
                   "11bbbb1111bbbb1111bbbb1111bbbb11",
                   "22cccc2222cccc2222cccc2222cccc22"]
        let out = ["00aaaa0000aaaa0000aaaa0000aaaa00",
                   "deadbeefdeadbeefdeadbeefdeadbeef"] // diverges at 1, also shorter
        let verdict = TranscodeJob.compareFrameMD5(
            source: framemd5Body(hashes: src),
            output: framemd5Body(hashes: out))
        #expect(verdict == .mismatch(frameIndex: 1,
                                     source: "11bbbb1111bbbb1111bbbb1111bbbb11",
                                     output: "deadbeefdeadbeefdeadbeefdeadbeef"),
                "earliest real divergence must win over a trailing count mismatch; got \(verdict)")
    }

    @Test("compareFrameMD5: output side has no frame hashes → .malformed")
    func compareFrameMD5_emptyOutputMalformed() {
        let src = framemd5Body(hashes: ["aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"])
        // Output is header-only (no data lines) — parses to zero hashes.
        let outHeaderOnly = "# software: Lavf\n# tb 0: 1/30\n"
        let verdict = TranscodeJob.compareFrameMD5(source: src, output: outHeaderOnly)
        switch verdict {
        case .malformed(let why):
            #expect(why.contains("output"),
                    "expected the malformed message to name the output side; got: \(why)")
        default:
            Issue.record("expected .malformed for empty output, got \(verdict)")
        }
    }

    @Test("compareFrameMD5: source side has no frame hashes → .malformed")
    func compareFrameMD5_emptySourceMalformed() {
        let srcHeaderOnly = "# software: Lavf\n# tb 0: 1/30\n"
        let out = framemd5Body(hashes: ["bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"])
        let verdict = TranscodeJob.compareFrameMD5(source: srcHeaderOnly, output: out)
        switch verdict {
        case .malformed(let why):
            #expect(why.contains("source"),
                    "expected the malformed message to name the source side; got: \(why)")
        default:
            Issue.record("expected .malformed for empty source, got \(verdict)")
        }
    }

    @Test("compareFrameMD5: both sides empty → .malformed (both empty)")
    func compareFrameMD5_bothEmptyMalformed() {
        // Truly empty strings (no headers, no data) on both sides.
        let verdict = TranscodeJob.compareFrameMD5(source: "", output: "")
        switch verdict {
        case .malformed(let why):
            #expect(why.contains("both"),
                    "expected a 'both empty' malformed verdict; got: \(why)")
        default:
            Issue.record("expected .malformed for both-empty input, got \(verdict)")
        }
    }

    // MARK: - parseStreamMD5 (whole-stream audio verify — Rick 2026-06-18)
    //
    // Audio is verified by a single whole-stream `-f md5` (packetization-
    // invariant) rather than per-frame framemd5, so a MOV→MKV PCM re-block
    // can't false-fail bit-identical audio. parseStreamMD5 pulls the digest
    // out of the muxer's `MD5=<hex>` line. The empty-on-absent contract is
    // load-bearing: the verify guard treats "" as failure, so two failed
    // decodes must NOT look like equal (matching) empties.

    @Test("parseStreamMD5 extracts and lower-cases the hex digest from an MD5= line")
    func parseStreamMD5_extractsDigest() {
        #expect(TranscodeJob.parseStreamMD5("MD5=D41D8CD98F00B204E9800998ECF8427E\n")
                == "d41d8cd98f00b204e9800998ecf8427e")
    }

    @Test("parseStreamMD5 finds the MD5 line amid ffmpeg banner/progress noise")
    func parseStreamMD5_ignoresSurroundingLines() {
        let out = """
        frame=  100 fps=0.0 q=-0.0 size=N/A time=00:00:04.00
        progress=continue
        MD5=0123456789abcdef0123456789abcdef
        progress=end
        """
        #expect(TranscodeJob.parseStreamMD5(out) == "0123456789abcdef0123456789abcdef")
    }

    @Test("parseStreamMD5 returns empty string when no MD5 line is present (decode failure → loud fail)")
    func parseStreamMD5_emptyWhenAbsent() {
        #expect(TranscodeJob.parseStreamMD5("").isEmpty)
        #expect(TranscodeJob.parseStreamMD5("progress=end\nframe=0\n").isEmpty)
    }

    @Test("the verify guard fails (not matches) when both decodes produce no hash")
    func parseStreamMD5_emptyDoesNotFalseMatch() {
        // Mirrors verifyLossless's guard: src.isEmpty || out.isEmpty || src != out.
        let src = TranscodeJob.parseStreamMD5("garbage, no hash")
        let out = TranscodeJob.parseStreamMD5("also nothing")
        let wouldFail = src.isEmpty || out.isEmpty || src != out
        #expect(wouldFail, "two failed decodes must fail verification, not silently 'match' as equal empties")
    }

    // MARK: - pcmCodecForProbe (audio compare-depth matching — Rick 2026-06-18)
    //
    // Audio is hashed in an EXPLICIT integer PCM format matched to the
    // master's bit depth, so AAC/MP3 (float-native) sources and their FLAC
    // masters are compared like-for-like instead of float-vs-int (which
    // always false-mismatched). bits_per_raw_sample wins; sample_fmt is the
    // fallback; pcm_s24le is the default (the FLAC capture depth).

    @Test("pcmCodecForProbe maps a 24-bit FLAC master (s32 fmt, 24 raw bits) to pcm_s24le")
    func pcmCodecForProbe_flac24() {
        #expect(TranscodeJob.pcmCodecForProbe("bits_per_raw_sample=24\nsample_fmt=s32") == "pcm_s24le")
    }

    @Test("pcmCodecForProbe maps bit depths: 16→s16le, 24→s24le, 32→s32le")
    func pcmCodecForProbe_byBits() {
        #expect(TranscodeJob.pcmCodecForProbe("bits_per_raw_sample=16") == "pcm_s16le")
        #expect(TranscodeJob.pcmCodecForProbe("bits_per_raw_sample=24") == "pcm_s24le")
        #expect(TranscodeJob.pcmCodecForProbe("bits_per_raw_sample=32") == "pcm_s32le")
    }

    @Test("pcmCodecForProbe falls back to sample_fmt when bits are absent")
    func pcmCodecForProbe_byFmtFallback() {
        #expect(TranscodeJob.pcmCodecForProbe("sample_fmt=s16") == "pcm_s16le")
        #expect(TranscodeJob.pcmCodecForProbe("sample_fmt=s32p") == "pcm_s32le")
    }

    @Test("pcmCodecForProbe defaults to pcm_s24le for float/unknown/empty probes")
    func pcmCodecForProbe_defaults() {
        #expect(TranscodeJob.pcmCodecForProbe("sample_fmt=fltp") == "pcm_s24le")
        #expect(TranscodeJob.pcmCodecForProbe("") == "pcm_s24le")
        #expect(TranscodeJob.pcmCodecForProbe("garbage") == "pcm_s24le")
    }

    // MARK: - Helpers
    //
    // Pure little helpers for "did we emit `-flag value` adjacent in the
    // args vector" so the tests don't have to fall back on
    // `joined(separator:)` substring checks (which would false-pass on
    // accidental concatenations). (Swift's value-type Array<String> ≈
    // std::vector<std::string> — indexing + count are O(1).)

    private func adjacentPair(_ args: [String], _ flag: String, _ value: String) -> Bool {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return false }
        return args[idx + 1] == value
    }

    private func valueAfter(_ args: [String], _ flag: String) -> String? {
        guard let idx = args.firstIndex(of: flag), idx + 1 < args.count else { return nil }
        return args[idx + 1]
    }

    /// The value token following EVERY occurrence of `flag`, in order.
    /// (adjacentPair/valueAfter only see the first — `-map` appears twice
    /// in the preservation recipe.)
    private func flagValues(_ args: [String], _ flag: String) -> [String] {
        var out: [String] = []
        for (i, a) in args.enumerated() where a == flag && i + 1 < args.count {
            out.append(args[i + 1])
        }
        return out
    }

    /// True iff every flag in `flags` is present in `args` AND their first
    /// occurrences appear in the given relative order. Used to pin the
    /// FFV1 v3 flag sequence so a reorder breaks loudly. (≈ asserting a
    /// monotonically increasing sequence of std::find positions.)
    private func orderedFlags(_ args: [String], _ flags: [String]) -> Bool {
        var lastIdx = -1
        for flag in flags {
            guard let idx = args.firstIndex(of: flag) else { return false }
            if idx <= lastIdx { return false }
            lastIdx = idx
        }
        return true
    }
}
