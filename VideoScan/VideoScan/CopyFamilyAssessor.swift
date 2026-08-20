// CopyFamilyAssessor.swift
// Promote-Helper slice 1 (docs/promote_helper_plan.md, spec
// docs/promote-helper-workflow.md): given one copy family — every catalog
// record that is (or claims to be) the same recording — collapse the
// physical copies into distinct REPRESENTATIONS, decide which one is the
// original source master, pick the instance of it to promote, and list
// the actions that make sense. Pure and Sendable: the main actor projects
// `CopyFamilyInput`s from records (+ DuplicateKeeperPolicy for volume
// rank and human-metadata score); everything here is table-testable.
//
// THE DECISION IS LEXICOGRAPHIC (spec): 1 same complete recording incl.
// audio → 2 known original generation over derivatives → 3 reject
// damaged / truncated → 4 preserve native structure → 5 format
// sustainability → 6 drive reliability + human metadata ONLY among
// byte-identical instances. Size, resolution, bitrate never win alone.
//
// Roles (one per representation):
//   originalSource        native acquisition encoding (DV, DVCPRO, HDV
//                         MPEG-2, MJPEG, camera AVC/HEVC-from-device) or
//                         the lineage root — "promote this first"
//   presumedOriginal      no native codec in the family; the lineage root
//                         / lossless / oldest-stamped candidate — flagged
//                         UNCONFIRMED
//   byteIdenticalCopy     (instances, not a role) — same contentHash
//   preservationCompanion FFV1/lossless audio with provenance to the
//                         original — optional companion
//   editingDerivative     ProRes / DNxHD / DNxHR
//   accessCopy            HEVC / H.264 / AAC
//   unconfirmedVariant    damaged, truncated, duration off, provenance
//                         unknown lossless (the "37 GB FFV1" case)
//
// NOTE `ArchiveReadiness.formatRisk` is longevity advice; it is not a
// fidelity signal and is deliberately NOT consulted here.

import Foundation

// MARK: - Input

struct CopyFamilyInput: Sendable, Equatable, Identifiable {
    var id: UUID
    var fullPath: String
    var filename: String
    var sizeBytes: Int64
    var durationSeconds: Double
    var videoCodec: String
    var audioCodec: String
    var container: String
    var resolution: String
    var frameRate: String
    var scanType: String
    var audioChannels: String
    var audioSampleRate: String
    var bitDepth: String
    var streamTypeRaw: String
    var isPlayable: Bool
    /// Segmented content hash ("v1:…"); empty when never computed.
    var contentHash: String
    var derivedFrom: UUID?
    var derivationKind: String?
    var cleanupRecipeID: String?
    var embeddedCreationDate: Date?
    var originMake: String?
    /// "ok" / "damaged" / "" — from Verify Audio.
    var audioVerifyStatus: String
    /// Volume facts for rule 6 (built by the caller from DuplicateKeeperPolicy).
    var isReachable: Bool
    var isRetired: Bool
    var isMasterArchive: Bool
    var isArchiveCopy: Bool
    /// Higher = more reliable drive (DuplicateKeeperPolicy.precedenceScore).
    var volumeScore: Int
    /// DuplicateKeeperPolicy.humanMetadataScore.
    var humanScore: Int

