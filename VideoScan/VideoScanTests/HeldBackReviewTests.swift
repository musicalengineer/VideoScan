// HeldBackReviewTests.swift — GH #339, Codex round 1 (cycle #385, ten
// findings): each finding's regression test, seen RED on 004989d15 before
// the fix (the commit carries the red/green table).
//   #1 PROOF   the proof binds to the DESTINATION record's stored identity
//   #2 CONFIRM the confirmation covers the fields as they will be written now
//   #3 ARCHIVE no date is written while any copy of the content is archived
//   #4 BATCH   conflicting selected rows are resolved before any mutation
//   #5 DURABLE a held-back row closes only on a value durable in the store
//   #6 TRUTH   a sampled match is "likely the same file", never "proven"
//   #7 TRUTH   "already back" needs content identity, not a path
//   #8 TRUTH   a failed inspection is "couldn't check", never "gone"
//   #9 AUDIT   the closure is written as `import carry`
//   #10 UI     a failed closure's words stay visible
// Invented fixtures only; files live in sandbox folders (TestScratch).

import CryptoKit
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@MainActor
extension HeldBackScene {

    /// The open rows a person may close (no finding), in qid order.
    func openRows(_ n: Int) throws -> [HeldBackEntry] {
        let rows = store.entries.filter { !$0.isResolved && $0.findingsCount == 0 }
        try #require(rows.count >= n, "the fixture has \(rows.count) closable rows")
        return Array(rows.prefix(n))
    }

    /// One proven (whole-file) offer of `old` from `row` onto `record`, built the way the job builds it.
    func makeOffer(_ old: String, row: HeldBackEntry, onto record: VideoRecord) throws -> HeldBackOffer {
        let stamp = try #require(FileIdentityStamp.capture(path: record.fullPath))
        let live = HeldBackLive(record, dateReadOnly: model.isDateReadOnly(record))
        return HeldBackOffer.make(entry: row, old: HeldBackFixture.curated(old), live: live, evidence: .wholeFileSHA256, stamp: stamp)
    }

    /// A second live record of the SAME content as `record` (its whole-file
    /// digest copied), on its own sandbox file, committed.
    func sibling(of record: VideoRecord, archived: Bool) throws -> VideoRecord {
        let file = scene.folder.appendingPathComponent("sibling-\(record.filename)")
        try Data(repeating: 5, count: 512).write(to: file)
        let fresh = try scene.freshCopy(of: .healthy, path: file.path)
        fresh.contentFixity = record.contentFixity
        if archived { fresh.lifecycleStage = .archived }
        model.records.append(fresh)
        #expect(model.saveCatalogNow())
        return fresh
    }

    func digest(_ record: VideoRecord) throws -> String {
        try #require(CatalogCommit.digest(of: record))
    }
}

@Suite("Held back at import (#339) — Codex round 1 regressions", .serialized, .scratchCleanup)
@MainActor
struct HeldBackReviewTests {

    typealias F = HeldBackFixture

    // MARK: #1 — the proof binds to the destination

    @Test("#1 PROOF: a file whose bytes are not its catalog row's stored identity is never offered, even when it matches the held-back row")
    func proofBindsToDestination() async throws {
        let dir = try F.scratch("bind")
        let file = dir.appendingPathComponent("clip.mov")
        let a = Data(repeating: 7, count: 2_048)
        try a.write(to: file)
        // The catalog row says its content is B; the path now holds A (the held-back row's content).
        let live = F.live("clip.mov", path: file.path, size: 2_048, digest: F.sha256(Data(repeating: 8, count: 2_048)))
        let index = HeldBackLiveIndex([live])
        let rows = [F.row(1, path: "/Volumes/Online/old/clip.mov", size: 2_048, digest: F.sha256(a))]
        let plan = HeldBackJobPlan.make(entries: HeldBackClassifier.classify(rows, live: index, disk: F.disk([])), live: index)
        var delivered: [HeldBackOffer]?
        let job = FindMovedCopiesJob(plan: plan, note: { _ in }, deliver: { delivered = $0 })
        job.start()
        await job.task?.value
        #expect(delivered?.isEmpty == true, "A's values must never be carried onto the row whose identity is B")
    }

