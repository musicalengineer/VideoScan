// AssessCopiesJob.swift
// "Assess Copies for Archive…" as a Media File Operations row
// (Promote-Helper slice 2, docs/promote_helper_plan.md).
//
// The job is the VEHICLE for the result panel: it gathers the seed
// record's copy family on the main actor (duplicate group ∪ lineage
// links ∪ archive-copy links ∪ same content signature), projects it into
// Sendable `CopyFamilyInput`s with the duplicate-keeper volume facts, runs
// the pure `CopyFamilyAssessor` off-main, and publishes the
// `CopyFamilyAssessment` for `AssessCopiesDetailView`. No media I/O —
// it finishes in milliseconds; the actions it offers (Promote, Verify
// Audio, Transcode) are the existing verbs, launched from the panel.

import Combine
import Foundation
import os

private let fileOpsLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "fileOps")

@MainActor
final class AssessCopiesJob: @MainActor MediaFileOperationJob {
    let id = UUID()
    let kind: MediaFileOperationKind = .assessCopies
    let startedAt = Date()
    let canPause = false
    /// Lifecycle rule 2 (Rick 2026-08-20): a cancelled Helper session
    /// disappears from the MFO list completely and immediately — the
    /// panel is a workspace, and a cancelled workspace is not a result
    /// worth a "Stopped" row. The Center enforces this via its terminal
    /// watcher (removeIfCancellationVanishes).
    let vanishesWhenCancelled = true

    /// The record the user right-clicked.
    let seed: VideoRecord
    /// Family members by id (for the panel's actions → records).
    private(set) var familyByID: [UUID: VideoRecord]
    private let inputs: [CopyFamilyInput]

    @Published private(set) var assessment: CopyFamilyAssessment?
    @Published private(set) var state: MediaFileOperationState = .running
    @Published private(set) var finishedAt: Date?
    private(set) var task: Task<Void, Never>?

    var title: String { "Archive Helper: \(seed.filename)" }
    var subtitle: String {
        if let a = assessment { return a.headline }
        return "Collecting this recording's copies…"
    }
    var fraction: Double { assessment == nil ? 0 : 1 }
    var isIndeterminate: Bool { assessment == nil }

    init(seed: VideoRecord, family: [VideoRecord], inputs: [CopyFamilyInput]) {
        self.seed = seed
        self.familyByID = Dictionary(uniqueKeysWithValues: family.map { ($0.id, $0) })
        self.inputs = inputs
    }

