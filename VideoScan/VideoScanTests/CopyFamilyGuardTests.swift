import Foundation
import Testing
@testable import VideoScan

// R2 refactor gate (GH #281, plan docs/reviews/cloud/N1006-D-next-refactors.md
// "Guards and the test that must go red"). Each test pins one rule of
// CopyFamilyAssessor.assess that no existing test failed on when its line
// was deleted (C6, C7, C10, C12 damaged branch, C13 presumed branch), plus
// a whole-assessment snapshot over seven fixed families (C14 sort order,
// caution order, wording, roles). Written BEFORE assess() was split; each
// was shown red under a mutation of its guard. Logic only; scale stays
// with CopyFamilyRules.scaleTwoThousandMembers.

/// Fixed UUIDs so the snapshot is reproducible.
private func uid(_ n: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", n))!
}
private func copy(_ n: Int, _ path: String, v: String, a: String, c: String, dur: Double = 600,
                  hash: String = "", from: UUID? = nil, kind: String? = nil, stamp: Date? = nil,
                  make: String? = nil, audio: String = "", playable: Bool = true,
                  stream: StreamType = .videoAndAudio, vol: Int = 0) -> CopyFamilyInput {
    CopyFamilyInput(id: uid(n), fullPath: path, sizeBytes: Int64(n) * 1_000, durationSeconds: dur,
                    videoCodec: v, audioCodec: a, container: c, resolution: "720x480", frameRate: "29.97",
                    audioChannels: "2", audioSampleRate: "48000",
                    streamType: stream, isPlayable: playable, contentHash: hash,
                    derivedFrom: from, derivationKind: kind, embeddedCreationDate: stamp, originMake: make,
                    audioVerifyStatus: audio, volumeScore: vol)
}
private func role(_ a: CopyFamilyAssessment, codec: String) -> CopyRole? {
    a.representations.first { $0.videoCodec == codec }?.role
}

@Suite("Copy family assessor — guards pinned before the R2 split")
struct CopyFamilyGuardTests {

    /// C6 key 1: a root that others derive from beats a lossless root.
    @Test func derivationTargetOutranksLossless() {
        let h264 = copy(1, "/V/a.mp4", v: "h264", a: "aac", c: "mp4")
        let pr = copy(2, "/V/a_prores.mov", v: "prores", a: "pcm_s16le", c: "mov", from: h264.id)
        let lossless = copy(3, "/V/a.mkv", v: "ffv1", a: "flac", c: "mkv")
        let a = CopyFamilyAssessor.assess([lossless, pr, h264])
        #expect(a.recommendedRepresentation?.videoCodec == "h264", "\(a.representations.map(\.signature))")
        #expect(a.recommendedRepresentation?.role == .presumedOriginal)
    }

    /// C6 key 2: with no derivation target, lossless beats lossy, even when
    /// the lossy copy has the earlier stamp and the earlier signature (so
    /// neither later key could produce the same answer).
    @Test func losslessRootBeatsLossyRoot() {
        let lossy = copy(1, "/V/a.mp4", v: "h264", a: "aac", c: "mp4", stamp: Date(timeIntervalSince1970: 1_000))
        let lossless = copy(2, "/V/a.mkv", v: "utvideo", a: "pcm_s16le", c: "mkv", stamp: Date(timeIntervalSince1970: 9_000))
        #expect(CopyFamilyAssessor.signature(lossy) < CopyFamilyAssessor.signature(lossless))
        let a = CopyFamilyAssessor.assess([lossy, lossless])
        #expect(a.recommendedRepresentation?.videoCodec == "utvideo")
    }

