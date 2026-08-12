// CatalogView+ScanTargetsPane.swift
// The catalog's scan-targets pane and the volume-row data pipeline that
// feeds it and the volume Table (volumeTableRows, aggregate cache
// recompute, target lookup/browse/scanned helpers, filtering) —
// extracted verbatim from CatalogView's body in ContentView.swift
// (refactor 2026-06-11). Members the main file or the VolumeTable
// extension reach are internal; the rest are private to this file.

import SwiftUI

extension CatalogView {

    /// Build VolumeRow values from filtered scan targets for the Table.
    var volumeTableRows: [VolumeRow] {
        // Snapshot global activity flags once per table redraw so every row
        // computes its `uiStatus` against the same instant. Without the
        // snapshot a model update mid-loop could flip the meaning of
        // adjacent rows. (Cheap — these are scalar reads.)
        let isCombining = model.isCombining
        let isBackfilling = model.isBackfillingProvenance
        let verifyingIDs = model.verifyingTargetIDs

        let rows = filteredScanTargets.map { target in
            // Pull the file/byte/error/Cmd+I aggregate from the cache. On
            // a cache miss (cold start before the first refresh fires, or
            // a target added since the last refresh) we serve a zeroed
            // placeholder — the next `.onChange` trigger populates it.
            // O(1) per row vs the old O(records) filter.
            let agg = volumeAggregateCache[target.id]
            let isNet = VolumeReachability.isNetworkVolume(path: target.searchPath)

            // Per-target progress, if scan tracking has populated counts.
            // 0/0 → nil (discovery phase), else clamped to 0…1.
            let progress: Double?
            if target.filesFound > 0 {
                progress = min(1.0, Double(target.filesScanned) / Double(target.filesFound))
            } else {
                progress = nil
            }

            let uiStatus = VolumeUIStatus.compute(VolumeUIStatusInputs(
                mountReachable: target.isReachable,
                targetStatus: target.status,
                isCombining: isCombining,
                isBackfilling: isBackfilling,
                isVerifyingThisVolume: verifyingIDs.contains(target.id),
                scanProgress: progress
            ))

            return VolumeRow(
                id: target.id,
                name: VolumeReachability.displayLabel(forPath: target.searchPath),
                path: target.searchPath,
                status: target.status,
                uiStatus: uiStatus,
                files: agg?.files ?? 0,
                errors: agg?.errors ?? 0,
                mediaBytes: agg?.mediaBytes ?? 0,
                phase: target.phase,
                lastScanned: target.lastScannedDate,
                isReachable: target.isReachable,
                isNetwork: isNet,
                catalogStatusText: agg?.catalogStatusText ?? "Loading catalog data…",
                role: target.role,
                trust: target.trust
            )
        }
        // Apply the user-controlled sort. KeyPathComparator is cheap for
        // ~15 rows; no need to memoize. Empty sort order falls back to
        // the natural map order from filteredScanTargets.
        return volumeTableSortOrder.isEmpty
            ? rows
            : rows.sorted(using: volumeTableSortOrder)
    }

