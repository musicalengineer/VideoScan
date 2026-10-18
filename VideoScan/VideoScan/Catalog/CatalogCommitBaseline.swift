// CatalogCommitBaseline.swift
// What the committer believes catalog.sqlite holds, record by record
// (cutover B2.1, re-scoped B2.2). One value type, owned by CatalogCommitter,
// so the committer file is the synchronous pipeline and this file is the
// bookkeeping:
//
//   prints   id → fingerprint of the state the store holds (the dirty test);
//   shared   id → the SHARED curated values (stars, notes, people, …) this
//            record last agreed with the store on — the per-FIELD baseline
//            codex B2 P1-1 asked for: a row writes a shared field only when
//            THIS record changed it since then;
//   waiting  rows the store deferred or refused, at the fingerprint it saw:
//            not sent again until they change;
//   held     id → the fingerprint of the payload `pending_rows` holds for
//            it (no whole-file digest yet — gap 1). B2.2 (codex B2.1 closing
//            pass): a held row is durable only AT that fingerprint, so an
//            older payload never certifies a newer edit whose update failed;
//   absent   ids the app did not hold at the last full commit. B2.2: an id
//            is purged only when it is absent at two full commits in a row
//            (or at a synchronous save) — a momentary absence never costs a
//            held row its payload (and the store keeps it anyway, tombstoned).
//
// The B2.1 marker journal (a snapshot per revision, replayed in a later
// commit) is GONE: the committer now commits a row before its marker moves
// again (CatalogCommitter.markerWillChange), so a commit only ever carries
// the next revision.
//
// `absorb` moves all of it after one commit and says what the committer
// must do next. `propagate` then copies, onto the other in-memory copies of
// one content, the value the store ENDS with for each shared group (the
// last row of the commit that wrote it — B2.2, codex finding (a)), and only
// onto a copy whose group still equals its own baseline. The commit is
// synchronous, so "still equals its baseline" means exactly "the person did
// not change it since the store last agreed" — no edit can arrive mid-commit.
//
// Memory: per record one Int (prints) + one CatalogSharedCurated (12 small
// fields, strings and arrays shared with the record until it changes) —
// ≈ 150 B a record, 14k records ≈ 2 MB, 100k ≈ 15 MB.
//
// (For Rick: the "shadow copy" a write-behind cache keeps of what is on
// disk — a checksum per row plus a copy of the few shared columns.)

import Foundation
import VideoScanCore

struct CatalogCommitBaseline {
    typealias Fingerprint = CatalogChangeDetector.Fingerprint
    /// One shared-curated write a commit made: the row, its content, the
    /// groups it wrote and the values it wrote them with.
    typealias Share = (source: UUID, digest: String, groups: [CatalogSharedCurated.Group], committed: CatalogSharedCurated)

    private(set) var prints: [UUID: Fingerprint] = [:]
    private(set) var shared: [UUID: CatalogSharedCurated] = [:]
    private(set) var waiting: [UUID: (print: Fingerprint, words: String)] = [:]
    private(set) var held: [UUID: Fingerprint] = [:]
    /// Ids the store holds (or holds pending) that the app did not hold at
    /// the last full commit.
    private var absentLastTime: Set<UUID> = []
    /// Words already said for a partly-written row (said once until they change).
    private var partialWords: [UUID: [String]] = [:]

    // MARK: - At launch

    /// The store holds exactly these records — `heldIDs` as payloads in
    /// `pending_rows` (not rows: they stay changed, durable at the
    /// fingerprint they were loaded with), the rest as rows.
    mutating func adopt(_ records: [VideoRecord], held heldIDs: Set<UUID>) {
        let snapshots = records.map(VideoRecordDTO.init)
        let fingerprints = CatalogChangeDetector.fingerprints(of: snapshots)
        prints = [:]
        shared = [:]
        held = [:]
        for (index, record) in records.enumerated() {
            if heldIDs.contains(record.id) {
                if held[record.id] == nil { held[record.id] = fingerprints[index] }
            } else if prints[record.id] == nil {
                prints[record.id] = fingerprints[index]
                shared[record.id] = CatalogSharedCurated(snapshots[index])
            }
        }
        waiting = [:]
        absentLastTime = []
        partialWords = [:]
    }

