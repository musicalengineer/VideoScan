// PersonFinderView+Helpers.swift
// Action helpers — adding a per-person search, the Search-for-Family
// folder picker, mounted-volume enumeration, recent-path persistence,
// the output/Python/script browse panels, and clip reveal — extracted
// verbatim from PersonFinderView in PersonFinderView.swift
// (refactor 2026-06-24). These members were already internal; nothing
// here needed an access-level change.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

extension PersonFinderView {

    /// Add a search row for a specific person, expanded and ready for volume selection.
    func addJobForPerson(_ profile: POIProfile) {
        model.selectedPersonForNewJobs = profile
        model.addJob()
        if let job = model.jobs.last {
            expandedJobIDs.insert(job.id)
            selectedJobID = job.id
        }
    }

    /// Step 3 entry point. Ask for a folder, then fan a scan across every
    /// saved POI profile against it. Each profile becomes its own ScanJob
    /// running on its own detached Task — engines run in parallel.
    /// Expands the first new job so the user sees activity immediately.
    func browseForFamilyScanFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Pick a folder or volume — every saved person will be scanned in parallel"
        panel.prompt = "Search for Family"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                Self.recordRecentPath(url.path)
                let newJobs = model.startFamilyScan(at: url.path)
                if let first = newJobs.first {
                    expandedJobIDs.insert(first.id)
                    selectedJobID = first.id
                }
            }
        }
    }

    /// Mounted volumes (excluding system volumes) for the volume picker.
    static var mountedVolumes: [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRemovableKey]
        guard let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                               options: [.skipHiddenVolumes]) else { return [] }
        return vols.filter { url in
            // Skip the boot volume (/), system partials, and the app's own
            // RAM-disk scratch volume (network-prefetch plumbing).
            url.path != "/" && !url.path.hasPrefix("/System")
                && !CatalogScanTarget.isScratchVolumePath(url.path)
        }
    }

    /// Recently used search paths, persisted across sessions.
    /// Test hosts never read the user's real recents (the list would leak
    /// Rick's volume names into assertions and vary per machine); instead
    /// the Gauntlet's fixture folder — if injected — is the whole list,
    /// which is how UI tests pick a scan folder without an NSOpenPanel.
    static let recentPathsKey = "PersonFinder.recentSearchPaths"
    static var recentPaths: [String] {
        if TestEnvironment.isTestHost {
            if let seam = GauntletSeams.recentSearchPath { return [seam] }
            return []
        }
        return UserDefaults.standard.stringArray(forKey: recentPathsKey) ?? []
    }
    static func recordRecentPath(_ path: String) {
        // Never WRITE the real prefs plist from a test host
        // (settings-pollution class).
        if TestEnvironment.isTestHost { return }
        var paths = recentPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > 10 { paths = Array(paths.prefix(10)) }
        UserDefaults.standard.set(paths, forKey: recentPathsKey)
    }

    func browseForOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose folder where clips and compiled video will be saved"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.outputDir = url.path
                model.settings.save()
            }
        }
    }

    func browsePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the Python executable (e.g. venv/bin/python)"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.pythonPath = url.path
                model.settings.save()
            }
        }
    }

    func browseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Select the face_recognize.py script"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.recognitionScript = url.path
                model.settings.save()
            }
        }
    }

    func revealClips(for result: ClipResult) {
        let dir = result.outputDir
        if let first = result.clipFiles.first(where: { !$0.isEmpty }) {
            let fullPath = (dir as NSString).appendingPathComponent(first)
            if FileManager.default.fileExists(atPath: fullPath) {
                NSWorkspace.shared.selectFile(fullPath, inFileViewerRootedAtPath: dir)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }
}
