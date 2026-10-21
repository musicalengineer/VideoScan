// PersonFinderCatalogFilter.swift
// Catalog skip-set, person-scan prefilter, video discovery, and small
// formatting/sanitization helpers extracted from PersonFinderModel.swift.
//
// Step 2 of 6 in the PersonFinderModel decomposition. These free functions
// are shared by both the catalog scan path and the person-finder pre-flight
// path, which is why they sit at file scope (not on the model).
//
// 2026-10-21: the prefilter reads the LIVE catalog records (see "Live
// catalog snapshot" below) and never touches a catalog file.

import Foundation

// MARK: - Catalog skip set

/// The one "known unscannable" rule (audio-only, no streams, ffprobe
/// failure), shared by the basic skip set (#23) and the prefilter (#66).
nonisolated func pfIsUnscannable(_ streamType: StreamType) -> Bool {
    switch streamType {
    case .audioOnly, .noStreams, .ffprobeFailed: return true
    case .videoAndAudio, .videoOnly: return false
    }
}

/// Pure helper: from a list of records, return paths known to be unscannable
/// (audio-only, no streams, ffprobe failures).
nonisolated func pfCatalogSkipPaths(from records: [VideoRecord]) -> Set<String> {
    var skip = Set<String>()
    for rec in records where !rec.fullPath.isEmpty && pfIsUnscannable(rec.streamType) {
        skip.insert(rec.fullPath)
    }
    return skip
}

// MARK: - Live catalog snapshot
//
// Until 2026-10-21 the prefilter decoded catalog.json from disk at every job
// start (`CatalogStore.readRecordsWithoutAdopting()`, inside MainActor.run —
// an ~80 MB decode on the main thread). Since the 10/18 cutover catalog.sqlite
// is the authority and catalog.json is frozen, so every skip decision was
// made on pre-cutover data: files catalogued since were not skipped, files
// removed since still were. The prefilter now reads the LIVE records the
// catalog model holds — whichever authority loaded them.
//
// GH #167 still holds by construction: nothing here can load, adopt or
// rotate the catalog session, because nothing here touches CatalogStore.

/// The facts the prefilter reads from one record, copied out on the main
/// actor. A value type (for Rick: a plain C++ struct copied by value; the
/// String/Array members are copy-on-write, so a copy is a refcount bump,
/// not a deep copy) so the snapshot can cross to a background task —
/// `VideoRecord` is a mutable class owned by the main actor.
nonisolated struct PFSkipFacts: Sendable, Equatable {
    var fullPath: String
    var isUnscannable: Bool
    var detectedPeople: [String]
    var suspectedPeople: [String]
    var junkScore: Int
    var durationSeconds: Double
    var resolution: String

    init(fullPath: String, isUnscannable: Bool = false,
         detectedPeople: [String] = [], suspectedPeople: [String] = [],
         junkScore: Int = 0, durationSeconds: Double = 0, resolution: String = "") {
        self.fullPath = fullPath
        self.isUnscannable = isUnscannable
        self.detectedPeople = detectedPeople
        self.suspectedPeople = suspectedPeople
        self.junkScore = junkScore
        self.durationSeconds = durationSeconds
        self.resolution = resolution
    }

    init(_ rec: VideoRecord) {
        self.init(fullPath: rec.fullPath,
                  isUnscannable: pfIsUnscannable(rec.streamType),
                  detectedPeople: rec.detectedPeople,
                  suspectedPeople: rec.suspectedPeople,
                  junkScore: rec.junkScore,
                  durationSeconds: rec.durationSeconds,
                  resolution: rec.resolution)
    }
}

/// Snapshot the records' prefilter facts. Records with no path are dropped
/// here (no rule could match them). Call where the records live (the main
/// actor); hand the result to `pfPersonScanSkipPaths(fromFacts:)` off it.
nonisolated func pfSkipFacts(from records: [VideoRecord]) -> [PFSkipFacts] {
    var out: [PFSkipFacts] = []
    out.reserveCapacity(records.count)
    for rec in records where !rec.fullPath.isEmpty { out.append(PFSkipFacts(rec)) }
    return out
}

extension VideoScanModel {
    /// The Person Finder prefilter's source: the live in-memory catalog
    /// (`records` — loaded from catalog.sqlite under the SQLite authority).
    /// One O(records) field copy; no file I/O, no decode.
    func personScanSkipFacts() -> [PFSkipFacts] {
        pfSkipFacts(from: records)
    }
}

