// ProvenanceFieldsTests.swift — the three provenance fields Rick types
// (digitization date, tape, source) as rows of provenance_assertions, and the
// new-media decision (DECISIONS 2026-11-27, "Provenance fields live in
// provenance_assertions; no schema change").
//
// Dimensions (CLAUDE.md rule 8):
//   LOGIC      what stands per field (newest Rick row; rejected = unknown;
//              machine rows never read); normalisation (one line, bounded, a
//              real calendar date); the drafts a save appends (first
//              confirmed, change corrected, clear rejected, unchanged nothing);
//              new vs re-seen vs moved vs copy-of-known; the words.
//   TRUTH      a missing field reads "unknown", never a guess; a machine
//              'carrier' (the estimate's "VHS") is not shown as Rick's tape.
//   DOOR       the rows land through the one assertions door; digitizedOn is
//              REFUSED on archived content (rule 3), tape and source land;
//              read back after closing and reopening the store (relaunch).
//   ISOLATION  a poisoned row (unknown field, non-owner, bad state) changes
//              nothing; a digest that is not a SHA-256 drafts nothing.
//   SCALE      100k records → the new-media decision inside a budget.
//
// Suites (filter by SUITE): ProvenanceFieldsLogicTests · ProvenanceFieldsDoorTests ·
// NewContentFinderTests · NewContentFinderScaleTests
// Synthetic names only.

import Foundation
import GRDB
import Testing
@testable import VideoScanCore

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

private func row(_ seq: Int64, _ field: String, _ value: String, state: String = "confirmed", by: String = "rick") -> CatalogRow.ProvenanceAssertionReading {
    CatalogRow.ProvenanceAssertionReading(seq: seq, subjectKind: "content", subjectID: hex(1), field: field, value: value, state: state,
                                          by: by, at: 1_800_000_000 + seq, confidence: state == "inferred" ? 0.9 : nil, evidenceJSON: "{}")
}

private func record(_ path: String, digest: String? = nil, contentHash: String = "", partialMD5: String = "", size: Int64 = 4_096) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.sizeBytes = size
    r.contentHash = contentHash
    r.partialMD5 = partialMD5
    if let digest {
        r.contentFixity = ContentFixity(digest: digest, byteCount: size,
                                        stamp: FileIdentityStamp(device: 1, inode: 1, size: size, mtimeNs: 1),
                                        computedAt: Date(timeIntervalSince1970: 1_800_000_000))
    }
    return r
}

// MARK: - LOGIC + TRUTH + ISOLATION (pure)

@Suite("Provenance fields — logic")
struct ProvenanceFieldsLogicTests {

    @Test("a content with no rows reads unknown on all three lines — never a guess")
    func missingIsUnknown() {
        let values = ProvenanceFields.current(fromRowsOfOneSubject: [])
        #expect(values.isEmpty)
        #expect(ProvenanceFields.lines(values) == ["Digitized: unknown", "Tape: unknown", "Source: unknown"])
        #expect(ProvenanceFields.searchWords(values).isEmpty)
    }

    @Test("per field, Rick's NEWEST row stands; a rejected newest row is unknown and the older value never comes back")
    func newestRickRowStands() {
        let rows = [row(1, "digitizedOn", "2023"), row(2, "digitizedOn", "2024-07", state: "corrected"),
                    row(3, "carrier", "Christmas 1994"), row(4, "carrier", "Christmas 1994", state: "rejected"),
                    row(5, "source", "Grandma's attic")]
        let values = ProvenanceFields.current(fromRowsOfOneSubject: rows.shuffled())
        #expect(values == ProvenanceFieldValues(digitizedOn: "2024-07", carrier: nil, source: "Grandma's attic"))
        #expect(ProvenanceFields.lines(values) == ["Digitized: 2024-07", "Tape: unknown", "Source: Grandma's attic"])
    }

    @Test("TRUTH: a machine 'carrier' (the estimate's VHS) is never shown as Rick's tape; Rick's own confirmed VHS is")
    func machineRowsAreNeverRead() {
        let machine = [row(1, "carrier", "VHS", state: "inferred", by: "machine:vhsCapture2026@r1")]
        #expect(ProvenanceFields.current(fromRowsOfOneSubject: machine).carrier == nil)
        let confirmed = machine + [row(2, "carrier", "VHS")]
        #expect(ProvenanceFields.current(fromRowsOfOneSubject: confirmed).carrier == "VHS")
    }

