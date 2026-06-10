import Foundation
import Testing
@testable import VideoScan

// MARK: - CatalogCoverage exclusion tests (Rick 2026-06-10)
//
// CatalogCoverage drives the Dossier Dashboard dial. It used to count
// EVERY record including confirmedJunk + purged ones, which inflated
// the "Remaining" pool and made the dial look stuck even when all
// meaningful records had been dossier'd. These tests pin the
// exclusion rules so a future edit can't silently regress them.

@MainActor
@Suite("CatalogCoverage exclusions")
struct CatalogCoverageExclusionTests {

    private func plain(_ path: String, dossiered: Bool = false) -> VideoRecord {
        let r = VideoRecord()
        r.fullPath = path
        r.filename = (path as NSString).lastPathComponent
        if dossiered {
            r.dossierProcessedAt = Date()
            r.sceneCaptions = [SceneCaption(timestamp: 0, text: "test")]
        }
        return r
    }

    @Test func confirmedJunkRecordsExcludedFromTotalAndDossiered() {
        // 2 normal undossier'd, 1 normal dossier'd, 2 confirmedJunk
        // (one of which also has a dossier timestamp — that shouldn't
        // count it back in).
        let normalUndone = plain("/V/normal1.mov")
        let normalDone = plain("/V/normal2.mov", dossiered: true)
        let junkUndone = plain("/V/junk1.mov")
        junkUndone.mediaDisposition = .confirmedJunk
        let junkDone = plain("/V/junk2.mov", dossiered: true)
        junkDone.mediaDisposition = .confirmedJunk

        let cov = CatalogCoverage(records: [normalUndone, normalDone, junkUndone, junkDone])

        // Junk records of both states must be excluded — total counts
        // only the 2 active records.
        #expect(cov.total == 2,
                "confirmedJunk must not count toward total; got total=\(cov.total)")
        #expect(cov.dossiered == 1,
                "confirmedJunk must not count toward dossiered; got dossiered=\(cov.dossiered)")
        #expect(cov.remaining == 1)
    }

    @Test func purgedRecordsExcluded() {
        // Soft-deleted records (purgedAt non-nil) are tombstones —
        // they shouldn't pull on the dial either.
        let active = plain("/V/active.mov", dossiered: true)
        let purged = plain("/V/purged.mov", dossiered: true)
        purged.purgedAt = Date()

        let cov = CatalogCoverage(records: [active, purged])
        #expect(cov.total == 1)
        #expect(cov.dossiered == 1)
    }

    @Test func emptyCatalogIsAllZeros() {
        let cov = CatalogCoverage(records: [])
        #expect(cov.total == 0)
        #expect(cov.dossiered == 0)
        #expect(cov.remaining == 0)
        #expect(cov.scenes == 0)
        #expect(cov.transcripts == 0)
    }

    @Test func dialPercentReflectsExcludedJunk() {
        // Concrete regression case: 5 records, 2 are confirmedJunk,
        // 3 are active. 2 of the 3 active are dossier'd.
        // Pre-fix:  dial = 2/5 = 40% (dial looks stuck — junk's fault)
        // Post-fix: dial = 2/3 = 67% (honest read)
        var records: [VideoRecord] = []
        for i in 0..<3 { records.append(plain("/V/active_\(i).mov", dossiered: i < 2)) }
        for i in 0..<2 {
            let j = plain("/V/junk_\(i).mov")
            j.mediaDisposition = .confirmedJunk
            records.append(j)
        }
        let cov = CatalogCoverage(records: records)
        #expect(cov.total == 3)
        #expect(cov.dossiered == 2)
        // Dial fraction is computed by the caller; here we just pin
        // the inputs so the caller's math lands at 67% not 40%.
        let fraction = Double(cov.dossiered) / Double(cov.total)
        #expect(abs(fraction - 0.6666) < 0.01,
                "dial fraction should reflect exclusion of junk; got \(fraction)")
    }

    @Test func channelCountersAlsoSkipJunk() {
        // Scene/OCR/transcript counters should respect the exclusion
        // too — otherwise the "Channel coverage" panel would still
        // count contributions from junk-tagged records.
        let active = plain("/V/active.mov", dossiered: true)
        active.audioTranscript = "real footage transcript"
        active.ocrDateCandidates = [SceneCaption(timestamp: 0, text: "1991")]

        let junk = plain("/V/junk.mov", dossiered: true)
        junk.mediaDisposition = .confirmedJunk
        junk.audioTranscript = "junk transcript"
        junk.ocrDateCandidates = [SceneCaption(timestamp: 0, text: "2024")]

        let cov = CatalogCoverage(records: [active, junk])
        #expect(cov.transcripts == 1)
        #expect(cov.ocrDates == 1)
        #expect(cov.scenes == 1) // active has the test caption added by plain(dossiered:true)
    }
}
