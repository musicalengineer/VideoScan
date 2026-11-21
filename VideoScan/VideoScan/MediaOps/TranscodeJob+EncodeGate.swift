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
//      Verified means THIS file (codex r1 F2): the partial's stamp (device,
//      inode, size, mtime) is taken before the probes and must be the same
//      after them, and again immediately before the publish
//      (`publishVerified`). A length read from one file never vouches for
//      another put at its name. Residual: the re-stat and the publish's
//      rename are separate syscalls; a swap inside that instant is not seen.
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
        /// May be published. `sizeBytes` is the new file's size. `verified`
        /// (Replace only) is the stamp of the file whose lengths were read:
        /// the publish must find exactly that file.
        case passed(sizeBytes: Int64, verified: PartialFileNaming.FileStamp?)
    }

    /// What the cleanup of this run's partial actually did — the job's
    /// message reports this, never an inference from "nothing is there"
    /// (codex r1 F4: a folder that lost its search permission looks empty).
    enum PartialCleanup: Sendable, Equatable {
        case removed
        case alreadyGone
        /// The reason, which names the path.
        case notRemoved(String)
    }

    /// The new file at the partial's name is not the file that was verified.
    struct ChangedSinceVerified: Error {}
    static let changedAfterVerification = "the new file changed after it was verified"

    /// Reads only. Disk and probes run off the main actor.
    @concurrent
    nonisolated static func encodeGate(_ result: ProcessRunner.Result, inputPath: String,
                                       partialPath: String, replace: Bool) async -> EncodeGate {
        let fm = FileManager.default
        let before = PartialFileNaming.fileStamp(partialPath)   // the file the probes are about to read
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
        guard replace else { return .passed(sizeBytes: size, verified: nil) }
        guard let before, PartialFileNaming.fileStamp(partialPath) == before else {
            return .unverified(cause: "the new file changed while it was being verified")
        }
        switch verification {
        case .verified: return .passed(sizeBytes: size, verified: before)
        case .unmeasured(let why): return .unverified(cause: why)
        case .failed, nil: return .unverified(cause: "the new file was not there to measure")
        }
    }

    nonisolated private static func sentence(_ reason: String) -> String {
        reason.prefix(1).uppercased() + reason.dropFirst()
    }

    /// The disk half of the publish, off the main thread. With Replace
    /// (`verified` non-nil) the partial must still be exactly the verified
    /// file — checked here, immediately before the publish that may Trash
    /// the previous file — else `ChangedSinceVerified` and nothing is touched.
    @concurrent
    nonisolated static func publishVerified(
        partial: String, final: URL, policy: DerivativeOutputPublish.ExistingFilePolicy,
        archiveCheck: ArchiveRemovalCheck?, trash: @escaping @Sendable (URL) throws -> URL?,
        verified: PartialFileNaming.FileStamp?
    ) async throws -> DerivativeOutputPublish.Outcome {
        if let verified, PartialFileNaming.fileStamp(partial) != verified { throw ChangedSinceVerified() }
        return try DerivativeOutputPublish.publish(partial: partial, as: final, policy: policy,
                                                   archiveCheck: archiveCheck, trash: trash)
    }

    /// What became of the original and of the new file — said on every
    /// failed Replace. "removed" only when the cleanup said so.
    nonisolated static func disposition(original: String, newFile: String, cleanup: PartialCleanup) -> String {
        let what: String
        switch cleanup {
        case .removed: what = "the \(newFile) new file was removed"
        case .alreadyGone: what = "the \(newFile) new file was no longer there to remove"
        case .notRemoved(let why): what = "the \(newFile) new file was NOT removed: \(why)"
        }
        return "\(original) was not moved or changed; \(what)."
    }

    /// The one sentence for a Replace refused because the new file could
    /// not be verified. The MFO row, its detail and the Center's OUTCOME
    /// line ("transcode FAILED: <source> — …") all show exactly this: the
    /// plain words first, then the specific cause, then what happened to
    /// the original and to the new file.
    nonisolated static func unverifiedReplaceMessage(cause: String, original: String,
                                                     cleanup: PartialCleanup) -> String {
        "Could not verify the new file — the original was not replaced. Cause: \(cause). "
            + disposition(original: original, newFile: "unverified", cleanup: cleanup)
    }

    /// A Replace whose ENCODE failed says the same two things after the
    /// failure itself (codex r1 F5).
    nonisolated static func failedReplaceMessage(failure: String, original: String,
                                                 cleanup: PartialCleanup) -> String {
        "\(failure). The original was not replaced: "
            + disposition(original: original, newFile: "failed", cleanup: cleanup)
    }
}
