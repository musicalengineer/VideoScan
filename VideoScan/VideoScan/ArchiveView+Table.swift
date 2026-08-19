import SwiftUI

// MARK: - Archive tab: file list, status cell, context menu
//
// Split from ArchiveView.swift 2026-08-17. Reads the memoized snapshot
// (ArchiveView.snapshot) — the only per-row work here is O(1) index
// lookups (status, relpath) and string joins for the visible rows.

extension ArchiveView {

    // MARK: - File List

    var fileList: some View {
        VStack(spacing: 0) {
            // Toolbar
            HStack(spacing: 10) {
                Image(systemName: selectedCategory.icon)
                    .foregroundColor(selectedCategory.color)
                Text(selectedCategory.label)
                    .font(.headline)

                Spacer()

                TextField("Search", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 180)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

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

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: selectedCategory == .archived ? "checkmark.seal" : "tray")
                .font(.system(size: 43))
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
        if !searchText.isEmpty { return "No matches" }
        switch selectedCategory {
        case .archived:       return "Nothing archived yet"
        case .notYetArchived: return "Everything is archived"
        case .needsDate:      return "Every unarchived file has a date"
        }
    }

    private var emptySubtitle: String {
        if !searchText.isEmpty { return "Try a different search term." }
        switch selectedCategory {
        case .archived:
            return model.masterArchive == nil
                ? "Initialize a Master Archive, then right-click files in the Catalog and choose Promote to Archive."
                : "Right-click files in the Catalog (or under Not Yet Archived here) and choose Promote to Archive."
        case .notYetArchived:
            return "Every active catalog asset has a byte-verified copy in the Master Archive."
        case .needsDate:
            return "Promote will file each of these under its resolved year."
        }
    }

    // MARK: - Table

    private func fileTable(rows: [VideoRecord]) -> some View {
        let sorted = rows.sorted(using: sortOrder)
        return Table(sorted, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                Text(rec.filename)
                    .font(.system(size: 16, design: .monospaced))
                    .foregroundColor(.green)
                    .lineLimit(1)
                    .help(rec.fullPath)
            }
            .width(min: 180, ideal: 280)

            TableColumn("Duration", value: \.durationSeconds) { rec in
                Text(rec.duration.isEmpty ? "—" : rec.duration)
                    .font(.system(size: 15, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            .width(min: 60, ideal: 75)

            // Confirmed → detected → suspected? (Rick 2026-08-17: the old
            // column read only detectedPeople — "people not following").
            TableColumn("People", value: \.peopleSortKey) { rec in
                let text = ArchivePeopleCell.text(for: rec)
                Text(text)
                    .font(.system(size: 15))
                    .foregroundColor(text == "—" ? .secondary : .blue)
                    .lineLimit(1)
                    .help(text)
            }
            .width(min: 80, ideal: 140)

            TableColumn("Archived To") { rec in
                archivedToCell(rec)
            }
            .width(min: 160, ideal: 260)

            TableColumn("Status") { rec in
                statusCell(rec)
            }
            .width(min: 120, ideal: 170)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            recordContextMenu(for: ids)
        } primaryAction: { ids in
            // Double-click / Return on row(s) → smart open (QuickTime when
            // the cataloged codecs guarantee picture+sound, else VLC).
            let recs = ids.compactMap { id in rows.first { $0.id == id } }
            MediaOpener.open(recs)
        }
    }

    /// Archive-relative path of the master copy, or "—".
    private func archivedToCell(_ rec: VideoRecord) -> some View {
        let status = ArchiveCategorySnapshot.status(of: rec, model: model)
        return Group {
            if let rel = status.relPath {
                Text(rel)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(.purple)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rel)
            } else {
                Text("—")
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Status cell (replaces the legacy H M B R A pills)

    private func statusCell(_ rec: VideoRecord) -> some View {
        let status = ArchiveCategorySnapshot.status(of: rec, model: model)
        return HStack(spacing: 4) {
            switch status {
            case .verified:
                Image(systemName: "checkmark.seal.fill").foregroundColor(.green)
                Text(status.label).foregroundColor(.green)
            case .unverified:
                Image(systemName: "seal").foregroundColor(.yellow)
                Text(status.label).foregroundColor(.yellow)
            case .orphanCopy:
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.orange)
                Text(status.label).foregroundColor(.orange)
            case .notArchived:
                Text(status.label).foregroundColor(.secondary)
            }
        }
        .font(.system(size: 14))
        .help(statusHelp(status))
    }

    private func statusHelp(_ status: ArchiveRowStatus) -> String {
        switch status {
        case .verified:
            return "Copied to the Master Archive, re-read and its SHA-256 compared before being recorded."
        case .unverified:
            return "An archive copy exists but no fixity record — cataloged by rescan, not by Promote. Re-promote or verify."
        case .orphanCopy:
            return "This is a Master Archive copy whose source record is no longer in the catalog."
        case .notArchived:
            return "No Master Archive copy yet. Right-click → Promote to Archive."
        }
    }

    // MARK: - Context Menu

    @ViewBuilder
    func recordContextMenu(for ids: Set<UUID>) -> some View {
        let recs = ids.compactMap { model.record(forID: $0) }
        let count = recs.count
        // Promote applies to the not-yet-archived subset of the selection;
        // the plan sheet reports anything else as skipped, so this only
        // gates on "is there anything promotable at all".
        let promotable = recs.filter { model.pfNotYetArchived($0) }

        Button {
            model.requestPromote(recordIDs: promotable.map(\.id))
        } label: {
            Label(promotable.count > 1 ? "Promote \(promotable.count) to Archive" : "Promote to Archive",
                  systemImage: "archivebox.fill")
        }
        .disabled(promotable.isEmpty || model.isReadOnly)

        Divider()

        Button {
            archiveDetailRecord = recs.first
        } label: {
            Label("Show Archive Details", systemImage: "info.circle")
        }
        .disabled(count != 1)

        // File Journey (Rick 2026-08-19): in the archive the journey IS
        // the provenance — origin, repairs, promote, rename — so the
        // timeline belongs on this menu too.
        Button {
            if let rec = recs.first { fileJourneyPayload = model.makeFileJourney(for: rec) }
        } label: {
            Label("Show this file's journey", systemImage: "mappin.and.ellipse")
        }
        .disabled(count != 1)
        .accessibilityIdentifier("archive.row.showJourney")

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

        if let rec = recs.first, count == 1,
           let copy = model.masterArchiveCopy(of: rec) {
            Button {
                NSWorkspace.shared.selectFile(copy.fullPath, inFileViewerRootedAtPath: "")
            } label: {
                Label("Reveal Archive Copy in Finder", systemImage: "archivebox")
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

    // MARK: - Navigate to Catalog

    func showInCatalog(_ rec: VideoRecord) {
        model.focusedMediaIDs = model.focusSet(for: rec.id)
        model.pendingCatalogSelection = rec.id
        model.pendingCatalogPairMode = false
        selectedTab = 1
        MainWindowHelper.shared.openMainWindow()
    }

    func showPairInCatalog(_ rec: VideoRecord) {
        model.focusedMediaIDs = model.focusSet(for: rec.id)
        model.pendingCatalogSelection = rec.id
        model.pendingCatalogPairMode = true
        selectedTab = 1
        MainWindowHelper.shared.openMainWindow()
    }
}