    /// Walk the catalog once and bucket records into each volume's
    /// aggregate. Replaces the per-row O(records) filters that used to
    /// dominate `volumeTableRows`. Single pass over `model.records`,
    /// per-record prefix check against every scan target — total work
    /// O(records × targets), done once per records-changed trigger
    /// rather than once per render.
    ///
    /// A record can belong to BOTH the volume it currently lives on AND
    /// the volume it originated from (Bucket-A copy / Bucket-D adoption
    /// rewrites `fullPath` but preserves `originalFullPath`). That
    /// matches the historical filter semantics — the Volumes table
    /// counted those records on the source volume even after migration
    /// — so we preserve the double-count.
    private func recomputeVolumeAggregates() {
        // Toolbar badge counts ride the same triggers — one extra O(n)
        // pass here instead of two per render.
        streamTypeCounts = CatalogStreamTypeCounts.compute(model.records)
        // Catalog-wide storage totals for the pinned TOTAL MEDIA footer.
        // Folded into this existing refresh (rather than getting its own
        // .onChange set) so the two caches can never disagree about
        // which catalog revision they describe.
        //
        // NOTE — deliberate divergence from the Media Size COLUMN: the
        // per-volume aggregates below double-count a migrated record on
        // both its current and its origin volume (see this function's
        // doc comment). The footer counts each record ONCE, because it
        // answers "how many bytes exist", not "what does each volume
        // hold". So on a catalog with migrations the column can sum to
        // slightly MORE than the footer's total. That is correct; the
        // footer is the number to plan a drive purchase against.
        //
        // Reachability comes from the scan targets' already-cached
        // `isReachable` flag — a @Published Bool, NOT a filesystem probe.
        // Deriving it here rather than inside the calculator keeps that
        // function pure (its tests depend on it) and keeps disk I/O out
        // of an O(records) loop.
        let onlineVolumes = Set(
            model.scanTargets
                .filter { $0.isReachable && !$0.searchPath.isEmpty }
                .map { VolumeReachability.volumeName(forPath: $0.searchPath) }
        )
        storageTotals = CatalogStorageTotalsCalculator.compute(
            records: model.records,
            onlineVolumes: onlineVolumes
        )
        // Content-hash backfill plan for the Catalog Options menu. Reuses
        // the SAME cached volume set rather than stat()-ing per record.
        hashBackfillPlan = VideoScanModel.planContentHashBackfill(
            records: model.records,
            isReachable: { onlineVolumes.contains(VolumeReachability.volumeName(forPath: $0)) }
        )
        let targets = model.scanTargets
        guard !targets.isEmpty else {
            volumeAggregateCache = [:]
            return
        }
        // Sort prefixes longest-first so nested target paths
        // (e.g. /Volumes/MyBook AND /Volumes/MyBook/Sub) both match
        // correctly — `hasPrefix` is greedy on this side anyway, but the
        // sort keeps semantics explicit.
        let entries: [(id: UUID, target: CatalogScanTarget, prefix: String)] = targets
            .sorted { $0.searchPath.count > $1.searchPath.count }
            .map { ($0.id, $0, $0.searchPath) }
        var buckets: [UUID: [VideoRecord]] = [:]
        buckets.reserveCapacity(entries.count)
        for r in model.records {
            for e in entries {
                if r.fullPath.hasPrefix(e.prefix)
                    || (r.originalFullPath?.hasPrefix(e.prefix) ?? false) {
                    buckets[e.id, default: []].append(r)
                }
            }
        }
        var built: [UUID: VolumeAggregate] = [:]
        built.reserveCapacity(entries.count)
        for e in entries {
            let recs = buckets[e.id] ?? []
            let errCount = recs.reduce(into: 0) { acc, r in
                if r.streamType == .ffprobeFailed { acc += 1 }
            }
            let bytes = recs.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
            built[e.id] = VolumeAggregate(
                files: recs.count,
                errors: errCount,
                mediaBytes: bytes,
                catalogStatusText: Self.buildCatalogInfo(records: recs, target: e.target)
            )
        }
        volumeAggregateCache = built
    }

    /// Look up the CatalogScanTarget for a VolumeRow ID.
    func target(for id: UUID) -> CatalogScanTarget? {
        model.scanTargets.first { $0.id == id }
    }

