// JournalApplier.swift — the background helper's observations into
// catalog.sqlite, through the ONE commit door (design §3.4; background
// service step 1, item 3).
//
// One sentence: at launch and every 5 minutes, read the journal lines the
// app has not applied yet, commit them in batches of ≤ 256 (by digest)
// through the committer's side-table door, and move the file's `.applied`
// cursor only after the batch committed.
//
// Shape: a feature store behind a seam (rule 12, #337) — the model holds ONE
// (`VideoScanModel.journalApplier`, like `provenanceRoles`); nothing here
// extends the model. The batch body is Core's `JournalApplication.apply`
// (the same code the 100k scale test runs); this file owns the timer, the
// cursor, the counts Catalog Status shows and the log lines.
//
// Rules carried here (each tested in JournalApplierTests):
//   * nothing but the committer writes: `commitSideTables(via: .observations)`
//     — the same refusals as every person's change (read-only / viewer
//     session, a job's write hold, a blocked or reopening catalog). While
//     the door refuses, NOTHING is read past the cursor: the lines wait, the
//     count says so, and the refusal is said once per reason;
//   * the cursor moves only after its batch committed; a crash between the
//     commit and the cursor re-reads the batch, and the store's duplicate
//     check makes that a no-op (apply twice = once);
//   * a refused line goes to journal/refused.jsonl with its rule — one
//     durable write per batch, off the main actor, after the commit and
//     BEFORE the cursor; if it cannot be written the cursor stays (Codex #187
//     F1, F10). A crash between the two may write a refused record twice; it
//     never loses one;
//   * the cursor is bound to the file (inode + the hash of the bytes before
//     it): a replaced or truncated file is replayed from 0 (duplicates are
//     no-ops) instead of being skipped (F3); an earlier day's torn tail that
//     has been quiet for 10 minutes is sealed and refused "torn" (F9);
//   * rule 3 (archived means fixed): step 1's fields — era.yearRange,
//     era.fused, era.none, ocr.date — are OBSERVATIONS, metadata, not the file's name
//     or date (DECISIONS 2026-11-01), so they are applied on archived
//     contents too; a name or date field on an archived content is refused
//     by the store's door (`archivedNameOrDate`). Both branches are tested.
//   * OUTCOME (rule 5) when a pass found lines: files · lines read · applied ·
//     duplicates · refused, rows before · after. A pass that found nothing
//     says nothing (it runs every 5 minutes).
//   * the Catalog Status line ("Background: N journal lines waiting · M
//     refused") is computed off the main actor after each pass and pushed
//     into the freshness snapshot — never counted in a view body.
//
// Memory: one batch (≤ 256 lines ≈ 1 MB) in flight; the counts are two Ints.
// Counting waiting lines streams the unapplied bytes once (1 MB buffer).
//
// (For Rick: a log-shipping consumer — read a WAL from its last checkpoint,
// apply each block in one DB transaction, persist the checkpoint after the
// commit; idempotent because the DB rejects a replayed record.)

import Combine
import Foundation
import VideoScanCore

/// The catalog side: reads through the repository, writes through the
/// session's committer (the one door). Mirrors ProvenanceRoleCatalogBacking.
@MainActor
final class JournalApplierBacking {
    typealias Commit = (_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String?

    let repository: any CatalogRepository
    let writeRefusal: () -> String?
    private let commit: Commit

    init(repository: any CatalogRepository, writeRefusal: @escaping () -> String?, commit: @escaping Commit) {
        self.repository = repository
        self.writeRefusal = writeRefusal
        self.commit = commit
    }

    convenience init(committer: CatalogCommitter) {
        self.init(repository: committer.repository, writeRefusal: { [weak committer] in
            guard let committer else { return "the catalog is closed" }
            return committer.sideTableWriteRefusal
        }, commit: { [weak committer] what, body in
            guard let committer else { return "the catalog is closed" }
            return committer.commitSideTables(what, via: .observations, body)
        })
    }

    func write(_ what: String, _ body: (any CatalogTransaction) throws -> Void) -> String? { commit(what, body) }
}

/// The words (pure; tests read them).
enum JournalApplierWords {
    static func statusLine(_ counts: JournalApplier.Counts) -> String {
        "Background: \(counts.waiting.formatted()) journal line\(counts.waiting == 1 ? "" : "s") waiting · \(counts.refused.formatted()) refused"
    }