    init(id: UUID = UUID(), fullPath: String, filename: String? = nil, sizeBytes: Int64 = 0,
         durationSeconds: Double = 0, videoCodec: String = "", audioCodec: String = "",
         container: String = "", resolution: String = "", frameRate: String = "",
         scanType: String = "", audioChannels: String = "", audioSampleRate: String = "",
         bitDepth: String = "", streamType: StreamType = .videoAndAudio, isPlayable: Bool = true,
         contentHash: String = "", derivedFrom: UUID? = nil, derivationKind: String? = nil,
         cleanupRecipeID: String? = nil, embeddedCreationDate: Date? = nil, originMake: String? = nil,
         audioVerifyStatus: String = "", isReachable: Bool = true, isRetired: Bool = false,
         isMasterArchive: Bool = false, isArchiveCopy: Bool = false,
         volumeScore: Int = 0, humanScore: Int = 0) {
        self.id = id
        self.fullPath = fullPath
        self.filename = filename ?? (fullPath as NSString).lastPathComponent
        self.sizeBytes = sizeBytes
        self.durationSeconds = durationSeconds
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.container = container
        self.resolution = resolution
        self.frameRate = frameRate
        self.scanType = scanType
        self.audioChannels = audioChannels
        self.audioSampleRate = audioSampleRate
        self.bitDepth = bitDepth
        self.streamTypeRaw = streamType.rawValue
        self.isPlayable = isPlayable
        self.contentHash = contentHash
        self.derivedFrom = derivedFrom
        self.derivationKind = derivationKind
        self.cleanupRecipeID = cleanupRecipeID
        self.embeddedCreationDate = embeddedCreationDate
        self.originMake = originMake
        self.audioVerifyStatus = audioVerifyStatus
        self.isReachable = isReachable
        self.isRetired = isRetired
        self.isMasterArchive = isMasterArchive
        self.isArchiveCopy = isArchiveCopy
        self.volumeScore = volumeScore
        self.humanScore = humanScore
    }

    var streamType: StreamType { StreamType(rawValue: streamTypeRaw) ?? .ffprobeFailed }
}

// MARK: - Output

enum CopyRole: String, Sendable, Equatable, CaseIterable {
    case originalSource        = "Original source master"
    case presumedOriginal      = "Presumed original (unconfirmed)"
    /// A repair derivative of the original (Balance/Rebuild Audio, external
    /// repair, Clean Up): the PLAYABLE master — corrected audio/picture —
    /// while the original stays the untouched source. Both belong in the
    /// archive (2026-08-19, the Clip 01_balanced.mov case).
    case repairedCopy          = "Repaired copy"
    case preservationCompanion = "Preservation companion"
    case editingDerivative     = "Editing derivative"
    case accessCopy            = "Access copy"
    case unconfirmedVariant    = "Unconfirmed or partial variant"

    /// Display order: original first, then companions, then derivatives.
    var rank: Int {
        switch self {
        case .originalSource: return 0
        case .presumedOriginal: return 1
        case .repairedCopy: return 2
        case .preservationCompanion: return 3
        case .editingDerivative: return 4
        case .accessCopy: return 5
        case .unconfirmedVariant: return 6
        }
    }
    var isOriginal: Bool { self == .originalSource || self == .presumedOriginal }
}

/// One physical copy inside a representation.
struct CopyInstance: Sendable, Equatable, Identifiable {
    var id: UUID
    var fullPath: String
    var filename: String
    var sizeBytes: Int64
    var isReachable: Bool
    var isRetired: Bool
    var isMasterArchive: Bool
    var isArchiveCopy: Bool
    /// Instances sharing a non-empty contentHash get the same cluster;
    /// nil = no hash yet (candidate only).
    var byteCluster: String?
}

/// A distinct encoding of the recording.
struct CopyRepresentation: Sendable, Equatable, Identifiable {
    var id: String { signature }
    /// Human signature, e.g. "DV 720×480 29.97 interlaced · PCM 2ch 48 kHz · mov".
    var signature: String
    var role: CopyRole
    var instances: [CopyInstance]
    /// The instance to use if this representation is promoted (rule 6).
    var recommendedInstanceID: UUID?
    /// Why it got this role, in human words.
    var reason: String
    /// Representative facts for the table.
    var videoCodec: String
    var audioCodec: String
    var container: String
    var resolution: String
    var frameRate: String
    var durationSeconds: Double
    var sizeBytes: Int64
    /// True when EVERY instance shares one byte cluster (all proven-candidate identical).
    var instancesByteIdentical: Bool {
        let clusters = Set(instances.compactMap(\.byteCluster))
        return clusters.count == 1 && instances.allSatisfy { $0.byteCluster != nil }
    }
}

