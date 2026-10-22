// VideoScanModel+PrunePlan.swift
// The app half of the ONE prune plan (docs/design/pruneplan_simple_2026-10-21.md):
// the main-actor snapshot of the records that can matter, R2–R5 captured as
// a `hold`, and the off-main build + disk check. "Archived — what next?"
// (a Promote batch, or Tidy's backlog) and Triage ▸ Clean up ▸ Excess copies
// both call `prunePlan(batch:)`; so does the protection line.
//
// R2 live: `removal == nil`. R3: archive files are the archive side; a
// working record the gate refuses AS THE ARCHIVE (its tree, its volume) is
// never snapshotted — FamilyArchive is never listed. R4: offline → "drive not
// connected"; any other gate refusal (Read only, an unprovable drive) or an
// Archive backup mark → "drive is protected"; network is asked off-main. R5:
// a recovered A/V pair half.
//
// Memory: one `PruneSnapshot` per archive file and per RELEVANT working
// record (same digest, linked by lineage, same filename, or in the batch);
// a record that cannot matter costs a few set probes and allocates nothing
// but its lowercased name. Never called from a view body.

import Foundation
import VideoScanCore

extension VideoScanModel {

    /// The disk questions the plan asks off the main actor — injectable so
    /// synthetic-path tests never touch a volume.
    struct PruneDiskProbe: Sendable {
        var isMissing: @Sendable (String) -> Bool
        var isNetwork: @Sendable (String) -> Bool

        static let live = PruneDiskProbe(isMissing: { !FileManager.default.fileExists(atPath: $0) },
                                         isNetwork: { ArchiveVolumeProtection.isNetworkMount($0) })
    }

    /// The plan for `batch` (nil = the whole catalog): snapshot on main,
    /// build + disk check off it.
    func prunePlan(batch: Set<UUID>?, isOnline: @escaping (VideoRecord) -> Bool = VideoScanModel.volumeIsOnline,
                   disk: PruneDiskProbe = .live) async -> PrunePlan {
        let snaps = pruneSnapshots(batch: batch, isOnline: isOnline)
        return await Self.prunePlanOffMain(snaps, batch: batch, disk: disk)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    nonisolated static func prunePlanOffMain(_ snapshots: [PruneSnapshot], batch: Set<UUID>?,
                                             disk: PruneDiskProbe) async -> PrunePlan {
        PrunePlan.build(snapshots, batch: batch)
            .confirmingOnDisk(isMissing: disk.isMissing, isNetwork: disk.isNetwork)
    }

    // MARK: Snapshot (main actor, one pass)

    /// Is the VOLUME mounted — never "does the file exist" (2026-09-21: a
    /// missing file on the boot disk is a missing file, not a drive that is
    /// not connected; the disk probe says "missing").
    nonisolated static func volumeIsOnline(_ rec: VideoRecord) -> Bool {
        VolumeReachability.isVolumeReachable(path: rec.fullPath)
    }

    func pruneSnapshots(batch: Set<UUID>?, isOnline: @escaping (VideoRecord) -> Bool) -> [PruneSnapshot] {
        var out: [PruneSnapshot] = []
        for r in records where r.removal == nil && isArchiveElement(r) {
            out.append(pruneArchiveSnapshot(r))
        }
        let wanted = PruneRelevance(archives: out, batch: batch)
        guard !wanted.isEmpty else { return out }
        let rules = PruneHoldRules(model: self, isOnline: isOnline)
        for r in records where r.removal == nil && wanted.contains(r) && !isArchiveElement(r) {
            if let s = rules.snapshot(r) { out.append(s) }
        }
        return out
    }

    private func pruneArchiveSnapshot(_ r: VideoRecord) -> PruneSnapshot {
        PruneSnapshot(id: r.id, filename: r.filename, fullPath: r.fullPath, volumeName: r.volumeName,
                      sizeBytes: r.sizeBytes, digest: Self.verifiedArchiveDigest(r), isArchive: true,
                      derivedFrom: isArchiveCopy(r) ? r.derivedFrom : nil, attestations: r.backupAttestations)
    }

    /// R1's archive side: the read-back SHA-256 (`archiveFixity` exists only
    /// once a read-back verified it), and only when the record's digest key —
    /// the one the curated tables are keyed by — agrees with it.
    nonisolated static func verifiedArchiveDigest(_ r: VideoRecord) -> String? {
        guard let f = r.archiveFixity, f.algorithm == ContentFixity.sha256 else { return nil }
        let digest = f.digest.lowercased()
        return CatalogCommit.digest(of: r) == digest ? digest : nil
    }

    // MARK: The protection line and Tidy's backlog

    /// The protection line for a batch, from the same plan.
    func batchProtection(for recordIDs: [UUID]) async -> ProtectionSummary {
        await prunePlan(batch: Set(recordIDs)).protection
    }

    /// Tidy → "Copies of archived media": the same sheet, catalog-wide. The
    /// headline's count and size are BOTH the offered copies (QA r1 m1). The
    /// sheet opens even when nothing is offered, and says why (QA r1 M1).
    /// Computed off-main; presents when done.
    func offerArchivedWhatNextForBacklog() async {
        let plan = await prunePlan(batch: nil)
        let ids = plan.items.flatMap { $0.offered.map(\.id) }
        if ids.isEmpty {
            let why = plan.reasonSummary.joined(separator: ", ")
            log("Archived — what next?: no obvious choices — nothing outside the Master Archive is byte-for-byte a verified archive file"
                + (why.isEmpty ? "." : " (\(why))."))
        }
        offerArchivedWhatNext(batchID: "tidy-\(UUID().uuidString.prefix(8))", recordIDs: ids,
                              totalBytes: plan.offeredBytes, protection: plan.protection, source: .tidyBacklog)
    }

    /// The plan, one line per archive file, when a sheet first shows it.
    func logPrunePlan(_ plan: PrunePlan, batchID: String) {
        for line in plan.logLines(batchID: batchID) { log(line) }
    }
}

// MARK: - Which records can matter

/// Built from the archive snapshots: a working record is snapshotted only
/// when it could land in an item (same digest, lineage, filename) or is in
/// the batch. (≈ a precomputed filter; four hash-set probes per record.)
struct PruneRelevance {
    private var digests = Set<String>()
    private var links = Set<UUID>()
    private var names = Set<String>()
    private let batch: Set<UUID>

