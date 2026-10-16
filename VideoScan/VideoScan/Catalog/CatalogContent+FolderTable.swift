// CatalogContent+FolderTable.swift
// Show ▸ Events & Copies as Folders — the Catalog's folder view
// (docs/design/footage_folders_2026_10_16.md §2). A second Table over
// `FootageFolderTableRow` (why: FootageFolderTableRow.swift), drawn
// INSTEAD of the linear one while the option is on; the linear table is
// untouched when it is off.
//
//   ▸ 📁 Thanksgiving 2009          5 files · 2 copies   1:12:30  12.4 GB  Nov 26, 2009  3 archived
//       Thanksgiving_2009.dv        LaCie     V+A  0:41:02 …                       Ready
//       ↳ Thanksgiving_2009.mkv     LaCie     V+A  0:41:02 …   made from it · preservation master
//       = Thanksgiving_2009.dv      SanDisk   V+A  0:41:02 …   copy · byte for byte, SanDisk   (grey)
//       ≈ Pie_contest.mov           LaCie     V+A  0:08:11 …   same event · different footage
//   loose_file.mov                  …
//
// Rows observe ONLY the model's FootageFoldersSnapshot (the display lands
// through `onReceive`, turned into table rows in that event handler); no
// O(records) work in any body. Words, glyphs, colours and spacing live in
// FootageFolderWords.swift.
//
// (Swift extension ≈ C++ partial class via free member functions; the
// cell builders it shares with the linear table live in
// CatalogContent+Table.swift.)

import AppKit
import SwiftUI

extension CatalogContent {

    // MARK: - The Table

    var footageFolderTable: some View {
        Table(folderRows, selection: $selectedIDs, sortOrder: folderSortBinding) {
            TableColumn("Filename", value: \.filename) { row in
                folderNameCell(row)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Volume", value: \.volume) { row in
                if let rec = row.record { volumeCell(rec) } else { folderSummaryText(folderFilesWords(row)) }
            }
            .width(min: 80, ideal: 160)

            TableColumn("Stream", value: \.stream) { row in
                if let rec = row.record { streamCell(rec) } else { folderSummaryText("") }
            }
            .width(min: 90, ideal: 130)

            TableColumn("Duration", value: \.duration) { row in
                if let rec = row.record { durationCell(rec) } else { folderSummaryText(folderDurationWords(row)) }
            }
            .width(min: 65, ideal: 75)

            TableColumn("Resolution", value: \.pixels) { row in
                if let rec = row.record { resolutionCell(rec) } else { folderSummaryText("") }
            }
            .width(min: 80, ideal: 95)

            TableColumn("Codec", value: \.codec) { row in
                if let rec = row.record { codecCell(rec) } else { folderSummaryText("") }
            }
            .width(min: 60, ideal: 80)

            TableColumn("Dossier", value: \.dossier) { row in
                if let rec = row.record { dossierCell(rec) } else { folderSummaryText("") }
            }
            .width(min: 64, ideal: 72)

            TableColumn("Size", value: \.size) { row in
                if let rec = row.record { sizeCell(rec) } else { folderSummaryText(folderSizeWords(row)) }
            }
            .width(min: 60, ideal: 75)

            TableColumn("Date", value: \.date) { row in
                if let rec = row.record { dateCell(rec) } else { folderSummaryText(row.summary?.dateWords ?? "") }
            }
            .width(min: 80, ideal: 100)

            // Same 10-child limit as the linear table: the last four ride in
            // a Group.
            Group {
                TableColumn("Place", value: \FootageFolderTableRow.place) { row in
                    if let rec = row.record { placeCell(rec) } else { folderSummaryText("") }
                }
                .width(min: 80, ideal: 110)

                TableColumn("People", value: \FootageFolderTableRow.people) { row in
                    if let rec = row.record { peopleColumnCell(for: rec) } else { folderSummaryText("") }
                }
                .width(min: 90, ideal: 140)

                TableColumn("Tag") { row in
                    if let rec = row.record { tagColumnCell(for: rec) } else { folderSummaryText(folderArchivedWords(row)) }
                }
                .width(min: 70, ideal: 120)

                TableColumn("Duplicate") { row in
                    if let rec = row.record { duplicateCell(rec) } else { folderSummaryText("") }
                }
                .width(min: 80, ideal: 95)
            }
        }
    }