enum CopyFamilyAction: String, Sendable, Equatable, CaseIterable {
    case promoteRecommendedOriginal     = "Promote Recommended Original"
    case promoteOriginalAndRepaired     = "Promote Original + Repaired Copy"
    case chooseAnotherEquivalent        = "Choose Another Equivalent Copy…"
    case createAndPromoteCompanion      = "Create + Promote Lossless Companion"
    case promoteOriginalAndCompanion    = "Promote Original + Companion"
    case createAccessCopy               = "Create Access Copy"
    case verifyAudioFirst               = "Verify Audio First"
}

struct CopyFamilyAssessment: Sendable, Equatable {
    var representations: [CopyRepresentation] = []
    var recommendedRepresentationID: String?
    var recommendedInstanceID: UUID?
    /// "12 locations → 4 distinct representations"
    var headline: String = ""
    /// The paragraph verdict.
    var summary: String = ""
    var actions: [CopyFamilyAction] = []
    var cautions: [String] = []
    var locationCount: Int = 0

    var recommendedRepresentation: CopyRepresentation? {
        representations.first { $0.id == recommendedRepresentationID }
    }
}

// MARK: - Assessor

enum CopyFamilyAssessor {

    /// Duration tolerance for "same complete recording": max(1 s, 1 %).
    static func durationsMatch(_ a: Double, _ b: Double) -> Bool {
        guard a > 0, b > 0 else { return true }     // unknown → cannot refute
        let tol = max(1.0, 0.01 * max(a, b))
        return abs(a - b) <= tol
    }

    // MARK: Codec classes (rule 2 evidence when lineage is absent)

    /// Native acquisition encodings — what a camera or deck wrote.
    static let nativeVideoCodecs: Set<String> = [
        "dvvideo", "dv", "dvcpro", "dvcprohd", "hdv", "mpeg2video", "mjpeg", "mjpega", "mpeg1video",
    ]
    static let preservationVideoCodecs: Set<String> = ["ffv1", "huffyuv", "utvideo", "v210", "rawvideo"]
    static let losslessAudioCodecs: Set<String> = ["pcm_s16le", "pcm_s16be", "pcm_s24le", "pcm_s24be", "pcm_s32le",
                                                   "pcm_f32le", "flac", "alac", "pcm_u8", "pcm_mulaw"]
    static let editingVideoCodecs: Set<String> = ["prores", "prores_ks", "dnxhd", "dnxhr", "cineform", "apch", "apcn", "apcs", "apco"]
    static let accessVideoCodecs: Set<String> = ["hevc", "h265", "h264", "avc1", "vp9", "av1", "mpeg4", "wmv3", "vc1"]

    enum CodecClass: Sendable, Equatable { case native, preservation, editing, access, unknown }

    /// derivationKind values that mean "a REPAIR of the source" — the
    /// output is the same recording with a defect corrected, not a
    /// quality-reduced derivative. Balance/Rebuild write these; Clean Up
    /// stamps cleanupRecipeID instead (see isRepairDerivative).
    static let repairDerivationKinds: Set<String> = ["balanceAudio", "rebuildAudio", "externalRepair"]

    /// ONE predicate for "this member is a repair made from another copy",
    /// used by BOTH the repairedCopy classifier and the anchor election.
    /// The two used to disagree: a Clean Up output (no derivationKind,
    /// cleanupRecipeID stamped) classified as a Repaired copy but did not
    /// anchor its source, so the prepared original could still lose the
    /// election to an unproven better-drive twin (codex QA, 2026-08-20).
    static func isRepairDerivative(_ m: CopyFamilyInput) -> Bool {
        if let dk = m.derivationKind { return repairDerivationKinds.contains(dk) }
        return m.cleanupRecipeID != nil && m.derivedFrom != nil
    }

