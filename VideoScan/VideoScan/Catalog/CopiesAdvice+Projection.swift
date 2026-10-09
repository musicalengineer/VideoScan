// CopiesAdvice+Projection.swift
// The main-actor half of "Copies & Advice…" (CopiesAdvice.swift has the
// pure half): read ONE record and its groups out of the live catalog into
// Sendable values, then hand them to the off-main assessor.
//
// COST. Called from the card's `.task` (never a view body, never a menu
// builder). One pass over `records` compares two group ids per record —
// the duplicate engine's `duplicateGroupID` and Find Similar Footage's
// `footage.groupID` — because the catalog keeps no group → members index
// (the inspector and FootageGroupSheet make the same pass). No strings, no
// stats on main. Everything after the pass is O(group): election keys
// (DuplicateKeeperPolicy), the archive link (`archivedCopy(of:)`, an index
// lookup), the steward's live cases (O(cases)). The 100k-record budget is
// pinned by CopiesAdviceScaleTests.
//
// (For Rick: `@MainActor` ≈ "touches UI-thread state; run it there". The
// records are reference objects owned by the UI thread, so they are copied
// into plain values here before anything leaves it.)

import Foundation
import VideoScanCore

extension CopiesAdviceInput {

    /// The card's input for `rec`.
    @MainActor
    static func project(_ rec: VideoRecord, model: VideoScanModel) -> CopiesAdviceInput {
        let groups = CopiesAdviceGroups.collect(for: rec, in: model.records)
        var others = groups.duplicates
        if let link = archiveLink(of: rec, model: model), link !== rec, !others.contains(where: { $0 === link }) {
            others.append(link)
        }
        let policy = model.duplicateKeeperPolicy()
        return CopiesAdviceInput(
            header: header(rec),
            this: candidate(rec, policy: policy, model: model),
            others: others.map { candidate($0, policy: policy, model: model) },
            footage: groups.footage.map(footageMember),
            hold: hold(rec, model: model),
            duplicates: duplicateFreshness(rec, model: model),
            footageFreshness: footageFreshness(rec, model: model),
            flagged: CopiesAdviceWhy.lines(flagFacts(rec, model: model)))
    }

    // MARK: Pieces

    /// The archive copy holding this file's content (promote link, digest
    /// index, or hash-backed group — the model's ONE answer), or, for an
    /// archive copy, the file it was promoted from.
    @MainActor
    static func archiveLink(of rec: VideoRecord, model: VideoScanModel) -> VideoRecord? {
        model.isArchiveCopy(rec) ? model.promotionSource(of: rec) : model.archivedCopy(of: rec)
    }

    @MainActor
    static func candidate(_ r: VideoRecord, policy: DuplicateKeeperPolicy,
                          model: VideoScanModel) -> CopiesAdviceCandidate {
        let inArchive = model.isArchiveElement(r)
        return CopiesAdviceCandidate(
            id: r.id, filename: r.filename, fullPath: r.fullPath,
            volume: VolumeReachability.volumeName(forPath: r.fullPath), sizeBytes: r.sizeBytes,
            isArchiveCopy: inArchive,
            archiveDigest: inArchive ? ArchivePromotionIndex.verifiedDigest(of: r) : nil,
            archiveCheckedAt: inArchive ? r.archiveFixity?.verifiedAt : nil,
            contentFixity: r.contentFixity, contentHash: r.contentHash, partialMD5: r.partialMD5,
            electionKey: policy.electionKey(for: r, technicalScore: DuplicateDetector.keeperScore(r)))
    }

    @MainActor
    static func header(_ r: VideoRecord) -> Header {
        let size = r.sizeBytes > 0 ? ByteCountFormatter.string(fromByteCount: r.sizeBytes, countStyle: .file) : r.size
        return Header(filename: r.filename, size: size, codec: r.videoCodec.uppercased(),
                      duration: r.duration.isEmpty ? durationText(r.durationSeconds) : r.duration)
    }

