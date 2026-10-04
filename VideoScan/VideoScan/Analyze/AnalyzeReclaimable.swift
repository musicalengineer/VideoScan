// AnalyzeReclaimable.swift
// The Storage tab's "Reclaimable" card arithmetic (Phase A trial,
// 2026-10-02; design §3.1): "N GB in M duplicate copies on this drive ·
// each has K+ verified copies elsewhere", plus how current the duplicate
// knowledge for that drive is.
//
// It is an ESTIMATE and says so. DeleteDuplicatesForecast is the real
// preview (keeper digest vs row digest, archive copies, hard links, plan
// order), and it needs the model on the main actor; the run itself decides
// every row from fresh stats and full reads. This card answers the
// Storage-tab glance — "how many dups do I have, can I clean some up?" —
// from the dup groups already on the records, off the main actor, cached,
// refreshed on catalog mutation (the VolumeDashboard pattern).
//
// What counts as a copy here: an `extraCopy` row on THIS volume whose
// group's elected keeper is on this same volume (the Delete flow's default
// scope), or — only when "Also clean up working copies" is ON — whose
// keeper is on another drive (the forecast and the picker apply the
// keeper-policy verdict on top of that; this card does not, so with the
// toggle ON the copy count is an upper bound).
//
// "Verified copies elsewhere" for a row = other group members whose drive
// is connected and that carry a usable stamp-bound fixity digest — the
// same evidence the tier counts (`DeletionTierFacts`), minus the digest
// comparison the run does. The survival rule it reports is quoted from
// `DeletionTierDecision` (DeleteDuplicatesPlan.swift), not paraphrased.
//
// MEMORY. One ReclaimableInput per active record (~64 bytes + path) and
// one small accumulator per dup group — ≈ 15 MB at 100k records, freed
// when the compute ends.
//
// (For Rick: a pure `enum` namespace of static functions; `inout` ≈ pass
// by non-const reference.)

import Foundation
import VideoScanCore

// MARK: - Input projection

struct ReclaimableInput: Sendable, Equatable {
    var fullPath: String
    var sizeBytes: Int64
    var isExtraCopy: Bool
    var isKeeper: Bool
    var groupID: UUID?
    /// `contentFixity` present and usable for verification.
    var hasUsableDigest: Bool
    var dupAnalyzedAt: Date?

    init(fullPath: String, sizeBytes: Int64 = 1, isExtraCopy: Bool = false, isKeeper: Bool = false,
         groupID: UUID? = nil, hasUsableDigest: Bool = false, dupAnalyzedAt: Date? = nil) {
        self.fullPath = fullPath
        self.sizeBytes = sizeBytes
        self.isExtraCopy = isExtraCopy
        self.isKeeper = isKeeper
        self.groupID = groupID
        self.hasUsableDigest = hasUsableDigest
        self.dupAnalyzedAt = dupAnalyzedAt
    }

    @MainActor
    init(record r: VideoRecord) {
        self.init(fullPath: r.fullPath,
                  sizeBytes: r.sizeBytes,
                  isExtraCopy: r.duplicateDisposition == .extraCopy,
                  isKeeper: r.duplicateDisposition == .keep,
                  groupID: r.duplicateGroupID,
                  hasUsableDigest: r.contentFixity?.isUsableForVerification ?? false,
                  dupAnalyzedAt: r.dupAnalyzedAt)
    }
}

// MARK: - Result

struct ReclaimableEstimate: Sendable, Equatable {
    /// Duplicate copies on this volume the Delete flow would consider.
    var copies = 0
    var bytes: Int64 = 0
    /// The fewest verified copies any of those rows has elsewhere (the
    /// "K+" in "each has K+ verified copies elsewhere"). nil when `copies == 0`.
    var verifiedFloor: Int?
    /// Rows with fewer than `DeletionTierDecision.minimumForTrash` verified
    /// copies elsewhere — the run would have to read their siblings first,
    /// or leave them alone.
    var copiesShortOfTwo = 0
    /// Rows whose group has members on drives not connected.
    var copiesWithOfflineSiblings = 0
    /// Records on this volume never checked for duplicates.
    var neverChecked = 0
    /// Newest duplicate check on this volume.
    var lastChecked: Date?
    /// Active records on this volume (the knowledge line's denominator).
    var volumeFiles = 0
    var computedAt: Date = Date(timeIntervalSince1970: 0)

    /// "412 GB in 1,208 duplicate copies on this drive"
    var headline: String {
        guard copies > 0 else { return "No duplicate copies to reclaim on this drive" }
        return "\(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)) in \(copies.formatted()) duplicate cop\(copies == 1 ? "y" : "ies") on this drive"
    }

    /// "each has 3+ verified copies elsewhere" / the honest shortfall.
    var copiesLine: String {
        guard copies > 0, let floor = verifiedFloor else { return "" }
        if copiesShortOfTwo == 0 {
            return "each has \(floor)+ verified cop\(floor == 1 ? "y" : "ies") elsewhere"
        }
        var s = "\(copiesShortOfTwo.formatted()) of them need other copies read first"
        if copiesWithOfflineSiblings > 0 { s += " · \(copiesWithOfflineSiblings.formatted()) have copies on drives not connected" }
        return s
    }

