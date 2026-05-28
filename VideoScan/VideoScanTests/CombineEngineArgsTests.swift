import Testing
import Foundation
@testable import VideoScan

// MARK: - CombineEngineArgsTests
//
// Locks in the ffmpeg encoder + flag choices for each CombineTechnique so
// a typo or a future flag change (e.g. swapping prores_videotoolbox back
// to prores_ks, or losing the -q:v on h264_videotoolbox) gets caught at
// test time rather than the next time someone runs an overnight Combine
// All and finds out their archival ProRes was actually software-encoded
// and took 5× longer than expected.
//
// Hardware-encoder swap landed 2026-05-27 in commit <pending>.
// See [[project_archive_combine_pipeline_order]] step 1.

struct CombineEngineArgsTests {

    private func args(for technique: CombineJobStatus.CombineTechnique,
                      withProgress: Bool = false) -> [String] {
        CombineEngine.buildArgs(
            videoPath: "/tmp/v.mxf",
            audioPath: "/tmp/a.mxf",
            outputPath: "/tmp/out.mov",
            technique: technique,
            withProgress: withProgress
        )
    }

    // MARK: - Stream Copy (unchanged — pure mux)

    @Test
    func streamCopyUsesCopyCodec() {
        let a = args(for: .streamCopy)
        // Must NOT contain any encoder reference; pure copy.
        #expect(a.contains("copy"))
        #expect(!a.contains("prores_videotoolbox"))
        #expect(!a.contains("h264_videotoolbox"))
        #expect(!a.contains("libx264"))
        // Specifically: -c:v copy -c:a copy
        #expect(consecutive(a, "-c:v", "copy"))
        #expect(consecutive(a, "-c:a", "copy"))
    }

    // MARK: - ProRes — hardware encoder

    @Test
    func proResUsesVideoToolboxHardwareEncoder() {
        let a = args(for: .reencodeProRes)
        // Critical: prores_videotoolbox, NOT prores_ks (software).
        #expect(consecutive(a, "-c:v", "prores_videotoolbox"),
                "ProRes must use the hardware encoder on Apple Silicon — prores_ks is software-only and ~3-5× slower")
        #expect(!a.contains("prores_ks"), "prores_ks must not reappear without explicit re-evaluation")
        // Profile 3 = ProRes 422 HQ, the archival mezzanine target.
        #expect(consecutive(a, "-profile:v", "3"))
        // PCM audio for mezzanine quality.
        #expect(consecutive(a, "-c:a", "pcm_s24le"))
    }

    // MARK: - H.264 — hardware encoder

    @Test
    func h264UsesVideoToolboxHardwareEncoder() {
        let a = args(for: .reencodeH264)
        #expect(consecutive(a, "-c:v", "h264_videotoolbox"),
                "H.264 must use the hardware encoder — libx264 is software-only")
        #expect(!a.contains("libx264"))
        // Quality target. h264_videotoolbox uses -q:v (0-100, higher = better),
        // not -crf. If this fails, someone re-introduced an x264-only flag.
        #expect(consecutive(a, "-q:v", "70"))
        #expect(!a.contains("-crf"), "h264_videotoolbox does not accept -crf; that flag belongs to libx264")
        #expect(!a.contains("-preset"), "h264_videotoolbox does not accept -preset")
        // AAC audio at the existing bitrate.
        #expect(consecutive(a, "-c:a", "aac"))
        #expect(consecutive(a, "-b:a", "256k"))
    }

    // MARK: - Container + I/O invariants (all techniques)

    @Test
    func allTechniquesProduceMovWithFaststartAndCorrectIO() {
        for tech in [CombineJobStatus.CombineTechnique.streamCopy,
                     .reencodeProRes,
                     .reencodeH264] {
            let a = args(for: tech)
            #expect(consecutive(a, "-f", "mov"), "\(tech): output container must be mov")
            #expect(consecutive(a, "-movflags", "+faststart"),
                    "\(tech): +faststart for streaming-friendly mov layout")
            #expect(consecutive(a, "-i", "/tmp/v.mxf"), "\(tech): video input")
            #expect(consecutive(a, "-i", "/tmp/a.mxf"), "\(tech): audio input")
            #expect(consecutive(a, "-map", "0:v"), "\(tech): video from input 0")
            #expect(consecutive(a, "-map", "1:a"), "\(tech): audio from input 1")
            #expect(a.last == "/tmp/out.mov", "\(tech): output path must be the trailing positional arg")
            #expect(a.first == "-y", "\(tech): -y to overwrite must be first")
        }
    }

    @Test
    func progressFlagOnlyAppearsWhenRequested() {
        let withFlag = args(for: .streamCopy, withProgress: true)
        let withoutFlag = args(for: .streamCopy, withProgress: false)
        #expect(consecutive(withFlag, "-progress", "pipe:1"))
        #expect(!withoutFlag.contains("-progress"))
    }

    // MARK: - Helper

    /// True if `pair` appears as adjacent elements in `args`.
    private func consecutive(_ args: [String], _ a: String, _ b: String) -> Bool {
        for i in args.indices.dropLast() where args[i] == a && args[i + 1] == b {
            return true
        }
        return false
    }
}