    static func codecClass(videoCodec: String, audioCodec: String, container: String, originMake: String?) -> CodecClass {
        let v = videoCodec.lowercased()
        let a = audioCodec.lowercased()
        let c = container.lowercased()
        if nativeVideoCodecs.contains(v) || v.hasPrefix("dv") { return .native }
        if preservationVideoCodecs.contains(v) { return .preservation }
        if editingVideoCodecs.contains(v) || v.hasPrefix("prores") || v.hasPrefix("dnx") { return .editing }
        if accessVideoCodecs.contains(v) || v.hasPrefix("h26") || v.hasPrefix("hevc") {
            // Camera-native AVC/HEVC: AVCHD (.mts/.m2ts) or a device stamp (iPhone, GoPro…)
            // with PCM/AC-3 — treat as native acquisition.
            if c == "mts" || c == "m2ts" || c == "m2t" { return .native }
            if let make = originMake, !make.isEmpty { return .native }
            if a.hasPrefix("pcm") || a == "ac3" { return .native }
            return .access
        }
        return .unknown
    }

    // MARK: Entry point

    static func assess(_ inputs: [CopyFamilyInput]) -> CopyFamilyAssessment {
        var out = CopyFamilyAssessment()
        out.locationCount = inputs.count
        guard !inputs.isEmpty else {
            out.headline = "No copies"
            out.summary = "Nothing to assess."
            return out
        }

        // Rule 1 — same complete recording: the family's reference duration is
        // the modal (most common) duration among playable members.
        let referenceDuration = modalDuration(inputs)

        // Repair anchors: the instances the user's repairs were MADE FROM.
        // 2026-08-19 incident: Rick balanced LaCie's Clip 01.dv, but rule 6
        // promoted the Projects twin (better drive, unproven audio) — the
        // copy he had prepared lost to the copy he had never even played.
        // The anchor is the prepared copy; it wins the instance election.
        let repairAnchors: Set<UUID> = Set(inputs.compactMap { m -> UUID? in
            Self.isRepairDerivative(m) ? m.derivedFrom : nil
        })

        // Collapse into representations by encoding signature. Damaged or
        // duration-off INSTANCES are split out of their encoding's group
        // (rules 1/3 are per copy, not per encoding) so a truncated DV does
        // not hide among the complete DVs.
        func groupSignature(_ r: CopyFamilyInput) -> String {
            var sig = signature(r)
            if !r.isPlayable || r.streamType == .ffprobeFailed || r.streamType == .noStreams {
                sig += " — unreadable"
            } else if !durationsMatch(r.durationSeconds, referenceDuration) {
                sig += " — duration differs"
            }
            return sig
        }
        var groups: [String: [CopyFamilyInput]] = [:]
        var order: [String] = []
        for r in inputs {
            let sig = groupSignature(r)
            if groups[sig] == nil { order.append(sig) }
            groups[sig, default: []].append(r)
        }

        // Lineage: a representation whose members are derived FROM a member
        // of another representation is a derivative of it.
        let idToSig: [UUID: String] = Dictionary(uniqueKeysWithValues: inputs.map { ($0.id, groupSignature($0)) })

        struct Draft {
            var sig: String
            var members: [CopyFamilyInput]
            var cls: CodecClass
            var damaged: Bool
            var durationOff: Bool
            var derivedFromSig: String?       // provenance INSIDE the family
            var hasExternalLineage: Bool      // derivedFrom set but points outside
        }
        var drafts: [Draft] = order.map { sig in
            let members = groups[sig]!
            let rep = members[0]
            let cls = codecClass(videoCodec: rep.videoCodec, audioCodec: rep.audioCodec,
                                 container: rep.container, originMake: rep.originMake)
            let damaged = members.allSatisfy { !$0.isPlayable || $0.streamType == .ffprobeFailed || $0.streamType == .noStreams }
            let durationOff = members.allSatisfy { !durationsMatch($0.durationSeconds, referenceDuration) }
            var derivedSig: String? = nil
            var external = false
            for m in members {
                if let d = m.derivedFrom {
                    if let s = idToSig[d], s != sig { derivedSig = s }
                    else if idToSig[d] == nil { external = true }
                }
            }
            return Draft(sig: sig, members: members, cls: cls, damaged: damaged,
                         durationOff: durationOff, derivedFromSig: derivedSig, hasExternalLineage: external)
        }

        // Rule 2/3 — choose the original representation.
        let healthy = drafts.indices.filter { !drafts[$0].damaged && !drafts[$0].durationOff }
        let lineageRoots = healthy.filter { drafts[$0].derivedFromSig == nil }
        let natives = lineageRoots.filter { drafts[$0].cls == .native }
        var originalIndex: Int? = nil
        var originalRole: CopyRole = .originalSource
        var originalReason = ""
        if let n = natives.first {
            originalIndex = n
            originalReason = "Native acquisition encoding (\(drafts[n].members[0].videoCodec.uppercased()) + \(drafts[n].members[0].audioCodec.uppercased())) and not derived from any other copy."
            if natives.count > 1 {
                out.cautions.append("More than one native encoding is present (\(natives.map { drafts[$0].sig }.joined(separator: "; "))). The first is recommended; compare them before promoting.")
            }
        } else if !lineageRoots.isEmpty {
            // No native codec: prefer a lineage root that others derive from,
            // then lossless, then oldest embedded stamp. Never by size.
            let derivedTargets = Set(drafts.compactMap(\.derivedFromSig))
            let ranked = lineageRoots.sorted { a, b in
                let da = derivedTargets.contains(drafts[a].sig), db = derivedTargets.contains(drafts[b].sig)
                if da != db { return da }
                let la = drafts[a].cls == .preservation, lb = drafts[b].cls == .preservation
                if la != lb { return la }
                let ta = drafts[a].members.compactMap(\.embeddedCreationDate).min() ?? .distantFuture
                let tb = drafts[b].members.compactMap(\.embeddedCreationDate).min() ?? .distantFuture
                if ta != tb { return ta < tb }
                return drafts[a].sig < drafts[b].sig
            }
            originalIndex = ranked.first
            originalRole = .presumedOriginal
            originalReason = "No native acquisition encoding in this family; this is the lineage root with the best evidence (others derive from it, lossless, or earliest stamp). Confirm before treating it as the master."
            out.cautions.append("The original generation cannot be confirmed from metadata alone — the recommended copy is presumed, not proven.")
        }

        // Build representations with roles.
        var reps: [CopyRepresentation] = []
        for (i, d) in drafts.enumerated() {
            let role: CopyRole
            let reason: String
            if i == originalIndex {
                role = originalRole; reason = originalReason
            } else if d.damaged {
                role = .unconfirmedVariant
                reason = "Not playable or no readable streams — cannot be verified as the same recording."
            } else if d.durationOff {
                role = .unconfirmedVariant
                reason = String(format: "Duration %.1f s differs from the family's %.1f s — truncated, extended, or a different cut.",
                                d.members[0].durationSeconds, referenceDuration)
            } else if let oi = originalIndex,
                      d.members.contains(where: Self.isRepairDerivative),
                      d.derivedFromSig == drafts[oi].sig || d.derivedFromSig == nil {
                // Repair derivative of the original (or of a member whose
                // signature matched the original's) — the corrected master.
                role = .repairedCopy
                reason = "Repair of the original (corrected audio/picture) — the playable master. Promote it WITH the original; Confirm Repair retires the original from everyday views."
                reps.append(makeRepresentation(d.sig, members: d.members, role: role, reason: reason,
                                               anchors: repairAnchors))
                continue
            } else {
                switch d.cls {
                case .preservation:
                    if d.derivedFromSig != nil, let oi = originalIndex, d.derivedFromSig == drafts[oi].sig {
                        role = .preservationCompanion
                        reason = "Lossless encoding generated directly from the original — a valid preservation companion."
                    } else {
                        role = .unconfirmedVariant
                        reason = "Lossless encoding but its provenance is missing — it may have been generated from a lossy copy, so it cannot be assumed equivalent to the original."
                        out.cautions.append("\(d.sig): lossless but provenance unknown — not promoted automatically.")
                    }
                case .editing:
                    role = .editingDerivative
                    reason = "Mezzanine/editing codec; contains no information beyond the original."
                case .access:
                    role = .accessCopy
                    reason = "Compact lossy encoding for viewing; never a source master."
                case .native:
                    role = .unconfirmedVariant
                    reason = "Native encoding that is not the recommended original (see cautions)."
                case .unknown:
                    role = d.derivedFromSig != nil ? .accessCopy : .unconfirmedVariant
                    reason = d.derivedFromSig != nil ? "Derived from another copy in this family." : "Encoding could not be classified."
                }
            }
            reps.append(makeRepresentation(d.sig, members: d.members, role: role, reason: reason,
                                           anchors: repairAnchors))
        }
        reps.sort { a, b in
            if a.role.rank != b.role.rank { return a.role.rank < b.role.rank }
            return a.signature < b.signature
        }
        out.representations = reps

        // Recommendation + headline.
        if let oi = originalIndex {
            let sig = drafts[oi].sig
            out.recommendedRepresentationID = sig
            out.recommendedInstanceID = reps.first { $0.id == sig }?.recommendedInstanceID
        }
        out.headline = "\(inputs.count) location\(inputs.count == 1 ? "" : "s") → \(reps.count) distinct representation\(reps.count == 1 ? "" : "s")"

        // Unproven equivalence caution: promoting one of several copies
        // that are NOT all proven byte-identical is a leap of faith —
        // Pair Compare is the proof (and would have caught the
        // left-channel-only twin).
        if let oi = originalIndex {
            let m = drafts[oi].members
            if m.count > 1 {
                let hashes = Set(m.compactMap { $0.contentHash.isEmpty ? nil : $0.contentHash })
                if hashes.count > 1 || m.contains(where: { $0.contentHash.isEmpty }) {
                    out.cautions.append("The original's copies are NOT all proven byte-identical (missing or differing content signatures) — they can differ in audio even when the picture matches. Run Compare These Two Files… on the copy you intend to promote before trusting a twin.")
                }
            }
        }

        // Audio caution (rule 1 includes audio). A repair derivative in the
        // family answers it: the audio problem was already handled — the
        // repaired copy is the playable master (2026-08-19: the helper told
        // Rick to fix audio he had ALREADY balanced).
        var audioNeedsWork = false
        if let oi = originalIndex {
            let m = drafts[oi].members
            let hasAudio = m.contains { $0.streamType == .videoAndAudio || $0.streamType == .audioOnly }
            let verified = m.contains { $0.audioVerifyStatus == "ok" }
            let damagedAudio = m.contains { $0.audioVerifyStatus == "damaged" }
            let repaired = reps.first { $0.role == .repairedCopy }
            if let repaired {
                out.cautions.append("Audio was already repaired into \(repaired.instances.first?.filename ?? "a repaired copy") — promote it together with the original (the original keeps its history; the repaired copy is the one to watch).")
            } else if damagedAudio {
                audioNeedsWork = true
                out.cautions.append("Verify Audio reported a problem on the recommended original — fix or choose another equivalent copy before promoting.")
            } else if hasAudio && !verified {
                audioNeedsWork = true
                out.cautions.append("Audio on the recommended original has not been verified — run Verify Audio before promoting (bad or missing audio is the one thing that ruins a keeper).")
            }
        }

        // Actions.
        var actions: [CopyFamilyAction] = []
        if let rec = out.recommendedRepresentation {
            let hasRepaired = reps.contains { $0.role == .repairedCopy }
            if hasRepaired {
                actions.append(.promoteOriginalAndRepaired)
            } else {
                actions.append(.promoteRecommendedOriginal)
            }
            if rec.instances.count > 1 { actions.append(.chooseAnotherEquivalent) }
            if audioNeedsWork {
                actions.insert(.verifyAudioFirst, at: 0)
            }
            let hasCompanion = reps.contains { $0.role == .preservationCompanion }
            if hasCompanion { actions.append(.promoteOriginalAndCompanion) }
            else if rec.role != .presumedOriginal { actions.append(.createAndPromoteCompanion) }
            if !reps.contains(where: { $0.role == .accessCopy }) { actions.append(.createAccessCopy) }
        }
        out.actions = actions

        // Summary paragraph.
        out.summary = composeSummary(reps: reps, recommended: out.recommendedRepresentation, locations: inputs.count)
        return out
    }

