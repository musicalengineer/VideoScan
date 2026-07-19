// GauntletSeams.swift
// Launch-argument seams for the Gauntlet UI-regression suite
// (docs/gauntlet.md). The Gauntlet drives the REAL app the way Rick
// spot-tests it, but its fixtures live in per-run temp dirs — these
// seams are how the runner tells the app-under-test where they are
// without an NSOpenPanel (which XCUITest cannot drive reliably).
//
// Every seam:
//   * is ONLY honored when TestEnvironment.isTestHost is true (in
//     production the getters short-circuit to nil before touching
//     UserDefaults);
//   * is read from the NSArgumentDomain — the volatile overlay
//     NSUserDefaults builds from `-key value` launch-argument pairs
//     (the established `-combineOutputFolder` pattern from
//     CombineWorkflowUITests). Nothing here is ever WRITTEN, so the
//     real prefs plist is untouched (settings-pollution class).
//
// C++ analogy: think of the argument domain as argv-driven overrides
// layered over the config file — reads hit the overlay, and we never
// call the setter, so the "file" never changes.

import Foundation

enum GauntletSeams {

    /// `-gauntletScanTarget <dir>` — a catalog scan target to pre-add at
    /// startup (flows 2/3/4: catalog search, set-a-date, Balance Audio).
    /// The UI still does the actual scanning by clicking Scan All.
    static var catalogScanTargetPath: String? { seamString("gauntletScanTarget") }

    /// `-gauntletPOIName <name>` + `-gauntletPOIRefPath <dir>` — create a
    /// saved POI profile at startup so flow 1 (person search) can start
    /// from the People pane exactly like a real saved person. The photos
    /// in the ref dir are copied into the (test-host-redirected) POI store.
    static var poiName: String? { seamString("gauntletPOIName") }
    static var poiReferencePath: String? { seamString("gauntletPOIRefPath") }

    /// `-gauntletRecentPath <dir>` — surfaces the fixture folder in the
    /// Person Finder job row's "Recent" volume-picker section, replacing
    /// the NSOpenPanel Browse… step (see PersonFinderView.recentPaths).
    static var recentSearchPath: String? { seamString("gauntletRecentPath") }

    private static func seamString(_ key: String) -> String? {
        guard TestEnvironment.isTestHost else { return nil }
        guard let value = UserDefaults.standard.string(forKey: key),
              !value.isEmpty else { return nil }
        return value
    }
}

// MARK: - Install hooks

extension VideoScanModel {

    /// Called from restoreScanTargets()'s test-host branch (which skips
    /// the real persisted-target restore). Appends the fixture folder as
    /// an ordinary CatalogScanTarget; persistScanTargets() is a no-op
    /// under a test host, so nothing leaks into the real defaults.
    func installGauntletScanTargetIfRequested() {
        guard let path = GauntletSeams.catalogScanTargetPath else { return }
        guard !scanTargets.contains(where: { $0.searchPath == path }) else { return }
        scanTargets.append(CatalogScanTarget(searchPath: path))
        log("Gauntlet seam: added scan target \(path)")
    }
}

extension PersonFinderModel {

    /// Called from init's test-host branch (which skips
    /// restoreSessionFromDisk). Creates and saves a POI profile named by
    /// the seam, copying the reference photos into the POI's own folder —
    /// POIProfile.save() always heals referencePath to that folder, so
    /// the photos must physically live there. POIStorage.storeDir is
    /// redirected to a per-process temp dir under test hosts, so this
    /// never touches the real POI store.
    func installGauntletPOIIfRequested() {
        guard let name = GauntletSeams.poiName,
              let refPath = GauntletSeams.poiReferencePath else { return }
        let fm = FileManager.default
        do {
            let profile = POIProfile(name: name, referencePath: refPath)
            try profile.save()
            let destDir = POIStorage.folder(for: name)
            for item in (try? fm.contentsOfDirectory(atPath: refPath)) ?? [] {
                let src = (refPath as NSString).appendingPathComponent(item)
                let dst = destDir.appendingPathComponent(item).path
                if !fm.fileExists(atPath: dst) {
                    try? fm.copyItem(atPath: src, toPath: dst)
                }
            }
            savedProfiles = POIProfile.listAll()
        } catch {
            NSLog("VideoScan: Gauntlet POI seam failed — %@", String(describing: error))
        }
    }
}