    /// The shared sort order, seen through the folder table's own row
    /// type. A header click lands in `sortOrder` as a VideoRecord
    /// comparator, so the model, the linear table and the join all follow.
    var folderSortBinding: Binding<[KeyPathComparator<FootageFolderTableRow>]> {
        Binding(
            get: { FootageFolderSort.rowComparators(from: sortOrder) },
            set: { sortOrder = FootageFolderSort.recordComparators(from: $0) })
    }

    // MARK: - Cells

    /// The name cell: chevron + folder glyph + title for a folder; indent +
    /// relation glyph + the real filename cell + muted words for a member;
    /// the plain filename cell for a loose file.
    @ViewBuilder
    func folderNameCell(_ row: FootageFolderTableRow) -> some View {
        if let eventID = row.eventID {
            folderTitleCell(eventID: eventID, title: row.title, selected: selectedIDs.contains(eventID))
        } else if let rec = row.record {
            HStack(spacing: 4) {
                if let relation = row.relation {
                    Spacer().frame(width: FootageFolderWords.memberIndent)
                    Text(relation.glyph ?? " ")
                        .font(FootageFolderWords.glyphFont)
                        .foregroundColor(FootageFolderWords.relationColor)
                        .frame(width: 12)
                }
                recordFilenameCell(rec, dimmed: row.relation?.isCopy ?? false)
                if let words = row.relation?.words {
                    Text(words)
                        .font(FootageFolderWords.relationFont)
                        .foregroundColor(FootageFolderWords.relationColor)
                        .lineLimit(1)
                        .layoutPriority(-1)
                }
            }
        }
    }

    private func folderTitleCell(eventID: UUID, title: String, selected: Bool) -> some View {
        let open = tableState.openFolderIDs.contains(eventID)
        return HStack(spacing: 4) {
            Button {
                toggleFolder(eventID)
            } label: {
                Image(systemName: open ? FootageFolderWords.chevronOpen : FootageFolderWords.chevronClosed)
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: FootageFolderWords.chevronWidth)
            }
            .buttonStyle(.borderless)
            .help(open ? FootageFolderWords.closeFolder : FootageFolderWords.openFolder)
            .accessibilityIdentifier("catalog.folder.chevron")
            Image(systemName: open ? FootageFolderWords.folderOpenSymbol : FootageFolderWords.folderSymbol)
                .foregroundColor(selected ? .primary : FootageFolderWords.folderTint)
            Text(title)
                .font(.system(.body, design: .default).weight(.medium))
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        .help(FootageFolderWords.folderRowHelp(title))
    }

    /// A record's filename cell with the folder view's one extra: a copy
    /// reads in grey (the dimmed flag), everything else as in the linear table.
    private func recordFilenameCell(_ rec: VideoRecord, dimmed: Bool) -> some View {
        let offline = !VolumeReachability.isReachable(path: rec.fullPath)
        return CatalogFilenameCell(record: rec,
                                   isSelected: selectedIDs.contains(rec.id),
                                   isOffline: offline,
                                   pairTint: showPairsOnly && rec.pairedWith != nil,
                                   tooltip: filenameTooltip(for: rec, offline: offline, purged: rec.isPurged),
                                   dimmed: dimmed)
    }

    private func folderSummaryText(_ text: String) -> some View {
        Text(text)
            .font(FootageFolderWords.summaryFont)
            .foregroundColor(FootageFolderWords.summaryColor)
            .lineLimit(1)
    }

    private func folderFilesWords(_ row: FootageFolderTableRow) -> String {
        guard let s = row.summary else { return "" }
        return FootageFolderWords.filesAndCopies(files: s.files, copies: s.copies)
    }

    private func folderDurationWords(_ row: FootageFolderTableRow) -> String {
        guard let s = row.summary, s.totalSeconds > 0 else { return "" }
        return RelatedLadder.mmss(s.totalSeconds)
    }

    private func folderSizeWords(_ row: FootageFolderTableRow) -> String {
        guard let s = row.summary, s.totalBytes > 0 else { return "" }
        return MediaBytes.display(s.totalBytes)
    }