    @Test("ISOLATION: rows of other fields, other writers and unknown states change nothing")
    func poisonedRowsAreIgnored() {
        let rows = [row(1, "role", "master"), row(2, "era.fused", "1990-1995", state: "inferred", by: "machine:era@r1"),
                    row(3, "digitizedOn", "1999", state: "inferred", by: "machine:x@r1"), row(4, "source", "x", state: "bogus"),
                    row(5, "Digitizedon", "2001"), row(6, "carrier", "Tape 3", by: "someone")]
        #expect(ProvenanceFields.current(fromRowsOfOneSubject: rows).isEmpty)
    }

    @Test("normalise: one line, trimmed, bounded; empty is unknown; control characters refused")
    func normalise() {
        #expect(ProvenanceFields.normalize(.carrier, "   ") == .empty)
        #expect(ProvenanceFields.normalize(.carrier, "  Hi8\n tape  3 ") == .value("Hi8 tape 3"))
        #expect(ProvenanceFields.normalize(.source, String(repeating: "a", count: 301)) == .invalid("Source is longer than 300 characters"))
        #expect(ProvenanceFields.normalize(.source, "a\u{0007}b") == .invalid("Source has a character that cannot be stored"))
    }

    @Test("a digitization date is a year, a year-month or a real day — nothing looser")
    func digitizationDate() {
        #expect(ProvenanceFields.digitizationDate("2024") == "2024")
        #expect(ProvenanceFields.digitizationDate("2024-7") == "2024-07")
        #expect(ProvenanceFields.digitizationDate("2024/07/04") == "2024-07-04")
        #expect(ProvenanceFields.digitizationDate("2024-02-29") == "2024-02-29")
        for bad in ["2023-02-29", "2024-13", "2024-00", "24", "1899", "2101", "July 2024", "2024-07-04T10:00", "２０２４", "2024--07", "-2024"] {
            #expect(ProvenanceFields.digitizationDate(bad) == nil, "\(bad)")
        }
        guard case .invalid(let words) = ProvenanceFields.normalize(.digitizedOn, "last summer") else { Issue.record("expected a refusal"); return }
        #expect(words == "Digitized must be a year, a year and month, or a day: 2024, 2024-07 or 2024-07-04")
    }

    @Test("the form's three texts: every field optional; one refusal refuses the whole save")
    func formValues() {
        #expect(ProvenanceFields.values(digitizedOn: "", carrier: "", source: "") == .success(ProvenanceFieldValues()))
        #expect(ProvenanceFields.values(digitizedOn: "2024", carrier: "", source: "") == .success(ProvenanceFieldValues(digitizedOn: "2024")))
        guard case .failure = ProvenanceFields.values(digitizedOn: "soon", carrier: "Tape 1", source: "") else { Issue.record("expected a refusal"); return }
    }

    @Test("drafts: a first value is confirmed, a change corrected, a clear rejected (of what it clears), unchanged writes nothing")
    func drafts() throws {
        let before = ProvenanceFieldValues(digitizedOn: "2023", carrier: "Tape 1", source: nil)
        let after = ProvenanceFieldValues(digitizedOn: "2024", carrier: nil, source: "Uncle's box")
        let drafts = ProvenanceFields.drafts(digest: "sha256:" + hex(1).uppercased(), before: before, after: after,
                                             at: 1_800_000_000, enteredIn: "review list")
        #expect(drafts.map(\.field) == ["digitizedOn", "carrier", "source"])
        #expect(drafts.map(\.state) == ["corrected", "rejected", "confirmed"])
        #expect(drafts.map(\.value) == ["2024", "Tape 1", "Uncle's box"])
        #expect(drafts.allSatisfy { $0.subjectKind == "content" && $0.subjectID == hex(1) && $0.by == "rick" && $0.confidence == nil })
        let evidence = try #require(drafts.first?.evidenceJSON)
        #expect(evidence == #"{"entered":"review list","how":"typed by the owner"}"#)
        #expect(ProvenanceFields.drafts(digest: hex(1), before: before, after: before, at: 1, enteredIn: "x").isEmpty)
        #expect(ProvenanceFields.drafts(digest: "not-a-digest", before: ProvenanceFieldValues(), after: after, at: 1, enteredIn: "x").isEmpty)
    }

