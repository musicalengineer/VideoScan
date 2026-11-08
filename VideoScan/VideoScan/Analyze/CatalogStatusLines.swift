// CatalogStatusLines.swift — what Catalog Status says, built in ONE place.
//
// THE STRIP (Rick 2026-11-03, DECISIONS "two indicators, Catalog and
// Content"): the totals strip shows two indicators, never one chip —
//
//   ● Catalog: Synced        ● Content: Up to date
//
//   Catalog   the Database and Files lines below, combined (the worst of the
//             two): Synced (green) · Stale (yellow) · Unhealthy (red) ·
//             Unknown (grey: not counted yet, or a drive needed to decide is
//             not connected) · Checking… (grey: a check running over a stale
//             verdict, or an Update running — GH #441). The
//             sound print sidecar that can't be opened is Catalog red (the
//             Database line): storage trouble, not analysis. Click → the
//             Catalog Status window, which says per colour why and what to do.
//   Content   the Content line: Up to date (green) · N left to analyze
//             (grey) · Analyzing N of M files (blue). NEVER yellow, NEVER red.
//             Rick's reasoning: content is almost always behind; it is a work
//             in progress, not an alarm; a yellow that is always on teaches
//             the eye to ignore yellow, including Catalog's. Per-file analysis
//             problems are listed in Content Analysis (click), never here.
//
// THE THREE LINES under it, in the Catalog Status window (Rick 2026-11-01):
//
//   ● Database   does the last integrity check pass, and is it recent?
//                integrity-latest.json (IntegrityReportFacts — the same strict
//                read the Integrity row and the Database facts' "Last
//                Validate Catalog" row take). GREEN = it completed, found
//                no break, within 7 days (CatalogRealityPolicy.freshFor — the
//                backstop; the app runs the check itself daily, DailyFileCheck);
//                YELLOW = older, stopped, or never ran here; RED = it failed,
//                its report cannot be read, it found a structural BREAK
//                (reality.breaks — a tier 4 / 5 decision), or the sound print
//                sidecar can't be opened. Findings no verb can clear never
//                colour it (Rick 2026-11-02; DECISIONS 2026-10-20 "N to review
//                never changes the colour"). Every coloured line reads
//                "<Colour>: <cause>. Fix: <verb>" (or "Fix: no fix yet").
//   ● Files      is every file where the catalog says? The last file check's
//                record (catalog-audit.json → CatalogAuditPresenceFacts and the
//                band's PresenceTally) for present / unsettled / not checked,
//                and the coverage pass's Missing rows (MissingCopyCounts — what
//                the band's review items count). A Missing file that IS
//                missing is reality: it never colours the line (10/20 ruling).
//                GREY when a large share was on drives not connected at the
//                check and some are still not connected (named).
//   ● Content    the coverage report's PER-FILE count of connected files with
//                at least one counted analysis left (contentFiles), with the
//                per-analyzer counts beneath it.
//
// Built in ONE place — CatalogFreshnessSnapshot.rejudge, from the facts and
// the report it already holds — so the strip, the menu title, the window and
// the band can never read different sources. Pure: values in, words out;
// `now` injected. Memory: three small structs and a few strings.
//
// (For Rick: `CatalogStatusLineState` is Comparable — grey < green <
// inProgress < yellow < red — so "the worst line" is a `max` with a
// tie-break, like std::max_element.)

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

/// A line's state. Four are the band's colours; `inProgress` (blue) is the
/// Content line's own (Rick 2026-11-01 evening): work is left AND an
/// analyzer or the background service is on it.
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
    /// The entities the words name — the drives a Files line asks to connect
    /// (the coverage tally's roots). Compared EXACTLY by the transition log
    /// (Codex closing-5): a name is never parsed back out of the prose.
    var names: [String] = []
    /// The same line built TIMELESS — the identical builder, facts and `now`
    /// (so the same colour), with the check's date and age written as "WHEN".
    /// The transition log compares these (Codex closing passes 3–8: no
    /// masking of the shown words can tell a name from a timestamp; building
    /// the cause without the timestamp can). nil = compare `words`/`detail`.
    var cause: String?
    var causeDetail: [String]?
}

