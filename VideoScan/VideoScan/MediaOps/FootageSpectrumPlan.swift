// FootageSpectrumPlan.swift
// The PURE side of "Compare Footage…" (Footage Spectrum trial, 2026-10-03;
// docs/design/footage_spectrum_design_2026-10-03.md, stage 1 as a UI-first
// shoehorn of scripts/footage_spectrum.py into the app):
//
//   * `FootageSpectrumPlanner`  — which of the chosen files are compared, in
//     what order, and which one is the reference; or why the run is refused.
//   * `FootageSpectrumSets`     — the sets.json the helper reads.
//   * `FootageSpectrumProtocol` — the helper's ESTIMATE / PROGRESS / DONE /
//     ERROR lines, parsed.
//   * `FootageSpectrumETA`      — "about 1:10 left" from the helper's own
//     estimates, re-scaled by the rate actually observed.
//   * `FootageSpectrumWords`    — the row text and the one-line summary.
//
// No I/O, no SwiftUI, no model: value types in, value types out, so every
// rule here is a table test (FootageSpectrumPlanTests).
//
// (For Rick: a `struct … : Sendable, Equatable` ≈ a C++ POD with operator==;
// `enum … { case a(payload) }` ≈ a tagged union / std::variant; `Result<T, E>`
// ≈ std::expected.)

import Foundation

// MARK: - What goes in

/// One chosen record, reduced to the facts the planner needs. Built in an
/// EVENT HANDLER from the model's id index (never in a view body).
struct FootageSpectrumCandidate: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var path: String
    var sizeBytes: Int64
    var durationSeconds: Double
    /// The volume's friendly label ("LaCie") — for the detail list and labels.
    var volumeLabel: String
    /// A file OF the Master Archive (the model's canonical predicate,
    /// `isArchiveElement`): wins the reference seat and goes first.
    var isArchiveCopy: Bool
    /// The file can be opened right now (its drive is connected, the file
    /// exists). Offline files are left out with a line, never guessed at.
    var isReadable: Bool
}

// MARK: - What comes out

/// One file the helper will read.
struct FootageSpectrumMember: Sendable, Equatable, Identifiable {
    var id: UUID
    /// "A · clip.mov" — the first word is the short tag the page uses in
    /// captions, the rest is the file name.
    var label: String
    var filename: String
    var path: String
    var volumeLabel: String
    var sizeBytes: Int64
    var durationSeconds: Double
    var isArchiveCopy: Bool
}

/// A chosen file that will NOT be read, and why (shown in the job's detail).
struct FootageSpectrumLeftOut: Sendable, Equatable, Identifiable {
    var id: UUID
    var filename: String
    var reason: String
}

struct FootageSpectrumPlan: Sendable, Equatable {
    /// The window's title ("Christmas 1994", "Same footage", "5 videos").
    var title: String
    /// In reading order; `members[referenceIndex]` is the reference.
    var members: [FootageSpectrumMember]
    var referenceIndex: Int
    var leftOut: [FootageSpectrumLeftOut]

    var reference: FootageSpectrumMember { members[referenceIndex] }
    var recordIDs: [UUID] { members.map(\.id) }
    var paths: [String] { members.map(\.path) }
}

/// Why nothing was started.
struct FootageSpectrumRefusal: Error, Sendable, Equatable {
    var reason: String
}

// MARK: - Planner (pure)

enum FootageSpectrumPlanner {

    /// The most files one run compares — the page is one row per file, and
    /// eight rows is what a screen holds; the helper's pair table stops at
    /// six candidate pairs anyway.
    static let maxFiles = 8
    static let minFiles = 2

    /// What the Triage toolbar says about a selection of `count` rows.
    static func selectionAllowed(_ count: Int) -> Bool {
        count >= minFiles && count <= maxFiles
    }

