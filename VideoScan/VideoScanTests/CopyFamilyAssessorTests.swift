import Foundation
import Testing
@testable import VideoScan

// Promote-Helper slice 1 — CopyFamilyAssessor (docs/promote_helper_plan.md).
// Logic: the Clip 01.dv family from the spec + each lexicographic rule;
// Scale: 2,000-member family under budget; Isolation: pure.

private func dv(_ path: String, hash: String = "v1:dv", vol: Int = 0, human: Int = 0,
                reachable: Bool = true, retired: Bool = false, archiveCopy: Bool = false,
                audio: String = "", id: UUID = UUID()) -> CopyFamilyInput {
    CopyFamilyInput(id: id, fullPath: path, sizeBytes: 12_960_000_000, durationSeconds: 3604,
                    videoCodec: "dvvideo", audioCodec: "pcm_s16le", container: "dv",
                    resolution: "720x480", frameRate: "29.97", scanType: "tb",
                    audioChannels: "2", audioSampleRate: "48000", bitDepth: "8",
                    contentHash: hash, audioVerifyStatus: audio,
                    isReachable: reachable, isRetired: retired, isArchiveCopy: archiveCopy,
                    volumeScore: vol, humanScore: human)
}
private func hevc(_ path: String, from: UUID? = nil) -> CopyFamilyInput {
    CopyFamilyInput(fullPath: path, sizeBytes: 1_200_000_000, durationSeconds: 3604,
                    videoCodec: "hevc", audioCodec: "aac", container: "mov", resolution: "720x480",
                    frameRate: "29.97", audioChannels: "2", audioSampleRate: "48000", bitDepth: "10",
                    derivedFrom: from)
}
private func prores(_ path: String, from: UUID? = nil) -> CopyFamilyInput {
    CopyFamilyInput(fullPath: path, sizeBytes: 30_000_000_000, durationSeconds: 3604,
                    videoCodec: "prores", audioCodec: "pcm_s16le", container: "mov", resolution: "720x480",
                    frameRate: "29.97", audioChannels: "2", audioSampleRate: "48000", bitDepth: "10",
                    derivedFrom: from)
}
private func ffv1(_ path: String, from: UUID? = nil) -> CopyFamilyInput {
    CopyFamilyInput(fullPath: path, sizeBytes: 37_100_000_000, durationSeconds: 3604,
                    videoCodec: "ffv1", audioCodec: "flac", container: "mkv", resolution: "720x480",
                    frameRate: "29.97", audioChannels: "2", audioSampleRate: "48000", bitDepth: "8",
                    derivedFrom: from)
}
private func rep(_ a: CopyFamilyAssessment, _ role: CopyRole) -> [CopyRepresentation] {
    a.representations.filter { $0.role == role }
}

@Suite("Copy family assessor — the Clip 01.dv case")
struct CopyFamilyClipCase {
    @Test func dvWinsOverBiggerDerivatives() {
        let dvID = UUID()
        let family: [CopyFamilyInput] =
            (0..<8).map { dv("/Volumes/D\($0)/Clip 01.dv", vol: $0, id: $0 == 0 ? dvID : UUID()) }
            + (0..<3).map { hevc("/Volumes/X/access\($0).mov", from: dvID) }
            + [prores("/Volumes/Edit/Clip 01.mov", from: dvID)]
            + [ffv1("/Volumes/Big/Clip 01.mkv")]                     // provenance missing
        let a = CopyFamilyAssessor.assess(family)
        #expect(a.headline == "13 locations → 4 distinct representations")
        let orig = a.recommendedRepresentation
        #expect(orig?.role == .originalSource)
        #expect(orig?.videoCodec == "dvvideo")
        #expect(orig?.instances.count == 8)
        #expect(orig?.instancesByteIdentical == true)
        #expect(rep(a, .accessCopy).first?.instances.count == 3)
        #expect(rep(a, .editingDerivative).count == 1)
        // The 37 GB FFV1 without provenance is NOT a companion, and size never wins.
        #expect(rep(a, .preservationCompanion).isEmpty)
        #expect(rep(a, .unconfirmedVariant).first?.videoCodec == "ffv1")
        #expect(a.cautions.contains { $0.contains("provenance unknown") })
        // Rule 6: the most reliable drive's DV instance is recommended.
        #expect(a.recommendedInstanceID == family.first { $0.fullPath == "/Volumes/D7/Clip 01.dv" }?.id)
        #expect(a.actions.contains(.promoteRecommendedOriginal))
        #expect(a.actions.contains(.chooseAnotherEquivalent))
        #expect(a.actions.contains(.createAndPromoteCompanion))
        #expect(!a.actions.contains(.createAccessCopy))          // HEVC exists
        #expect(a.actions.first == .verifyAudioFirst)            // audio never verified
        #expect(a.summary.hasPrefix("Recommended original: DVVIDEO"))
    }

