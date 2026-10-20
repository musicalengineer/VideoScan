// CurationAuthorityCodex113Tests.swift
// Pins for codex cycle #113 (docs/reviews/codex/
// codex-review-curation-into-sqlite-2026-10-19.md). Finding 1 (folder rows
// reconciled on a changed JSON) is pinned in EventsCatalogBackingTests.
//   P1-2  a put-back entry never comes back from the frozen JSON after a
//         refused import — the next save does not ignore it again;
//   P1-3  the split HOLDS a group whose departing member has no whole-file
//         SHA-256 (it could keep no relationship), in words;
//   P1-4  with catalog.cutover beside them and no committer attached, the
//         folder store and the ignore store refuse every write with words
//         and never write their JSON files; without the latch they write
//         as before (control).
// Synthetic names only; every folder is a scratch folder.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private func scratch(_ tag: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("test_codex113_\(tag)_\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeLatch(_ folder: URL) throws {
    try Data("switched\n".utf8).write(to: folder.appendingPathComponent(CatalogAuthority.latchFileName))
}

private func ignoredEntry(_ n: Int) -> IgnoredContentEntry {
    IgnoredContentEntry(id: UUID(uuidString: String(format: "DDDDDDDD-0000-4000-8000-%012d", n)) ?? UUID(), partialMD5: "md5-\(n)",
                        sizeBytes: Int64(500 + n), filename: "test_synthetic_junk_\(n).mov", reason: "junk",
                        addedAt: Date(timeIntervalSince1970: 1_760_850_000 + Double(n)), samplePath: "/Volumes/Synthetic/junk_\(n).mov")
}

// MARK: - P1-2

/// A door whose refusal a test switches off (a hold that is released).
@MainActor
private final class Gate {
    var words: String? = "held: test"
}

@Suite("Codex #113 P1-2 — a put-back entry stays put back", .serialized)
@MainActor
struct PutBackStaysPutBackTests {

    @Test("a refused import honours the file in memory EXCEPT put-back entries; after the hold lifts, the save writes B and never re-ignores A")
    func putBackNeverReturns() async throws {
        let scene = try CutoverScene.make("c113_putback"); defer { scene.cleanup() }
        try await scene.launchOnSQLite()
        let committer = try #require(scene.model.catalogCutover.committer)
        let a = ignoredEntry(1), b = ignoredEntry(2)
        // A was ignored in catalog.sqlite, then PUT BACK by a person.
        let seeded = committer.commitSideTables("seed", via: .ignoredContent) { tx in
            try tx.appendIgnoredEntry(IgnoredContentCatalogRows.row(a))
            try tx.putBackIgnored(entryID: a.id.uuidString, at: 1)
        }
        #expect(seeded == nil)
        // The frozen file still holds A, plus B it never imported.
        let folder = try scratch("putback"); defer { try? FileManager.default.removeItem(at: folder) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(IgnoredContentFile(entries: [a, b])).write(to: folder.appendingPathComponent(IgnoredContentStore.filename))
        let gate = Gate()
        let backing = IgnoredContentCatalogBacking(repository: committer.repository, writeRefusal: { gate.words }, commit: { what, body in
            gate.words ?? committer.commitSideTables(what, via: .ignoredContent, body)
        })
        let store = IgnoredContentStore(directory: folder)
        store.attachCatalog(backing)
        _ = await store.load()
        #expect(store.entry(id: a.id) == nil, "a put-back entry is not honoured back into memory")
        #expect(store.entry(id: b.id) != nil, "the unimported entry is honoured")
        gate.words = nil                                     // the hold lifts
        #expect(await store.save())
        let rows = try await committer.repository.read { reader -> [CatalogRow.IgnoredReading] in
            var out: [CatalogRow.IgnoredReading] = []
            try reader.ignoredRows { out.append($0) }
            return out
        }
        let liveA = rows.filter { $0.entry.entryID == a.id.uuidString && !$0.putBack }
        #expect(liveA.isEmpty, "A was not ignored again")
        #expect(rows.contains { $0.entry.entryID == b.id.uuidString && !$0.putBack }, "B landed")
    }
}

// MARK: - P1-3

@Suite("Codex #113 P1-3 — no departing member loses its only relationship")
struct SplitUnknownDigestHoldTests {

    private func fact(_ name: String, digest: String?, group: UUID, _ d: DuplicateDisposition = .extraCopy) -> DuplicateGroupDigestSplit.MemberFact {
        let f = DuplicateLikeness.Facts(filename: name, partialMD5: "p-\(name)", sizeBytes: 100, timecode: "00:00:00:00",
                                        durationSeconds: 600, resolution: "720x480", digest: digest)
        return .init(id: f.id, groupID: group, filename: name, digest: digest, disposition: d, confidence: .high, bestMatch: "",
                     likeness: f, groupReasons: "timecode+duration")
    }