/// One of the two indicators on the totals strip.
struct CatalogStatusIndicator: Sendable, Equatable {
    enum Kind: String, Sendable { case catalog, content }

    var kind: Kind
    var state: CatalogStatusLineState
    /// What follows "Catalog: " / "Content: " on the strip.
    var words: String
    /// The window's lead under the dot: why this colour, and what to do or
    /// what is happening underneath (so a grey says whether to wait).
    var why: [String] = []

    static let catalogPrefix = "Catalog: "
    static let contentPrefix = "Content: "
    /// Catalog's grey while a check is under way — Validate Catalog over a
    /// Stale verdict, or an Update (GH #441, Rick 2026-11-06): undecided,
    /// the verdict is coming. Grey for any other reason reads "Unknown".
    static let checking = "Checking…"

    /// Catalog's four words (Rick 2026-11-03), one per colour.
    static func catalogWords(_ s: CatalogStatusLineState) -> String {
        switch s {
        case .green: return "Synced"
        case .yellow: return "Stale"
        case .red: return "Unhealthy"
        case .grey, .inProgress: return "Unknown"
        }
    }
}

/// The strip's pair, from the snapshot's state — grey "Unknown" /
/// "Counting…" until the first pass has landed.
struct CatalogStatusIndicators: Sendable, Equatable {
    var catalog: CatalogStatusIndicator
    var content: CatalogStatusIndicator

    static let counting = "Counting…"

    init(_ state: CatalogFreshnessState) {
        self.init(state.isComputed ? state.lines : nil)
    }

    init(_ lines: CatalogStatusLines?) {
        guard let lines else {
            catalog = CatalogStatusIndicator(kind: .catalog, state: .grey, words: CatalogStatusIndicator.catalogWords(.grey),
                                             why: ["\(Self.counting) the first pass over the catalog has not landed yet — wait a moment."])
            content = CatalogStatusIndicator(kind: .content, state: .grey, words: Self.counting,
                                             why: ["\(Self.counting) the first pass over the catalog has not landed yet — wait a moment."])
            return
        }
        catalog = lines.catalog
        content = lines.contentIndicator
    }
}

struct CatalogStatusLines: Sendable, Equatable {
    var database: CatalogStatusLine
    var files: CatalogStatusLine
    var content: CatalogStatusLine
    /// Validate Catalog (the file check or the integrity check) is running
    /// now: a Stale verdict is about to be replaced, so Catalog reads grey
    /// "Checking…" until it lands. Red stays red; green stays green.
    var checking = false
    /// "Update everything stale" is running (GH #441): its steps rebuild
    /// what the check judges and its LAST step is the check, so any colour
    /// before then is about to be replaced — Catalog reads grey "Checking…"
    /// whatever the lines say. The lines themselves, and the transition log,
    /// are untouched (the truth is still said; only the indicator waits),
    /// and the window's lead repeats what the last check found.
    var updating = false

    var all: [CatalogStatusLine] { [database, files, content] }

    /// The two lines Catalog combines. Content is not one of them.
    var catalogLines: [CatalogStatusLine] { [database, files] }

    /// The worst non-green CATALOG line (red over yellow; ties in display
    /// order); nil = none needs attention. Content never needs attention
    /// (Rick 2026-11-03), so it is never the worst.
    var worst: CatalogStatusLine? {
        let bad = catalogLines.filter(\.state.needsAttention)
        guard let top = bad.map(\.state).max() else { return nil }
        return bad.first { $0.state == top }
    }

    /// Catalog = Database + Files, the worst of the two; a running check
    /// turns a Stale into grey "Checking…"; a running Update turns every
    /// colour grey "Checking…"; grey beats green (a drive needed to decide
    /// is not connected).
    var catalogState: CatalogStatusLineState {
        if updating { return .grey }
        let states = catalogLines.map(\.state)
        if states.contains(.red) { return .red }
        if states.contains(.yellow) { return checking ? .grey : .yellow }
        if states.contains(.grey) { return .grey }
        return .green
    }

