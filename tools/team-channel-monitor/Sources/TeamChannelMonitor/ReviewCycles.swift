import Foundation
import Darwin

/// One codex review cycle as written by tools/codex_review.py
/// (review-cycles.json, beside the channel DB). Only the fields the
/// monitor shows are decoded; everything is optional so a newer or older
/// writer never makes the section vanish over one field.
struct ReviewCycle: Decodable, Equatable {
    var id: Int?
    var title: String?
    var range: String?
    var phase: String?
    var phaseSince: String?
    var pid: Int32?
    var closedBy: String?
    var findings: Int?
    var failure: String?
}

/// One line of the "Review cycles" section: `<title> — <phase words> <age>`.
struct ReviewCycleLine: Equatable, Identifiable {
    enum Colour: Equatable { case green, yellow, red }
    let id: Int
    let text: String
    let colour: Colour
}

/// Pure rules (no I/O except the injected pid probe), so every threshold is unit-testable.
/// Rick's rule for this monitor: message id and stuck-or-waiting, nothing more.
enum ReviewCycles {
    static let yellowAfter: TimeInterval = 10 * 60
    static let redAfter: TimeInterval = 30 * 60
    /// "fixing" is an agent's fix round (20–40 min is normal), not codex
    /// thinking (2–5 min) — Rick 2026-09-27: give it its own limits so a
    /// normal fix round doesn't turn red.
    static let fixingYellowAfter: TimeInterval = 60 * 60
    static let fixingRedAfter: TimeInterval = 2 * 60 * 60
    static let closedHiddenAfter: TimeInterval = 24 * 60 * 60
    static let shown = 3

    static var fileURL: URL {
        URL(fileURLWithPath: ChannelDB.path).deletingLastPathComponent()
            .appendingPathComponent("review-cycles.json")
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Absent or malformed file → [] → the section is hidden. Never throws.
    static func load(from url: URL = fileURL) -> [ReviewCycle] {
        guard let data = try? Data(contentsOf: url),
              let cycles = try? JSONDecoder().decode([ReviewCycle].self, from: data) else { return [] }
        return cycles
    }

    /// `kill(pid, 0)` sends nothing; it only asks whether the pid exists.
    /// EPERM means it exists but belongs to someone else — still alive.
    static func isAlive(_ pid: Int32) -> Bool {
        pid > 0 && (kill(pid, 0) == 0 || errno == EPERM)
    }

    static func colour(phase: String, age: TimeInterval, pidAlive: Bool) -> ReviewCycleLine.Colour {
        switch phase {
        case "closed": return .green
        case "failed": return .red
        case "running" where !pidAlive: return .red   // codex died without a verdict
        case "fixing":
            if age >= fixingRedAfter { return .red }
            if age >= fixingYellowAfter { return .yellow }
            return .green
        default:
            if age >= redAfter { return .red }
            if age >= yellowAfter { return .yellow }
            return .green
        }
    }

    static func ageText(_ t: TimeInterval) -> String {
        let m = max(0, Int(t / 60))
        if m < 60 { return "\(m)m" }
        if m < 24 * 60 { return "\(m / 60)h \(m % 60)m" }
        return "\(m / (24 * 60))d"
    }

    static func phaseWords(_ c: ReviewCycle) -> String {
        switch c.phase ?? "" {
        case "briefed": return "briefed"
        case "running": return "codex running"
        case "verdict": return "writing verdict"
        case "fixing":
            if let n = c.findings { return "fixing \(n) finding\(n == 1 ? "" : "s")" }
            return "fixing"
        case "failed": return "failed" + (c.failure.map { " (\($0))" } ?? "")
        case let other: return other.isEmpty ? "?" : other
        }
    }

    /// Newest `shown` cycles still worth a glance, one line each.
    static func lines(_ cycles: [ReviewCycle], now: Date = Date(),
                      pidAlive: (Int32) -> Bool = isAlive) -> [ReviewCycleLine] {
        var out: [ReviewCycleLine] = []
        for c in cycles.sorted(by: { ($0.id ?? 0) > ($1.id ?? 0) }) {
            guard let phase = c.phase, let since = c.phaseSince.flatMap({ iso.date(from: $0) }) else { continue }
            let age = now.timeIntervalSince(since)
            if phase == "closed" && age > closedHiddenAfter { continue }
            let title = c.title ?? "?"
            let text: String
            if phase == "closed" {
                text = "\(title) — closed " + (c.closedBy.map { String($0.prefix(8)) } ?? ageText(age))
            } else {
                let start = c.range.map { " (\(String($0.split(separator: ".").first ?? "").prefix(8)))" } ?? ""
                text = "\(title)\(start) — \(phaseWords(c)) \(ageText(age))"
            }
            let alive = c.pid.map(pidAlive) ?? false
            out.append(ReviewCycleLine(id: c.id ?? out.count, text: text,
                                       colour: colour(phase: phase, age: age, pidAlive: alive)))
            if out.count == shown { break }
        }
        return out
    }
}