    static func outcome(_ p: JournalApplier.PassOutcome) -> String {
        "OUTCOME applied — \(p.files) file\(p.files == 1 ? "" : "s") · \(p.linesRead) lines read · \(p.applied) applied · "
            + "\(p.duplicates) duplicates · \(p.refused) refused; rows before \(p.rowsBefore) · after \(p.rowsAfter)"
            + (p.waitingBecause.map { " — stopped: \($0); the rest wait" } ?? "")
    }
}

@MainActor
final class JournalApplier: ObservableObject {

    struct Counts: Equatable, Sendable {
        var waiting = 0
        var refused = 0
    }

    struct PassOutcome: Equatable, Sendable {
        var files = 0
        var linesRead = 0
        var applied = 0
        var duplicates = 0
        var refused = 0
        var rowsBefore = 0
        var rowsAfter = 0
        /// The door refused (held, read-only, viewer, blocked): the lines wait.
        var waitingBecause: String?
        /// Another pass was running; this one did nothing.
        var busy = false
    }

    nonisolated static let interval: Duration = .seconds(300)
    nonisolated static let batchLines = 256

    /// nil until the first pass counted (the status line is absent until then).
    @Published private(set) var counts: Counts?
    private(set) var backing: JournalApplierBacking?
    private(set) var journal: ObservationJournal?
    /// The one log sink (console + catalog.log + videoscan.log).
    var note: (String) -> Void = { _ in }
    /// Catalog Status hears every new count.
    var onCounts: (Counts) -> Void = { _ in }
    /// After a pass that committed at least one new row (the readers'
    /// refresh hook: MachineEraStore re-reads the eras — background step 1,
    /// item 8). Not called for a pass of duplicates or refusals only.
    var onApplied: () -> Void = {}
    /// The pass at attach (launch); tests await it.
    private(set) var launchPass: Task<PassOutcome, Never>?
    private var timer: Task<Void, Never>?
    private var running = false
    private var saidRefusal: String?

    init() {}

