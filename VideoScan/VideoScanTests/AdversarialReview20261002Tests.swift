// AdversarialReview20261002Tests.swift
// Pins for the nightly adversarial review of 2026-10-02
// (docs/reviews/adversarial/2026-10-02.md, range 05c2b9a5..83afc55f).
//   F1 7336e5bf — a lore draft typed and then reverted overwrote lore another
//                 pane saved; both-changed is now a surfaced conflict.
//   F2 0932b527 — a re-run dropped a vanished Unreviewed finding together
//                 with Rick's lore (and would drop a told/filed one too).
//   F3 a11d9465 — a rollback whose write 2 never ran reported a false
//                 mixed state ("it still lists this record").
// Synthetic names and URLs only (public repo).

import CoreGraphics
import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private let advGedcom = """
0 HEAD
1 SOUR AdvTests
0 @I1@ INDI
1 NAME Testa /Synthetica/
1 SEX F
1 BIRT
2 DATE 1870
1 DEAT
2 DATE 1930
1 _FSFTID ZZZZ-903
0 TRLR
"""

private struct AdvDown: Error {}

private struct AdvDownSource: ResearchSource {
    let kind: ResearchSourceKind = .chroniclingAmerica
    func search(plan: ResearchQueryPlan) async throws -> [ResearchFinding] { throw AdvDown() }
}

private let advAt = Date(timeIntervalSince1970: 1_790_000_000)

private func advSubject() throws -> ResearchSubject {
    let record = try #require(GedcomFamilyGraph(gedcomText: advGedcom).people["@I1@"])
    return ResearchSubject(person: record)
}

private func advHit(_ n: Int = 1) -> ResearchFinding {
    ResearchFinding(source: .chroniclingAmerica, title: "Synthetic hit \(n)", date: nil,
                    excerpt: "Synthetic excerpt", url: "https://example.invalid/hit/\(n)",
                    retrievedAt: advAt)
}

// MARK: - F1

@Suite("Adversarial 2026-10-02 — F1 reverted lore draft", .serialized)
struct AdvRevertedLoreDraftTests {
    private let fm = FileManager.default

    @MainActor
    private func pane(_ subject: ResearchSubject, _ store: ResearchStore) -> ResearchPersonModel {
        ResearchPersonModel(subject: subject, store: store,
                            fetcher: FixtureResearchFetcher(fixtures: [], retrievedAt: advAt),
                            speakerName: "Tester", record: { _ in throw AdvDown() },
                            log: { _ in }, now: { advAt })
    }

    /// Two panes on one person; both show "Synthetic first note".
    private func seeded(confirmed: Bool = false) throws -> (URL, ResearchStore, ResearchSubject, ResearchFinding) {
        let base = fm.temporaryDirectory.appendingPathComponent("AdvLoreRevert-\(UUID().uuidString)", isDirectory: true)
        let store = ResearchStore(peopleRoot: base.appendingPathComponent("People", isDirectory: true))
        let subject = try advSubject()
        let hit = advHit()
        var prior = ResearchDossier(subject: subject)
        prior.merge(fresh: [hit], at: advAt)
        prior.setLore("Synthetic first note", for: hit.id)
        if confirmed { prior.setVerdict(.confirmed, for: hit.id) }
        try store.saveDossier(prior)
        return (base, store, subject, hit)
    }

    private func loreOnDisk(_ store: ResearchStore, _ subject: ResearchSubject, _ id: String) throws -> String? {
        try store.loadDossier(key: subject.key)?.findings.first { $0.id == id }?.lore
    }