// MARK: - Person scan prefilter (issue #66)
//
// Extends the basic catalog-skip set with four more rules grounded in
// already-collected catalog metadata. Each category produces an
// independently testable bucket; PersonFinder logs per-category counts
// so the user can see why files were dropped.

/// Result of a person-scan prefilter pass — categorised so callers can
/// report why each file was excluded.
struct CatalogSkipResult: Equatable {
    /// Audio-only / no-streams / ffprobe-failed (basic catalog filter, #23).
    var unscannable: Set<String> = []
    /// Files where `detectedPeople` already contains the target name
    /// (cache hit from a prior scan — re-running would just confirm).
    var alreadyKnown: Set<String> = []
    /// `junkScore >= junkScoreCeiling`. Probably noise.
    var junkScored: Set<String> = []
    /// Duration > 0 but < `minDurationSeconds`. Too short to contain a
    /// recognisable face shot.
    var tooShort: Set<String> = []
    /// Resolution height < `minResolutionHeight`. Vision struggles below
    /// 480p; signal-to-noise is poor.
    var lowResolution: Set<String> = []
    /// How many catalog records (with a path) the prefilter looked at —
    /// 0 means the live catalog had nothing loaded (e.g. an early-launch job).
    var checkedRecords: Int = 0

    /// Union of every category — what callers actually filter against.
    var all: Set<String> {
        unscannable
            .union(alreadyKnown)
            .union(junkScored)
            .union(tooShort)
            .union(lowResolution)
    }

    /// Sum of every category's count (categories may overlap, so this can
    /// exceed `all.count` — exposed for diagnostic logging only).
    var totalDropsAcrossCategories: Int {
        unscannable.count + alreadyKnown.count + junkScored.count
            + tooShort.count + lowResolution.count
    }

    /// The per-category breakdown for the job log, e.g.
    /// " (3 unscannable, 1 already-known for Donna)"; "" when every bucket
    /// is empty.
    func breakdownDetail(targetName: String) -> String {
        let buckets: [(Int, String)] = [
            (unscannable.count, "unscannable"),
            (alreadyKnown.count, "already-known for \(targetName)"),
            (junkScored.count, "junk-scored"),
            (tooShort.count, "too-short"),
            (lowResolution.count, "low-resolution"),
        ]
        let parts = buckets.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
        return parts.isEmpty ? "" : " (\(parts.joined(separator: ", ")))"
    }
}

/// The prefilter's one always-written job-log line (it is never silent):
/// what it looked at and what it dropped.
nonisolated func pfPrefilterSummaryLine(connected: Bool, checked: Int, skipped: Int) -> String {
    guard connected else { return "Catalog prefilter: no catalog connected — nothing skipped" }
    guard checked > 0 else {
        return "Catalog prefilter: the catalog has no records loaded yet — nothing skipped"
    }
    return "Catalog prefilter: checked \(checked) catalog record(s), skipped \(skipped) file(s)"
}

/// Parse a resolution string like "1920x1080" → 1080. Returns nil if the
/// string can't be parsed (e.g. empty, "—", "unknown") so callers know to
/// skip the resolution rule rather than misclassify.
nonisolated func pfResolutionHeight(from resolution: String) -> Int? {
    let parts = resolution.split(separator: "x", maxSplits: 1, omittingEmptySubsequences: true)
    guard parts.count == 2, let h = Int(parts[1]) else { return nil }
    return h
}

/// Pure helper: build a categorised skip set for person search using all
/// available catalog metadata. Each category's bucket is independently
/// populated so PersonFinder can log "skipped 12 too-short, 3 already-known
/// hits for Donna, …" for diagnostic transparency.
///
/// Defaults match the conservative rules from issue #66 — increase
/// thresholds to be more aggressive, set to nil to disable a rule.
nonisolated func pfPersonScanSkipPaths(
    fromFacts facts: [PFSkipFacts],
    targetPersonName: String?,
    minDurationSeconds: Double = 5.0,
    minResolutionHeight: Int = 480,
    junkScoreCeiling: Int = 80
) -> CatalogSkipResult {
    var result = CatalogSkipResult()
    let target = targetPersonName?
        .trimmingCharacters(in: .whitespaces)
        .lowercased()

    for rec in facts where !rec.fullPath.isEmpty {
        result.checkedRecords += 1
        // Rule 1: unscannable (existing #23 behavior)
        if rec.isUnscannable {
            result.unscannable.insert(rec.fullPath)
            continue   // no other rule matters
        }

        // Rule 2: detectedPeople OR suspectedPeople already contains target
        // (cache hit from a prior scan — re-running a per-profile search
        // would just confirm; multi-POI "Search for Family" callers should
        // pass nil targetPersonName to bypass this rule and force re-verify).
        if let target, !target.isEmpty {
            let already = rec.detectedPeople.contains { $0.lowercased() == target }
                || rec.suspectedPeople.contains { $0.lowercased() == target }
            if already { result.alreadyKnown.insert(rec.fullPath) }
        }

        // Rule 3: junkScore exceeds ceiling
        if rec.junkScore >= junkScoreCeiling {
            result.junkScored.insert(rec.fullPath)
        }

        // Rule 4: too short. Only fires when duration is positive AND below
        // threshold — durationSeconds == 0 means "we don't know" → don't skip.
        if rec.durationSeconds > 0 && rec.durationSeconds < minDurationSeconds {
            result.tooShort.insert(rec.fullPath)
        }

        // Rule 5: low resolution. Empty / unparseable resolution string is
        // treated as "don't know" → don't skip.
        if let h = pfResolutionHeight(from: rec.resolution), h < minResolutionHeight {
            result.lowResolution.insert(rec.fullPath)
        }
    }
    return result
}

