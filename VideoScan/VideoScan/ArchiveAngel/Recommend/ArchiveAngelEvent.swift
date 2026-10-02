// ArchiveAngelEvent.swift
// Rules v13 (2026-09-26, docs/design/footage_groups_gap_plan_2026-09-26.md Stage 2,
// as bounded by docs/reviews/codex/codex-review-angel-coverage-2026-09-26.md D2 / D3):
// the DAY a file records, and the one O(n) coverage pre-pass.
//
// Rick: "If AA recommends 5 different versions of the same Thanksgiving
// 1994, rather than misc birthdays, trips, christmas from other years not
// yet archived, then AA is not working that well." The existing filters are
// per RECORDING (duplicate group, footage group, name + length, event
// family = folder + base stem). Nothing said "these five files, in five
// folders under five names, are the same DAY". This file does:
//
//   eventKey   the resolved date at DAY precision and nothing else — the
//              ONE date rule, RecordDateResolver (a person's date, then a
//              camera's stamp, then the dossier's inferred date, then a
//              year in the name). Two files shot on the same day are one
//              event for a family archive, whatever they are called and
//              wherever they sit (Exports beside Restored). A DIVERSITY
//              heuristic (codex D2), never identity: it holds a same-day
//              row back for a later batch, never excludes it, and the
//              explanation says so. A coarser date is NOT an event — a
//              year is not a day, and "1994" must never make two unrelated
//              tapes one thing — so a month, a year, a transcoder's stamp
//              (a copy-era day, confidence 0.80) or no date at all gives
//              NO key. The year cap (coverage.maxPerYearPerBatch) spreads
//              those gently instead.
//   eventYear  the same resolution's year, whatever its precision — what
//              the year cap and the backlog bonus read.
//
// PURE. `applyCoverage` is the pre-pass the sweep and the walk run once
// per candidate set beside markDerivatives / applyFamilyAttention; the
// evidence path's few per-record projections compute the key on demand
// (`resolvedEvent(now:)`), exactly as `resolvedFamilyKey` does.

//
// Rules v14 (2026-09-29, EVENT LABELS — Rick approved a–c): a day is too
// narrow an event. Christmas shot on the 24th and the 25th were two
// events; a Christmas tape with only a year had none. With
// `coverage.eventLabels` on, VideoScanCore.EventLabeler names the
// OCCASION — a holiday from a trusted day, a People-tab birthday within
// the window, a curated name word with the year — and the key carries it
// BESIDE the day: "e:christmas:1994|d:1994-12-25". onePerEvent treats a
// row as the same event as a kept row when ANY key matches (`claim`), so
// every v13 same-day collapse still happens and labelled occasions now
// collapse across days too. Keys are strings with no "|" of their own
// (the labeler's person key strips it). With the switch off, or no label,
// the key is v13's day key byte for byte. Birthdays are INJECTED
// (ArchiveAngelEventContext) — this file never reads the People tab.

import Foundation
import VideoScanCore

enum ArchiveAngelEvent {

    /// A stamp with no camera behind it (a transcoder's `encoder` tag only,
    /// RecordDateResolver.embeddedConfidenceEncoderOnly = 0.80) is the day
    /// the COPY was made, not the day the footage was shot: it never keys
    /// an event.
    static let dayKeyMinimumConfidence: Float = RecordDateResolver.embeddedConfidenceUnknownOrigin

    /// The event key ("d:1994-11-24", "e:christmas:1994|d:1994-12-25", or
    /// "" when the file has neither a trusted day nor a labelled occasion
    /// with a year) and the year (at any precision) for one candidate.
    /// Pure over the candidate's date facts and `context`; `now` only
    /// bounds the resolver's filename-year search.
    nonisolated static func resolve(_ c: ArchiveAngelCandidate, now: Date,
                                    context: ArchiveAngelEventContext = .builtIn) -> (key: String, year: Int?) {
        let d = resolveDetailed(c, now: now, context: context)
        return (d.key, d.year)
    }

    /// One file's date CLAIM for its recording — the ordering now lives in
    /// VideoScanCore (`RecordDateClaim`) so the footage-group date sharing can
    /// use it without naming the Angel. Same type, same `<`.
    typealias DateClaim = RecordDateClaim

