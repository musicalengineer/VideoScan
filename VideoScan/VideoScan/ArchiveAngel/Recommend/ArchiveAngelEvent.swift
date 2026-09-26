// ArchiveAngelEvent.swift
// Rules v13 (2026-09-26, docs/footage_groups_gap_plan_2026-09-26.md Stage 2,
// as bounded by docs/codex-review-angel-coverage-2026-09-26.md D2 / D3):
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

import Foundation
import VideoScanCore

enum ArchiveAngelEvent {

    /// A stamp with no camera behind it (a transcoder's `encoder` tag only,
    /// RecordDateResolver.embeddedConfidenceEncoderOnly = 0.80) is the day
    /// the COPY was made, not the day the footage was shot: it never keys
    /// an event.
    static let dayKeyMinimumConfidence: Float = RecordDateResolver.embeddedConfidenceUnknownOrigin

    /// The event key ("d:1994-11-24", or "" when the file has no
    /// day-precise date worth trusting) and the year (at any precision)
    /// for one candidate. Pure over the candidate's date facts; `now` only
    /// bounds the resolver's filename-year search.
    nonisolated static func resolve(_ c: ArchiveAngelCandidate, now: Date) -> (key: String, year: Int?) {
        let r = RecordDateResolver.resolve(
            userDate: c.userDate,
            userDateConfidence: c.userDateConfidence,
            embeddedCreationDate: c.captureDate,
            originMake: c.originMake,
            originModel: c.deviceModel.isEmpty ? nil : c.deviceModel,
            originEncoder: c.originEncoder,
            inferredRecordDate: c.inferredRecordDate,
            inferredDateConfidence: c.inferredDateConfidence,
            filename: c.filename.isEmpty ? nil : c.filename,
            now: now)
        guard let year = r.year else { return ("", nil) }
        guard r.precision == .day, r.source != .embedded || r.confidence >= dayKeyMinimumConfidence else {
            return ("", year)
        }
        return ("d:" + r.isoString, year)
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
    ///   year        the members' most common resolved year (tie: the
    ///               earliest); members with no year do not vote; a
    ///               recording nobody can date goes to `unknownDate`
    ///
    /// Memory: O(recordings) for the table plus two Ints and one short
    /// string per candidate — at 100k candidates well under 20 MB.
    @discardableResult
    nonisolated static func applyCoverage(_ candidates: inout [ArchiveAngelCandidate],
                                          policy p: AngelRecommendationPolicy = .builtIn,
                                          now: Date = Date()) -> CoverageTable {
        let minimum = p.weights.minimumDurationSeconds
        let collapseBy = p.recommend.copies.batchCollapseBy
        // 1. Dates, once per candidate.
        var years: [Int?] = []
        years.reserveCapacity(candidates.count)
        for i in candidates.indices {
            let (key, year) = resolve(candidates[i], now: now)
            candidates[i].eventKey = key
            candidates[i].eventYear = year
            years.append(year)
        }
        // 2. Recordings: union-find over the copy keys (O(n·k), k ≤ 2).
        let comps = ArchiveAngelCopyChooser.components(candidates.map { ArchiveAngelCopyChooser.keys($0, collapseBy: collapseBy) })
        struct Recording {
            var votes: [Int: Int] = [:]
            var archived = false
            var actionable = false
        }
        var recordings: [String: Recording] = [:]
        var solo: [Recording] = []              // candidates with no copy key: their own recording each
        for i in candidates.indices {
            let c = candidates[i]
            let archived = c.isOnMasterArchive || c.hasArchivedDuplicate || c.archivedFootageOriginal
            let actionable = isActionable(c, minimumDuration: minimum)
            if let comp = comps[i] {
                var r = recordings[comp.key, default: Recording()]
                if let y = years[i] { r.votes[y, default: 0] += 1 }
                r.archived = r.archived || archived
                r.actionable = r.actionable || actionable
                recordings[comp.key] = r
            } else {
                var r = Recording()
                if let y = years[i] { r.votes[y] = 1 }
                r.archived = archived
                r.actionable = actionable
                solo.append(r)
            }
        }
        // 3. The table.
        var table = CoverageTable()
        func count(_ r: Recording) {
            table.recordings += 1
            let year = r.votes.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
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

    /// Material a person would archive: a video, not junk, not the Angel's
    /// buffer, not a Live Photo half, not gone, and at least the policy's
    /// minimum length. Pure, O(1).
    nonisolated static func isActionable(_ c: ArchiveAngelCandidate, minimumDuration: Double) -> Bool {
        guard isVideo(c), !c.isAngelWorkingCopy, !c.isLivePhotoMotion else { return false }
        switch c.mediaDisposition {
        case .confirmedJunk, .suspectedJunk: return false
        default: break
        }
        switch c.archiveStage {
        case .manuallyDeleted, .salvageFailed: return false
        default: break
        }
        return c.durationSeconds >= minimumDuration
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
