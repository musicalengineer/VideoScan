// POIProfileAuditTests.swift
// Rick 2026-09-19: "an edit of a person or add/subtract a person deserves a
// log entry for audit level tracking." LOGIC (the diff and the line) ·
// ISOLATION (journal in a temp dir; the test host default is scratch) ·
// SENSOR (settings fields never appear in the audit).

import Foundation
import Testing
@testable import VideoScan

@Suite("People audit — every profile write leaves a line")
struct POIProfileAuditTests {

    private func profile(_ name: String, aliases: [String] = [], surname: String? = nil,
                         middle: String? = nil, uuid: UUID = UUID()) -> POIProfile {
        var p = POIProfile(name: name, referencePath: "/tmp/x")
        p.uuid = uuid
        p.aliases = aliases
        p.surname = surname
        p.middleName = middle
        return p
    }

    @Test("Libby's edit tonight: name, surname and aliases in one line, display name first")
    func libbyEdit() {
        let id = UUID()
        let before = profile("Libby", aliases: ["Libby", "Elizabeth"], uuid: id)
        let after = profile("Elizabeth", aliases: ["Libby"], surname: "Breen", uuid: id)
        let diff = POIProfileAudit.changes(before: before, after: after)
        #expect(diff.map(\.field) == ["name", "surname", "aliases"])
        let line = POIProfileAudit.line(action: .edited, before: before, after: after)
        #expect(line.hasPrefix("[people] edited Libby (\(id.uuidString.prefix(8))) — Elizabeth: "), Comment(rawValue: line))
        #expect(line.contains("name 'Libby' → 'Elizabeth'; surname — → 'Breen'; aliases 'Libby, Elizabeth' → 'Libby'"), Comment(rawValue: line))
    }

    @Test("a save that changes only a threshold or the crop is 'no identity field changed' (SENSOR)")
    func settingsAreNotIdentity() {
        let id = UUID()
        let before = profile("Dan", aliases: ["Dan"], uuid: id)
        var after = before
        after.visionThreshold = 0.9; after.coverCropScale = 2; after.sortOrder = 3
        #expect(POIProfileAudit.changes(before: before, after: after).isEmpty)
        #expect(POIProfileAudit.line(action: .edited, before: before, after: after).hasSuffix("saved, no identity field changed"))
    }

    @Test("added / deleted / restored lines name the person by display name and short uuid")
    func otherActions() {
        let p = profile("Daniel", aliases: ["Dan"], surname: "Breen", middle: "Richard")
        let added = POIProfileAudit.line(action: .added, before: nil, after: p)
        #expect(added.hasPrefix("[people] added Dan (") && added.contains("— Daniel: name 'Daniel'; middleName 'Richard'; surname 'Breen'; aliases 'Dan'"), Comment(rawValue: added))
        #expect(POIProfileAudit.line(action: .deleted, before: p, after: nil).hasPrefix("[people] deleted Dan ("))
        #expect(POIProfileAudit.line(action: .restored, before: nil, after: p).hasPrefix("[people] restored Dan ("))
    }

    @Test("the journal is append-only JSONL with the same changes; the test-host default directory is scratch")
    func journal() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_people_audit_\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let before = profile("Dan", aliases: ["Dan", "bug"], uuid: id)
        let after = profile("Daniel", aliases: ["Dan"], surname: "Breen", middle: "Richard", uuid: id)
        try POIProfileAudit.append(POIProfileAudit.entry(action: .edited, before: before, after: after)!, directory: dir)
        try POIProfileAudit.append(POIProfileAudit.entry(action: .deleted, before: after, after: nil)!, directory: dir)
        let entries = POIProfileAudit.entries(directory: dir)
        #expect(entries.map(\.action) == [.edited, .deleted])
        #expect(entries[0].uuid == id && entries[0].display == "Dan" && entries[0].name == "Daniel")
        #expect(entries[0].changes.map(\.field) == ["name", "middleName", "surname", "aliases"])
        #expect(POIProfileAudit.defaultDirectory.path.contains("VideoScan-tests/people-audit-"), "never the real journal under a test host")
    }
}
