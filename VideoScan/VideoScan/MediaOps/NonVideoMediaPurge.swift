import Foundation

// MARK: - Non-Video Media Purge — extension×volume classification (2026-07-21)
//
// The composition layer behind the single "Purge Non-Video Media…" dialog.
// REDESIGN (Rick, 2026-07-21): the "what to purge" control is now a PURE
// EXTENSION CHECKLIST, not two smart categories. Every file EXTENSION present
// in the catalog that is NOT a known video container / Avid essence type is
// offered as its own checkbox with a live count and a "(N paired)" safety
// annotation. The user opts in per extension; nothing is preselected.
//
// WHY PURE EXTENSION. Rick will spot-test this "as a user / me in 6 months":
// an explicit, literal "remove all .cr3 / .mp3 on these volumes" is far easier
// to reason about than two heuristic buckets. The former paired-record
// PROTECTION now lives in a VISIBLE annotation — each row shows how many of
// its records belong to an A/V pair ("(N paired)", orange) — so the user is
// shown the risk rather than having it silently applied. Extension-purge is
// LITERAL: it removes matching records INCLUDING paired ones. That is
// intended, per Rick — the guard is the annotation, not a hidden keep-rule.
//
// EFFICIENT INTERACTIVE RECOMPUTE. `classify(records:)` does ONE O(N) pass:
// for each offered record it computes (extension, volumeKey) and folds it into
// a small (extension × volume) matrix of Cells. Each Cell carries the record
// IDs (the removal key set), a paired-record count (for the "(N paired)"
// annotation), and a per-parent-directory tally (for the top-locations
// breakdown). Toggling extension / volume selections in the dialog is then
// pure arithmetic over the matrix cells — sum a few Ints, union a few small ID
// sets — never another pass over the ~100k records. The O(N) pass runs ONCE
// (on the sheet's .onAppear), off the SwiftUI view body, per the
// no-O(records)-work-in-a-view-body rule.
//
// VIDEO / ESSENCE EXCLUSION. Known video containers and Avid essence are NEVER
// offered here (never purgeable through this dialog) and the extensionless
// bucket ("") is excluded too — a video-only Avid/QuickTime file often has no
// extension, so offering "" would risk severing real footage. See
// `excludedVideoExtensions`.
//
// VOLUME DERIVATION. A record's volume key is `VolumeReachability
// .volumeName(forPath:)` — the SAME pure path-string derivation the
// Volumes/Archive view labels rows with ("/Volumes/<name>/…" → "<name>";
// "/Users/<name>/…" → "<name>"; other paths bucket to their top-level
// component). Pure, no disk I/O, so it is safe inside the O(N) pass and
// deterministic for tests.
//
// MEMORY. Worst case the Cell ID arrays together hold one UUID per offered
// record — bounded by the catalog size (~100k → ~1.6 MB of UUIDs). The
// per-directory tallies are bounded by the number of DISTINCT parent
// directories among candidates (far smaller). No media bytes are ever read. A
// few MB total, negligible against `records` itself.
//
// (Swift `enum` with only static members ≈ a C++ namespace — no instances,
// just a scoping shell for free functions.)

enum NonVideoMediaPurge {

    // MARK: - Excluded (never-offered) extensions

    /// Known video containers + Avid essence. Records with any of these
    /// extensions — or with NO extension (the "" bucket) — are never offered
    /// in the checklist and can never be removed through this dialog. Lower-
    /// cased; the classify pass lowercases each record's extension before test.
    /// (Swift `Set<String>` literal ≈ a std::unordered_set built once.)
    static let excludedVideoExtensions: Set<String> = [
        "mov", "mp4", "m4v", "avi", "mkv", "mts", "m2ts", "wmv", "flv",
        "3gp", "3g2", "mpg", "mpeg", "mpe", "vob", "ogv", "webm",
        "dv", "m2v", "mod", "tod", "mxf",
    ]

    /// Normalized extension for a record: lowercased, any leading dot stripped.
    /// Empty means the extensionless bucket (excluded from the checklist).
    static func normalizedExtension(_ record: VideoRecord) -> String {
        var e = record.ext.lowercased()
        if e.hasPrefix(".") { e.removeFirst() }
        return e
    }

