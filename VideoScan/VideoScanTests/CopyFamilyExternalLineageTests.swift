import Foundation
import Testing
@testable import VideoScan

// Stage-0 static triage R3 (2026-09-29). `Draft.hasExternalLineage` was set
// and never read, so a native-codec copy whose `derivedFrom` parent is no
// longer in the catalog (purged, or outside the walked family) became a
// lineage root, won the native election and was labelled `.originalSource`
// with the reason "…and not derived from any other copy" — false, and it
// feeds a human Keep/Promote decision in Show Copies.
//
// Logic: the orphan is presumed, not proven, and says why. Sensor: a group
// of byte-identical DVs where only ONE member carries a stale derivedFrom is
// still the proven original (the others are unlineaged copies of it).

private func dvCopy(_ path: String, derivedFrom: UUID? = nil, id: UUID = UUID()) -> CopyFamilyInput {
    CopyFamilyInput(id: id, fullPath: path, sizeBytes: 12_960_000_000, durationSeconds: 3604,
                    videoCodec: "dvvideo", audioCodec: "pcm_s16le", container: "dv",
                    resolution: "720x480", frameRate: "29.97", scanType: "tb",
                    audioChannels: "2", audioSampleRate: "48000", bitDepth: "8",
                    contentHash: "v1:dv", derivedFrom: derivedFrom)
}

@Suite("Copy family assessor — parent no longer in the catalog")
struct CopyFamilyExternalLineageTests {

    @Test func nativeCopyDerivedFromAbsentRecordIsNotCalledTheProvenOriginal() {
        let orphan = dvCopy("/Volumes/X/Clip 01 trim.dv", derivedFrom: UUID())
        let a = CopyFamilyAssessor.assess([orphan])
        let rec = a.recommendedRepresentation
        #expect(rec?.role == .presumedOriginal, "\(String(describing: rec?.role))")
        #expect(rec?.reason.contains("not derived from any other copy") == false)
        #expect(rec?.reason.contains("no longer in the catalog") == true)
        #expect(a.cautions.contains { $0.contains("derived from a file no longer in the catalog") },
                "\(a.cautions)")
    }

    @Test func aGenuineNativeRootBeatsANativeOrphan() {
        // Different duration-matching signature: the orphan is a .mov-wrapped
        // DV (a separate representation) whose parent was purged.
        let originals = (0..<3).map { dvCopy("/Volumes/D\($0)/Clip 01.dv") }
        let orphan = CopyFamilyInput(fullPath: "/Volumes/X/Clip 01.mov", sizeBytes: 13_000_000_000,
                                     durationSeconds: 3604, videoCodec: "dvvideo", audioCodec: "pcm_s16le",
                                     container: "mov", resolution: "720x480", frameRate: "29.97",
                                     audioChannels: "2", audioSampleRate: "48000", derivedFrom: UUID())
        let a = CopyFamilyAssessor.assess(originals + [orphan])
        #expect(a.recommendedRepresentation?.role == .originalSource)
        #expect(a.recommendedRepresentation?.instances.count == 3)
        #expect(!a.cautions.contains { $0.contains("More than one native encoding") },
                "the orphan must not count as a competing native root: \(a.cautions)")
    }

    @Test func oneStaleDerivedFromInAnIdenticalGroupDoesNotDemoteTheOriginal() {
        let group = [dvCopy("/Volumes/A/Clip 01.dv"),
                     dvCopy("/Volumes/B/Clip 01.dv"),
                     dvCopy("/Volumes/C/Clip 01.dv", derivedFrom: UUID())]
        let a = CopyFamilyAssessor.assess(group)
        #expect(a.recommendedRepresentation?.role == .originalSource)
        #expect(!a.cautions.contains { $0.contains("no longer in the catalog") })
    }
}
