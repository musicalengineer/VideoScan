import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - GH #477: a machine date never becomes Rick's; a check's date is never the archive day
//
// 1. `registerOrphanPromotedCopy` (the source-gone registration) turned ANY
//    manifest `record_date` into a user date — `user-known` → known, and
//    everything else, `inferred 0.87` / `low 0.41` included, → estimated. A
//    user date means Rick set it: the File Journey's Reviewed step said "date
//    set" and the Confirmed-date filter counted it (DATE-8: an inferred date
//    is shown as inferred, never as his). Now the one rule
//    `PromoteToArchiveJob.userDate(fromManifestFields:)` decides — only a
//    `user-…` cell is a user date.
// 2. `ArchivedAtBackfill`'s last tier froze `archiveFixity.verifiedAt` into
//    `archivedAt`. Verify Archive Copies refreshes `verifiedAt` on every
//    pass, so that is the day of a CHECK, not the day the file was archived —
//    and once written nobody can tell it from Promote's own stamp. The tier is
//    gone: no note and no manifest row → `archivedAt` stays empty (the
//    Journey already says nothing rather than show a check's date).
//
// Dimensions: logic (every confidence cell; every backfill tier), truth
// (pfRecordHasConfirmedDate, the Journey's "date set" predicate), scale (the
// backfill over 100k copies inside a budget, zero from a check's date).
// Media / isolation / writer: not applicable — no file is read, no catalog
// commit is made by either pure step (the backfill's save is the existing
// debounced one).

@MainActor
@Suite("GH #477 — an inferred manifest date is not a user date; a check's date is not the archive day", .serialized)
struct ArchiveDateProvenanceTruthTests {

    private func fields(date: String, confidence: String) -> [String] {
        let row = ArchiveManifestCSV.Row(promotedAt: Date(timeIntervalSince1970: 1_757_700_000),
                                         archiveRelPath: "30_Video/1990-1999/1992/1992-07-15_test.mov",
                                         sha256: "s", sizeBytes: 1, originalPath: "/Volumes/T/test.mov",
                                         originalVolume: "T", recordID: UUID(), sourceRecordID: UUID(),
                                         recordDate: date, dateConfidence: confidence, people: [], starRating: 3)
        return ArchiveManifestCSV.fields(ofLine: ArchiveManifestCSV.line(for: row))
    }

    private func rebuild(_ f: [String]) throws -> (VideoRecord, () -> Void) {
        let sb = try MasterArchiveTestSupport.makeSandbox("orphan477")
        let model = MasterArchiveTestSupport.makeModel(sb)
        let rel = f[1]
        let rec = model.registerOrphanPromotedCopy(sourceID: UUID(), sourcePath: f[4],
                                                   destinationURL: sb.archiveRoot.appendingPathComponent(rel),
                                                   relativePath: rel, sha256: "s", probed: VideoRecord(),
                                                   manifestRow: f)
        return (rec, { sb.cleanup() })
    }

    @Test("RED before #477: an orphan copy whose manifest says 'inferred' / 'low' / '' gets NO user date",
          arguments: ["inferred 0.87", "low 0.41", ""])
    func machineDateIsNotAUserDate(_ confidence: String) throws {
        let (rec, done) = try rebuild(fields(date: "1992-07-15", confidence: confidence))
        defer { done() }
        #expect(rec.userDate == nil, "'\(confidence)' became Rick's date: \(rec.userDate ?? "")")
        #expect(rec.userDateConfidence == nil)
        #expect(!pfRecordHasConfirmedDate(rec), "TRUTH: the Journey would say 'date set' for a machine date")
    }

    @Test("control: 'user-known' and 'user-estimated' rows still rebuild Rick's date at its precision",
          arguments: [("1992-07-15", "user-known", "1992-07-15", UserDateConfidence.known),
                      ("1992-07-xx", "user-estimated", "1992-07", UserDateConfidence.estimated),
                      ("1992-xx-xx", "user-known", "1992", UserDateConfidence.known)])
    func usersDateRebuilds(_ c: (String, String, String, UserDateConfidence)) throws {
        let (rec, done) = try rebuild(fields(date: c.0, confidence: c.1))
        defer { done() }
        #expect(rec.userDate == c.2)
        #expect(rec.userDateConfidence == c.3.rawValue)
    }

    @Test("an undated or decade-only user row yields no user date (nothing to invent)",
          arguments: ["", "xxxx-xx-xx", "1990s"])
    func noDayNoYearNoUserDate(_ date: String) throws {
        let (rec, done) = try rebuild(fields(date: date, confidence: "user-estimated"))
        defer { done() }
        #expect(rec.userDate == nil)
    }

    // MARK: ArchivedAtBackfill

    @Test("RED before #477: a copy whose only trace is a fixity check keeps archivedAt EMPTY — a check's date is not the archive day")
    func fixityDateIsNotTheArchiveDay() {
        let check = Date(timeIntervalSince1970: 1_760_000_000)
        let c = VideoRecord(); c.archiveFixity = ArchiveFixity(digest: "x", verifiedAt: check, sizeBytes: 1)
        let tally = ArchivedAtBackfill.apply(to: [c], manifest: [:])
        #expect(c.archivedAt == nil, "archivedAt took the check's date")
        #expect(tally.filled == 0 && tally.unresolved == 1)
    }

    /// The note tier is left out on purpose: `promoteStamp(inNotes:)` builds two
    /// ISO8601DateFormatters per call (~80 µs in Debug), which this fix does not
    /// touch; the tiers it changes are the manifest lookup and the dropped fixity.
    @Test("SCALE: the backfill over 100k copies (half manifest, half fixity-only) inside 2 s; none from a check")
    func backfillScale() {
        let manifestDate = Date(timeIntervalSince1970: 1_750_000_000)
        var copies: [VideoRecord] = []
        var manifest: [UUID: Date] = [:]
        copies.reserveCapacity(100_000)
        for i in 0..<100_000 {
            let r = VideoRecord()
            if i % 2 == 0 {
                manifest[r.id] = manifestDate
            } else {
                r.archiveFixity = ArchiveFixity(digest: "x", verifiedAt: Date(), sizeBytes: 1)
            }
            copies.append(r)
        }
        let clock = ContinuousClock()
        var tally = ArchivedAtBackfill.Tally()
        let elapsed = clock.measure { tally = ArchivedAtBackfill.apply(to: copies, manifest: manifest) }
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "took \(elapsed)")
        #expect(tally.fromManifest == 50_000 && tally.unresolved == 50_000)
        #expect(copies.enumerated().allSatisfy { $0.offset % 2 == 0 || $0.element.archivedAt == nil })
    }
}
