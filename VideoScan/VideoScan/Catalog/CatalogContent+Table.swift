// CatalogContent+Table.swift
// The catalog results Table and the per-column cell builders (the row
// context menus moved to CatalogRowContextMenu*.swift — R1, GH #281) —
// extracted verbatim from CatalogContent's body in
// CatalogHelpers.swift (refactor 2026-06-11). A cross-file `extension`
// can't see `private` members, so the handful of CatalogContent stored
// properties/helpers this code touches were widened to internal in
// CatalogHelpers.swift (single-module app — same visibility in practice).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import Combine
import SwiftUI

extension CatalogContent {

    /// Filename-cell tooltip: directory + state suffix, plus the pro-video
    /// bundle tag when the file lives inside a project bundle ("Look Inside
    /// Video Project Bundles", 2026-07-02). Kept as a helper so the bundle
    /// line composes with every existing state instead of another ternary.
    private func filenameTooltip(for rec: VideoRecord, offline: Bool, purged: Bool) -> String {
        var tip: String
        if purged {
            tip = "\(rec.directory) (removed from catalog)"
        } else if rec.isSetAside {
            let label = rec.setAsideReason
                .flatMap { CatalogScopePolicy.SetAsideReason(rawValue: $0)?.friendlyLabel }
                ?? "outside catalog scope"
            tip = "\(rec.directory) (set aside — \(label.lowercased()))"
        } else if rec.isSuperseded {
            // Repair lifecycle (GH #132): name the replacing file when we
            // can still resolve it — the "why is this row brown" answer.
            let replacement = rec.supersededByID
                .flatMap { model.record(forID: $0)?.filename }
            tip = replacement == nil
                ? "\(rec.directory) (superseded by its repaired copy)"
                : "\(rec.directory) (superseded by \(replacement ?? ""))"
        } else if let reason = rec.unanalyzableReason {
            tip = "\(rec.directory)\n\n⚠️ \(reason)"
        } else if offline {
            tip = "\(rec.directory) (offline)"
        } else {
            tip = rec.directory
        }
        if !rec.scanContext.bundleContainer.isEmpty {
            tip += "\n\n📦 Inside video project bundle: \(rec.scanContext.bundleContainer)"
        }
        // Verify Audio damaged verdict (GH #128) — composes with every
        // state above (the red filename tint needs its "why" visible).
        // The note self-describes since the "Damaged audio — <detail>"
        // standardization, so no extra label — a label would double up
        // as "Damaged audio: Damaged audio — …".
        if rec.audioVerifyStatus == "damaged" {
            tip += "\n\n⚠️ \(rec.audioVerifyNote.isEmpty ? "Damaged audio" : rec.audioVerifyNote)"
        }
        // Verify Video (2026-09-23): broken AND warning verdicts explain
        // themselves here; the note self-describes ("Broken video — …").
        if rec.videoVerifyStatus == "broken" || rec.videoVerifyStatus == "warning" {
            tip += "\n\n⚠️ \(rec.videoVerifyNote.isEmpty ? "Video \(rec.videoVerifyStatus)" : rec.videoVerifyNote)"
        }
        return tip
    }

    // MARK: - Results Table

    // Internal (not private): the view body in CatalogHelpers.swift embeds
    // this table in the left pane.
    //
    // Split (GH #132): the Table-with-columns expression and its long
    // modifier chain were ONE expression, and the chain's growth (extra
    // onChange keys) pushed the combined type-check past Xcode's budget.
    // `catalogTableBase` isolates the columns; this var owns the chain.
    var catalogTable: some View {
        // Second Archive Angel stage (codex #1345): a sweep that keeps the
        // A+B set but flips a grade A↔B or rewrites a summary leaves
        // `candidateIDs` silent, so the rows' badge/tooltip went stale.
        // The store's `revision` bumps on every replace; here it only
        // touches a @State the Tag cell reads — rows re-render, the
        // filter is NOT recomputed (that is the stage below). Its own
        // wrapper var, same reason as the grade stage (GH #132).
        tableWithAngelGrades
            .onReceive(angelRevisionPublisher) { angelBadgeRevision = $0 }
    }