    @Test("search words: human words, never the field key, the state or the digest")
    func searchWords() {
        let words = ProvenanceFields.searchWords(ProvenanceFieldValues(digitizedOn: "2024-07", carrier: "Hi8 Cape 1994", source: "Costco transfer"))
        #expect(words == ["digitized 2024-07", "tape Hi8 Cape 1994", "source Costco transfer"])
        #expect(!words.joined().contains("digitizedOn"))
    }
}

// MARK: - DOOR (catalog.sqlite)

@Suite("Provenance fields — through the assertions door")
struct ProvenanceFieldsDoorTests {

    private func open(_ fixture: StoreFixture) async throws -> GRDBCatalogRepository {
        let repository = GRDBCatalogRepository(host: "test-host", durability: .volatileForTests)
        try #require(await repository.open(at: fixture.url) == .readWrite)
        return repository
    }

    private func seed(_ fixture: StoreFixture, archived: [Int] = []) throws {
        try DatabaseQueue(path: fixture.url.path).inDatabase { db in
            for n in 1...2 {
                try db.execute(sql: "INSERT INTO content (digest, byte_count, first_seen_at, first_seen_how) VALUES (?, 100, 1700000000, 'rescan')",
                               arguments: [hex(n)])
            }
            try db.execute(sql: "INSERT OR IGNORE INTO volumes (volume_uuid) VALUES ('')")
            for n in archived {
                try db.execute(sql: """
                    INSERT INTO files (id, content_digest, volume_uuid, full_path, path_fold, filename, ext, directory, size_bytes,
                                       digest_computed_at, digest_source, stream_type, lifecycle, archive_stage, volume_case_sensitive)
                    VALUES ('\(String(format: "00000000-0000-0000-0000-%012X", n))', ?, '', '/a/\(n).mov', '/a/\(n).mov', '\(n).mov', 'mov', '/a', 100, 1, 'archiveFixity', 'Video+Audio', 'Archived', 'Archived', 0)
                    """, arguments: [hex(n)])
            }
        }
    }

    private func append(_ repository: GRDBCatalogRepository, _ drafts: [CatalogRow.ProvenanceAssertionDraft]) async -> [CatalogRow.ProvenanceAssertionLanding] {
        let box = FieldLandings()
        _ = await repository.write(as: .ui) { tx in for d in drafts { box.append(try tx.appendProvenanceAssertion(d)) } }
        return box.items
    }

    @Test("round trip: the three fields land, read back as what stands, and survive closing and reopening the store")
    func roundTripAndRelaunch() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seed(fixture)
        var repository = try await open(fixture)
        let typed = ProvenanceFieldValues(digitizedOn: "2024-07-04", carrier: "Hi8 tape 3", source: "Grandma's attic")
        let landed = await append(repository, ProvenanceFields.drafts(digest: hex(1), before: ProvenanceFieldValues(), after: typed,
                                                                      at: 1_800_000_000, enteredIn: "review list"))
        #expect(landed.count == 3 && landed.allSatisfy { if case .recorded = $0 { return true } else { return false } }, "\(landed)")
        let corrected = ProvenanceFieldValues(digitizedOn: "2024-07-04", carrier: nil, source: "Uncle's attic")
        _ = await append(repository, ProvenanceFields.drafts(digest: hex(1), before: typed, after: corrected,
                                                             at: 1_800_000_100, enteredIn: "inspector"))
        await repository.close()

