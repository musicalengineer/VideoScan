// TranscodeJob+EncodeGate.swift
// The gate between a finished encode and its publish: every check that can
// say no, in one read-only function, run BEFORE the first mutation (nothing
// is trashed or renamed until it answers `.passed`).
//
// Order (the first that applies is the answer):
//   1. the encode FAILED — ffmpeg's exit code, or an output shorter than the
//      source (FFmpegEncodeCheck);
//   2. ffmpeg wrote nothing, or under 10 KB (it sometimes exits 0 with a
//      header-only file when a codec library is missing);
//   3. REPLACE ONLY (GH #500; Rick 2026-11-20: "transcode to a temp, verify
//      the temp, only when verified could it replace anything. If the
//      transcode is not verified, the operation fails."): the new file must
//      be VERIFIED — both container lengths read and in agreement. A length
//      that could not be read is not verified. The bug: the old nil verdict
//      ("not failed") was read as leave to Trash the file at the output
//      name, so an output ffprobe could not read replaced a good file and
//      was catalogued as "Transcoded".
// Without Replace nothing can be removed, and an unmeasured output is still
// published beside whatever is there, as before.
//
// `replace` is the user's answer, not "is a file at the name right now", so
// there is no check-then-act window between this gate and the publish.
//
// Memory: two one-line ffprobe answers and one stat; ffprobe streams.
// (For Rick: `EncodeGate` ≈ a std::variant<Failed, Unverified, Passed>; the
// caller's `switch` must handle all three or it does not compile.)

import Foundation
import VideoScanCore

extension TranscodeJob {

    enum EncodeGate: Sendable, Equatable {
        /// The encode failed. `message` is the row's sentence; `stage` tags
        /// the console line.
        case failed(String, stage: String)
        /// Replace was chosen and the new file could not be verified.
        /// `cause` names the file, the tool, its exit code and its words.
        case unverified(cause: String)
        /// May be published. `sizeBytes` is the new file's size.
        case passed(sizeBytes: Int64)
    }

    /// Reads only. Disk and probes run off the main actor.
    @concurrent
    nonisolated static func encodeGate(_ result: ProcessRunner.Result, inputPath: String,
                                       partialPath: String, replace: Bool) async -> EncodeGate {
        let fm = FileManager.default
        let verification: FFmpegEncodeCheck.Verification? = fm.fileExists(atPath: partialPath)
            ? await FFmpegEncodeCheck.verification(for: result, sourcePath: inputPath, outputPath: partialPath)
            : nil
        if case .failed(let failure) = verification {
            return .failed(sentence(failure), stage: "encode")
        }
        // The partial is gone and ffmpeg failed: the exit reason beats
        // "no output file".
        if let failure = FFmpegEncodeCheck.exitFailure(exitCode: result.exitCode, stderr: result.stderr) {
            return .failed(sentence(failure), stage: "encode, no output")
        }
        // The reservation is an empty file: still empty (or gone) ⇒ ffmpeg
        // wrote nothing.
        let attrs = try? fm.attributesOfItem(atPath: partialPath)
        let size = (attrs?[.size] as? NSNumber)?.int64Value ?? 0
        guard attrs != nil, size > 0 else {
            return .failed("ffmpeg finished but no output file was produced", stage: "no output")
        }
        guard size >= 10_000 else {
            return .failed("ffmpeg output too small (\(size) bytes) — likely a codec failure", stage: "output too small")
        }
        guard replace else { return .passed(sizeBytes: size) }
        switch verification {
        case .verified: return .passed(sizeBytes: size)
        case .unmeasured(let why): return .unverified(cause: why)
        case .failed, nil: return .unverified(cause: "the new file was not there to measure")
        }
    }

    nonisolated private static func sentence(_ reason: String) -> String {
        reason.prefix(1).uppercased() + reason.dropFirst()
    }

    /// `path` when something is still there, else nil (after the discard:
    /// what the message may truthfully say about the new file).
    nonisolated static func pathIfPresent(_ path: String) -> String? {
        FileManager.default.fileExists(atPath: path) ? path : nil
    }

    /// The one sentence for a Replace refused because the new file could
    /// not be verified. The MFO row, its detail and the Center's OUTCOME
    /// line ("transcode FAILED: <source> — …") all show exactly this: the
    /// plain words first, then the specific cause, then what happened to
    /// the original and to the new file (`partialStillAt` is non-nil only
    /// when the new file could not be removed).
    nonisolated static func unverifiedReplaceMessage(cause: String, original: String,
                                                     partialStillAt: String?) -> String {
        let newFile = partialStillAt.map { "the unverified new file could not be removed and is at \($0)" }
            ?? "the unverified new file was removed"
        return "Could not verify the new file — the original was not replaced. Cause: \(cause). "
            + "\(original) was not moved or changed; \(newFile)."
    }
}