    /// True when this record's extension is OFFERED in the checklist (present,
    /// non-empty, and not a known video/essence container).
    static func isOffered(_ record: VideoRecord) -> Bool {
        let e = normalizedExtension(record)
        return !e.isEmpty && !excludedVideoExtensions.contains(e)
    }

    // MARK: - Human labels

    /// Small static map from extension → short human label for clarity in the
    /// checklist. Unmapped extensions fall back to "(.ext)". (Swift dictionary
    /// literal ≈ a const std::unordered_map<string,string> initialized once.)
    private static let extensionLabels: [String: String] = [
        "cr3":  "Canon RAW photo",
        "cr2":  "Canon RAW",
        "dng":  "RAW photo",
        "jpg":  "JPEG photo",
        "jpeg": "JPEG photo",
        "heic": "HEIC photo",
        "png":  "PNG image",
        "m4a":  "AAC audio",
        "mp3":  "MP3 audio",
        "wav":  "WAV audio",
        "aif":  "AIFF audio",
        "aiff": "AIFF audio",
        "aac":  "audio",
        "flac": "audio",
    ]

    /// Human label for an extension row. Falls back to "(.ext)" if unmapped so
    /// even stray types render legibly.
    static func label(forExtension ext: String) -> String {
        let e = ext.lowercased()
        return extensionLabels[e] ?? "(.\(e))"
    }

    // MARK: - Matrix pieces

    /// One parent directory and how many candidates live under it, for the
    /// dialog's top-locations breakdown.
    struct TreeCount: Identifiable {
        let path: String
        let count: Int
        var id: String { path }
    }

    /// A single (extension × volume) matrix cell: the candidate record IDs in
    /// that cell, how many of them belong to an A/V pair, and a per-parent-
    /// directory tally for the breakdown.
    struct Cell {
        var ids: [UUID] = []
        var pairedCount: Int = 0
        var dirCounts: [String: Int] = [:]
        var count: Int { ids.count }
    }

    /// The result of the ONE O(N) classification pass. All the dialog's
    /// interactive numbers are derived from this by cheap cell arithmetic —
    /// no further catalog walks.
    struct Classification {
        /// matrix[extension][volumeKey] → Cell. Absent keys mean an empty cell.
        let matrix: [String: [String: Cell]]
        /// Every offered extension present in the catalog, SORTED BY OVERALL
        /// COUNT DESCENDING (biggest junk first), tie-broken by name ascending.
        let extensions: [String]
        /// Every volume key that holds ANY offered record, sorted
        /// case-insensitively for a stable dialog list.
        let volumeKeys: [String]

        // MARK: Interactive queries (pure cell arithmetic, no records walk)

        /// Candidates for one extension across the given volumes — the count
        /// shown next to an EXTENSION checkbox for the currently-selected
        /// volumes.
        func extensionCount(_ ext: String,
                            volumeKeys keys: Set<String>) -> Int {
            guard let byVolume = matrix[ext] else { return 0 }
            var n = 0
            for k in keys { n += byVolume[k]?.count ?? 0 }
            return n
        }

        /// How many of one extension's records across the given volumes belong
        /// to an A/V pair — the "(N paired)" safety annotation, scoped to the
        /// currently-selected volumes (same scope as `extensionCount`).
        func extensionPairedCount(_ ext: String,
                                  volumeKeys keys: Set<String>) -> Int {
            guard let byVolume = matrix[ext] else { return 0 }
            var n = 0
            for k in keys { n += byVolume[k]?.pairedCount ?? 0 }
            return n
        }

        /// Candidates on one volume across the given extensions — the count
        /// shown next to a VOLUME checkbox for the currently-selected
        /// extensions.
        func volumeCount(_ volumeKey: String,
                         extensions exts: Set<String>) -> Int {
            var n = 0
            for e in exts { n += matrix[e]?[volumeKey]?.count ?? 0 }
            return n
        }

        /// Grand total across the selected extensions × volumes — the live
        /// "Remove N records" number.
        func totalCount(extensions exts: Set<String>,
                        volumeKeys keys: Set<String>) -> Int {
            var n = 0
            for e in exts {
                guard let byVolume = matrix[e] else { continue }
                for k in keys { n += byVolume[k]?.count ?? 0 }
            }
            return n
        }