    func browsePath(for target: CatalogScanTarget) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a volume or folder to scan"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            Self.applyBrowsedPath(url.path, to: target)
        }
    }

    /// Apply a user-browsed path to an existing target. Extracted from
    /// browsePath so the decision is unit-testable (NSOpenPanel isn't).
    /// This was the ninth ingestion vector (QA 2026-07-08): re-pointing
    /// an existing target was the one remaining path that could smuggle
    /// a scratch entry into `scanTargets` and persisted state — the row
    /// would vanish from every screened list while still being scanned.
    @discardableResult
    static func applyBrowsedPath(_ path: String, to target: CatalogScanTarget) -> Bool {
        guard !CatalogScanTarget.isScratchVolumePath(path) else { return false }
        target.searchPath = path
        return true
    }

    /// Strict-catalog policy predicate. A target counts as "scanned" if either:
    ///   - it has a successful `lastScannedDate`, OR
    ///   - it isn't idle (currently scanning, paused mid-scan, waiting for the
    ///     volume to come back, etc. — i.e. real work in flight).
    /// Note: `CatalogTargetStatus.isIdle` is `true` for `.idle` and
    /// `.resumable`. A resumable target with no last-scan date is treated as
    /// unscanned here — that's intentional, it matches the cleanup predicate
    /// in `VideoScanModel.isUnscannedRemovable`.
    private func hasBeenScanned(_ t: CatalogScanTarget) -> Bool {
        if t.lastScannedDate != nil { return true }
        if !t.status.isIdle { return true }
        return false
    }

    /// Targets that pass the current Volume Options filters.
    /// Always hides the RAM disk (VideoScan_Temp). Also hides "never scanned"
    /// targets unless `showUnscannedTargets` is on — strict-catalog policy.
    private var filteredScanTargets: [CatalogScanTarget] {
        let base = CatalogScanTarget.excludingScratch(model.scanTargets)

        // Strict-catalog default: hide targets that have never been scanned.
        // The user can flip the toggle to see the full list (useful right
        // after adding new targets that haven't been scanned yet).
        let scopedToScanned = showUnscannedTargets
            ? base
            : base.filter { hasBeenScanned($0) }

        // "All Ever Scanned" = show everything within the strict-catalog scope,
        // no further user-filter narrowing.
        if volumeFilters.contains(.allScanned) {
            return scopedToScanned
        }

        return scopedToScanned.filter { target in
            let path = target.searchPath
            // Drive hasRecords/hasBadFiles off the per-volume aggregate cache
            // instead of re-scanning all ~16k records TWICE per target on every
            // render (~640K hasPrefix calls/render before this — the exact cost
            // volumeAggregateCache exists to kill, which had leaked back in
            // here uncached). The cache counts records matching fullPath OR
            // originalFullPath, so an emptied relocate-source volume correctly
            // still "has records" via its origin provenance rather than flipping
            // to "uncataloged". Perf fix 2026-06-20.
            let agg = volumeAggregateCache[target.id]
            let hasRecords = (agg?.files ?? 0) > 0
            let hasBadFiles = (agg?.errors ?? 0) > 0
            let isNetwork = VolumeReachability.isNetworkVolume(path: path)

            // Target passes if ANY active filter matches
            for filter in volumeFilters {
                switch filter {
                case .connected:
                    if target.isReachable { return true }
                case .network:
                    if isNetwork { return true }
                case .allScanned:
                    return true // handled above
                case .uncataloged:
                    if !hasRecords && target.isReachable { return true }
                case .withErrors:
                    if hasBadFiles { return true }
                }
            }
            return false
        }
    }

    // MARK: - Scan Targets Pane (matches PersonFinder's jobsSection pattern)

    var scanTargetsPane: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                // Icon only — the words "Volume Scanner" were a title for
                // a row that already reads as one, and the button beside
                // it now carries the verb (Rick 2026-08-11).
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title3).foregroundColor(.secondary)
                    .padding(.trailing, 4)
                    .help("Volume Scanner")

                Button(action: { model.addScanTarget() }) {
                    Label("Scan Volume…", systemImage: "externaldrive.badge.plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)


                // "Show unscanned" toggle and "Clean up unscanned" button
                // both removed from the toolbar 2026-06-07 per Rick's
                // 14" M5 cleanup pass — they were eating toolbar width
                // for actions Rick doesn't take daily. View → Online is
                // his preferred filter; the underlying `showUnscannedTargets`
                // AppStorage stays so the strict-catalog view persists
                // (off by default), and `cleanupUnscannedTargets()` on
                // the model is still callable from other surfaces if we
                // ever want a "Tools" menu entry.


                ScanOptionsMenu(model: model)

                Button(action: { openWindow(id: "compare") }) {
                    Label("Compare Volumes", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .help("Compare two volumes — show what's unique to the source volume (would be lost if it died). Opens in its own window so a multi-hour rescue copy doesn't block the main UI.")

                // Migrate moved up here from the catalog toolbar
                // (Rick 2026-08-11): it is a VOLUME operation — copy off a
                // flaky drive onto a healthier one — so it belongs beside
                // Compare in the Volume Scanner, not down among the
                // per-record catalog actions.
                Button(action: { showRelocateSheet = true }) {
                    Label("Migrate Volume…", systemImage: "externaldrive.badge.checkmark")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.records.isEmpty)
                .accessibilityIdentifier("catalog.relocate.openSheet")
                .help("Copy catalogued files from a flaky source volume onto a healthier destination and rewrite catalog paths.")

                // Persistent rescue progress chip — only visible when
                // a copy is in flight (or just finished, awaiting ack).
                // Click opens the Compare window. Chip subscribes to
                // VolumeRescueOperation via @EnvironmentObject on its
                // own scope so a rescue tick doesn't re-render
                // ContentView's body.
                RescueToolbarChip()

                Menu {
                    ForEach(VolumeFilter.allCases, id: \.self) { filter in
                        Button(action: { toggleVolumeFilter(filter) }) {
                            HStack {
                                if volumeFilters.contains(filter) {
                                    Image(systemName: "checkmark")
                                }
                                Label(filter.rawValue, systemImage: filter.icon)
                            }
                        }
                    }
                } label: {
                    Label("Volumes", systemImage: "line.3.horizontal.decrease.circle")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Filter which volumes appear in the list below")

                // Volume run controls. These are volume-scanning VERBS, so
                // they belong in the volume group rather than stranded on
                // the far right (Rick 2026-08-12). Divider marks "settings
                // above, execution here" inside the same group.
                Divider().frame(height: 22)

                Button(action: { model.startAllTargets() }) {
                    Label("Scan All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.scanTargets.isEmpty || model.scanTargets.allSatisfy { $0.status.isActive })
                // Gauntlet flows 2/3/4 kick off the fixture scan here. Test-only.
                .accessibilityIdentifier("catalog.scanAll")

                Button(action: {
                    if model.hasPausedTargets { model.resumeAllTargets() } else { model.pauseAllTargets() }
                }) {
                    Label(model.hasPausedTargets ? "Resume All" : "Pause All",
                          systemImage: model.hasPausedTargets ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.hasActiveTargets && !model.hasPausedTargets)

                Button(action: { model.stopAllTargets() }) {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.hasActiveTargets)

                Spacer(minLength: 20)

                // ── CATALOG OPS ────────────────────────────────
                // Everything past the spacer acts on the CATALOG; everything
                // before it acts on VOLUMES (Rick 2026-08-12: "Volume stuff
                // on left, Catalog stuff to the right… things have to fall
                // into one of these categories"). Menu first, then the two
                // housekeeping verbs, then the status chips.
                Menu {
                    Section("Scan") {
                        Button(action: { model.startAllTargets() }) {
                            Label("Scan All Volumes", systemImage: "arrow.clockwise")
                        }
                        .disabled(model.scanTargets.isEmpty)

                        ForEach(model.scanTargets.filter { $0.status.isIdle && $0.isReachable && !$0.isScratchVolume && !$0.isRetired }) { target in
                            Button(action: {
                                if target.status == .resumable {
                                    model.resumeTarget(target)
                                } else {
                                    model.startTarget(target)
                                }
                            }) {
                                Label(VolumeReachability.displayLabel(forPath: target.searchPath),
                                      systemImage: target.status == .resumable ? "arrow.clockwise" : "play.fill")
                            }
                        }
                    }

                    // Content-hash backfill (2026-08-11). Deliberately a
                    // menu item rather than a toolbar button: it is a
                    // once-per-catalog maintenance pass, not a daily verb.
                    //
                    // The LABEL carries the cost — file count and a time
                    // estimate — so clicking is an informed decision rather
                    // than a surprise 20-minute job. A confirm sheet would
                    // be the alternative, but this pass is additive and
                    // interruptible (it only ever writes a hash onto a
                    // record that has none), so the label is enough.
                    Section("Content hashes") {
                        // Read the CACHED plan. Computing it here would be
                        // O(records) inside a view body — and worse, the
                        // reachability probe is filesystem I/O, so it would
                        // stat once per record every time this menu built.
                        let plan = hashBackfillPlan
                        Button {
                            Task { await model.runContentHashBackfill() }
                        } label: {
                            Label(plan.isEmpty
                                  ? "All reachable files hashed"
                                  : "Compute Content Hashes — \(plan.candidates) files, ≈\(Int(plan.estimatedSeconds / 60) + 1) min",
                                  systemImage: "number.square")
                        }
                        .disabled(plan.isEmpty || model.isScanning)
                        .help("Compute the segmented content hash used for safe duplicate detection. Reads 3 MiB per file — no ffprobe, no file is modified. Safe to interrupt and re-run.")

                        if plan.unreachable > 0 {
                            Text("\(plan.unreachable) more need their drives mounted")
                                .font(.caption)
                        }
                        if plan.alreadyHashed > 0 {
                            Text("\(plan.alreadyHashed) already hashed")
                                .font(.caption)
                        }
                    }

                    // Avid bin scanning moved off the catalog toolbar
                    // 2026-08-11. Rick: "I'm not even sure how it works
                    // anymore… if needed, use it, user need not know
                    // unless they go digging." The parser already runs
                    // automatically where it is needed; this stays as the
                    // explicit re-scan for when you DO go digging.
                    Section("Avid bins") {
                        Button(action: { model.scanAvidBins() }) {
                            let clips = model.avidBinResults.reduce(0) { $0 + $1.clips.count }
                            Label(clips > 0
                                  ? "Re-scan Avid Bins (\(model.avidBinResults.count) bins · \(clips) clips)"
                                  : "Scan for Avid Bins",
                                  systemImage: "film.stack")
                        }
                        .disabled(model.isScanning)
                        .help("Scan for Avid .avb bin files and extract clip metadata.")
                    }

                    Section("Delete") {
                        ForEach(model.scanTargets.filter { target in
                            model.records.contains { $0.fullPath.hasPrefix(target.searchPath) || ($0.originalFullPath?.hasPrefix(target.searchPath) ?? false) }
                        }) { target in
                            let count = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) || ($0.originalFullPath?.hasPrefix(target.searchPath) ?? false) }.count
                            Button(role: .destructive, action: {
                                deleteVolumeCatalogTarget = target
                                showDeleteVolumeCatalogConfirm = true
                            }) {
                                Label("\(VolumeReachability.displayLabel(forPath: target.searchPath)) (\(count))",
                                      systemImage: "trash")
                            }
                        }

                        Divider()

                        Button(role: .destructive, action: {
                            showDeleteAllCatalogConfirm = true
                        }) {
                            Label("Delete All (\(model.records.count))", systemImage: "trash.fill")
                        }
                        .disabled(model.records.isEmpty)
                    }
                } label: {
                    Label("Catalog Options", systemImage: "doc.text.magnifyingglass")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Update or delete catalog data")


                Button {
                    showTidySheet = true
                } label: {
                    Label("Tidy Catalog", systemImage: "sparkles")
                }
                .buttonStyle(.bordered)
                .disabled(model.records.isEmpty || model.isScanning)
                .help("Find photos, music, and unmatched audio in the catalog and set them aside (hidden, never deleted). Shows a summary first — nothing happens until you confirm.")

                backupStatusBadge

                // Analysis progress ring, moved up from the catalog row
                // (Rick 2026-08-11 — right-justifying it down there
                // crowded the media-kind label into being clipped).
                DossierToolbarChip(model: model)

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if filteredScanTargets.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: model.scanTargets.isEmpty ? "externaldrive.badge.plus" : "line.3.horizontal.decrease.circle")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text(model.scanTargets.isEmpty ? "No scan volumes yet" : "No volumes match current filters")
                        .font(.headline).foregroundColor(.secondary)
                    Text(model.scanTargets.isEmpty
                         ? "Add volumes manually or use Discover to find mounted drives."
                         : "Try adjusting View filters to see more volumes.")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                volumeTable
            }

            // TOTAL MEDIA — pinned OUTSIDE the table so it never
            // scrolls away (Rick 2026-08-09). Shown even when the
            // filtered table is empty: the totals cover the whole
            // catalog, not the filtered view, so hiding them behind a
            // volume filter would be misleading.
            VolumeTableTotalsFooter(totals: storageTotals,
                                    columnFrames: volumeColumnFrames)
        }
        // Shared coordinate space: the Media Size cell measures itself
        // in it, the footer positions itself in it. Both must name the
        // SAME space or the footer's offsets are relative to nothing.
        .coordinateSpace(name: volumeTableCoordinateSpace)
        .onPreferenceChange(VolumeColumnFramesKey.self) { frames in
            // Guard the assignment: SwiftUI republishes preferences on
            // every layout pass, and an unconditional write would
            // re-render the pane forever.
            if !frames.isEmpty && frames != volumeColumnFrames {
                volumeColumnFrames = frames
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .background(
            // Hidden button gives Cmd-I a global binding on the scan-volumes
            // pane — the context-menu Button's shortcut only fires when the
            // menu is actually open, so this mirrors it for the selected row.
            Button("") { showCatalogInfoForSelection() }
                .keyboardShortcut("i", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        )
        // Per-volume aggregate cache refresh triggers. Keep these here on
        // the pane that consumes the cache so a hidden Catalog tab still
        // refreshes its cache on tab switch via `.onAppear`. Count-based
        // triggers cover the dominant change paths (scan completion,
        // record import, scan-target add/remove, purge). In-place
        // mutation paths that change `fullPath` without changing the
        // overall count (Bucket-D adoption) call
        // `notifyVolumeAggregatesStale()` directly — see below.
        .onAppear { recomputeVolumeAggregates() }
        .onChange(of: model.records.count) { recomputeVolumeAggregates() }
        .onChange(of: model.scanTargets.count) { recomputeVolumeAggregates() }
        .onChange(of: model.lastPurgedBatch) { recomputeVolumeAggregates() }
        .onChange(of: model.volumeAggregatesRevision) { recomputeVolumeAggregates() }
    }

    /// Auto-size the volume pane to fit the toolbar + visible volume rows.
    /// Capped at 400 so it never swallows the entire window; floored at
    /// 3 rows so the table is readable even when filtered down to 1-2
    /// volumes (Rick 2026-06-15 — the prior formula ignored the toolbar
    /// and produced a 92px ideal for 2 volumes, hiding the table behind
    /// the toolbar on every launch).
    var scanTargetsPaneAutoHeight: CGFloat {
        let toolbarHeight: CGFloat = 62      // HStack w/ .controlSize(.large) + 20px vpad
        let tableHeaderHeight: CGFloat = 28
        let perRowHeight: CGFloat = 28
        let bottomMargin: CGFloat = 8
        let displayRowCount = max(CGFloat(volumeTableRows.count), 3)
        let needed = toolbarHeight + tableHeaderHeight
                   + (displayRowCount * perRowHeight) + bottomMargin
                   + VolumeTableTotalsFooter.height
        // Cap raised by the footer's height so pinning TOTAL MEDIA
        // doesn't cost a row of visible volumes at the 400pt ceiling.
        return min(400 + VolumeTableTotalsFooter.height, needed)
    }
}