    /// `resolve` plus the file's date claim, from ONE resolver call.
    nonisolated static func resolveDetailed(_ c: ArchiveAngelCandidate, now: Date,
                                            context: ArchiveAngelEventContext = .builtIn)
    -> (key: String, year: Int?, claim: DateClaim?) {
        var folders = EventLabeler.FolderWordCache()
        return resolveDetailed(c, now: now, context: context, folders: &folders)
    }

    /// `resolveDetailed` with the pass's folder-word memo (the pre-pass:
    /// each folder's name is scanned once, not once per file in it).
    nonisolated static func resolveDetailed(_ c: ArchiveAngelCandidate, now: Date, context: ArchiveAngelEventContext,
                                            folders: inout EventLabeler.FolderWordCache)
    -> (key: String, year: Int?, claim: DateClaim?) {
        let d = derive(c, now: now, context: context, keysOnly: true, folders: &folders)
        return (d.key, d.year, d.claim)
    }

    /// The labels behind a candidate's key, with their reason lines — what
    /// the Archive Readiness sheet shows. Empty with labels off. A name
    /// word on a file whose year is unknown (or only a copy-era stamp's)
    /// is returned WITHOUT a year: it explains, it keys nothing. Pure.
    nonisolated static func labels(_ c: ArchiveAngelCandidate, now: Date,
                                   context: ArchiveAngelEventContext) -> [EventLabel] {
        var folders = EventLabeler.FolderWordCache()
        return derive(c, now: now, context: context, keysOnly: false, folders: &folders).labels
    }

    /// The one derivation behind `resolveDetailed` and `labels`.
    /// `keysOnly` (the pre-pass, once per catalog file): skip the labels
    /// that could never key anything — a file with no year, or only a
    /// copy-era stamp's year, and no trusted day.
    nonisolated static func derive(_ c: ArchiveAngelCandidate, now: Date, context: ArchiveAngelEventContext,
                                   keysOnly: Bool, folders: inout EventLabeler.FolderWordCache)
    -> (key: String, year: Int?, claim: DateClaim?, labels: [EventLabel]) {
        let r = RecordDateResolver.resolve(
            userDate: c.userDate,
            userDateConfidence: c.userDateConfidence,
            embeddedCreationDate: c.captureDate,
            originMake: c.originMake,
            originModel: c.deviceModel.isEmpty ? nil : c.deviceModel,
            originEncoder: c.originEncoder,
            inferredRecordDate: c.inferredRecordDate,
            inferredDateConfidence: c.inferredDateConfidence,
            inferredDateRange: c.inferredDateRange,
            filename: c.filename.isEmpty ? nil : c.filename,
            now: now)
        guard let year = r.year else {
            let explain = context.labels && !keysOnly
            return ("", nil, nil, explain ? EventLabeler.nameLabels(filename: c.filename, fullPath: c.fullPath, year: nil,
                                                                    cache: &folders) : [])
        }
        let claim = DateClaim(r)
        // A stamp with no camera behind it dates the COPY: it keys no day,
        // and (v14) lends no year to a label either.
        let trusted = r.source != .embedded || r.confidence >= dayKeyMinimumConfidence
        var day: EventDay?
        if r.precision == .day, trusted, let m = r.month, let dd = r.day { day = EventDay(year: year, month: m, day: dd) }
        let dayKey = day == nil ? "" : "d:" + r.isoString
        guard context.labels, trusted || !keysOnly else { return (dayKey, year, claim, []) }
        let labels = EventLabeler.labels(day: day, year: trusted ? year : nil, filename: c.filename, fullPath: c.fullPath,
                                         birthdays: context.birthdays, birthdayWindowDays: context.birthdayWindowDays,
                                         cache: &folders)
        return (composeKey(labels, dayKey: dayKey), year, claim, labels)
    }