    // MARK: Helpers

    static func modalDuration(_ inputs: [CopyFamilyInput]) -> Double {
        var buckets: [Int: (count: Int, sum: Double)] = [:]
        for r in inputs where r.isPlayable && r.durationSeconds > 0 {
            let key = Int((r.durationSeconds / 0.5).rounded())
            var b = buckets[key] ?? (0, 0)
            b.count += 1; b.sum += r.durationSeconds
            buckets[key] = b
        }
        guard let best = buckets.max(by: { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }) else {
            return inputs.map(\.durationSeconds).max() ?? 0
        }
        return best.value.sum / Double(best.value.count)
    }

    /// Encoding signature: codec/audio/container/geometry/fps/scan/channels/rate/depth.
    static func signatureKey(_ r: CopyFamilyInput) -> String {
        [r.videoCodec, r.audioCodec, r.container, r.resolution, r.frameRate, r.scanType,
         r.audioChannels, r.audioSampleRate, r.bitDepth]
            .map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
            .joined(separator: "|")
    }

    static func signature(_ r: CopyFamilyInput) -> String {
        let v = r.videoCodec.isEmpty ? "no video" : r.videoCodec.uppercased()
        let geo = [r.resolution, r.frameRate.isEmpty ? "" : "\(r.frameRate) fps", scanWord(r.scanType)]
            .filter { !$0.isEmpty }.joined(separator: " ")
        let a: String = {
            if r.audioCodec.isEmpty { return "no audio" }
            var parts = [r.audioCodec.uppercased()]
            if !r.audioChannels.isEmpty { parts.append("\(r.audioChannels)ch") }
            if !r.audioSampleRate.isEmpty { parts.append("\(r.audioSampleRate) Hz") }
            return parts.joined(separator: " ")
        }()
        let c = r.container.isEmpty ? "" : " · \(r.container.lowercased())"
        return "\(v)\(geo.isEmpty ? "" : " \(geo)") · \(a)\(c)"
    }

