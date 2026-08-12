// CatalogStorageTotals.swift
// The "TOTAL MEDIA" footer's arithmetic — two numbers for a storage-
// planning question Rick asked on 2026-08-09:
//
//     TOTAL MEDIA        7.3 TB        4.3 TB UNIQUE
//
//   * GROSS  — every byte this catalog knows about, on every volume,
//     retired insurance drives included (Rick's explicit call: the big
//     number is "what is actually sitting on my shelves", and the copies
//     on MyBook / RicksBackups / LACIE500 fall back out of the second
//     number via the duplicate collapse below).
//   * UNIQUE — the bytes of material we have POSITIVE reason to believe
//     is one-of-a-kind family audio/video. This is the number that
//     answers "how big a drive do I need to buy".
//
// WHY A WATERFALL, NOT TWO SUMS. Every excluded byte lands in exactly
// one of four buckets, and the buckets sum EXACTLY to gross - unique
// (pinned by CatalogStorageTotalsTests.waterfallIsExact). A number that
// can't show its work is a number Rick can't trust with a purchase
// decision, and a silent double-count would quietly shrink `unique`.
// Precedence is fixed and total:
//
//     1. non-video media  (stills, documents, no-A/V-stream files)
//     2. music library    (the iTunes sweep — MusicTriage's rule)
//     3. junk             (suspected or confirmed)
//     4. duplicate copies (extra copies of something counted already)
//     5. → UNIQUE
//
// Order matters: a duplicated junk JPEG must be counted once, and it is
// counted as non-video, not three times over.
//
// TWO DUPLICATE SIGNALS, UNIONED. Catalog-wide duplicate analysis is
// parked behind its beachball (GH #104), so leaning on
// `duplicateDisposition` alone would badly UNDER-count the copies on the
// insurance volumes and inflate `unique` — the exact direction of error
// that makes you buy too much disk. So we also collapse EXACT BYTE
// TWINS: same partial MD5 AND same byte length. Both signals are unioned
// and the keeper is elected once, so a record can never be charged to
// the duplicate bucket twice.
//
// HONESTY FIELD. `unanalyzedFiles` counts records carrying NEITHER dup
// signal (no partial MD5, never dup-analyzed). Those records can only
// ever have been scored as unique, so `uniqueBytes` is an UPPER BOUND
// and the footer says so when coverage is thin. Reporting a bound as if
// it were a measurement is the failure mode this field exists to
// prevent.
//
// COST. Two O(n) passes plus one dictionary group-by, no disk I/O, no
// media reads. Budgeted at 100k records by CatalogStorageTotalsTests
// (feature-test checklist dimension 2). Memory is one small String key
// per hashed record, freed on return.
//
// All functions `nonisolated` and pure — same testability contract as
// CatalogQueries.swift. (Swift `enum` with only static members ≈ a C++
// namespace: no instances, just a scoping shell for free functions.)

import Foundation

// MARK: - Result

/// The footer's two headline numbers plus the waterfall that explains
/// the gap between them. Value type, `Equatable` so SwiftUI can skip
/// redundant footer redraws.
struct CatalogStorageTotals: Equatable, Sendable {

    /// Every active byte on every volume. The big number.
    var grossBytes: Int64 = 0
    /// Bytes on volumes that are reachable RIGHT NOW.
    ///
    /// Added 2026-08-11 because the footer confused its own author: the
    /// volume table defaults to a Connected filter, so Rick added up the
    /// visible rows, got 4.9 TB against a 6.8 TB total, and reasonably
    /// asked which number was wrong. Neither was — the gap is the
    /// offline drives. This is the figure the eye can actually verify
    /// against the rows above it.
    var onlineBytes: Int64 = 0
    /// Bytes of material believed to be one-of-a-kind A/V. The
    /// parenthetical. An UPPER BOUND when `unanalyzedFiles > 0`.
    var uniqueBytes: Int64 = 0

    /// Distinct volumes contributing at least one active record.
    var volumeCount: Int = 0
    /// Active records counted into `grossBytes`.
    var fileCount: Int = 0
    /// Active records counted into `uniqueBytes`.
    var uniqueFileCount: Int = 0
    /// Active records on reachable volumes.
    var onlineFileCount: Int = 0

    // The waterfall. These four sum EXACTLY to grossBytes - uniqueBytes.
    var duplicateBytes: Int64 = 0
    var junkBytes: Int64 = 0
    var nonVideoBytes: Int64 = 0
    var musicBytes: Int64 = 0

