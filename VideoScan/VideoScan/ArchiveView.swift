import SwiftUI

// MARK: - Archive Tab

struct ArchiveView: View {
    @EnvironmentObject var model: VideoScanModel

    @State private var selectedCategory: ArchiveCategory = .unreviewed
    @State private var selectedIDs: Set<UUID> = []
    @State private var searchText: String = ""
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteIDs: Set<UUID> = []
    @State private var showFilter: ArchiveShowFilter = .all
    @State private var sortOrder = [KeyPathComparator(\VideoRecord.filename)]
    @State private var isAnalyzing = false
    @State private var analysisSummary: MediaAnalyzer.AnalysisSummary?
    @State private var showAnalysisSummary = false
    @State private var archiveDetailRecord: VideoRecord?

    var body: some View {
        HSplitView {
            sidebar
                .frame(minWidth: 200, idealWidth: 220, maxWidth: 280)
            fileList
                .frame(minWidth: 500)
        }
        .onAppear {
            handlePendingArchiveNavigation()
            restoreFocusedMedia()
        }
        .onChange(of: model.pendingArchiveSelection) { handlePendingArchiveNavigation() }
        .sheet(item: $archiveDetailRecord) { rec in
            ArchiveDetailSheet(record: rec, allRecords: model.records)
        }
    }

    private func handlePendingArchiveNavigation() {
        guard let id = model.pendingArchiveSelection else { return }
        model.pendingArchiveSelection = nil
        selectedCategory = .allFiles
        showFilter = .all
        searchText = ""
        model.focusedMediaIDs = model.focusSet(for: id)
        selectedIDs = model.focusedMediaIDs
    }

    private func restoreFocusedMedia() {
        guard model.pendingArchiveSelection == nil,
              !model.focusedMediaIDs.isEmpty else { return }
        selectedCategory = .allFiles
        showFilter = .all
        searchText = ""
        selectedIDs = model.focusedMediaIDs
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Archive")
                .font(.title2.weight(.semibold))
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 10)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarRow(.allFiles)

                    Divider().padding(.vertical, 4)

                    sidebarSection("PIPELINE") {
                        sidebarRow(.hasFamily)
                        sidebarRow(.masterSet)
                        sidebarRow(.backedUp)
                        sidebarRow(.ready)
                        sidebarRow(.archived)
                    }

                    Divider().padding(.vertical, 8)

                    sidebarSection("VOLUMES") {
                        ForEach(model.scanTargets, id: \.id) { target in
                            volumeRoleRow(target)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 8)
            }

            Divider()