    static func scanWord(_ s: String) -> String {
        let l = s.lowercased()
        if l.isEmpty || l == "progressive" || l == "unknown" { return "" }
        return "interlaced"
    }

    static func makeRepresentation(_ sig: String, members: [CopyFamilyInput], role: CopyRole,
                                   reason: String, anchors: Set<UUID> = []) -> CopyRepresentation {
        // Byte clusters by contentHash; rule 6 picks the instance.
        let instances = members.map { m in
            CopyInstance(id: m.id, fullPath: m.fullPath, filename: m.filename, sizeBytes: m.sizeBytes,
                         isReachable: m.isReachable, isRetired: m.isRetired,
                         isMasterArchive: m.isMasterArchive, isArchiveCopy: m.isArchiveCopy,
                         byteCluster: m.contentHash.isEmpty ? nil : m.contentHash)
        }
        let rep = members[0]
        return CopyRepresentation(
            signature: sig, role: role, instances: instances,
            recommendedInstanceID: recommendedInstance(members, anchors: anchors)?.id,
            reason: reason,
            videoCodec: rep.videoCodec, audioCodec: rep.audioCodec, container: rep.container,
            resolution: rep.resolution, frameRate: rep.frameRate,
            durationSeconds: members.map(\.durationSeconds).max() ?? 0,
            sizeBytes: members.map(\.sizeBytes).max() ?? 0)
    }