    static func selectionHelp(_ count: Int) -> String {
        if count < minFiles {
            return "Select \(minFiles) to \(maxFiles) videos, then compare their pictures and sound side by side on one time line. Nothing is changed."
        }
        if count > maxFiles {
            return "\(count) selected — Compare Footage looks at up to \(maxFiles) at a time (one row per video is what a screen holds). Select fewer."
        }
        return "Compare the pictures and sound of the \(count) selected videos side by side on one time line. Nothing is changed."
    }

    /// Order, cap, choose the reference, leave out what cannot be read.
    ///
    ///   order      archive copies first, then `preferredFirst` (a group's
    ///              likely original), then the biggest first; ties by name
    ///              so the result is deterministic
    ///   cap        the first `maxFiles` readable ones; the rest are "left
    ///              out — over the limit"
    ///   reference  the first archive copy among those read, else the
    ///              longest (ties: the bigger, then the name)
    ///   refusal    fewer than `minFiles` readable
    ///
    /// Duplicated ids/paths are compared once.
    static func plan(candidates: [FootageSpectrumCandidate],
                     title: String,
                     preferredFirst: UUID? = nil) -> Result<FootageSpectrumPlan, FootageSpectrumRefusal> {
        var seenPaths = Set<String>()
        var unique: [FootageSpectrumCandidate] = []
        for c in candidates where seenPaths.insert(c.path).inserted {
            unique.append(c)
        }
        guard unique.count >= minFiles else {
            return .failure(FootageSpectrumRefusal(reason: unique.count == 1
                ? "Compare Footage needs at least \(minFiles) videos — only one was chosen."
                : "Compare Footage needs at least \(minFiles) videos — none were chosen."))
        }

        func rank(_ c: FootageSpectrumCandidate) -> (Int, Int, Int64, String) {
            (c.isArchiveCopy ? 0 : 1, c.id == preferredFirst ? 0 : 1, -c.sizeBytes, c.filename.lowercased())
        }
        let ordered = unique.sorted { rank($0) < rank($1) }

        var leftOut: [FootageSpectrumLeftOut] = []
        var readable: [FootageSpectrumCandidate] = []
        for c in ordered {
            if !c.isReadable {
                leftOut.append(FootageSpectrumLeftOut(id: c.id, filename: c.filename,
                                                      reason: "left out — its drive is not connected, or the file is gone"))
            } else if readable.count >= maxFiles {
                leftOut.append(FootageSpectrumLeftOut(id: c.id, filename: c.filename,
                                                      reason: "left out — over the limit of \(maxFiles) videos per comparison"))
            } else {
                readable.append(c)
            }
        }

        guard readable.count >= minFiles else {
            let offline = ordered.count - readable.count
            let reason: String
            if readable.isEmpty {
                reason = "None of the \(ordered.count) videos can be read right now — their drives are not connected, or the files are gone. Compare Footage needs at least \(minFiles)."
            } else {
                reason = "Only 1 of the \(ordered.count) videos can be read right now (\(offline) \(offline == 1 ? "is" : "are") on a drive that is not connected, or gone). Compare Footage needs at least \(minFiles)."
            }
            return .failure(FootageSpectrumRefusal(reason: reason))
        }

        // The reference: an archive copy if there is one, else the longest.
        let referenceIndex: Int
        if let archive = readable.firstIndex(where: \.isArchiveCopy) {
            referenceIndex = archive
        } else {
            var best = 0
            for i in readable.indices where longer(readable[i], than: readable[best]) { best = i }
            referenceIndex = best
        }

        // Labels: a letter tag the page shortens to, then the file name;
        // a repeated file name gets its volume so the rows read apart.
        var nameCounts: [String: Int] = [:]
        for c in readable { nameCounts[c.filename, default: 0] += 1 }
        let members = readable.enumerated().map { i, c -> FootageSpectrumMember in
            let shown = (nameCounts[c.filename] ?? 1) > 1 && !c.volumeLabel.isEmpty
                ? "\(c.filename) (\(c.volumeLabel))" : c.filename
            return FootageSpectrumMember(id: c.id, label: "\(letter(i)) · \(shown)", filename: c.filename,
                                         path: c.path, volumeLabel: c.volumeLabel, sizeBytes: c.sizeBytes,
                                         durationSeconds: c.durationSeconds, isArchiveCopy: c.isArchiveCopy)
        }
        return .success(FootageSpectrumPlan(title: title, members: members,
                                            referenceIndex: referenceIndex, leftOut: leftOut))
    }