        repository = try await open(fixture)      // the relaunch: a fresh connection to the same file
        let all = try await repository.read { try ProvenanceFields.all(in: $0) }
        #expect(all == [hex(1): corrected], "the cleared tape is unknown; content 2 has nothing")
        let rows = try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: hex(1)) }
        #expect(rows.map(\.state) == ["confirmed", "confirmed", "confirmed", "rejected", "corrected"])
        #expect(ProvenanceFields.current(fromRowsOfOneSubject: rows) == corrected)
        await repository.close()
    }

    @Test("ARCHIVED (rule 3): the door refuses a digitization date on archived content; tape and source land")
    func archivedContentKeepsItsDate() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seed(fixture, archived: [1])
        let repository = try await open(fixture)
        let drafts = ProvenanceFields.drafts(digest: hex(1), before: ProvenanceFieldValues(),
                                             after: ProvenanceFieldValues(digitizedOn: "2024", carrier: "Tape 1", source: "attic"),
                                             at: 1_800_000_000, enteredIn: "review list")
        let landed = await append(repository, drafts)
        #expect(landed.first == .archivedNameOrDate)
        #expect(landed.dropFirst().allSatisfy { if case .recorded = $0 { return true } else { return false } }, "\(landed)")
        #expect(ProvenanceAssertionFieldPolicy.isNameOrDate(ProvenanceField.digitizedOn.stored))
        #expect(!ProvenanceAssertionFieldPolicy.isNameOrDate(ProvenanceField.carrier.stored))
        #expect(!ProvenanceAssertionFieldPolicy.isNameOrDate(ProvenanceField.source.stored))
        let notArchived = await append(repository, ProvenanceFields.drafts(digest: hex(2), before: ProvenanceFieldValues(),
                                                                           after: ProvenanceFieldValues(digitizedOn: "2024"),
                                                                           at: 1_800_000_000, enteredIn: "review list"))
        #expect(notArchived.count == 1 && notArchived != [.archivedNameOrDate])
        await repository.close()
    }

    @Test("a content catalog.sqlite does not hold is refused by the door (contentMissing), nothing written")
    func contentMissing() async throws {
        let fixture = try await StoreFixture.make(.grdb, generation: 0)
        defer { fixture.remove() }
        try seed(fixture)
        let repository = try await open(fixture)
        let landed = await append(repository, ProvenanceFields.drafts(digest: hex(9), before: ProvenanceFieldValues(),
                                                                      after: ProvenanceFieldValues(source: "x"), at: 1, enteredIn: "x"))
        #expect(landed == [.contentMissing])
        #expect(try await repository.read { try $0.provenanceAssertionCount() } == 0)
        await repository.close()
    }
}

private final class FieldLandings: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [CatalogRow.ProvenanceAssertionLanding] = []
    var items: [CatalogRow.ProvenanceAssertionLanding] { lock.withLock { storage } }
    func append(_ l: CatalogRow.ProvenanceAssertionLanding) { lock.withLock { storage.append(l) } }
}

// MARK: - New media (pure)

@Suite("New media — which files are content the catalog has never seen")
struct NewContentFinderTests {

    @Test("LOGIC: a stranger with a digest no other record holds is new; one that copies known content is settled quietly")
    func newVersusCopyOfKnown() {
        let known = record("/V/old/a.mov", digest: hex(1))
        let copy = record("/V/new/a-copy.mov", digest: hex(1))
        let fresh = record("/V/new/b.mov", digest: hex(2))
        let out = NewContentFinder.evaluate(records: [known, copy, fresh], pending: [copy.id, fresh.id], offered: [])
        #expect(out.newContents == [NewContentFinder.NewContent(digest: hex(2), recordIDs: [fresh.id])])
        #expect(out.settled == [copy.id, fresh.id])
        #expect(out.copiesOfKnown == 1)
        #expect(out.waiting.isEmpty)
    }

    @Test("LOGIC: a pending file with no full hash yet waits; nothing is offered for it")
    func waitsForTheHash() {
        let unhashed = record("/V/new/c.mov", contentHash: "v1:abc")
        let out = NewContentFinder.evaluate(records: [unhashed], pending: [unhashed.id], offered: [])
        #expect(out.newContents.isEmpty)
        #expect(out.waiting == [unhashed.id])
        #expect(out.settled.isEmpty)
    }

