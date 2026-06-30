import Foundation

// MARK: - Catalog Verification + Provenance Backfill
//
// Two related "non-rescan" passes over the catalog:
//   1. verifyCatalog(for:) — confirm files still exist and sizes match
//      for one volume, opportunistically backfilling scanContext on
//      records that predate the provenance fields.
//   2. backfillAllProvenance() — same scanContext backfill but global,
//      no existence/size check (cheaper). Used to populate volume names
//      across legacy records all at once.
//
// Both write `target.status = .scanning` and rely on the scan-lifecycle
// plumbing — that's why updateGlobalScanState is internal, not private.

extension VideoScanModel {

    /// Verify catalog records for a volume without running ffprobe.
    /// Checks provenance, file existence, and size. Backfills missing
    /// scanContext fields (volume name, host, mount type) when the volume
    /// is online — no rescan needed for that.
    func verifyCatalog(for target: CatalogScanTarget) {
        let root = target.searchPath
        let volName = URL(fileURLWithPath: root).lastPathComponent
        let volumeRecords = records.filter { PathScope.contains($0.fullPath, within: root) } // regression: codex C2

        guard !volumeRecords.isEmpty else {
            log("No catalog records for \(volName) — nothing to verify")
            return
        }

        guard VolumeReachability.isReachable(path: root) else {
            var report = CatalogHealthReport(
                volumePath: root, volumeName: volName,
                totalRecords: volumeRecords.count
            )
            report.volumeOffline = true
            report.missingVolumeName = volumeRecords.filter { $0.scanContext.volumeName.isEmpty }.count
            report.missingProvenance = volumeRecords.filter { !$0.scanContext.isPopulated }.count
            log(report.summary)
            return
        }

        log("""

        ─────────────────────────────────────────────
        Verifying catalog for \(volName)…
        ─────────────────────────────────────────────
          \(volumeRecords.count) records to check
        """)
        target.status = .scanning
        target.filesFound = volumeRecords.count
        target.filesScanned = 0
        target.startElapsedTimer()
        // Mark this target as verifying so VolumeUIStatus surfaces the
        // "Verifying" badge instead of "Scanning". Target ID set is cleared
        // in the task's final block. (Verify reuses .scanning status because
        // the existing lifecycle plumbing — pause, stop, elapsed timer —
        // assumes it; the badge difference lives only at the view layer.)
        verifyingTargetIDs.insert(target.id)

        // Snapshot the record paths + sizes so the background task can
        // do all the filesystem I/O without touching MainActor state.
        struct RecordSnapshot {
            let index: Int
            let path: String
            let url: URL
            let sizeBytes: Int64
            let needsBackfill: Bool
        }
        let snapshots = volumeRecords.enumerated().map { (i, rec) in
            RecordSnapshot(
                index: i,
                path: rec.fullPath,
                url: URL(fileURLWithPath: rec.fullPath),
                sizeBytes: rec.sizeBytes,
                needsBackfill: rec.scanContext.volumeName.isEmpty || !rec.scanContext.isPopulated
            )
        }
        let totalCount = volumeRecords.count

        target.scanTask = Task {
            struct FileResult {
                let index: Int
                let exists: Bool
                let sizeChanged: Bool
                let needsBackfill: Bool
                var capturedContext: ScanContext?
            }

            // Run all filesystem checks off the main thread.
            let results: [FileResult] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                return snapshots.map { snap in
                    guard fm.fileExists(atPath: snap.path) else {
                        return FileResult(index: snap.index, exists: false,
                                          sizeChanged: false, needsBackfill: false)
                    }
                    let attrs = try? fm.attributesOfItem(atPath: snap.path)
                    let diskSize = (attrs?[.size] as? Int64) ?? 0
                    let changed = snap.sizeBytes > 0 && diskSize > 0 && diskSize != snap.sizeBytes
                    var ctx: ScanContext?
                    if !changed && snap.needsBackfill {
                        ctx = ScanContext.capture(for: snap.url)
                    }
                    return FileResult(index: snap.index, exists: true,
                                      sizeChanged: changed,
                                      needsBackfill: snap.needsBackfill,
                                      capturedContext: ctx)
                }
            }.value

            // Apply results back on MainActor.
            var report = CatalogHealthReport(
                volumePath: root, volumeName: volName, totalRecords: totalCount
            )
            var backfillCount = 0
            let milestones = Set([10, 25, 50, 75, 90])
            var loggedMilestones: Set<Int> = []

            for (i, result) in results.enumerated() {
                if !result.exists {
                    report.filesDeleted += 1
                } else if result.sizeChanged {
                    report.sizeChanged += 1
                } else {
                    if let ctx = result.capturedContext {
                        volumeRecords[result.index].scanContext = ctx
                        backfillCount += 1
                    }
                    report.healthy += 1
                }

                let done = i + 1
                target.filesScanned = done
                let pct = done * 100 / totalCount
                if milestones.contains(pct) && !loggedMilestones.contains(pct) {
                    loggedMilestones.insert(pct)
                    self.log("  [\(volName)] \(done)/\(totalCount) (\(pct)%) — \(report.filesDeleted) deleted, \(backfillCount) backfilled")
                }
            }

            let elapsed = target.elapsedSecs

            report.provenanceBackfilled = backfillCount
            report.missingVolumeName = volumeRecords.filter { $0.scanContext.volumeName.isEmpty }.count
            report.missingProvenance = volumeRecords.filter { !$0.scanContext.isPopulated }.count

            if backfillCount > 0 { self.saveCatalogDebounced() }

            target.stopElapsedTimer()
            target.status = .complete
            self.verifyingTargetIDs.remove(target.id)
            self.updateGlobalScanState()

            self.log(report.summary)
            self.log("  Completed in \(String(format: "%.1f", elapsed))s")

            if report.isHealthy || (report.issues == 0 && backfillCount > 0) {
                appLog.write("Verified \(volName): \(totalCount) records healthy, \(backfillCount) backfilled (\(String(format: "%.1f", elapsed))s)")
            } else {
                appLog.write("Verified \(volName): \(report.issues) issue(s) found — \(report.recommendation)")
            }
        }
    }

    /// Backfill scanContext for all catalog records across all volumes.
    /// Quick pass — no ffprobe, just stat + URL resource values per file.
    func backfillAllProvenance() {
        let needsBackfill = records.filter { $0.scanContext.volumeName.isEmpty }
        guard !needsBackfill.isEmpty else {
            log("All records already have volume names — nothing to backfill")
            return
        }

        var byVolume: [String: [(index: Int, rec: VideoRecord)] ] = [:]
        for (i, rec) in needsBackfill.enumerated() {
            let vol = VolumeReachability.volumeName(forPath: rec.fullPath)
            byVolume[vol, default: []].append((i, rec))
        }

        log("""

        ─────────────────────────────────────────────
        Backfilling volume names for \(needsBackfill.count) records
        ─────────────────────────────────────────────
          \(byVolume.count) volume(s) to process
        """)

        struct BackfillSnap {
            let recIndex: Int
            let path: String
            let url: URL
            let vol: String
        }
        var allSnaps: [BackfillSnap] = []
        var volOrder: [(name: String, range: Range<Int>)] = []
        for (vol, entries) in byVolume.sorted(by: { $0.value.count > $1.value.count }) {
            let start = allSnaps.count
            for (_, rec) in entries {
                allSnaps.append(BackfillSnap(
                    recIndex: records.firstIndex(where: { $0 === rec }) ?? 0,
                    path: rec.fullPath,
                    url: URL(fileURLWithPath: rec.fullPath),
                    vol: vol
                ))
            }
            volOrder.append((vol, start..<allSnaps.count))
        }
        let snapshots = allSnaps
        let volumes = volOrder

        isBackfillingProvenance = true
        backfillTask = Task {
            struct BackfillResult {
                let recIndex: Int
                let reachable: Bool
                var capturedContext: ScanContext?
            }

            // Defer-style cleanup: clear the global flag on every exit path
            // — completion, cancellation, exception. `defer` ≈ C++ RAII guard.
            // The outer class is @MainActor so this closure inherits it and
            // the flag write is main-thread-safe.
            defer { self.isBackfillingProvenance = false }

            let startTime = CFAbsoluteTimeGetCurrent()

            let results: [BackfillResult] = await Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                return snapshots.map { snap in
                    guard fm.fileExists(atPath: snap.path) else {
                        return BackfillResult(recIndex: snap.recIndex, reachable: false)
                    }
                    let ctx = ScanContext.capture(for: snap.url)
                    return BackfillResult(recIndex: snap.recIndex, reachable: true, capturedContext: ctx)
                }
            }.value

            var backfilled = 0
            var unreachable = 0

            for vol in volumes {
                var volBackfilled = 0
                var volUnreachable = 0
                for i in vol.range {
                    let r = results[i]
                    if r.reachable, let ctx = r.capturedContext {
                        self.records[r.recIndex].scanContext = ctx
                        volBackfilled += 1
                        backfilled += 1
                    } else if !r.reachable {
                        volUnreachable += 1
                        unreachable += 1
                    }
                }
                if volUnreachable == vol.range.count {
                    self.log("  [\(vol.name)] \(vol.range.count) records — offline/unreachable")
                } else {
                    self.log("  [\(vol.name)] \(volBackfilled)/\(vol.range.count) backfilled\(volUnreachable > 0 ? ", \(volUnreachable) unreachable" : "")")
                }
            }

            let elapsed = CFAbsoluteTimeGetCurrent() - startTime
            if backfilled > 0 { self.saveCatalogDebounced() }

            self.log("""

            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
              Backfill Complete
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
              Updated:     \(backfilled)
              Unreachable: \(unreachable)
              Elapsed:     \(String(format: "%.1f", elapsed))s
            ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
            """)
            appLog.write("Provenance backfill: \(backfilled) updated, \(unreachable) unreachable (\(String(format: "%.1f", elapsed))s)")
        }
    }
}
