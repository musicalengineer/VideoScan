import Foundation
import os

// MARK: - CleanupFFmpegEngine
//
// The v1 CleanupRecipeEngine: renders a recipe as ONE single-pass ffmpeg
// filtergraph. Every step compiles to a filter chain segment; segments
// join in recipe order. Output is ProRes 422 LT via the Apple Silicon
// hardware encoder (matches TranscodePreset.editingLT's codec choice) in
// a .mov container. AUDIO (M4, QA+Manager amendment 2026-07-07):
// stream-copied VERBATIM only for an ALLOWLIST of playback-safe codecs
// (pcm_*, aac, alac, mp3, mp2, ac3, eac3, adpcm_ima_qt); everything else
// is re-encoded to pcm_s16le/48k. Default-deny — vorbis/opus/cook fail
// the .mov mux outright, and QDM2-class codecs mux silently but produce
// unplayable files (the historical QDM2 trap). The allowlisted copy is
// still a documented exception to the transcode presets' blanket
// "never -c:a copy" rule: a cleanup output sits beside its original, so
// the original remains the fallback.
//
// Filter choices (all conservative — when in doubt, weaker):
//   - bwdif=mode=send_field:parity=auto   deinterlace, one frame per
//     field (same invocation ReformatJob uses). AUTO-SKIPPED when the
//     catalog's ffprobe field_order says the source is progressive.
//   - crop + pad                          masks VHS head-switching noise:
//     crop N lines off the bottom, pad back to the original dimensions
//     with black. Width, SAR and DAR are untouched (crop/pad change
//     neither), so players see the exact source geometry.
//   - hqdn3d=2:1.5:3:2.25                 HALF of ffmpeg's default
//     denoise strength — gentle by design.
//   - eq=contrast=1.02:saturation=1.05    barely-there touch-up; no
//     brightness/gamma guessing.
//
// No color-space retagging: unlike the editing transcode preset we do NOT
// pin BT.709 — VHS/SD sources are typically BT.601/SMPTE-170M and
// mislabelling them would shift colors. ffmpeg propagates the source tags.
//
// Memory: ffmpeg streams; this process holds only progress lines (~200 B
// per stderr write, bounded by ProcessRunner's 256 KB stderr cap). The
// rendered file lands in the caller-provided scratch directory — sizing
// of that directory is CleanupJob's responsibility.
//
// Cancellation: Task.cancel propagates into ProcessRunner which
// SIGTERM→SIGKILLs the ffmpeg child; the caller deletes the scratch dir.

private let cleanupEngineLog = Logger(subsystem: "Rick-Breen.VideoScan",
                                      category: "cleanup")

struct CleanupFFmpegEngine: CleanupRecipeEngine {

    let engineID = "ffmpeg-filtergraph-v1"

    /// Every current CleanupStepKind compiles to a single-pass ffmpeg
    /// filter chain. Future kinds (vidstab passes, CoreML frame models)
    /// will NOT appear in this set — a dispatcher then routes recipes
    /// containing them to a more capable engine.
    static let supportedKinds: Set<CleanupStepKind> = [
        .deinterlace, .cropBottomNoise, .denoise, .colorTouchUp
    ]

    func canExecute(_ recipe: CleanupRecipe) -> Bool {
        recipe.steps.allSatisfy { !$0.enabled || Self.supportedKinds.contains($0.kind) }
    }

    // MARK: - Render

    func render(recipe: CleanupRecipe,
                source: CleanupSource,
                scratchDirectory: URL,
                progress: @escaping @Sendable (CleanupProgress) -> Void) async throws -> URL {
        guard canExecute(recipe) else {
            let unsupported = recipe.steps.first {
                $0.enabled && !Self.supportedKinds.contains($0.kind)
            }
            throw CleanupEngineError.unsupportedStep(unsupported?.kind ?? .deinterlace)
        }

        let ffmpeg = ToolLocator.ffmpegPath
        guard !ffmpeg.isEmpty, FileManager.default.fileExists(atPath: ffmpeg) else {
            throw CleanupEngineError.toolUnavailable(
                "ffmpeg not found (set VS_FFMPEG_PATH or install via Homebrew)")
        }

        let renderURL = scratchDirectory.appendingPathComponent("cleanup-render.mov")
        let args = Self.ffmpegArgs(recipe: recipe,
                                   source: source,
                                   input: source.path,
                                   output: renderURL.path)

        cleanupEngineLog.info("cleanup render (\(recipe.id, privacy: .public) v\(recipe.version, privacy: .public)): ffmpeg \(args.joined(separator: " "), privacy: .public)")

        progress(CleanupProgress(phase: "Cleaning up…",
                                 fraction: source.durationSeconds > 0 ? 0 : nil))

        // Determinate progress off ffmpeg's `-progress pipe:2` stream —
        // same parser the Reformat/Transcode jobs use.
        let totalDur = source.durationSeconds
        let result = await ProcessRunner.runProcess(
            executable: ffmpeg,
            arguments: args,
            stderrLine: { line in
                guard let sec = ReformatJob.parseProgressSeconds(line: line),
                      totalDur > 0 else { return }
                progress(CleanupProgress(phase: "Cleaning up…",
                                         fraction: min(1.0, sec / totalDur)))
            }
        )

        try Task.checkCancellation()

        guard result.exitCode == 0 else {
            let tail = result.stderr.split(separator: "\n").suffix(4).joined(separator: " · ")
            throw CleanupEngineError.renderFailed(
                "ffmpeg exited with status \(result.exitCode)\(tail.isEmpty ? "" : " — \(tail)")")
        }
        // Reject header-only outputs (ffmpeg occasionally exits 0 after a
        // codec-library failure — same guard Reformat/Transcode use).
        let attrs = try? FileManager.default.attributesOfItem(atPath: renderURL.path)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard size >= 10_000 else {
            throw CleanupEngineError.renderFailed(
                "ffmpeg output too small (\(size) bytes) — likely a codec failure")
        }

        return renderURL
    }

