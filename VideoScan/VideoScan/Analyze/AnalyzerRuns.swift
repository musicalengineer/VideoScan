// AnalyzerRuns.swift — the three analyzers that left the Catalog menu for
// Content Analysis (Rick 2026-11-01): Embedded Dates, Full Hashes, Sound
// Fingerprints. Their rows say what they do in one sentence and how long a
// run would take, from the LAST run's pace and the count left ("not run
// yet" when no run has been measured); Run / Pause are the rows' existing
// controls (AnalyzeRunner — the same engines the menu items started).
//
// Three pieces, none on VideoScanModel (rule 12):
//   * `AnalyzerRunRate` / `AnalyzerRunRates` — the last measured pace per
//     analyzer, one tiny Codable value per key in UserDefaults (bytes; the
//     panel reads three keys on its 1 s tick). A run with no files or no
//     time records nothing — an unknown pace stays unknown, never 0.
//   * `AnalyzerRunWords` — pure: one sentence per analyzer; the estimate.
//   * `AnalyzerRunFollowUp` — told by the MFO center exactly once per job at
//     its terminal transition (`MediaFileOperationsCenter.onJobTerminal`):
//     records the pace of a Full Hashes / Sound Fingerprints run, and when a
//     whole-catalog Full Hashes run reaches 100 % (every file it set out to
//     hash was hashed — an offline lane, a missing or unreadable file means
//     no split, and the log says why; Codex #189)
//     runs Split Duplicate Groups by Full Hash — the SAME call the retired
//     menu item made (`splitDuplicateGroupsKeepingSameFootage`), which
//     writes its own START / OUTCOME lines; this file adds one line saying
//     why it started. Embedded Dates is not an MFO job: AnalyzeRunner
//     measures it around its one await.
//
// Pace = files resolved ÷ (finishedAt − startedAt). Paused time is inside
// that span, so a paused run reads slower than it was — said in the words
// ("at the last run's pace"), never presented as a measured speed.
//
// (For Rick: `Codable` ≈ a struct with generated serialize/deserialize;
// the follow-up's closures ≈ std::function members injected for tests.)

import Foundation
import VideoScanCore

// MARK: - The last run's pace

struct AnalyzerRunRate: Codable, Sendable, Equatable {
    /// Files the run resolved (whatever the outcome).
    var files: Int
    var seconds: Double
    var finishedAt: Date

    var filesPerSecond: Double { seconds > 0 ? Double(files) / seconds : 0 }
}

enum AnalyzerRunRates {

    /// The analyzers this applies to, in Content Analysis order.
    static let analyzers: [AnalyzeCycler] = [.fullHashes, .soundPrints, .embeddedDates]

    static func key(_ c: AnalyzeCycler) -> String { "analyze.lastRunRate.\(c.rawValue)" }

    static func read(_ c: AnalyzeCycler, defaults: UserDefaults = .standard) -> AnalyzerRunRate? {
        guard let data = defaults.data(forKey: key(c)) else { return nil }
        return try? JSONDecoder().decode(AnalyzerRunRate.self, from: data)
    }

    /// Records a run's pace; a run with no files or no time is not a pace.
    static func record(_ c: AnalyzeCycler, files: Int, seconds: Double, finishedAt: Date = Date(),
                       defaults: UserDefaults = .standard) {
        guard files > 0, seconds > 0, seconds.isFinite else { return }
        let rate = AnalyzerRunRate(files: files, seconds: seconds, finishedAt: finishedAt)
        guard let data = try? JSONEncoder().encode(rate) else { return }
        defaults.set(data, forKey: key(c))
    }

    static func readAll(defaults: UserDefaults = .standard) -> [AnalyzeCycler: AnalyzerRunRate] {
        var out: [AnalyzeCycler: AnalyzerRunRate] = [:]
        for c in analyzers { out[c] = read(c, defaults: defaults) }
        return out
    }
}

// MARK: - Words (pure)

enum AnalyzerRunWords {

    /// What it does, in one sentence (shown on the row).
    static func sentence(_ c: AnalyzeCycler) -> String? {
        switch c {
        case .embeddedDates:
            return "Reads the recording date and camera each file carries inside it — one quick tag read per file with no date yet."
        case .fullHashes:
            return "Reads each file once, in full, and keeps its SHA-256 so copies are proved byte for byte; at 100 % it splits duplicate groups whose files differ."
        case .soundPrints:
            return "Listens to each file once and keeps a small fingerprint of its sound, so copies and clips of the same recording can be told apart."
        default:
            return nil
        }
    }

    /// "How long: about 3 h 10 min for 660 files left, at the last run's pace (210 files an hour)".
    static func howLong(remaining: Int, rate: AnalyzerRunRate?) -> String {
        guard remaining > 0 else { return "How long: nothing left to do" }
        let left = "\(remaining.formatted()) file\(remaining == 1 ? "" : "s") left"
        guard let rate, rate.filesPerSecond > 0 else { return "How long: not run yet — \(left)" }
        let seconds = Double(remaining) / rate.filesPerSecond
        return "How long: \(duration(seconds)) for \(left), at the last run's pace (\(pace(rate)))"
    }

    /// "under a minute" · "about 12 min" · "about 3 h 10 min" · "about 4 days".
    static func duration(_ s: Double) -> String {
        if s < 60 { return "under a minute" }
        let minutes = Int((s / 60).rounded())
        if minutes < 60 { return "about \(minutes) min" }
        let hours = minutes / 60, rest = minutes % 60
        if hours >= 48 { return "about \(Int((Double(minutes) / 1_440).rounded())) days" }
        return rest == 0 ? "about \(hours) h" : "about \(hours) h \(rest) min"
    }