            // Volume progress summary
            volumeProgressBar
                .padding(12)
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    @ViewBuilder
    private func sidebarSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, 8)
                .padding(.top, 6)
                .padding(.bottom, 2)
            content()
        }
    }

    private func sidebarRow(_ category: ArchiveCategory) -> some View {
        let count = countForCategory(category)
        return Button {
            selectedCategory = category
            selectedIDs = []
            model.focusedMediaIDs = []
        } label: {
            HStack(spacing: 8) {
                Image(systemName: category.icon)
                    .foregroundColor(category.color)
                    .frame(width: 18)
                Text(category.label)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
            .background(
                selectedCategory == category
                    ? Color.accentColor.opacity(0.12)
                    : Color.clear
            )
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .buttonStyle(.plain)
    }

    @Environment(\.openWindow) private var openWindow

    private func volumeRoleRow(_ target: CatalogScanTarget) -> some View {
        let name = VolumeReachability.volumeName(forPath: target.searchPath)
        let fileCount = model.records.filter { $0.fullPath.hasPrefix(target.searchPath) }.count

        return HStack(spacing: 6) {
            VolumeBadge(role: target.role,
                        trust: target.trust,
                        isReachable: target.isReachable)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(target.isReachable ? .primary : .secondary)
                        .lineLimit(1)
                    if !target.isReachable {
                        Text("offline")
                            .font(.system(size: 11))
                            .foregroundColor(.orange)
                    }
                }
                HStack(spacing: 4) {
                    Text("\(fileCount)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    PolicyBadge(policy: target.destinationPolicy)
                        .scaleEffect(0.75, anchor: .leading)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            model.pendingVolumesSelectionID = target.id
            openWindow(id: "volumes")
        }
        .contextMenu {
            Button("Edit Volume…") {
                model.pendingVolumesSelectionID = target.id
                openWindow(id: "volumes")
            }
            Divider()
            Menu("Role") {
                ForEach(VolumeRole.allCases, id: \.self) { role in
                    Button {
                        model.setRole(role, for: target)
                    } label: {
                        HStack {
                            Image(systemName: role.icon)
                            Text(role.rawValue)
                            if target.role == role {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
            Menu("Reliability") {
                ForEach(VolumeTrust.allCases, id: \.self) { trust in
                    Button {
                        model.setTrust(trust, for: target)
                    } label: {
                        HStack {
                            Image(systemName: trust.icon)
                            Text(trust.rawValue)
                            if target.trust == trust {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    private var volumeProgressBar: some View {
        let total = keeperRecords.count
        let fullyArchived = keeperRecords.filter { $0.archiveStage >= .archived }.count
        let backedUp = keeperRecords.filter { $0.archiveStage >= .backedUp }.count
        let pct = total > 0 ? Double(backedUp) / Double(total) : 0

        return VStack(alignment: .leading, spacing: 4) {
            Text("\(total) keepers")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.secondary)
            ProgressView(value: pct)
                .tint(pct >= 1.0 ? .green : .accentColor)
            Text("\(backedUp) backed up · \(fullyArchived) archived")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - File List

    private var fileList: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                Image(systemName: selectedCategory.icon)
                    .foregroundColor(selectedCategory.color)
                Text(selectedCategory.label)
                    .font(.headline)

                Spacer()

                // Show filter
                Picker("Show", selection: $showFilter) {
                    ForEach(ArchiveShowFilter.allCases, id: \.self) { filter in
                        Text(filter.label).tag(filter)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)

                // Analyze
                Menu {
                    Button("Analyze All (\(model.records.count))") {
                        runAnalysis(records: model.records)
                    }
                    if !selectedIDs.isEmpty {
                        Button("Analyze Selected (\(selectedIDs.count))") {
                            let selected = model.records.filter { selectedIDs.contains($0.id) }
                            runAnalysis(records: selected)
                        }
                    }
                } label: {
                    Label(isAnalyzing ? "Analyzing..." : "Analyze", systemImage: "wand.and.stars")
                }
                .menuStyle(.borderedButton)
                .controlSize(.large)
                .disabled(model.records.isEmpty || isAnalyzing)
                .help("Score and classify catalog records using heuristics")

            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            // Analysis summary banner
            if let summary = analysisSummary, showAnalysisSummary {
                analysisBanner(summary)
            }

            Divider()

            // File table
            let rows = filteredRecords
            if rows.isEmpty {
                emptyState
            } else {
                fileTable(rows: rows)
            }
        }
    }

    @ViewBuilder
    private var junkActions: some View {
        if selectedCategory == .suspectedJunk {
            Button("Confirm Selected as Junk") {
                for id in selectedIDs {
                    if let rec = model.records.first(where: { $0.id == id }) {
                        rec.mediaDisposition = .confirmedJunk
                    }
                }
                selectedIDs = []
            }
            .disabled(selectedIDs.isEmpty)
            .buttonStyle(.bordered)

            Button("Keep Selected") {
                for id in selectedIDs {
                    if let rec = model.records.first(where: { $0.id == id }) {
                        rec.mediaDisposition = .important
                    }
                }
                selectedIDs = []
            }
            .disabled(selectedIDs.isEmpty)
            .buttonStyle(.bordered)
        }

        if selectedCategory == .confirmedJunk {
            Button("Delete Selected") {
                pendingDeleteIDs = selectedIDs
                showDeleteConfirm = true
            }
            .disabled(selectedIDs.isEmpty)
            .buttonStyle(.bordered)
            .foregroundColor(.red)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: selectedCategory == .archived ? "checkmark.seal" : "tray")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(emptyMessage)
                .font(.headline)
                .foregroundColor(.secondary)
            Text(emptySubtitle)
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptyMessage: String {
        switch selectedCategory {
        case .allFiles:      return "No keepers yet"
        case .hasFamily:     return "No files with family detected"
        case .archived:      return "Nothing archived yet"
        default:             return "No files in this category"
        }
    }

    private var emptySubtitle: String {
        switch selectedCategory {
        case .allFiles:
            return "Mark files as Important or Recoverable in the Triage tab to see them here."
        case .hasFamily:
            return "Run Person Finder in the People tab to detect family members in your media."
        case .archived:
            return "Promote backed-up keepers to Archived once they have verified 3-2-1 redundancy."
        default:
            return ""
        }
    }

    private func fileTable(rows: [VideoRecord]) -> some View {
        let sorted = rows.sorted(using: sortOrder)
        return Table(sorted, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("") { rec in
                HStack(spacing: 2) {
                    Image(systemName: rec.mediaDisposition.icon)
                        .foregroundColor(rec.mediaDisposition.color)
                    if rec.archiveHealth != .notApplicable {
                        Image(systemName: rec.archiveHealth.icon)
                            .font(.system(size: 9))
                            .foregroundColor(rec.archiveHealth.color)
                    }
                }
                .help(rec.archiveHealth != .notApplicable
                      ? "\(rec.mediaDisposition.rawValue) — \(rec.archiveHealth.label)"
                      : rec.mediaDisposition.rawValue)
            }
            .width(44)

            TableColumn("Filename", value: \.filename) { rec in
                Text(rec.filename)
                    .font(.system(size: 13, design: .monospaced))
                    .foregroundColor(rec.filenameColor)
                    .lineLimit(1)
                    .help(rec.fullPath)
            }
            .width(min: 150, ideal: 250)

            TableColumn("Type", value: \.streamTypeRaw) { rec in
                Text(rec.streamType.rawValue)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 100)

            TableColumn("Duration", value: \.durationSeconds) { rec in
                Text(rec.duration.isEmpty ? "—" : rec.duration)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 60, ideal: 70)

            TableColumn("Size", value: \.sizeBytes) { rec in
                Text(rec.size.isEmpty ? "—" : rec.size)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 60, ideal: 80)

            TableColumn("Volume", value: \.volumeName) { rec in
                Text(rec.volumeName)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            .width(min: 80, ideal: 110)

            TableColumn("Rating") { rec in
                StarRatingView(rating: Binding(
                    get: { rec.starRating },
                    set: { rec.starRating = $0 }
                ))
            }
            .width(min: 60, ideal: 70)

            // Keeper checkmarks
            TableColumn("Lifecycle") { rec in
                lifecycleCheckmarks(rec)
            }
            .width(min: 140, ideal: 180)

            TableColumn("Score", value: \.junkScore) { rec in
                junkScoreCell(rec)
            }
            .width(min: 40, ideal: 50)

            TableColumn("Why") { rec in
                junkReasonsCell(rec)
            }
            .width(min: 120, ideal: 200)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            recordContextMenu(for: ids)
        }
        .alert("Delete Confirmed Junk", isPresented: $showDeleteConfirm) {
            Button("Move to Trash", role: .destructive) {
                deleteConfirmedJunk(ids: pendingDeleteIDs)
                pendingDeleteIDs = []
                selectedIDs = []
            }
            Button("Cancel", role: .cancel) {
                pendingDeleteIDs = []
            }
        } message: {
            let count = pendingDeleteIDs.count
            let bytes = pendingDeleteIDs.compactMap { id in
                model.records.first { $0.id == id }?.sizeBytes
            }.reduce(0, +)
            Text("Delete \(count) file(s) (\(Formatting.humanSize(bytes)))?\n\nLocal files will be moved to Trash. Network files will be permanently deleted.")
        }
    }

    // MARK: - Lifecycle Checkmarks

    private func lifecycleCheckmarks(_ rec: VideoRecord) -> some View {
        HStack(spacing: 3) {
            checkmark("H", passed: rec.archiveStage >= .healthy, help: "Healthy")
            checkmark("M", passed: rec.archiveStage >= .masterAssigned,
                      help: rec.masterLocation.isEmpty ? "Master" : "Master: \(rec.masterLocation)")
            checkmark("B", passed: rec.archiveStage >= .backedUp,
                      help: rec.backupDestinations.isEmpty
                        ? "Backed Up"
                        : "Backed up to: " + rec.backupDestinations.map(\.name).joined(separator: ", "))
            checkmark("R", passed: rec.archiveStage >= .readyForArchive, help: "Ready for Archive")
            checkmark("A", passed: rec.archiveStage >= .archived, help: "Archived")
        }
    }

    private func checkmark(_ letter: String, passed: Bool, help: String) -> some View {
        Text(letter)
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundColor(passed ? .white : .secondary.opacity(0.5))
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 3)
                    .fill(passed ? Color.green : Color.secondary.opacity(0.15))
            )
            .help(help)
    }

    // MARK: - Context Menu

    @ViewBuilder
    private func recordContextMenu(for ids: Set<UUID>) -> some View {
        let recs = ids.compactMap { id in model.records.first { $0.id == id } }
        let count = recs.count

        Section("Disposition") {
            Button {
                for rec in recs { rec.mediaDisposition = .important }
            } label: {
                Label("Mark as Important", systemImage: "star.fill")
            }
            Button {
                for rec in recs { rec.mediaDisposition = .recoverable }
            } label: {
                Label("Mark as Recoverable", systemImage: "wrench.and.screwdriver.fill")
            }
            Button {
                for rec in recs { rec.mediaDisposition = .suspectedJunk }
            } label: {
                Label("Mark as Suspected Junk", systemImage: "exclamationmark.triangle")
            }
            Button {
                for rec in recs { rec.mediaDisposition = .confirmedJunk }
            } label: {
                Label("Confirm as Junk", systemImage: "xmark.circle.fill")
            }
            Button {
                for rec in recs { rec.mediaDisposition = .unreviewed }
            } label: {
                Label("Reset to Unreviewed", systemImage: "arrow.counterclockwise")
            }
        }

        if recs.allSatisfy({ $0.mediaDisposition == .important }) {
            lifecycleAndBackupSections(for: recs)
        }

        Divider()

        Button {
            archiveDetailRecord = recs.first
        } label: {
            Label("Show Archive Details", systemImage: "info.circle")
        }
        .disabled(count != 1)

        Button {
            if let rec = recs.first {
                showInCatalog(rec)
            }
        } label: {
            Label("Show in Catalog", systemImage: "film.stack")
        }
        .disabled(count != 1)

        if let rec = recs.first, rec.pairedWith != nil || rec.pairGroupID != nil {
            Button {
                showPairInCatalog(rec)
            } label: {
                Label("Show Pair in Catalog", systemImage: "link")
            }
        }

        Button {
            if let rec = recs.first {
                NSWorkspace.shared.selectFile(rec.fullPath, inFileViewerRootedAtPath: "")
            }
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        .disabled(count != 1)
    }

    @ViewBuilder
    private func junkScoreCell(_ rec: VideoRecord) -> some View {
        if rec.junkScore > 0 {
            Text("\(rec.junkScore)")
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundColor(rec.junkScore >= 8 ? .red : rec.junkScore >= 5 ? .orange : .yellow)
        } else {
            Text("—")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func junkReasonsCell(_ rec: VideoRecord) -> some View {
        if !rec.junkReasons.isEmpty {
            Text(rec.junkReasons.joined(separator: " · "))
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .lineLimit(2)
                .help(rec.junkReasons.joined(separator: "\n"))
        } else {
            Text("—")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }

    @ViewBuilder
    private func lifecycleAndBackupSections(for recs: [VideoRecord]) -> some View {
        Divider()
        Section("Lifecycle") {
            Button { for rec in recs { rec.archiveStage = .healthy } } label: {
                Label("Mark Healthy", systemImage: "heart.fill")
            }
            Button { for rec in recs { rec.archiveStage = .masterAssigned } } label: {
                Label("Designate as Master", systemImage: "crown.fill")
            }
            Button { for rec in recs { rec.archiveStage = .backedUp } } label: {
                Label("Mark Backed Up", systemImage: "doc.on.doc.fill")
            }
            Button { for rec in recs { rec.archiveStage = .readyForArchive } } label: {
                Label("Mark Ready for Archive", systemImage: "checkmark.seal.fill")
            }
            Button { for rec in recs { rec.archiveStage = .archived } } label: {
                Label("Mark Archived", systemImage: "archivebox.fill")
            }
        }

        Divider()

        Section("Backed Up To") {
            Button {
                let entry = BackupEntry(name: "LTA_Crucial", kind: .local, date: Date())
                for rec in recs { addBackup(rec, entry: entry) }
            } label: {
                Label("LTA_Crucial (Local)", systemImage: "externaldrive.fill")
            }
            Button {
                let entry = BackupEntry(name: "iCloud", kind: .cloud, date: Date())
                for rec in recs { addBackup(rec, entry: entry) }
            } label: {
                Label("iCloud (Cloud)", systemImage: "icloud.fill")
            }
            Button {
                let entry = BackupEntry(name: "Breen's NAS", kind: .offsite, date: Date())
                for rec in recs { addBackup(rec, entry: entry) }
            } label: {
                Label("Breen's NAS (Offsite)", systemImage: "building.2.fill")
            }
        }
    }

    // MARK: - Backup Tracking

    private func addBackup(_ rec: VideoRecord, entry: BackupEntry) {
        // Don't add the same destination twice
        if !rec.backupDestinations.contains(where: { $0.name == entry.name }) {
            rec.backupDestinations.append(entry)
        }
        // Auto-advance archive stage if not already past backedUp
        if rec.archiveStage < .backedUp {
            rec.archiveStage = .backedUp
        }
    }

    // MARK: - Navigate to Catalog

    @AppStorage("selectedTab") private var selectedTab: Int = 0

    private func showInCatalog(_ rec: VideoRecord) {
        model.focusedMediaIDs = model.focusSet(for: rec.id)
        model.pendingCatalogSelection = rec.id
        model.pendingCatalogPairMode = false
        selectedTab = 1
    }

    private func showPairInCatalog(_ rec: VideoRecord) {
        model.focusedMediaIDs = model.focusSet(for: rec.id)
        model.pendingCatalogSelection = rec.id
        model.pendingCatalogPairMode = true
        selectedTab = 1
    }

    // MARK: - Junk Deletion

    private func deleteConfirmedJunk(ids: Set<UUID>) {
        let fm = FileManager.default
        for id in ids {
            guard let rec = model.records.first(where: { $0.id == id }),
                  rec.mediaDisposition == .confirmedJunk else { continue }
            let url = URL(fileURLWithPath: rec.fullPath)
            do {
                // Try Trash first (works on local volumes)
                try fm.trashItem(at: url, resultingItemURL: nil)
            } catch {
                // Network volumes don't support Trash — permanent delete
                try? fm.removeItem(at: url)
            }
            // Remove from catalog
            model.records.removeAll { $0.id == id }
        }
    }

    // MARK: - Analysis

    private func runAnalysis(records: [VideoRecord]) {
        isAnalyzing = true
        DispatchQueue.global(qos: .userInitiated).async {
            let summary = MediaAnalyzer.analyzeAll(records)
            DispatchQueue.main.async {
                analysisSummary = summary
                showAnalysisSummary = true
                isAnalyzing = false
            }
        }
    }

    private func analysisBanner(_ summary: MediaAnalyzer.AnalysisSummary) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
            Text("Analyzed \(summary.total):")
                .font(.system(size: 13, weight: .medium))
            Group {
                Label("\(summary.junkCount) junk", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.orange)
                Label("\(summary.familyCount) family", systemImage: "person.2.fill")
                    .foregroundColor(.blue)
                if summary.recoverableCount > 0 {
                    Label("\(summary.recoverableCount) recoverable", systemImage: "wrench.and.screwdriver.fill")
                        .foregroundColor(.teal)
                }
                Text("\(summary.stillUnreviewed) unclassified")
                    .foregroundColor(.secondary)
                if summary.unchanged > 0 {
                    Text("(\(summary.unchanged) unchanged)")
                        .foregroundColor(.secondary)
                }
            }
            .font(.system(size: 12))
            Spacer()
            Button {
                showAnalysisSummary = false
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Color.green.opacity(0.08))
    }

    // MARK: - Filtering

    /// Base pool: only keepers — files explicitly marked important/recoverable
    /// by the user, or already promoted to the archive pipeline (master+).
    private var keeperRecords: [VideoRecord] {
        model.records.filter {
            $0.mediaDisposition == .important ||
            $0.mediaDisposition == .recoverable ||
            $0.archiveStage >= .masterAssigned
        }
    }

    private var filteredRecords: [VideoRecord] {
        let byCategory: [VideoRecord]
        switch selectedCategory {
        case .allFiles:
            byCategory = keeperRecords
        case .hasFamily:
            byCategory = keeperRecords.filter { $0.mediaDisposition == .important && $0.archiveStage < .masterAssigned }
        case .masterSet:
            byCategory = keeperRecords.filter { $0.archiveStage == .masterAssigned }
        case .backedUp:
            byCategory = keeperRecords.filter { $0.archiveStage == .backedUp }
        case .ready:
            byCategory = keeperRecords.filter { $0.archiveStage == .readyForArchive }
        case .archived:
            byCategory = keeperRecords.filter { $0.archiveStage == .archived }
        default:
            byCategory = keeperRecords
        }

        // Then apply Show filter
        let byShow: [VideoRecord]
        switch showFilter {
        case .all:
            byShow = byCategory
        case .familyCandidates:
            byShow = byCategory.filter { $0.mediaDisposition == .important }
        default:
            byShow = byCategory
        }

        // Then apply search text
        if searchText.isEmpty { return byShow }
        let q = searchText.lowercased()
        return byShow.filter {
            $0.filename.lowercased().contains(q) ||
            $0.fullPath.lowercased().contains(q) ||
            $0.videoCodec.lowercased().contains(q) ||
            $0.notes.lowercased().contains(q)
        }
    }

    private func countForCategory(_ cat: ArchiveCategory) -> Int {
        switch cat {
        case .allFiles:      return keeperRecords.count
        case .hasFamily:     return keeperRecords.filter { $0.mediaDisposition == .important && $0.archiveStage < .masterAssigned }.count
        case .masterSet:     return keeperRecords.filter { $0.archiveStage == .masterAssigned }.count
        case .backedUp:      return keeperRecords.filter { $0.archiveStage == .backedUp }.count
        case .ready:         return keeperRecords.filter { $0.archiveStage == .readyForArchive }.count
        case .archived:      return keeperRecords.filter { $0.archiveStage == .archived }.count
        default:             return 0
        }
    }
}

// MARK: - Archive Category (sidebar items)

enum ArchiveCategory: String, CaseIterable {
    case allFiles      = "allFiles"
    case unreviewed    = "unreviewed"
    case hasFamily     = "hasFamily"
    case recoverable   = "recoverable"
    case masterSet     = "masterSet"
    case backedUp      = "backedUp"
    case ready         = "ready"
    case archived      = "archived"
    case suspectedJunk = "suspectedJunk"
    case confirmedJunk = "confirmedJunk"

    var label: String {
        switch self {
        case .allFiles:      return "All Files"
        case .unreviewed:    return "Unreviewed"
        case .hasFamily:     return "Has Family"
        case .recoverable:   return "Recoverable"
        case .masterSet:     return "Master Set"
        case .backedUp:      return "Backed Up"
        case .ready:         return "Ready for Archive"
        case .archived:      return "Archived"
        case .suspectedJunk: return "Suspected Junk"
        case .confirmedJunk: return "Confirmed Junk"
        }
    }

    var icon: String {
        switch self {
        case .allFiles:      return "tray.full.fill"
        case .unreviewed:    return "circle"
        case .hasFamily:     return "person.2.fill"
        case .recoverable:   return "wrench.and.screwdriver.fill"
        case .masterSet:     return "crown.fill"
        case .backedUp:      return "doc.on.doc.fill"
        case .ready:         return "checkmark.seal.fill"
        case .archived:      return "archivebox.fill"
        case .suspectedJunk: return "exclamationmark.triangle"
        case .confirmedJunk: return "xmark.circle.fill"
        }
    }

    var color: Color {
        switch self {
        case .allFiles:      return .primary
        case .unreviewed:    return .secondary
        case .hasFamily:     return .blue
        case .recoverable:   return .teal
        case .masterSet:     return .purple
        case .backedUp:      return .indigo
        case .ready:         return .mint
        case .archived:      return .green
        case .suspectedJunk: return .orange
        case .confirmedJunk: return .red
        }
    }
}

// MARK: - Show Filter (toolbar segmented control)

enum ArchiveShowFilter: String, CaseIterable {
    case all              = "all"
    case junkOnly         = "junk"
    case familyCandidates = "family"
    case unclassified     = "unclassified"

    var label: String {
        switch self {
        case .all:              return "All"
        case .junkOnly:         return "Junk"
        case .familyCandidates: return "Family"
        case .unclassified:     return "Unclassified"
        }
    }
}

// MARK: - Archive Detail Sheet

struct ArchiveDetailSheet: View {
    let record: VideoRecord
    let allRecords: [VideoRecord]
    @Environment(\.dismiss) private var dismiss

    private var duplicates: [VideoRecord] {
        guard let gid = record.duplicateGroupID else { return [] }
        return allRecords.filter { $0.duplicateGroupID == gid && $0.id != record.id }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: record.archiveHealth.icon)
                    .font(.title2)
                    .foregroundColor(record.archiveHealth.color)
                VStack(alignment: .leading, spacing: 2) {
                    Text(record.filename)
                        .font(.headline)
                    Text(record.fullPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .background(record.archiveHealth.color.opacity(0.08))

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    detailSection("Status") {
                        detailRow("Classification", record.mediaDisposition.rawValue,
                                  icon: record.mediaDisposition.icon, color: record.mediaDisposition.color)
                        detailRow("Rating", record.starRating > 0
                                  ? String(repeating: "\u{2605}", count: record.starRating)
                                  : "Not rated")
                        detailRow("Archive Health", record.archiveHealth.label,
                                  icon: record.archiveHealth.icon, color: record.archiveHealth.color)
                    }

                    detailSection("Media") {
                        detailRow("Stream Type", record.streamType.rawValue)
                        if !record.duration.isEmpty { detailRow("Duration", record.duration) }
                        if !record.size.isEmpty { detailRow("Size", record.size) }
                        if !record.resolution.isEmpty { detailRow("Resolution", record.resolution) }
                        if !record.videoCodec.isEmpty { detailRow("Video Codec", record.videoCodec) }
                        if !record.audioCodec.isEmpty { detailRow("Audio Codec", record.audioCodec) }
                        detailRow("Volume", record.volumeName)
                    }

                    detailSection("Archive Pipeline") {
                        pipelineRow("Healthy", record.archiveStage >= .healthy)
                        pipelineRow("Master Assigned", record.archiveStage >= .masterAssigned,
                                    detail: record.masterLocation.isEmpty ? nil : record.masterLocation)
                        pipelineRow("Backed Up", record.archiveStage >= .backedUp,
                                    detail: record.backupDestinations.isEmpty
                                    ? nil
                                    : record.backupDestinations.map { "\($0.name) (\($0.kind.rawValue))" }.joined(separator: ", "))
                        pipelineRow("Ready for Archive", record.archiveStage >= .readyForArchive)
                        pipelineRow("Archived", record.archiveStage >= .archived)
                    }

                    if !record.notes.isEmpty {
                        detailSection("Notes") {
                            Text(record.notes)
                                .font(.system(size: 13))
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    if !duplicates.isEmpty {
                        detailSection("Copies (\(duplicates.count))") {
                            ForEach(duplicates) { dup in
                                HStack(spacing: 6) {
                                    Image(systemName: VolumeReachability.isReachable(path: dup.fullPath)
                                          ? "externaldrive.fill" : "externaldrive.badge.xmark")
                                        .foregroundColor(VolumeReachability.isReachable(path: dup.fullPath) ? .green : .secondary)
                                        .frame(width: 16)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(dup.filename)
                                            .font(.system(size: 12, weight: .medium))
                                        Text("\(dup.volumeName)\(VolumeReachability.isReachable(path: dup.fullPath) ? "" : " (offline)")")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                    }

                    if record.pairedWith != nil {
                        detailSection("A/V Pair") {
                            if let partner = record.pairedWith {
                                detailRow("Partner", partner.filename)
                                detailRow("Partner Type", partner.streamType.rawValue)
                            }
                        }
                    }
                }
                .padding()
            }
        }
        .frame(width: 480, height: 520)
    }

    @ViewBuilder
    private func detailSection(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
            content()
        }
    }

    private func detailRow(_ label: String, _ value: String,
                           icon: String? = nil, color: Color? = nil) -> some View {
        HStack(spacing: 6) {
            Text(label)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
                .frame(width: 120, alignment: .trailing)
            if let icon = icon {
                Image(systemName: icon)
                    .foregroundColor(color ?? .primary)
                    .frame(width: 16)
            }
            Text(value)
                .font(.system(size: 13, weight: .medium))
            Spacer()
        }
    }

    private func pipelineRow(_ label: String, _ passed: Bool, detail: String? = nil) -> some View {
        HStack(spacing: 6) {
            Image(systemName: passed ? "checkmark.circle.fill" : "circle")
                .foregroundColor(passed ? .green : .secondary.opacity(0.4))
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13, weight: passed ? .medium : .regular))
                .foregroundColor(passed ? .primary : .secondary)
            if let detail = detail {
                Text("— \(detail)")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
            }
            Spacer()
        }
    }
}
