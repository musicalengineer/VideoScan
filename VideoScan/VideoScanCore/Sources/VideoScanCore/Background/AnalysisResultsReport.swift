// AnalysisResultsReport.swift (VideoScanCore/Background) — what the
// Content Analysis ▸ Results sheet shows (Rick 2026-11-04: "how can we see
// what it produced?"; background_service.md §6 view 1, BACKLOG 11/04).
//
// One sentence: per analyzer — keyed by its signer, so a second analyzer
// just appears — how many files it found an era for, found no usable era
// in, gave up on after 3 tries (with the reason), had its era rejected by
// Rick (counted apart: a vetoed value is never "found"), is still trying, and has
// still to do; how often its era agrees with Rick's confirmed date within
// 5 years; and its pace over the last hour and the last 24 hours.
//
// Where each number comes from (rule 1: evidence, not a remembered field):
//   found / rejected by you /          provenance_assertions, classified in
//   no usable era / given up           SQL (GRDBCatalogRepository+AnalysisResults)
//                                      with MachineEraResolver's selection and
//                                      veto rule (its SQL twin)
//   tries in progress                  background/attempts/era.jsonl through
//                                      EraAttemptStore.snapshot — READ ONLY
//                                      (never compacts); unreadable → nil and
//                                      the words say why. A try whose verdict
//                                      already landed (catalog row or journal
//                                      line) is not "in progress" (review 11/04)
//   still to do                        the era planner's own predicate
//                                      (EraPlanner.plannedFilesPredicate) minus
//                                      the planner's "cached" rule, both halves:
//                                      a catalog row by the signer OR a journal
//                                      line by it, applied or not
//                                      (EraPlanner.answeredInJournal) — so a
//                                      verdict waiting in the journal is not
//                                      "to do" (review 11/04). Only for
//                                      the seated analyzer: nothing plans an
//                                      older signer, so it has no "to do".
//                                      NOT the totals strip's number: the strip
//                                      does not count machine era (DECISIONS
//                                      2026-11-03; BackgroundServiceActivity).
//   agrees within 5 y                  MachineEraResolver's selection (newest
//                                      fused era per signer, Rick's rejection
//                                      honoured) and its `closeEnough` — the
//                                      SAME rule as Catalog Status's line —
//                                      against `user_dates.value` (see
//                                      CatalogAnalysisResultsRows.swift for why
//                                      that is the confirmed date)
//   pace                               the first `at` per content by the signer
//
// By ruling (DECISIONS 2026-11-01) a machine era is never a date and never a
// filter: the sheet shows it in human words, "early 1990s (1991–1995)", and
// `era.none` is never shown as an era.
//
// Pure apart from the reader it is handed; builds off the main actor.
// Memory: the report is a few dozen Ints per analyzer; a file list is at most
// `limit` rows (≈ 300 B each → 10k ≈ 3 MB).
//
// (For Rick: a report object built by a static factory from a DAO — like a
// C++ `Report::build(const Reader&)` returning a plain struct.)

import Foundation

public struct AnalysisResultsReport: Sendable, Equatable {

    /// The six lists the sheet offers, in its order.
    public enum Outcome: String, Sendable, CaseIterable, Identifiable {
        case eraFound, rejected, eraNone, gaveUp, inProgress, stillToDo
        public var id: String { rawValue }

        public var title: String {
            switch self {
            case .eraFound: return "Era found"
            case .rejected: return "Rejected by you"
            case .eraNone: return "No usable era"
            case .gaveUp: return "Given up after \(EraAttemptStore.maxTries) tries"
            case .inProgress: return "Tries in progress"
            case .stillToDo: return "Still to do"
            }
        }
    }

    public struct Rate: Sendable, Equatable {
        public var lastHour: Int
        public var last24Hours: Int
        public init(lastHour: Int, last24Hours: Int) {
            self.lastHour = lastHour
            self.last24Hours = last24Hours
        }
    }