    /// The review's drafted red test.
    @MainActor
    @Test func aTypedThenRevertedDraftDoesNotOverwriteAnotherPanesLore() async throws {
        let (base, store, subject, hit) = try seeded()
        defer { try? fm.removeItem(at: base) }
        let a = pane(subject, store), b = pane(subject, store)
        a.load()
        b.load()
        b.editLore("Synthetic correction", for: hit.id)   // pane B: a real edit, saved
        b.commitLore(for: hit.id)
        a.editLore("Synthetic first notes", for: hit.id)  // pane A: one key typed…
        a.editLore("Synthetic first note", for: hit.id)   // …and deleted again
        a.commitLore(for: hit.id)

        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic correction",
                "pane A changed nothing; pane B's newer lore must survive")
        #expect(a.loreDrafts[hit.id] == "Synthetic correction", "a reverted draft follows the disk again")
        #expect(a.loreConflicts.isEmpty)
    }

    /// Same, through Tell Hallie (which commits every edited draft): the
    /// stale words are neither written nor told.
    @MainActor
    @Test func tellHallieDoesNotCommitARevertedDraft() async throws {
        let (base, store, subject, hit) = try seeded()
        defer { try? fm.removeItem(at: base) }
        let a = pane(subject, store), b = pane(subject, store)
        a.load()
        b.load()
        b.editLore("Synthetic correction", for: hit.id)
        b.commitLore(for: hit.id)
        a.editLore("Synthetic first notex", for: hit.id)
        a.editLore("Synthetic first note", for: hit.id)
        _ = a.tellHallie()   // nothing confirmed; the record closure is never reached
        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic correction")
    }

    /// Both changed: A really edited, B saved meanwhile. A's commit is
    /// refused, B's lore stays on disk, and the conflict is surfaced.
    @MainActor
    @Test func bothChangedIsAConflictNotASilentOverwrite() async throws {
        let (base, store, subject, hit) = try seeded()
        defer { try? fm.removeItem(at: base) }
        let a = pane(subject, store), b = pane(subject, store)
        a.load()
        b.load()
        b.editLore("Synthetic correction", for: hit.id)
        b.commitLore(for: hit.id)
        a.editLore("Synthetic other note", for: hit.id)
        a.commitLore(for: hit.id)

        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic correction", "theirs is not overwritten")
        #expect(a.loreConflicts[hit.id] == "Synthetic correction", "the conflict names their words")
        #expect(a.loreDrafts[hit.id] == "Synthetic other note", "my words are kept on screen")
        #expect(a.errorMessage?.contains("changed elsewhere") == true)
    }

    /// Keep mine: the user's words are written over the value they were
    /// shown in the conflict.
    @MainActor
    @Test func keepMineWritesTheDraft() async throws {
        let (base, store, subject, hit) = try seeded()
        defer { try? fm.removeItem(at: base) }
        let a = pane(subject, store), b = pane(subject, store)
        a.load()
        b.load()
        b.editLore("Synthetic correction", for: hit.id)
        b.commitLore(for: hit.id)
        a.editLore("Synthetic other note", for: hit.id)
        a.commitLore(for: hit.id)
        a.keepMyLore(for: hit.id)
        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic other note")
        #expect(a.loreConflicts.isEmpty)
        #expect(a.errorMessage == nil)
    }

    /// Keep mine is itself guarded: a third save after the conflict was
    /// shown is a new conflict, not overwritten.
    @MainActor
    @Test func keepMineAfterAThirdSaveIsANewConflict() async throws {
        let (base, store, subject, hit) = try seeded()
        defer { try? fm.removeItem(at: base) }
        let a = pane(subject, store), b = pane(subject, store)
        a.load()
        b.load()
        b.editLore("Synthetic correction", for: hit.id)
        b.commitLore(for: hit.id)
        a.editLore("Synthetic other note", for: hit.id)
        a.commitLore(for: hit.id)
        b.editLore("Synthetic third note", for: hit.id)
        b.commitLore(for: hit.id)
        a.keepMyLore(for: hit.id)
        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic third note")
        #expect(a.loreConflicts[hit.id] == "Synthetic third note")
    }

    /// Keep theirs: the draft is dropped and follows the disk.
    @MainActor
    @Test func keepTheirsDropsTheDraft() async throws {
        let (base, store, subject, hit) = try seeded()
        defer { try? fm.removeItem(at: base) }
        let a = pane(subject, store), b = pane(subject, store)
        a.load()
        b.load()
        b.editLore("Synthetic correction", for: hit.id)
        b.commitLore(for: hit.id)
        a.editLore("Synthetic other note", for: hit.id)
        a.commitLore(for: hit.id)
        a.keepTheirLore(for: hit.id)
        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic correction")
        #expect(a.loreDrafts[hit.id] == "Synthetic correction")
        #expect(a.loreConflicts.isEmpty)
        a.commitLore(for: hit.id)   // no longer edited: writes nothing
        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic correction")
    }

    /// A conflicted, confirmed finding is held back from Tell Hallie until
    /// Rick picks a side: neither the stale nor the unchosen words are told.
    @MainActor
    @Test func aConflictedFindingIsNotToldUntilResolved() async throws {
        let (base, store, subject, hit) = try seeded(confirmed: true)
        defer { try? fm.removeItem(at: base) }
        let a = pane(subject, store), b = pane(subject, store)
        a.load()
        b.load()
        b.editLore("Synthetic correction", for: hit.id)
        b.commitLore(for: hit.id)
        a.editLore("Synthetic other note", for: hit.id)
        #expect(a.tellHallie() == 0, "the conflicted finding is held back")
        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic correction")
        #expect(a.loreConflicts[hit.id] == "Synthetic correction")
    }

    /// Negative: an ordinary edit with nobody else writing still saves,
    /// and two equal edits (A and B typed the same words) are no conflict.
    @MainActor
    @Test func anOrdinaryEditAndAnAgreeingEditStillSave() async throws {
        let (base, store, subject, hit) = try seeded()
        defer { try? fm.removeItem(at: base) }
        let a = pane(subject, store), b = pane(subject, store)
        a.load()
        b.load()
        a.editLore("Synthetic agreed note", for: hit.id)
        a.commitLore(for: hit.id)
        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic agreed note")
        b.editLore("Synthetic agreed note", for: hit.id)
        b.commitLore(for: hit.id)
        #expect(b.loreConflicts.isEmpty, "the disk already holds my words")
        #expect(try loreOnDisk(store, subject, hit.id) == "Synthetic agreed note")
    }
}