    /// C6 key 3: no lossless → the earliest embedded stamp wins (the later
    /// one's signature sorts first, so the final tie-break would pick it).
    @Test func earliestStampBeatsSignatureOrder() {
        let older = copy(1, "/V/z.mp4", v: "mpeg4", a: "aac", c: "mp4", stamp: Date(timeIntervalSince1970: 1_000))
        let newer = copy(2, "/V/a.mp4", v: "h264", a: "aac", c: "mp4", stamp: Date(timeIntervalSince1970: 9_000))
        #expect(CopyFamilyAssessor.signature(newer) < CopyFamilyAssessor.signature(older))
        let a = CopyFamilyAssessor.assess([newer, older])
        #expect(a.recommendedRepresentation?.videoCodec == "mpeg4")
    }

    /// C7: two native roots → the first is recommended, with a caution.
    @Test func twoNativeRootsCaution() {
        let a = CopyFamilyAssessor.assess([copy(1, "/V/c.dv", v: "dvvideo", a: "pcm_s16le", c: "dv"),
                                           copy(2, "/V/c.mov", v: "dvvideo", a: "pcm_s16le", c: "mov")])
        #expect(a.recommendedRepresentation?.container == "dv")
        #expect(a.cautions.contains { $0.hasPrefix("More than one native encoding is present") }, "\(a.cautions)")
    }