    init(archives: [PruneSnapshot], batch: Set<UUID>?) {
        self.batch = batch ?? []
        for a in archives {
            if let d = a.digest { digests.insert(d) }
            links.insert(a.id)
            if let source = a.derivedFrom { links.insert(source) }
            names.insert(a.filename.lowercased())
        }
    }

    var isEmpty: Bool { links.isEmpty && batch.isEmpty }

    func contains(_ r: VideoRecord) -> Bool {
        if batch.contains(r.id) || links.contains(r.id) { return true }
        if let parent = r.derivedFrom, links.contains(parent) { return true }
        if let d = CatalogCommit.digest(of: r), digests.contains(d) { return true }
        return names.contains(r.filename.lowercased())
    }
}

/// R2–R5 for one working record, with every input captured ONCE per pass on
/// the main actor (the gate, the Archive backup marks, reachability).
@MainActor
struct PruneHoldRules {
    let model: VideoScanModel
    let gate: VideoScanModel.BulkDeleteGate
    let backup: ReadOnlyVolumeProtection
    let isOnline: (VideoRecord) -> Bool

    init(model: VideoScanModel, isOnline: @escaping (VideoRecord) -> Bool) {
        self.model = model
        gate = model.bulkDeleteGate(volume: model.archiveVolumeProtection())
        backup = model.archiveBackupProtection()
        self.isOnline = isOnline
    }

    /// nil = never listed: the gate refuses it AS the Master Archive.
    func snapshot(_ r: VideoRecord) -> PruneSnapshot? {
        let refusal = gate.refusal(for: model.bulkDeleteSubject(r))
        if refusal == .archiveTree || refusal == .archiveVolume { return nil }
        return PruneSnapshot(id: r.id, filename: r.filename, fullPath: r.fullPath, volumeName: r.volumeName,
                             sizeBytes: r.sizeBytes, digest: CatalogCommit.digest(of: r), derivedFrom: r.derivedFrom,
                             hold: hold(r, gateRefused: refusal != nil), attestations: r.backupAttestations)
    }

    func hold(_ r: VideoRecord, gateRefused: Bool) -> PruneReason? {
        if !isOnline(r) { return .driveOffline }
        if gateRefused || backup.verdict(forPath: r.fullPath) != nil { return .driveProtected }
        return CatalogScopePolicy.isPairProtected(r) ? .pairHalf : nil
    }
}