    private func folderArchivedWords(_ row: FootageFolderTableRow) -> String {
        FootageFolderWords.archived(row.summary?.archivedCount ?? 0)
    }

    // MARK: - Legend and breadcrumb

    /// Under the table while the option is on.
    var footageFolderLegend: some View {
        HStack(spacing: 8) {
            Text(FootageFolderWords.legend)
                .font(FootageFolderWords.legendFont)
                .foregroundColor(.secondary)
                .lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .help(FootageFolderWords.legendHelp)
        .accessibilityIdentifier("catalog.folders.legend")
    }

    /// "‹ All · Thanksgiving 2009" above the table while the list is
    /// scoped to one event or one family — the pair-filter banner's style
    /// (the Catalog's existing focus chip); click or Esc comes back.
    @ViewBuilder
    var footageFolderCrumb: some View {
        if let scope = tableState.folderScope {
            HStack(spacing: 8) {
                Button {
                    setFolderScope(nil)
                } label: {
                    Text(FootageFolderWords.crumb(folderScopeTitle(scope)))
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.plain)
                .help(FootageFolderWords.crumbHelp)
                .accessibilityIdentifier("catalog.folders.crumb")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.accentColor.opacity(0.08))
        }
    }

    private func folderScopeTitle(_ scope: FootageFolders.Scope) -> String {
        switch scope {
        case .event(let id):
            return model.footageFolders.index.folders[id]?.title ?? ""
        case .family(let id):
            return FootageFolderWords.copiesScopeTitle(model.record(forID: id)?.filename ?? "")
        }
    }

    // MARK: - Menus and the double-click

    /// A right-click on a folder row gets the folder's menu; anything
    /// else gets the row menu as always.
    @ViewBuilder
    func tableContextMenu(ids: Set<UUID>) -> some View {
        if showFootageFolders, let folderID = ids.first(where: { tableState.folderIDs.contains($0) }) {
            folderContextMenu(folderID)
        } else {
            rowContextMenu(ids: ids)
        }
    }

    @ViewBuilder
    private func folderContextMenu(_ eventID: UUID) -> some View {
        let open = tableState.openFolderIDs.contains(eventID)
        Button(open ? FootageFolderWords.closeFolder : FootageFolderWords.openFolder) { toggleFolder(eventID) }
        Button(FootageFolderWords.showOnlyThisEvent) { setFolderScope(.event(eventID)) }
    }

    /// Double-click / Return: a folder scopes the list; rows open as always
    /// — only the rows on screen (Return carries the whole selection).
    func tablePrimaryAction(ids: Set<UUID>) {
        if showFootageFolders, let folderID = ids.first(where: { tableState.folderIDs.contains($0) }) {
            setFolderScope(.event(folderID))
            return
        }
        openRows(ids: displayedIDs(among: ids), gesture: "double-click")
    }

    /// The row menu's two folder items (the `find` group), only while the
    /// option is on: a file in an event → "Show in its event"; a file
    /// with no event → "Show Copies & Related…" (greyed when it has none).
    @ViewBuilder
    func footageFolderItems(rec: VideoRecord) -> some View {
        if showFootageFolders {
            let index = model.footageFolders.index
            if let eventID = index.folderOf[rec.id] {
                Button(FootageFolderWords.showInItsEvent) {
                    tableState.openFolderIDs.insert(eventID)
                    setFolderScope(.event(eventID))
                    selectedIDs = [rec.id]
                }
                .accessibilityIdentifier("catalog.row.showInItsEvent")
            } else {
                Button(FootageFolderWords.showCopiesAndRelated) {
                    setFolderScope(.family(rec.id))
                    selectedIDs = [rec.id]
                }
                .disabled(index.family(of: rec.id) == nil)
                .help(index.family(of: rec.id) == nil ? "No copies or versions of this file are in the catalog." : "Just this file with its copies and the versions made from it.")
                .accessibilityIdentifier("catalog.row.showCopiesAndRelated")
            }
        }
    }

    // MARK: - State changes (open set, scope) → one compose

    func toggleFolder(_ eventID: UUID) {
        if tableState.openFolderIDs.contains(eventID) {
            tableState.openFolderIDs.remove(eventID)
        } else {
            tableState.openFolderIDs.insert(eventID)
        }
        refreshFolderDisplay()
    }

    func setFolderScope(_ scope: FootageFolders.Scope?) {
        guard scope != tableState.folderScope else { return }
        tableState.folderScope = scope
        refreshFolderDisplay()
    }

    /// Hand the snapshot what the table shows now. Called from
    /// `refreshRows` (rows changed), the sort change, and every open /
    /// scope change; a repeat request is free. Nothing while the option is off.
    func refreshFolderDisplay() {
        // The mirror, not `showFootageFolders`: the key monitor's closure
        // holds a copy of this view struct from install time, and only
        // the reference box reads live from there.
        guard tableState.folderKeyMirror.isOn else { return }
        model.footageFolders.compose(visible: tableData.map(\.id),
                                     sort: FootageFolderSort.sort(from: sortOrder),
                                     open: tableState.openFolderIDs,
                                     scope: tableState.folderScope)
    }

    /// The display landed: one pass turns it into table rows (record
    /// lookups are O(1) through the model's id index) and publishes the
    /// displayed record ids; then the selection is pruned to what shows.
    /// Event handler, never body.
    func rebuildFolderRows(_ display: FootageFolders.Display) {
        let keysOf = model.footageFolders.index.keysOf
        var rows: [FootageFolderTableRow] = []
        rows.reserveCapacity(display.rows.count)
        var folderIDs = Set<UUID>()
        var recordIDs = Set<UUID>()
        for d in display.rows {
            if let e = d.eventID {
                folderIDs.insert(e)
                rows.append(FootageFolderTableRow(display: d, record: nil,
                                                  keys: model.footageFolders.index.folders[e]?.keys ?? FootageFolders.SortKeys()))
            } else if let id = d.recordID, let rec = model.record(forID: id) {
                // A row the index has not seen yet (a derivative that just
                // landed) still needs its sort facts: one projection.
                recordIDs.insert(id)
                rows.append(FootageFolderTableRow(display: d, record: rec,
                                                  keys: keysOf[id] ?? model.footageFolderRow(rec).keys))
            }
        }
        tableState.folderRows = rows
        tableState.folderIDs = folderIDs
        tableState.folderRecordIDs = recordIDs
        // The empty display is also what `stop()` and a fresh subscription
        // deliver (the pane re-appearing with the option on): nothing is
        // shown yet, so nothing is pruned yet — every action intersects
        // with this (empty) set regardless.
        if tableState.folderKeyMirror.isOn, !display.rows.isEmpty { pruneSelectionToDisplay() }
    }

    /// The option flipped (or the pane appeared / left): tell the model
    /// whether to keep the join warm, and compose or clear.
    func footageFoldersOptionChanged(on: Bool) {
        tableState.folderKeyMirror.isOn = on
        model.setFootageFoldersWanted(on)
        if on {
            refreshFolderDisplay()
        } else {
            tableState.folderScope = nil
            tableState.folderRows = []
            tableState.folderIDs = []
            tableState.folderRecordIDs = []
        }
    }

    // MARK: - Keyboard (→ / ← / Esc) — through the pane's NSEvent monitor

    /// True when the key was ours. Only while the option is on and the
    /// FILES table has the keyboard (the Space rule); bare keys only, so
    /// ⌘← and friends keep their owners. ↑↓ are never touched — the
    /// Table's native row walk (Rick 2026-10-05).
    func handleFolderKey(_ event: NSEvent) -> Bool {
        guard tableState.folderKeyMirror.isOn, spaceShouldToggleLivePreview() else { return false }
        let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask).isSubset(of: [.function, .numericPad])
        guard bare else { return false }
        switch FootageFolderKey(keyCode: event.keyCode) {
        case .open?: return openSelectedFolder()
        case .close?: return closeSelectedFolder()
        case .escape?: return clearFolderScope()
        case nil: return false
        }
    }