    @Test func ffv1WithProvenanceIsACompanion() {
        let dvID = UUID()
        let a = CopyFamilyAssessor.assess([dv("/Volumes/A/c.dv", audio: "ok", id: dvID),
                                           ffv1("/Volumes/A/c.mkv", from: dvID)])
        #expect(rep(a, .preservationCompanion).count == 1)
        #expect(a.actions.contains(.promoteOriginalAndCompanion))
        #expect(!a.actions.contains(.createAndPromoteCompanion))
        #expect(!a.actions.contains(.verifyAudioFirst))
        #expect(a.actions.contains(.createAccessCopy))
    }
}

@Suite("Copy family assessor — rules")
struct CopyFamilyRules {
    @Test func truncatedCopyIsUnconfirmed() {
        var short = dv("/Volumes/A/short.dv", hash: "v1:short")
        short.durationSeconds = 1800
        let a = CopyFamilyAssessor.assess([dv("/Volumes/A/a.dv"), dv("/Volumes/B/a.dv"), short])
        #expect(a.recommendedRepresentation?.instances.count == 2)
        #expect(rep(a, .unconfirmedVariant).count == 1)
        #expect(rep(a, .unconfirmedVariant).first?.reason.contains("Duration") == true)
    }

    @Test func damagedCopyNeverRecommended() {
        var bad = dv("/Volumes/A/bad.dv")
        bad.isPlayable = false
        let a = CopyFamilyAssessor.assess([bad, hevc("/Volumes/A/access.mov")])
        // The only DV is damaged → HEVC is the lineage root with no native codec → presumed.
        #expect(a.recommendedRepresentation?.role == .presumedOriginal)
        #expect(rep(a, .unconfirmedVariant).first?.videoCodec == "dvvideo")
        #expect(a.cautions.contains { $0.contains("presumed") })
    }

    @Test func noNativeCodecPicksLineageRootNotBiggest() {
        let srcID = UUID()
        let src = CopyFamilyInput(id: srcID, fullPath: "/Volumes/A/phone.mp4", sizeBytes: 500_000_000, durationSeconds: 120,
                                  videoCodec: "h264", audioCodec: "aac", container: "mp4", resolution: "1920x1080",
                                  frameRate: "30", audioChannels: "2", audioSampleRate: "44100")
        var big = prores("/Volumes/A/phone_prores.mov", from: srcID)   // 60× larger, still a derivative
        big.durationSeconds = 120
        let a = CopyFamilyAssessor.assess([src, big])
        #expect(a.recommendedRepresentation?.videoCodec == "h264")
        #expect(a.recommendedRepresentation?.role == .presumedOriginal)
        #expect(rep(a, .editingDerivative).count == 1)
    }

    @Test func cameraAVCHDIsNative() {
        #expect(CopyFamilyAssessor.codecClass(videoCodec: "h264", audioCodec: "ac3", container: "mts", originMake: nil) == .native)
        #expect(CopyFamilyAssessor.codecClass(videoCodec: "hevc", audioCodec: "aac", container: "mov", originMake: "Apple") == .native)
        #expect(CopyFamilyAssessor.codecClass(videoCodec: "hevc", audioCodec: "aac", container: "mov", originMake: nil) == .access)
        #expect(CopyFamilyAssessor.codecClass(videoCodec: "prores", audioCodec: "pcm_s24le", container: "mov", originMake: nil) == .editing)
        #expect(CopyFamilyAssessor.codecClass(videoCodec: "ffv1", audioCodec: "flac", container: "mkv", originMake: nil) == .preservation)
    }

    @Test func rule6OrdersOnlineThenReliabilityThenHumanThenPath() {
        let offlineBest = dv("/Volumes/Off/a.dv", vol: 99, human: 99, reachable: false)
        let retired = dv("/Volumes/Ret/a.dv", vol: 98, retired: true)
        let archiveCopy = dv("/Volumes/FamilyArchive/a.dv", vol: 97, archiveCopy: true)
        let reliable = dv("/Volumes/RAID/a.dv", vol: 50, human: 0)
        let scratch = dv("/Volumes/SSD/a.dv", vol: 10, human: 100)
        let a = CopyFamilyAssessor.assess([offlineBest, retired, archiveCopy, reliable, scratch])
        #expect(a.recommendedInstanceID == reliable.id)
        let tie = CopyFamilyAssessor.recommendedInstance([dv("/Volumes/B/z.dv", vol: 5), dv("/Volumes/A/z.dv", vol: 5)])
        #expect(tie?.fullPath == "/Volumes/A/z.dv")
    }

    @Test func emptyAndSingle() {
        #expect(CopyFamilyAssessor.assess([]).actions.isEmpty)
        let one = CopyFamilyAssessor.assess([dv("/Volumes/A/only.dv", audio: "ok")])
        #expect(one.headline == "1 location → 1 distinct representation")
        #expect(one.actions == [.promoteRecommendedOriginal, .createAndPromoteCompanion, .createAccessCopy])
    }