    /// Rule 6 — among instances of ONE representation: online › not
    /// retired › not already an archive copy › the REPAIR ANCHOR (the copy
    /// the user's repairs were made from) › verified audio › then, ONLY
    /// when every instance is proven byte-identical, drive reliability
    /// before human metadata — otherwise the copies may differ in content
    /// (left-channel-only twin, 2026-08-19), so EVIDENCE outranks the
    /// drive: human metadata › audio state › volume.
    static func recommendedInstance(_ members: [CopyFamilyInput], anchors: Set<UUID> = []) -> CopyFamilyInput? {
        let hashes = Set(members.compactMap { $0.contentHash.isEmpty ? nil : $0.contentHash })
        let provenIdentical = hashes.count == 1 && members.allSatisfy { !$0.contentHash.isEmpty }
        return members.max { a, b in
            if a.isReachable != b.isReachable { return !a.isReachable }
            if a.isRetired != b.isRetired { return a.isRetired }
            if a.isArchiveCopy != b.isArchiveCopy { return a.isArchiveCopy }
            let aAnchor = anchors.contains(a.id), bAnchor = anchors.contains(b.id)
            if aAnchor != bAnchor { return !aAnchor }
            let aAudio = a.audioVerifyStatus == "ok", bAudio = b.audioVerifyStatus == "ok"
            if aAudio != bAudio { return !aAudio }
            if provenIdentical {
                if a.volumeScore != b.volumeScore { return a.volumeScore < b.volumeScore }
                if a.humanScore != b.humanScore { return a.humanScore < b.humanScore }
            } else {
                if a.humanScore != b.humanScore { return a.humanScore < b.humanScore }
                if a.volumeScore != b.volumeScore { return a.volumeScore < b.volumeScore }
            }
            return a.fullPath > b.fullPath
        }
    }