    /// C10: an unclassifiable codec is an access copy when derived, else unconfirmed.
    @Test func unknownCodecDependsOnLineage() {
        let dv = copy(1, "/V/c.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", audio: "ok")
        let derived = copy(2, "/V/c.ogv", v: "theora", a: "vorbis", c: "ogg", from: dv.id)
        #expect(CopyFamilyAssessor.codecClass(videoCodec: "theora", audioCodec: "vorbis", container: "ogg",
                                              originMake: nil) == .unknown)
        let a = CopyFamilyAssessor.assess([dv, derived])
        let rep = a.representations.first { $0.videoCodec == "theora" }
        #expect(rep?.role == .accessCopy)
        #expect(rep?.reason == "Derived from another copy in this family.")

        let loose = copy(3, "/V/d.ogv", v: "theora", a: "vorbis", c: "ogg")
        let b = CopyFamilyAssessor.assess([dv, loose])
        let rep2 = b.representations.first { $0.videoCodec == "theora" }
        #expect(rep2?.role == .unconfirmedVariant)
        #expect(rep2?.reason == "Encoding could not be classified.")
    }

    /// C12: damaged audio and no repair → Verify Audio first, "reported a problem".
    @Test func damagedAudioWithoutRepair() {
        let a = CopyFamilyAssessor.assess([copy(1, "/V/c.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", audio: "damaged")])
        #expect(a.actions.first == .verifyAudioFirst)
        #expect(a.cautions.contains { $0.contains("reported a problem") }, "\(a.cautions)")
        #expect(!a.cautions.contains { $0.contains("has not been verified") })
    }

    /// C13: a PRESUMED original is never offered "Create + Promote Lossless Companion".
    @Test func presumedOriginalGetsNoCreateCompanion() {
        let a = CopyFamilyAssessor.assess([copy(1, "/V/a.mp4", v: "h264", a: "aac", c: "mp4", audio: "ok")])
        #expect(a.recommendedRepresentation?.role == .presumedOriginal)
        #expect(!a.actions.contains(.createAndPromoteCompanion), "\(a.actions)")
        #expect(a.actions == [.promoteRecommendedOriginal, .createAccessCopy])
    }

    /// QA (R2 review): the `hasAudio` arm counts an AUDIO-ONLY original, so
    /// its unverified audio still puts Verify Audio first.
    @Test func audioOnlyOriginalNeedsVerify() {
        let a = CopyFamilyAssessor.assess([copy(1, "/V/a.wav", v: "", a: "pcm_s16le", c: "wav", stream: .audioOnly)])
        #expect(a.actions.first == .verifyAudioFirst, "\(a.actions)")
    }

    /// Whole-assessment snapshot over seven fixed families. Must stay green
    /// with ZERO edits across the split.
    @Test func wholeAssessmentSnapshot() {
        var s = ""
        for family in Self.snapshotFamilies {
            dump(CopyFamilyAssessor.assess(family), to: &s)
        }
        #expect(s == copyFamilyGoldenAssessments, "\n\(s)")
    }

    static var snapshotFamilies: [[CopyFamilyInput]] {
        let dv = uid(100)
        let clip: [CopyFamilyInput] = [
            copy(100, "/V/A/Clip 01.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", hash: "v1:dv", vol: 10),
            copy(101, "/V/B/Clip 01.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", hash: "v1:dv", vol: 90),
            copy(102, "/V/X/access.mov", v: "hevc", a: "aac", c: "mov", from: dv),
            copy(103, "/V/E/edit.mov", v: "prores", a: "pcm_s16le", c: "mov", from: dv),
            copy(104, "/V/Big/c.mkv", v: "ffv1", a: "flac", c: "mkv"),
        ]
        let h = uid(200)
        let presumed: [CopyFamilyInput] = [
            copy(201, "/V/a.mkv", v: "ffv1", a: "flac", c: "mkv"),
            copy(200, "/V/a.mp4", v: "h264", a: "aac", c: "mp4", stamp: Date(timeIntervalSince1970: 5)),
            copy(202, "/V/a_prores.mov", v: "prores", a: "pcm_s16le", c: "mov", from: h),
        ]
        let external: [CopyFamilyInput] = [
            copy(300, "/V/orphan.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", from: uid(399)),
            copy(301, "/V/orphan.mp4", v: "h264", a: "aac", c: "mp4", from: uid(300)),
        ]
        let o = uid(400)
        let repaired: [CopyFamilyInput] = [
            copy(400, "/V/tape.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", hash: "v1:t", audio: "damaged"),
            copy(401, "/V/tape2.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", hash: "", vol: 50),
            copy(402, "/V/tape_balanced.mov", v: "dvvideo", a: "pcm_s16le", c: "mov", from: o,
                 kind: "balanceAudio", audio: "ok"),
            copy(403, "/V/tape.mkv", v: "ffv1", a: "flac", c: "mkv", from: o),
        ]
        let damaged: [CopyFamilyInput] = [
            copy(500, "/V/good.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", audio: "ok"),
            copy(501, "/V/good2.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", audio: "ok"),
            copy(502, "/V/short.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", dur: 300),
            copy(503, "/V/bad.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", playable: false),
            copy(504, "/V/nostreams.dv", v: "dvvideo", a: "pcm_s16le", c: "dv", stream: .noStreams),
        ]
        let unknown: [CopyFamilyInput] = [
            copy(600, "/V/a.ogv", v: "theora", a: "vorbis", c: "ogg"),
            copy(601, "/V/b.ogv", v: "theora", a: "vorbis", c: "ogg", dur: 100),
        ]
        let twoNatives: [CopyFamilyInput] = [
            copy(700, "/V/c.dv", v: "dvvideo", a: "pcm_s16le", c: "dv"),
            copy(701, "/V/c.mov", v: "dvvideo", a: "pcm_s16le", c: "mov", make: "Sony"),
            copy(702, "/V/c.mp4", v: "h264", a: "aac", c: "mp4", audio: "ok", stream: .videoOnly),
        ]
        return [clip, presumed, external, repaired, damaged, unknown, twoNatives, []]
    }
}

