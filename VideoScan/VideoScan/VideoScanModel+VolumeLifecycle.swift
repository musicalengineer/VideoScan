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
        // A fresh mount is exactly when a RENAMED volume shows up (same
        // UUID, new /Volumes path) — re-run the rename detection so the
        // "Update catalog" badge appears without waiting for a catalog
        // mutation. Debounced/off-main; see +VolumeRenameMigration.
        noteVolumeRenameCandidatesStale()
        // Master Archive follows its volume UUID: a remount at a new path
        // rehomes the designation (docs/archive_promotion_workflow.md §3).
        reresolveMasterArchiveMount()
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
                // An unmount can invalidate a rename candidate (the "new"
                // volume just left) — re-derive so the badge never offers
                // a migration against a volume that isn't there.
                self?.noteVolumeRenameCandidatesStale()
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
        // Guarded removal (2026-07-03): coverage check + >50-record
        // snapshot tripwire + fail-safe degrade — same helper as
        // resetTarget. "Delete Catalog" is explicit, but the multi-select
        // path bypasses the confirmation dialog, and records nested under
        // ANOTHER registered target's root are not this target's to delete.
        let outcome = removeCatalogRecords(underTargetRoot: path, action: "delete catalog")
        // If any of the banner-tracked rows lived on this volume, the
        // banner's Undo would now skip them — drop the banner to avoid the
        // partial-restore confusion.
        clearPurgeUndoState()
        clearCacheForTarget(target)
        persistScanDates()
        saveCatalogNow()
        notifyTargetsChanged()
        log("Deleted \(outcome.removed) catalog record(s) for \(volName).")
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

    // MARK: - Retired-volume catalog cleanup nag (Rick 2026-08-14)
    //
    // A retired volume whose records linger is a trap: the 8/14 incident
    // resurrected 72,503 ancient records for a volume that no longer even
    // exists, because its target still looked live to the launch-time
    // backfill. Rick's design: humans defer cleanup ("drive in a drawer
    // for a while"), so the app nags at BACKUP time — the moment the user
    // is already caring for the catalog — and the prompt PERFORMS the
    // deletion (nag-button pattern: the badge does the fix).

    /// Retired targets that still hold catalog records. One pass over
    /// `records` regardless of target count (checklist: no O(records ×
    /// targets) scans).
    func retiredCatalogCleanupCandidates() -> [(target: CatalogScanTarget, recordCount: Int)] {
        // Retirement currently has two owners (codex #385 / taxonomy
        // proposal): the retire FLOW stamps `retiredAt`, but a user can
        // also set the role chip to Retired by hand and never get a
        // stamp. Rick 2026-08-16: RicksBackups + 500USB were role=Retired
        // with retiredAt=nil, so this nag never fired for them. Honor
        // both until retirement is centralized on retiredAt.
        let retired = scanTargets.filter { $0.isRetired      // covers stamp OR role chip
                                           && $0.phase != .noCatalog
                                           && !$0.searchPath.isEmpty }
        guard !retired.isEmpty else { return [] }
        var counts: [ObjectIdentifier: Int] = [:]
        for r in records {
            for t in retired where r.fullPath.hasPrefix(t.searchPath) {
                counts[ObjectIdentifier(t), default: 0] += 1
                break
            }
        }
        return retired.compactMap { t in
            guard let n = counts[ObjectIdentifier(t)], n > 0 else { return nil }
            return (t, n)
        }
    }

    /// Post-backup nag: list retired volumes still carrying records and
    /// offer to delete their catalogs right here. Recurs at every backup
    /// until the list is empty — deliberate; see header comment.
    func promptRetiredCatalogCleanup() {
        promptRetiredCatalogCleanup(explicit: false)
    }

    /// `explicit: true` = the user chose the menu command, so an empty
    /// candidate list gets a reassuring "nothing to clean up" instead of
    /// silence (silence is right for the backup-time nag).
    func promptRetiredCatalogCleanup(explicit: Bool) {
        let candidates = retiredCatalogCleanupCandidates()
        guard !candidates.isEmpty else {
            if explicit {
                let a = NSAlert()
                a.messageText = "No retired-volume catalogs to clean up"
                a.informativeText = "Every retired volume's catalog entries are already gone. Nothing to do."
                a.addButton(withTitle: "OK")
                a.runModal()
            }
            return
        }

        // One checkbox per retired volume, all ON by default (Rick
        // 2026-08-16): "not sure why they would deselect, but it is most
        // flexible this way" — e.g. keep one volume's entries while a
        // comparison is still in progress.
        let checks: [NSButton] = candidates.map { c in
            let name = VolumeReachability.volumeName(forPath: c.target.searchPath)
            let age: String
            if let r = c.target.retiredAt {
                let days = max(0, Int(Date().timeIntervalSince(r) / 86_400))
                age = days == 0 ? "retired today" : "retired \(days) day\(days == 1 ? "" : "s") ago"
            } else {
                age = "retired"
            }
            let b = NSButton(checkboxWithTitle:
                "\(name) — \(c.recordCount.formatted()) record\(c.recordCount == 1 ? "" : "s"), \(age)",
                target: nil, action: nil)
            b.state = .on
            return b
        }
        let stack = NSStackView(views: checks)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        let width = max(360, checks.map { $0.intrinsicContentSize.width }.max() ?? 0)
        stack.widthAnchor.constraint(greaterThanOrEqualToConstant: width).isActive = true

        let alert = NSAlert()
        alert.messageText = "Remove catalogs from retired volumes"
        alert.informativeText = """
        Removing catalogs of retired volumes improves search and promotes \
        better organization. This removes catalog entries only — the drives \
        themselves are untouched.

        Remove catalogs from retired volumes:
        """
        alert.accessoryView = stack
        // "Not Yet" is the DEFAULT (first) button: a destructive action
        // should never be one accidental Return away. The nag returning at
        // every backup is what applies the pressure, not button order.
        alert.addButton(withTitle: "Not Yet")
        alert.addButton(withTitle: "Remove Catalogs")
        if alert.runModal() == .alertSecondButtonReturn {
            let chosen = zip(candidates, checks).filter { $0.1.state == .on }.map(\.0)
            for c in chosen {
                deleteCatalogForTarget(c.target)
            }
            log("Retired-volume cleanup: removed catalogs for \(chosen.count) of \(candidates.count) volume(s) at prompt.")
        } else {
            log("Retired-volume cleanup deferred — will ask again at next backup (\(candidates.count) volume(s) pending).")
        }
    }
}