    private var angelRevisionPublisher: AnyPublisher<Int, Never> {
        model.archiveAngel.evidenceRevisionPublisher
    }

    private var tableWithAngelGrades: some View {
        // A finished Archive Angel sweep republishes its grade set: the
        // "Promote me" badges and the Archive-candidates filter follow it
        // (2026-09-11). The store is a nested ObservableObject, which the
        // environment model does not forward — hence a publisher, not
        // onChange. Its own stage: the onChange chain below is already at
        // the type-checker's budget (GH #132).
        tableWithCatalogTriggers
            .onReceive(angelGradesPublisher) { _ in refreshRows() }
    }

    /// Grade-set changes only — identical sweeps do not churn the table.
    private var angelGradesPublisher: AnyPublisher<Set<UUID>, Never> {
        model.archiveAngel.candidateIDsPublisher
    }

    // Split into three typed stages (stage-0 triage R2, 2026-09-29): as
    // ONE chain of an onAppear and fifteen onChange modifiers this getter
    // took 21.7 s to type-check on the nightly runner — one wobble short of
    // "unable to type-check in reasonable time", the 2026-09-01 CI-red
    // shape. Each stage below resolves its onChange overloads against a
    // fixed `some View`, so the solver never sees the whole chain at once.
    // Order is irrelevant to behaviour: every trigger does the same thing.
    // (C++ analogy: breaking one giant template expression into named
    // intermediate typedefs so overload resolution stays local.)
    private var tableWithCatalogTriggers: some View {
        tableWithFilterTriggers
            .onChange(of: model.lastTidyBatch) { refreshRows() }
            // Re-compute when purge state flips on any record (purge, undo, restore).
            // We key off lastPurgedBatch so mutations from the model are observed.
            .onChange(of: model.lastPurgedBatch) { refreshRows() }
            // In-place purge/lifecycle mutations that arm no banner (Delete
            // Confirmed Junk, workbench discard, dossier auto-purge) — #160.
            .onChange(of: model.volumeAggregatesRevision) { refreshRows() }
            // Confirm Repair supersedes originals (and undo restores them) —
            // same observation pattern as the purge batch (GH #132).
            .onChange(of: model.lastConfirmBatch) { refreshRows() }
    }

    /// Reveal toggles: disconnected media, kind facet, removed / set-aside /
    /// superseded rows.
    private var tableWithFilterTriggers: some View {
        tableWithSearchTriggers
            // Reachable-only baseline opt-out (2026-07-20).
            .onChange(of: showDisconnectedMedia) { refreshRows() }
            // Media-kind facet chip flip (GH #124).
            .onChange(of: kindFacet) { refreshRows() }
            .onChange(of: showRemoved) { refreshRows() }
            .onChange(of: showSetAside) { refreshRows() }
            // Superseded reveal toggle (GH #132).
            .onChange(of: showSuperseded) { refreshRows() }
    }

    /// First appearance, record count, and the search / scope inputs.
    private var tableWithSearchTriggers: some View {
        tableWithMenus
            .onAppear { tableData = computeFiltered() }   // appear: no filter changed — selection untouched
            .onChange(of: records.count) { refreshRows() }
            .onChange(of: searchText) { refreshRows() }
            .onChange(of: filterTargetPaths) { refreshRows() }
            .onChange(of: showPairsOnly) { refreshRows() }
            .onChange(of: filterByIDs) { refreshRows() }
            .onChange(of: viewFilters) { refreshRows() }
    }