    @Test("#1 PROOF: a carry onto a record whose stored identity changed since the proof is skipped")
    func carrySkipsChangedIdentity() async throws {
        let s = try await HeldBackScene.make("identity"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let offer = try s.offer(HeldBackCarryTests.old, onto: record)
        let fixity = try #require(record.contentFixity)
        record.contentFixity = ContentFixity(digest: String(repeating: "f", count: 64), byteCount: fixity.byteCount, stamp: fixity.stamp)
        let outcome = s.carryNow([offer.id])
        #expect(outcome == .carried(carried: 0, closed: 0, skipped: 1), "\(outcome)")
        #expect(record.mediaDisposition == .unreviewed)
        #expect(record.userDate == nil)
    }

    // MARK: #2 — the confirmation covers what will be written now

    @Test("#2 CONFIRM: a destination changed after the offer was shown is re-shown before anything is written — Confirmed Junk never lands unwarned")
    func confirmationCoversCurrentFields() async throws {
        let s = try await HeldBackScene.make("junk"); defer { s.cleanup() }
        let record = try s.liveRecord()
        record.mediaDisposition = .important
        #expect(s.model.saveCatalogNow())
        let offer = try s.offer(#"{"mediaDisposition":"Confirmed Junk","userPlace":"Cape Cod"}"#, onto: record)
        #expect(offer.fields.tag == .conflict(old: "Confirmed Junk", live: "Important"), "what Rick was shown: Important kept, no Junk warning")
        let shown = s.store.previewCarry([offer.id])               // what the confirmation showed him
        #expect(shown.items.allSatisfy { !$0.setsConfirmedJunk })
        #expect(!HeldBackWords.confirmMessage(shown, changed: false).contains("Confirmed Junk will be set"))
        record.mediaDisposition = .unreviewed                      // the destination changes before he confirms
        let outcome = s.store.carry(shown)
        #expect(record.mediaDisposition != .confirmedJunk, "Confirmed Junk was never shown to him for this file")
        #expect(record.userPlace == nil, "nothing is written until the new fields are confirmed")
        guard case .reconfirm(let now) = outcome else { Issue.record("expected the new preview, got \(outcome)"); return }
        #expect(now.items.first?.setsConfirmedJunk == true)
        #expect(HeldBackWords.confirmMessage(now, changed: true).contains("Confirmed Junk will be set on 1 file: Delete Junk may then offer it for the Trash."))
        #expect(s.store.carry(now) == .carried(carried: 1, closed: 1, skipped: 0), "confirmed as shown now: carried")
        #expect(record.mediaDisposition == .confirmedJunk)
    }

    // MARK: #3 — an archived copy's date

    @Test("#3 ARCHIVE: carrying onto an unarchived copy never dates an archived copy of the same content")
    func archivedSiblingKeepsDate() async throws {
        let s = try await HeldBackScene.make("archsib"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let archived = try s.sibling(of: record, archived: true)
        #expect(record.userDate == nil && archived.userDate == nil)
        let offer = try s.offer(#"{"mediaDisposition":"Important","userDate":"1992"}"#, onto: record)
        _ = s.carryNow([offer.id])
        #expect(archived.userDate == nil, "the archived copy's date changes only with Update…")
        #expect(record.userDate == nil, "dates are stored per content: the unarchived copy's date is the archived one's")
        #expect(try s.query("SELECT count(*) FROM user_dates WHERE digest = '\(try s.digest(record))' AND value IS NOT NULL") == "0")
        #expect(record.mediaDisposition == .important, "the tag still carries")
    }

    // MARK: #4 — the batch is resolved before any mutation

    @Test("#4 BATCH: two selected rows offering different dates for one destination carry neither date and close neither row")
    func batchConflictSameDestination() async throws {
        let s = try await HeldBackScene.make("batch1"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let rows = try s.openRows(2)
        let o1 = try s.makeOffer(#"{"userDate":"1992"}"#, row: rows[0], onto: record)
        let o2 = try s.makeOffer(#"{"userDate":"1980"}"#, row: rows[1], onto: record)
        s.store.setOffers([o1, o2])
        let open = try await s.openCountInDatabase()
        _ = s.carryNow([o1.id, o2.id])
        #expect(record.userDate == nil, "neither value is Rick's choice yet")
        #expect(try await s.openCountInDatabase() == open, "neither row's value landed — neither row closes")
    }

    @Test("#4 BATCH: two rows offering different dates onto two copies of one content carry neither date")
    func batchConflictSameContent() async throws {
        let s = try await HeldBackScene.make("batch2"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let copy = try s.sibling(of: record, archived: false)
        let rows = try s.openRows(2)
        let o1 = try s.makeOffer(#"{"userDate":"1992"}"#, row: rows[0], onto: record)
        let o2 = try s.makeOffer(#"{"userDate":"1980"}"#, row: rows[1], onto: copy)
        s.store.setOffers([o1, o2])
        let open = try await s.openCountInDatabase()
        _ = s.carryNow([o1.id, o2.id])
        #expect(record.userDate == nil)
        #expect(copy.userDate == nil)
        #expect(try await s.openCountInDatabase() == open)
    }

    @Test("#4 LOGIC: the batch — different values for one content become batch conflicts; equal values, or other contents, still carry")
    func batchResolvePure() {
        let d1 = HeldBackFields(tag: .carry("Important"), date: .carry("1992"), place: nil)
        let d2 = HeldBackFields(tag: .carry("Important"), date: .carry("1980"), place: .carry("Boston"))
        let other = HeldBackFields(tag: nil, date: .carry("1970"), place: nil)
        let out = HeldBackBatch.resolve([("A", d1), ("A", d2), ("B", other)])
        #expect(out[0].tag == .carry("Important"), "the same value carries once")
        #expect(out[0].date == .batchConflict("1992", others: ["1980"]))
        #expect(out[1].date == .batchConflict("1980", others: ["1992"]))
        #expect(out[1].place == .carry("Boston"))
        #expect(out[2].date == .carry("1970"), "another content is not a conflict")
        #expect(HeldBackWords.field("date", out[0].date)?.contains("neither is carried") == true)
    }

    @Test("#4 SCALE: 2,110 selected rows over 100 contents are judged together within 1 s (Debug)")
    func batchResolveScale() {
        let items = (0..<2_110).map { i in (key: "K\(i % 100)", fields: HeldBackFields(tag: .carry("Important"), date: .carry("19\(50 + i % 7)"), place: nil)) }
        let clock = ContinuousClock()
        let start = clock.now
        let out = HeldBackBatch.resolve(items)
        #expect(clock.now - start < .seconds(1))
        #expect(out.count == 2_110)
        #expect(out.allSatisfy { $0.tag == .carry("Important") })
        #expect(out.allSatisfy { $0.date?.isBatchConflict == true }, "each content got several different dates")
    }

    // MARK: #5 — durable before closed

    @Test("#5 DURABLE: an 'already present' value typed inside the debounce window is in the store before its row closes")
    func alreadyPresentIsDurable() async throws {
        let s = try await HeldBackScene.make("durable"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let offer = try s.offer(#"{"userDate":"1992-06"}"#, onto: record)
        #expect(offer.fields.date == .carry("1992-06"))
        record.userDate = "1992-06"                               // Rick types the same date; the 2 s timer is pending
        record.userDateConfidence = UserDateConfidence.estimated.rawValue
        s.model.saveCatalogDebounced()
        _ = s.carryNow([offer.id])
        // Synchronous reads, no await: the debounce timer cannot have fired.
        let resolved = try s.query("SELECT resolution FROM quarantine WHERE qid = \(offer.qid)")
        let stored = try s.query("SELECT value FROM user_dates WHERE digest = '\(try s.digest(record))'")
        #expect(resolved == nil || stored == "1992-06", "row closed (\(resolved ?? "open")) while the store holds date \(stored ?? "none")")
        #expect(resolved == "personDecided", "the value was made durable first, so the row closes")
        #expect(stored == "1992-06")
    }

    // MARK: #6 — sampled is likely, never proven

    @Test("#6 TRUTH: a sampled match is worded 'likely the same file (sampled check)' — in the proof, the note, and the sheet")
    func sampledIsLikely() throws {
        #expect(HeldBackEvidence.sampledHash.words.contains("likely the same file (sampled check)"))
        let entry = HeldBackClassifier.classify([F.row(1, path: "/Volumes/Online/old/a.mov")], live: HeldBackLiveIndex([]), disk: F.disk([]))[0]
        let stamp = FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3, ctimeNs: 4)
        let offer = HeldBackOffer.make(entry: entry, old: F.curated(#"{"mediaDisposition":"Important"}"#),
                                       live: F.live("a.mov", path: "/b/a.mov"), evidence: .sampledHash, stamp: stamp)
        let note = HeldBackStore.resolutionNote(offer, offer.fields)
        #expect(!note.contains("proven"), Comment(rawValue: note))
        #expect(note.contains("likely the same file (sampled check)"), Comment(rawValue: note))
        let sheet = try SourceTree.appCode(named: "HeldBackSheet.swift")
        #expect(!sheet.contains("proven the same content"), "no blanket 'proven' over offers that may be sampled")
        #expect(!sheet.contains("Moved copies proven"))
    }

    @Test("#6 TRUTH: the offers' title and lead say 'proven' only when every offer in view is whole-file proven")
    func offersWords() {
        let entry = HeldBackClassifier.classify([F.row(1, path: "/Volumes/Online/old/a.mov")], live: HeldBackLiveIndex([]), disk: F.disk([]))[0]
        let stamp = FileIdentityStamp(device: 1, inode: 2, size: 100, mtimeNs: 3, ctimeNs: 4)
        let old = F.curated(#"{"mediaDisposition":"Important"}"#)
        let whole = HeldBackOffer.make(entry: entry, old: old, live: F.live("a.mov", path: "/b/a.mov"), evidence: .wholeFileSHA256, stamp: stamp)
        let sampled = HeldBackOffer.make(entry: entry, old: old, live: F.live("a.mov", path: "/c/a.mov"), evidence: .sampledHash, stamp: stamp)
        #expect(HeldBackWords.offersTitle([whole]) == "Moved copies proven by whole-file SHA-256 — 1")
        #expect(HeldBackWords.offersLead([whole]).contains("proven the same content"))
        #expect(HeldBackWords.offersTitle([sampled]) == "Moved copies, likely the same file (sampled check) — 1")
        #expect(!HeldBackWords.offersTitle([sampled]).contains("proven"))
        #expect(HeldBackWords.offersTitle([whole, sampled]) == "Moved copies — 1 proven by whole-file SHA-256 · 1 likely the same file (sampled check)")
        let mixed = HeldBackWords.offersLead([whole, sampled])
        #expect(mixed.contains("likely the same file (sampled check)") && mixed.contains("were not compared"))
        #expect(!mixed.hasPrefix("Each pair below was proven"))
    }

    @Test("#6 TRUTH: two 8 MiB files that differ only between the samples share a sampled hash — the reason it is only 'likely'")
    func sampledCollisionIsReal() throws {
        let dir = try F.scratch("collide")
        var bytes = Data(repeating: 0x5A, count: 8 * 1_048_576)
        let a = dir.appendingPathComponent("a.mov"), b = dir.appendingPathComponent("b.mov")
        try bytes.write(to: a)
        bytes[2 * 1_048_576] = 0x00
        try bytes.write(to: b)
        try #require(FileHasher.segmentedHash(path: a.path) == FileHasher.segmentedHash(path: b.path), "the precondition: one v1 hash")
        #expect(F.sha256(try Data(contentsOf: a)) != F.sha256(try Data(contentsOf: b)))
        #expect(!HeldBackEvidence.sampledHash.words.lowercased().contains("proven"))
    }

    // MARK: #7 — already back needs content identity

    @Test("#7 TRUTH: a live record at the path with OTHER content is not 'already back' — and the row can still be checked for a moved copy")
    func alreadyBackNeedsIdentity() {
        let occupant = F.live("clip.mov", path: "/Volumes/Online/clip.mov", size: 100, digest: String(repeating: "b", count: 64))
        let moved = F.live("clip.mov", path: "/Volumes/Online/new/clip.mov", size: 100, digest: String(repeating: "a", count: 64))
        let index = HeldBackLiveIndex([occupant, moved])
        let row = F.row(1, path: "/Volumes/Online/clip.mov", size: 100, digest: String(repeating: "a", count: 64))
        let entries = HeldBackClassifier.classify([row], live: index, disk: F.disk(["/Volumes/Online/clip.mov"]))
        #expect(entries[0].whereNow != .alreadyBack(recordID: occupant.id), "content B is not content A")
        let plan = HeldBackJobPlan.make(entries: entries, live: index)
        #expect(plan.tasks.map(\.entry.qid) == [1], "Find Moved Copies may still prove the moved copy")
        // The same content at the path IS already back.
        let same = HeldBackClassifier.classify([row], live: HeldBackLiveIndex([moved, F.live("clip.mov", path: "/Volumes/Online/clip.mov",
                                                                                                    digest: String(repeating: "a", count: 64))]),
                                               disk: F.disk(["/Volumes/Online/clip.mov"]))
        #expect(same[0].whereNow.group == .alreadyBack)
    }

    // MARK: #8 — a failed inspection is not absence

    @Test("#8 TRUTH: a path behind a folder that denies traversal, or a symlink, is 'couldn't check', never gone")
    func failedInspectionIsNotGone() throws {
        let dir = try F.scratch("lstat")
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 100).write(to: locked.appendingPathComponent("clip.mov"))
        let target = dir.appendingPathComponent("target.mov")
        try Data(repeating: 2, count: 100).write(to: target)
        let link = dir.appendingPathComponent("link.mov")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        var disk = HeldBackDisk.live
        disk.driveOnline = { _ in true }
        let rows = [F.row(1, path: locked.appendingPathComponent("clip.mov").path), F.row(2, path: link.path)]
        let entries = HeldBackClassifier.classify(rows, live: HeldBackLiveIndex([]), disk: disk)
        for e in entries {
            #expect(e.whereNow.group != .goneNoMatch && e.whereNow.group != .goneLikelyMoved, "row \(e.qid): \(e.whereNow)")
        }
    }

    // MARK: #9 — the closure's writer

    @Test("#9 AUDIT: the held-back rows close in a commit written as 'import carry'")
    func closureWriterIsImportCarry() async throws {
        let s = try await HeldBackScene.make("writer"); defer { s.cleanup() }
        let record = try s.liveRecord()
        let offer = try s.offer(HeldBackCarryTests.old, onto: record)
        _ = s.carryNow([offer.id])
        #expect(try s.query("SELECT resolution FROM quarantine WHERE qid = \(offer.qid)") == "personDecided")
        #expect(try s.query("SELECT writer FROM generation_history ORDER BY generation DESC LIMIT 1") == "import carry")
    }

    // MARK: #10 — a failed closure stays visible

    @Test("#10 UI: when the rows cannot be closed, the words stay visible and the pair stays offered")
    func failedClosureStaysVisible() async throws {
        let s = try await HeldBackScene.make("closefail"); defer { s.cleanup() }
        let committer = try #require(s.model.catalogCutover.committer)
        s.store.attach(HeldBackCatalogBacking(repository: committer.repository, writeRefusal: { nil },
                                              flushRecords: { committer.commitPending(ids: $0) },
                                              commitRecords: { committer.commitCarried(ids: $0) },
                                              commitSide: { _, _ in "the store refused (test)" }))
        await s.store.loadList()
        let record = try s.liveRecord()
        let offer = try s.offer(HeldBackCarryTests.old, onto: record)
        _ = s.carryNow([offer.id])
        #expect(s.store.lastCarryLines.contains { $0.contains("NOT closed") }, "\(s.store.lastCarryLines)")
        #expect(s.store.offers.contains { $0.qid == offer.qid }, "the row is open: its pair stays, to close it later")
        let sheet = try SourceTree.appCode(named: "HeldBackSheet.swift")
        let offersBody = try #require(sheet.range(of: "private var offersSection").flatMap { start in
            sheet.range(of: "private func offerRow", range: start.upperBound..<sheet.endIndex).map { String(sheet[start.lowerBound..<$0.lowerBound]) }
        })
        #expect(!offersBody.contains("lastCarryLines"), "the carry's words must not live only inside the offers group")
    }
}
