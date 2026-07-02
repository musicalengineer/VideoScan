import Foundation

// MARK: - VideoScanModel+RecoveredExtension
//
// Punch-list item #3: when Relocate RECOVERS (copies) a catalogued media
// file that has NO usable filename extension to a destination volume, give
// the destination file the correct extension so macOS can actually open it.
//
// Why this matters: macOS routes file-open by extension/UTI, NOT by sniffing
// bytes. A file that ffprobe decodes perfectly (catalog `isPlayable = Yes`)
// still fails to open on double-click if it has no extension — the OS has no
// UTI to hand to QuickTime/AVFoundation. Real spot-test case:
//   …/iPhoto Library/Thumbnails/…/Donna-MyGirl-1984-Final  (no extension)
// is genuine media (ffprobe: mov / mjpeg+pcm) yet "not a media file" on
// double-click. The app's "ffprobe-decodable" ≠ the user's "OS-openable".
//
// Scope is deliberately conservative:
//   * We map ONLY unambiguous, well-known family-media containers.
//   * Unknown / ambiguous / empty container ⇒ we return nil and leave the
//     name untouched. We never guess.
//   * We only ADD an extension on the RECOVERED COPY. The user's source file
//     is never renamed in place.
//
// Both pure helpers below are `nonisolated static` (like the other
// Relocate path helpers) so they're trivially unit-testable with no disk
// and no VideoScanModel instance. (Swift `static` in an `extension`
// ≈ a free function namespaced under the class — no `self`, no actor hop.)

extension VideoScanModel {

    /// Container → extension mapping is keyed off the value VideoScan stores
    /// in `VideoRecord.container`, which is ffprobe's `format_long_name`
    /// when available, else the short comma-list `format_name`
    /// (see ScanEngine.extractMetadata), plus the synthetic "MXF (…)" label
    /// produced by the MXF header-fallback path. So this helper must cope
    /// with all three shapes:
    ///   - short comma list: "mov,mp4,m4a,3gp,3g2,mj2"  → mov
    ///   - long name:        "QuickTime / MOV"          → mov
    ///   - synthetic:        "MXF (D10Video)"           → mxf
    ///
    /// Strategy: tokenize on every non-alphanumeric boundary into a lowercase
    /// token SET, then test a priority-ordered rule list. Order matters where
    /// one container's tokens are a superset of another's (e.g. an MPEG-TS
    /// long name "MPEG-TS (MPEG-2 Transport Stream)" tokenizes to include both
    /// "ts" AND "mpeg", so the `ts` rule must win over the `mpeg` rule).
    ///
    /// Returns nil for empty / unknown / ambiguous input — the caller then
    /// leaves the filename as-is. Pure & nonisolated.
    nonisolated static func canonicalContainerExtension(forProbedContainer raw: String) -> String? {
        let lowered = raw.lowercased()
        guard !lowered.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        // Split on anything that isn't a-z / 0-9. "mpeg-ts" → ["mpeg","ts"],
        // "mov,mp4,m4a" → ["mov","mp4","m4a"], "quicktime / mov" → ["quicktime","mov"].
        let tokens = Set(
            lowered.split { !($0.isLetter || $0.isNumber) }.map(String.init)
        )
        guard !tokens.isEmpty else { return nil }

        // Priority-ordered rules. First whose `any token in set` matches wins.
        // Each entry: (recognizing tokens, canonical extension to emit).
        // Comments note the ffprobe forms each rule is meant to catch.
        let rules: [(match: Set<String>, ext: String)] = [
            // Matroska / WebM family.            short "matroska,webm" | long "Matroska / WebM"
            (["matroska", "webm", "mkv"], "mkv"),
            // Material eXchange Format.          short "mxf" | synthetic "MXF (…)"
            (["mxf"], "mxf"),
            // MPEG transport stream — MUST precede the generic mpeg rule.
            //                                    short "mpegts" | long "MPEG-TS (MPEG-2 Transport Stream)"
            (["mpegts", "ts", "m2ts", "mts"], "ts"),
            // QuickTime / MP4 family — canonical primary is mov (openable for
            // either; ffprobe can't distinguish mp4 from mov at demux time).
            //                                    short "mov,mp4,m4a,3gp,3g2,mj2" | long "QuickTime / MOV"
            (["quicktime", "mov", "mp4", "m4v"], "mov"),
            // Audio Video Interleave.            short "avi" | long "AVI (Audio Video Interleaved)"
            (["avi"], "avi"),
            // Advanced Systems Format → .wmv.    short "asf" | long "ASF (Advanced / Active Streaming Format)"
            (["asf", "wmv"], "wmv"),
            // Flash Video.                       short "flv" | long "FLV (Flash Video)"
            (["flv"], "flv"),
            // MPEG audio (MP3/MP2) — MUST precede the generic mpeg rule.
            // ffprobe's demuxer long name "MP2/3 (MPEG audio layer 2/3)"
            // tokenizes to include "mpeg" AND "mp2" (but NOT "mp3"), so
            // without this rule an extensionless MP3 would be stamped ".mpg",
            // a video extension. Match both the long-name token "mp2" and the
            // short format_name "mp3". macOS routes ".mp3" to CoreAudio for
            // MPEG audio layers 2 and 3 alike.
            //                                    short "mp3" | long "MP2/3 (MPEG audio layer 2/3)"
            (["mp3", "mp2"], "mp3"),
            // MPEG program/elementary stream.    short "mpeg" | long "MPEG-PS (MPEG-2 Program Stream)"
            (["mpeg", "mpg", "mpegps"], "mpg"),
        ]
        for rule in rules where !rule.match.isDisjoint(with: tokens) {
            return rule.ext
        }
        return nil
    }