    /// Catalog's grey means "a check is under way", not "undecided".
    var isChecking: Bool {
        updating || (checking && catalogState == .grey && catalogLines.contains { $0.state == .yellow })
    }

    static let updatingWhy = "Checking… Update is running; its last step is Validate Catalog, and that check's verdict "
        + "colours Catalog when it finishes — nothing to do but wait."

    /// The strip's Catalog indicator and the window's lead under it.
    var catalog: CatalogStatusIndicator {
        let state = catalogState
        var why: [String] = []
        if updating {
            // What the last check said rides beneath, so nothing true is hidden.
            why = [Self.updatingWhy]
                + catalogLines.filter { $0.state != .green }.map { "Before this Update — \($0.kind.title): \($0.words)" }
            return CatalogStatusIndicator(kind: .catalog, state: .grey, words: CatalogStatusIndicator.checking, why: why)
        }
        switch state {
        case .red:
            why = catalogLines.filter { $0.state == .red }.map { "\($0.kind.title): \($0.words)" }
        case .yellow:
            why = catalogLines.filter { $0.state == .yellow }.map { "\($0.kind.title): \($0.words)" }
        case .grey:
            if checking && catalogLines.contains(where: { $0.state == .yellow }) {
                why.append("Checking… Validate Catalog is running — the verdict lands when it finishes; nothing to do but wait.")
            }
            why += catalogLines.filter { $0.state == .grey }.map { "\($0.kind.title): \($0.words)" }
        case .green, .inProgress:
            break
        }
        let words = isChecking ? CatalogStatusIndicator.checking : CatalogStatusIndicator.catalogWords(state)
        return CatalogStatusIndicator(kind: .catalog, state: state, words: words, why: why)
    }

    /// The strip's Content indicator: the Content line's own state and words.
    var contentIndicator: CatalogStatusIndicator {
        CatalogStatusIndicator(kind: .content, state: content.state, words: content.words, why: content.detail)
    }

    /// Catalog ▸ "Catalog Status — Files needs attention…" / "— Green…".
    static func menuTitle(_ lines: CatalogStatusLines?) -> String {
        guard let lines, !lines.updating, lines.catalogLines.allSatisfy({ $0.state != .grey }) else { return "Catalog Status…" }
        guard let worst = lines.worst else { return "Catalog Status — Green…" }
        return "Catalog Status — \(worst.kind.title) needs attention…"
    }
}

enum CatalogStatusLinesPolicy {

    /// The analyzers whose stamps say "analyzed" — the Content line's counts
    /// (the coverage pass's per-file count uses the same list).
    static var contentAnalyzers: [AnalyzeCycler] { AnalyzeCoverageReport.contentAnalyzers }

    /// `backgroundDetail`: the helper's work that the Content numbers do NOT
    /// count (the era job's "Machine era: N of M" line), shown under Content.
    static func lines(facts: CatalogFreshnessFacts, report: AnalyzeCoverageReport, now: Date, working: Bool = false,
                      checking: Bool = false, updating: Bool = false, backgroundDetail: [String] = [],
                      date: (Date) -> String = Self.date) -> CatalogStatusLines {
        var content = content(report, working: working)
        content.detail = backgroundDetail + content.detail
        return CatalogStatusLines(database: database(facts.integrity, soundStoreProblem: facts.soundStoreProblem, now: now, date: date),
                                  files: files(facts, missing: report.missingCopies, offline: report.offlineFilesByRoot, now: now, date: date),
                                  content: content,
                                  checking: checking,
                                  updating: updating)
    }

    /// Something is on the content work right now: an analyzer the Content
    /// line counts is running (MFO job, engine flag or the dossier engine —
    /// the snapshot's `running` set), or the background helper is running a
    /// job that feeds one (BackgroundServiceActivity.isActive — never a
    /// queued, paused or waiting job, never the era job: Codex 11/03 F2).
    static func contentIsWorking(running: Set<AnalyzeCycler>, backgroundActive: Bool) -> Bool {
        backgroundActive || !running.isDisjoint(with: contentAnalyzers)
    }