    public struct Analyzer: Sendable, Equatable, Identifiable {
        public var signer: String
        public var id: String { signer }
        /// "8B" (MachineEraResolver.modelShortName).
        public var modelShortName: String
        /// The analyzer the helper runs today (SeatedApproach.eraA2's signer).
        public var isSeated: Bool
        public var analyzed: Int
        public var eraFound: Int
        /// The analyzer's era, which Rick rejected afterwards: never "Era found" (Codex 11/05).
        public var rejected: Int
        public var eraNone: Int
        public var gaveUp: Int
        /// nil = the try counts could not be read (`AnalysisResultsReport.triesProblem` says why).
        public var triesInProgress: Int?
        /// nil = not the seated analyzer: nothing plans it, so nothing is "to do".
        public var stillToDo: Int?
        /// Files with Rick's confirmed date and an era by this signer; `total` 0 = none yet.
        public var agreement: MachineEraConvergence
        public var rate: Rate

        public init(signer: String, modelShortName: String, isSeated: Bool, analyzed: Int, eraFound: Int, rejected: Int = 0,
                    eraNone: Int, gaveUp: Int,
                    triesInProgress: Int?, stillToDo: Int?, agreement: MachineEraConvergence, rate: Rate) {
            self.signer = signer
            self.modelShortName = modelShortName
            self.isSeated = isSeated
            self.analyzed = analyzed
            self.eraFound = eraFound
            self.rejected = rejected
            self.eraNone = eraNone
            self.gaveUp = gaveUp
            self.triesInProgress = triesInProgress
            self.stillToDo = stillToDo
            self.agreement = agreement
            self.rate = rate
        }

        /// Analyzed, but in none of the four verdict lists (only an ocr.date
        /// row, or a malformed fused value) — shown so the numbers add up.
        public var other: Int { max(0, analyzed - eraFound - rejected - eraNone - gaveUp) }

        /// The count beside an outcome; nil = not known (said in words).
        public func count(_ outcome: Outcome) -> Int? {
            switch outcome {
            case .eraFound: return eraFound
            case .rejected: return rejected
            case .eraNone: return eraNone
            case .gaveUp: return gaveUp
            case .inProgress: return triesInProgress
            case .stillToDo: return stillToDo
            }
        }
    }

    public var analyzers: [Analyzer]
    /// Why "tries in progress" is unavailable (the attempts file's own words); nil = read fine.
    public var triesProblem: String?
    /// Unix seconds the report was built (the pace's "now").
    public var builtAt: Int64

    public init(analyzers: [Analyzer] = [], triesProblem: String? = nil, builtAt: Int64 = 0) {
        self.analyzers = analyzers
        self.triesProblem = triesProblem
        self.builtAt = builtAt
    }

    // MARK: Build