    /// The label keys (each once, in label order) and then the day key,
    /// joined by `keySeparator`; the bare day key when no label has a year.
    nonisolated static func composeKey(_ labels: [EventLabel], dayKey: String) -> String {
        // The usual cases without an array (once per labelled file per pass).
        if labels.isEmpty { return dayKey }
        if labels.count == 1 {
            guard let k = labels[0].key else { return dayKey }
            return dayKey.isEmpty ? k : k + String(keySeparator) + dayKey
        }
        var keys: [String] = []
        for l in labels {
            if let k = l.key, !keys.contains(k) { keys.append(k) }
        }
        guard !keys.isEmpty else { return dayKey }
        if !dayKey.isEmpty { keys.append(dayKey) }
        return keys.joined(separator: String(keySeparator))
    }

    static let keySeparator: Character = "|"

    /// onePerEvent's bookkeeping for one row, in rank order: true = the
    /// row is the first of every event it belongs to and now CLAIMS them
    /// all; false = one of its events is already claimed by a better row
    /// (hold it back — it claims nothing). An empty key never collapses.
    /// With a single key this is exactly rules v13's
    /// `seen.insert(key).inserted`. O(keys), a handful at most.
    nonisolated static func claim(_ key: String, in seen: inout Set<String>) -> Bool {
        if key.isEmpty { return true }
        guard key.contains(keySeparator) else { return seen.insert(key).inserted }
        let parts = key.split(separator: keySeparator).map(String.init)
        if parts.contains(where: { seen.contains($0) }) { return false }
        seen.formUnion(parts)
        return true
    }

    // MARK: The coverage pre-pass

    /// Per-year backlog in UNIQUE MATERIAL: how many recordings the catalog
    /// still has to archive from that year, and how many it already has.
    /// Built ONCE per sweep by `applyCoverage`; the `backlogBonus` signal
    /// reads the pair off each candidate. (≈ a POD pair; a struct so the
    /// field names travel.)
    struct YearBacklog: Sendable, Equatable {
        var unarchived = 0
        var archived = 0
    }

    /// The whole table: per year, plus the recordings whose year nobody
    /// knows (their own bucket — codex D3 — which earns no bonus) and how
    /// many recordings (components) were counted in all.
    struct CoverageTable: Sendable, Equatable {
        var years: [Int: YearBacklog] = [:]
        var unknownDate = YearBacklog()
        var recordings = 0
    }