/// Record-array convenience over `pfPersonScanSkipPaths(fromFacts:)` —
/// identical rules, for callers already holding the records.
nonisolated func pfPersonScanSkipPaths(
    from records: [VideoRecord],
    targetPersonName: String?,
    minDurationSeconds: Double = 5.0,
    minResolutionHeight: Int = 480,
    junkScoreCeiling: Int = 80
) -> CatalogSkipResult {
    pfPersonScanSkipPaths(fromFacts: pfSkipFacts(from: records),
                          targetPersonName: targetPersonName,
                          minDurationSeconds: minDurationSeconds,
                          minResolutionHeight: minResolutionHeight,
                          junkScoreCeiling: junkScoreCeiling)
}

/// The live-catalog snapshot closure. `@Sendable` as well as `@MainActor`
/// so it may be stored in the Sendable `PFLiveCatalogSource` and carried
/// into the nonisolated scan path (Swift 6 strict concurrency). For Rick:
/// think of it as a std::function that may only be invoked on the main
/// thread and whose captures are all safe to share across threads.
typealias PFSkipFactsSnapshot = @MainActor @Sendable () -> [PFSkipFacts]

/// The job-start prefilter: snapshot the live catalog on the main actor
/// (`source` — the app wires `VideoScanModel.personScanSkipFacts`), then
/// build the skip set on a detached background task. Returns nil when no
/// catalog is connected (a bare PersonFinderModel, e.g. in a unit test), so
/// the caller can say so rather than pretend the catalog knew nothing.
nonisolated func pfLiveCatalogSkipResult(
    targetPersonName: String?,
    source: PFSkipFactsSnapshot?
) async -> CatalogSkipResult? {
    guard let source else { return nil }
    let facts = await MainActor.run { source() }
    return await Task.detached(priority: .userInitiated) {
        pfPersonScanSkipPaths(fromFacts: facts, targetPersonName: targetPersonName)
    }.value
}

/// A scan job's connection to the live catalog, captured at job start and
/// carried into the nonisolated scan path. Wraps the optional snapshot
/// closure (nil = no catalog connected) so the job path passes one value.
nonisolated struct PFLiveCatalogSource: Sendable {
    let snapshot: PFSkipFactsSnapshot?

    init(_ snapshot: PFSkipFactsSnapshot?) {
        self.snapshot = snapshot
    }

    /// See `pfLiveCatalogSkipResult` — nil when no catalog is connected.
    func skipResult(targetPersonName: String?) async -> CatalogSkipResult? {
        await pfLiveCatalogSkipResult(targetPersonName: targetPersonName, source: snapshot)
    }
}

// MARK: - Video discovery