    var duplicateFiles: Int = 0
    var junkFiles: Int = 0
    var nonVideoFiles: Int = 0
    var musicFiles: Int = 0

    /// Records with no duplicate evidence of any kind — neither a
    /// partial MD5 to twin on nor a completed dup analysis. They were
    /// necessarily scored unique, so this is the size of the doubt.
    var unanalyzedFiles: Int = 0

    /// True when every excluded byte is accounted for. The invariant the
    /// sensor test pins; also cheap enough to assert in debug UI code.
    var waterfallBalances: Bool {
        grossBytes - uniqueBytes
            == duplicateBytes + junkBytes + nonVideoBytes + musicBytes
    }

    /// Share of counted files that carry at least one duplicate signal.
    /// 1.0 = the unique number is as good as the catalog can make it;
    /// low values mean "hash more of the catalog before trusting this".
    var duplicateCoverage: Double {
        guard fileCount > 0 else { return 1.0 }
        return Double(fileCount - unanalyzedFiles) / Double(fileCount)
    }
}

// MARK: - Classification

/// Which bucket a single record falls into. Exhaustive and mutually
/// exclusive by construction — the compiler enforces total handling at
/// every use site, which is what keeps the waterfall balanced.
enum CatalogStorageBucket: Equatable, Sendable {
    case unique
    case duplicate
    case junk
    case nonVideo
    case music
}

enum CatalogStorageTotalsCalculator {

    // MARK: Non-video extensions

    /// Stills, raw photos, and documents that ffprobe happily reports as
    /// a one-frame `mjpeg`/`png` VIDEO stream. That trap is exactly why
    /// this bucket keys off EXTENSION rather than stream shape: a .cr3
    /// otherwise sails through as "video-only" and inflates the number
    /// Rick is about to buy a drive against.
    ///
    /// Deliberately NOT the inverse of
    /// `NonVideoMediaPurge.excludedVideoExtensions` — that set answers a
    /// different question ("what is definitely unsafe to offer for
    /// deletion"). An unknown extension here stays counted as media,
    /// because the app's whole recovery mission is extensionless and
    /// oddly-named Avid essence.
    static let stillImageExtensions: Set<String> = [
        // Consumer stills
        "jpg", "jpeg", "png", "gif", "bmp", "tif", "tiff", "heic", "heif",
        "webp", "psd", "ico",
        // Camera raw
        "cr2", "cr3", "nef", "arw", "dng", "orf", "raf", "rw2", "pef",
        "sr2", "srw", "x3f",
        // Documents / sidecars that can appear in a media tree
        "pdf", "txt", "rtf", "doc", "docx", "xls", "xlsx", "xmp", "thm",
        "log", "json", "xml", "plist",
    ]

    /// Positive test for "this record is not audio/video material".
    /// Two independent signals; either is sufficient.
    static func isNonVideoMedia(_ rec: VideoRecord) -> Bool {
        // ffprobe looked and found nothing playable at all.
        if rec.streamType == .noStreams { return true }
        // Or the extension says still/document regardless of what
        // ffprobe made of it (the one-frame-mjpeg trap above).
        return stillImageExtensions.contains(NonVideoMediaPurge.normalizedExtension(rec))
    }

    /// Junk per the triage workflow. Both suspected AND confirmed are
    /// subtracted: Rick's question is "what will I still be keeping",
    /// and suspected junk is material he has already eyeballed once and
    /// flagged. Counting it as unique would overstate the drive he needs.
    static func isJunk(_ rec: VideoRecord) -> Bool {
        rec.mediaDisposition == .suspectedJunk
            || rec.mediaDisposition == .confirmedJunk
    }

    /// The bucket for one record, given the two precomputed sets the
    /// caller builds in a single pass (`videoStemKeys` for the music
    /// veto, `duplicateIDs` for the collapsed copies). Both are
    /// parameters rather than recomputed here — that signature is what
    /// keeps this O(n) instead of O(n²).
    static func bucket(
        for rec: VideoRecord,
        videoStemKeys: Set<String>,
        duplicateIDs: Set<UUID>
    ) -> CatalogStorageBucket {
        // Precedence is fixed — see the file header. Each record lands
        // in exactly one bucket so the waterfall cannot double-count.
        if isNonVideoMedia(rec) { return .nonVideo }
        if MusicTriage.candidateVerdict(rec, videoStemKeys: videoStemKeys) { return .music }
        if isJunk(rec) { return .junk }
        if duplicateIDs.contains(rec.id) { return .duplicate }
        return .unique
    }