// MARK: - F2

@Suite("Adversarial 2026-10-02 — F2 re-run keeps Rick's work", .serialized)
struct AdvRerunKeepsLoreTests {
    private let fm = FileManager.default

    /// The review's drafted red test.
    @MainActor
    @Test func aRerunWhoseSourceFailsKeepsLoreOnAnUnreviewedFinding() async throws {
        let base = fm.temporaryDirectory.appendingPathComponent("AdvRerunLore-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let store = ResearchStore(peopleRoot: base.appendingPathComponent("People", isDirectory: true))
        let subject = try advSubject()
        let hit = advHit()
        var prior = ResearchDossier(subject: subject)
        prior.merge(fresh: [hit], at: advAt)
        try store.saveDossier(prior)

        let model = ResearchPersonModel(subject: subject, store: store,
                                        fetcher: FixtureResearchFetcher(fixtures: [], retrievedAt: advAt),
                                        speakerName: "Tester", record: { _ in throw AdvDown() },
                                        sources: { _ in [AdvDownSource()] }, log: { _ in }, now: { advAt })
        model.load()
        let note = "Synthetic note: check the mill ledger"
        model.editLore(note, for: hit.id)
        model.commitLore(for: hit.id)                  // saved; verdict left Unreviewed
        try #require(try store.loadDossier(key: subject.key)?.findings.first { $0.id == hit.id }?.lore == note)

        model.run()                                    // this time the source fails
        for _ in 0..<150 where model.isRunning { try await Task.sleep(nanoseconds: 10_000_000) }
        try #require(!model.isRunning)

        let after = try #require(try store.loadDossier(key: subject.key))
        #expect(after.findings.first { $0.id == hit.id }?.lore == note,
                "Rick's lore is his work; a failed or changed source must not delete it")
    }

