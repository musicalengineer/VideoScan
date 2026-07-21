import Foundation

// MARK: - Non-Video Media Purge — unified classification (catalog maintenance, 2026-07-21)
//
// The composition layer behind the single "Purge Non-Video Media…" dialog
// that REPLACES the two separate purge commands (cover-art music, unrelated
// audio). This file adds NO new purge logic — it REUSES the two existing,
// QA-approved candidate predicates and organizes their results by CATEGORY
// and by VOLUME so the dialog can offer live per-category / per-volume
// counts and a top-locations breakdown without re-walking the catalog on
// every checkbox toggle.
//
//   • CoverArtMusicPurge.isCandidate      → category .coverArt
//     (audio mis-tagged as video via embedded cover art; video-tagged)
//   • UnrelatedAudioPurge.isCandidate     → category .unrelatedAudio
//     (audio-only unrelated to any video; KEEPS curated pairs + essence)
//
// The two categories are DISJOINT by construction: cover-art candidates are
// video-tagged (streamType videoAndAudio/videoOnly), unrelated-audio
// candidates are audioOnly — no record can satisfy both. So the per-record
// category is a clean 3-way {coverArt, unrelatedAudio, none}.
//
// EFFICIENT INTERACTIVE RECOMPUTE. `classify(records:)` does ONE O(N) pass:
// for each record it computes (category, volumeKey) and folds it into a
// small (category × volume) matrix of Cells. Each Cell carries the record
// IDs (the removal key set) and a per-parent-directory tally (for the
// top-locations breakdown). Toggling category / volume selections in the
// dialog is then pure arithmetic over the matrix cells — sum a few Ints,
// union a few small ID sets — never another pass over the ~100k records.
// The O(N) pass runs ONCE (on the sheet's .onAppear / a model call), off the
// SwiftUI view body, per the no-O(records)-work-in-a-view-body rule.
//
// EMPTY-ANCHOR FAIL-SAFE. The unrelated-audio predicate is only meaningful
// when the catalog has video/essence anchors to relate audio against; with
// NO anchors EVERY audio-only record would look "unrelated" and the purge
// must remove nothing (a catalog scanned before its video volumes were
// online). We honor that here by NEVER classifying a record as
// .unrelatedAudio when `hasVideoAnchors` is false — so the category's count
// is 0 and its ID set is empty, exactly matching UnrelatedAudioPurge's own
// `guard !sets.isEmpty` behavior. `hasVideoAnchors` is surfaced so the dialog
// and the model purge can also refuse explicitly.
//
// VOLUME DERIVATION. A record's volume key is `VolumeReachability
// .volumeName(forPath:)` — the SAME pure path-string derivation the
// Volumes/Archive view labels rows with ("/Volumes/<name>/…" → "<name>";
// "/Users/<name>/…" → "<name>"; other paths bucket to their top-level
// component). Pure, no disk I/O, so it is safe inside the O(N) pass and
// deterministic for tests.
//
// MEMORY. Worst case the Cell ID arrays together hold one UUID per candidate
// record — bounded by the catalog size (~100k → ~1.6 MB of UUIDs). The
// per-directory tallies are bounded by the number of DISTINCT parent
// directories among candidates (far smaller). Three video-side Set<String>
// (~16k anchors) are built once by UnrelatedAudioPurge.videoSets. No media
// bytes are ever read. A few MB total, negligible against `records` itself.
//
// (Swift `enum` with only static members ≈ a C++ namespace — no instances,
// just a scoping shell for free functions.)

/// The two purgeable non-video categories the dialog composes. Raw String
/// so selections can round-trip through logs / defaults if ever needed.
/// (Swift `enum: String, CaseIterable` ≈ a C++ scoped enum plus a compiler-
/// generated `allCases` array.)
enum NonVideoCategory: String, CaseIterable, Hashable, Identifiable {
    case coverArt
    case unrelatedAudio

    var id: String { rawValue }

    /// Human label for the dialog's checkbox.
    var label: String {
        switch self {
        case .coverArt:       return "Cover-art music"
        case .unrelatedAudio: return "Unrelated audio / sample libraries"
        }
    }
}

enum NonVideoMediaPurge {

    /// One parent directory and how many candidates live under it, for the
    /// dialog's top-locations breakdown. Mirrors UnrelatedAudioPurge.TreeCount.
    struct TreeCount: Identifiable {
        let path: String
        let count: Int
        var id: String { path }
    }

    /// A single (category × volume) matrix cell: the candidate record IDs in
    /// that cell plus a per-parent-directory tally for the breakdown.
    struct Cell {
        var ids: [UUID] = []
        var dirCounts: [String: Int] = [:]
        var count: Int { ids.count }
    }

    /// The result of the ONE O(N) classification pass. All the dialog's
    /// interactive numbers are derived from this by cheap cell arithmetic —
    /// no further catalog walks.
    struct Classification {
        /// matrix[category][volumeKey] → Cell. Absent keys mean an empty cell.
        let matrix: [NonVideoCategory: [String: Cell]]
        /// Every volume key that has ANY candidate in ANY category, sorted
        /// case-insensitively for a stable dialog list.
        let volumeKeys: [String]
        /// True iff the catalog has at least one video/essence anchor. When
        /// false, `.unrelatedAudio` is never populated (empty-anchor fail-safe).
        let hasVideoAnchors: Bool
        /// Count of relationship anchors (video-bearing + recovered essence).
        let anchorCount: Int

