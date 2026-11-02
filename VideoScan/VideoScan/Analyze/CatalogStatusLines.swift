// CatalogStatusLines.swift — the three questions Catalog Status answers
// (Rick 2026-11-01, DECISIONS "… Catalog Status answers three questions"):
//
//   ● Database   does the last integrity check pass, and is it recent?
//                integrity-latest.json (IntegrityReportFacts — the same strict
//                read the Integrity row and the Database facts' "Last
//                Validate Catalog" row take). GREEN = it completed, found
//                nothing, within 24 hours (CatalogRealityPolicy.freshFor);
//                YELLOW = older, stopped, or never ran here; RED = it found
//                something, failed, or its report cannot be read.
//   ● Files      is every file where the catalog says? The last file check's
//                record (catalog-audit.json → CatalogAuditPresenceFacts and the
//                band's PresenceTally) for present / unsettled / not checked,
//                and the coverage pass's Missing rows (MissingCopyCounts — what
//                the band's review items count). A Missing file that IS
//                missing is reality: it never colours the line (10/20 ruling).
//   ● Content    is the analysis current? The coverage report's per-analyzer
//                "not yet analyzed on a connected drive" counts — the cycler
//                stamps the Content Analysis rows read. GREEN = nothing left;
//                IN PROGRESS (blue) = work left and a counted analyzer or the
//                background helper is on it; YELLOW = work left and nothing
//                will do it (Rick 2026-11-01 evening). The title names only
//                yellow and red lines.
//
// The menu title names the worst line: "Catalog Status — Files needs
// attention…", or "Catalog Status — Green…" when all three are green
// (ties: Database, then Files, then Content).
//
// Built in ONE place — CatalogFreshnessSnapshot.rejudge, from the facts and
// the report it already holds — so the menu title, the window and the band
// can never read different sources. Pure: values in, words out; `now`
// injected. Memory: three small structs.
//
// (For Rick: `FreshnessColour` is Comparable — grey < green < yellow < red —
// so "the worst line" is a `max` with a tie-break, like std::max_element.)

import Foundation
import VideoScanCore

enum CatalogStatusLineKind: String, CaseIterable, Sendable {
    case database, files, content

    var title: String {
        switch self {
        case .database: return "Database"
        case .files: return "Files"
        case .content: return "Content"
        }
    }
}

/// A line's state. Four are the band's colours; `inProgress` is the
/// Content line's own (Rick 2026-11-01 evening): work is left AND an
/// analyzer or the background service is on it — not "you must act".
enum CatalogStatusLineState: Int, Sendable, Equatable, Comparable {
    case grey, green, inProgress, yellow, red

    init(_ c: FreshnessColour) {
        switch c {
        case .grey: self = .grey
        case .green: self = .green
        case .yellow: self = .yellow
        case .red: self = .red
        }
    }

    /// Yellow and red ask a person to act; the menu title names only those.
    var needsAttention: Bool { self == .yellow || self == .red }

    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct CatalogStatusLine: Sendable, Equatable {
    var kind: CatalogStatusLineKind
    var state: CatalogStatusLineState
    /// The verdict in words, with its date where it has one.
    var words: String
    /// Further lines under it (what is unsettled, what is not counted).
    var detail: [String] = []
}

struct CatalogStatusLines: Sendable, Equatable {
    var database: CatalogStatusLine
    var files: CatalogStatusLine
    var content: CatalogStatusLine

    var all: [CatalogStatusLine] { [database, files, content] }

    /// The worst non-green line (red over yellow; ties in display order); nil = all green.
    var worst: CatalogStatusLine? {
        let bad = all.filter(\.state.needsAttention)
        guard let top = bad.map(\.state).max() else { return nil }
        return bad.first { $0.state == top }
    }

    /// Catalog ▸ "Catalog Status — Files needs attention…" / "— Green…".
    static func menuTitle(_ lines: CatalogStatusLines?) -> String {
        guard let lines, lines.all.allSatisfy({ $0.state != .grey }) else { return "Catalog Status…" }
        guard let worst = lines.worst else { return "Catalog Status — Green…" }
        return "Catalog Status — \(worst.kind.title) needs attention…"
    }
}

enum CatalogStatusLinesPolicy {

