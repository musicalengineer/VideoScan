// TranscodeJob+Args.swift
// The pure ffmpeg argument-vector builder for TranscodeJob — extracted
// verbatim from TranscodeJob.swift (refactor 2026-06-25). This is the
// `transcodeArgs(preset:input:output:sourceAudioIsPCM:)` static, kept as an
// extension of TranscodeJob so the existing TranscodeTests call sites are
// unchanged. No I/O, no Process spawn, no state — behavior unchanged.
// (Swift extension ≈ C++ out-of-line member definitions for the same type.)

import Foundation

// MARK: - Pure args builder
//
// Extracted as a static func so TranscodeTests can assert the args list
// without actually invoking ffmpeg (modeled on
// `ReformatJob.parseProgressSeconds`). The "never pass-through lossy
// audio" invariant lives here too — Editing/Archival hard-code their audio
// codec. A future regression that swaps in `-c:a copy` for those presets
// breaks the `transcodePreset_neverPassesThroughAudio` test loudly.

extension TranscodeJob {

    /// Build the ffmpeg argument vector for a given preset, input path, and
    /// output path. Pure — no I/O, no Process spawn. Testable.
    ///
    /// `sourceAudioIsPCM` is consulted ONLY by the `.preservation` branch
    /// (match-source audio: PCM → verbatim copy, anything else → FLAC). The
    /// editing/archival call sites keep working unchanged via the default.
    nonisolated static func transcodeArgs(preset: TranscodePreset,
                                          input: String,
                                          output: String,
                                          sourceAudioIsPCM: Bool = false) -> [String] {
        switch preset {
        case .editingLT, .editing:
            // ProRes 422 LT/HQ via Apple Silicon hardware encoder.
            //   - prores_videotoolbox profile 1 = 422 LT; profile 3 = HQ.
            //   - yuv422p10le matches the profile's chroma + bit depth.
            //   - pcm_s24le is the lossless audio FCP expects in a ProRes
            //     timeline source.
            //   - prores_metadata bitstream filter pins BT.709 color tags
            //     so FCP doesn't second-guess the color space.
            //   - +write_colr writes the QuickTime 'colr' atom so
            //     AVFoundation reads the tags back correctly.
            let profile = preset == .editingLT ? "1" : "3"
            return [
                "-hide_banner",
                "-nostdin",
                "-y",
                "-hwaccel", "videotoolbox",
                "-i", input,
                "-c:v", "prores_videotoolbox",
                "-profile:v", profile,
                "-pix_fmt", "yuv422p10le",
                "-c:a", "pcm_s24le",
                "-ar", "48000",
                "-bsf:v", "prores_metadata=color_primaries=bt709:color_trc=bt709:colorspace=bt709",
                "-movflags", "+write_colr",
                "-progress", "pipe:2",
                output
            ]

        case .archival:
            // HEVC 10-bit via Apple Silicon hardware encoder.
            //   - hevc_videotoolbox + p010le = 10-bit 4:2:0 (matches
            //     VideoToolbox's preferred input layout on M-series).
            //   - -q:v 60 is VBR quality mode — 60 = high-quality archive
            //     (≈ CRF 20 visually). Lower numbers = bigger.
            //   - -tag:v hvc1 so QuickTime/AVFoundation decode natively
            //     (without this, default 'hev1' tag forces software
            //     fallback on some Apple players).
            //   - Explicit BT.709 color tags so playback matches the
            //     source's intended color space.
            //   - aac_at = Apple AudioToolbox AAC — best-quality AAC
            //     encoder on macOS, offloads to the audio coprocessor.
            //   - +faststart moves the moov atom to the front so
            //     streaming/web-browser playback starts immediately.
            return [
                "-hide_banner",
                "-nostdin",
                "-y",
                "-hwaccel", "videotoolbox",
                "-i", input,
                "-c:v", "hevc_videotoolbox",
                "-q:v", "60",
                "-pix_fmt", "p010le",
                "-tag:v", "hvc1",
                "-color_primaries", "bt709",
                "-color_trc", "bt709",
                "-colorspace", "bt709",
                "-c:a", "aac_at",
                "-b:a", "256k",
                "-movflags", "+faststart",
                "-progress", "pipe:2",
                output
            ]

        case .preservation:
            // FFV1 v3 lossless preservation master (FADGI / Library of
            // Congress archival recipe). Software encode — there is no
            // hardware FFV1 path, and we WANT the deterministic software
            // codec for an archive deposit anyway.
            //
            // Video flags (the "why" for each, for the archive record):
            //   - ffv1 -level 3      : FFV1 version 3, the only level FADGI
            //                          and the LoC accept (self-describing
            //                          header, CRC support).
            //   - -coder 1           : range coder (better compression than
            //                          the legacy Golomb-Rice -coder 0).
            //   - -context 1         : large context model — slightly
            //                          smaller files, standard for archive.
            //   - -g 1               : GOP size 1 → every frame is an
            //                          intra frame. Mandatory for archival
            //                          so any single frame is independently
            //                          decodable / recoverable.
            //   - -slices 24         : split each frame into 24 slices.
            //                          Parallelises encode/decode AND
            //                          localises corruption to one slice.
            //   - -slicecrc 1        : per-slice CRC. This is what lets a
            //                          future reader DETECT bit rot at the
            //                          slice level — central to the
            //                          preservation use case.
            //   - NO -pix_fmt        : deliberately omitted. FFV1 supports
            //                          the source chroma + bit depth
            //                          natively; forcing a pix_fmt would
            //                          resample and DESTROY losslessness.
            //                          We preserve the source pixels exactly.
            //   - NO color flags     : VideoRecord only carries a single
            //                          coarse `colorSpace` string, not the
            //                          full primaries/trc/range triplet, so
            //                          we let ffmpeg PROPAGATE the source
            //                          color metadata rather than risk
            //                          MISLABELLING SD home video (bt601 /
            //                          smpte170m) as bt709. If/when
            //                          VideoRecord exposes the full triplet
            //                          we can emit -color_primaries /
            //                          -color_trc / -colorspace /
            //                          -color_range here to make the file
            //                          self-describing.
            //
            // Audio — "match source" (the sanctioned PCM-copy exception,
            // see the file header):
            //   - PCM source  → `-c:a copy`. The source audio is already
            //                   uncompressed; copying the verbatim bytes is
            //                   the most faithful possible preservation. This
            //                   is the ONE place -c:a copy is allowed.
            //   - everything  → `-c:a flac`. FLAC is lossless; ffmpeg can
            //     else            DECODE legacy/undecodable codecs (QDM2,
            //                     MP3, AAC, …) even when AVFoundation can't,
            //                     then re-encode losslessly. We capture the
            //                     decoded audio with zero generation loss
            //                     rather than copy a codec a future reader
            //                     might not be able to open.
            //
            //   - -map_metadata 0    : carry all source metadata into the
            //                          master (timecode, tape name, etc.).
            var args: [String] = [
                "-hide_banner",
                "-nostdin",
                "-y",
                "-i", input,
                "-map", "0:v:0",
                "-map", "0:a:0",
                "-c:v", "ffv1",
                "-level", "3",
                "-coder", "1",
                "-context", "1",
                "-g", "1",
                "-slices", "24",
                "-slicecrc", "1"
            ]
            if sourceAudioIsPCM {
                args += ["-c:a", "copy"]
            } else {
                args += ["-c:a", "flac"]
            }
            args += [
                "-map_metadata", "0",
                "-progress", "pipe:2",
                output
            ]
            return args
        }
    }
}