    @Test func scaleTwoThousandMembers() {
        let dvID = UUID()
        var fam: [CopyFamilyInput] = [dv("/Volumes/A/o.dv", id: dvID)]
        for i in 0..<1999 { fam.append(i % 2 == 0 ? hevc("/Volumes/B/a\(i).mov", from: dvID) : dv("/Volumes/C/d\(i).dv", vol: i)) }
        let start = ContinuousClock.now
        let a = CopyFamilyAssessor.assess(fam)
        #expect(ContinuousClock.now - start < .milliseconds(300))
        #expect(a.recommendedRepresentation?.instances.count == 1000)
    }
}

@Suite("Assess copies — family discovery")
@MainActor
struct AssessCopiesFamilyTests {
    private func vr(_ path: String) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (path as NSString).lastPathComponent
        r.directory = (path as NSString).deletingLastPathComponent
        r.fullPath = path
        r.sizeBytes = 10
        r.videoCodec = "dvvideo"; r.audioCodec = "pcm_s16le"; r.durationSeconds = 60
        return r
    }

    @Test func familyFollowsGroupLineageAndSignature() {
        let model = VideoScanModel()
        let g = UUID()
        let seed = vr("/Volumes/A/seed.dv"); seed.duplicateGroupID = g; seed.contentHash = "v1:abc"
        let twin = vr("/Volumes/B/twin.dv"); twin.duplicateGroupID = g
        let child = vr("/Volumes/A/seed_access.mov"); child.derivedFrom = twin.id; child.videoCodec = "hevc"; child.audioCodec = "aac"
        let grandchild = vr("/Volumes/A/seed_access_clip.mov"); grandchild.derivedFrom = child.id; grandchild.videoCodec = "hevc"; grandchild.audioCodec = "aac"
        let hashTwin = vr("/Volumes/C/other name.dv"); hashTwin.contentHash = "v1:abc"
        let stranger = vr("/Volumes/C/stranger.dv")
        let purged = vr("/Volumes/C/purged.dv"); purged.duplicateGroupID = g; purged.purgedAt = Date()
        model.records = [seed, twin, child, grandchild, hashTwin, stranger, purged]
        model.scanTargets = [CatalogScanTarget(searchPath: "/Volumes/A"), CatalogScanTarget(searchPath: "/Volumes/B"), CatalogScanTarget(searchPath: "/Volumes/C")]

        let family = AssessCopiesJob.collectFamily(seed: seed, model: model)
        #expect(Set(family.map(\.id)) == [seed.id, twin.id, child.id, grandchild.id, hashTwin.id])

        let inputs = AssessCopiesJob.projectInputs(family, model: model)
        #expect(inputs.count == 5)
        let a = CopyFamilyAssessor.assess(inputs)
        #expect(a.recommendedRepresentation?.instances.count == 3)          // seed, twin, hashTwin
        #expect(a.representations.contains { $0.role == .accessCopy })
    }
}

@Suite("Archive name advisor")
struct ArchiveNameAdvisorTests {
    @Test func genericStems() {
        for s in ["clip 01", "Clip_01", "IMG_1234", "MVI0042", "00005", "untitled",
                  "Sequence 1", "tape-3", "capture07", "20040704", "1997-07-04 12.30.45", "DSC_0001a", ""] {
            #expect(ArchiveNameAdvisor.isGenericStem(s), "\(s) should be generic")
        }
        for s in ["CapeCodVacation", "Donna_wedding", "Timmy first steps", "Christmas 1997 at Grandmas",
                  "clip of the boat"] {
            #expect(!ArchiveNameAdvisor.isGenericStem(s), "\(s) should NOT be generic")
        }
    }

    @Test func suggestions() {
        #expect(ArchiveNameAdvisor.suggestedTitle(people: ["Donna", "Timmy"], tags: ["cape cod"])
                == "Donna_Timmy_CapeCod")
        #expect(ArchiveNameAdvisor.suggestedTitle(people: [], tags: []) == nil)
        #expect(ArchiveNameAdvisor.suggestedTitle(people: ["donna", "Donna"], tags: []) == "Donna")
    }
}

@Suite("Promote plan — archive titles")
@MainActor
struct ArchiveTitleThreadingTests {
    @Test func perRecordTitleReachesTheDestinationStem() {
        // Pure resolver check: the title replaces the stem, date prefix and
        // extension survive.
        let facts = ArchivePathResolver.RecordFacts(
            streamType: .videoAndAudio, filename: "Clip 01.dv", ext: "DV",
            dateHint: .year(1997), dateIsLowConfidence: false)
        let base = ArchivePathResolver.baseRelativePath(facts: facts, title: "CapeCodVacation")
        #expect(base.hasSuffix("/1997-xx-xx_CapeCodVacation.dv"), "got \(base)")
        let keep = ArchivePathResolver.baseRelativePath(facts: facts, title: nil)
        #expect(keep.hasSuffix("/1997-xx-xx_Clip-01.dv"), "got \(keep)")
    }
}
