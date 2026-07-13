// CatalogView+VolumeTable.swift
// The catalog's volume Table, its context-menu sections, and the backup
// status badge — extracted verbatim from CatalogView's body in
// ContentView.swift (refactor 2026-06-11). A cross-file `extension`
// can't see `private` members, so the CatalogView state/helpers this
// code touches were widened to internal in ContentView.swift
// (single-module app — same visibility in practice). `private` in this
// file means file-private to THIS file.

import SwiftUI

extension CatalogView {

    // MARK: - Volume Table

    // Internal (not private): CatalogView's scanTargetsPane in
    // ContentView.swift embeds this table (and backupStatusBadge below).
    var volumeTable: some View {
        Table(volumeTableRows, selection: $selectedVolumeIDs, sortOrder: $volumeTableSortOrder) {
            // Cells are now plain — no per-cell tap gestures. Double-
            // click to open the editor is handled by the Table's
            // `.contextMenu(forSelectionType:menu:primaryAction:)`
            // modifier below (canonical SwiftUI `Table` equivalent of
            // NSTableView.doubleAction, macOS 13+). Single-click
            // selection stays snappy because `primaryAction` is
            // dispatched independently of selection — no gesture-
            // arbiter tap-count window.
            TableColumn("Volume", value: \VolumeRow.name) { row in
                HStack(spacing: 6) {
                    Text(row.name)
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .foregroundColor(volumeNameColor(for: row))
                        .lineLimit(1)
                        .help(row.path)
                    // Volume-rename indicator/badge. Both branches are O(1)
                    // reads (published id + the model's off-main detection
                    // cache; NO O(records) work in view bodies).
                    //   - migration in flight for THIS row → SpinningRing
                    //     (rotation-based — the only animation style that
                    //     reliably runs on macOS here). Keyed by target id,
                    //     not path: the row's path flips old→new mid-flight.
                    //   - rename detected → the nag badge; the badge IS the
                    //     fix button.
                    if model.volumeRenameMigrationInFlightTargetID == row.id {
                        SpinningRing(color: .orange, size: 12)
                        Text("Updating catalog…")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.orange)
                            .lineLimit(1)
                    } else if let candidate = model.volumeRenameCandidate(for: row.path) {
                        volumeRenameBadge(candidate: candidate, rowID: row.id)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 100, ideal: 150)

            TableColumn("Status") { row in
                // Pill + cycling spinner when a remediation pass is active.
                // See VolumeStatusView.swift / VolumeUIStatus.swift.
                VolumeStatusView(status: row.uiStatus)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 70, ideal: 110)

            TableColumn("Files", value: \VolumeRow.files) { row in
                Text(row.files > 0 ? "\(row.files)" : "—")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Errors") { row in
                Group {
                    if row.errors > 0 {
                        Text("\(row.errors)")
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.red)
                    } else {
                        Text("—")
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 50, ideal: 60)

            TableColumn("Media Size", value: \VolumeRow.mediaBytes) { row in
                Text(row.mediaBytes > 0 ? Self.formatBytesStatic(row.mediaBytes) : "—")
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 70, ideal: 90)

            TableColumn("Scanned", value: \VolumeRow.lastScanned, comparator: OptionalDateComparator()) { row in
                Group {
                    if let date = row.lastScanned {
                        Text(Self.shortDateStatic(date))
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.secondary)
                    } else {
                        Text("—")
                            .font(.system(size: 15, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 75, ideal: 95)

            TableColumn("Phase") { row in
                HStack(spacing: 4) {
                    if row.status.isActive {
                        ProgressView()
                            .controlSize(.small)
                            .scaleEffect(0.7)
                        Text("In Progress")
                            .font(.system(size: 15, weight: .medium))
                    } else if let t = target(for: row.id), t.isRetired {
                        // §1B Retire — a retired volume still has its
                        // catalog (records carry the safe-witness
                        // dispositions or originVolume backfill); the
                        // underlying `phase` enum can stay at whatever
                        // it was, but the user-facing label should
                        // reflect retirement, not "NO CATALOG". A
                        // checkmark.seal reads as "completed/sealed",
                        // matching the lifecycle stage; system purple
                        // signals "preserved historical record" without
                        // the "warning" weight of orange or the "safe
                        // for active use" weight of green.
                        Image(systemName: "checkmark.seal.fill")
                            .font(.system(size: 15))
                        Text("RETIRED")
                            .font(.system(size: 15, weight: .medium))
                    } else {
                        Image(systemName: row.phase.icon)
                            .font(.system(size: 15))
                        Text(row.phase.rawValue)
                            .font(.system(size: 15))
                    }
                }
                .foregroundColor(
                    row.status.isActive
                        ? .orange
                        : (target(for: row.id)?.isRetired == true
                           ? .purple
                           : row.phase.color)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 95, ideal: 115)

            // Role column — shows volume role (Original/Backup/Archive/
            // LTA/etc.) on its own when trust is .reliable or .unknown,
            // and "Role · Trust" when trust is degraded so the user can
            // spot drives that need attention without opening the
            // editor. Trust word inherits VolumeTrust.color so .aging is
            // yellow and .unreliable is red. Sortable on the role's
            // raw value.
            TableColumn("Role", value: \VolumeRow.role.rawValue) { row in
                roleTrustCell(role: row.role, trust: row.trust)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .width(min: 90, ideal: 130)

            TableColumn("") { row in
                HStack(spacing: 6) {
                    if let t = target(for: row.id) {
                        if t.status.isActive {
                            Button(action: { model.togglePauseTarget(t) }) {
                                Image(systemName: t.status.isPaused ? "play.fill" : "pause.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .help(t.status.isPaused ? "Resume" : "Pause")

                            Button(action: { model.stopTarget(t) }) {
                                Image(systemName: "stop.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .help("Stop Scanning")
                        } else if t.status == .resumable {
                            Button(action: { model.resumeTarget(t) }) {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .disabled(!t.isReachable)
                            .help(t.isReachable ? "Resume interrupted scan" : "Volume offline")
                        } else {
                            Button(action: { model.startTarget(t) }) {
                                Image(systemName: "play.fill")
                                    .font(.system(size: 16))
                            }
                            .buttonStyle(.borderless)
                            .disabled(t.searchPath.isEmpty || !t.isReachable)
                            .help(t.isReachable ? "Scan" : "Volume offline")
                        }
                    }
                }
            }
            .width(min: 55, ideal: 70)
        }
        // `primaryAction:` is SwiftUI's canonical equivalent of
        // NSTableView.doubleAction — fires on double-click OR Return
        // when a row is keyboard-focused. Dispatched independently of
        // the Table's selection binding, so single-click selection
        // stays snappy (no gesture-arbiter tap-count window). This
        // replaces the per-cell `.onTapGesture(count: 2)` /
        // `.simultaneousGesture(TapGesture(count: 2))` approaches that
        // both delayed single-click selection by ~250 ms.
        .contextMenu(forSelectionType: UUID.self) { ids in
            volumeContextMenu(for: ids)
        } primaryAction: { ids in
            if let id = ids.first { openVolumesEditor(for: id) }
        }
        .font(.system(size: 14))
    }

    /// Build the migration report for one offline/retired volume and
    /// present the sheet. Pure index-build + lookups over ~16k records
    /// (a few ms) — fine to run synchronously on the menu action.
    private func showMigrationReport(for target: CatalogScanTarget) {
        guard !target.searchPath.isEmpty else { return }
        let report = OnlineCopyFinder(records: model.records).migrationReport(
            volumePathPrefix: target.searchPath,
            isOnline: { VolumeReachability.isReachable(path: $0) },
            volumeLabel: { VolumeReachability.displayLabel(forPath: $0) }
        )
        migrationReportItem = VolumeMigrationItem(
            volumeName: VolumeReachability.displayLabel(forPath: target.searchPath),
            report: report
        )
    }

    /// Open the Volumes editor window with the given scan target pre-selected.
    /// Mirrors the Volume Roles & Archive… context-menu action (volumeContextVolumeSection)
    /// and the VolumeBadge double-click in ArchiveView. Safe if the id no longer
    /// resolves — VolumesWindow keeps whatever selection it had.
    /// (Swift's `private func` on a struct ≈ a C++ member function with file/class linkage.)
    private func openVolumesEditor(for targetID: UUID) {
        model.pendingVolumesSelectionID = targetID
        openWindow(id: "volumes")
    }

    @ViewBuilder
    private func volumeContextMenu(for ids: Set<UUID>) -> some View {
        let targets = ids.compactMap { id in target(for: id) }
        if let first = targets.first {
            let single = targets.count == 1
            volumeContextCatalogSection(targets: targets, first: first, single: single)
            Divider()
            volumeContextPhaseSection(targets: targets, first: first, single: single)
            Divider()
            volumeContextVolumeSection(targets: targets, first: first, single: single)
        }
    }

    @ViewBuilder
    private func volumeContextCatalogSection(
        targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool
    ) -> some View {
        Section("Catalog") {
            if single {
                Button(action: { showCatalogInfo(for: first) }) {
                    Label("Catalog Info", systemImage: "info.circle")
                }
                .keyboardShortcut("i", modifiers: .command)
            }
            Button(action: {
                for t in targets where t.status.isIdle && t.isReachable {
                    if t.status == .resumable {
                        model.resumeTarget(t)
                    } else {
                        model.startTarget(t)
                    }
                }
            }) {
                let hasResumable = targets.contains { $0.status == .resumable }
                Label(hasResumable ? "Resume Scan" : (single ? "Scan / Update Catalog" : "Scan Selected"),
                      systemImage: hasResumable ? "arrow.clockwise" : "arrow.clockwise")
            }
            if single {
                Button(action: { model.verifyCatalog(for: first) }) {
                    Label("Verify Catalog", systemImage: "checkmark.shield")
                }
                .disabled(!first.status.isIdle)
            }
            // Show Migrated — offline/retired volumes only: the verb
            // answers "this disk is gone/parked; is its content safe
            // somewhere else?" An online volume's files ARE the online
            // version, so the report would be noise there.
            if single, first.isRetired || !first.isReachable {
                Button(action: { showMigrationReport(for: first) }) {
                    Label("Show Migrated…",
                          systemImage: "externaldrive.badge.checkmark")
                }
                .help("Report which of this volume's cataloged files have copies on other volumes, and which have no copy anywhere else.")
            }
            if single {
                // Caption Videos — sibling per-target action to "Find
                // Person" (which lives on the People tab). Runs the VLM
                // captioner over every cataloged video on this volume.
                // Disabled when there are no eligible videos so the
                // user gets a hint rather than a confusing no-op.
                let captionableCount = model.records.filter { r in
                    r.fullPath.hasPrefix(first.searchPath) &&
                    (r.streamType == .videoAndAudio || r.streamType == .videoOnly)
                }.count
                Button(action: {
                    showCaptionProgress = true
                    Task {
                        await captionOrchestrator.startCaptioning(target: first, model: model)
                    }
                }) {
                    Label(
                        captionableCount > 0
                            ? "Caption Videos (\(captionableCount))"
                            : "Caption Videos",
                        systemImage: "text.viewfinder"
                    )
                }
                .disabled(captionableCount == 0 || captionOrchestrator.currentStatus.isActive)
                .help(
                    captionableCount == 0
                        ? "No video files on this volume — nothing to caption"
                        : "Run the vision-language model on every video on this volume to generate scene captions"
                )
            }
            // Catalog-wide caption — sweeps every reachable volume in
            // one go. Idempotent: already-captioned records skip
            // through fast. Roadmap item #4.
            let reachableCaptionable = pfCatalogWideCaptionCandidates(
                pfCatalogWideMetadataCandidates(
                    records: model.records,
                    reachableVolumePaths: CatalogScanTarget.analyzeCandidates(model.scanTargets).map { $0.searchPath }
                )
            ).count
            Button(action: {
                showCaptionProgress = true
                Task {
                    await captionOrchestrator.startCatalogWideCaptioning(model: model)
                }
            }) {
                Label(
                    reachableCaptionable > 0
                        ? "Caption All Reachable Volumes (\(reachableCaptionable))"
                        : "Caption All Reachable Volumes",
                    systemImage: "text.viewfinder.rtl"
                )
            }
            .disabled(reachableCaptionable == 0 || captionOrchestrator.currentStatus.isActive)
            .help(
                reachableCaptionable == 0
                    ? "No eligible videos on any reachable volume"
                    : "Run the VLM across every reachable volume — idempotent, can be re-run to pick up new captures"
            )
            // Dossier sweep — three-prompt VLM (date / scene / text)
            // plus Whisper transcription per video, idempotent skip on
            // already-dossiered records. Populates the dossier schema
            // fields (ocrDateCandidates, ocrText, inferredRecordDate)
            // that single-prompt captioning leaves empty.
            Button(action: {
                showCaptionProgress = true
                Task {
                    await captionOrchestrator.startCatalogWideDossier(model: model)
                }
            }) {
                Label(
                    reachableCaptionable > 0
                        ? "Dossier All Reachable Volumes (\(reachableCaptionable))"
                        : "Dossier All Reachable Volumes",
                    systemImage: "doc.text.magnifyingglass"
                )
            }
            .disabled(reachableCaptionable == 0 || captionOrchestrator.currentStatus.isActive)
            .help(
                reachableCaptionable == 0
                    ? "No eligible videos on any reachable volume"
                    : "Run the full dossier (date/scene/text VLM prompts + Whisper transcript) across every reachable volume. ~3× slower than captioning but populates all dossier fields. Idempotent."
            )
            if targets.count > 1 || (single && model.records.contains(where: { $0.scanContext.volumeName.isEmpty })) {
                Button(action: { model.backfillAllProvenance() }) {
                    Label("Backfill All Volume Names", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            Button(role: .destructive, action: {
                if single {
                    deleteVolumeCatalogTarget = first
                    showDeleteVolumeCatalogConfirm = true
                } else {
                    for t in targets { model.deleteCatalogForTarget(t) }
                }
            }) {
                Label("Delete Catalog", systemImage: "trash")
            }
            if targets.contains(where: { $0.status == .complete || $0.status == .stopped || $0.status == .error }) {
                Button(action: {
                    for t in targets { model.resetTarget(t) }
                }) {
                    Label("Reset & Re-probe", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    @ViewBuilder
    private func volumeContextPhaseSection(
        targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool
    ) -> some View {
        Section("Phase") {
            ForEach(VolumePhase.allCases, id: \.self) { phase in
                Button(action: {
                    for t in targets { model.setPhase(phase, for: t) }
                }) {
                    HStack {
                        if single, first.phase == phase {
                            Image(systemName: "checkmark")
                        }
                        Label(phase.rawValue, systemImage: phase.icon)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func volumeContextVolumeSection(
        targets: [CatalogScanTarget], first: CatalogScanTarget, single: Bool
    ) -> some View {
        Section("Volume") {
            Button(action: {
                model.pendingVolumesSelectionID = first.id
                openWindow(id: "volumes")
            }) {
                Label("Volume Roles & Archive…", systemImage: "externaldrive.badge.checkmark")
            }
            if single {
                Button(action: { browsePath(for: first) }) {
                    Label("Browse…", systemImage: "folder")
                }
                .disabled(!first.status.isIdle)
            }
            if targets.contains(where: { !$0.isReachable }) {
                Button(action: {
                    for t in targets where !t.isReachable { model.wakeVolume(t) }
                }) {
                    Label("Wake Volume", systemImage: "bolt.fill")
                }
            }
            // Manual rename fallback: Rick tells us which mounted volume
            // this offline target became; a fingerprint spot-check runs
            // before anything is rewritten (friendly refusal on fail).
            if single, !first.isReachable, !first.isRetired,
               first.searchPath.hasPrefix("/Volumes/") {
                Menu {
                    let choices = manualRenameMountChoices()
                    if choices.isEmpty {
                        Text("No other connected volumes")
                    }
                    ForEach(choices, id: \.self) { root in
                        Button((root as NSString).lastPathComponent) {
                            Task { await model.manualVolumeRenameCheck(for: first, mountedRoot: root) }
                        }
                    }
                } label: {
                    Label("This Volume Was Renamed…", systemImage: "externaldrive.badge.questionmark")
                }
            }
            if targets.contains(where: { $0.isReachable && $0.searchPath.hasPrefix("/Volumes/") }) {
                Button(action: {
                    for t in targets where t.isReachable && t.searchPath.hasPrefix("/Volumes/") {
                        model.ejectVolume(t)
                    }
                }) {
                    Label("Eject", systemImage: "eject.fill")
                }
            }
            Button(role: .destructive, action: {
                for t in targets { model.removeScanTarget(t) }
            }) {
                Label(single ? "Remove from List" : "Remove Selected", systemImage: "minus.circle")
            }
        }
    }

    private func volumeNameColor(for row: VolumeRow) -> Color {
        switch row.status {
        case .scanning, .discovering:  return .green
        case .paused:                  return .cyan
        case .complete:                return .blue
        case .error:                   return .red
        case .stopped:                 return .orange
        case .resumable:               return .purple
        case .waitingForVolume:        return .yellow
        case .idle:                    return .primary
        }
    }

    private static func formatBytesStatic(_ bytes: Int64) -> String {
        let mb: Int64 = 1_048_576
        let gb: Int64 = 1_073_741_824
        let tb: Int64 = 1_099_511_627_776
        if bytes < gb {
            return String(format: "%.1f MB", Double(bytes) / Double(mb))
        } else if bytes < tb {
            return String(format: "%.1f GB", Double(bytes) / Double(gb))
        } else {
            return String(format: "%.2f TB", Double(bytes) / Double(tb))
        }
    }

    private static func shortDateStatic(_ date: Date) -> String {
        let fmt = DateFormatter()
        let cal = Calendar.current
        if cal.component(.year, from: date) == cal.component(.year, from: Date()) {
            fmt.dateFormat = "MMM d"
        } else {
            fmt.dateFormat = "MMM d, yyyy"
        }
        return fmt.string(from: date)
    }

    /// Backup-status pill rendered in the scan-targets header. Color
    /// hints at recency at a glance: green < 7 days, yellow 7–30,
    /// orange > 30, red when never. The pill IS the "back up now"
    /// button — clicking always runs the same Back Up Catalog… flow as
    /// the File menu (the nag is the button). Reveal-in-Finder of the
    /// last backup moved to the right-click context menu.
    @ViewBuilder
    var backupStatusBadge: some View {
        let now = Date()
        let last = model.lastBackupAt
        let path = model.lastBackupPath
        let dayCount = last.map { Int(now.timeIntervalSince($0) / 86_400) }
        let (label, color, icon): (String, Color, String) = {
            guard let last, let dayCount else {
                return ("Never backed up", .red, "externaldrive.badge.exclamationmark")
            }
            let where_ = path.map { Self.shortBackupDest($0) } ?? "?"
            if dayCount < 1 {
                let fmt = DateFormatter()
                fmt.timeStyle = .short
                fmt.dateStyle = .none
                return ("Backed up \(fmt.string(from: last)) → \(where_)",
                        .green, "externaldrive.badge.checkmark")
            } else if dayCount < 7 {
                return ("Backed up \(dayCount)d ago → \(where_)",
                        .green, "externaldrive.badge.checkmark")
            } else if dayCount < 30 {
                return ("Backed up \(dayCount)d ago → \(where_)",
                        .yellow, "externaldrive.badge.checkmark")
            } else {
                return ("Backed up \(dayCount)d ago → \(where_)",
                        .orange, "externaldrive.badge.exclamationmark")
            }
        }()
        Button(action: backupBadgeAction) {
            HStack(spacing: 5) {
                Image(systemName: icon)
                    .font(.system(size: 13))
                Text(label)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
            }
            .foregroundColor(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(color.opacity(0.4), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(color.opacity(0.08))
                    )
            )
        }
        .buttonStyle(.plain)
        .help(backupBadgeTooltip())
        .contextMenu {
            Button("Show Last Backup in Finder") {
                if let p = model.lastBackupPath {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
                }
            }
            .disabled(!lastBackupExistsOnDisk)
        }
    }

    /// True when the last recorded backup bundle is still present on
    /// disk — gates the context-menu reveal so we never point Finder at
    /// a deleted/ejected destination.
    private var lastBackupExistsOnDisk: Bool {
        guard let p = model.lastBackupPath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    private func backupBadgeAction() {
        // Always back up — same single code path as File ▸ Back Up
        // Catalog… (⌘E). A stale badge is a nag; the nag is the button.
        model.exportBundleViaPanel()
    }

    private func backupBadgeTooltip() -> String {
        guard let last = model.lastBackupAt else {
            return "No catalog backup yet. Click to back up now."
        }
        let fmt = DateFormatter()
        fmt.dateStyle = .medium
        fmt.timeStyle = .short
        let where_ = model.lastBackupPath ?? "(unknown location)"
        return "Last backed up \(fmt.string(from: last)) → \(where_)\n\nClick to back up now. Right-click to show the last backup in Finder."
    }

    /// Shorten a bundle path to its containing folder name + ".../leaf",
    /// e.g. "/Users/rickb/iCloud Drive/Backups/VideoScan_…bundle" →
    /// "Backups / VideoScan_…bundle" — enough for the badge to convey
    /// "did this land in iCloud or somewhere else?".
    private static func shortBackupDest(_ path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let leaf = url.lastPathComponent
        let parent = url.deletingLastPathComponent().lastPathComponent
        if parent.isEmpty || parent == "/" { return leaf }
        return "\(parent) / \(leaf)"
    }

    /// "Volume renamed" pill on a scan-target row (nag-button pattern —
    /// same as backupStatusBadge: the badge IS the fix, one verb, one
    /// meaning). Shown when the model's rename detection matched this
    /// offline target's records to a mounted volume (UUID and/or
    /// spot-check — see VolumeRenameCandidate.action). Clicking runs the
    /// catalog migration and raises the informational dialog (with Undo).
    /// Friendly family language — no UUIDs in the label, the identity
    /// proof lives in the tooltip.
    @ViewBuilder
    private func volumeRenameBadge(candidate: VolumeRenameCandidate, rowID: UUID) -> some View {
        Button(action: {
            guard let t = target(for: rowID) else { return }
            Task { await model.userInitiatedVolumeRenameMigration(for: t) }
        }) {
            HStack(spacing: 4) {
                Image(systemName: "externaldrive.badge.questionmark")
                    .font(.system(size: 11))
                Text("\(candidate.oldVolumeName) is now \(candidate.newVolumeName) — Update catalog")
            }
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .foregroundColor(.orange)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .stroke(Color.orange.opacity(0.4), lineWidth: 1)
                    .background(
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.orange.opacity(0.08))
                    )
            )
        }
        .buttonStyle(.plain)
        .disabled(model.volumeRenameMigrationInFlight != nil)
        .help(volumeRenameBadgeTooltip(candidate))
    }

    private func volumeRenameBadgeTooltip(_ c: VolumeRenameCandidate) -> String {
        var text = c.uuidMatched
            ? "The drive now connected as “\(c.newVolumeName)” looks like “\(c.oldVolumeName)” with a new name — it has the same volume ID, and a spot-check of its files matches."
            : "The drive now connected as “\(c.newVolumeName)” looks like “\(c.oldVolumeName)” with a new name — a spot-check found its files at the same places."
        text += "\n\nClick to update the catalog so \(c.matchingRecords) file record(s) follow the new name. Nothing on the drive itself is touched, and a safety copy of the catalog is saved first (you can Undo)."
        if c.mismatchedRecords > 0 {
            text += "\n\n\(c.mismatchedRecords) record(s) under \(c.oldVolumeName) can't be proven to belong to this drive — those will be left alone and reported."
        }
        return text
    }

    // MARK: - Volume-rename dialog pieces (alert lives in ContentView's
    // CatalogView body; helpers are internal so the cross-file extension
    // can reach them)

    /// Alert title per notice kind. Nil notice → "" (alert not shown).
    func volumeRenameNoticeTitle(_ notice: VolumeRenameNotice?) -> String {
        guard let notice else { return "" }
        switch notice.kind {
        case .migrated: return "Volume Renamed"
        case .ask:      return "Was This Volume Renamed?"
        case .refused:  return "That Doesn't Look Like the Same Drive"
        }
    }

    /// Buttons per notice kind. The drift follow-up reuses the EXISTING
    /// per-target rescan verb ("Scan / Update Catalog" — same label as the
    /// row context menu, same startTarget entry point; one verb, one
    /// meaning). Undo restores the pre-migration snapshot verbatim.
    @ViewBuilder
    func volumeRenameNoticeButtons(_ notice: VolumeRenameNotice) -> some View {
        switch notice.kind {
        case .migrated:
            Button("OK") { model.pendingVolumeRenameNotice = nil }
            if notice.driftDetected {
                Button("Scan / Update Catalog") { model.rescanAfterVolumeRename(notice) }
            }
            Button("Undo") { model.undoVolumeRenameMigration(notice) }
        case .ask:
            Button("Update") {
                Task { await model.acceptVolumeRenameAsk(notice) }
            }
            Button("Not Now", role: .cancel) { model.dismissVolumeRenameNotice(notice) }
        case .refused:
            Button("OK") { model.pendingVolumeRenameNotice = nil }
        }
    }

    /// Message per notice kind — Rick's approved wording, plus the honest
    /// footnotes (skipped records, drift).
    func volumeRenameNoticeMessage(_ notice: VolumeRenameNotice) -> String {
        switch notice.kind {
        case .migrated:
            var text = "Volume “\(notice.oldVolumeName)” is now “\(notice.newVolumeName)”. The catalog has been updated to match."
            if notice.mismatchedCount > 0 {
                text += " \(notice.mismatchedCount) record(s) couldn't be proven to belong to this drive and were left alone."
            }
            if notice.driftDetected {
                text += "\n\nSome files on \(notice.newVolumeName) look different since the last scan."
            }
            return text
        case .ask:
            return "It looks like “\(notice.oldVolumeName)” was renamed to “\(notice.newVolumeName)”. Update the catalog?"
        case .refused(let reason):
            return reason
        }
    }

    /// Mounted /Volumes roots offered by the manual "This Volume Was
    /// Renamed…" picker: everything currently mounted that isn't already
    /// a registered target (and isn't our RAM-disk scratch). Reads the
    /// KERNEL mount table only — no disk I/O in the menu builder.
    private func manualRenameMountChoices() -> [String] {
        let targetPaths = Set(model.scanTargets.map { PathScope.normalize($0.searchPath) })
        return VolumeReachability.currentMountedRoots()
            .filter {
                $0.hasPrefix("/Volumes/")
                    && !CatalogScanTarget.isScratchVolumePath($0)
                    && !targetPaths.contains(PathScope.normalize($0))
            }
            .sorted()
    }

    /// One-cell renderer for the Role column. Two flavors:
    ///   - quiet: just the role label in its own color (no trust word)
    ///   - degraded: "Role · Trust" with each word in its color, so a
    ///     glance at the table surfaces drives that need attention
    /// Unassigned + unknown trust renders as the universal "—" so empty
    /// rows don't shout for attention.
    @ViewBuilder
    private func roleTrustCell(role: VolumeRole, trust: VolumeTrust) -> some View {
        if role == .unassigned && (trust == .unknown || trust == .reliable) {
            Text("—")
                .font(.system(size: 14, design: .monospaced))
                .foregroundColor(.secondary)
        } else {
            HStack(spacing: 4) {
                Text(role.rawValue)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(role.color)
                    .lineLimit(1)
                if trust == .aging || trust == .unreliable {
                    Text("·")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                    Text(trust.rawValue)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(trust.color)
                        .lineLimit(1)
                }
            }
        }
    }
}