nonisolated func pfFindVideoFiles(at searchPath: String, skipBundles: Bool) -> [String] {
    let pfSkipDirectories: Set<String> = [
        ".Spotlight-V100", ".Trashes", ".fseventsd", ".TemporaryItems",
        ".DocumentRevisions-V100", ".PKInstallSandboxManager-SystemSoftware",
        ".MobileBackups", ".vol", ".hotfiles.btree",
        "System", "Library", "usr", "bin", "sbin", "private", "cores", "dev",
        "node_modules", ".npm", ".yarn", "bower_components",
        ".git", ".svn", ".hg", "DerivedData", "__pycache__",
        ".Trash", "Caches", "Logs", "DiagnosticReports",
        ".next", ".nuxt", ".angular", ".webpack", "vendor",
        ".vscode", ".idea", ".eclipse", "xcuserdata"
    ]
    let pfBundleExtensions: Set<String> = [
        "fcpbundle", "imovielibrary", "photoslibrary", "aplibrary", "dvdmedia",
        "imovieproject", "dvdproj", "prproj", "aep", "aet", "fcp"
    ]
    let pfVideoExtensions: Set<String> = [
        "mov", "qt", "mp4", "m4v", "avi", "divx", "wmv", "asf", "mkv", "webm", "mxf",
        "mts", "m2ts", "m2t", "trp", "tp", "mpg", "mpeg", "mpe", "mpv", "m2v", "m2p", "mp2v", "vob",
        "dv", "dif", "3gp", "3g2", "3gpp", "3gpp2", "flv", "f4v", "mod", "tod", "ogv", "ogm",
        "mjpeg", "mjpg", "hevc", "h264", "h265", "264", "265", "rm", "rmvb", "amv", "wtv", "dvr-ms",
        "braw", "r3d", "vro"
    ]
    // Excluded: m4p/m4b (DRM audio), dat (FINDER.DAT junk), ts (conflicts with TypeScript)
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: searchPath, isDirectory: &isDir) else { return [] }
    if !isDir.boolValue {
        let ext = (searchPath as NSString).pathExtension.lowercased()
        if ext == "ts" {
            return pfLikelyTransportStream(path: searchPath, relativePath: searchPath) ? [searchPath] : []
        }
        return pfVideoExtensions.contains(ext) ? [searchPath] : []
    }
    var files: [String] = []
    guard let e = fm.enumerator(atPath: searchPath) else { return [] }
    while let el = e.nextObject() as? String {
        // Skip system/hidden/irrelevant directories early
        let component = (el as NSString).lastPathComponent
        if pfSkipDirectories.contains(component) {
            e.skipDescendants(); continue
        }
        if skipBundles {
            let parts = el.components(separatedBy: "/")
            if parts.dropLast().contains(where: { pfBundleExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) {
                e.skipDescendants(); continue
            }
            if pfBundleExtensions.contains((el as NSString).pathExtension.lowercased()) {
                e.skipDescendants(); continue
            }
        }
        let ext = (el as NSString).pathExtension.lowercased()
        if pfVideoExtensions.contains(ext) || ext == "ts" {
            if ext == "ts" {
                let fullPath = (searchPath.hasSuffix("/") ? searchPath : searchPath + "/") + el
                if !pfLikelyTransportStream(path: fullPath, relativePath: el) { continue }
            }
            let base = searchPath.hasSuffix("/") ? searchPath : searchPath + "/"
            files.append(base + el)
        }
    }
    var seen = Set<String>(); var deduped: [String] = []
    for path in files.sorted() {
        let key = "\((path as NSString).lastPathComponent)|\((try? fm.attributesOfItem(atPath: path)[.size] as? Int) ?? -1)"
        if seen.insert(key).inserted { deduped.append(path) }
    }
    return deduped
}

private func pfLikelyTransportStream(path: String, relativePath: String) -> Bool {
    let name = (path as NSString).lastPathComponent
    if name.hasSuffix(".d.ts") || name.hasSuffix(".spec.ts") ||
       name.hasSuffix(".test.ts") || name.hasSuffix(".config.ts") {
        return false
    }
    let devTreeMarkers: Set<String> = [
        "node_modules", ".npm", "src", "dist", "build", ".next",
        "packages", "components", "lib", "__tests__", "test",
        "scripts", ".vscode", ".idea", "vendor", "bower_components"
    ]
    let parts = relativePath.components(separatedBy: "/")
    if parts.contains(where: { devTreeMarkers.contains($0) }) { return false }
    let fm = FileManager.default
    if let attrs = try? fm.attributesOfItem(atPath: path),
       let size = attrs[.size] as? Int64, size < 512_000 {
        return false
    }
    return true
}

// MARK: - Utilities

nonisolated func pfSanitize(_ s: String) -> String {
    var r = s.replacingOccurrences(of: " ", with: "_")
    let ok = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_."))
    r = String(r.unicodeScalars.filter { ok.contains($0) })
    return r
}

func pfFormatDuration(_ secs: Double) -> String {
    let t = Int(secs); let h = t/3600; let m = (t%3600)/60; let s = t%60
    return h > 0 ? "\(h)h \(m)m \(s)s" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
}

func pfFormatBytes(_ bytes: Int64) -> String {
    // Rick 2026-08-18: one app-wide decimal formatter (Finder / df base).
    MediaBytes.display(bytes)
}
