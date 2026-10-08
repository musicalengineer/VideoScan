import Foundation

// MARK: - The report card's "Recommended action" banner, and the
// before → after card a repair leaves behind (Rick 2026-10-08).
// Pure values: the views draw them, the tests pin them.

/// What the banner at the top of a report card says.
enum MediaRepairAdvice: Equatable {
    /// Nothing worth a banner (no problem; or only warnings nothing fixes).
    case none
    /// At least one fixable problem: what's wrong, the fix in one line,
    /// the fixes Repair Now will run, the problems it can't touch, and
    /// the equivalent manual steps (read-only text for Rick).
    case recommended(headline: String, fixLine: String, recipe: MediaRepairRecipe,
                     unfixable: [String], manualSteps: [String])
    /// Problems, none with an automatic fix.
    case noAutomaticFix(sentence: String)

    /// The pinned sentence for a problem nothing can repair (the "find the
    /// original material" feature doesn't exist yet — text only).
    static let noAutomaticFixAdvice =
        "No automatic repair can fix this — the damage is in what was recorded, not in how it is stored. The best fix is to find the original material (another copy, the tape, or the camera's own file) and keep that instead."

    static func advice(for card: MediaReportCard, offers: [MediaRepairOffer],
                       balance: MediaRepairBalanceInput?, sourceName: String) -> MediaRepairAdvice {
        let fixable = offers.filter { $0.answers != nil && $0.isAvailable }
        let fixedKinds = Set(fixable.compactMap(\.answers))
        let problems = card.checks.filter { $0.verdict == .problem }
        let unfixable = problems.filter { !fixedKinds.contains($0.kind) }
        guard let first = card.checks.first(where: { fixedKinds.contains($0.kind) }) else {
            guard let worst = problems.first else { return .none }
            return .noAutomaticFix(sentence: "\(worst.kind.title): \(worst.sentence) \(noAutomaticFixAdvice)")
        }
        let recipe = MediaRepairRecipe(fixes: fixable.map(\.fix), balance: balance)
        return .recommended(headline: "Recommended: Repair \u{2014} \(first.sentence)",
                            fixLine: fixLine(recipe),
                            recipe: recipe,
                            unfixable: unfixable.map { "\($0.kind.title): \($0.sentence)" },
                            manualSteps: manualSteps(recipe, sourceName: sourceName))
    }

    /// The fix, in one line.
    static func fixLine(_ recipe: MediaRepairRecipe) -> String {
        if recipe.isLossless {
            return "A lossless remux puts sound and picture side by side; nothing is re-encoded. The original is never changed."
        }
        let parts = recipe.applied.compactMap { fix -> String? in
            switch fix {
            case .removeRepeatedFrames: return "removes the repeated frames (the picture is re-encoded, H.264 at a high-quality setting)"
            case .remux: return "stores sound beside picture"
            case .rebuildAudio: return "rebuilds the sound track as uncompressed PCM"
            case .balanceAudio: return "balances the sound to both speakers"
            }
        }
        return "Repair Now " + ListFormatter.localizedString(byJoining: parts)
            + " \u{2014} into a new file; the original is never changed."
    }