    nonisolated static func durationText(_ seconds: Double) -> String {
        guard seconds > 0 else { return "" }
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    @MainActor
    static func footageMember(_ r: VideoRecord) -> CopiesAdviceFootageMember {
        let f = r.footage
        let facts = [r.videoCodec.uppercased(), durationText(r.durationSeconds), f?.confidence.label ?? ""]
            .filter { !$0.isEmpty }.joined(separator: " · ")
        let evidence = f?.evidence.first.map { " — \($0)" } ?? ""
        return CopiesAdviceFootageMember(id: r.id, filename: r.filename, fullPath: r.fullPath,
                                         role: f?.role.label ?? "related", detail: facts + evidence)
    }

    /// Why the ⌘⌫ routine would leave this file alone — the same two gates
    /// it asks (the bulk-delete refusal, the A/V pair rule), worded.
    @MainActor
    static func hold(_ rec: VideoRecord, model: VideoScanModel) -> String? {
        let archiveVolume = model.archiveVolumeProtection()
        if let refusal = model.bulkDeleteRefusal(rec, volume: archiveVolume) {
            return VideoScanModel.bulkDeleteRefusalNote(refusal, volume: archiveVolume?.label ?? "the archive volume")
        }
        if CatalogScopePolicy.isPairProtected(rec) {
            return "is half of a recovered audio/video pair, which Combine still needs"
        }
        return nil
    }

    @MainActor
    static func duplicateFreshness(_ rec: VideoRecord, model: VideoScanModel) -> CopiesFreshness {
        guard let at = rec.dupAnalyzedAt else { return .notComputed }
        return model.isDuplicateKeeperPolicyStale ? .outOfDate(at) : .asOf(at)
    }

    /// The file's own grouping stamp; with none, the last automatic run
    /// (it looked and found nothing); with neither, not computed.
    @MainActor
    static func footageFreshness(_ rec: VideoRecord, model: VideoScanModel) -> CopiesFreshness {
        if let at = rec.footage?.scannedAt { return .asOf(at) }
        if let at = model.archiveAngel.lastFootageAutoRunAt { return .asOf(at) }
        return .notComputed
    }

    @MainActor
    static func flagFacts(_ rec: VideoRecord, model: VideoScanModel) -> CopiesFlagFacts {
        let id = rec.id
        let steward = model.stewardSnapshot.queue.cases
            .filter { c in c.recordIDs.contains(id) || c.copies.contains { $0.id == id } }
            .map { "Tidy suggestions: \($0.kind.chip) — \($0.title)" }
        return CopiesFlagFacts(disposition: rec.mediaDisposition, junkReasons: rec.junkReasons,
                               duplicateDisposition: rec.duplicateDisposition,
                               duplicateReasons: rec.duplicateReasons,
                               duplicateBestMatch: rec.duplicateBestMatchFilename,
                               duplicateCheckedAt: rec.dupAnalyzedAt, stewardLines: steward)
    }
}

// MARK: - The one pass

/// The records that share this file's duplicate group and footage group.
/// Removed (purged) and set-aside records are not copies anyone can keep.
enum CopiesAdviceGroups {
    struct Members {
        var duplicates: [VideoRecord] = []
        /// Likely original first (FootageMembership.rank), then path.
        var footage: [VideoRecord] = []
    }

    /// ONE pass, two UUID compares per record. O(records) time, O(group)
    /// memory.
    @MainActor
    static func collect(for rec: VideoRecord, in records: [VideoRecord]) -> Members {
        let dup = rec.duplicateGroupID
        let foot = rec.footage?.groupID
        var out = Members()
        guard dup != nil || foot != nil else { return out }
        for r in records where r !== rec {
            let inDup = dup != nil && r.duplicateGroupID == dup
            let inFoot = foot != nil && r.footage?.groupID == foot
            guard inDup || inFoot, !r.isPurged, !r.isSetAside else { continue }
            if inDup { out.duplicates.append(r) }
            if inFoot { out.footage.append(r) }
        }
        out.footage.sort { ($0.footage?.rank ?? .max, $0.fullPath) < ($1.footage?.rank ?? .max, $1.fullPath) }
        return out
    }
}

// MARK: - Loading (the card's .task)

enum CopiesAdviceLoader {
    /// Project on main, decide off main. nil when the record is gone.
    @MainActor
    static func load(recordID: UUID, model: VideoScanModel) async -> CopiesAdvice? {
        guard let rec = model.record(forID: recordID) else { return nil }
        let input = CopiesAdviceInput.project(rec, model: model)
        return await CopiesAdviceAssessor.assessOffMain(input)
    }
}
