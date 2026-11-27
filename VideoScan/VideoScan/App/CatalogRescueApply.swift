// CatalogRescueApply.swift
// GH #520 (rest of #356; DECISIONS 2026-11-27 (3), "least risky"). One
// sentence: at launch VideoScan says a quit left a rescue copy of changes it
// couldn't save, and Rick chooses Apply… (back up the catalog, then apply the
// rescued records the catalog hasn't changed since), Discard… (the copy goes
// to the Trash) or Later (nothing changes; asked again next launch).
//
// Apply…, each step refusing before anything changes:
//   1. REFUSE a session that cannot write (a viewer, a read-only launch, a
//      held / blocked / reopening committer) — in words; nothing happens.
//   2. READ the copy (off the main actor; ≤ 64 MB, else refused: an older
//      VideoScan's whole-catalog dump, not a delta).
//   3. CONFIRM, saying the backup comes first and that File ▸ Restore from
//      Backup… with it undoes the apply (Cancel is the default).
//   4. BACK UP through the one Back Up Catalog engine (`backUpCatalog(to:)`,
//      which commits what is in memory first). A refused backup applies
//      NOTHING.
//   5. CHECK each rescued record against what catalog.sqlite holds NOW —
//      one read snapshot, compared with the copy's `rescueBasis`
//      (CatalogRescueBasis: the stored row's digest when the copy was
//      written). Unchanged since → applied; changed, gone, newly there,
//      unreadable, edited in this session and not saved, its path now held
//      by another record, or no basis at all → NOT applied, listed with why,
//      the catalog's record left as it is.
//   6. APPLY in ONE main-actor turn after the read (no await between the
//      check and the commit; a commit that landed during the read makes the
//      check run again): each record to apply takes the live record's place
//      in memory (same id), then ONE commit of exactly those ids through the
//      commit door under the `rescue apply` writer. A row the store did not
//      take is put back as it was (its words listed).
//   7. KEEP the copy, renamed `catalog.applied-recovery-….json` (no-clobber
//      rename) so the launch notice stops; the outcome sheet offers Move
//      Rescue Copy to Trash….
// Discard… moves the copy to the Trash through THE one Trash call
// (MediaTrash.move) — undoable from the Trash. Later changes nothing.
// START / APPLIED / NOT APPLIED / OUTCOME / REFUSED lines through the quit's
// one sink (console, catalog.log, videoscan.log).
//
// Not an MFO job, like its twins Back Up Catalog and Restore from Backup:
// the backup is that engine's own work, then one indexed read and one commit
// of the delta (a handful of records). Nothing is O(catalog) but the
// in-memory path check for new records (one pass) and the swap.
//
// Memory: the copy's bytes and its records (the unsaved delta, ~2 KB a
// record, ≤ 64 MB by the cap), one digest per record; the backup's own.
//
// (For Rick: a three-way merge where the "base" is a checksum of each row at
// dump time — a row whose checksum still matches takes the rescued values; any
// other is a conflict, reported and left alone. A caseless `enum` ≈ a C++
// namespace of static functions; `@concurrent` ≈ "always on a worker thread".)

import AppKit
import Foundation
import VideoScanCore

@MainActor
enum CatalogRescueApply {

    // MARK: - The rescue copy

    struct RescueFile {
        let url: URL
        /// The generation the rescued changes were based on (the header's).
        let generation: Int
        let savedAt: Date?
        let records: [VideoRecord]
        /// nil = written before GH #520 (no basis): nothing can be applied.
        let basis: CatalogRescueBasis?
        var name: String { url.lastPathComponent }
    }

    struct Refusal: Error, Equatable {
        let words: String
    }

    /// An applied copy is renamed to this prefix (the launch notice lists
    /// only `catalog.recovery-*.json`).
    nonisolated static let appliedPrefix = "catalog.applied-recovery-"
    /// Larger is an older VideoScan's whole-catalog dump, not a delta.
    nonisolated static let maxBytes = 64 * 1024 * 1024