    // MARK: - Pure builders (unit-tested, no I/O)

    /// Playback-safe audio codecs the cleanup output may STREAM-COPY into
    /// a .mov (M4). Everything outside this set — vorbis/opus/cook (mux
    /// failure), qdm2/qdmc/mace (the silent-unplayable QDM2 trap), and
    /// the unknown "" — is re-encoded to pcm_s16le. Default-deny: this
    /// ALLOWLIST is the mechanism; `unplayableLegacyAudioCodecs` documents
    /// only the worst offenders and is deliberately NOT the gate.
    static let audioCopyAllowlist: Set<String> = [
        "aac", "alac", "mp3", "mp2", "ac3", "eac3", "adpcm_ima_qt"
    ]

    /// True when `codec` (raw ffprobe name) may be stream-copied: any
    /// `pcm_*` variant plus the explicit allowlist above. Pure — tested.
    nonisolated static func audioCopyAllowed(codec: String) -> Bool {
        let c = codec.trimmingCharacters(in: .whitespaces).lowercased()
        if c.hasPrefix("pcm_") { return true }
        return audioCopyAllowlist.contains(c)
    }

    /// True when the catalog's ffprobe field_order marks the source
    /// progressive. "tt"/"bb"/"tb"/"bt" are interlaced; ""/"unknown" is
    /// treated as NOT progressive (VHS captures frequently probe as
    /// unknown — deinterlacing them is the safe default for this recipe,
    /// and bwdif degrades gracefully on progressive input).
    nonisolated static func isProgressive(fieldOrder: String) -> Bool {
        fieldOrder.trimmingCharacters(in: .whitespaces).lowercased() == "progressive"
    }

    /// Compile ONE step to its ffmpeg filter chain segment, or nil when
    /// the step contributes nothing (disabled, or deinterlace on a
    /// progressive source). Pure — the whole v1 recipe is testable as
    /// strings.
    nonisolated static func filterChain(for step: CleanupStep,
                                        source: CleanupSource) -> String? {
        guard step.enabled else { return nil }
        switch step.kind {
        case .deinterlace:
            // Auto-skip on progressive sources: the recipe still runs,
            // this step just compiles to nothing.
            guard !isProgressive(fieldOrder: source.fieldOrder) else { return nil }
            let mode = step.parameters["mode"] ?? "send_field"
            let parity = step.parameters["parity"] ?? "auto"
            return "bwdif=mode=\(mode):parity=\(parity)"

        case .cropBottomNoise:
            // Remove the bottom N lines (head-switching noise band), then
            // pad back to the original height with black. After `crop`,
            // `ih` refers to the CROPPED height, so `ih+N` restores the
            // source dimensions exactly — SAR/DAR are untouched.
            let lines = max(0, Int(step.parameters["lines"] ?? "") ?? 8)
            guard lines > 0 else { return nil }
            return "crop=iw:ih-\(lines):0:0,pad=iw:ih+\(lines):0:0:black"

        case .denoise:
            let strength = step.parameters["hqdn3d"] ?? "2:1.5:3:2.25"
            return "hqdn3d=\(strength)"

        case .colorTouchUp:
            let eq = step.parameters["eq"] ?? "contrast=1.02:saturation=1.05"
            return "eq=\(eq)"
        }
    }

    /// Join every step's chain in recipe order. nil when NO step
    /// contributes (all disabled / all auto-skipped) — the caller then
    /// omits `-vf` entirely and the render is a plain re-encode.
    nonisolated static func filterGraph(recipe: CleanupRecipe,
                                        source: CleanupSource) -> String? {
        let chains = recipe.steps.compactMap { filterChain(for: $0, source: source) }
        return chains.isEmpty ? nil : chains.joined(separator: ",")
    }

    /// Full ffmpeg argument vector: filtergraph + ProRes 422 LT
    /// (hardware) + allowlist-gated audio copy-or-modernize +
    /// `-progress pipe:2`. Pure.
    nonisolated static func ffmpegArgs(recipe: CleanupRecipe,
                                       source: CleanupSource,
                                       input: String,
                                       output: String) -> [String] {
        var args: [String] = [
            "-hide_banner",
            "-nostdin",
            "-y",
            "-hwaccel", "videotoolbox",
            "-i", input,
            "-map", "0:v:0"
        ]
        if source.hasAudio {
            args += ["-map", "0:a:0"]
        }
        if let graph = filterGraph(recipe: recipe, source: source) {
            args += ["-vf", graph]
        }
        args += [
            // ProRes 422 LT via the M-series media engine — profile 1
            // (matches TranscodeJob's editingLT choice).
            "-c:v", "prores_videotoolbox",
            "-profile:v", "1",
            "-pix_fmt", "yuv422p10le"
        ]
        if source.hasAudio {
            if audioCopyAllowed(codec: source.audioCodec) {
                // Verbatim audio copy — see the file-header note for why
                // this allowlisted copy is a sanctioned exception to the
                // transcode presets' no-copy rule.
                args += ["-c:a", "copy"]
            } else {
                // Modernize: non-allowlisted codec (vorbis/opus/qdm2/…)
                // or unknown "". pcm_s16le/48k mirrors the ProRes+PCM
                // editing idiom and always muxes + plays everywhere.
                args += ["-c:a", "pcm_s16le", "-ar", "48000"]
            }
        }
        // Carry source metadata (timecode, tape name) into the clean copy.
        args += [
            "-map_metadata", "0",
            "-progress", "pipe:2",
            output
        ]
        return args
    }
}