    /// The whole report from one read snapshot. `attempts` is the try counts'
    /// read (a failure becomes words, never a guess); `journal` is the
    /// helper's journal (nil = none: a viewer, a test without one);
    /// `seatedSigner` always appears, even before its first verdict.
    public static func build(reader: any CatalogAnalysisResultsReading, attempts: Result<EraAttemptSnapshot, Refusal>,
                             journal: ObservationJournal?, seatedSigner: String = SeatedApproach.eraA2.signer,
                             now: Int64) throws -> AnalysisResultsReport {
        var counts = try reader.analyzerOutcomeCounts()
        if !counts.contains(where: { $0.signer == seatedSigner }) {
            counts.insert(CatalogRow.AnalyzerOutcomeCounts(signer: seatedSigner, analyzed: 0, eraFound: 0, eraNone: 0, gaveUp: 0), at: 0)
        }
        let agreements = try agreements(reader: reader)
        var snapshot: EraAttemptSnapshot?
        var problem: String?
        switch attempts {
        case .success(let s): snapshot = s
        case .failure(let r): problem = r.words
        }
        var analyzers: [Analyzer] = []
        for c in counts {
            let seated = c.signer == seatedSigner
            let inJournal = journal.map { EraPlanner.answeredInJournal($0, signer: c.signer) } ?? []
            let toDo: Int? = seated ? try stillToDo(reader: reader, signer: c.signer, inJournal: inJournal).count : nil
            let trying = try snapshot.map { try inProgress(reader: reader, signer: c.signer, attempts: $0, inJournal: inJournal).count }
            let rate = Rate(lastHour: try reader.analyzerFirstVerdicts(signer: c.signer, since: now - 3_600),
                            last24Hours: try reader.analyzerFirstVerdicts(signer: c.signer, since: now - 86_400))
            analyzers.append(Analyzer(
                signer: c.signer, modelShortName: MachineEraResolver.modelShortName(by: c.signer), isSeated: seated,
                analyzed: c.analyzed, eraFound: c.eraFound, rejected: c.rejected, eraNone: c.eraNone, gaveUp: c.gaveUp,
                triesInProgress: trying,
                stillToDo: toDo, agreement: agreements[c.signer] ?? MachineEraConvergence(total: 0, agree: 0), rate: rate))
        }
        analyzers.sort { ($0.isSeated ? 0 : 1, $0.signer) < ($1.isSeated ? 0 : 1, $1.signer) }
        return AnalysisResultsReport(analyzers: analyzers, triesProblem: problem, builtAt: now)
    }

    /// The try counts, read-only (EraAttemptStore.snapshot); any failure is
    /// carried as words, never thrown — the rest of the report still builds.
    public static func readAttempts(stateRoot: URL) -> Result<EraAttemptSnapshot, Refusal> {
        do { return .success(try EraAttemptStore.snapshot(stateRoot: stateRoot)) } catch let r as Refusal {
            return .failure(r)
        } catch {
            return .failure(Refusal("the try counts could not be read (\(error))"))
        }
    }

    /// The planner's "not cached" for `signer`: planned contents with no
    /// catalog row by it, minus those with a journal line by it.
    static func stillToDo(reader: any CatalogAnalysisResultsReading, signer: String, inJournal: Set<String>) throws -> [String] {
        try reader.eraUnansweredInCatalog(signer: signer).filter { !inJournal.contains($0) }
    }

    /// The signer's try entries whose content has no verdict yet (no catalog
    /// row and no journal line by the signer). An entry left behind by a
    /// crash between "verdict appended" and "try cleared" is not in progress.
    /// Public: the Realtime Content Analysis window's "trying" reads this
    /// same rule (Codex F6, 2026-11-05) — one rule, not two.
    public static func inProgress(reader: any CatalogAnalysisResultsReading, signer: String, attempts: EraAttemptSnapshot,
                           inJournal: Set<String>) throws -> [String: EraAttempt] {
        let tries = attempts.attempts(signer: signer)
        guard !tries.isEmpty else { return [:] }
        let answered = try reader.analyzerAnswered(signer: signer, digests: tries.keys.sorted()).union(inJournal)
        return tries.filter { !answered.contains($0.key) }
    }

    /// Per signer: N of M contents (Rick's date AND that signer's shown era)
    /// whose era is `closeEnough` — the resolver picks the era exactly as the
    /// inspector does; the rule is Catalog Status's.
    static func agreements(reader: any CatalogAnalysisResultsReading) throws -> [String: MachineEraConvergence] {
        var out: [String: MachineEraConvergence] = [:]
        try reader.eraFusedRowsOfDatedContents { _, rickDate, rows in
            guard let year = MachineEraResolver.rickYear(rickDate) else { return }
            for era in MachineEraResolver.eras(fromRowsOfOneSubject: rows) {
                var c = out[era.by] ?? MachineEraConvergence(total: 0, agree: 0)
                c.total += 1
                if MachineEraResolver.closeEnough(era: era, rickYear: year) { c.agree += 1 }
                out[era.by] = c
            }
        }
        return out
    }

    // MARK: The file lists