    /// Validate Catalog's steps (the file check, the integrity check) are
    /// running — the Catalog indicator's "Checking…".
    static func catalogIsChecking(running: Set<AnalyzeCycler>) -> Bool {
        running.contains(.filePresence) || running.contains(.integrity)
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

    /// The sidecar's red words (Rick 2026-11-03: Catalog, not Content). No
    /// verb in VideoScan repairs it — said honestly.
    static func soundStoreWords(_ problem: String) -> String {
        "Red: the sound print sidecar (\(AudioFingerprintStore.fileName)) can't be opened — \(problem). "
            + "Fix: no fix yet — no verb in VideoScan repairs it; the sound prints in it can't be read until it is replaced"
    }

    /// The integrity line, then the sidecar: a sidecar that can't be opened
    /// makes the line red. When the check is red too, the check's words lead
    /// and the sidecar rides beneath; otherwise the sidecar leads and the
    /// check's own verdict rides beneath (nothing said is lost).
    static func database(_ f: IntegrityReportFacts, soundStoreProblem: String? = nil, now: Date,
                         date: (Date) -> String) -> CatalogStatusLine {
        var line = databaseLine(f, soundStoreProblem: soundStoreProblem, now: now, date: date, timeless: false)
        let bare = databaseLine(f, soundStoreProblem: soundStoreProblem, now: now, date: date, timeless: true)
        line.cause = bare.words
        line.causeDetail = bare.detail
        return line
    }

    private static func databaseLine(_ f: IntegrityReportFacts, soundStoreProblem: String?, now: Date,
                                     date: (Date) -> String, timeless: Bool) -> CatalogStatusLine {
        var line = integrity(f, now: now, date: date, timeless: timeless)
        guard let soundStoreProblem else { return line }
        if line.state == .red {
            line.detail.append(soundStoreWords(soundStoreProblem))
        } else {
            line = CatalogStatusLine(kind: .database, state: .red, words: soundStoreWords(soundStoreProblem),
                                     detail: ["Integrity check: \(line.words)"] + line.detail)
        }
        return line
    }

    /// The check's date and age as the words show them — or "WHEN" for the
    /// timeless build the transition log compares.
    static func stamp(_ d: Date, now: Date, date: (Date) -> String, timeless: Bool) -> String {
        timeless ? "WHEN" : "\(date(d)) (\(age(d, now: now)))"
    }

    /// Rick 2026-11-02 (DECISIONS 2026-11-02): a coloured line says 1. exactly
    /// why it is that colour and 2. exactly how to fix it — "Red: <cause>.
    /// Fix: <verb>", "Yellow: <cause>. Fix: Check Now…". RED only for a
    /// check that failed or cannot be read, or a structural BREAK —
    /// `reality.breaks`: a decided tier 4 / 5 constraint finding such as an
    /// event member pointing at nothing — each named with its verb (or "no
    /// verb yet", honestly). A finding no verb can clear (tier 3's measured
    /// silence) is information: it never colours this line, so the decision
    /// counts (`needsDecision`) are not read here at all. YELLOW = older
    /// than the 7-day backstop (`CatalogRealityPolicy.freshFor`), stopped
    /// part way, or never ran. GREEN = completed within it and found no break.
    static func integrity(_ f: IntegrityReportFacts, now: Date, date: (Date) -> String, timeless: Bool = false) -> CatalogStatusLine {
        func line(_ c: FreshnessColour, _ w: String, _ d: [String] = []) -> CatalogStatusLine {
            CatalogStatusLine(kind: .database, state: CatalogStatusLineState(c), words: w, detail: d)
        }
        let checkNow = "Fix: Check Now… runs Validate Catalog"
        if let problem = f.problem {
            return line(.red, "Red: the last integrity check's report can't be read — \(problem). \(checkNow) and writes a new report")
        }
        if f.predatesSwitch { return line(.yellow, "Yellow: not checked since the switch to SQLite. \(checkNow)") }
        let when = f.lastCompleted.map { " " + stamp($0, now: now, date: date, timeless: timeless) } ?? ""
        switch f.outcome {
        case .neverRan:
            return line(.yellow, "Yellow: not checked yet. \(checkNow)")
        case .failed:
            return line(.red, "Red: the last integrity check failed. Fix: Check Now… runs it again")
        case .partial:
            return line(.yellow, "Yellow: the last integrity check stopped part way\(when) — not a full check. Fix: Check Now… runs it again")
        case .ok:
            break
        }
        let breaks = f.reality.breaks.filter { $0.count >= 1 }
        if !breaks.isEmpty { return line(.red, breakWords(breaks, details: f.reality.breakDetails, when: when), breakDetail(breaks, details: f.reality.breakDetails)) }
        var detail: [String] = []
        if f.unverified > 0, let gaps = f.unverifiedWords { detail.append("not verified: \(gaps)") }
        // Facts the check recorded that nothing needs to clear — said, never coloured.
        if f.reality.measuredSilence > 0 { detail.append(VerifyCatalogTiers.measuredSilenceWords(f.reality.measuredSilence)) }
        detail += f.reality.information
        guard let at = f.lastCompleted else { return line(.yellow, "Yellow: not checked yet. \(checkNow)") }
        if now.timeIntervalSince(at) <= CatalogRealityPolicy.freshFor {
            return line(.green, "Integrity check passed\(when)", detail)
        }
        return line(.yellow, "Yellow: the last integrity check passed\(when) — older than \(CatalogRealityPolicy.freshForWords). Fix: Check Now… runs it again", detail)
    }

    /// "Red: event "Matt": a member points at a row that no longer exists
    /// (id:…) — checked 2 Nov 10:41 (1 h ago)" when the one break is one
    /// finding the report kept; otherwise the counted rules ("Red: 2 event
    /// members point at nothing · 1 paths have more than one live row — …").
    static func breakWords(_ breaks: [CatalogRealityCount], details: [String], when: String) -> String {
        let found = breaks.reduce(0) { $0 + $1.count }
        let cause = (found == 1 && details.count == 1) ? details[0] : breaks.map(\.words).joined(separator: " · ")
        return "Red: \(cause) — checked\(when)"
    }

    /// Under the words: each kept finding ("Why: …") when the words counted
    /// rather than named, then one "Fix: …" per broken rule.
    static func breakDetail(_ breaks: [CatalogRealityCount], details: [String]) -> [String] {
        let found = breaks.reduce(0) { $0 + $1.count }
        var out: [String] = []
        if !(found == 1 && details.count == 1) { out += details.map { "Why: \($0)" } }
        out += breaks.map { "Fix: \($0.fix ?? CatalogConstraints.Rule.defaultFix)" }
        return out
    }

    // MARK: Files

    /// "/Volumes/X9 (1,204 files) · /Volumes/Y (3 files)" — the drives with
    /// live rows not connected now (the coverage pass's tally), most first,
    /// three named and the rest counted.
    static func drivesWords(_ offline: [String: Int]) -> String {
        let sorted = offline.filter { $0.value > 0 }.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        func name(_ root: String) -> String { root == AnalyzeCoverageCalculator.otherRoot ? "files outside any scan target" : root }
        var parts = sorted.prefix(3).map { "\(name($0.key)) (\($0.value.formatted()) file\($0.value == 1 ? "" : "s"))" }
        if sorted.count > 3 { parts.append("\(sorted.count - 3) more") }
        return parts.joined(separator: " · ")
    }

    static func files(_ facts: CatalogFreshnessFacts, missing: MissingCopyCounts, offline: [String: Int] = [:], now: Date,
                      date: (Date) -> String) -> CatalogStatusLine {
        var line = filesLine(facts, missing: missing, offline: offline, now: now, date: date, timeless: false)
        let bare = filesLine(facts, missing: missing, offline: offline, now: now, date: date, timeless: true)
        line.cause = bare.words
        line.causeDetail = bare.detail
        return line
    }

    private static func filesLine(_ facts: CatalogFreshnessFacts, missing: MissingCopyCounts, offline: [String: Int], now: Date,
                                  date: (Date) -> String, timeless: Bool) -> CatalogStatusLine {
        func line(_ c: FreshnessColour, _ w: String, _ d: [String] = []) -> CatalogStatusLine {
            CatalogStatusLine(kind: .files, state: CatalogStatusLineState(c), words: w, detail: d)
        }
        let checkNow = "Fix: Check Now… runs Validate Catalog"
        let markedMissing = missing.noOtherCopy + missing.otherCopyPresent + missing.possibleCopyNotProven
        let missingWords = "\(markedMissing.formatted()) missing"
        if let problem = facts.auditProblem {
            return line(.red, "Red: the last file check's record can't be read — \(problem). \(checkNow) and writes a new record")
        }
        let presence = CatalogAuditPresenceFacts.from(facts.audit, switchedAt: facts.switchedAt)
        if presence.predatesSwitch || presence.outcome == .neverRan {
            return line(.yellow, "Yellow: files not checked yet · \(missingWords). \(checkNow), which checks every file")
        }
        let tally = CatalogRealityFactsBuilder.PresenceTally(facts.audit, switchedAt: facts.switchedAt)
        let present = (facts.audit?.counts[CatalogAuditResult.present.rawValue] ?? 0)
            + (facts.audit?.counts[CatalogAuditResult.cameBack.rawValue] ?? 0)
        let when = presence.lastCompleted.map { " · checked " + stamp($0, now: now, date: date, timeless: timeless) } ?? ""
        let words = "\(present.formatted()) present where the catalog says · \(missingWords)\(when)"
        var detail = tally.unsettled.map(\.words)
        if tally.notChecked > 0 {
            detail.append("\(tally.notChecked.formatted()) of \(tally.planned.formatted()) not checked (drives not connected, or could not check)")
        }
        switch presence.outcome {
        case .failed: return line(.red, "Red: the last file check did not finish · \(missingWords). Fix: Check Now… runs Validate Catalog again", detail)
        case .partial: return line(.yellow, "Yellow: \(words) — the last check stopped part way. Fix: Check Now… runs it again", detail)
        case .neverRan, .ok: break
        }
        if !tally.unsettled.isEmpty {
            let n = tally.unsettled.reduce(0) { $0 + $1.count }
            return line(.yellow, "Yellow: \(words) — \(n.formatted()) file\(n == 1 ? "" : "s") out of step with the catalog. "
                        + "Fix: no verb yet — Fix Links is not built; Validate Catalog's detail in Media File Operations lists them", detail)
        }
        // The large share not checked, split by why: a drive not connected
        // (`notAsked`) is grey while it is still away, a check that could not
        // read is yellow (Check Now… asks again).
        let notAsked = facts.audit?.counts[CatalogAuditResult.notAsked.rawValue] ?? 0
        let unreachable = tally.notChecked - notAsked
        func large(_ n: Int) -> Bool {
            tally.planned > 0 && Double(n) / Double(tally.planned) >= CatalogRealityPolicy.largeShareNotChecked
        }
        let stale = presence.lastCompleted.map { now.timeIntervalSince($0) > CatalogRealityPolicy.freshFor } ?? true
        if large(unreachable) {
            return line(.yellow, "Yellow: \(words) — \(unreachable.formatted()) of \(tally.planned.formatted()) files could not be checked. Fix: Check Now… runs it again", detail)
        }
        if stale { return line(.yellow, "Yellow: \(words) — older than \(CatalogRealityPolicy.freshForWords). Fix: Check Now… runs it again", detail) }
        if large(notAsked) || large(tally.notChecked) {
            let share = "\(notAsked.formatted()) of \(tally.planned.formatted()) files were on drives not connected at the last check"
            if offline.values.contains(where: { $0 > 0 }) {
                var grey = line(.grey, "Unknown: \(share) — not connected now: \(drivesWords(offline)). Fix: connect them, then Check Now…", detail)
                grey.names = offline.filter { $0.value > 0 }.keys.sorted()
                return grey
            }
            return line(.yellow, "Yellow: \(words) — \(share); every drive is connected now. \(checkNow)", detail)
        }
        return line(.green, words, detail)
    }

    // MARK: Content

    /// Never yellow, never red (Rick 2026-11-03, header). Green = nothing
    /// left; blue = work left and something is on it; grey = work left,
    /// nothing running it (normal) or not counted yet. The words count
    /// FILES (the coverage pass's per-file tally, `contentFiles`); a report
    /// without that tally (hand-built) counts analyses instead — never a
    /// number the report does not hold.
    /// What the grey N counts, in words (tooltip and window).
    static func countsFiles(_ n: Int) -> String {
        "\(n.formatted()) counts files on connected drives with at least one counted analysis left"
    }

    /// Files Analyze skips because their bytes could not be decoded.
    static func cannotDecodeWords(_ n: Int) -> String {
        "\(n.formatted()) file\(n == 1 ? "" : "s") could not be decoded (this copy or another copy of the same content needs reformat) — "
            + "not counted as left; right-click a file ▸ Analyze to try one again"
    }

    /// Files the dossier pass analyzed without a transcript.
    static func noTranscriptWords(_ n: Int) -> String {
        "\(n.formatted()) file\(n == 1 ? " was" : "s were") analyzed without a transcript — not counted as left: "
            + "Analyze never runs an analyzed file again, so nothing would transcribe it today"
    }

    static func content(_ report: AnalyzeCoverageReport, working: Bool = false) -> CatalogStatusLine {
        func line(_ s: CatalogStatusLineState, _ w: String, _ d: [String] = []) -> CatalogStatusLine {
            CatalogStatusLine(kind: .content, state: s, words: w, detail: d)
        }
        guard report.computedAt.timeIntervalSince1970 > 0 else { return line(.grey, CatalogStatusIndicators.counting) }
        let notCounted = "Embedded Dates and Inferred Dates are not counted: a file with none can never be marked as looked at."
        var analysesLeft = 0
        let left = contentAnalyzers.compactMap { c -> String? in
            let n = report.counts(c).remaining
            analysesLeft += n
            return n > 0 ? "\(c.title) \(n.formatted())" : nil
        }
        let offline = report.contentFiles.offline
        var detail: [String] = []
        if !left.isEmpty { detail.append("Not yet analyzed: " + left.joined(separator: " · ")) }
        if offline > 0 { detail.append("\(offline.formatted()) file\(offline == 1 ? " on drives not connected is" : "s on drives not connected are") not counted") }
        // Observed, not left (Rick 2026-11-06, "88 left"): Analyze skips these,
        // so they are said apart with the reason, never counted as left.
        if report.cannotDecode > 0 { detail.append(Self.cannotDecodeWords(report.cannotDecode)) }
        let noTranscript = report.counts(.transcribe).secondary
        if noTranscript > 0 { detail.append(Self.noTranscriptWords(noTranscript)) }
        detail.append(notCounted)
        if left.isEmpty { return line(.green, "Up to date", detail) }
        let files = report.contentFiles
        if working {
            if files.remaining > 0 {
                return line(.inProgress, "Analyzing \(files.covered.formatted()) of \(files.eligible.formatted()) files",
                            ["\(files.covered.formatted()) of \(files.eligible.formatted()) files on connected drives have every counted analysis; "
                             + Self.countsFiles(files.remaining)] + detail)
            }
            return line(.inProgress, "Analyzing — \(analysesLeft.formatted()) left to analyze",
                        ["\(analysesLeft.formatted()) counts analyzer-file pairs (no per-file tally in this report)"] + detail)
        }
        // Rick 2026-11-03: grey reads "N left to analyze". N = files with at
        // least one counted analysis left (the per-file tally); the detail
        // says what N counts, so the tooltip and window can state it.
        if files.remaining > 0 {
            return line(.grey, "\(files.remaining.formatted()) left to analyze",
                        [Self.countsFiles(files.remaining)] + detail)
        }
        return line(.grey, "\(analysesLeft.formatted()) left to analyze",
                    ["\(analysesLeft.formatted()) counts analyzer-file pairs (no per-file tally in this report)"] + detail)
    }
}

// MARK: - Transitions → the log (Codex 11/03 F6)

/// What Catalog Status says changed, in words for the one log sink — one
/// line per Database / Files / Content line whose colour or cause changed,
/// never per recompute. "Cause" = the words with their digits taken out, so
/// a count ticking ("Analyzing 12 of 300" → "13 of 300") or an age ("1 h
/// ago" → "2 h ago") is not a change; a different reason is. A first
/// judgement says only the lines that are not green ("appear"); a line that
/// goes green says so ("clear"). Pure. (For Rick: a diff of two small
/// structs, keyed like a debounced edge detector.)
enum CatalogStatusTransitions {