    /// Sort + menus stage of the split — see `catalogTable`'s note.
    private var tableWithMenus: some View {
        tableWithTrashShortcut
        .onChange(of: sortOrder) {
            onSort(sortOrder)
            tableData.sort(using: sortOrder)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            rowContextMenu(ids: ids)
        } primaryAction: { ids in
            // Double-click / Return on row(s) → the ONE open path (smart
            // player choice + looks-moved check), shared with File ▸ Open
            // ⌘O — see CatalogOpenCommand.swift.
            openRows(ids: ids, gesture: "double-click")
        }
    }

    /// ⌘⌫ — the Finder gesture — moves the highlighted rows to the Trash
    /// (Rick 2026-09-13), through the Catalog ▸ Move to Trash menu item,
    /// which reads the selection this table publishes ONLY while it owns
    /// keyboard focus: the search box, rename fields and the editor sheets
    /// keep their own ⌘⌫. Its own stage, same reason as the others (GH #132).
    private var tableWithTrashShortcut: some View {
        catalogTableBase
            // Keyboard harness hook (CatalogKeyboardUITests).
            .accessibilityIdentifier("catalog.filesTable")
            // One of the two Catalog focus targets (CatalogPane). Focus
            // arrives only natively — a click in this table, Tab, or the
            // window's default focus — never from a selection change.
            .focused($focusedPane, equals: .files)
            .onChange(of: focusedPane, initial: true) { tableState.paneFocusMirror.pane = focusedPane }
            // The menu route (2026-09-20): Catalog ▸ Move to Trash ⌘⌫ reads
            // this while the table has keyboard focus — see
            // CatalogTrashCommand.swift for why the key handler below was
            // never reached by a Command-key gesture.
            .focusedValue(\.catalogTrashSelection,
                          CatalogTrashSelection(count: selectedIDs.count, perform: trashSelectedRows))
            // File ▸ Open ⌘O (2026-09-26): same focused-value shape, same
            // reason — a Command key is a key equivalent the menu bar
            // claims first. See CatalogOpenCommand.swift.
            .focusedValue(\.catalogOpenSelection,
                          CatalogOpenSelection(count: selectedIDs.count, perform: openSelectedRows))
            // Archive ▸ Promote Selected (2026-10-06): visible ∩ selected,
            // only while this table has the keyboard. CatalogPromoteCommand.swift.
            .focusedValue(\.catalogPromoteSelection,
                          CatalogPromoteSelection(count: selectedIDs.count, visibleRecordIDs: {
                              CatalogPromoteScope.recordIDs(selection: selectedIDs, visibleRows: tableData)
                          }))
            // File ▸ Get Media Info ⌘I (2026-10-07): one highlighted file
            // while this table has the keyboard. CatalogInfoCommand.swift.
            .focusedValue(\.catalogFileInfo,
                          CatalogFileInfo(isAvailable: selectedIDs.count == 1, perform: {
                              guard selectedIDs.count == 1, let id = selectedIDs.first,
                                    let rec = model.record(forID: id) else { return }
                              presentMediaInfo(for: rec)
                          }))
            // NO .onKeyPress here (Rick 2026-10-05: "still can't arrow up and
            // down in cat view"). A key handler on the Table wrapped it in
            // SwiftUI's own focus handling, so ↑/↓ never reached the table's
            // native row navigation. It was dead weight anyway: ⌘⌫ is a key
            // equivalent the menu bar claims first (2026-09-20), so it lives
            // in Catalog ▸ Move to Trash (CatalogTrashCommand.swift), scoped
            // to this table's focus by the focusedValue above.
    }