        // MARK: Interactive queries (pure cell arithmetic, no records walk)

        /// Candidates in one category across the given volumes — the number
        /// shown next to a CATEGORY checkbox for the currently-selected volumes.
        func categoryCount(_ category: NonVideoCategory,
                           volumeKeys keys: Set<String>) -> Int {
            guard let byVolume = matrix[category] else { return 0 }
            var n = 0
            for k in keys { n += byVolume[k]?.count ?? 0 }
            return n
        }

        /// Candidates on one volume across the given categories — the number
        /// shown next to a VOLUME checkbox for the currently-selected categories.
        func volumeCount(_ volumeKey: String,
                         categories: Set<NonVideoCategory>) -> Int {
            var n = 0
            for c in categories { n += matrix[c]?[volumeKey]?.count ?? 0 }
            return n
        }

        /// Grand total across the selected categories × volumes — the live
        /// "Purge N records" number.
        func totalCount(categories: Set<NonVideoCategory>,
                        volumeKeys keys: Set<String>) -> Int {
            var n = 0
            for c in categories {
                guard let byVolume = matrix[c] else { continue }
                for k in keys { n += byVolume[k]?.count ?? 0 }
            }
            return n
        }

        /// The exact removal key set for the selected categories × volumes.
        /// Union of the relevant cells' ID arrays — O(selected candidates),
        /// never O(catalog).
        func candidateIDs(categories: Set<NonVideoCategory>,
                          volumeKeys keys: Set<String>) -> Set<UUID> {
            var ids = Set<UUID>()
            for c in categories {
                guard let byVolume = matrix[c] else { continue }
                for k in keys {
                    if let cell = byVolume[k] { ids.formUnion(cell.ids) }
                }
            }
            return ids
        }

        /// Top parent directories among the selected categories × volumes,
        /// highest count first. Merges only the selected cells' per-directory
        /// tallies — iterates DISTINCT directories in-selection, not records.
        /// Also returns the grand total so the dialog can render "…and N more".
        func topLocations(categories: Set<NonVideoCategory>,
                          volumeKeys keys: Set<String>,
                          topN: Int = 6) -> (trees: [TreeCount], total: Int) {
            var perDir: [String: Int] = [:]
            var total = 0
            for c in categories {
                guard let byVolume = matrix[c] else { continue }
                for k in keys {
                    guard let cell = byVolume[k] else { continue }
                    total += cell.count
                    for (dir, n) in cell.dirCounts {
                        perDir[dir, default: 0] += n
                    }
                }
            }
            let top = perDir
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(topN)
                .map { TreeCount(path: $0.key, count: $0.value) }
            return (Array(top), total)
        }
    }

    // MARK: - The single O(N) classification pass

    /// Volume key for a record's full path — the SAME pure derivation the
    /// Volumes/Archive view uses for labels. No disk I/O.
    static func volumeKey(forFullPath fullPath: String) -> String {
        VolumeReachability.volumeName(forPath: fullPath)
    }

    /// The 3-way category for a record given the precomputed video sets and
    /// whether the catalog has anchors. Reuses BOTH existing predicates; adds
    /// no new purge logic. Returns nil for "keep" (not a candidate).
    static func category(for record: VideoRecord,
                         videoSets sets: UnrelatedAudioPurge.VideoSets,
                         hasVideoAnchors: Bool) -> NonVideoCategory? {
        // Cover-art music: video-tagged audio (mjpeg/png cover art). Disjoint
        // from unrelated-audio (which is audioOnly), so test it first.
        if CoverArtMusicPurge.isCandidate(record) { return .coverArt }
        // Unrelated audio-only — only meaningful with anchors present. Without
        // anchors we classify NOTHING here (empty-anchor fail-safe), matching
        // UnrelatedAudioPurge.candidates' own guard.
        if hasVideoAnchors,
           UnrelatedAudioPurge.isCandidate(record, videoSets: sets) {
            return .unrelatedAudio
        }
        return nil
    }

    /// ONE O(N) pass over `records`: build the (category × volume) matrix, the
    /// sorted list of volumes that hold any candidate, and the anchor summary.
    /// Everything the dialog needs is derived from the returned Classification
    /// by cell arithmetic — this is the only full walk.
    static func classify(records: [VideoRecord]) -> Classification {
        let sets = UnrelatedAudioPurge.videoSets(in: records)
        let hasAnchors = !sets.isEmpty

        var matrix: [NonVideoCategory: [String: Cell]] = [:]
        var anchorCount = 0
        var volumeKeySet = Set<String>()

        for r in records {
            if UnrelatedAudioPurge.isEssenceBearing(r) { anchorCount += 1 }
            guard let cat = category(for: r, videoSets: sets, hasVideoAnchors: hasAnchors) else {
                continue
            }
            let vk = volumeKey(forFullPath: r.fullPath)
            let dir = UnrelatedAudioPurge.dir(ofFullPath: r.fullPath)
            volumeKeySet.insert(vk)
            var byVolume = matrix[cat] ?? [:]
            var cell = byVolume[vk] ?? Cell()
            cell.ids.append(r.id)
            cell.dirCounts[dir, default: 0] += 1
            byVolume[vk] = cell
            matrix[cat] = byVolume
        }

        let sortedKeys = volumeKeySet.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return Classification(matrix: matrix,
                              volumeKeys: sortedKeys,
                              hasVideoAnchors: hasAnchors,
                              anchorCount: anchorCount)
    }
}