    private var singleSelection: UUID? {
        selectedIDs.count == 1 ? selectedIDs.first : nil
    }

    /// → on a folder opens it.
    private func openSelectedFolder() -> Bool {
        guard let id = singleSelection, tableState.folderIDs.contains(id) else { return false }
        guard !tableState.openFolderIDs.contains(id) else { return true }
        tableState.openFolderIDs.insert(id)
        refreshFolderDisplay()
        return true
    }

    /// ← on an open folder closes it; on a member it selects the folder
    /// (the Finder's two-step), so a second ← closes it.
    private func closeSelectedFolder() -> Bool {
        guard let id = singleSelection else { return false }
        if tableState.folderIDs.contains(id) {
            guard tableState.openFolderIDs.contains(id) else { return true }
            tableState.openFolderIDs.remove(id)
            refreshFolderDisplay()
            return true
        }
        guard let parent = model.footageFolders.index.folderOf[id], tableState.folderIDs.contains(parent) else { return false }
        selectedIDs = [parent]
        return true
    }

    /// Esc clears the scope; without one it is not ours.
    private func clearFolderScope() -> Bool {
        guard tableState.folderScope != nil else { return false }
        setFolderScope(nil)
        return true
    }

    // MARK: - A derivative landed: open its source's folder, select, reveal