/// `dump` of the output, captured from main@6db24a65 before the split.
/// Regenerate ONLY for a deliberate behaviour change, never for a refactor.
/// (A file-scope constant, not an enum member, so the type-body lint stays quiet.)
private let copyFamilyGoldenAssessments = #"""
▿ VideoScan.CopyFamilyAssessment
  ▿ representations: 4 elements
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
      - role: VideoScan.CopyRole.originalSource
      ▿ instances: 2 elements
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000100
          - fullPath: "/V/A/Clip 01.dv"
          - filename: "Clip 01.dv"
          - sizeBytes: 100000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          ▿ byteCluster: Optional("v1:dv")
            - some: "v1:dv"
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000101
          - fullPath: "/V/B/Clip 01.dv"
          - filename: "Clip 01.dv"
          - sizeBytes: 101000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          ▿ byteCluster: Optional("v1:dv")
            - some: "v1:dv"
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000101)
        - some: 00000000-0000-0000-0000-000000000101
      - reason: "Native acquisition encoding (DVVIDEO + PCM_S16LE) and not derived from any other copy."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "dv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 101000
    ▿ VideoScan.CopyRepresentation
      - signature: "PRORES 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · mov"
      - role: VideoScan.CopyRole.editingDerivative
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000103
          - fullPath: "/V/E/edit.mov"
          - filename: "edit.mov"
          - sizeBytes: 103000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000103)
        - some: 00000000-0000-0000-0000-000000000103
      - reason: "Mezzanine/editing codec; contains no information beyond the original."
      - videoCodec: "prores"
      - audioCodec: "pcm_s16le"
      - container: "mov"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 103000
    ▿ VideoScan.CopyRepresentation
      - signature: "HEVC 720x480 29.97 fps · AAC 2ch 48000 Hz · mov"
      - role: VideoScan.CopyRole.accessCopy
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000102
          - fullPath: "/V/X/access.mov"
          - filename: "access.mov"
          - sizeBytes: 102000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000102)
        - some: 00000000-0000-0000-0000-000000000102
      - reason: "Compact lossy encoding for viewing; never a source master."
      - videoCodec: "hevc"
      - audioCodec: "aac"
      - container: "mov"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 102000
    ▿ VideoScan.CopyRepresentation
      - signature: "FFV1 720x480 29.97 fps · FLAC 2ch 48000 Hz · mkv"
      - role: VideoScan.CopyRole.unconfirmedVariant
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000104
          - fullPath: "/V/Big/c.mkv"
          - filename: "c.mkv"
          - sizeBytes: 104000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000104)
        - some: 00000000-0000-0000-0000-000000000104
      - reason: "Lossless encoding but its provenance is missing — it may have been generated from a lossy copy, so it cannot be assumed equivalent to the original."
      - videoCodec: "ffv1"
      - audioCodec: "flac"
      - container: "mkv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 104000
  ▿ recommendedRepresentationID: Optional("DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv")
    - some: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
  ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000101)
    - some: 00000000-0000-0000-0000-000000000101
  - headline: "5 locations → 4 distinct representations"
  - summary: "Recommended original: DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv. 2 byte-identical locations found (same content signature). Also present: 1 editing derivative, 1 access copy, 1 unconfirmed variant. Derivatives contain no information beyond the original; re-encoding cannot recover what the original recording lost."
  ▿ actions: 4 elements
    - VideoScan.CopyFamilyAction.verifyAudioFirst
    - VideoScan.CopyFamilyAction.promoteRecommendedOriginal
    - VideoScan.CopyFamilyAction.chooseAnotherEquivalent
    - VideoScan.CopyFamilyAction.createAndPromoteCompanion
  ▿ cautions: 2 elements
    - "FFV1 720x480 29.97 fps · FLAC 2ch 48000 Hz · mkv: lossless but provenance unknown — not promoted automatically."
    - "Audio on the recommended original has not been verified — run Check Media before promoting (bad or missing audio is the one thing that ruins a keeper)."
  - locationCount: 5