    static func composeSummary(reps: [CopyRepresentation], recommended: CopyRepresentation?, locations: Int) -> String {
        guard let rec = recommended else {
            return "No copy in this family can be confirmed as a complete, playable recording — nothing is recommended for promotion."
        }
        var s = "Recommended original: \(rec.signature)."
        if rec.instances.count > 1 {
            s += rec.instancesByteIdentical
                ? " \(rec.instances.count) byte-identical locations found (same content signature)."
                : " \(rec.instances.count) locations found; not all have a content signature yet, so equivalence is by metadata until Pair Compare proves it."
        }
        let companions = reps.filter { $0.role == .preservationCompanion }.count
        let editing = reps.filter { $0.role == .editingDerivative }.count
        let access = reps.filter { $0.role == .accessCopy }.count
        let unconfirmed = reps.filter { $0.role == .unconfirmedVariant }.count
        var tail: [String] = []
        if companions > 0 { tail.append("\(companions) preservation companion\(companions == 1 ? "" : "s")") }
        if editing > 0 { tail.append("\(editing) editing derivative\(editing == 1 ? "" : "s")") }
        if access > 0 { tail.append("\(access) access cop\(access == 1 ? "y" : "ies")") }
        if unconfirmed > 0 { tail.append("\(unconfirmed) unconfirmed variant\(unconfirmed == 1 ? "" : "s")") }
        if !tail.isEmpty { s += " Also present: " + tail.joined(separator: ", ") + "." }
        if rec.role == .presumedOriginal {
            s += " The original generation is presumed, not proven."
        } else {
            s += " Derivatives contain no information beyond the original; re-encoding cannot recover what the original recording lost."
        }
        return s
    }
}
