// ArchivedAtTests.swift — the archived date (Rick 2026-09-09): Promote's
// field first, the Promote note for older copies, fixity last; DTO round-trip.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archived date — resolution")
struct ArchivedAtTests {

    @Test("field wins, then the earliest Promote note, then fixity")
    func precedence() {
        let field = Date(timeIntervalSince1970: 1_700_000_000)
        let noteDate = ISO8601DateFormatter().date(from: "2026-08-16T20:11:03Z")!
        let fixity = ArchiveFixity(digest: "ab", verifiedAt: Date(timeIntervalSince1970: 1_800_000_000), sizeBytes: 1)

        let r = VideoRecord()
        #expect(r.resolvedArchivedAt == nil)
        #expect(r.archivedDateText == "—")

        r.archiveFixity = fixity
        #expect(r.resolvedArchivedAt == fixity.verifiedAt)

        r.notes = "Promote 2026-08-20T10:00:00Z: promoted from /a · sha256 x\nPromote 2026-08-16T20:11:03Z: promoted from /b · sha256 y"
        #expect(r.resolvedArchivedAt == noteDate, "earliest Promote stamp wins over a later re-promote and over fixity")
        #expect(r.archivedDateText == "2026-08-16")

        r.archivedAt = field
        #expect(r.resolvedArchivedAt == field)
    }

    @Test("note parsing ignores non-Promote lines and garbage stamps")
    func noteParsing() {
        #expect(VideoRecord.promoteStamp(inNotes: "") == nil)
        #expect(VideoRecord.promoteStamp(inNotes: "Verify 2026-08-16T20:11:03Z: ok") == nil)
        #expect(VideoRecord.promoteStamp(inNotes: "Promote yesterday: promoted") == nil)
        #expect(VideoRecord.promoteStamp(inNotes: "  Promote 2026-08-16T20:11:03Z: promoted to Master Archive as 30_Video/x.mov")
                == ISO8601DateFormatter().date(from: "2026-08-16T20:11:03Z"))
    }

    @Test("archivedAt survives the DTO round-trip and is absent when nil")
    func dtoRoundTrip() throws {
        let r = VideoRecord()
        r.filename = "a.mov"; r.fullPath = "/v/a.mov"
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let withoutData = try enc.encode(VideoRecordDTO(r))
        #expect(!String(decoding: withoutData, as: UTF8.self).contains("archivedAt"))
        r.archivedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let data = try enc.encode(VideoRecordDTO(r))
        let back = try dec.decode(VideoRecord.self, from: data)
        #expect(back.archivedAt == r.archivedAt)
    }
}