    private var catalogTableBase: some View {
        Table(tableData, selection: $selectedIDs, sortOrder: $sortOrder) {
            TableColumn("Filename", value: \.filename) { rec in
                let offline = !VolumeReachability.isReachable(path: rec.fullPath)
                let purged = rec.isPurged
                let workspaceActive = rec.workspaceActive
                let setAside = rec.isSetAside
                let superseded = rec.isSuperseded
                HStack(spacing: 4) {
                    if purged {
                        // Trash-slash icon makes the "removed" state obvious
                        // at a glance — even if the user's row colors are
                        // partially overridden by a high-contrast theme.
                        Image(systemName: "trash.slash")
                            .font(.system(size: 10))
                            .foregroundColor(.orange)
                    } else if setAside {
                        // Archive-box = "set aside by catalog scope" (photo /
                        // music / audio with no matching video). Purple to
                        // stay distinct from purge-orange.
                        Image(systemName: "archivebox")
                            .font(.system(size: 10))
                            .foregroundColor(.purple)
                    } else if superseded {
                        // Swap arrows = "a confirmed repair replaced this
                        // original" (GH #132). Brown to stay distinct from
                        // purge-orange and set-aside-purple.
                        Image(systemName: "arrow.triangle.swap")
                            .font(.system(size: 10))
                            .foregroundColor(.brown)
                    } else if rec.isLikelyUnanalyzable {
                        // Red "!" — file's video / audio codec was
                        // deprecated by AVFoundation (svq3, qdm2,
                        // cinepak, etc.) so the analyzer can't decode
                        // it. Right-click → Reformat and Analyze to
                        // convert via ffmpeg. Rick 2026-06-14.
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.red)
                    } else if workspaceActive {
                        // Hammer = "being worked on with external tools."
                        // Turquoise (.mint adapts for dark mode) marks the
                        // record as triage-active. Pass A — Rick 2026-06-14.
                        Image(systemName: "hammer.fill")
                            .font(.system(size: 10))
                            .foregroundColor(.mint)
                    } else if showPairsOnly && rec.pairedWith != nil {
                        Image(systemName: rec.streamType == .videoOnly ? "film" : "waveform")
                            .font(.system(size: 10))
                            .foregroundColor(rec.streamType == .videoOnly ? .blue : .green)
                    }
                    Text(rec.filename)
                        .font(.system(.body, design: .monospaced))
                        // Italic when offline OR purged — both signal "not the
                        // active default state". Purge color (orange) wins over
                        // both offline-secondary and pair-blue/green when set.
                        // Workspace tint (.mint / turquoise) sits between
                        // purged-orange (highest priority) and the rest.
                        .italic(offline || purged || setAside || superseded)
                        .foregroundColor(purged ? .orange
                            : (setAside ? .purple
                                : (superseded ? .brown
                                    : (workspaceActive ? .mint
                                        : (offline ? .secondary
                                            : (showPairsOnly && rec.pairedWith != nil
                                               ? (rec.streamType == .videoOnly ? .blue : .green)
                                               : rec.filenameColor))))))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 2)
                // Rick 2026-10-05: "sometimes it's not clear which file I am
                // right clicking on" — the system selection turns grey when
                // the window isn't key (Hallie's window, the MFO window
                // brought forward). A light-blue marker behind the selected
                // file's name that does NOT depend on focus. O(1) per cell.
                .background {
                    if selectedIDs.contains(rec.id) {
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Color.accentColor.opacity(0.30))
                            .overlay(RoundedRectangle(cornerRadius: 5)
                                .strokeBorder(Color.accentColor.opacity(0.75), lineWidth: 1))
                            .padding(.horizontal, -4)
                    }
                }
                .help(filenameTooltip(for: rec, offline: offline, purged: purged))
            }
            .width(min: 180, ideal: 260)

            // Sort by `displayVolumeLabel` so folder-scoped scans of the same
            // folder name (e.g. multiple "Movies" subfolders across volumes)
            // sort together under their owning volume. The label embeds the
            // volume name as the prefix, so this preserves volume grouping.
            TableColumn("Volume", value: \.displayVolumeLabel) { rec in
                Text(rec.displayVolumeLabel)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .help(rec.fullPath)
            }
            .width(min: 80, ideal: 160)