    private static func longer(_ a: FootageSpectrumCandidate, than b: FootageSpectrumCandidate) -> Bool {
        if a.durationSeconds != b.durationSeconds { return a.durationSeconds > b.durationSeconds }
        if a.sizeBytes != b.sizeBytes { return a.sizeBytes > b.sizeBytes }
        return a.filename.lowercased() < b.filename.lowercased()
    }

    /// "A", "B", … "H" (and "I", "J"… should the cap ever grow).
    static func letter(_ index: Int) -> String {
        let scalar = UnicodeScalar(UInt8(65 + (index % 26)))
        return String(Character(scalar))
    }
}

// MARK: - sets.json (what the helper reads)

enum FootageSpectrumSets {

    /// `[{title, note, reference, files:[{label, path}]}]` — one set. The
    /// helper puts `files[reference]` first and reads the rest in order.
    static func json(for plan: FootageSpectrumPlan) throws -> Data {
        let set: [String: Any] = [
            "title": plan.title,
            "note": note(for: plan),
            "reference": plan.referenceIndex,
            "files": plan.members.map { ["label": $0.label, "path": $0.path] },
        ]
        return try JSONSerialization.data(withJSONObject: [set], options: [.prettyPrinted, .sortedKeys])
    }

    static func note(for plan: FootageSpectrumPlan) -> String {
        let ref = plan.reference
        var parts = ["Reference: \(ref.filename)" + (ref.isArchiveCopy ? " (the archive copy)" : " (the longest)")]
        if !plan.leftOut.isEmpty {
            parts.append("\(plan.leftOut.count) left out")
        }
        return parts.joined(separator: " · ")
    }
}

// MARK: - The helper's lines (parsed)

enum FootageSpectrumProtocol {

    struct Estimate: Sendable, Equatable {
        var file: Int
        var label: String
        var seconds: Double
        var cached: Bool
    }

    enum Phase: String, Sendable, Equatable {
        case reading, aligning, writing
    }

    struct Progress: Sendable, Equatable {
        var file: Int
        var of: Int
        var label: String
        var phase: Phase
        var fraction: Double
    }

    struct Skipped: Sendable, Equatable {
        var label: String
        var reason: String
    }

    struct FileResult: Sendable, Equatable {
        var label: String
        /// "reference" | "same" | "close" | "part" | "diff"
        var verdict: String
        var offset: Int
    }

    struct Summary: Sendable, Equatable {
        var same = 0
        var close = 0
        var part = 0
        var different = 0
        /// Share of the reference the others match between them (0…1).
        var covered = 0.0
    }

    struct Done: Sendable, Equatable {
        var html: String
        var files: Int
        var skipped: [Skipped]
        var summary: Summary?
        var results: [FileResult]
    }

    struct Failure: Sendable, Equatable {
        var message: String
        /// "numpy" | "ffmpeg" | "ffprobe" when a dependency is missing.
        var missing: String?
        var skipped: [Skipped]
    }

    enum Event: Sendable, Equatable {
        case estimate([Estimate], totalSeconds: Double)
        case progress(Progress)
        case done(Done)
        case error(Failure)
    }

