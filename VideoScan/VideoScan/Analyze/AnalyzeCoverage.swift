// AnalyzeCoverage.swift
// "x of y eligible · z%" for every cycler, from the stamps that exist
// TODAY (Phase A trial, 2026-10-02 — no new stamps, no engine changes):
//
//   Duplicates      dupAnalyzedAt
//   Footage         footage.scannedAt   — groups stamp only their MEMBERS,
//                                         a singleton has no stamp → the row
//                                         says "coverage unknown" honestly
//   Scene Captions  sceneCaptionDate / sceneCaptions (or the dossier pass
//                   stamp dossierProcessedAt — a pass that found no scene
//                   still ran)
//   OCR             no stamp of its own → dossierProcessedAt is the proxy;
//                   "n with text found" rides beside it
//   Transcribe      audioTranscriptDate / audioTranscript
//   Correlate       pairs + unpaired video-only / audio-only (no %)
//   Signatures      contentHash present (contentHashAt is nil on legacy rows)
//   Embedded Dates  embeddedCreationDate present — a file with no tag can
//                   never be "covered"; the row says so
//   Date Inference  inferredRecordDate present, over records with no user date
//
// DENOMINATOR = eligible AND reachable (design §5.5 revision): a record on
// a drive that is not connected is counted as "offline", a DRM / photo /
// out-of-scope / junk record as "not applicable", so 100% is reachable and
// means "everything I can see is current".
//
// Same contract as VolumeDashboard.swift: the view projects on the main
// actor (one pass, Sendable rows), this calculator runs in a detached task,
// the result is cached and read O(1) by every view body. Budgeted for 100k
// records (scale test: AnalyzeCoverageTests).
//
// MEMORY. One AnalyzeCoverageInput per active record: ~96 bytes of flags
// and dates plus the path string (~80 bytes average) ≈ 18 MB at 100k,
// freed when the compute ends. The report itself is a few hundred Ints.
//
// (For Rick: `nonisolated` + value types ≈ "no shared state, safe to run
// on any thread"; the `[String: Counts]` dictionaries ≈ std::unordered_map.)

import Foundation
import VideoScanCore

// MARK: - Input projection

/// The facts the coverage math needs from one record. Built on the main
/// actor (`VideoRecord` is main-actor bound), consumed off it.
struct AnalyzeCoverageInput: Sendable, Equatable {
    var fullPath: String
    var filename: String
    var streamTypeRaw: String
    var sizeBytes: Int64
    /// purged / set-aside / superseded — hidden cruft, out of every cycler.
    var isHidden: Bool
    /// lifecycleStage ∈ {cataloged, workbench} — the dossier pool's gate.
    var lifecycleOK: Bool
    var isJunk: Bool
    var drmProtected: Bool
    var dupStamped: Bool
    var footageScannedAt: Date?
    var dossierStamped: Bool
    var hasCaptions: Bool
    var hasOCRText: Bool
    var hasTranscript: Bool
    var isPaired: Bool
    var hasHash: Bool
    var hasEmbeddedDate: Bool
    var hasInferredDate: Bool
    var hasUserDate: Bool

    init(fullPath: String, filename: String = "", streamTypeRaw: String = StreamType.videoAndAudio.rawValue,
         sizeBytes: Int64 = 1, isHidden: Bool = false, lifecycleOK: Bool = true, isJunk: Bool = false,
         drmProtected: Bool = false, dupStamped: Bool = false, footageScannedAt: Date? = nil,
         dossierStamped: Bool = false, hasCaptions: Bool = false, hasOCRText: Bool = false,
         hasTranscript: Bool = false, isPaired: Bool = false, hasHash: Bool = false,
         hasEmbeddedDate: Bool = false, hasInferredDate: Bool = false, hasUserDate: Bool = false) {
        self.fullPath = fullPath
        self.filename = filename.isEmpty ? (fullPath as NSString).lastPathComponent : filename
        self.streamTypeRaw = streamTypeRaw
        self.sizeBytes = sizeBytes
        self.isHidden = isHidden
        self.lifecycleOK = lifecycleOK
        self.isJunk = isJunk
        self.drmProtected = drmProtected
        self.dupStamped = dupStamped
        self.footageScannedAt = footageScannedAt
        self.dossierStamped = dossierStamped
        self.hasCaptions = hasCaptions
        self.hasOCRText = hasOCRText
        self.hasTranscript = hasTranscript
        self.isPaired = isPaired
        self.hasHash = hasHash
        self.hasEmbeddedDate = hasEmbeddedDate
        self.hasInferredDate = hasInferredDate
        self.hasUserDate = hasUserDate
    }

