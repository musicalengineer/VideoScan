// CatalogContent+FolderTable.swift
// Show ▸ Events & Copies as Folders — the Catalog's folder view as a
// two-level Finder (docs/design/footage_folders_2026_10_16.md §2; Rick
// 2026-10-17: "I'd really like it to look like Finder in this view, with
// MarksBirthday, Cape1990, etc, then double-click shows the event
// including copies"). A second Table over `FootageFolderTableRow` (why:
// FootageFolderTableRow.swift), drawn INSTEAD of the linear one while the
// option is on; the linear table is untouched when it is off.
//
//   ‹ Back   Catalog                                   (the breadcrumb bar)
//   ▾ 📁 Marks Birthday 1984        12 items · 3 copies   1:12:30  12.4 GB  Apr 7, 1984 – Apr 8, 1984   3 archived
//        Birthday_1984.dv          LaCie     V+A  0:41:02 …        (the triangle / → reveals in place)
//          ↳ Birthday_1984.mkv     LaCie     V+A  0:41:02 …   made from it · preservation master
//          = Birthday_1984.dv      SanDisk   V+A  0:41:02 …   copy · byte for byte, SanDisk   (grey)
//        ≈ Cake.mov                LaCie     V+A  0:08:11 …   same event · different footage
//   ▸ 📁 Cape 1990                   4 items              0:41:02   6.1 GB  Jul 1990
//     loose_file.mov                LaCie     V+A  0:08:11 …
//       = loose_file.mov            SanDisk   V+A  0:08:11 …   copy · byte for byte, SanDisk   (grey)
//
//   ‹ Back   Catalog ▸ Marks Birthday 1984              (double-click / Return / ⌘↓)
//   Birthday_1984.dv              LaCie     V+A  0:41:02 …                       Ready
//     ↳ Birthday_1984.mkv         LaCie     V+A  0:41:02 …   made from it · preservation master
//     = Birthday_1984.dv          SanDisk   V+A  0:41:02 …   copy · byte for byte, SanDisk   (grey)
//   ≈ Cake.mov                    LaCie     V+A  0:08:11 …   same event · different footage
//
// The top level is the Finder's LIST view (Rick 2026-10-18): each folder
// is a `DisclosureTableRow` whose members are its children; the system
// triangle and indent carry the hierarchy, → / ← twist (the outline
// view's own keys), ⌥-click twists every folder. Which folders are open
// is view state (`expandedFolderIDs`), so the displayed set counts only
// the members on screen. Double-click still drills in; Back, ⌘↑, ←
// (inside a folder) and Esc return to the top with the folder selected
// (the Finder's Enclosing Folder). Rows observe ONLY the model's
// FootageFoldersSnapshot (the display lands through `onReceive`, turned
// into the level and its table rows in that event handler); no
// O(records) work in any body. The level itself is pure
// (FootageFolderLevel.swift); words, glyphs, colours and spacing live in
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
        Table(of: FootageFolderTableRow.self, selection: $selectedIDs, sortOrder: folderSortBinding) {
            folderColumns
        } rows: {
            // A folder with members twists open in place; every other row
            // is a plain row. (A result-builder `if` ≈ a compile-time
            // variant: each branch is its own row type.)
            ForEach(folderRows) { row in
                if let members = row.children {
                    DisclosureTableRow(row, isExpanded: folderExpansion(row.id)) {
                        ForEach(members) { TableRow($0) }
                    }
                } else {
                    TableRow(row)
                }
            }
        }
        .background(FolderChevronStyle(revision: tableState.folderRows.count &+ tableState.expandedFolderIDs.count))
    }

    @TableColumnBuilder<FootageFolderTableRow, KeyPathComparator<FootageFolderTableRow>>
    private var folderColumns: some TableColumnContent<FootageFolderTableRow, KeyPathComparator<FootageFolderTableRow>> {
            TableColumn("Filename", value: \.filename) { row in
                folderNameCell(row)
            }
            .width(min: 180, ideal: 260)

            TableColumn("Volume", value: \.volume) { row in
                if let rec = row.record { volumeCell(rec) } else { folderSummaryText(row.folder?.itemsWords ?? "") }
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
                if let rec = row.record { dateCell(rec) } else { folderSummaryText(row.folder?.dateWords ?? "") }
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

    /// One folder's triangle. ⌥ held (⌥-click, ⌥→ / ⌥←) twists every
    /// folder at once — the Finder's "expand all", which for one level of
    /// folders means every folder.
    private func folderExpansion(_ id: UUID) -> Binding<Bool> {
        Binding(get: { tableState.expandedFolderIDs.contains(id) },
                set: { setFolderExpanded(id, $0, everyFolder: NSEvent.modifierFlags.contains(.option)) })
    }

    /// Twist, then recount what is on screen: a collapsed folder's members
    /// leave the displayed set (and the selection), so ⌘⌫ / Promote can
    /// never reach a row Rick cannot see. Event handler, never body.
    func setFolderExpanded(_ id: UUID, _ open: Bool, everyFolder: Bool = false) {
        let ids: Set<UUID> = everyFolder ? tableState.folderIDs : [id]
        var expanded = tableState.expandedFolderIDs
        if open { expanded.formUnion(ids) } else { expanded.subtract(ids) }
        guard expanded != tableState.expandedFolderIDs else { return }
        tableState.expandedFolderIDs = expanded
        tableState.folderRecordIDs = tableState.folderLevel.recordIDs(expanded: expanded)
        pruneSelectionToDisplay()
    }

    /// The shared sort order, seen through the folder table's own row
    /// type. A header click lands in `sortOrder` as a VideoRecord
    /// comparator, so the model, the linear table and the join all follow
    /// (the loose rows and the members; the folders keep date-then-name).
    var folderSortBinding: Binding<[KeyPathComparator<FootageFolderTableRow>]> {
        Binding(
            get: { FootageFolderSort.rowComparators(from: sortOrder) },
            set: { sortOrder = FootageFolderSort.recordComparators(from: $0) })
    }

    // MARK: - Cells

    /// The name cell: folder glyph + title for a folder; indent + relation
    /// glyph + the real filename cell + muted words for a copy or a
    /// version (≈ gets the glyph without the indent — it is a recording);
    /// the plain filename cell for a recording or a loose file. The
    /// outline's own indent sits outside this cell.
    @ViewBuilder
    func folderNameCell(_ row: FootageFolderTableRow) -> some View {
        if let eventID = row.eventID {
            folderTitleCell(title: row.title, selected: selectedIDs.contains(eventID))
        } else if let rec = row.record {
            HStack(spacing: 4) {
                if let relation = row.relation, let glyph = relation.glyph {
                    Text(glyph)
                        .font(FootageFolderWords.glyphFont)
                        .foregroundColor(FootageFolderWords.relationColor)
                        .frame(width: FootageFolderWords.glyphWidth)
                        .padding(.leading, FootageFolderWords.indent(for: relation))
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

    private func folderTitleCell(title: String, selected: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: FootageFolderWords.folderSymbol)
                .font(FootageFolderWords.folderSymbolFont)
                .foregroundColor(selected ? .primary : FootageFolderWords.folderTint)
            Text(title)
                .font(FootageFolderWords.folderTitleFont)
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

    private func folderDurationWords(_ row: FootageFolderTableRow) -> String {
        guard let f = row.folder, f.totalSeconds > 0 else { return "" }
        return RelatedLadder.mmss(f.totalSeconds)
    }

    private func folderSizeWords(_ row: FootageFolderTableRow) -> String {
        guard let f = row.folder, f.totalBytes > 0 else { return "" }
        return MediaBytes.display(f.totalBytes)
    }

    private func folderArchivedWords(_ row: FootageFolderTableRow) -> String {
        FootageFolderWords.archived(row.folder?.archived ?? 0)
    }

    // MARK: - The breadcrumb bar and the legend

    /// Above the table while the option is on: "‹ Back · Catalog ▸ Marks
    /// Birthday 1984" inside a folder, "Catalog" (Back greyed) at the top.
    @ViewBuilder
    var footageFolderCrumb: some View {
        if showFootageFolders {
            HStack(spacing: 8) {
                Button {
                    leaveFolder()
                } label: {
                    Label(FootageFolderWords.backTitle, systemImage: FootageFolderWords.backSymbol)
                        .font(FootageFolderWords.crumbFont)
                }
                .buttonStyle(.plain)
                .disabled(tableState.folderScope == nil)
                .help(tableState.folderScope == nil ? FootageFolderWords.backHelpAtTop : FootageFolderWords.backHelp)
                .accessibilityLabel(FootageFolderWords.crumb(tableState.folderScope.map(folderScopeTitle) ?? ""))
                .accessibilityIdentifier("catalog.folders.back")
                Text(FootageFolderWords.crumbPath(tableState.folderScope.map(folderScopeTitle)))
                    .font(FootageFolderWords.crumbFont)
                    .lineLimit(1)
                    .accessibilityIdentifier("catalog.folders.crumb")
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Color.accentColor.opacity(0.08))
        }
    }

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
            Button(FootageFolderWords.openFolder) { enterFolder(folderID) }
        } else {
            rowContextMenu(ids: ids)
        }
    }

    /// Double-click / Return: a folder opens (the Finder); rows open as
    /// always — only the rows on screen (Return carries the whole selection).
    func tablePrimaryAction(ids: Set<UUID>) {
        if showFootageFolders, let folderID = ids.first(where: { tableState.folderIDs.contains($0) }) {
            enterFolder(folderID)
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

    // MARK: - Moving between the levels → one compose

    /// Into a folder: the level is that event's members.
    func enterFolder(_ eventID: UUID) {
        setFolderScope(.event(eventID))
    }

    /// Up to the top, with the folder just left selected (the Finder's
    /// Enclosing Folder). Nothing to do at the top.
    func leaveFolder() {
        guard let scope = tableState.folderScope else { return }
        setFolderScope(nil)
        if case .event(let id) = scope { selectedIDs = [id] }
    }

    func setFolderScope(_ scope: FootageFolders.Scope?) {
        guard scope != tableState.folderScope else { return }
        tableState.folderScope = scope
        tableState.pendingReveal = nil   // Rick moved: a waiting reveal is stale
        refreshFolderDisplay()
    }

    /// Hand the snapshot what the table shows now. Called from
    /// `refreshRows` (rows changed), the sort change, and every level
    /// change; a repeat request is free. Nothing while the option is off.
    /// The top is composed with EVERY folder open, so each folder row
    /// arrives with its members for the triangle (which ones show is the
    /// table's `expandedFolderIDs`); a scope shows one folder's members
    /// (the join's event scope, where `open` is not read).
    func refreshFolderDisplay() {
        // The mirror, not `showFootageFolders`: the key monitor's closure
        // holds a copy of this view struct from install time, and only
        // the reference box reads live from there.
        guard tableState.folderKeyMirror.isOn else { return }
        model.footageFolders.compose(visible: tableData.map(\.id),
                                     sort: FootageFolderSort.sort(from: sortOrder),
                                     open: folderComposeOpenSet,
                                     scope: tableState.folderScope)
    }

    /// Every folder the join knows, at the top; nothing inside a scope.
    /// O(folders).
    private var folderComposeOpenSet: Set<UUID> {
        tableState.folderScope == nil ? Set(model.footageFolders.index.folders.keys) : []
    }

    /// A new join recomposes under the LAST request, whose open set may
    /// predate the join's folders (the first index of all, a newly
    /// confirmed event): ask again so every folder carries its members.
    private var folderRequestIsStale: Bool {
        guard let request = model.footageFolders.request else { return false }
        return request.open != folderComposeOpenSet
    }

    /// The display landed: the level is derived (pure, O(rows)) and one
    /// pass turns it into table rows (record lookups are O(1) through the
    /// model's id index) and publishes the displayed record ids; then the
    /// selection is pruned to what shows and a waiting reveal completes.
    /// A folder the join no longer has (merged, dismissed) sends the
    /// table back to the top. Event handler, never body.
    func rebuildFolderRows(_ display: FootageFolders.Display) {
        let index = model.footageFolders.index
        if tableState.folderKeyMirror.isOn, let scope = tableState.folderScope, !FootageFolderLevel.exists(scope, in: index) {
            setFolderScope(nil)   // nothing to re-select; the top level's compose is on its way
            return
        }
        if tableState.folderKeyMirror.isOn, folderRequestIsStale { refreshFolderDisplay() }   // its display follows
        let level = FootageFolderLevel.level(scope: tableState.folderScope, index: index, display: display)
        tableState.folderLevel = level
        tableState.folderRows = folderTableRows(level, index: index)
        tableState.folderIDs = level.folderIDs
        tableState.folderRecordIDs = level.recordIDs(expanded: tableState.expandedFolderIDs)
        // The empty display is also what `stop()` and a fresh subscription
        // deliver (the pane re-appearing with the option on): nothing is
        // shown yet, so nothing is pruned yet — every action intersects
        // with this (empty) set regardless.
        guard tableState.folderKeyMirror.isOn, !display.rows.isEmpty else { return }
        pruneSelectionToDisplay()
        completePendingReveal()
    }

    private func folderTableRows(_ level: FootageFolderLevel.Level, index: FootageFolders.Index) -> [FootageFolderTableRow] {
        var rows: [FootageFolderTableRow] = []
        rows.reserveCapacity(level.rows.count)
        for d in level.rows {
            if let e = d.eventID {
                let members = (level.children[e] ?? []).compactMap { recordTableRow($0, index: index) }
                rows.append(FootageFolderTableRow(display: d, record: nil, folder: level.folders[e],
                                                  keys: index.folders[e]?.keys ?? FootageFolders.SortKeys(),
                                                  children: members.isEmpty ? nil : members))
            } else if let row = recordTableRow(d, index: index) {
                rows.append(row)
            }
        }
        return rows
    }

    /// A record's row; nil when the record has left the catalog.
    private func recordTableRow(_ d: FootageFolders.DisplayRow, index: FootageFolders.Index) -> FootageFolderTableRow? {
        guard let id = d.recordID, let rec = model.record(forID: id) else { return nil }
        // A row the index has not seen yet (a derivative that just
        // landed) still needs its sort facts: one projection.
        return FootageFolderTableRow(display: d, record: rec, keys: index.keysOf[id] ?? model.footageFolderRow(rec).keys)
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
            tableState.pendingReveal = nil
            tableState.folderRows = []
            tableState.folderIDs = []
            tableState.folderLevel = .empty
            tableState.expandedFolderIDs = []
            tableState.folderRecordIDs = []
        }
    }

    // MARK: - Keyboard (← / Esc, ⌘↓ / ⌘↑) — through the pane's NSEvent monitor

    /// True when the key was ours. Only while the option is on and the
    /// FILES table has the keyboard (the Space rule). Bare ← / Esc inside
    /// a folder and the Finder's ⌘↓ (open) / ⌘↑ (enclosing folder);
    /// anything else keeps its owner. At the top, bare → / ← are the
    /// outline's own (twist open / closed; ← on a member goes to its
    /// folder — Finder list view, 2026-10-18). ↑↓ alone are never touched
    /// — the Table's native row walk (Rick 2026-10-05).
    func handleFolderKey(_ event: NSEvent) -> Bool {
        guard tableState.folderKeyMirror.isOn, spaceShouldToggleLivePreview() else { return false }
        guard let key = FootageFolderKey(event) else { return false }
        switch key {
        case .open: return enterSelectedFolder()
        case .close, .escape: return leaveFolderByKey()
        }
    }

    private var singleSelection: UUID? {
        selectedIDs.count == 1 ? selectedIDs.first : nil
    }

    /// ⌘↓ on a folder row opens it.
    private func enterSelectedFolder() -> Bool {
        guard let id = singleSelection, tableState.folderIDs.contains(id) else { return false }
        enterFolder(id)
        return true
    }

    /// ←, ⌘↑ or Esc inside a folder goes back up; at the top the key is
    /// not ours.
    private func leaveFolderByKey() -> Bool {
        guard tableState.folderScope != nil else { return false }
        leaveFolder()
        return true
    }

    // MARK: - A derivative landed: enter its source's folder, select, reveal

    /// Transcode / Reformat / Trim / Repair / Clean Up finished and the
    /// catalog took the new row (`VideoScanModel.adoptDerivative`). With
    /// the option on, the new row belongs under its source: the source's
    /// folder is entered (from the top) or kept (inside it), and the row
    /// is selected as soon as the level shows it — the join may still be
    /// placing it (`pendingReveal`). Off, the row is selected in the
    /// linear table. Either way the selection is scrolled into view — but
    /// ONLY when the list can show the row (codex 2026-10-16 P1): a row
    /// the filter hides, or a scope on another event hides, is never
    /// selected; the one console line says where it went.
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
        case .select, .openScopeAndSelect:
            let folder = selectDerivative(landing)
            model.log(folder.map { FootageFolderWords.landedInFolder(name, source: source, folder: $0) }
                      ?? FootageFolderWords.landedSelected(name, source: source))
        case .hiddenByFilter:
            model.log(FootageFolderWords.landedHiddenByFilter(name, source: source))
        case .outsideScope:
            let scope = tableState.folderScope.map(folderScopeTitle) ?? ""
            let place = model.footageFolders.index.folder(containing: landing.sourceID)?.title
            model.log(FootageFolderWords.landedOutsideScope(name, source: source, scope: scope, place: place))
        }
    }

    /// The row can be shown: from the top, enter the source's folder
    /// (option on); then select the new row as soon as the level shows it.
    /// Returns the folder's title when one was entered or kept.
    private func selectDerivative(_ landing: DerivativeLanding) -> String? {
        var folder: String?
        if showFootageFolders, let eventID = model.footageFolders.index.folderOf[landing.sourceID] {
            if tableState.folderScope == nil { enterFolder(eventID) }
            if tableState.folderScope == .event(eventID) { folder = model.footageFolders.index.folders[eventID]?.title }
        }
        tableState.pendingReveal = landing
        completePendingReveal()
        return folder
    }

    /// A waiting reveal whose row is on screen now: select it, scroll to
    /// it, done. A row not shown yet waits for the next display.
    private func completePendingReveal() {
        guard let landing = tableState.pendingReveal, displayedIDs(among: [landing.id]).contains(landing.id) else { return }
        tableState.pendingReveal = nil
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

/// The folder keys: `open` = into the selected folder (⌘↓ — the
/// Finder's Open), `close` = up to the enclosing level (bare ←, or ⌘↑ —
/// the Finder's Enclosing Folder), `escape` = up as well. Bare → is NOT
/// ours: it is the outline's twist-open (Finder list view, 2026-10-18).
/// By virtual key code (kVK_LeftArrow 123, kVK_DownArrow 125,
/// kVK_UpArrow 126, kVK_Escape 53). (≈ a C++ enum class with explicit
/// converting constructors.)
enum FootageFolderKey: Equatable {
    case open, close, escape

    /// A BARE key (no modifier beyond fn / the numeric pad).
    init?(keyCode: UInt16) {
        switch keyCode {
        case 123: self = .close
        case 53: self = .escape
        default: return nil
        }
    }

    /// A key with ⌘ alone held.
    init?(commandKeyCode: UInt16) {
        switch commandKeyCode {
        case 125: self = .open
        case 126: self = .close
        default: return nil
        }
    }

    /// The event's key, bare or ⌘-only; any other modifier set is not ours.
    init?(_ event: NSEvent) {
        self.init(keyCode: event.keyCode, modifiers: event.modifierFlags.intersection(.deviceIndependentFlagsMask))
    }

    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) {
        let real = modifiers.subtracting([.function, .numericPad])
        if real.isEmpty { self.init(keyCode: keyCode) }
        else if real == [.command] { self.init(commandKeyCode: keyCode) }
        else { return nil }
    }
}