        /// The exact removal key set for the selected extensions × volumes.
        /// Union of the relevant cells' ID arrays — O(selected candidates),
        /// never O(catalog).
        func candidateIDs(extensions exts: Set<String>,
                          volumeKeys keys: Set<String>) -> Set<UUID> {
            var ids = Set<UUID>()
            for e in exts {
                guard let byVolume = matrix[e] else { continue }
                for k in keys {
                    if let cell = byVolume[k] { ids.formUnion(cell.ids) }
                }
            }
            return ids
        }

        /// Top parent directories among the selected extensions × volumes,
        /// highest count first. Merges only the selected cells' per-directory
        /// tallies — iterates DISTINCT directories in-selection, not records.
        /// Also returns the grand total so the dialog can render "…and N more".
        func topLocations(extensions exts: Set<String>,
                          volumeKeys keys: Set<String>,
                          topN: Int = 6) -> (trees: [TreeCount], total: Int) {
            var perDir: [String: Int] = [:]
            var total = 0
            for e in exts {
                guard let byVolume = matrix[e] else { continue }
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

    /// Parent-directory string for a full path — reuses the shared helper so
    /// the top-locations breakdown matches the other purge dialogs exactly.
    static func dir(ofFullPath fullPath: String) -> String {
        UnrelatedAudioPurge.dir(ofFullPath: fullPath)
    }

    /// True when a record is part of an A/V pair — either grouped
    /// (`pairGroupID`) or directly linked (`pairedWith`). Drives the
    /// "(N paired)" annotation.
    static func isPaired(_ record: VideoRecord) -> Bool {
        record.pairGroupID != nil || record.pairedWith != nil
    }

    /// ONE O(N) pass over `records`: build the (extension × volume) matrix, the
    /// count-descending list of offered extensions, and the sorted list of
    /// volumes that hold any offered record. Everything the dialog needs is
    /// derived from the returned Classification by cell arithmetic — this is
    /// the only full walk.
    static func classify(records: [VideoRecord]) -> Classification {
        var matrix: [String: [String: Cell]] = [:]
        var volumeKeySet = Set<String>()
        // Overall (all-volume) count per extension, for the descending sort.
        var overallCount: [String: Int] = [:]

        for r in records {
            guard isOffered(r) else { continue }
            let ext = normalizedExtension(r)
            let vk = volumeKey(forFullPath: r.fullPath)
            let d = dir(ofFullPath: r.fullPath)
            let paired = isPaired(r)
            volumeKeySet.insert(vk)
            overallCount[ext, default: 0] += 1

            // DETACH before mutating: `removeValue` hands us the SOLE reference
            // to the inner dict / Cell, so `cell.ids.append` mutates in place
            // (amortized O(1)) instead of triggering copy-on-write of the whole
            // accumulated array every iteration. A plain `matrix[ext]` read
            // keeps a second reference alive → COW → O(k²) for a cell that
            // accumulates k candidates (tens of thousands of one extension
            // collapsing into one volume bucket = billions of copies, a
            // multi-second freeze on the main thread — the beachball QA caught
            // last round). Restoring unique ownership makes this a true O(N)
            // pass. (C++ analogy: emplace into a uniquely-owned vector vs.
            // deep-copying a shared one on every push_back.)
            var byVolume = matrix.removeValue(forKey: ext) ?? [:]
            var cell = byVolume.removeValue(forKey: vk) ?? Cell()
            cell.ids.append(r.id)
            if paired { cell.pairedCount += 1 }
            cell.dirCounts[d, default: 0] += 1
            byVolume[vk] = cell
            matrix[ext] = byVolume
        }

        let sortedExtensions = overallCount.keys.sorted {
            let ca = overallCount[$0] ?? 0
            let cb = overallCount[$1] ?? 0
            return ca != cb ? ca > cb : $0 < $1
        }
        let sortedVolumeKeys = volumeKeySet.sorted {
            $0.localizedCaseInsensitiveCompare($1) == .orderedAscending
        }
        return Classification(matrix: matrix,
                              extensions: sortedExtensions,
                              volumeKeys: sortedVolumeKeys)
    }
}
