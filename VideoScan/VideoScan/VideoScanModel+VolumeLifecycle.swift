import Foundation
import AppKit
import Combine
import UniformTypeIdentifiers

// MARK: - Volume Lifecycle
//
// Mount/unmount observation, wake/eject, and the per-volume catalog
// teardown live together because they all answer the question "what
// happens when a drive comes and goes?" Pulled out of VideoScanModel.swift
// during the 2026-05 size-cap refactor — the model spine no longer needs
// to know that NSWorkspace exists.

extension VideoScanModel {

    /// Synchronous mount-event handler factored out of `installVolumeMountObservers`
    /// so unit tests can exercise the auto-add policy without juggling a real
    /// NSNotificationCenter dispatch and Task hop. The observer block below
    /// just calls this on the main actor.
    ///
    /// Strict-catalog policy: volumes are NEVER auto-added on mount. We only:
    ///   1. Invalidate the reachability cache (drops 5s TTL of stale "offline").
    ///   2. Refresh reachability on every existing target.
    ///   3. Re-check reachability on any existing target whose searchPath sits
    ///      under the newly mounted volume — load-bearing for USB/TB offline
    ///      → online flip without waiting for TTL.
    ///   4. Log a friendly note that the user can use Add Scan Target.
    @MainActor
    func handleVolumeMounted(at volumeURL: URL?) {
        VolumeReachability.invalidateCache()
        VolumeStatsCache.invalidate()   // volume-size memo (preview pane)
        refreshTargetReachability()
        if let url = volumeURL {
            let volumeRoot = url.path
            for t in scanTargets where t.searchPath.hasPrefix(volumeRoot) {
                t.isReachable = VolumeReachability.isReachable(path: t.searchPath)
            }
            log("Volume mounted: \(url.lastPathComponent) (not auto-added — use Add Scan Target to catalog)")
        }
        notifyTargetsChanged()
    }

