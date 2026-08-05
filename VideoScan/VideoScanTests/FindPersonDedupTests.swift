import Testing
import Foundation
@testable import VideoScan

// In-run fingerprint dedup (Rick 2026-08-05). The key contract comes
// from the 2026-08-04 overnight evidence audit: content identity =
// size|duration|partialMD5 (seven proven duplicate groups, ≥46m42s
// waste), NEVER filename (same-name files scored .720 vs .381 across
// distinct content). These pin the pure key seam; planner behavior is
// covered by integration tests.
struct FindPersonDedupTests {

    private func record(size: Int64, duration: Double, md5: String) -> VideoRecord {
        let rec = VideoRecord()
        rec.sizeBytes = size
        rec.durationSeconds = duration
        rec.partialMD5 = md5
        return rec
    }

    @Test func keyMatchesTheOvernightAuditTriple() {
        let rec = record(size: 43_370_703_217, duration: 36.65,
                         md5: "1f9bd7753bf5112f1da30550f2eb1abc")
        #expect(FindPersonJob.fingerprintKey(for: rec)
                == "43370703217|36.65|1f9bd7753bf5112f1da30550f2eb1abc")
    }

    @Test func identicalContentDifferentNamesShareOneKey() {
        // The CapeCod pair: different filenames/volumes, same bytes.
        let a = record(size: 100, duration: 5.0, md5: "abc")
        let b = record(size: 100, duration: 5.0, md5: "abc")
        a.fullPath = "/Volumes/LaCieWorkspace/CapeCod_June_1997.mp4"
        b.fullPath = "/Volumes/CrucialX9/CapeCod_2000-something.mp4"
        #expect(FindPersonJob.fingerprintKey(for: a) == FindPersonJob.fingerprintKey(for: b))
    }

    @Test func sameSizeDifferentHashDoNotCollide() {
        let a = record(size: 100, duration: 5.0, md5: "abc")
        let b = record(size: 100, duration: 5.0, md5: "def")
        #expect(FindPersonJob.fingerprintKey(for: a) != FindPersonJob.fingerprintKey(for: b))
    }

    @Test func unhashedOrEmptyRecordsProduceNoKey() {
        // No partial hash yet → must scan, never guess.
        #expect(FindPersonJob.fingerprintKey(for: record(size: 100, duration: 5, md5: "")) == nil)
        #expect(FindPersonJob.fingerprintKey(for: record(size: 0, duration: 5, md5: "abc")) == nil)
    }
}
