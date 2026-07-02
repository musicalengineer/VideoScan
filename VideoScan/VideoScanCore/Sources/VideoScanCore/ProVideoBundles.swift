// ProVideoBundles.swift
// Pro-video project bundle/package conventions (Feature: discovery
// completeness, 2026-07-02).
//
// Final Cut / iMovie / legacy Apple pro-video apps store user media INSIDE
// package directories that Finder shows as single files. The "Look Inside
// Video Project Bundles" scan option descends into these; media found inside
// is tagged with the enclosing bundle path (ScanContext.bundleContainer) so
// the catalog can say "this clip lives inside Vacation.fcpbundle".
//
// This is the CANONICAL list — the app-side walker skip categories
// (SkipCategories.proVideoBundleExtensions) alias it rather than duplicating
// it. Deliberately EXCLUDES photo/music libraries (.photoslibrary, .lrdata,
// .aplibrary, .musiclibrary, …): those stay governed by the existing
// "Skip Media Bundles" option and are never unlocked by the pro-video toggle.
//
// Pure, Foundation-only string logic — unit-testable with no filesystem.

import Foundation

public enum ProVideoBundles {

    /// Package-directory extensions (lowercased) for pro-video project
    /// bundles: Final Cut Pro X libraries/legacy projects, iMovie libraries
    /// and legacy iMovie HD project bundles, and iMovie '08–'11 (.rcproject)
    /// projects.
    public static let bundleExtensions: Set<String> = [
        "fcpbundle",              // Final Cut Pro X library
        "finalcutprojectlibrary", // FCP X library (early naming)
        "fcp",                    // legacy Final Cut project package
        "imovielibrary",          // iMovie 10+ library
        "imovieproject",          // iMovie HD (6) project bundle
        "rcproject"               // iMovie '08–'11 / iMovie for iOS project
    ]

    /// The path of the OUTERMOST pro-video bundle directory enclosing
    /// `path`, or nil when the path is not inside one. The last path
    /// component (the file itself) is never considered — a regular FILE
    /// named `x.fcpbundle` is not a container.
    ///
    ///   /Vol/Projects/Trip.fcpbundle/Media/clip.mov → /Vol/Projects/Trip.fcpbundle
    ///   /Vol/Movies/clip.mov                        → nil
    public static func container(forPath path: String) -> String? {
        let comps = (path as NSString).pathComponents
        guard comps.count > 1 else { return nil }
        for i in 0..<(comps.count - 1) {
            let ext = (comps[i] as NSString).pathExtension.lowercased()
            if !ext.isEmpty, bundleExtensions.contains(ext) {
                return NSString.path(withComponents: Array(comps[0...i]))
            }
        }
        return nil
    }
}