▿ VideoScan.CopyFamilyAssessment
  ▿ representations: 3 elements
    ▿ VideoScan.CopyRepresentation
      - signature: "H264 720x480 29.97 fps · AAC 2ch 48000 Hz · mp4"
      - role: VideoScan.CopyRole.presumedOriginal
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000200
          - fullPath: "/V/a.mp4"
          - filename: "a.mp4"
          - sizeBytes: 200000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000200)
        - some: 00000000-0000-0000-0000-000000000200
      - reason: "No native acquisition encoding in this family; this is the lineage root with the best evidence (others derive from it, lossless, or earliest stamp). Confirm before treating it as the master."
      - videoCodec: "h264"
      - audioCodec: "aac"
      - container: "mp4"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 200000
    ▿ VideoScan.CopyRepresentation
      - signature: "PRORES 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · mov"
      - role: VideoScan.CopyRole.editingDerivative
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000202
          - fullPath: "/V/a_prores.mov"
          - filename: "a_prores.mov"
          - sizeBytes: 202000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000202)
        - some: 00000000-0000-0000-0000-000000000202
      - reason: "Mezzanine/editing codec; contains no information beyond the original."
      - videoCodec: "prores"
      - audioCodec: "pcm_s16le"
      - container: "mov"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 202000
    ▿ VideoScan.CopyRepresentation
      - signature: "FFV1 720x480 29.97 fps · FLAC 2ch 48000 Hz · mkv"
      - role: VideoScan.CopyRole.unconfirmedVariant
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000201
          - fullPath: "/V/a.mkv"
          - filename: "a.mkv"
          - sizeBytes: 201000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000201)
        - some: 00000000-0000-0000-0000-000000000201
      - reason: "Lossless encoding but its provenance is missing — it may have been generated from a lossy copy, so it cannot be assumed equivalent to the original."
      - videoCodec: "ffv1"
      - audioCodec: "flac"
      - container: "mkv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 201000
  ▿ recommendedRepresentationID: Optional("H264 720x480 29.97 fps · AAC 2ch 48000 Hz · mp4")
    - some: "H264 720x480 29.97 fps · AAC 2ch 48000 Hz · mp4"
  ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000200)
    - some: 00000000-0000-0000-0000-000000000200
  - headline: "3 locations → 3 distinct representations"
  - summary: "Recommended original: H264 720x480 29.97 fps · AAC 2ch 48000 Hz · mp4. Also present: 1 editing derivative, 1 unconfirmed variant. The original generation is presumed, not proven."
  ▿ actions: 3 elements
    - VideoScan.CopyFamilyAction.verifyAudioFirst
    - VideoScan.CopyFamilyAction.promoteRecommendedOriginal
    - VideoScan.CopyFamilyAction.createAccessCopy
  ▿ cautions: 3 elements
    - "The original generation cannot be confirmed from metadata alone — the recommended copy is presumed, not proven."
    - "FFV1 720x480 29.97 fps · FLAC 2ch 48000 Hz · mkv: lossless but provenance unknown — not promoted automatically."
    - "Audio on the recommended original has not been verified — run Check Media before promoting (bad or missing audio is the one thing that ruins a keeper)."
  - locationCount: 3
▿ VideoScan.CopyFamilyAssessment
  ▿ representations: 2 elements
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
      - role: VideoScan.CopyRole.presumedOriginal
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000300
          - fullPath: "/V/orphan.dv"
          - filename: "orphan.dv"
          - sizeBytes: 300000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000300)
        - some: 00000000-0000-0000-0000-000000000300
      - reason: "Derived from a file no longer in the catalog, so it cannot be proven to be the original; it is the copy with the best remaining evidence. Confirm before treating it as the master."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "dv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 300000
    ▿ VideoScan.CopyRepresentation
      - signature: "H264 720x480 29.97 fps · AAC 2ch 48000 Hz · mp4"
      - role: VideoScan.CopyRole.accessCopy
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000301
          - fullPath: "/V/orphan.mp4"
          - filename: "orphan.mp4"
          - sizeBytes: 301000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000301)
        - some: 00000000-0000-0000-0000-000000000301
      - reason: "Compact lossy encoding for viewing; never a source master."
      - videoCodec: "h264"
      - audioCodec: "aac"
      - container: "mp4"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 301000
  ▿ recommendedRepresentationID: Optional("DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv")
    - some: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
  ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000300)
    - some: 00000000-0000-0000-0000-000000000300
  - headline: "2 locations → 2 distinct representations"
  - summary: "Recommended original: DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv. Also present: 1 access copy. The original generation is presumed, not proven."
  ▿ actions: 2 elements
    - VideoScan.CopyFamilyAction.verifyAudioFirst
    - VideoScan.CopyFamilyAction.promoteRecommendedOriginal
  ▿ cautions: 3 elements
    - "The original generation cannot be confirmed from metadata alone — the recommended copy is presumed, not proven."
    - "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv: derived from a file no longer in the catalog — its source cannot be checked."
    - "Audio on the recommended original has not been verified — run Check Media before promoting (bad or missing audio is the one thing that ruins a keeper)."
  - locationCount: 2
