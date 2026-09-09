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

@Suite("Archived date — one-time backfill")
struct ArchivedAtBackfillTests {

    @Test("manifest column 0 is the promotion date, keyed by record id, first promotion wins")
    func manifestDates() {
        let id = UUID()
        let header = "promotedAt,relPath,sha256,size,origPath,origVol,recordID,sourceID,date,conf,people,stars"
        let row1 = "\"2026-08-16T20:11:03Z\",\"30_Video/x.mov\",\"ab\",\"1\",\"/a\",\"V\",\"\(id.uuidString)\",\"\(UUID().uuidString)\",\"1994\",\"known\",\"\",\"3\""
        let row2 = "\"2026-08-20T09:00:00Z\",\"30_Video/x_1.mov\",\"cd\",\"1\",\"/a\",\"V\",\"\(id.uuidString)\",\"\(UUID().uuidString)\",\"1994\",\"known\",\"\",\"3\""
        let junk = "\"yesterday\",\"30_Video/y.mov\",\"ef\",\"1\",\"/b\",\"V\",\"not-a-uuid\",\"\",\"\",\"\",\"\",\"0\""
        let dates = ArchivedAtBackfill.manifestDates(text: [header, row1, row2, junk].joined(separator: "\n"))
        #expect(dates.count == 1)
        #expect(dates[id] == ISO8601DateFormatter().date(from: "2026-08-16T20:11:03Z"))
    }

    @MainActor
    @Test("note → manifest → fixity → unresolved; already-stamped copies untouched")
    func precedenceAndIdempotence() {
        let noteDate = ISO8601DateFormatter().date(from: "2026-08-16T20:11:03Z")!
        let manifestDate = Date(timeIntervalSince1970: 1_750_000_000)
        let fixityDate = Date(timeIntervalSince1970: 1_760_000_000)
        let keep = Date(timeIntervalSince1970: 1_000_000_000)

        let a = VideoRecord(); a.notes = "Promote 2026-08-16T20:11:03Z: promoted from /a"
        let b = VideoRecord()
        let c = VideoRecord(); c.archiveFixity = ArchiveFixity(digest: "x", verifiedAt: fixityDate, sizeBytes: 1)
        let d = VideoRecord()
        let e = VideoRecord(); e.archivedAt = keep; e.notes = "Promote 2026-08-16T20:11:03Z: promoted from /e"

        let tally = ArchivedAtBackfill.apply(to: [a, b, c, d, e], manifest: [b.id: manifestDate, e.id: manifestDate])
        #expect(tally == .init(fromNote: 1, fromManifest: 1, fromFixity: 1, unresolved: 1))
        #expect(a.archivedAt == noteDate)
        #expect(b.archivedAt == manifestDate)
        #expect(c.archivedAt == fixityDate)
        #expect(d.archivedAt == nil)
        #expect(e.archivedAt == keep)
        #expect(tally.line.hasPrefix("Backfilled archived dates for 3 archive copies"))
        #expect(ArchivedAtBackfill.apply(to: [a, b, c, e], manifest: [:]).filled == 0, "second pass changes nothing")
    }
}