    /// ONE O(n) pass over a candidate set: every candidate gets its
    /// `eventKey` / `eventYear`, and the per-year backlog table is built
    /// from unique RECORDINGS and written onto each candidate
    /// (`yearUnarchived` / `yearArchived`). Runs in the sweep's candidate
    /// builder and the job's walk, beside markDerivatives — never inside
    /// `select`'s loop, never in a view body. Returns the table for the
    /// log line.
    ///
    /// A recording = one connected component of the batch's copy keys
    /// (`ArchiveAngelCopyChooser.components` over the policy's
    /// `batchCollapseBy`: the duplicate group, plus the footage group when
    /// the policy collapses by it — never name + length, so C3's false
    /// merges stay out of these numbers). Importing 1,000 copies of one
    /// 1994 tape adds nothing to 1994 (codex D3; pinned by
    /// ArchiveAngelCoverageTests).
    ///   archived    any member is, or its content or footage original is,
    ///               in the Master Archive
    ///   unarchived  not archived, and some member is actionable material:
    ///               a video, not junk (marked or suspected), not the
    ///               Angel's own working copy, not a Live Photo motion
    ///               half, not a record Relocate reports gone, and at
    ///               least the policy's minimum duration (2026-09-21:
    ///               3,159 of 9,404 catalog videos were Live Photo halves —
    ///               they would have handed the 2020s a bonus for a
    ///               backlog nobody wants archived)
    ///   year        the members' STRONGEST date claim (`DateClaim`:
    ///               a person's date > a camera's stamp > the dossier > a
    ///               name; then confidence, precision, the earliest year)
    ///               — never a vote over files (codex F2); members with
    ///               no date make no claim; a recording nobody can date
    ///               goes to `unknownDate`
    ///
    /// Memory: O(recordings) for the table plus two Ints and one short
    /// string per candidate (v14: at most a few keys joined) — at 100k
    /// candidates well under 20 MB.
    ///
    /// Rules v14: `birthdays` (the People tab's, injected by the caller)
    /// feed the event labels when `coverage.eventLabels` is on.
    @discardableResult
    nonisolated static func applyCoverage(_ candidates: inout [ArchiveAngelCandidate],
                                          policy p: AngelRecommendationPolicy = .builtIn,
                                          now: Date = Date(),
                                          birthdays: [FamilyBirthday] = []) -> CoverageTable {
        let collapseBy = p.recommend.copies.batchCollapseBy
        let context = ArchiveAngelEventContext(coverage: p.coverage, birthdays: birthdays)
        var folders = EventLabeler.FolderWordCache()   // one per pass: each folder's words scanned once
        let junkFloors = junkFloors(of: p)      // ONCE per pass, not per record (three rules, not nineteen)
        // 1. Dates, once per candidate.
        var years: [Int?] = []
        var claims: [DateClaim?] = []
        years.reserveCapacity(candidates.count)
        claims.reserveCapacity(candidates.count)
        for i in candidates.indices {
            let d = resolveDetailed(candidates[i], now: now, context: context, folders: &folders)
            candidates[i].eventKey = d.key
            candidates[i].eventYear = d.year
            years.append(d.year)
            claims.append(d.claim)
        }
        // 2. Recordings: union-find over the copy keys (O(n·k), k ≤ 2).
        let comps = ArchiveAngelCopyChooser.components(candidates.map { ArchiveAngelCopyChooser.keys($0, collapseBy: collapseBy) })
        struct Recording {
            var best: DateClaim?
            var archived = false
            var actionable = false
            mutating func fold(_ claim: DateClaim?) {
                guard let claim else { return }
                if best.map({ claim < $0 }) ?? true { best = claim }
            }
        }
        var recordings: [String: Recording] = [:]
        var solo: [Recording] = []              // candidates with no copy key: their own recording each
        for i in candidates.indices {
            let c = candidates[i]
            let archived = c.isOnMasterArchive || c.hasArchivedDuplicate || c.archivedFootageOriginal
            let actionable = isActionable(c, policy: p, junkFloors: junkFloors, now: now)
            if let comp = comps[i] {
                var r = recordings[comp.key, default: Recording()]
                r.fold(claims[i])
                r.archived = r.archived || archived
                r.actionable = r.actionable || actionable
                recordings[comp.key] = r
            } else {
                var r = Recording()
                r.fold(claims[i])
                r.archived = archived
                r.actionable = actionable
                solo.append(r)
            }
        }
        // 3. The table.
        var table = CoverageTable()
        func count(_ r: Recording) {
            table.recordings += 1
            let year = r.best?.year
            if let year {
                if r.archived { table.years[year, default: .init()].archived += 1 }
                else if r.actionable { table.years[year, default: .init()].unarchived += 1 }
            } else {
                if r.archived { table.unknownDate.archived += 1 }
                else if r.actionable { table.unknownDate.unarchived += 1 }
            }
        }
        for r in recordings.values { count(r) }
        for r in solo { count(r) }
        // 4. Written onto each candidate, by ITS year (an undated file
        // earns nothing; the unknown bucket is reported, never rewarded).
        for i in candidates.indices {
            guard let y = years[i], let b = table.years[y] else {
                candidates[i].yearUnarchived = 0
                candidates[i].yearArchived = 0
                continue
            }
            candidates[i].yearUnarchived = b.unarchived
            candidates[i].yearArchived = b.archived
        }
        return table
    }

    /// Material a person would archive: a video, not the Angel's buffer,
    /// not a Live Photo half, not gone, at least the policy's minimum
    /// length — and not junk BY THE POLICY'S OWN JUNK FLOORS (codex final
    /// F3: the marked / suspected / junk-score floors as they stand in
    /// policy.json — enabled, `starExempt`, `when` — run through the same
    /// interpreter the scorer uses, so a file the Angel rejects as junk
    /// never manufactures backlog, and a floor Rick switched off or
    /// narrowed counts the way he asked). Pure, O(floors).
    nonisolated static func isActionable(_ c: ArchiveAngelCandidate, policy p: AngelRecommendationPolicy,
                                         junkFloors: [AngelRule]? = nil, now: Date) -> Bool {
        guard isVideo(c), !c.isAngelWorkingCopy, !c.isLivePhotoMotion else { return false }
        switch c.archiveStage {
        case .manuallyDeleted, .salvageFailed: return false
        default: break
        }
        guard c.durationSeconds >= p.weights.minimumDurationSeconds else { return false }
        return !junkFloorFires(c, floors: junkFloors ?? Self.junkFloors(of: p), policy: p, now: now)
    }