    /// "Duplicate knowledge: current" / "last checked 2 h ago" /
    /// "1,206 files never checked".
    func knowledgeLine(policyStale: Bool, now: Date = Date()) -> String {
        guard volumeFiles > 0 else { return "Duplicate knowledge: nothing catalogued here" }
        var parts: [String] = []
        if neverChecked == 0 && !policyStale {
            parts.append("current")
        }
        if let d = lastChecked {
            parts.append("last checked \(AnalyzeRowStateRule.relative(d, now: now))")
        }
        if neverChecked > 0 {
            parts.append("\(neverChecked.formatted()) file\(neverChecked == 1 ? "" : "s") never checked")
        }
        if policyStale {
            parts.append("keeper policy changed since the last check")
        }
        if parts.isEmpty { parts.append("never checked") }
        return "Duplicate knowledge: " + parts.joined(separator: " · ")
    }

    /// The rule, quoted from DeletionTierDecision (not paraphrased):
    /// ≥ 3 verified copies remaining on ≥ 2 drives (or with the archive
    /// copy among them) → permanent; ≥ 2 otherwise → the Trash; < 2 →
    /// left alone.
    static var survivalRule: String { DeletionTierDecision.ruleSentence }

    static let estimateNote = "Estimate from the catalog's duplicate groups — the Delete step shows the real forecast and the run proves every copy before it acts."
}

// MARK: - Calculator (pure)

enum ReclaimableCalculator {

    /// `leftAlone`: the Delete planner's own "this copy is left alone" rule
    /// (GH #258 — a copy the Archive Angel is using, a promoted
    /// copy; `VideoScanModel.duplicateDeletionHoldRule`). Such a row is
    /// projected as "not an extra copy": it can still be a counted sibling,
    /// but it is never counted as reclaimable — the run would not take it.
    @MainActor
    static func project(_ records: [VideoRecord],
                        leftAlone: (VideoRecord) -> Bool = { _ in false }) -> [ReclaimableInput] {
        var out: [ReclaimableInput] = []
        out.reserveCapacity(records.count)
        for r in records where !(r.isPurged || r.isSetAside || r.isSuperseded) {
            var input = ReclaimableInput(record: r)
            if input.isExtraCopy, leftAlone(r) { input.isExtraCopy = false }
            out.append(input)
        }
        return out
    }

    /// `/Volumes/X/…` → `/Volumes/X`; anything else → the given scan root
    /// when the path is under it, else the path's directory (mirrors
    /// `VideoScanModel.volumeRoot(for:)` closely enough for grouping).
    static func volumeRoot(of path: String, scanRoot: String) -> String {
        if path.hasPrefix("/Volumes/") {
            let name = path.dropFirst(9).prefix { $0 != "/" }
            return "/Volumes/" + name
        }
        if VolumeDashboardCalculator.isUnder(path, root: scanRoot) { return scanRoot }
        return (path as NSString).deletingLastPathComponent
    }

    /// `volumeRoot`: the drive the card describes (its scan target's
    /// search path, normalised). `mountedRoots`: the kernel mount table.
    static func compute(inputs: [ReclaimableInput],
                        volumeRoot rawRoot: String,
                        mountedRoots: Set<String>,
                        alsoCleanUpWorkingCopies: Bool,
                        now: Date = Date()) -> ReclaimableEstimate {
        var out = ReclaimableEstimate()
        out.computedAt = now
        let root = VolumeDashboardCalculator.normalizedRoot(rawRoot)
        // The drive this card describes, in the same spelling pass 1 gives
        // keepers ("/Volumes/X9" for external drives; the scan root itself
        // for an internal folder target).
        let hereRoot = root.hasPrefix("/Volumes/") ? volumeRoot(of: root, scanRoot: root) : root

        func online(_ path: String) -> Bool {
            guard path.hasPrefix("/Volumes/") else { return true }
            let name = path.dropFirst(9).prefix { $0 != "/" }
            return mountedRoots.contains("/Volumes/" + name)
        }

        // Pass 1: group facts — keeper's drive, verified/online members,
        // offline members. Keyed by group id.
        struct GroupAcc { var keeperRoot: String? ; var verifiedOnline = 0; var offline = 0 }
        var groups: [UUID: GroupAcc] = [:]
        for r in inputs {
            guard let g = r.groupID else { continue }
            var acc = groups[g] ?? GroupAcc()
            let isOnline = online(r.fullPath)
            if r.isKeeper { acc.keeperRoot = volumeRoot(of: r.fullPath, scanRoot: root) }
            if !isOnline { acc.offline += 1 }
            else if r.hasUsableDigest { acc.verifiedOnline += 1 }
            groups[g] = acc
        }

        // Pass 2: this volume's rows.
        var floor = Int.max
        for r in inputs where VolumeDashboardCalculator.isUnder(r.fullPath, root: root) {
            out.volumeFiles += 1
            if let d = r.dupAnalyzedAt {
                if out.lastChecked.map({ d > $0 }) ?? true { out.lastChecked = d }
            } else {
                out.neverChecked += 1
            }
            guard r.isExtraCopy, let g = r.groupID, let acc = groups[g], let keeperRoot = acc.keeperRoot else { continue }
            let sameDrive = keeperRoot == hereRoot
            guard sameDrive || alsoCleanUpWorkingCopies else { continue }
            out.copies += 1
            out.bytes += max(0, r.sizeBytes)
            // Verified copies ELSEWHERE: the group's verified online members
            // minus this row if it is one of them.
            let selfVerified = (online(r.fullPath) && r.hasUsableDigest) ? 1 : 0
            let verifiedElsewhere = max(0, acc.verifiedOnline - selfVerified)
            floor = min(floor, verifiedElsewhere)
            if verifiedElsewhere < DeletionTierDecision.minimumForTrash { out.copiesShortOfTwo += 1 }
            if acc.offline > 0 { out.copiesWithOfflineSiblings += 1 }
        }
        out.verifiedFloor = out.copies > 0 ? floor : nil
        return out
    }
}