▿ VideoScan.CopyFamilyAssessment
  ▿ representations: 3 elements
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
      - role: VideoScan.CopyRole.originalSource
      ▿ instances: 2 elements
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000400
          - fullPath: "/V/tape.dv"
          - filename: "tape.dv"
          - sizeBytes: 400000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          ▿ byteCluster: Optional("v1:t")
            - some: "v1:t"
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000401
          - fullPath: "/V/tape2.dv"
          - filename: "tape2.dv"
          - sizeBytes: 401000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000400)
        - some: 00000000-0000-0000-0000-000000000400
      - reason: "Native acquisition encoding (DVVIDEO + PCM_S16LE) and not derived from any other copy."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "dv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 401000
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · mov"
      - role: VideoScan.CopyRole.repairedCopy
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000402
          - fullPath: "/V/tape_balanced.mov"
          - filename: "tape_balanced.mov"
          - sizeBytes: 402000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000402)
        - some: 00000000-0000-0000-0000-000000000402
      - reason: "Repair of the original (corrected audio/picture) — the playable master. Promote it WITH the original; Confirm Repair retires the original from everyday views."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "mov"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 402000
    ▿ VideoScan.CopyRepresentation
      - signature: "FFV1 720x480 29.97 fps · FLAC 2ch 48000 Hz · mkv"
      - role: VideoScan.CopyRole.preservationCompanion
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000403
          - fullPath: "/V/tape.mkv"
          - filename: "tape.mkv"
          - sizeBytes: 403000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000403)
        - some: 00000000-0000-0000-0000-000000000403
      - reason: "Lossless encoding generated directly from the original — a valid preservation companion."
      - videoCodec: "ffv1"
      - audioCodec: "flac"
      - container: "mkv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 403000
  ▿ recommendedRepresentationID: Optional("DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv")
    - some: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
  ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000400)
    - some: 00000000-0000-0000-0000-000000000400
  - headline: "4 locations → 3 distinct representations"
  - summary: "Recommended original: DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv. 2 locations found; not all have a content signature yet, so equivalence is by metadata until Pair Compare proves it. Also present: 1 preservation companion. Derivatives contain no information beyond the original; re-encoding cannot recover what the original recording lost."
  ▿ actions: 4 elements
    - VideoScan.CopyFamilyAction.promoteOriginalAndRepaired
    - VideoScan.CopyFamilyAction.chooseAnotherEquivalent
    - VideoScan.CopyFamilyAction.promoteOriginalAndCompanion
    - VideoScan.CopyFamilyAction.createAccessCopy
  ▿ cautions: 2 elements
    - "The original\'s copies are NOT all proven byte-identical (missing or differing content signatures) — they can differ in audio even when the picture matches. Run Compare These Two Files… on the copy you intend to promote before trusting a twin."
    - "Audio was already repaired into tape_balanced.mov — promote it together with the original (the original keeps its history; the repaired copy is the one to watch)."
  - locationCount: 4
