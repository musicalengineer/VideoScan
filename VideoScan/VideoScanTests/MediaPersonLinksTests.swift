// MediaPersonLinksTests.swift
// Linking records to people in the tree (2026-08-31).

import Testing
import Foundation
@testable import VideoScan

@Suite("Family: media ↔ person links")
struct MediaPersonLinksTests {

    private func tempDir() throws -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("links-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private let bill = "GVQV-NW3"
    private let martha = "L1XY-ABC"

    @Test("a link is findable from both ends")
    func linkIsBidirectional() {
        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "abc123", path: "/v/Montana_Tape_1.mkv")

        #expect(links.media(forPerson: bill).count == 1)
        #expect(links.people(forHash: "abc123", path: "/v/Montana_Tape_1.mkv").count == 1)
        #expect(links.isLinked(personID: bill, hash: "abc123", path: "/v/Montana_Tape_1.mkv"))
        #expect(!links.isLinked(personID: martha, hash: "abc123", path: "/v/Montana_Tape_1.mkv"))
    }

    @Test("a link survives the file moving — hash is the identity, not path")
    func linkSurvivesAMove() {
        // Rick is moving 285 GB from MoviesExpansion to FamilyArchive as
        // this is written. A path-keyed link would break on the move.
        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "abc123",
                   path: "/Volumes/MediaExpansion/MoviesExpansion/Montana_Tape_1.mkv")

        let afterMove = links.people(
            forHash: "abc123",
            path: "/Volumes/FamilyArchive/Breen_Family_Archive/30_Video/Montana_Tape_1.mkv")
        #expect(afterMove.count == 1, "the link broke when the file moved")
        #expect(afterMove.first?.personID == bill)
    }

    @Test("linking the same person to the same content twice is one edge")
    func linkingIsIdempotent() {
        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "abc123", path: "/a.mkv")
        links.link(personID: bill, hash: "abc123", path: "/b.mkv")
        #expect(links.count == 1, "the same edge was recorded twice")
        // …and the newer sighting refreshes where the file is.
        #expect(links.media(forPerson: bill).first?.mediaPath == "/b.mkv")
    }

    @Test("a detector must NOT downgrade something a person stated")
    func statedBeatsDetected() {
        // The archive's whole approach is evidence with provenance. If
        // Rick says Uncle Bill is on this tape, a later detection pass
        // turning that into a guess would quietly lose a fact.
        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "abc123", path: "/a.mkv", source: .stated)
        links.link(personID: bill, hash: "abc123", path: "/moved.mkv", source: .detected)

        let link = try? #require(links.media(forPerson: bill).first)
        #expect(link?.source == .stated, "a human claim was downgraded to a guess")
        // The detector still knows where the file is, and that is useful.
        #expect(link?.mediaPath == "/moved.mkv")
    }

    @Test("a person CAN upgrade a detected link by confirming it")
    func statedUpgradesDetected() {
        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "abc123", path: "/a.mkv", source: .detected)
        links.link(personID: bill, hash: "abc123", path: "/a.mkv", source: .stated)
        #expect(links.media(forPerson: bill).first?.source == .stated)
    }

    @Test("unlinking removes exactly one edge")
    func unlinkIsPrecise() {
        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "abc123", path: "/a.mkv")
        links.link(personID: martha, hash: "abc123", path: "/a.mkv")
        // Called outside #expect: the macro captures its argument
        // immutably, so a mutating method cannot be invoked inside it.
        let removed = links.unlink(personID: bill, hash: "abc123", path: "/a.mkv")
        #expect(removed)
        #expect(links.count == 1)
        #expect(links.media(forPerson: martha).count == 1)
        let removedAgain = links.unlink(personID: bill, hash: "abc123", path: "/a.mkv")
        #expect(removedAgain == false)
    }

    @Test("records with no hash fall back to matching on path")
    func unhashedRecordsStillLink() {
        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "", path: "/no/hash/yet.mkv")
        #expect(links.people(forHash: "", path: "/no/hash/yet.mkv").count == 1)
        #expect(links.people(forHash: "", path: "/somewhere/else.mkv").isEmpty)
    }

    @Test("a path change updates the hint without touching the edge")
    func pathChangeIsRecorded() {
        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "abc123", path: "/old.mkv")
        links.notePathChange(from: "/old.mkv", to: "/new.mkv")
        #expect(links.media(forPerson: bill).first?.mediaPath == "/new.mkv")
        #expect(links.count == 1)
    }

    // MARK: - Persistence

    @Test("links round-trip through disk")
    func roundTrips() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var links = MediaPersonLinks()
        links.link(personID: bill, hash: "abc123", path: "/a.mkv",
                   source: .stated, note: "second from the left")
        links.link(personID: martha, hash: "def456", path: "/cert.pdf", source: .detected)
        try links.save(to: dir)

        let loaded = MediaPersonLinks.load(from: dir)
        #expect(loaded.count == 2)
        #expect(loaded.media(forPerson: bill).first?.note == "second from the left")
        #expect(loaded.media(forPerson: martha).first?.source == .detected)
    }

    @Test("a missing or corrupt sidecar means 'no links', never a crash")
    func missingFileIsEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(MediaPersonLinks.load(from: dir).isEmpty)

        try Data("{ not json".utf8).write(to: MediaPersonLinks.fileURL(in: dir))
        #expect(MediaPersonLinks.load(from: dir).isEmpty)
    }

    @Test("the file is a sorted array, so two machines produce a diffable file")
    func fileIsStableOnDisk() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        var a = MediaPersonLinks()
        a.link(personID: martha, hash: "zzz", path: "/z.mkv")
        a.link(personID: bill, hash: "aaa", path: "/a.mkv")
        try a.save(to: dir)
        let first = try Data(contentsOf: MediaPersonLinks.fileURL(in: dir))

        // Same edges, inserted in the opposite order.
        let billNoted = try #require(a.media(forPerson: bill).first).notedAt
        let marthaNoted = try #require(a.media(forPerson: martha).first).notedAt
        var b = MediaPersonLinks()
        b.link(personID: bill, hash: "aaa", path: "/a.mkv", now: billNoted)
        b.link(personID: martha, hash: "zzz", path: "/z.mkv", now: marthaNoted)
        try b.save(to: dir)
        let second = try Data(contentsOf: MediaPersonLinks.fileURL(in: dir))

        #expect(first == second, "insertion order leaked into the file")
    }

    @Test("a duplicated edge in the file resolves to the human claim")
    func duplicateEdgesResolveToStated() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Hand-written file with the same edge twice — what a bad merge
        // between two machines would produce.
        let json = """
        [
          {"personID":"\(bill)","mediaHash":"abc","mediaPath":"/a.mkv",
           "source":"detected","notedAt":"2026-08-31T12:00:00Z"},
          {"personID":"\(bill)","mediaHash":"abc","mediaPath":"/a.mkv",
           "source":"stated","notedAt":"2026-08-30T12:00:00Z"}
        ]
        """
        try Data(json.utf8).write(to: MediaPersonLinks.fileURL(in: dir))

        let loaded = MediaPersonLinks.load(from: dir)
        #expect(loaded.count == 1)
        // Older, but a person said it.
        #expect(loaded.media(forPerson: bill).first?.source == .stated)
    }
}