    /// Project one live record. Main actor (the record lives there).
    @MainActor
    init(record r: VideoRecord) {
        self.init(fullPath: r.fullPath,
                  filename: r.filename,
                  streamTypeRaw: r.streamTypeRaw,
                  sizeBytes: r.sizeBytes,
                  isHidden: r.isPurged || r.isSetAside || r.isSuperseded,
                  lifecycleOK: r.lifecycleStage == .cataloged || r.lifecycleStage == .workbench,
                  isJunk: r.mediaDisposition == .confirmedJunk,
                  drmProtected: r.drmProtected,
                  dupStamped: r.dupAnalyzedAt != nil,
                  footageScannedAt: r.footage?.scannedAt,
                  dossierStamped: r.dossierProcessedAt != nil,
                  hasCaptions: r.sceneCaptionDate != nil || !r.sceneCaptions.isEmpty,
                  hasOCRText: !r.ocrText.isEmpty || !r.ocrDateCandidates.isEmpty,
                  hasTranscript: r.audioTranscriptDate != nil || !(r.audioTranscript ?? "").isEmpty,
                  isPaired: r.pairedWith != nil,
                  hasHash: !r.contentHash.isEmpty,
                  hasEmbeddedDate: r.embeddedCreationDate != nil,
                  hasInferredDate: r.inferredRecordDate != nil,
                  hasUserDate: !(r.userDate ?? "").isEmpty)
    }
}

/// Where each catalogued volume stands: its scan-target root and whether
/// it is connected right now. Built on the main actor from `scanTargets`.
struct AnalyzeVolumeFact: Sendable, Equatable, Hashable {
    var root: String
    var isReachable: Bool
    var isRetired: Bool
}

// MARK: - Result

/// Coverage for one cycler, catalog-wide or on one volume.
struct AnalyzeCoverageCounts: Sendable, Equatable {
    /// Eligible and on a connected drive — the denominator.
    var eligible = 0
    /// Of `eligible`, stamped/current.
    var covered = 0
    /// Eligible, but on a drive that is not connected.
    var offline = 0
    /// Active records this cycler does not apply to (DRM, photos, out of
    /// scope, junk, zero-byte, no video stream, …).
    var notApplicable = 0
    /// Newest stamp seen (any volume) — "last checked …".
    var newestStamp: Date?
    /// A secondary tally the row mentions ("n with text found", "n grouped").
    var secondary = 0

    var remaining: Int { max(0, eligible - covered) }
    var percent: Double { eligible > 0 ? Double(covered) / Double(eligible) * 100 : 100 }

    /// Count one record into the right bucket (and remember the newest
    /// stamp / the secondary tally).
    mutating func record(applies: Bool, reachable: Bool, covered: Bool, stamp: Date?, secondary: Bool) {
        if !applies {
            notApplicable += 1
        } else if !reachable {
            offline += 1
        } else {
            eligible += 1
            if covered { self.covered += 1 }
        }
        if secondary { self.secondary += 1 }
        if let stamp, newestStamp.map({ stamp > $0 }) ?? true { newestStamp = stamp }
    }

    /// "1,204 of 1,513 eligible · 80%"
    var line: String {
        guard eligible > 0 else { return "nothing eligible" }
        return "\(covered.formatted()) of \(eligible.formatted()) eligible · \(Self.percentText(percent))"
    }

    /// "12 offline · 3 not applicable" (empty when both are zero).
    var sideLine: String {
        var parts: [String] = []
        if offline > 0 { parts.append("\(offline.formatted()) offline") }
        if notApplicable > 0 { parts.append("\(notApplicable.formatted()) not applicable") }
        return parts.joined(separator: " · ")
    }

    static func percentText(_ p: Double) -> String {
        if p >= 100 { return "100%" }
        if p > 99 { return ">99%" }
        if p > 0 && p < 1 { return "<1%" }
        return String(format: "%.0f%%", p)
    }
}

/// Correlate is counted differently: pairs and the unpaired candidates.
struct AnalyzeCorrelateCounts: Sendable, Equatable {
    var pairs = 0
    var unpairedVideoOnly = 0
    var unpairedAudioOnly = 0
    var offlineCandidates = 0

    var unpaired: Int { unpairedVideoOnly + unpairedAudioOnly }

    /// "412 pairs · 13 video-only + 9 audio-only unpaired"
    var line: String {
        var s = "\(pairs.formatted()) pair\(pairs == 1 ? "" : "s")"
        if unpaired > 0 {
            s += " · \(unpairedVideoOnly.formatted()) video-only + \(unpairedAudioOnly.formatted()) audio-only unpaired"
        } else {
            s += " · nothing unpaired"
        }
        return s
    }
}