    /// The copies waiting for a decision beside `catalogURL`, newest first.
    nonisolated static func pendingCopies(besideCatalog catalogURL: URL) -> [URL] {
        let folder = catalogURL.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { $0.hasPrefix(CatalogQuitRecovery.filePrefix) && $0.hasSuffix(".json") }
        func modified(_ name: String) -> Date {
            let url = folder.appendingPathComponent(name)
            return (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        return names.map { ($0, modified($0)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 > $1.0 }
            .map { folder.appendingPathComponent($0.0) }
    }

    private struct Header: Decodable {
        var version: Int?
        var generation: Int?
        var savedAt: Date?
        var rescueBasis: CatalogRescueBasis?
    }

    /// Read and decode a rescue copy, off the main actor. The records come
    /// back exactly as written (pair links pending, nothing revalidated —
    /// unlike a catalog load, which would drop a link to a record not in
    /// the file). `sending`: the records are fresh objects owned by the caller.
    @concurrent
    nonisolated static func read(_ url: URL) async -> sending Result<RescueFile, Refusal> {
        let data: Data
        do {
            let size = (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= maxBytes else {
                return .failure(Refusal(words: "\(url.lastPathComponent) is \(size / 1_048_576) MB — it holds a whole catalog "
                    + "(written by an older VideoScan), not just the changes, so it can't be applied"))
            }
            data = try Data(contentsOf: url, options: .uncached)
        } catch {
            return .failure(Refusal(words: "\(url.lastPathComponent) could not be read: \(error.localizedDescription)"))
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            let header = try decoder.decode(Header.self, from: data)
            guard (header.version ?? 0) <= CatalogSnapshot.currentVersion else {
                return .failure(Refusal(words: "\(url.lastPathComponent) was written by a newer VideoScan"))
            }
            let snapshot = try decoder.decode(CatalogSnapshot.self, from: data)
            var seen = Set<UUID>()
            let records = snapshot.records.filter { seen.insert($0.id).inserted }
            return .success(RescueFile(url: url, generation: header.generation ?? 0, savedAt: header.savedAt,
                                       records: records, basis: header.rescueBasis))
        } catch {
            return .failure(Refusal(words: "\(url.lastPathComponent) is not a readable rescue copy: \(error)"))
        }
    }

    // MARK: - The check (pure)

    /// One rescued record in the outcome: what it is, and why it was not applied.
    struct Item: Equatable, Sendable {
        let id: UUID
        let name: String
        let path: String
        var why: String?

        init(_ record: VideoRecord, why: String? = nil) {
            id = record.id
            name = record.filename.isEmpty ? (record.fullPath as NSString).lastPathComponent : record.filename
            path = record.fullPath
            self.why = why
        }
    }

    /// The plain words for each reason a record is left as it is.
    enum Why {
        static let noBasisOldCopy = "this rescue copy was made by an earlier VideoScan that didn't note what the catalog held "
            + "for each file, so VideoScan can't tell whether the catalog changed it since"
        static func noBasis(_ why: String) -> String {
            "VideoScan couldn't note what the catalog held for this file when the rescue copy was made (\(why)), "
                + "so it can't tell whether the catalog changed it since"
        }
        static let changed = "the catalog changed this file's record after the rescue copy was made"
        static let gone = "the catalog no longer has this file's record"
        static let appeared = "the catalog saved a record for this file after the rescue copy was made"
        static let unreadable = "the catalog's record for this file could not be read"
        static let unsavedHere = "it has changes in this session that are not saved yet"
        static func pathTaken(_ other: String) -> String { "another record (\(other)) holds this file's place in the catalog now" }
        static func notTaken(_ words: String) -> String { "the catalog would not take it (\(words))" }
    }

    /// What the catalog and memory say NOW, for the check.
    struct Now {
        /// File id → the stored row's digest now (`absent`; nil = unreadable).
        let stored: [String: String?]
        /// The live record with this id.
        let memory: (UUID) -> VideoRecord?
        /// Of the rescued ids, those whose live record is not saved as it is.
        let unsaved: Set<UUID>
        /// The live (not removed) record at a path, for new records.
        let pathHolder: (String) -> VideoRecord?
    }

    struct Plan {
        var apply: [VideoRecord] = []
        var leave: [Item] = []
    }

    /// Record by record: apply only what the catalog holds unchanged since
    /// the copy was written; everything else is left, with why.
    static func plan(_ file: RescueFile, now: Now) -> Plan {
        var plan = Plan()
        for record in file.records {
            if let why = leaveReason(record, file: file, now: now) {
                plan.leave.append(Item(record, why: why))
            } else {
                plan.apply.append(record)
            }
        }
        return plan
    }

    private static func leaveReason(_ record: VideoRecord, file: RescueFile, now: Now) -> String? {
        guard let basis = file.basis else { return Why.noBasisOldCopy }
        if let unknown = basis.unknown { return Why.noBasis(unknown) }
        let key = record.id.uuidString
        guard let base = basis.rows[key] else { return Why.noBasis("it was not in the list") }
        guard let entry = now.stored[key], let current = entry else { return Why.unreadable }
        if base == CatalogRescueBasis.absent {
            guard current == CatalogRescueBasis.absent else { return Why.appeared }
            if let holder = now.pathHolder(record.fullPath), holder.id != record.id { return Why.pathTaken(Item(holder).name) }
            return nil
        }
        if current == CatalogRescueBasis.absent { return Why.gone }
        guard current == base else { return Why.changed }
        guard now.memory(record.id) != nil else { return Why.gone }
        if now.unsaved.contains(record.id) { return Why.unsavedHere }
        return nil
    }

    // MARK: - The door

    /// What Apply… borrows from the session. Production: `live(model:)`.
    @MainActor
    struct Context {
        let committer: CatalogCommitter
        let note: (String) -> Void
        /// Why this session may not write; nil when it may.
        let readOnlyWords: () -> String?
        let records: () -> [VideoRecord]
        /// Each record takes the place of the live record with its id (or
        /// is appended); returns what each replaced (nil = appended).
        let place: ([VideoRecord]) -> [UUID: VideoRecord?]
        /// Puts back what `place` replaced (or removes what it appended).
        let unplace: ([VideoRecord], [UUID: VideoRecord?]) -> Void
        /// Step 3. Production: the alert.
        var confirm: @MainActor (RescueFile) -> Bool = CatalogRescueApply.confirmWithAlert
        /// Where the backup goes. Production: Back Up Catalog's save panel.
        var chooseBackup: @MainActor () -> URL?
        /// THE Back Up Catalog engine.
        var backUp: @MainActor (URL) async -> CatalogBackupOutcome

        /// nil when this Mac has no catalog.sqlite committer (a viewer, a launch that refused).
        static func live(model: VideoScanModel) -> Context? {
            guard let committer = model.catalogCutover.committer else { return nil }
            return Context(committer: committer,
                           note: { [weak model] in model?.catalogQuitNote("rescue copy — " + $0) },
                           readOnlyWords: { [weak model] in
                               guard let model else { return "VideoScan is closing" }
                               return model.readOnlyFacts.readOnlyWords
                           },
                           records: { [weak model] in model?.records ?? [] },
                           place: { [weak model] incoming in
                               guard let model else { return [:] }
                               return CatalogRescueApply.place(model, in: incoming)
                           },
                           unplace: { [weak model] records, previous in
                               if let model { CatalogRescueApply.unplace(records, previous, in: model) }
                           },
                           chooseBackup: { [weak model] in model?.askWhereToSaveBackup() },
                           backUp: { [weak model] url in
                               await model?.backUpCatalog(to: url) ?? .refused("VideoScan is closing")
                           })
        }
    }

    /// Why Apply… can't run on this Mac at all (no committer), in words.
    static func unavailableWords(_ model: VideoScanModel) -> String {
        if let readOnly = model.readOnlyFacts.readOnlyWords {
            return "this session is read-only (\(readOnly)), so nothing can be applied here"
        }
        return "this Mac has no catalog.sqlite open for writing, so nothing can be applied here"
    }

    struct Report: Equatable {
        var applied: [Item]
        var notApplied: [Item]
        /// The Back Up Catalog bundle made first.
        let backup: URL
        /// Where the rescue copy is now.
        var keptAs: URL
        /// Set when the copy could not be marked applied (the notice will return).
        var keepWords: String?
    }

    enum Outcome: Equatable {
        /// The check and the commit ran (all, some or none applied).
        case applied(Report)
        /// Nothing was applied; the words say why.
        case refused(String)
        case cancelled
    }

    /// One Apply at a time (≈ a file-scope `static bool` owned by the UI thread).
    private(set) static var running = false

    static func apply(rescue url: URL, context: Context) async -> Outcome {
        guard !running else { return .refused("a rescue copy is already being applied") }
        running = true
        defer { running = false }
        context.note("START Apply \(url.lastPathComponent)")
        if let why = writeRefusal(context) { return refuse(context, url, why) }

        // 2. Read.
        let file: RescueFile
        switch await read(url) {
        case .failure(let refusal): return refuse(context, url, refusal.words)
        case .success(let read): file = read
        }
        // 3. Confirm. 4. Back up (Back Up Catalog commits memory first).
        guard context.confirm(file), let backupURL = context.chooseBackup() else {
            context.note("OUTCOME Apply \(file.name) cancelled — nothing changed")
            return .cancelled
        }
        let backup: URL
        switch await context.backUp(backupURL) {
        case .refused(let words):
            return refuse(context, url, "the catalog backup could not be made (\(words)), so nothing was applied")
        case .backedUp(let summary):
            backup = summary.path
        }
        context.note("Apply \(file.name): the catalog is backed up at \(backup.path) — File ▸ Restore from Backup… with it undoes what follows")

        // 5–6. Check against catalog.sqlite now, then apply in the same turn.
        let ids = file.records.map(\.id)
        for _ in 0..<3 {
            if let why = writeRefusal(context) {
                return refuse(context, url, "\(why); the backup at \(backup.path) was made, nothing was applied")
            }
            let repository = context.committer.repository
            let read: (generation: Int, stored: [String: String?])
            do {
                read = try await repository.read { reader in (reader.generation, try CatalogRescueBasis.digests(ids, in: reader)) }
            } catch {
                return refuse(context, url, "catalog.sqlite could not be read to check the rescued records (\(error)); "
                    + "the backup at \(backup.path) was made, nothing was applied")
            }
            // A commit landed during the read: the snapshot is stale — read again.
            guard read.generation == context.committer.knownGeneration else { continue }
            // ONE main-actor turn from here: no await between the check and the commit.
            return .applied(finish(file, stored: read.stored, backup: backup, context: context))
        }
        return refuse(context, url, "the catalog kept saving while the rescue copy was checked; the backup at \(backup.path) "
            + "was made, nothing was applied — try again")
    }

    private static func writeRefusal(_ context: Context) -> String? {
        if let readOnly = context.readOnlyWords() { return "this session is read-only (\(readOnly)), so nothing can be applied here" }
        return context.committer.saveRefusal()
    }

    private static func refuse(_ context: Context, _ url: URL, _ words: String) -> Outcome {
        context.note("REFUSED Apply \(url.lastPathComponent) — \(words). Nothing was applied; the rescue copy is kept.")
        return .refused(words)
    }

    /// Steps 5–7, synchronous on the main actor.
    private static func finish(_ file: RescueFile, stored: [String: String?], backup: URL, context: Context) -> Report {
        let committer = context.committer
        let live = context.records()
        let byID = Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let newPaths = Set(file.records.filter { byID[$0.id] == nil }.map(\.fullPath))
        var holders: [String: VideoRecord] = [:]
        for record in live where record.removal == nil && newPaths.contains(record.fullPath) { holders[record.fullPath] = record }
        let now = Now(stored: stored, memory: { byID[$0] }, unsaved: committer.notDurable(Set(file.records.map(\.id))).intersection(byID.keys),
                      pathHolder: { holders[$0] })
        var plan = plan(file, now: now)

        var applied: [Item] = []
        if !plan.apply.isEmpty {
            let ids = Set(plan.apply.map(\.id))
            let previous = context.place(plan.apply)
            let refusal = committer.commitRescued(ids: ids)
            let failed = refusal == nil ? committer.notDurable(ids) : ids
            // A new record the store holds in part stays (it left memory with no purge otherwise).
            let putBack = plan.apply.filter { failed.contains($0.id) && (replaced(previous, $0.id) != nil || !committer.storesRow($0.id)) }
            context.unplace(putBack, previous)
            for record in plan.apply {
                guard failed.contains(record.id) else { applied.append(Item(record)); continue }
                let words = refusal ?? committer.refusalWords(record.id) ?? "see catalog.log"
                plan.leave.append(Item(record, why: Why.notTaken(words)))
            }
        }
        for item in applied { context.note("APPLIED \(item.name) (\(item.id.uuidString)) at \(item.path)") }
        for item in plan.leave { context.note("NOT APPLIED \(item.name) (\(item.id.uuidString)) — \(item.why ?? "") — the catalog's record is left as it is") }

        let (keptAs, keepWords) = markApplied(file.url)
        context.note("OUTCOME Apply \(file.name) — applied \(applied.count), not applied \(plan.leave.count) of \(file.records.count); "
            + "backup \(backup.path) (File ▸ Restore from Backup… undoes it); the rescue copy is kept as "
            + (keepWords.map { "\(file.name) — it could not be marked applied (\($0)), so the next launch offers it again" } ?? keptAs.path))
        return Report(applied: applied, notApplied: plan.leave, backup: backup, keptAs: keptAs, keepWords: keepWords)
    }

    /// The model side of `place`: one array assignment for the batch (one
    /// didSet). A record's pair link resolves to the live partner (else an
    /// id-only stub, as the commit body does); records that pointed at the
    /// replaced instance point at its replacement.
    private static func place(_ model: VideoScanModel, in incoming: [VideoRecord]) -> [UUID: VideoRecord?] {
        var all = model.records
        var index: [UUID: Int] = [:]
        for (i, record) in all.enumerated() where index[record.id] == nil { index[record.id] = i }
        var previous: [UUID: VideoRecord?] = [:]
        var swapped: [ObjectIdentifier: VideoRecord] = [:]
        for record in incoming {
            if let i = index[record.id] {
                previous[record.id] = .some(all[i])
                swapped[ObjectIdentifier(all[i])] = record
                all[i] = record
            } else {
                previous[record.id] = .some(nil)
                index[record.id] = all.count
                all.append(record)
            }
        }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for record in incoming {
            guard let partner = record.pendingPairedWithID else { continue }
            record.pairedWith = byID[partner] ?? VideoRecord(id: partner)
            record.pendingPairedWithID = nil
        }
        repoint(all, swapped)
        model.records = all
        return previous
    }

    private static func unplace(_ records: [VideoRecord], _ previous: [UUID: VideoRecord?], in model: VideoScanModel) {
        guard !records.isEmpty else { return }
        var all = model.records
        var swapped: [ObjectIdentifier: VideoRecord] = [:]
        let leaving = Set(records.map { ObjectIdentifier($0) })
        for (i, record) in all.enumerated() where leaving.contains(ObjectIdentifier(record)) {
            if let old = replaced(previous, record.id) {
                swapped[ObjectIdentifier(record)] = old
                all[i] = old
            }
        }
        all.removeAll { leaving.contains(ObjectIdentifier($0)) }      // what is left of them was appended
        repoint(all, swapped)
        model.records = all
    }

    /// The live record `place` replaced for `id`; nil when it appended.
    private static func replaced(_ previous: [UUID: VideoRecord?], _ id: UUID) -> VideoRecord? { previous[id].flatMap { $0 } }

    /// Records whose pair link pointed at a swapped-out instance follow it.
    private static func repoint(_ all: [VideoRecord], _ swapped: [ObjectIdentifier: VideoRecord]) {
        guard !swapped.isEmpty else { return }
        for record in all {
            if let partner = record.pairedWith, let next = swapped[ObjectIdentifier(partner)] { record.pairedWith = next }
        }
    }

    /// Step 7: `catalog.recovery-X.json` → `catalog.applied-recovery-X.json`,
    /// no-clobber (`renamex_np(RENAME_EXCL)`). On failure the copy stays
    /// where it is and the words say why.
    nonisolated static func markApplied(_ url: URL) -> (URL, String?) {
        let name = url.lastPathComponent
        guard name.hasPrefix(CatalogQuitRecovery.filePrefix) else { return (url, nil) }
        let target = url.deletingLastPathComponent()
            .appendingPathComponent(appliedPrefix + name.dropFirst(CatalogQuitRecovery.filePrefix.count))
        guard renamex_np(url.path, target.path, UInt32(RENAME_EXCL)) == 0 else {
            return (url, String(cString: strerror(errno)))
        }
        return (target, nil)
    }

    // MARK: - Discard…

    enum DiscardOutcome: Equatable {
        /// In the Trash at this URL.
        case discarded(URL)
        case refused(String)
        case cancelled
    }

    /// Discard… : the copy (pending or applied) moves to the Trash through
    /// THE one Trash call. The only removal in this file, and only of a
    /// rescue copy beside the catalog (refused for anything else).
    static func discard(rescue url: URL, besideCatalog catalogURL: URL, note: (String) -> Void,
                        confirm: @MainActor (URL) -> Bool = CatalogRescueApply.confirmDiscardWithAlert,
                        trash: (URL) throws -> URL = { try MediaTrash.move($0) }) -> DiscardOutcome {
        let name = url.lastPathComponent
        guard url.deletingLastPathComponent().standardizedFileURL.path == catalogURL.deletingLastPathComponent().standardizedFileURL.path,
              name.hasSuffix(".json"), name.hasPrefix(CatalogQuitRecovery.filePrefix) || name.hasPrefix(appliedPrefix) else {
            note("REFUSED Discard \(url.path) — not a rescue copy beside the catalog. Nothing was moved.")
            return .refused("\(name) is not a rescue copy beside the catalog")
        }
        guard confirm(url) else {
            note("OUTCOME Discard \(name) cancelled — the rescue copy is kept")
            return .cancelled
        }
        do {
            let trashed = try trash(url)
            note("OUTCOME Discard \(name) — moved to the Trash at \(trashed.path) (put it back from the Trash to keep it); nothing was applied from it")
            return .discarded(trashed)
        } catch {
            note("REFUSED Discard \(name) — it could not be moved to the Trash: \(error.localizedDescription). It is kept where it is.")
            return .refused("\(name) could not be moved to the Trash: \(error.localizedDescription)")
        }
    }

    // MARK: - Words (pure, tested)

    static func countWords(_ n: Int) -> String { n == 1 ? "1 change" : "\(n.formatted()) changes" }

    private static func whenWords(_ date: Date?) -> String {
        date.map { " on \($0.formatted(date: .abbreviated, time: .shortened))" } ?? ""
    }

    static func launchTitle(_ count: Int?) -> String {
        guard let count else { return "VideoScan kept a rescue copy of changes it couldn't save" }
        return "VideoScan kept a rescue copy of \(countWords(count)) it couldn't save"
    }

    static func launchText(name: String, savedAt: Date?, count: Int?, readProblem: String?, olderCopies: Int) -> String {
        var text = "When VideoScan quit\(whenWords(savedAt)), it couldn't save "
            + (count == 1 ? "a change" : "some changes") + " to the catalog, so it kept them in \(name) beside the catalog. "
            + "Nothing from it is in the catalog yet.\n\n"
            + "Apply… backs up the catalog first, then applies the changes to files whose records the catalog hasn't "
            + "changed since. Any the catalog has changed are listed and left as they are.\n"
            + "Discard… moves the rescue copy to the Trash without applying it.\n"
            + "Later keeps it and asks again the next time you open VideoScan."
        if let readProblem { text += "\n\nThe rescue copy could not be read: \(readProblem)." }
        if olderCopies > 0 {
            text += "\n\n\(olderCopies) older rescue cop\(olderCopies == 1 ? "y is" : "ies are") waiting; VideoScan asks about "
                + (olderCopies == 1 ? "it" : "them") + " next."
        }
        return text
    }

    static func confirmText(_ file: RescueFile) -> String {
        "First VideoScan backs up the catalog — you choose where. If you don't like the result, choose "
            + "File ▸ Restore from Backup… and pick that backup to put the catalog back as it was.\n\n"
            + "Then it applies the \(countWords(file.records.count)) in \(file.name) to files whose records the catalog hasn't "
            + "changed since\(whenWords(file.savedAt)). Any the catalog has changed are listed afterwards and left as they are.\n\n"
            + "The rescue copy stays beside the catalog until you discard it."
    }

    /// How many items an outcome sheet names before "…and N more".
    static let listedInSheet = 12

    static func reportTitle(_ report: Report) -> String {
        if report.notApplied.isEmpty { return "Rescue Copy Applied" }
        return report.applied.isEmpty ? "Nothing Applied from the Rescue Copy" : "Rescue Copy Partly Applied"
    }

    static func reportText(_ report: Report) -> String {
        var text = "Applied: \(countWords(report.applied.count))."
        if !report.notApplied.isEmpty {
            text += "\n\nNot applied — left as they are in the catalog (\(report.notApplied.count)):"
            for item in report.notApplied.prefix(listedInSheet) { text += "\n• \(item.name): \(item.why ?? "")" }
            if report.notApplied.count > listedInSheet {
                text += "\n…and \(report.notApplied.count - listedInSheet) more (catalog.log lists every one)."
            }
        }
        text += "\n\nThe catalog was backed up first to \(report.backup.path). To undo this, choose File ▸ Restore from Backup… "
            + "and pick that backup."
        if let keepWords = report.keepWords {
            text += "\n\nThe rescue copy is still \(report.keptAs.lastPathComponent); it could not be marked applied (\(keepWords)), "
                + "so VideoScan will offer it again next time."
        } else {
            text += "\n\nThe rescue copy is kept as \(report.keptAs.lastPathComponent) beside the catalog until you discard it."
        }
        return text
    }

    static func discardText(_ url: URL) -> String {
        "The changes in \(url.lastPathComponent) will not be applied. You can put the file back from the Trash if you change your mind."
    }

    static func sentence(_ words: String) -> String {
        words.prefix(1).uppercased() + words.dropFirst() + (words.hasSuffix(".") ? "" : ".")
    }

    // MARK: - The alerts (UI)

    enum LaunchChoice { case apply, discard, later }

    static func confirmWithAlert(_ file: RescueFile) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Apply the rescue copy?"
        alert.informativeText = confirmText(file)
        let apply = alert.addButton(withTitle: "Back Up and Apply")
        apply.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    static func confirmDiscardWithAlert(_ url: URL) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Move the rescue copy to the Trash?"
        alert.informativeText = discardText(url)
        let move = alert.addButton(withTitle: "Move to Trash")
        move.keyEquivalent = ""
        let cancel = alert.addButton(withTitle: "Cancel")
        cancel.keyEquivalent = "\r"
        return alert.runModal() == .alertFirstButtonReturn
    }

    private static func askAtLaunch(title: String, text: String) -> LaunchChoice {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = text
        alert.addButton(withTitle: "Apply…")
        alert.addButton(withTitle: "Discard…")
        let later = alert.addButton(withTitle: "Later")
        later.keyEquivalent = "\u{1b}"
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .apply
        case .alertSecondButtonReturn: return .discard
        default: return .later
        }
    }

    /// At launch (after the catalog opened): the newest waiting copy is
    /// offered; after Apply or Discard the next one is. Later stops.
    static func presentLaunchNotice(model: VideoScanModel?) {
        guard let model else { return }
        let catalogURL = URL(fileURLWithPath: model.catalogStore.fileLocation)
        let copies = pendingCopies(besideCatalog: catalogURL)
        guard let newest = copies.first else { return }
        Task { @MainActor in
            let read = await read(newest)
            var file: RescueFile?
            var problem: String?
            switch read {
            case .success(let ok): file = ok
            case .failure(let refusal): problem = refusal.words
            }
            let text = launchText(name: newest.lastPathComponent, savedAt: file?.savedAt, count: file?.records.count,
                                  readProblem: problem, olderCopies: copies.count - 1)
            let note: (String) -> Void = { [weak model] in model?.catalogQuitNote("rescue copy — " + $0) }
            switch askAtLaunch(title: launchTitle(file?.records.count), text: text) {
            case .later:
                note("Later — \(newest.lastPathComponent) is kept; nothing was applied; the next launch asks again")
                return
            case .discard:
                presentDiscard(discard(rescue: newest, besideCatalog: catalogURL, note: note))
            case .apply:
                guard let context = Context.live(model: model) else {
                    let words = unavailableWords(model)
                    note("REFUSED Apply \(newest.lastPathComponent) — \(words). Nothing was applied; the rescue copy is kept.")
                    VideoScanModel.showErrorAlert(title: "Rescue Copy Not Applied", message: sentence(words))
                    return
                }
                presentApplied(await apply(rescue: newest, context: context), catalogURL: catalogURL, note: note)
            }
            if pendingCopies(besideCatalog: catalogURL).first != newest { presentLaunchNotice(model: model) }
        }
    }

    private static func presentApplied(_ outcome: Outcome, catalogURL: URL, note: @escaping (String) -> Void) {
        switch outcome {
        case .cancelled:
            return
        case .refused(let words):
            VideoScanModel.showErrorAlert(title: "Rescue Copy Not Applied", message: sentence(words))
        case .applied(let report):
            let alert = NSAlert()
            alert.alertStyle = report.notApplied.isEmpty ? .informational : .warning
            alert.messageText = reportTitle(report)
            alert.informativeText = reportText(report)
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Move Rescue Copy to Trash…")
            if alert.runModal() == .alertSecondButtonReturn {
                presentDiscard(discard(rescue: report.keptAs, besideCatalog: catalogURL, note: note))
            }
        }
    }

    private static func presentDiscard(_ outcome: DiscardOutcome) {
        guard case .refused(let words) = outcome else { return }
        VideoScanModel.showErrorAlert(title: "Rescue Copy Not Moved", message: sentence(words))
    }
}