    /// The analyzers whose stamps say "analyzed" — the Content line's counts.
    /// Embedded Dates and Inferred Dates are not here: a file whose camera
    /// wrote no date can never carry their stamp, so their "left" is not
    /// "not yet analyzed" (the line says so). Footage and Correlate keep no
    /// per-file stamp (AnalyzeCoverageReport.coverageUnknown / pairs).
    static let contentAnalyzers: [AnalyzeCycler] = [.fullHashes, .soundPrints, .duplicates, .sceneCaptions,
                                                     .ocr, .transcribe, .fileSignatures]

    static func lines(facts: CatalogFreshnessFacts, report: AnalyzeCoverageReport, now: Date, working: Bool = false,
                      date: (Date) -> String = Self.date) -> CatalogStatusLines {
        CatalogStatusLines(database: database(facts.integrity, now: now, date: date),
                           files: files(facts, missing: report.missingCopies, now: now, date: date),
                           content: content(report, soundStoreProblem: facts.soundStoreProblem, working: working))
    }

    /// Something is on the content work right now: an analyzer the Content
    /// line counts is running (MFO job, engine flag or the dossier engine —
    /// the snapshot's `running` set), or the background helper has a job.
    static func contentIsWorking(running: Set<AnalyzeCycler>, backgroundActive: Bool) -> Bool {
        backgroundActive || !running.isDisjoint(with: contentAnalyzers)
    }

    static func date(_ d: Date) -> String { d.formatted(date: .abbreviated, time: .shortened) }

    /// "today 02:14" style is the formatter's; the age rides beside it.
    static func age(_ d: Date, now: Date) -> String {
        let s = max(0, now.timeIntervalSince(d))
        if s < 3_600 { return "\(max(1, Int(s / 60))) min ago" }
        if s < 48 * 3_600 { return "\(Int(s / 3_600)) h ago" }
        return "\(Int(s / 86_400)) days ago"
    }

    // MARK: Database

    static func database(_ f: IntegrityReportFacts, now: Date, date: (Date) -> String) -> CatalogStatusLine {
        func line(_ c: FreshnessColour, _ w: String, _ d: [String] = []) -> CatalogStatusLine {
            CatalogStatusLine(kind: .database, state: CatalogStatusLineState(c), words: w, detail: d)
        }
        if let problem = f.problem { return line(.red, "The last integrity check's report can't be read — \(problem)") }
        if f.predatesSwitch { return line(.yellow, "Not checked since the switch to SQLite — Check Now… runs Validate Catalog") }
        let breaks = f.reality.breaks.filter { $0.count >= 1 }
        let found = f.needsDecision + breaks.reduce(0) { $0 + $1.count }
        let when = f.lastCompleted.map { " \(date($0)) (\(age($0, now: now)))" } ?? ""
        switch f.outcome {
        case .neverRan:
            return line(.yellow, "Not checked yet — Check Now… runs Validate Catalog")
        case .failed:
            return line(.red, "The last integrity check failed — run it again")
        case .partial:
            return line(.yellow, "The last integrity check stopped part way\(when) — not a full check")
        case .ok:
            break
        }
        if found > 0 {
            let words = f.decisionWords ?? breaks.map(\.words).joined(separator: " · ")
            return line(.red, "Checked\(when): found \(found.formatted()) thing\(found == 1 ? "" : "s") to look at", words.isEmpty ? [] : [words])
        }
        var detail: [String] = []
        if f.unverified > 0, let gaps = f.unverifiedWords { detail.append("not verified: \(gaps)") }
        guard let at = f.lastCompleted else { return line(.yellow, "Not checked yet — Check Now… runs Validate Catalog") }
        if now.timeIntervalSince(at) <= CatalogRealityPolicy.freshFor {
            return line(.green, "Integrity check passed\(when)", detail)
        }
        return line(.yellow, "Integrity check passed\(when) — older than 24 hours; Check Now… runs it again", detail)
    }

    // MARK: Files

