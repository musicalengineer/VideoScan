import Foundation

// MARK: - Unrelated Audio Purge (catalog maintenance, 2026-07-21)
//
// A SECOND catalog-maintenance purge, a sibling to CoverArtMusicPurge.
// It removes audio-only records that have NO relationship to any video —
// the "unrelated audio junk" bulk: Logic Pro Library.bundle/Samples,
// Apple Loops, Omnisphere / Pro Tools sample libraries, standalone music.
//
// Rick's directive: the catalog should keep only video files + "stranded
// audio that might belong to video files"; everything else is purgeable.
// A read-only dry-run of the live catalog (101,604 records) counted
// 81,084 audio-only records — 77,293 unrelated to any video (PURGE) and
// 3,791 related (KEEP). The unrelated bulk is 42k Logic samples, 20k
// Apple Loops, plus Omnisphere / Pro Tools sample content.
//
// Reversible: this only removes CATALOG RECORDS. Files on disk are never
// touched, and a re-scan re-adds the records. A pre-purge recovery
// snapshot is written first (fail-safe: no snapshot → remove nothing),
// exactly like CoverArtMusicPurge.
//
// THE CRITERION (a pure function of catalog metadata — zero filesystem
// calls, so it is trivially unit-testable and is shared by BOTH the live
// count in the confirmation sheet and the removal itself). A record is a
// PURGE candidate iff:
//   • streamType == .audioOnly, AND
//   • it is NOT related to any video-bearing record, where "related"
//     means ANY of:
//       – same directory (dirname of fullPath) as a video-bearing record;
//       – its filename stem (basename sans extension, lowercased) equals
//         a video's stem;
//       – its materialPackageUMID is non-empty and matches a video's.
// "Video-bearing" = streamType is .videoAndAudio or .videoOnly.
//
// KEEP everything else: all video-bearing records, all .ffprobeFailed
// (recovered Avid essence — 4,410 of them), all .noStreams, and every
// audio-only record that IS related to a video.
//
// PERFORMANCE — O(N), not O(N²). The naive "for each audio, scan every
// video" is 81k × 16k ≈ 1.3 billion comparisons. Instead we make ONE
// pass over the catalog to precompute three video-side Sets (dirs,
// stems, UMIDs), then each audio record is O(1) three Set lookups. Total
// is O(N) over ~100k records — the live count AND the purge both run this
// and must stay well under a couple of seconds.
//
// Memory: three Set<String> bounded by the video-bearing record count
// (~16k) plus, for the removal, one Set<UUID> of candidate IDs bounded by
// the catalog size (~100k). No media bytes are ever read. Worst-case
// footprint is a few MB of strings — negligible against the catalog
// itself already resident in `records`.
//
// (Swift `enum` with only static members ≈ a C++ namespace — no
// instances, just a scoping shell for free functions.)

enum UnrelatedAudioPurge {

    // MARK: - Path helpers (pure, no filesystem access)

    /// Directory portion of a full path — `dirname(fullPath)`. Pure string
    /// operation; never touches disk. Empty paths yield "".
    static func dir(ofFullPath fullPath: String) -> String {
        (fullPath as NSString).deletingLastPathComponent
    }

    /// Filename stem: basename without its extension, lowercased. Used for
    /// the "same stem as a video" relationship (e.g. `reel.mxf` video and a
    /// stray `reel.wav` audio in a different folder are the same footage).
    static func stem(ofFullPath fullPath: String) -> String {
        let base = (fullPath as NSString).lastPathComponent
        return (base as NSString).deletingPathExtension.lowercased()
    }

    // MARK: - Video-side relationship sets (built ONCE, O(N))

    /// The three precomputed lookup sets from every video-bearing record.
    /// Building this once and probing it per-audio-record is what turns the
    /// relationship test from O(N²) into O(N).
    ///
    /// (In C++ terms: three `std::unordered_set<std::string>` you populate
    /// in a single sweep, then do O(1) `.count(key)` probes against.)
    struct VideoSets {
        let dirs: Set<String>
        let stems: Set<String>
        let umids: Set<String>

        var isEmpty: Bool { dirs.isEmpty && stems.isEmpty && umids.isEmpty }
    }

    /// True iff `record` carries a video stream (the "video-bearing" gate).
    static func isVideoBearing(_ record: VideoRecord) -> Bool {
        switch record.streamType {
        case .videoAndAudio, .videoOnly:
            return true
        case .audioOnly, .noStreams, .ffprobeFailed:
            return false
        }
    }