    /// One row of a list, in words.
    public struct FileRow: Sendable, Equatable, Identifiable {
        /// The content digest (one row per content).
        public var id: String { digest }
        public var digest: String
        /// The catalog record to reveal (files.id); nil when the content has no file row.
        public var recordID: UUID?
        public var filename: String
        public var path: String
        /// Every file of the content is removed from the catalog.
        public var removed: Bool
        /// The era in words, or what the verdict was ("no usable era", "tried 2 of 3 times").
        public var value: String
        /// The verdict's reason, verbatim (empty when there is none).
        public var reason: String

        public init(digest: String, recordID: UUID?, filename: String, path: String, removed: Bool, value: String, reason: String) {
            self.digest = digest
            self.recordID = recordID
            self.filename = filename
            self.path = path
            self.removed = removed
            self.value = value
            self.reason = reason
        }
    }

    public struct FileList: Sendable, Equatable {
        public var signer: String
        public var outcome: Outcome
        public var rows: [FileRow]
        /// The list stopped at `limit`.
        public var truncated: Bool

        public init(signer: String, outcome: Outcome, rows: [FileRow], truncated: Bool) {
            self.signer = signer
            self.outcome = outcome
            self.rows = rows
            self.truncated = truncated
        }
    }

    /// The default cap of a list (Table copes; the words say when it is hit).
    public static let listLimit = 10_000

    /// The files of one outcome for one signer, by file name. Pass the helper's
    /// `journal` (the app does; AnalysisResultsSheetSensorTests pins it): without
    /// it, "still to do" and "in progress" see only the catalog half of the rule.
    public static func files(reader: any CatalogAnalysisResultsReading, signer: String, outcome: Outcome,
                             attempts: EraAttemptSnapshot?, journal: ObservationJournal? = nil, limit: Int = listLimit) throws -> FileList {
        var rows: [FileRow]
        var truncated: Bool
        switch outcome {
        case .eraFound, .rejected, .eraNone, .gaveUp:
            let kind: CatalogRow.AnalyzerVerdictKind
            switch outcome {
            case .eraFound: kind = .eraFound
            case .rejected: kind = .rejected
            case .eraNone: kind = .eraNone
            default: kind = .gaveUp
            }
            let found = try reader.analyzerOutcomeFiles(signer: signer, kind: kind, limit: limit + 1)
            truncated = found.count > limit
            rows = found.prefix(limit).map { row(outcome, $0) }
        case .stillToDo:
            // The LIMIT is in SQL (review 11/05: this used to read every unanswered
            // content, then cut). A journal-answered content is dropped here, so ask for
            // `limit + 1 + |journal|`: enough to fill the list and know it was cut.
            // Memory: at most limit + 1 + |journal| rows (≈ 300 B each).
            let inJournal = journal.map { EraPlanner.answeredInJournal($0, signer: signer) } ?? []
            let page = try reader.eraUnansweredFiles(signer: signer, limit: limit + 1 + inJournal.count)
            let kept = page.filter { !inJournal.contains($0.digest) }
            truncated = kept.count > limit
            rows = kept.prefix(limit).map { row(outcome, $0) }
        case .inProgress:
            let inJournal = journal.map { EraPlanner.answeredInJournal($0, signer: signer) } ?? []
            let tries = try attempts.map { try inProgress(reader: reader, signer: signer, attempts: $0, inJournal: inJournal) } ?? [:]
            let byDigest = Dictionary(try reader.analyzerFiles(digests: tries.keys.sorted()).map { ($0.digest, $0) },
                                      uniquingKeysWith: { a, _ in a })
            rows = tries.map { digest, attempt in
                let file = byDigest[digest] ?? CatalogRow.AnalyzerOutcomeFile(digest: digest, fileID: nil, path: nil, filename: nil, removed: true)
                var r = row(outcome, file)
                r.value = "tried \(attempt.tries) of \(EraAttemptStore.maxTries) times"
                r.reason = attempt.lastReason
                return r
            }
            rows.sort { ($0.filename.lowercased(), $0.path, $0.digest) < ($1.filename.lowercased(), $1.path, $1.digest) }
            truncated = rows.count > limit
            rows = Array(rows.prefix(limit))
        }
        return FileList(signer: signer, outcome: outcome, rows: rows, truncated: truncated)
    }