    /// A Reopen: what was refused may be tried again.
    mutating func forgetWaiting() {
        waiting = [:]
    }

    // MARK: - At a commit

    /// The ids due for a purge: absent now AND at the previous full commit,
    /// or — `final` (a synchronous save: quit, Delete All) — absent now.
    /// In a stable order. Called once per FULL commit (never a marker one).
    mutating func purges(present: Set<UUID>, final: Bool) -> [UUID] {
        let absent = Set(prints.keys).union(held.keys).subtracting(present)
        let due = final ? absent : absent.intersection(absentLastTime)
        absentLastTime = absent
        return due.sorted { $0.uuidString < $1.uuidString }
    }

    /// Of the changed records the store took nothing from (they wait at
    /// this fingerprint), how many are NOT durable: every one except a
    /// held row whose stored payload has exactly this fingerprint.
    func notDurable(_ waitingRows: [(id: UUID, print: Fingerprint)]) -> Int {
        waitingRows.filter { held[$0.id] != $0.print }.count
    }

    // MARK: - After a commit

    /// What the committer must do after one commit.
    struct Report {
        var allStored = true
        var lines: [String] = []
        var needDigest: Set<UUID> = []
        var heldCount = 0
        var purged = 0
        var shared: [Share] = []
        /// (id, revision) a record whose purged row came back must carry.
        var revisions: [(id: UUID, revision: Int)] = []
    }

    /// Move the baseline for one commit's rows. `purgeRows` first (as the
    /// body ran them), then one row per `sent` item, in order.
    mutating func absorb(purgeRows: ArraySlice<CatalogCommit.RowResult>, itemRows: ArraySlice<CatalogCommit.RowResult>,
                         sent: [CatalogCommit.Item]) -> Report {
        var report = Report()
        for row in purgeRows { absorbPurge(row, into: &report) }
        for (row, item) in zip(itemRows, sent) { absorbItem(row, item: item, into: &report) }
        if report.heldCount > 0 {
            report.lines.append("Catalog store: HELD \(report.heldCount) new row(s) with no whole-file hash yet in catalog.sqlite's "
                                + "pending rows (kept across a relaunch); Fill In Full Hashes is queued for them")
        }
        return report
    }

    private mutating func absorbPurge(_ row: CatalogCommit.RowResult, into report: inout Report) {
        guard case .removed(let landing) = row.landing else {
            report.allStored = false
            if case .refused(let words) = row.landing { report.lines.append("Catalog store: NOT REMOVED \(row.id.uuidString) — \(words)") }
            return
        }
        if landing != .absent, landing != .alreadyPurged { report.purged += 1 }
        prints[row.id] = nil
        shared[row.id] = nil
        waiting[row.id] = nil
        held[row.id] = nil
        absentLastTime.remove(row.id)
        partialWords[row.id] = nil
    }

    private mutating func absorbItem(_ row: CatalogCommit.RowResult, item: CatalogCommit.Item, into report: inout Report) {
        if let revision = row.adoptedRevision { report.revisions.append((row.id, revision)) }
        switch row.landing {
        case .written(let curated, let notes):
            settle(row, item: item)
            for note in notes { report.lines.append("Catalog store: NOTE \(row.id.uuidString) — \(note)") }
            share(row, item: item, curated: curated, into: &report)
        case .unchanged:
            settle(row, item: item)
        case .partial(let curated, let words):
            // Curated values landed; the record stays CHANGED (codex P2-7).
            shared[row.id] = CatalogSharedCurated(item.snapshot)
            report.allStored = false
            notePartial(row, words: words, into: &report)
            share(row, item: item, curated: curated, into: &report)
        case .deferred(let words):
            noteWaiting(row, words: words, into: &report)
            absorbHold(row, into: &report)
        case .refused(let words):
            report.allStored = false
            noteWaiting(row, words: words, into: &report)
        case .removed:
            break
        }
    }