    // MARK: Duplicate collapse

    /// Elect one keeper per duplicate group and return the IDs of every
    /// OTHER member — the copies whose bytes we do not count twice.
    ///
    /// Unions two signals (see the file header): the dup analyzer's own
    /// `.extraCopy` disposition, and exact byte twins (same partial MD5
    /// AND same size). Records with an empty MD5 or zero size never twin
    /// — a shared empty hash would collapse unrelated files into one
    /// enormous bogus group and silently delete most of the catalog from
    /// the unique number.
    static func duplicateCopyIDs(in records: [VideoRecord]) -> Set<UUID> {
        var out = Set<UUID>()

        // Signal 1 — explicit analysis. `.review` is deliberately NOT
        // included: an unresolved maybe should inflate the number Rick
        // budgets against, not shrink it. Err toward buying enough disk.
        for rec in records where rec.duplicateDisposition == .extraCopy {
            out.insert(rec.id)
        }

        // Signal 2 — exact byte twins, keyed on hash AND length.
        var groups: [String: [VideoRecord]] = [:]
        groups.reserveCapacity(records.count / 2)
        for rec in records where !rec.partialMD5.isEmpty && rec.sizeBytes > 0 {
            groups["\(rec.partialMD5):\(rec.sizeBytes)", default: []].append(rec)
        }
        for (_, members) in groups where members.count > 1 {
            // Deterministic keeper: lowest full path. Any stable rule
            // gives the same TOTAL (twins are the same size by
            // definition) — determinism is for the tests, not the math.
            guard let keeper = members.min(by: { $0.fullPath < $1.fullPath }) else { continue }
            for m in members where m.id != keeper.id {
                out.insert(m.id)
            }
        }
        return out
    }

    /// True when a record carries any duplicate evidence at all. Its
    /// negation drives `unanalyzedFiles` — the honesty field.
    static func hasDuplicateEvidence(_ rec: VideoRecord) -> Bool {
        if !rec.partialMD5.isEmpty && rec.sizeBytes > 0 { return true }
        if rec.dupAnalyzedAt != nil { return true }
        return rec.duplicateGroupID != nil
    }

    // MARK: Entry point

    /// Compute both headline numbers and the full waterfall.
    ///
    /// Purged / set-aside / superseded records are dropped up front via
    /// `pfActiveRecords` — a file already in the Trash is not storage
    /// Rick has to plan for, and a set-aside row is hidden but not gone.
    ///
    /// MUST NOT be called from a SwiftUI view body: it is O(records).
    /// Callers cache the result and refresh it on catalog-change
    /// triggers (the VolumeStatusCache pattern).
    /// - Parameter onlineVolumes: names of volumes reachable right now,
    ///   derived by the CALLER from already-cached scan-target state.
    ///   Passed in rather than probed here so this stays a pure function
    ///   of its inputs — reachability is filesystem I/O, and it must
    ///   never run inside an O(records) loop. `nil` means "don't know",
    ///   which reports onlineBytes == grossBytes rather than zero: an
    ///   unknown reachability should not make the catalog look empty.
    static func compute(
        records: [VideoRecord],
        onlineVolumes: Set<String>? = nil
    ) -> CatalogStorageTotals {
        let active = pfActiveRecords(records)
        guard !active.isEmpty else { return CatalogStorageTotals() }

        // Precompute the two per-catalog sets ONCE (the O(n²) trap).
        let videoStemKeys = MusicTriage.videoStemKeys(in: active)
        let duplicateIDs = duplicateCopyIDs(in: active)

        var t = CatalogStorageTotals()
        var volumes = Set<String>()
        volumes.reserveCapacity(32)

        for rec in active {
            let bytes = max(0, rec.sizeBytes)   // a negative size is corrupt metadata, not a credit
            t.grossBytes += bytes
            t.fileCount += 1
            let volume = VolumeReachability.volumeName(forPath: rec.fullPath)
            volumes.insert(volume)

            // Online tally rides the SAME pass — a second walk just to
            // sum reachable bytes would double the cost of the footer.
            if onlineVolumes == nil || onlineVolumes!.contains(volume) {
                t.onlineBytes += bytes
                t.onlineFileCount += 1
            }

            if !hasDuplicateEvidence(rec) { t.unanalyzedFiles += 1 }

            switch bucket(for: rec, videoStemKeys: videoStemKeys, duplicateIDs: duplicateIDs) {
            case .unique:
                t.uniqueBytes += bytes
                t.uniqueFileCount += 1
            case .duplicate:
                t.duplicateBytes += bytes
                t.duplicateFiles += 1
            case .junk:
                t.junkBytes += bytes
                t.junkFiles += 1
            case .nonVideo:
                t.nonVideoBytes += bytes
                t.nonVideoFiles += 1
            case .music:
                t.musicBytes += bytes
                t.musicFiles += 1
            }
        }

        t.volumeCount = volumes.count
        return t
    }
}