    /// Transcode / Reformat / Trim / Repair / Clean Up finished and the
    /// catalog took the new row (`VideoScanModel.adoptDerivative`). With
    /// the option on, the source's folder opens and the new row is
    /// selected under it; off, the row is selected in the linear table.
    /// Either way the selection is scrolled into view — but ONLY when the
    /// list can show the row (codex 2026-10-16 P1): a row the filter hides,
    /// or a scope on another event hides, is never selected; the one
    /// console line says where it went. Scoped to the source's own event or
    /// family, the scope is cleared so the row can be shown and selected.
    func revealDerivative(_ landing: DerivativeLanding) {
        refreshRows()
        let name = model.record(forID: landing.id)?.filename ?? landing.id.uuidString
        let source = model.record(forID: landing.sourceID)?.filename ?? landing.sourceID.uuidString
        let plan = DerivativeReveal.plan(landing: landing,
                                         inTable: tableData.contains { $0.id == landing.id },
                                         foldersOn: showFootageFolders,
                                         scope: tableState.folderScope,
                                         index: model.footageFolders.index)
        switch plan {
        case .select:
            selectDerivative(landing)
            model.log(FootageFolderWords.landedSelected(name, source: source))
        case .openScopeAndSelect:
            let scope = tableState.folderScope.map(folderScopeTitle) ?? ""
            setFolderScope(nil)
            selectDerivative(landing)
            model.log(FootageFolderWords.landedScopeCleared(name, source: source, scope: scope))
        case .hiddenByFilter:
            model.log(FootageFolderWords.landedHiddenByFilter(name, source: source))
        case .outsideScope:
            let scope = tableState.folderScope.map(folderScopeTitle) ?? ""
            let place = model.footageFolders.index.folder(containing: landing.sourceID)?.title
            model.log(FootageFolderWords.landedOutsideScope(name, source: source, scope: scope, place: place))
        }
    }

    /// The row can be shown: open the source's folder (option on), select
    /// the new row, scroll to it.
    private func selectDerivative(_ landing: DerivativeLanding) {
        if showFootageFolders, let eventID = model.footageFolders.index.folderOf[landing.sourceID] {
            tableState.openFolderIDs.insert(eventID)
        }
        refreshFolderDisplay()
        selectedIDs = [landing.id]
        CatalogTableReveal.scrollSelectionIntoView()
    }
}

/// Show ▸ Events & Copies as Folders — the menu row itself (its own view
/// so the toolbar's body does not grow a branch per word).
struct FootageFoldersShowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle(isOn: $isOn) {
            Label(FootageFolderWords.showOptionTitle, systemImage: isOn ? "folder.fill" : "folder")
        }
        .help(isOn ? FootageFolderWords.showOptionHelpOn : FootageFolderWords.showOptionHelpOff)
        .accessibilityIdentifier("catalog.show.footageFolders")
    }
}

/// The three folder keys, by virtual key code (kVK_RightArrow,
/// kVK_LeftArrow, kVK_Escape). (≈ a C++ enum class with an explicit
/// converting constructor.)
enum FootageFolderKey {
    case open, close, escape

    init?(keyCode: UInt16) {
        switch keyCode {
        case 124: self = .open
        case 123: self = .close
        case 53: self = .escape
        default: return nil
        }
    }
}