    static func files(_ facts: CatalogFreshnessFacts, missing: MissingCopyCounts, now: Date,
                      date: (Date) -> String) -> CatalogStatusLine {
        func line(_ c: FreshnessColour, _ w: String, _ d: [String] = []) -> CatalogStatusLine {
            CatalogStatusLine(kind: .files, state: CatalogStatusLineState(c), words: w, detail: d)
        }
        let markedMissing = missing.noOtherCopy + missing.otherCopyPresent + missing.possibleCopyNotProven
        let missingWords = "\(markedMissing.formatted()) missing"
        if let problem = facts.auditProblem { return line(.red, "The last file check's record can't be read — \(problem)") }
        let presence = CatalogAuditPresenceFacts.from(facts.audit, switchedAt: facts.switchedAt)
        if presence.predatesSwitch || presence.outcome == .neverRan {
            return line(.yellow, "Not checked yet · \(missingWords) — Validate Catalog checks every file")
        }
        let tally = CatalogRealityFactsBuilder.PresenceTally(facts.audit, switchedAt: facts.switchedAt)
        let present = (facts.audit?.counts[CatalogAuditResult.present.rawValue] ?? 0)
            + (facts.audit?.counts[CatalogAuditResult.cameBack.rawValue] ?? 0)
        let when = presence.lastCompleted.map { " · checked \(date($0)) (\(age($0, now: now)))" } ?? ""
        let words = "\(present.formatted()) present where the catalog says · \(missingWords)\(when)"
        var detail = tally.unsettled.map(\.words)
        if tally.notChecked > 0 {
            detail.append("\(tally.notChecked.formatted()) of \(tally.planned.formatted()) not checked (drives not connected, or could not check)")
        }
        switch presence.outcome {
        case .failed: return line(.red, "The last file check did not finish · \(missingWords) — run Validate Catalog again", detail)
        case .partial: return line(.yellow, words + " — the last check stopped part way", detail)
        case .neverRan, .ok: break
        }
        let stale = presence.lastCompleted.map { now.timeIntervalSince($0) > CatalogRealityPolicy.freshFor } ?? true
        let unsettled = !tally.unsettled.isEmpty
        let largeShare = tally.planned > 0 && Double(tally.notChecked) / Double(tally.planned) >= CatalogRealityPolicy.largeShareNotChecked
        if unsettled || largeShare { return line(.yellow, words, detail) }
        if stale { return line(.yellow, words + " — older than 24 hours", detail) }
        return line(.green, words, detail)
    }

    // MARK: Content

    static func content(_ report: AnalyzeCoverageReport, soundStoreProblem: String?, working: Bool = false) -> CatalogStatusLine {
        func line(_ c: FreshnessColour, _ w: String, _ d: [String] = []) -> CatalogStatusLine {
            CatalogStatusLine(kind: .content, state: CatalogStatusLineState(c), words: w, detail: d)
        }
        guard report.computedAt.timeIntervalSince1970 > 0 else { return line(.grey, "Counting…") }
        let notCounted = "Embedded Dates and Inferred Dates are not counted: a file with none can never be marked as looked at."
        if let soundStoreProblem {
            return line(.red, "The sound print sidecar can't be opened — \(soundStoreProblem)", [notCounted])
        }
        let left = contentAnalyzers.compactMap { c -> String? in
            let n = report.counts(c).remaining
            return n > 0 ? "\(c.title) \(n.formatted())" : nil
        }
        let offline = contentAnalyzers.reduce(0) { $0 + report.counts($1).offline }
        var detail: [String] = []
        if offline > 0 { detail.append("files on drives not connected are not counted (\(offline.formatted()) analyzer-file pairs)") }
        detail.append(notCounted)
        if left.isEmpty { return line(.green, "Every file on a connected drive is analyzed", detail) }
        // Rick 2026-11-01 evening: work left is "in progress" while something
        // is on it, and yellow ("you must act") only when nothing will do it.
        if working {
            return CatalogStatusLine(kind: .content, state: .inProgress,
                                     words: "In progress — not yet analyzed: " + left.joined(separator: " · "), detail: detail)
        }
        return line(.yellow, "Not yet analyzed: " + left.joined(separator: " · ") + " — nothing is running it", detail)
    }
}