// MARK: - Display formatting

extension CatalogStorageTotals {

    /// Rick's requested shape: "7.3 TB", "150 GB". Base-1024 to MATCH
    /// the per-volume Media Size column directly above the footer — a
    /// total that doesn't add up to the column it sits under reads as a
    /// bug even when both numbers are individually defensible.
    ///
    /// Three or more significant figures drop the decimal ("150 GB", not
    /// "150.4 GB") — spurious precision on a storage-planning figure.
    static func displaySize(_ bytes: Int64) -> String {
        let kb = 1024.0
        let mb = kb * 1024
        let gb = mb * 1024
        let tb = gb * 1024
        let v = Double(max(0, bytes))

        let (scaled, unit): (Double, String)
        switch v {
        case tb...:     (scaled, unit) = (v / tb, "TB")
        case gb..<tb:   (scaled, unit) = (v / gb, "GB")
        case mb..<gb:   (scaled, unit) = (v / mb, "MB")
        case kb..<mb:   (scaled, unit) = (v / kb, "KB")
        default:        return "0 GB"
        }
        return scaled >= 100
            ? String(format: "%.0f %@", scaled, unit)
            : String(format: "%.1f %@", scaled, unit)
    }

    var grossDisplay: String { Self.displaySize(grossBytes) }
    var onlineDisplay: String { Self.displaySize(onlineBytes) }
    var uniqueDisplay: String { Self.displaySize(uniqueBytes) }

    /// The parenthetical beside the unique figure.
    ///
    /// Names all FOUR removed categories explicitly. An earlier draft
    /// said "non AV, etc." — but music is audio, so "non AV" reads as
    /// though the music library were still counted, and on this catalog
    /// music is one of the largest subtractions. Hiding the biggest
    /// exclusion behind "etc." is how a planning number quietly lies.
    ///
    /// Degrades to an explicit caveat when duplicate coverage is thin:
    /// records with no partial MD5 can only ever have scored as unique,
    /// so the figure is then an upper bound, not a measurement.
    var uniqueCaption: String {
        let categories = "ignoring duplicates, junk, photos & music"
        if duplicateCoverage < 0.5 && fileCount > 0 {
            return "at most — \(categories)"
        }
        return categories
    }

    /// True when the unique figure is an upper bound rather than a
    /// measurement. Drives the footer's warning glyph.
    var uniqueIsUpperBound: Bool {
        duplicateCoverage < 0.5 && fileCount > 0
    }

    /// Full breakdown for the footer's tooltip. Plain text, one line per
    /// waterfall step, so the arithmetic is auditable at a glance.
    var breakdownTooltip: String {
        var lines: [String] = [
            "TOTAL MEDIA — \(fileCount) files across \(volumeCount) volume\(volumeCount == 1 ? "" : "s")",
            "",
            "In catalog (all volumes, retired included):  \(Self.displaySize(grossBytes))",
            "Online now (reachable volumes):              \(Self.displaySize(onlineBytes))",
            "Offline (drives not connected):              \(Self.displaySize(grossBytes - onlineBytes))",
            "",
            "Removed:",
            "  Duplicate copies  \(Self.displaySize(duplicateBytes))  (\(duplicateFiles) files)",
            "  Junk              \(Self.displaySize(junkBytes))  (\(junkFiles) files)",
            "  Photos & non-A/V  \(Self.displaySize(nonVideoBytes))  (\(nonVideoFiles) files)",
            "  Music library     \(Self.displaySize(musicBytes))  (\(musicFiles) files)",
            "",
            "Unique A/V material:  \(Self.displaySize(uniqueBytes))  (\(uniqueFileCount) files)",
        ]
        if unanalyzedFiles > 0 {
            let pct = Int((duplicateCoverage * 100).rounded())
            lines.append("")
            lines.append("Note: \(unanalyzedFiles) files carry no duplicate")
            lines.append("evidence yet (\(pct)% coverage), so the unique")
            lines.append("figure is an upper bound — run duplicate")
            lines.append("detection to tighten it.")
        }
        return lines.joined(separator: "\n")
    }
}