    @Test("LOGIC: two new copies of one new content are ONE new media file; an already-offered digest is never offered again")
    func onePerContentAndNoRepeat() {
        let a = record("/V/new/x.mov", digest: hex(3)), b = record("/W/new/x.mov", digest: hex(3))
        let out = NewContentFinder.evaluate(records: [a, b], pending: [a.id, b.id], offered: [])
        #expect(out.newContents == [NewContentFinder.NewContent(digest: hex(3), recordIDs: [a.id, b.id])])
        let again = record("/X/x.mov", digest: hex(3))
        let second = NewContentFinder.evaluate(records: [again], pending: [again.id], offered: [hex(3)])
        #expect(second.newContents.isEmpty, "remembered per content, not path")
        #expect(second.settled == [again.id])
    }

    @Test("REFUSE RATHER THAN GUESS: an older copy never fully hashed (same sampled identity) means the stranger is NOT new")
    func anUnhashedOlderCopyIsKnownContent() {
        let older = record("/V/old/d.mov", contentHash: "v1:same")
        let stranger = record("/V/new/d.mov", digest: hex(4), contentHash: "v1:same")
        let out = NewContentFinder.evaluate(records: [older, stranger], pending: [stranger.id], offered: [])
        #expect(out.newContents.isEmpty)
        let olderByMD5 = record("/V/old/e.mov", partialMD5: "md5e", size: 10)
        let strangerByMD5 = record("/V/new/e.mov", digest: hex(5), partialMD5: "md5e", size: 10)
        #expect(NewContentFinder.evaluate(records: [olderByMD5, strangerByMD5], pending: [strangerByMD5.id], offered: []).newContents.isEmpty)
        let otherSize = record("/V/new/f.mov", digest: hex(6), partialMD5: "md5e", size: 11)
        #expect(NewContentFinder.evaluate(records: [olderByMD5, otherSize], pending: [otherSize.id], offered: []).newContents.count == 1,
                "partialMD5 alone, with another size, is not the same content")
    }

    @Test("ISOLATION: a pending id gone from the catalog, or a removed row, is dropped; an empty sampled value matches nothing")
    func droppedAndEmpty() {
        let removed = record("/V/new/g.mov", digest: hex(7))
        removed.removal = .inTrash(movedAt: Date(timeIntervalSince1970: 1_800_000_000), trashPath: nil, reason: .catalogTrash)
        let blankOld = record("/V/old/h.mov"), blankNew = record("/V/new/h.mov", digest: hex(8))
        let ghost = UUID()
        let out = NewContentFinder.evaluate(records: [removed, blankOld, blankNew], pending: [removed.id, blankNew.id, ghost], offered: [])
        #expect(out.dropped == 2)
        #expect(out.settled.isSuperset(of: [removed.id, ghost]))
        #expect(out.newContents.map(\.digest) == [hex(8)], "blank sampled identities are never 'the same content'")
    }

    @Test("LOGIC: re-seen and moved files are not strangers; a new path is")
    func strangers() {
        let reseen = record("/V/a.mov"), moved = record("/V/renamed.mov"), new = record("/V/new.mov")
        let ids = NewContentFinder.strangers(targetRecords: [reseen, moved, new], existingPaths: ["/V/a.mov", "/V/b.mov"],
                                             adoptedNewPaths: ["/V/renamed.mov"])
        #expect(ids == [new.id])
    }
}

@Suite("New media — scale")
struct NewContentFinderScaleTests {

    @Test("SCALE: 100k records, 10k pending → decided inside the budget", .tags(.quietMachine))
    func hundredThousand() {
        var records: [VideoRecord] = []
        records.reserveCapacity(100_000)
        var pending = Set<UUID>()
        for i in 0..<100_000 {
            let r = record("/V/\(i).mov", digest: hex(i % 95_000 + 1), contentHash: "v1:\(i)")
            if i >= 90_000 { pending.insert(r.id) }
            records.append(r)
        }
        let clock = ContinuousClock()
        var out = NewContentFinder.Outcome()
        let elapsed = clock.measure { out = NewContentFinder.evaluate(records: records, pending: pending, offered: []) }
        #expect(out.settled.count == 10_000)
        #expect(out.newContents.count == 5_000, "90k…95k are new; 95k…100k repeat digests 1…5k held by known records")
        #expect(elapsed < .seconds(3), "\(elapsed)")
    }
}