    /// "210 files an hour" / "14 files a minute" / "3 files a second".
    static func pace(_ r: AnalyzerRunRate) -> String {
        let perSecond = r.filesPerSecond
        if perSecond >= 1 { return "\(Int(perSecond.rounded()).formatted()) files a second" }
        if perSecond * 60 >= 1 { return "\(Int((perSecond * 60).rounded()).formatted()) files a minute" }
        return "\(max(1, Int((perSecond * 3_600).rounded())).formatted()) files an hour"
    }
}

// MARK: - After a job ends

@MainActor
final class AnalyzerRunFollowUp {

    /// What a terminal job tells the follow-up (a value, so the rule is a table test).
    struct Ending: Equatable {
        enum Kind: Equatable { case fullHashes, soundPrints, other }
        var kind: Kind
        var succeeded: Bool
        /// A Full Hashes run scoped to some rows (catalog.sqlite's held rows) is never "the catalog at 100 %".
        var scoped: Bool
        var planned: Int
        /// Full Hashes: files hashed; Sound: files resolved.
        var hashed: Int
        var resolved: Int
        var seconds: Double
        /// Files the job set out to hash that it did not: result words → count.
        var unresolved: [String: Int] = [:]
    }

    /// Why a finished whole-catalog Full Hashes run that hashed something
    /// did NOT split (Codex #189 P2-1: an offline lane's files are not in
    /// `planned`, so "planned == hashed" alone said 100 %). nil = it splits,
    /// or it is not a run that could.
    nonisolated static func noSplitReason(_ e: Ending) -> String? {
        guard e.kind == .fullHashes, e.succeeded, !e.scoped, e.hashed > 0 else { return nil }
        let left = e.unresolved.values.reduce(0, +) + max(0, e.planned - e.hashed)
        guard left > 0 else { return nil }
        let parts = e.unresolved.filter { $0.value > 0 }.sorted { $0.key < $1.key }.map { "\($0.value.formatted()) \($0.key)" }
        return "no automatic split: \(left.formatted()) file(s) not hashed (\(parts.joined(separator: " · "))) — "
            + "it runs when a Full Hashes run hashes every file it set out to"
    }

    /// The one rule: a whole-catalog Full Hashes run that finished with
    /// EVERY file it set out to hash hashed — none offline, missing,
    /// unreadable, changed or skipped (Codex #189 P2-1).
    nonisolated static func reachesOneHundredPercent(_ e: Ending) -> Bool {
        e.kind == .fullHashes && e.succeeded && !e.scoped && e.planned > 0 && e.hashed == e.planned
            && e.unresolved.values.allSatisfy { $0 == 0 }
    }

    static func ending(of job: any MediaFileOperationJob) -> Ending {
        let succeeded: Bool = { if case .finished = job.state { return true }; return false }()
        let seconds = (job.finishedAt ?? Date()).timeIntervalSince(job.startedAt)
        if let full = job as? FullHashBackfillJob {
            var unresolved: [String: Int] = [:]
            for r in FullHashBackfillResult.allCases where r != .hashed && full.totals[r] > 0 { unresolved[r.words] = full.totals[r] }
            return Ending(kind: .fullHashes, succeeded: succeeded, scoped: full.scope != nil, planned: full.totals.planned,
                          hashed: full.totals[.hashed], resolved: full.totals.done, seconds: seconds, unresolved: unresolved)
        }
        if let sound = job as? AudioFingerprintBackfillJob {
            return Ending(kind: .soundPrints, succeeded: succeeded, scoped: false, planned: sound.totals.planned,
                          hashed: 0, resolved: sound.totals.done, seconds: seconds)
        }
        return Ending(kind: .other, succeeded: succeeded, scoped: false, planned: 0, hashed: 0, resolved: 0, seconds: seconds)
    }

    /// The last "no automatic split" words (tests; the log carries them).
    private(set) var lastNoSplitReason: String?
    private weak var model: VideoScanModel?
    private weak var center: MediaFileOperationsCenter?
    /// The split (injected for tests; production = the retired menu item's call).
    var split: @MainActor (MediaFileOperationsCenter, VideoScanModel) -> Void = { center, model in
        center.splitDuplicateGroupsKeepingSameFootage(model: model)
    }
    var defaults: UserDefaults = .standard

    init() {}

    /// Install once (App onAppear): the center calls back at every job's end.
    /// A second call (the main window's onAppear runs again when a new main
    /// window opens) is a no-op — one observer, so one split per run.
    func attach(center: MediaFileOperationsCenter, model: VideoScanModel) {
        guard self.center == nil else { return }
        self.center = center
        self.model = model
        center.onJobTerminal.append { [weak self] job in self?.jobEnded(job) }
    }

    func jobEnded(_ job: any MediaFileOperationJob) {
        let e = Self.ending(of: job)
        switch e.kind {
        case .fullHashes: AnalyzerRunRates.record(.fullHashes, files: e.resolved, seconds: e.seconds, defaults: defaults)
        case .soundPrints: AnalyzerRunRates.record(.soundPrints, files: e.resolved, seconds: e.seconds, defaults: defaults)
        case .other: return
        }
        if let why = Self.noSplitReason(e) {
            lastNoSplitReason = why
            model?.fullHashBackfillNote(why)
            return
        }
        guard Self.reachesOneHundredPercent(e), let model, let center else { return }
        model.fullHashBackfillNote("every planned file now has a full hash (\(e.hashed.formatted()) of \(e.planned.formatted())) — "
                                   + "\(VideoScanModel.duplicateDigestSplitTitle) runs now (automatic since 2026-11-01); its own OUTCOME follows")
        split(center, model)
    }
}