▿ VideoScan.CopyFamilyAssessment
  ▿ representations: 3 elements
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
      - role: VideoScan.CopyRole.originalSource
      ▿ instances: 2 elements
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000500
          - fullPath: "/V/good.dv"
          - filename: "good.dv"
          - sizeBytes: 500000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000501
          - fullPath: "/V/good2.dv"
          - filename: "good2.dv"
          - sizeBytes: 501000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000500)
        - some: 00000000-0000-0000-0000-000000000500
      - reason: "Native acquisition encoding (DVVIDEO + PCM_S16LE) and not derived from any other copy."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "dv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 501000
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv — duration differs"
      - role: VideoScan.CopyRole.unconfirmedVariant
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000502
          - fullPath: "/V/short.dv"
          - filename: "short.dv"
          - sizeBytes: 502000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000502)
        - some: 00000000-0000-0000-0000-000000000502
      - reason: "Duration 300.0 s differs from the family\'s 600.0 s — truncated, extended, or a different cut."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "dv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 300.0
      - sizeBytes: 502000
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv — unreadable"
      - role: VideoScan.CopyRole.unconfirmedVariant
      ▿ instances: 2 elements
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000503
          - fullPath: "/V/bad.dv"
          - filename: "bad.dv"
          - sizeBytes: 503000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000504
          - fullPath: "/V/nostreams.dv"
          - filename: "nostreams.dv"
          - sizeBytes: 504000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000503)
        - some: 00000000-0000-0000-0000-000000000503
      - reason: "Not playable or no readable streams — cannot be verified as the same recording."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "dv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 504000
  ▿ recommendedRepresentationID: Optional("DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv")
    - some: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
  ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000500)
    - some: 00000000-0000-0000-0000-000000000500
  - headline: "5 locations → 3 distinct representations"
  - summary: "Recommended original: DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv. 2 locations found; not all have a content signature yet, so equivalence is by metadata until Pair Compare proves it. Also present: 2 unconfirmed variants. Derivatives contain no information beyond the original; re-encoding cannot recover what the original recording lost."
  ▿ actions: 4 elements
    - VideoScan.CopyFamilyAction.promoteRecommendedOriginal
    - VideoScan.CopyFamilyAction.chooseAnotherEquivalent
    - VideoScan.CopyFamilyAction.createAndPromoteCompanion
    - VideoScan.CopyFamilyAction.createAccessCopy
  ▿ cautions: 1 element
    - "The original\'s copies are NOT all proven byte-identical (missing or differing content signatures) — they can differ in audio even when the picture matches. Run Compare These Two Files… on the copy you intend to promote before trusting a twin."
  - locationCount: 5
▿ VideoScan.CopyFamilyAssessment
  ▿ representations: 2 elements
    ▿ VideoScan.CopyRepresentation
      - signature: "THEORA 720x480 29.97 fps · VORBIS 2ch 48000 Hz · ogg"
      - role: VideoScan.CopyRole.presumedOriginal
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000601
          - fullPath: "/V/b.ogv"
          - filename: "b.ogv"
          - sizeBytes: 601000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000601)
        - some: 00000000-0000-0000-0000-000000000601
      - reason: "No native acquisition encoding in this family; this is the lineage root with the best evidence (others derive from it, lossless, or earliest stamp). Confirm before treating it as the master."
      - videoCodec: "theora"
      - audioCodec: "vorbis"
      - container: "ogg"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 100.0
      - sizeBytes: 601000
    ▿ VideoScan.CopyRepresentation
      - signature: "THEORA 720x480 29.97 fps · VORBIS 2ch 48000 Hz · ogg — duration differs"
      - role: VideoScan.CopyRole.unconfirmedVariant
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000600
          - fullPath: "/V/a.ogv"
          - filename: "a.ogv"
          - sizeBytes: 600000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000600)
        - some: 00000000-0000-0000-0000-000000000600
      - reason: "Duration 600.0 s differs from the family\'s 100.0 s — truncated, extended, or a different cut."
      - videoCodec: "theora"
      - audioCodec: "vorbis"
      - container: "ogg"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 600000
  ▿ recommendedRepresentationID: Optional("THEORA 720x480 29.97 fps · VORBIS 2ch 48000 Hz · ogg")
    - some: "THEORA 720x480 29.97 fps · VORBIS 2ch 48000 Hz · ogg"
  ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000601)
    - some: 00000000-0000-0000-0000-000000000601
  - headline: "2 locations → 2 distinct representations"
  - summary: "Recommended original: THEORA 720x480 29.97 fps · VORBIS 2ch 48000 Hz · ogg. Also present: 1 unconfirmed variant. The original generation is presumed, not proven."
  ▿ actions: 3 elements
    - VideoScan.CopyFamilyAction.verifyAudioFirst
    - VideoScan.CopyFamilyAction.promoteRecommendedOriginal
    - VideoScan.CopyFamilyAction.createAccessCopy
  ▿ cautions: 2 elements
    - "The original generation cannot be confirmed from metadata alone — the recommended copy is presumed, not proven."
    - "Audio on the recommended original has not been verified — run Check Media before promoting (bad or missing audio is the one thing that ruins a keeper)."
  - locationCount: 2
