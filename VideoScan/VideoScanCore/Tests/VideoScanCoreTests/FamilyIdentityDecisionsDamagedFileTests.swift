// FamilyIdentityDecisionsDamagedFileTests.swift
// Pins N1009-D-Core-F1 (P1, 2026-10-06): a damaged identity-rulings file
// loads as "nothing ruled", and the next Hide click used to overwrite it,
// erasing weeks of Rick's hand-curated rulings for good.
//
// Invariant: save(to:) never destroys bytes it cannot read. A file that
// exists and does not decode is first moved aside, no-clobber, to
// `<name>.damaged-<ISO8601>`; if that move fails the save is REFUSED and
// the damaged file is left exactly where and as it was.
//
// Synthetic temp dirs only ("test_*" names); never App Support.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Family identity decisions — a damaged file survives the next save")
struct FamilyIdentityDecisionsDamagedFileTests {

    private let mary = FamilyIdentityDecision.Key.familySearch("TEST-0001")
    private let damagedBytes = Data("[{ \"key\": hand-edited, trailing comma, },".utf8)

    private func scratch() throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("test_identity_damaged_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func siblings(in dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    private func damagedCopies(in dir: URL) throws -> [URL] {
        try siblings(in: dir)
            .filter { $0.hasPrefix(FamilyIdentityDecisions.fileName + ".damaged-") }
            .map { dir.appendingPathComponent($0) }
    }

    @Test func aDamagedFileIsMovedAsideNotOverwrittenByTheNextRuling() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FamilyIdentityDecisions.fileURL(in: dir)
        try damagedBytes.write(to: url)

        var d = FamilyIdentityDecisions.load(from: dir)
        #expect(d.isEmpty, "precondition: an unparseable file loads as empty so the tree still opens")
        d.record(.init(key: mary, hidden: true))
        try d.save(to: dir)

        let copies = try damagedCopies(in: dir)
        let listing = try siblings(in: dir)
        #expect(copies.count == 1, "the damaged bytes must survive beside the new file; found \(listing)")
        if let copy = copies.first {
            #expect(try Data(contentsOf: copy) == damagedBytes, "the moved-aside file must be byte-identical")
        }
        #expect(FamilyIdentityDecisions.load(from: dir).isSuppressed(mary), "the user's new ruling is saved")
    }

    @Test func aDamagedFileThatCannotBeMovedAsideRefusesTheSave() throws {
        let dir = try scratch()
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
            try? FileManager.default.removeItem(at: dir)
        }
        let url = FamilyIdentityDecisions.fileURL(in: dir)
        try damagedBytes.write(to: url)
        // A read-only directory: neither a rename nor a publish can happen.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        var d = FamilyIdentityDecisions()
        d.record(.init(key: mary, hidden: true))
        #expect(throws: (any Error).self) { try d.save(to: dir) }
        #expect(try Data(contentsOf: url) == damagedBytes, "a refused save leaves the damaged file untouched")
    }

    @Test func aHealthyFileIsReplacedWithoutLeavingADamagedCopy() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        var d = FamilyIdentityDecisions()
        d.record(.init(key: mary, verified: true))
        try d.save(to: dir)
        d.record(.init(key: mary, verified: true, hidden: true))
        try d.save(to: dir)

        #expect(try damagedCopies(in: dir).isEmpty, "a file that decodes is not damaged")
        #expect(FamilyIdentityDecisions.load(from: dir).isSuppressed(mary))
    }

    /// QA round 1 (B): damaged at tree open (loads as empty), fixed by hand
    /// while the tree is open, then Hide — the stale empty snapshot must not
    /// overwrite the hand-fixed rulings.
    @Test func qaRedAFileFixedByHandAfterLoadIsNotOverwrittenByTheStaleSnapshot() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FamilyIdentityDecisions.fileURL(in: dir)
        try damagedBytes.write(to: url)
        var stale = FamilyIdentityDecisions.load(from: dir)
        #expect(stale.isEmpty)

        // Rick repairs the file by hand: two hard-won rulings.
        let other = FamilyIdentityDecision.Key.familySearch("TEST-0002")
        let third = FamilyIdentityDecision.Key.familySearch("TEST-0003")
        var fixed = FamilyIdentityDecisions()
        fixed.record(.init(key: other, verified: true, note: "hand-fixed"))
        fixed.record(.init(key: third, duplicateOf: other))
        try fixed.save(to: dir)

        // The open tree then hides one record from its stale snapshot.
        stale.record(.init(key: mary, hidden: true))
        try stale.save(to: dir)

        let back = FamilyIdentityDecisions.load(from: dir)
        #expect(back.decision(for: other)?.note == "hand-fixed", "the hand-fixed rulings survive")
        #expect(back.preferred(third) == other)
        #expect(back.isSuppressed(mary), "and the new ruling is applied on top of them")
        #expect(back.count == 3)
    }

    @Test func aStaleSnapshotOverAFileThatIsNowUnreadableIsRefused() throws {
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FamilyIdentityDecisions.fileURL(in: dir)
        var fixed = FamilyIdentityDecisions()
        fixed.record(.init(key: mary, verified: true))
        try fixed.save(to: dir)
        var stale = FamilyIdentityDecisions.load(from: dir)
        let other = Data("{ broken after load".utf8)
        try other.write(to: url)

        stale.record(.init(key: mary, verified: true, hidden: true))
        #expect(throws: (any Error).self) { try stale.save(to: dir) }
        #expect(try Data(contentsOf: url) == other, "refused: the damaged file is left as it is")
    }

    @Test func twoDamagedSavesInARowKeepBothDamagedCopies() throws {
        // Rick hand-edits, breaks it, Hide; hand-edits again, breaks it
        // again, Hide — inside the same second. Neither copy may clobber
        // the other.
        let dir = try scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = FamilyIdentityDecisions.fileURL(in: dir)
        let second = Data("{ also broken".utf8)

        try damagedBytes.write(to: url)
        var d = FamilyIdentityDecisions()
        d.record(.init(key: mary, hidden: true))
        try d.save(to: dir)
        try second.write(to: url)
        try d.save(to: dir)

        let contents = try damagedCopies(in: dir).map { try Data(contentsOf: $0) }
        #expect(Set(contents) == [damagedBytes, second], "both damaged versions must survive")
    }
}