    @Test("K(no digest, keeper), A, B under .pairs: HELD with words — K would leave with nothing; no change, no pair")
    func unknownKeeperHolds() throws {
        let g = UUID()
        let shaA = String(repeating: "a", count: 64), shaB = String(repeating: "b", count: 64)
        let plan = DuplicateGroupDigestSplit.plan([fact("test_k.mov", digest: nil, group: g, .keep),
                                                   fact("test_a.mov", digest: shaA, group: g),
                                                   fact("test_b.mov", digest: shaB, group: g)], keeping: .pairs)
        #expect(plan.isEmpty)
        #expect(plan.heldGroups.count == 1)
        #expect(plan.pairs.isEmpty, "a held group records nothing")
        let words = try #require(plan.heldGroups.first?.heldWhy)
        #expect(words.contains("test_k.mov has no whole-file SHA-256 yet"), "\(words)")
        #expect(words.hasSuffix("Fill In Full Hashes, then split again."))
    }

    @Test("control: the same group with K's digest known splits, every leaver paired")
    func knownKeeperSplits() {
        let g = UUID()
        let plan = DuplicateGroupDigestSplit.plan([fact("test_k.mov", digest: String(repeating: "c", count: 64), group: g, .keep),
                                                   fact("test_a.mov", digest: String(repeating: "a", count: 64), group: g),
                                                   fact("test_b.mov", digest: String(repeating: "b", count: 64), group: g)],
                                                  keeping: .pairs)
        #expect(plan.heldGroups.isEmpty)
        #expect(plan.recordsLeaving == 3 && plan.pairs.count == 2)
    }

    @Test("an unknown-digest member that STAYS with the keeper's copies holds nothing")
    func unknownStayingMemberIsFine() {
        let g = UUID()
        let shaK = String(repeating: "c", count: 64)
        let plan = DuplicateGroupDigestSplit.plan([fact("test_k.mov", digest: shaK, group: g, .keep),
                                                   fact("test_u.mov", digest: nil, group: g),
                                                   fact("test_a.mov", digest: String(repeating: "a", count: 64), group: g)],
                                                  keeping: .pairs)
        #expect(plan.heldGroups.isEmpty)
        #expect(plan.recordsLeaving == 1, "only A leaves; U stays beside K (not known to differ)")
    }
}

// MARK: - P1-4

@Suite("Codex #113 P1-4 — the authority is enforced at the store boundary", .serialized)
@MainActor
struct SideStoreAuthorityTests {

    @Test("folders: catalog.cutover beside the store and no committer → a new folder is refused with words; events-decisions.json is never written")
    func folderStoreRefuses() async throws {
        let folder = try scratch("folders"); defer { try? FileManager.default.removeItem(at: folder) }
        try writeLatch(folder)
        let store = EventsDecisionStore(directory: folder)
        _ = await store.load()
        var said: [String] = []
        store.note = { said.append($0) }
        #expect(store.writeRefusal?.contains("catalog.sqlite is the catalog's authority") == true)
        #expect(store.confirm(name: "Synthetic Picnic", categories: [], members: []) == nil)
        #expect(await store.save() == false)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path), "the JSON file is never written")
        #expect(said.contains { $0.contains("made a folder was NOT saved") })
    }

    @Test("control: without the latch the same store writes its file as before")
    func folderStoreWithoutLatchWrites() async throws {
        let folder = try scratch("folders_ok"); defer { try? FileManager.default.removeItem(at: folder) }
        let store = EventsDecisionStore(directory: folder)
        _ = await store.load()
        #expect(store.confirm(name: "Synthetic Picnic", categories: [], members: []) != nil)
        #expect(await store.save())
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test("ignore list: catalog.cutover beside the store and no committer → the save is refused with words; ignored-content.json is never written")
    func ignoredStoreRefuses() async throws {
        let folder = try scratch("ignored"); defer { try? FileManager.default.removeItem(at: folder) }
        try writeLatch(folder)
        let store = IgnoredContentStore(directory: folder)
        var said: [String] = []
        store.note = { said.append($0) }
        #expect(store.add(partialMD5: "m", sizeBytes: 5, filename: "test_x.mov", reason: "junk", samplePath: "/x"))
        #expect(await store.save() == false)
        #expect(store.lastSaveFailure?.contains("ignore-list changes refused") == true)
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))
        #expect(said.contains { $0.contains("never written") })
    }

    @Test("control: without the latch the ignore list writes its file as before")
    func ignoredStoreWithoutLatchWrites() async throws {
        let folder = try scratch("ignored_ok"); defer { try? FileManager.default.removeItem(at: folder) }
        let store = IgnoredContentStore(directory: folder)
        #expect(store.add(partialMD5: "m", sizeBytes: 5, filename: "test_x.mov", reason: "junk", samplePath: "/x"))
        #expect(await store.save())
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