    /// The same work, by hand: the commands VideoScan runs, with the
    /// file names filled in. Read-only text.
    static func manualSteps(_ recipe: MediaRepairRecipe, sourceName: String) -> [String] {
        let src = shellQuoted(sourceName)
        let out = shellQuoted(MediaRepairOutput.fileName(
            sourcePath: sourceName,
            fileExtension: recipe.fileExtension(sourceExtension: (sourceName as NSString).pathExtension, audioCodec: "")))
        var steps: [String] = []
        if recipe.picture == .removeRepeatedFrames {
            steps.append("Read the file's own frame rate F (it must be a camera rate — 25, 29.97, 30 …):\n  ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate,avg_frame_rate \(src)")
        }
        // A placeholder plan: F and the colour tags are shown as names.
        let placeholder = recipe.picture == .removeRepeatedFrames
            ? MediaRepairPicturePlan(rateText: "F", rate: 30, rateSource: "", pixelFormat: "<source format>",
                                     reducesColourDetail: false, tagArgs: [], sampleAspectRatio: nil)
            : nil
        let cmd = recipe.ffmpegArgs(input: "\u{1}SRC", output: "\u{1}OUT", picture: placeholder)
            .filter { $0 != "-progress" && $0 != "pipe:2" && $0 != "-hide_banner" && $0 != "-nostdin" && $0 != "-y" }
            .map { arg -> String in
                if arg == "\u{1}SRC" { return src }
                if arg == "\u{1}OUT" { return out }
                return arg.contains(" ") || arg.contains("|") || arg.contains("(") ? shellQuoted(arg) : arg
            }
        steps.append((steps.isEmpty ? "" : "Then write the repaired copy:\n  ") + "ffmpeg " + cmd.joined(separator: " "))
        if recipe.isLossless {
            steps.append("Check: ffprobe -show_entries packet=stream_index,size,duration on both files must count the same packets, bytes and length per stream.")
        }
        return steps
    }

    static func shellQuoted(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}

/// The before → after card: each row the ORIGINAL had trouble with, its
/// old verdict and the repaired copy's.
struct MediaRepairComparison: Equatable, Sendable {
    struct Row: Equatable, Sendable, Identifiable {
        let kind: MediaCheckKind
        let before: MediaCheckVerdict
        /// nil = the copy's check didn't include this row.
        let after: MediaCheckVerdict?
        /// The copy's sentence for a row that is still wrong.
        let afterSentence: String?
        /// A fix in this repair aimed at this row.
        let targeted: Bool

        var id: MediaCheckKind { kind }
        var isFixed: Bool { after == .ok }
        /// The copy's check looked at this row (a quick Verify leaves the
        /// full-tier rows — sound — "not run": unknown, not failed).
        var wasRechecked: Bool {
            guard let after else { return false }
            if case .notRun = after { return false }
            return true
        }
    }

    let rows: [Row]
    let outputName: String
    let besideOriginal: Bool

    init(before: MediaReportCard, after: MediaReportCard, applied: [MediaRepairFix],
         outputName: String, besideOriginal: Bool) {
        let targeted = Set(applied.map(\.answers))
        rows = before.checks
            .filter { $0.verdict == .problem || $0.verdict == .warning }
            .map { old in
                let new = after.check(old.kind)
                return Row(kind: old.kind, before: old.verdict, after: new?.verdict,
                           afterSentence: new?.verdict == .ok ? nil : new?.sentence,
                           targeted: targeted.contains(old.kind))
            }
        self.outputName = outputName
        self.besideOriginal = besideOriginal
    }

    var fixedCount: Int { rows.filter(\.isFixed).count }
    private var aimedRechecked: [Row] { rows.filter { $0.targeted && $0.wasRechecked } }
    /// Rows a fix aimed at that the quick Verify of the copy couldn't look at.
    var notRecheckedCount: Int { rows.filter { $0.targeted && !$0.wasRechecked }.count }

    /// Every row a fix aimed at was re-checked and now reads OK. Never true
    /// on a guess: an un-re-checked row keeps this false.
    var isFullyRepaired: Bool {
        notRecheckedCount == 0 && !aimedRechecked.isEmpty && aimedRechecked.allSatisfy(\.isFixed)
    }

    var headline: String {
        let place = besideOriginal ? "beside the original" : "in the folder you chose"
        let saved = "saved as \(outputName) \(place)"
        let fixed = aimedRechecked.filter(\.isFixed).count
        let later = notRecheckedCount > 0
            ? " \u{2014} \(notRecheckedCount) not re-checked yet (a full Verify of the copy listens to the sound)"
            : ""
        if aimedRechecked.isEmpty { return "Repaired copy \(saved)\(later)" }
        let noun = fixed == 1 ? "problem" : "problems"
        if fixed == aimedRechecked.count { return "Repaired: \(fixed) \(noun) fixed \u{2014} \(saved)\(later)" }
        return "Partly repaired: \(fixed) of \(aimedRechecked.count) fixed \u{2014} \(saved)\(later)"
    }
}
