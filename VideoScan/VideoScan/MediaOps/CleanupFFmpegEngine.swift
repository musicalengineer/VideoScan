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
//
// Verdict before a render is returned (and so before CleanupJob can
// publish it): exit code, the 10 KB floor, then length against the source
// (FFmpegEncodeCheck — N1014-F2) — and the length must have been READ: a
// render whose length (or whose source's length) cannot be measured is not
// verified and is never returned (GH #502, Rick 2026-11-21).

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
                progress: @escaping @Sendable (CleanupProgress) -> Void) async throws -> CleanupRender {
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
        // Length (N1014-F2, 2026-10-07): ffmpeg exits 0 when a source read
        // error (bad sectors on an aging drive) ends its input early, so a
        // 20-minute render of a 60-minute tape passed both gates above and
        // was published as the cleaned copy. Same rule Transcode/Reformat use.
        //
        // UNKNOWN IS NOT VERIFIED (GH #502, 2026-11-21). THE BUG: this read
        // both lengths through a "seconds or nil" probe and a nil — ffprobe
        // crashed, could not start, answered garbage, said "Invalid data",
        // hung to its deadline — skipped the rule, so a render nobody could
        // measure was returned and published as the cleaned copy. The three
        // answers are now all handled: only `.verified` returns the render.
        //
        // THIS file (Codex r1 #4, P0 — as #500 did for Transcode): the
        // render's stamp is taken before the probes and must be the same
        // after them; it travels with the render to the publish, which
        // copies the file only while it still has it. Residual (declined,
        // GH #503): a swap and swap-back inside one probe.
        let before = FileIdentityStamp.capture(path: renderURL.path)
        let length = await FFmpegEncodeCheck.lengthVerification(sourcePath: source.path, outputPath: renderURL.path,
                                                                output: "the cleaned copy")
        // A Stop that landed while the probes were out is still a Stop: a
        // good answer does not hand back a render over it.
        try Task.checkCancellation()
        switch length {
        case .verified, .lengthNotCompared:
            guard let before, FileIdentityStamp.capture(path: renderURL.path) == before else { throw Self.changedWhileVerified(source) }
            if case .lengthNotCompared(let why) = length {
                // The source has no readable duration (ffprobe ran and said
                // so). Cleanup never replaces the original, so this is a
                // note, not a refusal: the render was measured on its own terms.
                appLog.write("cleanup: \((source.path as NSString).lastPathComponent) has no readable duration (\(why)) — the cleaned copy's length was read but not compared")
                progress(CleanupProgress(phase: "Cleaning up…", fraction: 1.0, note: FFmpegEncodeCheck.lengthNotComparedNote))
            }
            return CleanupRender(url: renderURL, verified: before)
        case .failed(let shortfall):
            cleanupEngineLog.error("cleanup render FAILED (length): \(source.path, privacy: .public) — \(shortfall, privacy: .public)")
            throw CleanupEngineError.renderFailed(shortfall.prefix(1).uppercased() + shortfall.dropFirst())
        case .unmeasured(let cause):
            let message = Self.unverifiedRenderMessage(cause: cause)
            cleanupEngineLog.error("cleanup render FAILED (verify): \(source.path, privacy: .public) — \(message, privacy: .public)")
            throw CleanupEngineError.renderFailed(message)
        }
    }

    /// The cause when the render measured is not the render at the name now.
    nonisolated static let changedWhileVerifiedCause = "the new file changed while it was being verified"

    private static func changedWhileVerified(_ source: CleanupSource) -> CleanupEngineError {
        let message = unverifiedRenderMessage(cause: changedWhileVerifiedCause)
        cleanupEngineLog.error("cleanup render FAILED (verify): \(source.path, privacy: .public) — \(message, privacy: .public)")
        return .renderFailed(message)
    }

    /// The row's sentence for a render that could not be verified — the
    /// #500 family, minus the original (Cleanup never replaces it). The
    /// render sits in the job's scratch folder; nothing was copied beside
    /// the original. The sentence says where the render IS and promises
    /// nothing more (Codex r1 #8): the engine does not remove it, and the
    /// JOB appends what its own removal of the scratch folder did.
    nonisolated static func unverifiedRenderMessage(cause: String) -> String {
        "Could not verify the cleaned copy — nothing was published or added to the catalog. Cause: \(cause). "
            + "The unverified render is only in the job's scratch folder; the original is untouched."
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
