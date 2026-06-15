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
        // QDM2 silently produced FCP-unplayable derivatives. Both
        // presets must hard-code their audio codec (PCM or AAC).
        for preset in [TranscodePreset.editing, TranscodePreset.archival] {
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

    // MARK: - Output suffix

    // @MainActor: TranscodeJob.init and VideoScanModel.init are both
    // MainActor-isolated; Swift Testing runs tests on a background actor
    // by default, so we hop to the main actor here. (Marking the suite
    // itself MainActor would force the same hop on every test, including
    // the pure args tests above which don't need it.)
    @Test("output URL ends in .vs.edit.mov for editing preset and .vs.archive.mov for archival preset")
    @MainActor
    func transcodeOutputSuffix() {
        // Build minimal VideoRecords; we just need fullPath set so the
        // TranscodeJob init can derive the output URL beside the source.
        let recA = VideoRecord()
        recA.fullPath = "/Volumes/Crucial2TB/family/thanksgiving_1998.mov"
        let editingJob = TranscodeJob(record: recA, preset: .editing, model: VideoScanModel())
        #expect(editingJob.outputURL.lastPathComponent == "thanksgiving_1998.vs.edit.mov",
                "editing output should be <stem>.vs.edit.mov; got \(editingJob.outputURL.lastPathComponent)")

        let recB = VideoRecord()
        recB.fullPath = "/Volumes/Crucial2TB/family/thanksgiving_1998.mov"
        let archivalJob = TranscodeJob(record: recB, preset: .archival, model: VideoScanModel())
        #expect(archivalJob.outputURL.lastPathComponent == "thanksgiving_1998.vs.archive.mov",
                "archival output should be <stem>.vs.archive.mov; got \(archivalJob.outputURL.lastPathComponent)")

        // Both must land beside the source.
        #expect(editingJob.outputURL.deletingLastPathComponent().path == "/Volumes/Crucial2TB/family")
        #expect(archivalJob.outputURL.deletingLastPathComponent().path == "/Volumes/Crucial2TB/family")
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
}