            TableColumn("Stream", value: \.streamTypeRaw) { rec in
                let unpaired = rec.streamType.needsCorrelation && rec.pairedWith == nil
                let display = rec.streamType == .ffprobeFailed
                    ? rec.isPlayable
                    : rec.streamTypeRaw
                Text(display)
                    .foregroundColor(unpaired ? .orange : streamTypeColor(rec.streamType))
                    .bold(rec.streamType.needsCorrelation)
                    .help(unpaired
                          ? (rec.streamType == .videoOnly ? "No audio pair found" : "No video pair found")
                          : "V+A = video and audio, V-only/A-only = single stream, or file status if damaged")
            }
            .width(min: 90, ideal: 130)

            TableColumn("Duration", value: \.durationSeconds) { rec in
                Text(rec.duration)
                    .help("Playback duration (HH:MM:SS)")
            }
            .width(min: 65, ideal: 75)

            TableColumn("Resolution", value: \.pixelCount) { rec in
                Text(rec.resolution)
                    .help("Video frame size (width x height)")
            }
            .width(min: 80, ideal: 95)

            // GH #124 layer 4: audio-only rows always CAPTURED their codec
            // (ScanEngine maps codec_name for the first audio stream); the
            // column just never showed it, so 80k music rows read "—".
            // displayCodec = videoCodec, falling back to audioCodec when
            // there's no video stream. Sort key follows the displayed value.
            TableColumn("Codec", value: \.displayCodec) { rec in
                Text(rec.displayCodec.isEmpty ? "—" : rec.displayCodec)
                    .foregroundColor(rec.displayCodec.isEmpty ? .secondary : .primary)
                    .help("Video codec (e.g. h264, prores); for audio-only files, the audio codec (e.g. mp3, aac, pcm_s16le)")
            }
            .width(min: 60, ideal: 80)