    /// Attach to this session's committer and journal folder: one pass now,
    /// then one every `interval` until `detach`.
    func attach(_ backing: JournalApplierBacking, journal: ObservationJournal, interval: Duration = JournalApplier.interval) {
        detach()
        self.backing = backing
        self.journal = journal
        launchPass = Task { [weak self] in await self?.applyPending() ?? PassOutcome() }
        timer = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                if Task.isCancelled { return }
                _ = await self?.applyPending()
            }
        }
    }

    func detach() {
        timer?.cancel()
        timer = nil
        backing = nil
        journal = nil
        saidRefusal = nil
    }

    // MARK: The pass

    /// Read every unapplied line and commit it, file by file, batch by batch.
    @discardableResult
    func applyPending() async -> PassOutcome {
        guard !running else { return PassOutcome(busy: true) }
        guard let backing, let journal else { return PassOutcome(waitingBecause: "the catalog is not open") }
        running = true
        defer { running = false }
        var pass = PassOutcome()
        pass.rowsBefore = await rowCount(backing)
        pass.rowsAfter = pass.rowsBefore
        for file in await Self.offMain({ journal.dayFiles() }) {
            let replay = await replay(file, journal: journal, backing: backing, into: &pass)
            if replay.touched { pass.files += 1 }
            if replay.stopped { break }
        }
        if pass.linesRead > 0 { pass.rowsAfter = await rowCount(backing) }
        report(pass)
        if pass.applied > 0 { onApplied() }
        await recount()
        return pass
    }

    /// One day file from its cursor to its end: batch → commit → refusals →
    /// cursor. `stopped` = the door or the disk said no; the pass ends there
    /// and the rest waits.
    private func replay(_ file: String, journal: ObservationJournal, backing: JournalApplierBacking,
                        into pass: inout PassOutcome) async -> (touched: Bool, stopped: Bool) {
        var offset = journal.appliedOffset(file)
        var touched = false
        while true {
            if let why = backing.writeRefusal() {
                pass.waitingBecause = why
                return (touched, true)
            }
            let start = offset
            guard let read = try? await Self.offMain({ try journal.read(file: file, from: start, maxLines: Self.batchLines) }) else {
                return (touched, false)
            }
            if read.lines.isEmpty {
                // Codex #187 F9: an earlier day's abandoned torn tail is refused "torn", never left forever.
                if let tornAt = read.tornAt, await recoverAbandonedTail(journal, file: file, tornAt: tornAt, into: &pass) { touched = true }
                return (touched, false)
            }
            touched = true
            if let why = await commitBatch(read, file: file, journal: journal, backing: backing, into: &pass) {
                pass.waitingBecause = why
                return (touched, true)
            }
            offset = read.nextOffset
            if read.atEnd {
                if let tornAt = read.tornAt { _ = await recoverAbandonedTail(journal, file: file, tornAt: tornAt, into: &pass) }
                return (touched, false)
            }
        }
    }

    /// One batch through the door, then its refusals and its cursor —
    /// Codex #187 F1 / F10: the refused lines are made durable in ONE write
    /// off the main actor BEFORE the cursor moves; if that fails the cursor
    /// stays and the batch re-applies (its rows as duplicates), so no line is
    /// ever neither applied nor refused. nil = done; else why it stopped.
    private func commitBatch(_ read: ObservationJournal.ReadResult, file: String, journal: ObservationJournal,
                             backing: JournalApplierBacking, into pass: inout PassOutcome) async -> String? {
        var batch = JournalBatchOutcome()
        var failure: Error?
        if let refused = backing.write("\(read.lines.count) journal line(s) of \(file)", { tx in
            do { batch = try JournalApplication.apply(read.lines, in: tx) } catch { failure = error; throw error }
        }) {
            return failure.map { "a line the store refused (\($0))" } ?? refused    // rolled back; nothing moves
        }
        pass.linesRead += read.lines.count
        pass.applied += batch.applied
        pass.duplicates += batch.duplicates
        pass.refused += batch.refused.count
        let records = batch.refused.map {
            ObservationJournal.RefusedRecord(raw: $0.line.raw, file: file, offset: $0.line.offset, reason: $0.reason.rawValue, detail: $0.detail)
        }
        let next = read.nextOffset
        do {
            try await Self.offMain { try journal.appendRefused(records) }
        } catch {
            return "the refused lines of \(file) could not be written (\(error)) — the cursor stays; the batch re-applies as duplicates"
        }
        do {
            try await Self.offMain { try journal.markApplied(file, offset: next) }
        } catch {
            return "the cursor for \(file) could not be written (\(error)) — the batch re-applies as duplicates"
        }
        return nil
    }

    /// Seal and refuse an earlier day's abandoned torn tail; true when it did.
    private func recoverAbandonedTail(_ journal: ObservationJournal, file: String, tornAt: Int, into pass: inout PassOutcome) async -> Bool {
        do {
            guard let fragment = try await Self.offMain({ try journal.sealAbandonedTail(file, tornAt: tornAt) }) else { return false }
            let record = ObservationJournal.RefusedRecord(raw: fragment, file: file, offset: tornAt, reason: "torn",
                                                          detail: "an earlier day's last line was cut by a crash and never finished")
            try await Self.offMain { try journal.appendRefused([record]); try journal.markApplied(file, offset: journal.size(of: file)) }
            pass.refused += 1
            return true
        } catch {
            pass.waitingBecause = "the torn tail of \(file) could not be recovered (\(error))"
            return false
        }
    }

    private func report(_ pass: PassOutcome) {
        if pass.linesRead > 0 {
            note(JournalApplierWords.outcome(pass))
            saidRefusal = nil
        }
        if let why = pass.waitingBecause, pass.linesRead == 0, saidRefusal != why, (journal?.unappliedBytes() ?? 0) > 0 {
            saidRefusal = why
            note("waiting — the catalog cannot take journal lines now (\(why)); they stay in the journal")
        }
    }

    /// Recount waiting and refused lines off the main actor; publish only a change.
    func recount() async {
        guard let journal else { return }
        let next = await Self.offMain { Self.count(journal) }
        guard next != counts else { return }
        counts = next
        onCounts(next)
    }

    /// Lines past each file's cursor (complete lines only) + refused.jsonl's lines.
    nonisolated static func count(_ journal: ObservationJournal) -> Counts {
        var waiting = 0
        for file in journal.dayFiles() {
            let start = journal.appliedOffset(file)
            guard let handle = try? FileHandle(forReadingFrom: journal.directory.appendingPathComponent(file)) else { continue }
            defer { try? handle.close() }
            try? handle.seek(toOffset: UInt64(start))
            while let chunk = try? handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                waiting += chunk.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 }
            }
        }
        return Counts(waiting: waiting, refused: journal.refusedCount())
    }

    private func rowCount(_ backing: JournalApplierBacking) async -> Int {
        (try? await backing.repository.read { try $0.provenanceAssertionCount() }) ?? 0
    }

    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .utility) { try work() }.value
    }

    nonisolated private static func offMain<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .utility) { work() }.value
    }
}