/// Everything the panel and the toolbar menu read. O(1) reads.
struct AnalyzeCoverageReport: Sendable, Equatable {
    var byCycler: [AnalyzeCycler: AnalyzeCoverageCounts] = [:]
    /// Per-volume breakdown for the cyclers with a volume scope, keyed by
    /// scan-target root; records under no known root fall under
    /// `AnalyzeCoverageCalculator.otherRoot`.
    var byVolume: [AnalyzeCycler: [String: AnalyzeCoverageCounts]] = [:]
    var correlate = AnalyzeCorrelateCounts()
    /// Active (non-hidden) records seen.
    var activeRecords = 0
    var computedAt: Date = Date(timeIntervalSince1970: 0)

    /// Cyclers whose per-record stamp does not exist today, so the
    /// "x of y" line would be a guess. Footage (singletons carry nothing).
    static let coverageUnknown: Set<AnalyzeCycler> = [.footage]

    func counts(_ c: AnalyzeCycler) -> AnalyzeCoverageCounts { byCycler[c] ?? AnalyzeCoverageCounts() }

    /// Whether "x of y eligible · z%" is meaningful for this cycler.
    func coverageKnown(_ c: AnalyzeCycler) -> Bool { !Self.coverageUnknown.contains(c) }

    /// One-line summary for the toolbar menu row.
    func menuSummary(_ c: AnalyzeCycler, now: Date = Date()) -> String {
        if c == .correlate { return correlate.line }
        let k = counts(c)
        if !coverageKnown(c) {
            var s = "\(k.secondary.formatted()) grouped"
            if let d = k.newestStamp { s += " · last run \(AnalyzeRowStateRule.relative(d, now: now))" }
            return s
        }
        if k.eligible == 0 { return "nothing eligible" }
        if k.remaining == 0 { return "current · \(k.covered.formatted()) of \(k.eligible.formatted())" }
        return "\(AnalyzeCoverageCounts.percentText(k.percent)) · \(k.remaining.formatted()) to go"
    }
}

// MARK: - Calculator (pure)

enum AnalyzeCoverageCalculator {

    static let otherRoot = "(other)"

    // MARK: Projection (main actor side)

    /// One pass over the live records → Sendable rows. Hidden records
    /// (purged / set-aside / superseded) are dropped here; nothing else is.
    @MainActor
    static func project(_ records: [VideoRecord]) -> [AnalyzeCoverageInput] {
        var out: [AnalyzeCoverageInput] = []
        out.reserveCapacity(records.count)
        for r in records where !(r.isPurged || r.isSetAside || r.isSuperseded) {
            out.append(AnalyzeCoverageInput(record: r))
        }
        return out
    }

    @MainActor
    static func volumeFacts(_ targets: [CatalogScanTarget]) -> [AnalyzeVolumeFact] {
        targets.compactMap { t in
            let root = VolumeDashboardCalculator.normalizedRoot(t.searchPath)
            guard !root.isEmpty else { return nil }
            return AnalyzeVolumeFact(root: root, isReachable: t.isReachable, isRetired: t.isRetired)
        }
    }

    // MARK: Entry point