    static func row(_ outcome: Outcome, _ f: CatalogRow.AnalyzerOutcomeFile) -> FileRow {
        let value: String
        switch outcome {
        case .eraFound: value = f.value.map(eraWords) ?? ""
        case .rejected: value = "rejected by you: " + (f.value.map(eraWords) ?? "")
        case .eraNone: value = "no usable era"
        case .gaveUp: value = "given up"
        case .inProgress: value = ""
        case .stillToDo: value = "not analyzed yet"
        }
        return FileRow(digest: f.digest, recordID: f.fileID.flatMap(UUID.init(uuidString:)),
                       filename: f.filename ?? "(no file in the catalog)", path: f.path ?? "", removed: f.removed,
                       value: value, reason: f.reason ?? "")
    }

    // MARK: Words (pure; the sheet reads them)

    /// "early 1990s (1991–1995)", "1980s–1990s (1988–1992)", "1960s (1960–1969)":
    /// the long decade words MachineEraResolver.searchWords gives a person,
    /// most specific first, then the range. Never a date. A value that is not
    /// a range is shown as stored.
    public static func eraWords(_ value: String) -> String {
        guard let r = MachineEraResolver.range(value) else { return value }
        let era = MachineEra(lo: r.lo, hi: r.hi, by: "", at: 0, seq: 0)
        // Long forms end in a 4-digit decade: "1990s", "early 1990s".
        let long = MachineEraResolver.searchWords(era: era).filter { ($0.split(separator: " ").last?.count ?? 0) == 5 }
        let decades = long.filter { !$0.contains(" ") }
        let words = long.first(where: { $0.contains(" ") })
            ?? (decades.count > 1 ? "\(decades.first ?? "")–\(decades.last ?? "")" : decades.first ?? era.rangeText)
        return "\(words) (\(era.rangeText))"
    }

    /// "3 in the last hour · 70 in the last 24 hours".
    public static func rateWords(_ rate: Rate) -> String {
        "\(rate.lastHour.formatted()) in the last hour · \(rate.last24Hours.formatted()) in the last 24 hours"
    }

    /// The plain ETA for `stillToDo` at the last 24 h rate; never a made-up number.
    public static func etaWords(stillToDo: Int?, rate: Rate) -> String {
        guard let stillToDo else { return "not planned: this is not the analyzer the helper runs today" }
        if stillToDo == 0 { return "nothing left to analyze" }
        guard rate.last24Hours > 0 else { return "no rate yet: nothing analyzed in the last 24 hours, so no estimate" }
        let hours = Double(stillToDo) * 24 / Double(rate.last24Hours)
        if hours < 1 { return "under an hour at the last 24 h rate" }
        let whole = Int(hours.rounded())
        let days = hours >= 48 ? " (about \(Int((hours / 24).rounded())) days)" : ""
        return "about \(whole.formatted()) hour\(whole == 1 ? "" : "s")\(days) at the last 24 h rate"
    }

    /// "12 of 15 (80 %)", or why there is no number.
    public static func agreementWords(_ c: MachineEraConvergence) -> String {
        guard c.total > 0 else { return "no file with your confirmed date has an era from this analyzer yet" }
        return "\(c.agree.formatted()) of \(c.total.formatted()) (\(c.percent) %)"
    }

    /// The count beside an outcome, or why there is none.
    public func countWords(_ analyzer: Analyzer, _ outcome: Outcome) -> String {
        if let n = analyzer.count(outcome) { return n.formatted() }
        switch outcome {
        case .inProgress: return "unavailable"
        default: return "—"
        }
    }
}