    /// Single pass over the catalog collecting the video-side dirs, stems,
    /// and non-empty UMIDs. Called ONCE per count/purge — never per record.
    static func videoSets(in records: [VideoRecord]) -> VideoSets {
        var dirs = Set<String>()
        var stems = Set<String>()
        var umids = Set<String>()
        for r in records where isVideoBearing(r) {
            dirs.insert(dir(ofFullPath: r.fullPath))
            stems.insert(stem(ofFullPath: r.fullPath))
            if !r.materialPackageUMID.isEmpty {
                umids.insert(r.materialPackageUMID)
            }
        }
        return VideoSets(dirs: dirs, stems: stems, umids: umids)
    }

    // MARK: - The relationship check (pure, O(1) given the sets)

    /// True iff this audio record is RELATED to some video-bearing record —
    /// i.e. it should be KEPT as "stranded audio that might belong to a
    /// video." Three O(1) probes: shared directory, shared stem, or shared
    /// non-empty UMID. Testable directly against synthetic records + sets.
    static func isRelatedToVideo(_ record: VideoRecord, videoSets sets: VideoSets) -> Bool {
        if sets.dirs.contains(dir(ofFullPath: record.fullPath)) { return true }
        if sets.stems.contains(stem(ofFullPath: record.fullPath)) { return true }
        if !record.materialPackageUMID.isEmpty,
           sets.umids.contains(record.materialPackageUMID) { return true }
        return false
    }

    /// PURE candidate predicate given the precomputed video sets. A record
    /// is a purge candidate iff it is audio-only AND unrelated to any video.
    /// Non-audio records (video-bearing, ffprobeFailed, noStreams) are
    /// never candidates — they are always kept.
    static func isCandidate(_ record: VideoRecord, videoSets sets: VideoSets) -> Bool {
        guard record.streamType == .audioOnly else { return false }
        return !isRelatedToVideo(record, videoSets: sets)
    }

    // MARK: - Whole-catalog entry points (each builds the sets once)

    /// Every purge candidate in `records`, order preserved. Builds the
    /// video sets once, then O(1) per record.
    static func candidates(in records: [VideoRecord]) -> [VideoRecord] {
        let sets = videoSets(in: records)
        return records.filter { isCandidate($0, videoSets: sets) }
    }

    /// IDs of every purge candidate — the removal key set. `Set` so the
    /// `records.removeAll` pass is O(1) per record.
    static func candidateIDs(in records: [VideoRecord]) -> Set<UUID> {
        let sets = videoSets(in: records)
        var ids = Set<UUID>()
        for r in records where isCandidate(r, videoSets: sets) { ids.insert(r.id) }
        return ids
    }

    /// Count of purge candidates. One O(N) pass after the one-time set
    /// build — safe to call from the confirmation sheet's on-appear.
    static func count(in records: [VideoRecord]) -> Int {
        let sets = videoSets(in: records)
        var n = 0
        for r in records where isCandidate(r, videoSets: sets) { n += 1 }
        return n
    }

    // MARK: - Confirmation-sheet breakdown (what will be removed)

    /// One parent directory (tree) and how many candidates live under it.
    /// Shown in the confirmation sheet so Rick can eyeball that the doomed
    /// set is sample libraries, not family media, before clicking Purge.
    struct TreeCount: Identifiable {
        let path: String
        let count: Int
        var id: String { path }
    }

    /// Everything the confirmation sheet needs, computed in ONE combined
    /// pass so the sheet does not scan the catalog twice: the total
    /// candidate count plus the top-N parent directories by candidate
    /// count. Cheap and read-only — no filesystem access.
    struct Summary {
        let count: Int
        /// Top parent directories among candidates, highest count first.
        let topTrees: [TreeCount]
    }

    /// Build the sheet summary: total candidate count + the `topN` parent
    /// directories holding the most candidates. Single set-build then one
    /// O(N) pass that tallies per-directory counts on the fly.
    static func summary(in records: [VideoRecord], topN: Int = 6) -> Summary {
        let sets = videoSets(in: records)
        var total = 0
        var perDir: [String: Int] = [:]
        for r in records where isCandidate(r, videoSets: sets) {
            total += 1
            perDir[dir(ofFullPath: r.fullPath), default: 0] += 1
        }
        // Sort by count desc, then path asc for a stable, readable list.
        let top = perDir
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(topN)
            .map { TreeCount(path: $0.key, count: $0.value) }
        return Summary(count: total, topTrees: Array(top))
    }
}