    func start() {
        guard task == nil else { return }
        let inputs = self.inputs
        task = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                CopyFamilyAssessor.assess(inputs)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.assessment = result
            self.state = .finished(summary: result.headline)
            self.finishedAt = Date()
            fileOpsLog.info("assess copies: \(self.seed.filename, privacy: .public) — \(result.headline, privacy: .public)")
        }
    }

    func cancel() {
        guard state.isActive else { return }
        task?.cancel()
        state = .cancelled
        finishedAt = Date()
    }

    func record(for id: UUID) -> VideoRecord? { familyByID[id] }

    // MARK: - Family discovery + projection (main actor)

    /// Everything the catalog knows to be the same recording as `seed`:
    /// its duplicate group, its lineage (derivedFrom both ways,
    /// transitive), its archive copy / promotion source, and any record
    /// with the same non-empty content signature. Present records only.
    static func collectFamily(seed: VideoRecord, model: VideoScanModel) -> [VideoRecord] {
        let active = pfActiveRecords(model.records)
        var byID: [UUID: VideoRecord] = [:]
        byID.reserveCapacity(active.count)
        var children: [UUID: [VideoRecord]] = [:]
        var byHash: [String: [VideoRecord]] = [:]
        for r in active {
            byID[r.id] = r
            if let d = r.derivedFrom { children[d, default: []].append(r) }
            if !r.contentHash.isEmpty { byHash[r.contentHash, default: []].append(r) }
        }
        var family: [UUID: VideoRecord] = [seed.id: seed]
        var queue: [VideoRecord] = [seed]
        var hops = 0
        while let r = queue.popLast(), hops < 10_000 {
            hops += 1
            var related: [VideoRecord] = []
            if let g = r.duplicateGroupID {
                // Group members: one pass over active (groups are small
                // relative to the catalog; a per-group index is unnecessary
                // at catalog sizes the app targets).
                related += active.filter { $0.duplicateGroupID == g }
            }
            if let d = r.derivedFrom, let parent = byID[d] { related.append(parent) }
            related += children[r.id] ?? []
            if let copy = model.masterArchiveCopy(of: r) { related.append(copy) }
            if let src = model.promotionSource(of: r) { related.append(src) }
            if !r.contentHash.isEmpty { related += byHash[r.contentHash] ?? [] }
            for x in related where family[x.id] == nil {
                family[x.id] = x
                queue.append(x)
            }
        }
        return family.values.sorted { $0.fullPath < $1.fullPath }
    }

    static func projectInputs(_ family: [VideoRecord], model: VideoScanModel) -> [CopyFamilyInput] {
        let policy = model.duplicateKeeperPolicy()
        return family.map { r in
            let facts = policy.facts(forPath: r.fullPath)
            // Rows that predate stream classification carry an empty raw
            // (→ .ffprobeFailed); infer the shape from the codecs so an
            // old-but-healthy DV is not written off as damaged.
            let streamType: StreamType = {
                if !r.streamTypeRaw.isEmpty { return r.streamType }
                if r.videoCodec.isEmpty { return r.audioCodec.isEmpty ? .ffprobeFailed : .audioOnly }
                return r.audioCodec.isEmpty ? .videoOnly : .videoAndAudio
            }()
            return CopyFamilyInput(
                id: r.id,
                fullPath: r.fullPath,
                filename: r.filename,
                sizeBytes: r.sizeBytes,
                durationSeconds: r.durationSeconds,
                videoCodec: r.videoCodec,
                audioCodec: r.audioCodec,
                container: r.container.isEmpty ? r.ext.lowercased() : r.container,
                resolution: r.resolution,
                frameRate: r.frameRate,
                scanType: r.scanType,
                audioChannels: r.audioChannels,
                audioSampleRate: r.audioSampleRate,
                bitDepth: r.bitDepth,
                streamType: streamType,
                isPlayable: r.isPlayable.isEmpty || r.isPlayable == "Yes",
                contentHash: r.contentHash,
                derivedFrom: r.derivedFrom,
                derivationKind: r.derivationKind,
                cleanupRecipeID: r.cleanupRecipeID,
                embeddedCreationDate: r.embeddedCreationDate,
                originMake: r.originMake,
                audioVerifyStatus: r.audioVerifyStatus,
                isReachable: facts?.isReachable ?? VolumeReachability.isReachable(path: r.fullPath),
                isRetired: facts?.isRetired ?? false,
                isMasterArchive: facts?.isMasterArchive ?? false,
                isArchiveCopy: model.isArchiveCopy(r),
                volumeScore: policy.precedenceScore(forPath: r.fullPath, facts: facts),
                humanScore: DuplicateKeeperPolicy.humanMetadataScore(r))
        }
    }
}

// MARK: - Center hook

extension MediaFileOperationsCenter {
    /// Start an assessment for the seed's copy family. Metadata only —
    /// no volume gates. Returns the job so the caller can expand its row.
    ///
    /// ONE listed session per recording (lifecycle rule 3, Rick
    /// 2026-08-20): re-running the Helper while an earlier session for
    /// the same recording is still listed REPLACES it — never a pile.
    /// Replace (not focus) on purpose: the new job re-reads the catalog,
    /// so a promote/repair/date-fix since the last run shows up fresh.
    @discardableResult
    func startAssessCopies(seed: VideoRecord, model: VideoScanModel) -> AssessCopiesJob {
        let family = AssessCopiesJob.collectFamily(seed: seed, model: model)
        replaceEarlierAssessSessions(seed: seed,
                                     familyIDs: Set(family.map(\.id)))
        let inputs = AssessCopiesJob.projectInputs(family, model: model)
        let job = AssessCopiesJob(seed: seed, family: family, inputs: inputs)
        add(job)
        job.start()
        fileOpsLog.info("assess copies started: \(seed.filename, privacy: .public) (\(family.count) in family)")
        model.log("assess copies START: \(seed.filename) — \(family.count) copies → representations")
        return job
    }

    /// Drop every listed Assess session about the SAME RECORDING as the
    /// new seed. "Same recording" is membership in either direction —
    /// the old session's family contains the new seed, or the new seed's
    /// family contains the old session's seed — so re-running from a
    /// different copy of the family (the balanced .mov instead of the
    /// .dv) still replaces rather than stacks. Active stragglers are
    /// cancelled first (assess finishes in ms; this is belt-and-braces).
    /// Split out of startAssessCopies so tests can drive it with
    /// directly-constructed jobs.
    func replaceEarlierAssessSessions(seed: VideoRecord, familyIDs: Set<UUID>) {
        let stale = jobs.compactMap { $0 as? AssessCopiesJob }.filter { old in
            old.seed.id == seed.id
                || old.familyByID[seed.id] != nil
                || familyIDs.contains(old.seed.id)
        }
        guard !stale.isEmpty else { return }
        for old in stale where old.state.isActive { old.cancel() }
        fileOpsLog.info("assess copies: replacing \(stale.count) earlier session(s) for \(seed.filename, privacy: .public)")
        removeJobs(withIDs: Set(stale.map(\.id)))
    }
}