    /// `volumes`: every scan target's root + reachability. `mountedRoots`:
    /// the kernel mount table (for records under no scan target — a
    /// `/Volumes/X` path is reachable iff X is mounted; anything else is
    /// treated as reachable, like `VolumeReachability` does for internal
    /// paths without a stat). `scope`: the dossier Analysis Scope.
    static func compute(inputs: [AnalyzeCoverageInput],
                        volumes: [AnalyzeVolumeFact],
                        mountedRoots: Set<String>,
                        scope: AnalysisScope,
                        now: Date = Date()) -> AnalyzeCoverageReport {
        var report = AnalyzeCoverageReport()
        report.computedAt = now
        report.activeRecords = inputs.count

        // Longest root first so "/Volumes/X9" never claims "/Volumes/X9-Matt"
        // (component-wise test) and a nested target wins over its parent.
        let roots = volumes.sorted { $0.root.count > $1.root.count }
        var reachableByRoot: [String: Bool] = [:]
        for v in roots { reachableByRoot[v.root] = v.isReachable && !v.isRetired }

        func rootAndReachability(_ path: String) -> (root: String, reachable: Bool) {
            for v in roots where VolumeDashboardCalculator.isUnder(path, root: v.root) {
                return (v.root, reachableByRoot[v.root] ?? false)
            }
            if path.hasPrefix("/Volumes/") {
                let name = path.dropFirst(9).prefix { $0 != "/" }
                return (otherRoot, mountedRoots.contains("/Volumes/" + name))
            }
            return (otherRoot, true)
        }

        var by: [AnalyzeCycler: AnalyzeCoverageCounts] = [:]
        var byVol: [AnalyzeCycler: [String: AnalyzeCoverageCounts]] = [:]
        for c in AnalyzeCycler.allCases { by[c] = AnalyzeCoverageCounts() }
        for c in AnalyzeCycler.allCases where c.hasVolumeScope { byVol[c] = [:] }
        var corr = AnalyzeCorrelateCounts()
        var pairedRecords = 0

        /// Tally one record for one cycler — catalog-wide and, where the
        /// cycler has a volume scope, for its volume. `applies` = the cycler
        /// is meant for this record at all; `covered` = its stamp is present.
        func tally(_ c: AnalyzeCycler, root: String, reachable: Bool,
                   applies: Bool, covered: Bool, stamp: Date? = nil, secondary: Bool = false) {
            by[c, default: AnalyzeCoverageCounts()]
                .record(applies: applies, reachable: reachable, covered: covered, stamp: stamp, secondary: secondary)
            // Optional-chained subscript write: a no-op for cyclers with no
            // per-volume table (≈ `if (p) p->at(root).record(…)`).
            byVol[c]?[root, default: AnalyzeCoverageCounts()]
                .record(applies: applies, reachable: reachable, covered: covered, stamp: stamp, secondary: secondary)
        }

        for r in inputs {
            if r.isHidden { continue }
            let (root, reachable) = rootAndReachability(r.fullPath)
            let stream = StreamType(rawValue: r.streamTypeRaw) ?? .ffprobeFailed
            let classification = AnalysisScope.classify(streamTypeRaw: r.streamTypeRaw, filename: r.filename)
            let inScope = scope.includes(streamTypeRaw: r.streamTypeRaw, filename: r.filename)
            let hasVideo = stream == .videoAndAudio || stream == .videoOnly
            let hasAudio = stream == .videoAndAudio || stream == .audioOnly

            // Duplicates: every active record is a candidate.
            tally(.duplicates, root: root, reachable: reachable, applies: true, covered: r.dupStamped)

            // Footage: only MEMBERS carry a stamp — tracked as `secondary`
            // (grouped) plus the newest run; `eligible`/`covered` are still
            // tallied so the per-volume disclosure can show "n grouped of m".
            tally(.footage, root: root, reachable: reachable, applies: true,
                  covered: r.footageScannedAt != nil, stamp: r.footageScannedAt,
                  secondary: r.footageScannedAt != nil)

            // Dossier pool: lifecycle + not junk + not DRM + in scope + not a photo.
            let dossierApplies = r.lifecycleOK && !r.isJunk && !r.drmProtected && inScope
            let isPhoto: Bool = { if case .photo = classification { return true }; return false }()
            tally(.sceneCaptions, root: root, reachable: reachable,
                  applies: dossierApplies && !isPhoto && hasVideo,
                  covered: r.hasCaptions || r.dossierStamped)
            tally(.ocr, root: root, reachable: reachable,
                  applies: dossierApplies && !isPhoto && hasVideo,
                  covered: r.dossierStamped, secondary: r.hasOCRText)
            tally(.transcribe, root: root, reachable: reachable,
                  applies: dossierApplies && !isPhoto && hasAudio,
                  covered: r.hasTranscript)

            // Correlate: pairs and the unpaired A/V-only candidates.
            if r.isPaired { pairedRecords += 1 }
            if stream.needsCorrelation && !r.isPaired {
                if !reachable { corr.offlineCandidates += 1 }
                else if stream == .videoOnly { corr.unpairedVideoOnly += 1 }
                else { corr.unpairedAudioOnly += 1 }
            }

            // Signatures: anything with bytes.
            tally(.fileSignatures, root: root, reachable: reachable,
                  applies: r.sizeBytes > 0 && !r.fullPath.isEmpty, covered: r.hasHash)

            // Embedded dates: ffprobe-failed rows can't be probed.
            tally(.embeddedDates, root: root, reachable: reachable,
                  applies: stream != .ffprobeFailed && !r.fullPath.isEmpty, covered: r.hasEmbeddedDate)

            // Date inference: metadata only — reachability is irrelevant,
            // so every applicable record counts as reachable here.
            tally(.dateInference, root: root, reachable: true,
                  applies: !r.hasUserDate, covered: r.hasInferredDate)
        }
        corr.pairs = pairedRecords / 2
        report.byCycler = by
        report.byVolume = byVol
        report.correlate = corr
        return report
    }
}