    static func word(_ line: CatalogStatusLine) -> String {
        guard line.kind == .content else { return CatalogStatusIndicator.catalogWords(line.state) }
        switch line.state {
        case .green: return "Up to date"
        case .inProgress: return "Analyzing"
        default: return "Left to analyze"
        }
    }

    /// What the transition log compares (Codex closing passes 3–8), by what
    /// the words ARE:
    ///   Database / Files — names and facts: the line's TIMELESS build
    ///     (`CatalogStatusLine.cause` / `causeDetail`), compared exactly — no
    ///     pattern, no substring removal, so no name can be masked;
    ///   Content — counts only: free-standing numbers masked (`cause(_:)`).
    /// Drive names also ride as data (`CatalogStatusLine.names`).
    static func cause(_ words: String) -> String {
        countMask?.stringByReplacingMatches(in: words, range: NSRange(words.startIndex..., in: words), withTemplate: "#") ?? words
    }

    /// Free-standing numbers with their separators ("1,000", "12.5"); a
    /// number glued to a letter ("X9") stays.
    private static let countMask = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}/_.-])\d[\d,.]*(?![\p{L}\p{N}])"#)

    static func key(_ line: CatalogStatusLine) -> String {
        line.kind == .content ? cause(line.words) : (line.cause ?? line.words)
    }

    static func detailKey(_ line: CatalogStatusLine) -> [String] { line.causeDetail ?? line.detail }

    static func lines(old: CatalogStatusLines?, new: CatalogStatusLines) -> [String] {
        var out: [String] = []
        for (i, line) in new.all.enumerated() {
            let title = line.kind.title
            // Database / Files carry further causes in their detail (the sound
            // sidecar under a failed check): said with the headline whenever the
            // headline is said (Codex closing-2 #2). Content's detail is counts.
            let causes = line.kind == .content || line.detail.isEmpty ? "" : " · " + line.detail.joined(separator: " · ")
            guard let was = old?.all[i] else {
                if line.state != .green { out.append("\(title): \(word(line)) (\(line.words))\(causes)") }
                continue
            }
            if was.state != line.state {
                out.append("\(title): \(word(was)) → \(word(line)) (\(line.words))\(causes)")
            } else if key(was) != key(line) || was.names != line.names {
                out.append("\(title): \(word(line)) — now: \(line.words)\(causes)")
            } else if line.kind != .content, detailKey(was) != detailKey(line) {
                // A second cause under the same colour (the sound sidecar under a
                // failed check) rides in the detail: its arrival and clearing are
                // changes too (Codex closing #4). Content's detail is counts.
                let wasKeys = detailKey(was), nowKeys = detailKey(line)
                let added = zip(line.detail, nowKeys).filter { !wasKeys.contains($0.1) }.map(\.0)
                let gone = zip(was.detail, wasKeys).filter { !nowKeys.contains($0.1) }.map(\.0)
                out.append("\(title): \(word(line)) — " + (added.map { "now also: \($0)" } + gone.map { "cleared: \($0)" }).joined(separator: " · "))
            }
        }
        return out
    }
}