    /// Lore, a told Hallie item or a filed document each make an
    /// Unreviewed search finding survive a re-run that no longer returns
    /// it; a bare Unreviewed one is still dropped.
    @Test func mergeKeepsEveryKindOfRicksWorkAndDropsOnlyBareUnreviewed() throws {
        let subject = try advSubject()
        let (bare, lore, told, filed) = (advHit(1), advHit(2), advHit(3), advHit(4))
        var dossier = ResearchDossier(subject: subject)
        dossier.merge(fresh: [bare, lore, told, filed], at: advAt)
        dossier.setLore("Synthetic lore", for: lore.id)
        dossier.markTold(id: told.id, itemID: "synthetic-item")
        let at = try #require(dossier.findings.firstIndex { $0.id == filed.id })
        dossier.findings[at].documentPath = "People/Synthetic/Documents/BC-synthetic.pdf"
        #expect(dossier.findings.allSatisfy { $0.verdict == .unreviewed })

        dossier.merge(fresh: [], at: advAt)
        #expect(Set(dossier.findings.map(\.id)) == [lore.id, told.id, filed.id])
        #expect(dossier.findings.first { $0.id == lore.id }?.lore == "Synthetic lore")
    }

    /// The 500-finding trim never cuts Rick's work either.
    @Test func trimNeverCutsAnUnreviewedFindingWithLore() throws {
        let subject = try advSubject()
        let mine = advHit(0)
        var dossier = ResearchDossier(subject: subject)
        dossier.merge(fresh: [mine], at: advAt)
        dossier.setLore("Synthetic lore", for: mine.id)
        let flood = (1...ResearchDossier.maxFindings + 20).map { advHit($0) }
        dossier.merge(fresh: flood, at: advAt)
        #expect(dossier.findings.count == ResearchDossier.maxFindings)
        #expect(dossier.findings.first { $0.id == mine.id }?.lore == "Synthetic lore")
    }
}

// MARK: - F3

@Suite("Adversarial 2026-10-02 — F3 write 2 never ran", .serialized)
struct AdvWriteTwoNeverRanTests {
    private func pdf() throws -> Data {
        let data = NSMutableData()
        var box = CGRect(x: 0, y: 0, width: 211, height: 300)
        let consumer = try #require(CGDataConsumer(data: data as CFMutableData))
        let context = try #require(CGContext(consumer: consumer, mediaBox: &box, nil))
        context.beginPDFPage(nil)
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1))
        context.fill(CGRect(x: 10, y: 10, width: 90, height: 20))
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// The review's drafted red test.
    @Test func aDossierWriteThatNeverRanIsReportedAsRolledBack() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory.appendingPathComponent("AdvNoneRollback-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: base) }
        let downloads = base.appendingPathComponent("downloads", isDirectory: true)
        try fm.createDirectory(at: downloads, withIntermediateDirectories: true)
        let file = downloads.appendingPathComponent("synthetic.pdf")
        try pdf().write(to: file)

        var store = FamilyAssetStore(root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
                                     cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true),
                                     access: .readWrite)
        let subject = try advSubject()
        let record = try #require(GedcomFamilyGraph(gedcomText: advGedcom).people["@I1@"])
        let research = ResearchStore(peopleRoot: store.peopleDirectory)
        let dossierURL = try research.dossierURL(key: subject.key)
        let damaged = Data("{ damaged".utf8)
        let now = advAt
        // prepare() saw no dossier; during the import (after prepare, before
        // write 2) the dossier becomes unreadable.
        store.importClock = {
            try? FileManager.default.createDirectory(at: dossierURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? damaged.write(to: dossierURL)
            return now
        }
        let filer = RecordFinderFiler(assetStore: store, assetPerson: FamilyAssetPerson(record),
                                      researchStore: research, subject: subject, speakerName: "Tester",
                                      record: nil, log: { _ in }, now: { now })
        let outcome = await filer.file(FoundRecordSubmission(
            file: file, siteID: nil, siteTitle: "Synthetic archive", recordType: .birth, year: "1870",
            district: "", recordID: "", pageURL: "https://example.invalid/record/1",
            transcription: "", confirmedRead: false))

        #expect(try Data(contentsOf: dossierURL) == damaged, "write 2 never touched the dossier")
        #expect(!outcome.message.contains("still lists this record"), "false claim: \(outcome.message)")
        guard case .rolledBack = outcome else { Issue.record("expected rolledBack, got \(outcome)"); return }
    }
}