    /// Extensions macOS already knows how to route to a player. If the
    /// destination filename already ends in one of these we leave it alone —
    /// the file is already openable, no inference needed. Lowercased.
    nonisolated static var knownOpenableMediaExtensions: Set<String> {
        [
            "mov", "mp4", "m4v", "m4a", "qt",
            "mkv", "webm",
            "avi",
            "ts", "m2ts", "mts", "m2t",
            "mxf",
            "mpg", "mpeg", "m2v", "m1v", "vob",
            "wmv", "asf",
            "flv", "f4v",
            "3gp", "3g2", "mj2",
            "dv", "dif",
            "mp3", "wav", "aif", "aiff", "aac", "flac", "caf", "ogg",
        ]
    }

    /// Decision returned by `inferredRecoveryExtension(...)` — keeps the
    /// "what would happen" logic pure so both the caller and the tests can
    /// inspect it without side effects. (Swift enum-with-payload ≈ a tagged
    /// union / `std::variant`.)
    enum RecoveredExtensionDecision: Equatable {
        /// Append `.toExt` to the recovered file; `fromExt` is the original
        /// (empty or unknown) extension, for the log line.
        case append(newPath: String, fromExt: String, toExt: String)
        /// Leave the destination filename unchanged.
        case unchanged(Reason)

        enum Reason: Equatable {
            case alreadyOpenable      // dest already ends in a known media ext
            case noConfidentMapping   // container unknown/ambiguous/empty
            case disabled             // feature toggled off in RelocateOptions
        }
    }

    /// Decide whether a recovered file's destination path should gain an
    /// inferred extension. Pure: takes the computed destination path plus the
    /// record's probed `container` string and returns a decision the caller
    /// applies + logs. `enabled` mirrors `RelocateOptions.addInferredExtensionOnRecovery`.
    ///
    /// Trigger conditions (ALL must hold to append):
    ///   1. feature enabled, AND
    ///   2. the destination has no extension OR an extension macOS won't route
    ///      (not in `knownOpenableMediaExtensions`), AND
    ///   3. the probed container maps confidently to a canonical extension, AND
    ///   4. that mapped extension isn't already the current (unknown) one.
    ///
    /// We APPEND rather than replace, so "clip.t2-v" (a junk Avid pseudo-ext)
    /// becomes "clip.t2-v.mov" — the original name is preserved verbatim and
    /// the openable extension is added. An extensionless
    /// "Donna-MyGirl-1984-Final" becomes "Donna-MyGirl-1984-Final.mov".
    ///
    /// Collision handling is deliberately NOT done here: the appended path
    /// flows through the same `RelocateJob` → `RelocateEngine.runOne`, whose
    /// Stage-1 check already rejects a pre-existing destination as
    /// `.salvageFailed(.copy)`. We reuse that single collision policy rather
    /// than inventing a uniquing scheme.
    nonisolated static func inferredRecoveryExtension(
        forDestinationPath path: String,
        probedContainer: String,
        enabled: Bool
    ) -> RecoveredExtensionDecision {
        guard enabled else { return .unchanged(.disabled) }

        let currentExt = (path as NSString).pathExtension   // "" when no dot
        let currentLower = currentExt.lowercased()

        // Already has an OS-openable extension → never touch.
        if !currentLower.isEmpty,
           knownOpenableMediaExtensions.contains(currentLower) {
            return .unchanged(.alreadyOpenable)
        }

        guard let mapped = canonicalContainerExtension(forProbedContainer: probedContainer) else {
            return .unchanged(.noConfidentMapping)
        }

        // Defensive: the unknown extension already equals the mapped one
        // (case difference only) — nothing meaningful to add.
        if currentLower == mapped {
            return .unchanged(.alreadyOpenable)
        }

        return .append(newPath: path + "." + mapped,
                       fromExt: currentExt,
                       toExt: mapped)
    }
}