    /// nil for anything that is not one of the four machine lines (the
    /// helper's human chatter goes to stderr, but be tolerant anyway).
    static func parse(_ line: String) -> Event? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let space = trimmed.firstIndex(of: " ") else { return nil }
        let kind = trimmed[..<space]
        guard ["ESTIMATE", "PROGRESS", "DONE", "ERROR"].contains(kind) else { return nil }
        guard let data = trimmed[trimmed.index(after: space)...].data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        switch kind {
        case "ESTIMATE":
            let files = (obj["files"] as? [[String: Any]] ?? []).map {
                Estimate(file: $0["file"] as? Int ?? 0, label: $0["label"] as? String ?? "",
                         seconds: $0["seconds"] as? Double ?? 0, cached: $0["cached"] as? Bool ?? false)
            }
            return .estimate(files, totalSeconds: obj["total_seconds"] as? Double ?? files.reduce(0) { $0 + $1.seconds })
        case "PROGRESS":
            guard let phase = Phase(rawValue: obj["phase"] as? String ?? "") else { return nil }
            return .progress(Progress(file: obj["file"] as? Int ?? 0, of: obj["of"] as? Int ?? 0,
                                      label: obj["label"] as? String ?? "", phase: phase,
                                      fraction: min(max(obj["fraction"] as? Double ?? 0, 0), 1)))
        case "DONE":
            var summary: Summary?
            if let s = obj["summary"] as? [String: Any] {
                summary = Summary(same: s["same"] as? Int ?? 0, close: s["close"] as? Int ?? 0,
                                  part: s["part"] as? Int ?? 0, different: s["different"] as? Int ?? 0,
                                  covered: s["covered"] as? Double ?? 0)
            }
            let results = (obj["results"] as? [[String: Any]] ?? []).map {
                FileResult(label: $0["label"] as? String ?? "", verdict: $0["verdict"] as? String ?? "",
                           offset: $0["offset"] as? Int ?? 0)
            }
            return .done(Done(html: obj["html"] as? String ?? "", files: obj["files"] as? Int ?? 0,
                              skipped: skipped(obj), summary: summary, results: results))
        default:
            return .error(Failure(message: obj["message"] as? String ?? "the helper reported an error",
                                  missing: obj["missing"] as? String, skipped: skipped(obj)))
        }
    }

    private static func skipped(_ obj: [String: Any]) -> [Skipped] {
        (obj["skipped"] as? [[String: Any]] ?? []).map {
            Skipped(label: $0["label"] as? String ?? "", reason: $0["reason"] as? String ?? "")
        }
    }
}

// MARK: - Time left (pure)

/// Work is measured in the helper's ESTIMATE seconds. Until a few seconds
/// have been observed the estimate is taken at face value; after that the
/// remaining work is scaled by the rate actually seen (elapsed ÷ work done),
/// so a slow drive or a fast cache shows in the number within seconds.
enum FootageSpectrumETA {

    struct Position: Sendable, Equatable {
        /// 1-based file being read; 0 before the first.
        var file: Int
        var fraction: Double
        var phase: FootageSpectrumProtocol.Phase
    }

    /// Reading is 0…0.94 of the bar; aligning and writing take the rest.
    static func overallFraction(estimates: [Double], at p: Position) -> Double {
        switch p.phase {
        case .aligning: return 0.96
        case .writing: return 0.98
        case .reading:
            let total = max(estimates.reduce(0, +), 0.0001)
            return min(0.94, 0.94 * workDone(estimates: estimates, at: p) / total)
        }
    }

    static func workDone(estimates: [Double], at p: Position) -> Double {
        guard p.phase == .reading else { return estimates.reduce(0, +) }
        var done = 0.0
        for (i, e) in estimates.enumerated() {
            let n = i + 1
            if n < p.file { done += e } else if n == p.file { done += e * min(max(p.fraction, 0), 1) }
        }
        return done
    }

    /// Seconds left, or nil when nothing is known yet.
    static func secondsLeft(estimates: [Double], at p: Position, elapsed: Double) -> Double? {
        guard !estimates.isEmpty else { return nil }
        let total = estimates.reduce(0, +)
        let done = workDone(estimates: estimates, at: p)
        let remaining = max(total - done, 0)
        if p.phase != .reading { return 2 }
        // A measured rate once 3 s and 5 % of the work are behind us.
        if elapsed >= 3, done >= 0.05 * total, done > 0 {
            return remaining * (elapsed / done)
        }
        return remaining
    }