    /// Listen for drive mount/unmount events so the Scan Target list can
    /// flip its offline indicator without polling. Strict catalog policy:
    /// volumes are NEVER auto-added on mount. The user must explicitly add a
    /// target via `addScanTarget()` (or via a successful scan establishing one).
    /// This prevents random RAM disks, sparse images, and DMGs from polluting
    /// the catalog target list.
    func installVolumeMountObservers() {
        let nc = NSWorkspace.shared.notificationCenter
        let mount = nc.addObserver(
            forName: NSWorkspace.didMountNotification,
            object: nil,
            queue: .main
        ) { [weak self] note in
            // Notification is non-Sendable; pull the userInfo URL out before
            // hopping to the main actor so we don't capture `note` itself.
            let volumeURL = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            Task { @MainActor in
                self?.handleVolumeMounted(at: volumeURL)
            }
        }
        let unmount = nc.addObserver(
            forName: NSWorkspace.didUnmountNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                // Same cache invalidation as the mount handler — a yanked
                // drive needs to flip to offline immediately, not after TTL.
                VolumeReachability.invalidateCache()
                VolumeStatsCache.invalidate()
                self?.refreshTargetReachability()
                self?.notifyTargetsChanged()
            }
        }
        // Background reachability probes never block the UI, which means
        // rows can render before the truth lands. When a probe CHANGES an
        // answer, repaint so stale offline/online indicators get corrected
        // (2026-06-10 regression: defaults rendered once, never refreshed).
        let probeChange = NotificationCenter.default.addObserver(
            forName: VolumeReachability.reachabilityDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshTargetReachability()
                self?.objectWillChange.send()
            }
        }
        mountObservers = [mount, unmount, probeChange]
    }

    /// Re-check whether each scan target's path is currently mounted.
    func refreshTargetReachability() {
        for t in scanTargets {
            let r = VolumeReachability.isReachable(path: t.searchPath)
            if t.isReachable != r { t.isReachable = r }
        }
    }

    /// Attempt to wake/access an offline volume. For network shares this may trigger
    /// automount; for sleeping USB drives it can spin them up. After a brief delay,
    /// re-check reachability and update the target's status.
    func wakeVolume(_ target: CatalogScanTarget) {
        let path = target.searchPath
        let volName = URL(fileURLWithPath: path).lastPathComponent
        log("Attempting to wake \(volName)…")
        Task.detached(priority: .userInitiated) {
            // Strategy 1: open() the volume root — this is what actually triggers
            // macOS disk arbitration to spin up sleeping USB/TB drives and triggers
            // automountd for network shares. fileExists alone only checks the cache.
            let fd = open(path, O_RDONLY | O_NONBLOCK)
            if fd >= 0 { close(fd) }

            // Strategy 2: For network volumes under /Volumes, ask Finder to open
            // the path via NSWorkspace. Finder knows saved credentials and can
            // remount SMB/AFP shares that automountd won't.
            let url = URL(fileURLWithPath: path)
            if path.hasPrefix("/Volumes/") {
                NSWorkspace.shared.open(url)
                // Give Finder a moment to mount the share
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
            }

            await MainActor.run { [weak self] in
                let reachable = VolumeReachability.isReachable(path: path)
                target.isReachable = reachable
                if reachable {
                    self?.log("  \(volName) is now online.")
                } else {
                    self?.log("  \(volName) did not respond — try opening it in Finder.")
                }
                self?.refreshTargetReachability()
                self?.notifyTargetsChanged()
            }
        }
    }

    /// Eject a mounted volume. Uses NSWorkspace to safely unmount and eject.
    func ejectVolume(_ target: CatalogScanTarget) {
        let path = target.searchPath
        // Extract the volume root (e.g. /Volumes/MyDrive)
        let components = path.split(separator: "/", maxSplits: 3)
        guard components.count >= 2, components[0] == "Volumes" else {
            log("Cannot eject — not a /Volumes/ path: \(path)")
            return
        }
        let volumeRoot = "/\(components[0])/\(components[1])"
        let volumeName = String(components[1])
        log("Ejecting \(volumeName)…")
        let url = URL(fileURLWithPath: volumeRoot)
        Task.detached(priority: .userInitiated) {
            do {
                try NSWorkspace.shared.unmountAndEjectDevice(at: url)
                await MainActor.run { [weak self] in
                    self?.log("  \(volumeName) ejected.")
                    target.isReachable = false
                    self?.refreshTargetReachability()
                    self?.notifyTargetsChanged()
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.log("  Failed to eject \(volumeName): \(error.localizedDescription)")
                }
            }
        }
    }

    /// Delete all catalog records for a specific scan target's volume.
    func deleteCatalogForTarget(_ target: CatalogScanTarget) {
        let path = target.searchPath
        let volName = VolumeReachability.volumeName(forPath: path)
        // Reset target state BEFORE touching records so the UI picks up
        // the phase change on the same objectWillChange cycle.
        target.phase = .noCatalog
        target.lastScannedDate = nil
        target.filesFound = 0
        target.filesScanned = 0
        if target.status == .complete || target.status == .stopped || target.status == .error {
            target.status = .idle
        }
        let before = records.count
        records.removeAll { $0.fullPath.hasPrefix(path) }
        let removed = before - records.count
        // If any of the banner-tracked rows lived on this volume, the
        // banner's Undo would now skip them — drop the banner to avoid the
        // partial-restore confusion.
        clearPurgeUndoState()
        clearCacheForTarget(target)
        persistScanDates()
        saveCatalogNow()
        notifyTargetsChanged()
        log("Deleted \(removed) catalog record(s) for \(volName).")
    }

    /// Export volume info as CSV via a save panel.
    ///
    /// Purge policy: removed-from-catalog records are LOCAL-ONLY and never
    /// surface in the exported per-volume stats. Volume counts reflect what
    /// the user actually keeps in the catalog, not the trash bin.
    func exportVolumeInfo() {
        let activeRecords = pfActiveRecords(records)
        let excluded = records.count - activeRecords.count
        // Gather per-volume stats
        var volumePaths = Set<String>()
        for rec in activeRecords {
            let path = rec.fullPath
            if path.hasPrefix("/Volumes/") {
                let parts = path.split(separator: "/", maxSplits: 3)
                if parts.count >= 2 { volumePaths.insert("/Volumes/" + String(parts[1])) }
            }
        }
        // Also include scan targets that may have no records yet
        for t in scanTargets where !t.searchPath.isEmpty {
            volumePaths.insert(t.searchPath)
        }

        var csv = "Volume,Status,Files,Video+Audio,Video Only,Audio Only,Errors,Media Size,Codecs,Containers,Last Scanned\n"

        for vol in volumePaths.sorted() {
            let volRecords = activeRecords.filter { $0.fullPath.hasPrefix(vol) }
            let name = VolumeReachability.volumeName(forPath: vol)
            let target = scanTargets.first { $0.searchPath == vol }
            let status = target?.isReachable == true ? "Connected" : "Offline"
            let total = volRecords.count
            let va = volRecords.filter { $0.streamType == .videoAndAudio }.count
            let vo = volRecords.filter { $0.streamType == .videoOnly }.count
            let ao = volRecords.filter { $0.streamType == .audioOnly }.count
            let failed = volRecords.filter { $0.streamType == .ffprobeFailed }.count
            let bytes = volRecords.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
            let mediaSize = bytes < 1_073_741_824
                ? String(format: "%.1f MB", Double(bytes) / 1_048_576)
                : String(format: "%.1f GB", Double(bytes) / 1_073_741_824)
            let codecs = Set(volRecords.compactMap { $0.videoCodec.isEmpty ? nil : $0.videoCodec }).sorted().joined(separator: "; ")
            let containers = Set(volRecords.compactMap { $0.container.isEmpty ? nil : $0.container }).sorted().joined(separator: "; ")
            let lastScan: String
            if let date = target?.lastScannedDate {
                let fmt = DateFormatter()
                fmt.dateStyle = .medium
                fmt.timeStyle = .short
                lastScan = fmt.string(from: date)
            } else {
                lastScan = ""
            }
            csv += "\"\(name)\",\(status),\(total),\(va),\(vo),\(ao),\(failed),\"\(mediaSize)\",\"\(codecs)\",\"\(containers)\",\"\(lastScan)\"\n"
        }

        let panel = NSSavePanel()
        panel.title = "Export Volume Info"
        panel.nameFieldStringValue = "VideoScan_Volumes.csv"
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try csv.write(to: url, atomically: true, encoding: .utf8)
            if excluded > 0 {
                log("Exported volume info to \(url.lastPathComponent) (\(excluded) removed records excluded)")
            } else {
                log("Exported volume info to \(url.lastPathComponent)")
            }
        } catch {
            log("Export failed: \(error.localizedDescription)")
        }
    }
}