▿ VideoScan.CopyFamilyAssessment
  ▿ representations: 3 elements
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
      - role: VideoScan.CopyRole.originalSource
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000700
          - fullPath: "/V/c.dv"
          - filename: "c.dv"
          - sizeBytes: 700000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000700)
        - some: 00000000-0000-0000-0000-000000000700
      - reason: "Native acquisition encoding (DVVIDEO + PCM_S16LE) and not derived from any other copy."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "dv"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 700000
    ▿ VideoScan.CopyRepresentation
      - signature: "H264 720x480 29.97 fps · AAC 2ch 48000 Hz · mp4"
      - role: VideoScan.CopyRole.accessCopy
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000702
          - fullPath: "/V/c.mp4"
          - filename: "c.mp4"
          - sizeBytes: 702000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000702)
        - some: 00000000-0000-0000-0000-000000000702
      - reason: "Compact lossy encoding for viewing; never a source master."
      - videoCodec: "h264"
      - audioCodec: "aac"
      - container: "mp4"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 702000
    ▿ VideoScan.CopyRepresentation
      - signature: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · mov"
      - role: VideoScan.CopyRole.unconfirmedVariant
      ▿ instances: 1 element
        ▿ VideoScan.CopyInstance
          - id: 00000000-0000-0000-0000-000000000701
          - fullPath: "/V/c.mov"
          - filename: "c.mov"
          - sizeBytes: 701000
          - isReachable: true
          - isRetired: false
          - isMasterArchive: false
          - isArchiveCopy: false
          - byteCluster: nil
      ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000701)
        - some: 00000000-0000-0000-0000-000000000701
      - reason: "Native encoding that is not the recommended original (see cautions)."
      - videoCodec: "dvvideo"
      - audioCodec: "pcm_s16le"
      - container: "mov"
      - resolution: "720x480"
      - frameRate: "29.97"
      - durationSeconds: 600.0
      - sizeBytes: 701000
  ▿ recommendedRepresentationID: Optional("DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv")
    - some: "DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv"
  ▿ recommendedInstanceID: Optional(00000000-0000-0000-0000-000000000700)
    - some: 00000000-0000-0000-0000-000000000700
  - headline: "3 locations → 3 distinct representations"
  - summary: "Recommended original: DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv. Also present: 1 access copy, 1 unconfirmed variant. Derivatives contain no information beyond the original; re-encoding cannot recover what the original recording lost."
  ▿ actions: 3 elements
    - VideoScan.CopyFamilyAction.verifyAudioFirst
    - VideoScan.CopyFamilyAction.promoteRecommendedOriginal
    - VideoScan.CopyFamilyAction.createAndPromoteCompanion
  ▿ cautions: 2 elements
    - "More than one native encoding is present (DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · dv; DVVIDEO 720x480 29.97 fps · PCM_S16LE 2ch 48000 Hz · mov). The first is recommended; compare them before promoting."
    - "Audio on the recommended original has not been verified — run Check Media before promoting (bad or missing audio is the one thing that ruins a keeper)."
  - locationCount: 3
▿ VideoScan.CopyFamilyAssessment
  - representations: 0 elements
  - recommendedRepresentationID: nil
  - recommendedInstanceID: nil
  - headline: "No copies"
  - summary: "Nothing to assess."
  - actions: 0 elements
  - cautions: 0 elements
  - locationCount: 0

"""#