    /// "about 1:10 left" / "about 20 s left" / "almost done".
    static func text(secondsLeft: Double?) -> String {
        guard let s = secondsLeft else { return "" }
        if s < 5 { return "almost done" }
        let n = Int(s.rounded())
        if n < 60 { return "about \(max(5, (n + 4) / 5 * 5)) s left" }
        if n < 3600 { return "about \(n / 60):\(String(format: "%02d", n % 60)) left" }
        return "about \(n / 3600) h \((n % 3600) / 60) min left"
    }
}

// MARK: - Words (pure)

enum FootageSpectrumWords {

    /// The collapsed row: "Reading 2 of 5 · clip.mov · about 1:10 left".
    static func rowText(_ p: FootageSpectrumProtocol.Progress, timeLeft: String) -> String {
        var parts: [String]
        switch p.phase {
        case .reading:
            let name = p.label.split(separator: "·", maxSplits: 1).last.map { $0.trimmingCharacters(in: .whitespaces) } ?? p.label
            parts = ["Reading \(p.file) of \(p.of)"]
            if !name.isEmpty { parts.append(name) }
        case .aligning:
            parts = ["Lining up \(p.of) videos"]
        case .writing:
            parts = ["Drawing the page"]
        }
        if !timeLeft.isEmpty { parts.append(timeLeft) }
        return parts.joined(separator: " · ")
    }

    /// "Compared 5 videos — 3 the same footage, 1 close, 1 different".
    static func summary(files: Int, summary: FootageSpectrumProtocol.Summary?, leftOut: Int) -> String {
        var text = "Compared \(files) video\(files == 1 ? "" : "s")"
        if let s = summary {
            var parts: [String] = []
            if s.same > 0 { parts.append("\(s.same) the same footage") }
            if s.close > 0 { parts.append("\(s.close) close") }
            if s.part > 0 { parts.append("\(s.part) partly the same") }
            if s.different > 0 { parts.append("\(s.different) different") }
            if !parts.isEmpty { text += " — " + parts.joined(separator: ", ") }
        }
        if leftOut > 0 { text += " · \(leftOut) left out" }
        return text
    }

    /// The per-file line in the job's detail.
    static func verdictWords(_ verdict: String, offset: Int) -> String {
        switch verdict {
        case "reference": return "the reference"
        case "same": return offset == 0 ? "the same footage" : "the same footage, starting \(clock(offset)) into the reference"
        case "close": return "close — probably the same footage from another transfer"
        case "part": return "partly the same"
        case "diff": return "different"
        default: return verdict
        }
    }

    static func clock(_ seconds: Int) -> String {
        let s = abs(seconds)
        let h = s / 3600, m = (s % 3600) / 60, r = s % 60
        let body = h > 0 ? String(format: "%d:%02d:%02d", h, m, r) : String(format: "%d:%02d", m, r)
        return seconds < 0 ? "-" + body : body
    }

    /// Why the helper cannot run, in words that say what to install.
    static func missingDependency(_ what: String) -> String {
        switch what {
        case "python": return "Compare Footage needs the Python helper (the venv next to the app's scripts) — it was not found."
        case "script": return "Compare Footage needs scripts/footage_spectrum.py — it was not found."
        case "numpy": return "Compare Footage needs numpy in the Python helper — install it in the venv."
        case "ffmpeg": return "Compare Footage needs ffmpeg — it was not found (Homebrew: brew install ffmpeg)."
        case "ffprobe": return "Compare Footage needs ffprobe — it was not found (Homebrew: brew install ffmpeg)."
        default: return "Compare Footage needs \(what) — it was not found."
        }
    }
}
