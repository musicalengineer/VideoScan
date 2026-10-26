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
//   reportedAbsent  ids the store holds that left memory with no door's
//            purge, already named once. B2.3 (codex B2.2 finding (e)): absence
//            never purges — only `purges(requested:present:)`, fed by the
//            doors' explicit `CatalogCommitter.purge(ids:reason:)`, does.
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
// onto a copy whose group still equals its own baseline. The SETS (tags,
// people, attestations) are each copy's delta (B2.4): the value the store
// ends with is the set it read back after the commit, and it goes onto the
// copies that wrote too — A's {base,a} and B's {base,b} both become
// {a,b,base}, exactly what the next launch loads. The commit is
// synchronous, so "still equals its baseline" means exactly "the person did
// not change it since the store last agreed" — no edit can arrive mid-commit.
// A copy whose group is NOT clean keeps its baseline too (codex #141 F3): a
// scoped save (`commitNow(ids:)`) of A alone must not move dirty B's
// baseline to {base,a}, or B's own save reads `a` as B's removal.
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
    /// Ids the store holds (or holds pending) that left memory with no
    /// door's purge, already named once.
    private var reportedAbsent: Set<UUID> = []
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
        reportedAbsent = []
        partialWords = [:]
    }

    /// A Reopen: what was refused may be tried again.
    mutating func forgetWaiting() {
        waiting = [:]
    }

    /// Codex #141 F2: a Reopen found the store's row of `id` changed by
    /// another writer. The store now holds `print` / `stored`; the groups
    /// this session edited keep their OLD baseline value, so a set's next
    /// delta is still this session's own additions and removals (never a
    /// removal of what the other writer added).
    mutating func rebase(_ id: UUID, print: Fingerprint, shared stored: CatalogSharedCurated,
                         keeping groups: [CatalogSharedCurated.Group]) {
        var next = stored
        if let old = shared[id] {
            for group in groups { next.take(group, from: old) }
        }
        prints[id] = print
        shared[id] = next
        waiting[id] = nil
    }

    // MARK: - At a commit

    /// The store holds `id` (as a row, or as a held payload).
    func holds(_ id: UUID) -> Bool {
        prints[id] != nil || held[id] != nil
    }

    /// The ids due for a purge: a door asked (`requested`), the store holds
    /// the row and memory does not. Nothing else is ever purged. In a
    /// stable order. Called once per FULL commit (never a marker one).
    func purges(requested: Set<UUID>, present: Set<UUID>) -> [UUID] {
        requested.filter { holds($0) && !present.contains($0) }.sorted { $0.uuidString < $1.uuidString }
    }

    /// Ids the store holds that are not in memory and that no door asked
    /// to purge — a bug elsewhere — not named before. Each is returned
    /// ONCE (until it comes back and leaves again); the row is kept.
    mutating func unpurgedAbsences(present: Set<UUID>, requested: Set<UUID>) -> [UUID] {
        let absent = Set(prints.keys).union(held.keys).subtracting(present).subtracting(requested)
        reportedAbsent.formIntersection(absent)
        let new = absent.subtracting(reportedAbsent)
        reportedAbsent.formUnion(new)
        return new.sorted { $0.uuidString < $1.uuidString }
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
        reportedAbsent.remove(row.id)
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
        var committed = CatalogSharedCurated(item.snapshot)
        row.settledSets?.apply(to: &committed)          // the sets as the store ended them (B2.4)
        report.shared.append((row.id, digest, CatalogSharedCurated.groups(of: curated), committed))
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
        // A set reaches its writer too: the store's set is the union of the copies' deltas.
        for (group, final) in groups where final.source != copy.id || group.isSet {
            // Codex #141 F3: a copy with its OWN pending change to this group
            // keeps its value AND its baseline — its next delta is taken
            // against what it actually saw, so another copy's addition never
            // reads as this copy's removal (a scoped save of A moved B's
            // baseline to {base,a}; B's save then removed `a`).
            guard now.same(group, as: mine) else { continue }
            if !now.same(group, as: final.value) {
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
