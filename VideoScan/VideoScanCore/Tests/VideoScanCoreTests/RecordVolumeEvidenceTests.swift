import Foundation
import Testing
import VideoScanCore

// #401 (2026-10-30): which volume a record is on, from its own evidence.
// Logic only: pure properties over constructed records (no filesystem).

private let m4 = "A7A2B888-442A-42FC-B548-4FE8FE93F6C8"      // "M4drive"
private let ultra = "D72BF055-A608-4961-BEDD-66F772C8EDFA"   // "UltraDrive"
private let lacie = "84661FE3-C826-4B3B-A550-59BF9FEE77BD"

private func stamp(_ volume: String?) -> ContentFixity {
    ContentFixity(digest: "7a4f16fd", byteCount: 1,
                  stamp: FileIdentityStamp(device: 1, inode: 2, size: 1, mtimeNs: 3, volumeUUID: volume))
}

@Suite("Record volume evidence (#401)")
struct RecordVolumeEvidenceTests {

    @Test func noEvidenceIsUnknown() {
        #expect(VideoRecord().evidencedVolumeUUID == nil)
    }

    @Test func scanContextAloneIsUsedAndNormalized() {
        let r = VideoRecord()
        r.scanContext.volumeUUID = m4.lowercased()
        #expect(r.evidencedVolumeUUID == m4)
    }

    /// The 2026-10-30 shape: a file moved from LaCieWorkspace to Projects
    /// keeps its scan volume; the fixity stamp knows where it is now.
    @Test func fixityStampOutranksAStaleScanVolume() {
        let r = VideoRecord()
        r.scanContext.volumeUUID = lacie
        r.contentFixity = stamp(ultra)
        #expect(r.evidencedVolumeUUID == ultra)
    }

    @Test func auditSightingOutranksEverything() {
        let r = VideoRecord()
        r.scanContext.volumeUUID = lacie
        r.contentFixity = stamp(lacie)
        r.auditSeenOn = AuditSeenOn(volumeUUID: m4, mountFrom: nil, seenAt: Date())
        #expect(r.evidencedVolumeUUID == m4)
    }

    @Test func emptyOrZeroEvidenceFallsThrough() {
        let r = VideoRecord()
        r.auditSeenOn = AuditSeenOn(volumeUUID: "", mountFrom: nil, seenAt: Date())
        r.contentFixity = stamp(nil)
        r.scanContext.volumeUUID = m4
        #expect(r.evidencedVolumeUUID == m4)
    }

    @Test func sameVolumeRuleRefusesOnlyKnownAndDifferent() {
        #expect(VolumeIdentity.mayBeSameVolume(m4, ultra) == false)
        #expect(VolumeIdentity.mayBeSameVolume(m4, m4.lowercased()))
        #expect(VolumeIdentity.mayBeSameVolume(nil, ultra))
        #expect(VolumeIdentity.mayBeSameVolume(m4, nil))
        #expect(VolumeIdentity.mayBeSameVolume("", ultra))
    }
}