            // Dossier channel-dots column — at-a-glance richness per
            // record. Four dots = scene captions / audio transcript /
            // OCR text / OCR dates. Sorts by total channel count so
            // ascending → emptiest-first ("what's left to do") and
            // descending → richest-first ("what's been captured").
            TableColumn("Dossier", value: \.dossierChannelCount) { rec in
                DossierChannelDots(record: rec)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
            .width(min: 64, ideal: 72)

            TableColumn("Size", value: \.sizeBytes) { rec in
                // Formatted from bytes, not the persisted string (Rick
                // 2026-08-18: decimal units, consistent across rows).
                Text(rec.sizeDisplay)
                    .help("File size on disk")
            }
            .width(min: 60, ideal: 75)

            // Resolved best date (GH #117): Rick's hand-entered date —
            // either confidence — OUTRANKS the dossier's inferred date,
            // which outranks the filesystem creation date. Estimated
            // entries carry an " (est.)" suffix; the tooltip names the
            // source. Both accessors are O(1) per record (pure integer
            // math on the user-date path — VideoRecordUserDate.swift),
            // so the column stays safe at catalog scale.
            TableColumn("Date", value: \.resolvedDateSortKey) { rec in
                let display = rec.resolvedDateDisplay
                Text(display.isEmpty ? "—" : display)
                    .foregroundColor(display.isEmpty ? .secondary : .primary)
                    .font(.system(size: 11))
                    .help(rec.resolvedDateHelp)
            }
            .width(min: 80, ideal: 100)

            // Last three columns wrapped in Group to stay under the 10-child
            // limit of Swift's @TableColumnBuilder. The People column (Step 5)
            // is the 11th, so we group People + Tag + Duplicate.
            //
            // People column: confirmed names in blue, suspected (borderline)
            // names italic + secondary with a leading "?". Em-dash when both
            // arrays are empty — the "junk candidate" signal the user filters
            // on with .untaggedOnly. Sortable via peopleSortKey: confirmed
            // alphabetical first, suspected after (~ prefix), untagged last.
            Group {
                // Hand-entered place (Rick 2026-09-12) — beside the Date
                // column (there is no per-user column hiding on this
                // table). Same shape as Date: estimated entries carry an
                // " (est.)" suffix, unplaced rows show "—" and sort
                // first ascending (the review queue). O(1) per record.
                TableColumn("Place", value: \VideoRecord.resolvedPlaceSortKey) { rec in
                    let display = rec.resolvedPlaceDisplay
                    Text(display.isEmpty ? "—" : display)
                        .foregroundColor(display.isEmpty ? .secondary : .primary)
                        .font(.system(size: 11))
                        .lineLimit(1)
                        .help(rec.resolvedPlaceHelp)
                }
                .width(min: 80, ideal: 110)

                TableColumn("People", value: \.peopleSortKey) { rec in
                    peopleColumnCell(for: rec)
                }
                .width(min: 90, ideal: 140)

                TableColumn("Tag") { rec in
                    tagColumnCell(for: rec)
                }
                .width(min: 70, ideal: 120)

                TableColumn("Duplicate") { rec in
                    DuplicateDispositionCell(record: rec)
                        .help(rec.duplicateDisposition == .none
                              ? "Run Duplicates analysis to check for copies"
                              : "Total copies across catalog. Color: green = Keep (best copy), orange = Review (check manually), red = Extra copy (safe to remove)")
                }
                .width(min: 80, ideal: 95)
            }
        }
    }

    /// Surface a result alert ONLY when something interesting happened —
    /// skipped-offline, already-missing, or per-file failures. Pure
    /// success is silent, matching Finder's behavior on trash/delete.
    /// Called from the row context menu's Delete File submenu after the
    /// detached FileManager pass completes.
    /// ⌘⌫ handler: the highlighted rows, in table order, through the ONE
    /// existing Trash routine (VideoScanModel+TrashSelection.swift → the
    /// same `deleteConfirmedJunk(_:mode: .toTrash)` the row menu's "Move
    /// to Trash" calls). No selection → nothing happens. Refusals are
    /// console lines; the result is reported as the row menu reports it.
    private func trashSelectedRows() {
        // BEGIN LINE. Every refusal below this point already writes a
        // console line; the two guards did not, so an empty selection or a
        // selection that no longer matches any row looked exactly like a
        // dead keyboard shortcut. Say that the gesture arrived, then say
        // why nothing followed.
        model.log("Move to Trash (\u{2318}\u{232B}): \(selectedIDs.count) row(s) selected")
        guard !selectedIDs.isEmpty else {
            model.log("Move to Trash: nothing is selected — click a row first.")
            return
        }
        let targets = tableData.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else {
            model.log("Move to Trash: the \(selectedIDs.count) selected row(s) are no longer in the table — nothing to do.")
            return
        }
        Task { @MainActor in
            let result = await model.trashSelectedRecords(targets)
            reportDeleteResult(result)
        }
    }

    /// ⌘O route (File ▸ Open): the highlighted rows, through `openRows`.
    private func openSelectedRows() {
        openRows(ids: selectedIDs, gesture: "\u{2318}O")
    }

    /// The ONE open path for the table. Double-click / Return
    /// (`primaryAction`) and File ▸ Open ⌘O both land here; the work —
    /// looks-moved check per record, console line naming the player,
    /// MediaOpener's smart launch — is `CatalogOpenAction.open`
    /// (CatalogOpenCommand.swift). `tableData`, not `records`: the ids
    /// came from the rows on screen, and one filter pass is O(n).
    private func openRows(ids: Set<UUID>, gesture: String) {
        CatalogOpenAction.open(ids: ids, rows: tableData, gesture: gesture, model: model)
    }

    /// The result of ⌘⌫ / the row menu's Move to Trash. Silent when every
    /// file moved (Finder's behaviour); otherwise an alert with one
    /// sentence per bucket and EVERY file that stayed, with its reason, in
    /// a scrolling list (design R6 — nothing console-only, nothing
    /// truncated). Same presenter as Triage's result sheet.
    func reportDeleteResult(_ result: VideoScanModel.JunkDeletionResult) {
        let report = JunkDeletionReport(result)
        guard report.hasNotes else { return }
        let alert = NSAlert()
        alert.messageText = "Move to Trash \u{2014} some files stayed"
        alert.informativeText = report.summary.joined(separator: "\n")
        alert.alertStyle = result.failed.isEmpty ? .informational : .warning
        alert.accessoryView = Self.reportListView(report.linesText)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// A read-only, selectable, scrolling text list for the alert.
    private static func reportListView(_ text: String) -> NSView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 460, height: 180))
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let textView = NSTextView(frame: scroll.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.font = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        textView.string = text
        textView.autoresizingMask = [.width]
        scroll.documentView = textView
        return scroll
    }

    /// Extracted Tag-column cell. Moved out of the Table body to keep
    /// the @TableColumnBuilder's type inference manageable — when the
    /// People column pushed this Table from 10 → 11 columns, type-check
    /// timed out on the larger expression.
    @ViewBuilder
    private func tagColumnCell(for rec: VideoRecord) -> some View {
        HStack(spacing: 3) {
            Image(systemName: rec.mediaDisposition.icon)
                .foregroundColor(rec.mediaDisposition.color)
            if rec.mediaDisposition != .unreviewed {
                Text(rec.mediaDisposition.rawValue)
                    .font(.system(size: 11))
                    .foregroundColor(rec.mediaDisposition.color)
            }
            // Workflow tags (2026-07-23) — subtle teal chips, capped at
            // two + "+N" overflow so the column never balloons. Same
            // rounded-rect badge language as the inspector's stream-type
            // badge. Full list rides in the tooltip below.
            ForEach(Array(rec.tags.prefix(2)), id: \.self) { tag in
                Text(tag)
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(.teal)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.teal.opacity(0.12))
                    )
                    .lineLimit(1)
            }
            if rec.tags.count > 2 {
                Text("+\(rec.tags.count - 2)")
                    .font(.system(size: 9))
                    .foregroundColor(.teal)
            }
            // Note icon covers YOUR notes and the machine probe notes —
            // both mean "there's something written on this row".
            if !rec.userNotes.isEmpty || !rec.notes.isEmpty {
                Image(systemName: "note.text")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
            if rec.archiveHealth != .notApplicable {
                Image(systemName: rec.archiveHealth.icon)
                    .font(.system(size: 9))
                    .foregroundColor(rec.archiveHealth.color)
            }
            // The Archive Angel's word on this file (Rick 2026-09-11, and
            // 2026-10-06): "Ready for archive" (light green) when it is
            // picked and ready, "Angel pick" when picked but not ready,
            // "Prepared" while in a batch. O(1) per row — the hints are
            // built off-main once per recount. The revision is a real input
            // of the chip so a regrade or a hint update re-renders it
            // (codex #1345).
            if let badge = model.archiveAngel.catalogBadge(for: rec.id) {
                ArchiveAngelCatalogBadgeView(badge: badge, revision: angelBadgeRevision)
            }
            // Find Similar Footage (2026-09-23): "3 copies" — the group
            // size read straight off the record (O(1), no scan).
            if let f = rec.footage, f.groupSize > 1 {
                FootageGroupBadge(membership: f)
            }
        }
        .help(tagColumnHelp(for: rec))
    }

    /// Tooltip for the Tag column: disposition, then workflow tags,
    /// then your note (machine probe notes stay in the inspector).
    private func tagColumnHelp(for rec: VideoRecord) -> String {
        var lines = [rec.mediaDisposition.rawValue]
        if let badge = model.archiveAngel.catalogBadge(for: rec.id) {
            // The capsules' help is already the whole story in family words.
            lines.append(badge.style == .chip ? badge.help + " — Assess in the Archive tab to prepare it." : badge.help)
        }
        if let f = rec.footage, f.groupSize > 1 {
            lines.append(FootageGroupBadge.help(f))
        }
        if !rec.tags.isEmpty {
            lines.append("Tags: \(rec.tags.joined(separator: ", "))")
        }
        if !rec.userNotes.isEmpty {
            lines.append(rec.userNotes)
        } else if !rec.notes.isEmpty {
            lines.append(rec.notes)
        }
        return lines.joined(separator: "\n")
    }

    /// Render the family-tag column for one record. Confirmed names blue,
    /// suspected names italic + secondary with a leading "?", joined by
    /// " · ". Em-dash when both arrays are empty (junk-triage signal).
    /// Tooltip lists names with tier annotations.
    @ViewBuilder
    private func peopleColumnCell(for rec: VideoRecord) -> some View {
        // Notation (Rick 2026-08-02, deduced-vs-confirmed model):
        //   Donna   = confirmed by Rick        (plain blue)
        //   Donna*  = machine detected          (blue, starred)
        //   Donna?  = machine suspected         (italic gray, ? suffix)
        let confirmed = rec.confirmedByUserPeople.map(\.name)
        let confirmedKeys = Set(confirmed.map { $0.lowercased() })
        let machine = rec.detectedPeople
            .filter { !confirmedKeys.contains($0.lowercased()) }
        if confirmed.isEmpty && machine.isEmpty && rec.suspectedPeople.isEmpty {
            Text("—")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .help("No family tagged or detected — junk-triage candidate")
        } else {
            let strong = confirmed.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                + machine.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                    .map { "\($0)*" }
            let strongText = Text(strong.joined(separator: ", "))
                .foregroundColor(.blue)
            let suspectedJoined = rec.suspectedPeople
                .map { "\($0)?" }
                .joined(separator: ", ")
            let suspectedText = Text(suspectedJoined)
                .italic()
                .foregroundColor(.secondary)
            let separator = (!strong.isEmpty
                             && !rec.suspectedPeople.isEmpty) ? " · " : ""
            (strongText + Text(separator) + suspectedText)
                .font(.system(size: 12))
                .lineLimit(1)
                .help(peopleColumnHelp(for: rec))
        }
    }

    private func peopleColumnHelp(for rec: VideoRecord) -> String {
        var lines: [String] = []
        let confirmed = rec.confirmedByUserPeople.map(\.name)
        if !confirmed.isEmpty {
            lines.append("Confirmed by you: \(confirmed.joined(separator: ", "))")
        }
        if !rec.detectedPeople.isEmpty {
            lines.append("Detected: \(rec.detectedPeople.joined(separator: ", "))")
        }
        if !rec.suspectedPeople.isEmpty {
            lines.append("Suspected (name?): \(rec.suspectedPeople.joined(separator: ", "))")
        }
        if !rec.rejectedPeople.isEmpty {
            // Invisible rejections caused a "why won't it scan this file"
            // mystery (Rick 2026-08-02) — surface them here.
            lines.append("Rejected (recipes will NOT tag): \(rec.rejectedPeople.joined(separator: ", "))")
        }
        lines.append("Notation: plain = you confirmed · * = recipe detected · ? = recipe suspects")
        return lines.joined(separator: "\n")
    }

    private func streamTypeColor(_ st: StreamType) -> Color {
        switch st {
        case .videoOnly:     return .orange
        case .audioOnly:     return .yellow
        case .ffprobeFailed: return .red
        default:             return .primary
        }
    }
}

/// What a Verify Audio / Verify Video context-menu item says and runs
/// (stage-0 triage R4, 2026-09-29). The label used to count the whole
/// SELECTION while the action ran only the rows that can be verified — 3
/// selected with one audio-only or offline said "(3 Files)" and started 2
/// jobs. One value now carries both, so they cannot drift apart again.
/// O(selection). (C++: a small POD computed once, read by the view.)
struct CatalogVerifyMenuPlan {
    let label: String
    let runnable: [VideoRecord]
    var isDisabled: Bool { runnable.isEmpty }

    init(verb: String, selection: [VideoRecord], canRun: (VideoRecord) -> Bool) {
        runnable = selection.filter(canRun)
        label = runnable.count > 1 ? "\(verb) (\(runnable.count) Files)" : verb
    }
}