    /// A deferred row: durable only when its payload is now stored at THIS
    /// fingerprint. A failed put leaves `held` naming the OLD payload, so
    /// the row is not durable (B2.2, codex B2.1 closing pass (c)).
    private mutating func absorbHold(_ row: CatalogCommit.RowResult, into report: inout Report) {
        guard row.heldPending else {
            report.allStored = false
            return
        }
        if held[row.id] == nil { report.heldCount += 1 }
        held[row.id] = row.fingerprint
        report.needDigest.insert(row.id)
    }

    /// The store now holds exactly this snapshot of the record.
    private mutating func settle(_ row: CatalogCommit.RowResult, item: CatalogCommit.Item) {
        prints[row.id] = row.fingerprint
        shared[row.id] = CatalogSharedCurated(item.snapshot)
        waiting[row.id] = nil
        held[row.id] = nil
        partialWords[row.id] = nil
    }

    private mutating func notePartial(_ row: CatalogCommit.RowResult, words: [String], into report: inout Report) {
        guard partialWords[row.id] != words else { return }
        partialWords[row.id] = words
        report.lines.append("Catalog store: PARTLY SAVED \(row.id.uuidString) — " + words.joined(separator: "; ")
                            + " (it stays changed and is sent again)")
    }

    private mutating func noteWaiting(_ row: CatalogCommit.RowResult, words: String, into report: inout Report) {
        let said = waiting[row.id]?.words == words
        waiting[row.id] = (row.fingerprint, words)
        if !said, !row.heldPending { report.lines.append("Catalog store: NOT SAVED \(row.id.uuidString) — \(words)") }
    }

    private func share(_ row: CatalogCommit.RowResult, item: CatalogCommit.Item, curated: [CatalogDDL.KnowledgeField],
                       into report: inout Report) {
        guard let digest = row.digest, !curated.isEmpty else { return }
        report.shared.append((row.id, digest, CatalogSharedCurated.groups(of: curated), CatalogSharedCurated(item.snapshot)))
    }

    // MARK: - Copies of one content (codex P1-2, B2.2 finding (a))

    /// One shared group's value as the store ends the commit with it.
    private struct Final {
        let source: UUID
        let value: CatalogSharedCurated
    }

    /// After the commit, in the same main-actor turn: for each content the
    /// commit wrote a shared group of, the value the store ENDS with (the
    /// last row in commit order that wrote the group) goes onto every other
    /// in-memory copy — but only a copy whose group still equals its own
    /// baseline (the person did not change it since the store last agreed).
    /// The copy's per-field baseline takes that value (the store shows it);
    /// its fingerprint moves only when it was clean before. Returns whether
    /// any record changed.
    mutating func propagate(_ shares: [Share], records: [VideoRecord]) -> Bool {
        var finals: [String: [CatalogSharedCurated.Group: Final]] = [:]
        for entry in shares {
            for group in entry.groups { finals[entry.digest, default: [:]][group] = Final(source: entry.source, value: entry.committed) }
        }
        guard !finals.isEmpty else { return false }
        var touched = false
        for record in records {
            guard let digest = CatalogCommit.digest(of: record), let groups = finals[digest] else { continue }
            if share(groups, onto: record) { touched = true }
        }
        return touched
    }

    private mutating func share(_ groups: [CatalogSharedCurated.Group: Final], onto copy: VideoRecord) -> Bool {
        guard var mine = shared[copy.id] else { return false }
        let now = CatalogSharedCurated(copy)
        let wasClean = prints[copy.id] == CatalogChangeDetector.fingerprint(VideoRecordDTO(copy))
        var changed = false
        for (group, final) in groups where final.source != copy.id {
            if now.same(group, as: mine), !now.same(group, as: final.value) {
                final.value.apply(group, to: copy)
                changed = true
            }
            mine.take(group, from: final.value)
        }
        shared[copy.id] = mine
        if changed, wasClean { prints[copy.id] = CatalogChangeDetector.fingerprint(VideoRecordDTO(copy)) }
        return changed
    }
}
