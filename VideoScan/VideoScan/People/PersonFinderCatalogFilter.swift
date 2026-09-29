// PersonFinderCatalogFilter.swift
// Catalog skip-set, person-scan prefilter, video discovery, and small
// formatting/sanitization helpers extracted from PersonFinderModel.swift.
//
// Step 2 of 6 in the PersonFinderModel decomposition. Pure code movement
// from PersonFinderModel.swift — no logic changes. These free functions
// are shared by both the catalog scan path and the person-finder pre-flight
// path, which is why they sit at file scope (not on the model).

import Foundation

// MARK: - Catalog skip set

/// Pure helper: from a list of records, return paths known to be unscannable
/// (audio-only, no streams, ffprobe failures). Pulled out for unit testing —
/// `pfCatalogSkipSet()` calls this with `CatalogStore.shared.load()`.
nonisolated func pfCatalogSkipPaths(from records: [VideoRecord]) -> Set<String> {
    var skip = Set<String>()
    for rec in records {
        switch rec.streamType {
        case .audioOnly, .noStreams, .ffprobeFailed:
            if !rec.fullPath.isEmpty { skip.insert(rec.fullPath) }
        case .videoAndAudio, .videoOnly:
            break
        }
    }
    return skip
}

/// Build a set of full paths that should be skipped during person search because
/// they are known from prior catalog scans to be unscannable (audio-only, no streams,
/// ffprobe failures). Must be called on MainActor since CatalogStore is MainActor-isolated.
@MainActor
func pfCatalogSkipSet() -> Set<String> {
    pfCatalogSkipPaths(from: CatalogStore.shared.load())
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
    from records: [VideoRecord],
    targetPersonName: String?,
    minDurationSeconds: Double = 5.0,
    minResolutionHeight: Int = 480,
    junkScoreCeiling: Int = 80
) -> CatalogSkipResult {
    var result = CatalogSkipResult()
    let target = targetPersonName?
        .trimmingCharacters(in: .whitespaces)
        .lowercased()

    for rec in records where !rec.fullPath.isEmpty {
        // Rule 1: unscannable (existing #23 behavior)
        switch rec.streamType {
        case .audioOnly, .noStreams, .ffprobeFailed:
            result.unscannable.insert(rec.fullPath)
            continue   // no other rule matters
        case .videoAndAudio, .videoOnly:
            break
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

/// MainActor wrapper that loads the catalog and applies the full prefilter.
@MainActor
func pfPersonScanSkipResult(targetPersonName: String?) -> CatalogSkipResult {
    pfPersonScanSkipPaths(
        from: CatalogStore.shared.load(),
        targetPersonName: targetPersonName
    )
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