    /// The junk floor kinds the backlog honours.
    static let junkFloorKinds: Set<AngelRuleKind> = [.markedJunk, .suspectedJunk, .junkScore]

    /// The policy's ENABLED junk floors, in policy order — computed once
    /// per pass so the per-record test walks three rules, not nineteen.
    nonisolated static func junkFloors(of p: AngelRecommendationPolicy) -> [AngelRule] {
        p.floors.filter { $0.enabled && $0.resolvedKind.map(junkFloorKinds.contains) ?? false }
    }

    /// Does one of `floors` (the policy's junk floors, as configured:
    /// `starExempt`, `when`) reject `c`? Read in place, like
    /// `ArchiveAngelScorer.floorHit`; the context is made only for a
    /// narrowed rule (the default rules have no `when`).
    nonisolated static func junkFloorFires(_ c: ArchiveAngelCandidate, floors: [AngelRule],
                                           policy p: AngelRecommendationPolicy, now: Date) -> Bool {
        floors.withUnsafeBufferPointer { buffer -> Bool in
            guard let rules = buffer.baseAddress else { return false }
            for i in 0..<buffer.count {
                guard let kind = rules[i].resolvedKind else { continue }
                if rules[i].starExempt && c.starRating > 0 { continue }
                if !rules[i].when.isEmpty {
                    var ctx = AngelEvalContext(now: now)
                    if !AngelCondition.all(rules[i].when, c, &ctx) { continue }
                }
                if ArchiveAngelScorer.floorFires(kind, c, policy: p, now: now) != nil { return true }
            }
            return false
        }
    }

    nonisolated static func isVideo(_ c: ArchiveAngelCandidate) -> Bool {
        c.streamTypeRaw == StreamType.videoAndAudio.rawValue || c.streamTypeRaw == StreamType.videoOnly.rawValue
    }

    /// One log line per pass: "coverage: 23 years · 4,812 recordings ·
    /// deepest backlog 2010 (156 to archive, 27 archived), 2011 (77, 7),
    /// 2023 (70, 2) · undated 412 to archive".
    nonisolated static func summaryLine(_ table: CoverageTable, top: Int = 3) -> String {
        guard !table.years.isEmpty else {
            return "coverage: no dated recordings · undated \(table.unknownDate.unarchived) to archive"
        }
        let deepest = table.years.sorted { a, b in
            a.value.unarchived != b.value.unarchived ? a.value.unarchived > b.value.unarchived : a.key < b.key
        }.prefix(top)
        let parts = deepest.map { "\($0.key) (\($0.value.unarchived) to archive, \($0.value.archived) archived)" }
        return "coverage: \(table.years.count) years · \(table.recordings.formatted()) recordings · deepest backlog "
            + parts.joined(separator: ", ") + " · undated \(table.unknownDate.unarchived) to archive"
    }
}

// MARK: - Context

/// What the event rule knows beyond the candidate: the policy's label
/// switch and birthday window, and the People tab's birthdays — INJECTED
/// by the caller (the façade reads them read-only, off the main actor;
/// a test passes its own), never read here. (≈ a small const config
/// struct passed by value.)
struct ArchiveAngelEventContext: Sendable, Equatable {
    var labels: Bool
    var birthdayWindowDays: Int
    var birthdays: [FamilyBirthday]

    init(coverage: AngelCoverageRules, birthdays: [FamilyBirthday] = []) {
        labels = coverage.eventLabels
        birthdayWindowDays = coverage.birthdayWindowDays
        self.birthdays = coverage.eventLabels ? birthdays : []
    }

    /// Rules v13: the day and nothing else.
    static let dayOnly = ArchiveAngelEventContext(coverage: .off)
    /// The built-in coverage with no birthdays — what a caller with no
    /// policy in hand gets (the on-demand `resolvedEvent`).
    static let builtIn = ArchiveAngelEventContext(coverage: .standard)
}
