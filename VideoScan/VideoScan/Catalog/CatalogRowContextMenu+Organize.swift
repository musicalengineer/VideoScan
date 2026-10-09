// CatalogRowContextMenu+Organize.swift
// Rename / tags / people / notes (the `.describe` group) and the
// duplicates / Find ▸ / Copy Path items (the `.find` group) of the
// Catalog row menu, cut out of the single rowContextMenu builder section
// by section (R1 refactor, GH #281; regrouped 2026-10-07 and 2026-10-08).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

    /// The `.describe` group (pure-active selections only): Rename…,
    /// Tags ▸, People ▸, Notes… (R1 split, GH #281; regrouped 2026-10-07
    /// and 2026-10-08).
    @ViewBuilder
    func describeItems(rec: VideoRecord, selection: CatalogRowMenuSelection) -> some View {
        Button("Rename…") {
            renameTarget = rec
            renameText = (rec.filename as NSString).deletingPathExtension
            showRenameSheet = true
        }

        tagsMenu(selectedRecs: selection.selected)

        peopleMenu(selectedRecs: selection.selected)

        Button("Notes\u{2026}") {
            notesTarget = rec
            // userNotes split (2026-07-23): the sheet
            // edits YOUR note text; machine probe notes
            // stay read-only in the inspector.
            notesText = rec.userNotes
            showNotesSheet = true
        }

        // ("Mark as Family Music…" retired 2026-10-07 — Rick: "this app
        // is not going to track Rick's Music". Existing marks stay on the
        // records, inert; the Archive tab's Music shelf still lists them.)
    }

    /// The `.find` group (2026-10-08): Find Matching Audio / Video and
    /// Find Missing Audio (any active selection, as before), then — for
    /// pure-active selections — the duplicate and online-copy verbs,
    /// Find ▸ and Copy Path.
    @ViewBuilder
    func findItems(rec: VideoRecord, pureActive: Bool) -> some View {
        matchItems(rec: rec)

        if pureActive {
            duplicateMatchItems(rec: rec)

            findCopyItems(rec: rec)

            findMenu(rec: rec)

            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(rec.fullPath, forType: .string)
            }
        }
    }

    /// Tags ▸ — ONE menu (2026-10-07) for what used to be three: the
    /// one-of disposition (Important … Junk), the any-of workflow tags
    /// ("Follow Up", "Gold", your own words), and Find and Tag ▸.
    @ViewBuilder
    private func tagsMenu(selectedRecs: [VideoRecord]) -> some View {
        Menu("Tags") {
            dispositionItems(selectedRecs: selectedRecs)

            Divider()

            workflowTagItems(selectedRecs: selectedRecs)

            Divider()

            // Find & Tag (docs/find-and-tag-design.md): run a
            // per-person recipe over the selection; results
            // land in the machine tiers (Donna* / Donna?).
            // v1: Donna is the only tuned recipe.
            Menu("Find and Tag") {
                Button("Donna") {
                    _ = fileOpsCenter.startedByUser {
                        $0.startFindPerson(person: "Donna",
                                           records: selectedRecs,
                                           model: model)
                    }
                    MediaFileOperationsWindowOpener.openBehindMain(openWindow)   // MFO window (legacy id)
                }
                Divider()
                // should not be hardwired rather lookup if recipes
                Text("Only Donna has a tuned recipe so far")
            }
        }
    }

    /// The disposition verdicts (one-of): Important, Recoverable,
    /// Suspected Junk, Junk, Clear.
    @ViewBuilder
    private func dispositionItems(selectedRecs: [VideoRecord]) -> some View {
        Button {
            setDisposition(.important, on: selectedRecs)
        } label: {
            Label("Important", systemImage: "star.fill")
        }
        Button {
            setDisposition(.recoverable, on: selectedRecs)
        } label: {
            Label("Recoverable", systemImage: "wrench.and.screwdriver.fill")
        }
        Button {
            setDisposition(.suspectedJunk, on: selectedRecs)
        } label: {
            Label("Suspected Junk", systemImage: "exclamationmark.triangle")
        }
        Button {
            setDisposition(.confirmedJunk, on: selectedRecs)
        } label: {
            Label("Junk", systemImage: "xmark.circle.fill")
        }
        Button {
            setDisposition(.unreviewed, on: selectedRecs)
        } label: {
            Label("Clear Verdict", systemImage: "arrow.counterclockwise")
        }
    }

    private func setDisposition(_ disposition: MediaDisposition, on recs: [VideoRecord]) {
        for r in recs { r.mediaDisposition = disposition }
        model.saveCatalogDebounced()
    }

    /// Workflow tags (2026-07-23): any-of markers. Each quick-pick toggles
    /// across the WHOLE selection; a mixed selection applies to all.
    @ViewBuilder
    private func workflowTagItems(selectedRecs: [VideoRecord]) -> some View {
        ForEach(WorkflowTags.quickPicks, id: \.self) { tag in
            let allHave = selectedRecs.allSatisfy {
                WorkflowTags.contains($0.tags, tag)
            }
            // Toggle in a menu renders as a checkmark
            // item. Binding get/set ≈ a C++ property
            // with custom getter/setter: get feeds the
            // checkmark, set runs the toggle action.
            Toggle(tag, isOn: Binding(
                get: { allHave },
                set: { model.setTag(tag, on: selectedRecs, present: $0) }
            ))
        }
        Button("Custom Tag\u{2026}") {
            customTagTargetIDs = Set(selectedRecs.map(\.id))
            customTagText = ""
            showCustomTagAlert = true
        }
        if selectedRecs.contains(where: { !$0.tags.isEmpty }) {
            Button("Remove All Tags") {
                model.removeAllTags(from: selectedRecs)
            }
        }
    }

    /// Other people / Families as plain TAGS (Rick 2026-10-09: "tag Bonnie,
    /// or Hudson Family at a Thanksgiving, without making a People-tab
    /// card"). New Person… / New Family… tag the selection with the typed
    /// name (a confirmed people tag, same as the inspector's New Person…);
    /// names used before are remembered in `TagNameMemory`, so they're one
    /// click the next time. No O(records) work: the lists are that memory.
    @ViewBuilder
    private func otherTagItems(selectedRecs: [VideoRecord], poiNames: [String]) -> some View {
        let poi = Set(poiNames.map { $0.lowercased() })
        Divider()
        Section("Other people") {
            ForEach(TagNameMemory.people.filter { !poi.contains($0.lowercased()) }, id: \.self) { name in
                tagToggle(name, selectedRecs: selectedRecs)
            }
            Button("New Person\u{2026}") {
                if let name = TagNameMemory.ask(title: "Tag a New Person",
                                                example: "Bonnie", kind: .people) {
                    model.setPerson(name, on: selectedRecs, present: true)
                }
            }
        }
        Section("Families") {
            ForEach(TagNameMemory.families, id: \.self) { name in
                tagToggle(name, selectedRecs: selectedRecs)
            }
            Button("New Family\u{2026}") {
                if let name = TagNameMemory.ask(title: "Tag a Family",
                                                example: "Hudson Family", kind: .families) {
                    model.setPerson(name, on: selectedRecs, present: true)
                }
            }
        }
    }

    private func tagToggle(_ name: String, selectedRecs: [VideoRecord]) -> some View {
        let allHave = selectedRecs.allSatisfy { rec in
            rec.taggedPeople.contains { $0.compare(name, options: .caseInsensitive) == .orderedSame }
        }
        return Toggle(name, isOn: Binding(
            get: { allHave },
            set: { model.setPerson(name, on: selectedRecs, present: $0) }
        ))
    }

    /// People ▸ — ONE menu (2026-10-07): who is in it (confirmed person
    /// tags, POI-database names only) and, at the bottom, Show in People
    /// tab ▸ (hand-pick for a person's or family's page, GH #272 — a tag
    /// says "in it", that says "show it").
    @ViewBuilder
    private func peopleMenu(selectedRecs: [VideoRecord]) -> some View {
        Menu("People") {
            // Family wildcard first: "lots of us are in
            // this one" — surfaces for ANY person search.
            let familyAllHave = selectedRecs.allSatisfy { rec in
                rec.taggedPeople.contains { $0.lowercased() == "family" }
            }
            Toggle("Family (everyone)", isOn: Binding(
                get: { familyAllHave },
                set: { model.setPerson("Family", on: selectedRecs, present: $0) }
            ))
            Divider()
            let poiNames = POIProfile.listAll().map(\.name).sorted()
            if poiNames.isEmpty {
                Text("No people in the People database yet")
            } else {
                ForEach(poiNames, id: \.self) { name in
                    // Checkmark reflects the STRONG tier
                    // (confirmed ∪ detected) — what the
                    // People column shows — so toggling
                    // off a wrong auto-detection reads
                    // checked → unchecked, not phantom.
                    let allHave = selectedRecs.allSatisfy { rec in
                        rec.taggedPeople.contains {
                            $0.compare(name, options: .caseInsensitive) == .orderedSame
                        }
                    }
                    Toggle(name, isOn: Binding(
                        get: { allHave },
                        set: { model.setPerson(name, on: selectedRecs, present: $0) }
                    ))
                }
            }
            otherTagItems(selectedRecs: selectedRecs, poiNames: poiNames)
            peopleClearItems(selectedRecs: selectedRecs)
            Divider()
            ShowInPeopleTabMenu(records: selectedRecs)
        }
    }

    /// Clear Machine Tags / Clear Rejections / Clear People Tags.
    @ViewBuilder
    private func peopleClearItems(selectedRecs: [VideoRecord]) -> some View {
        if selectedRecs.contains(where: {
            !$0.taggedPeople.isEmpty || !$0.suspectedPeople.isEmpty
                || !$0.rejectedPeople.isEmpty
        }) {
            Divider()
            if selectedRecs.contains(where: {
                !$0.detectedPeople.isEmpty || !$0.suspectedPeople.isEmpty
            }) {
                // Machine tiers only — your confirmed
                // tags and rejections survive.
                Button("Clear Machine Tags (*/?)") {
                    model.clearMachinePeopleTags(from: selectedRecs)
                }
            }
            if selectedRecs.contains(where: { !$0.rejectedPeople.isEmpty }) {
                // Rejections block Find & Tag by design
                // ("not X" must stick) — this is the
                // explicit undo when one was a mistake.
                Button("Clear Rejections (let recipes re-judge)") {
                    model.clearRejections(from: selectedRecs)
                }
            }
            Button("Clear People Tags") {
                model.removeAllPeople(from: selectedRecs)
            }
        }
    }

    /// Find Online Copy ▸ and All Matches ▸ for the record's duplicate group.
    @ViewBuilder
    private func duplicateMatchItems(rec: VideoRecord) -> some View {
        // Show duplicate group matches
        let groupMatches = records.filter {
            $0.id != rec.id && $0.duplicateGroupID != nil && $0.duplicateGroupID == rec.duplicateGroupID
        }
        if !groupMatches.isEmpty {
            let onlineMatches = groupMatches.filter {
                VolumeReachability.isReachable(path: $0.fullPath)
            }

            if !onlineMatches.isEmpty {
                // Extracted to a dedicated method so Xcode 16.4 has a tiny,
                // isolated type-check context for the Menu→ForEach→Section→
                // ForEach chain. Inline, the compiler was leaking
                // ChartContentBuilder candidates into overload resolution.
                onlineCopyMenu(onlineMatches: onlineMatches)
            }

            Menu("All Matches (\(groupMatches.count))") {
                ForEach(groupMatches) { dup in
                    let online = VolumeReachability.isReachable(path: dup.fullPath)
                    Button {
                        selectedIDs = [dup.id]
                        onSelect(dup.id)
                    } label: {
                        let vol = VolumeReachability.displayLabel(forPath: dup.fullPath)
                        Text("\(dup.filename) — \(vol)\(online ? "" : " (offline)")")
                    }
                }
            }
        }
    }

    /// Find A/V Pair and Find Online Version.
    @ViewBuilder
    private func findCopyItems(rec: VideoRecord) -> some View {
        if rec.streamType.needsCorrelation {
            Button("Find A/V Pair") {
                onFindAVPair?(rec)
            }
            .help("Show this file's best matching pair in the catalog, including any online duplicates of either side.")
        }

        // Find Online Version — only offered when the
        // file itself is unreachable (the verb answers
        // "this one's offline, what CAN I use?").
        // Strict identity match, never the fuzzy
        // duplicate scorer — see OnlineCopyFinder.
        if !VolumeReachability.isReachable(path: rec.fullPath) {
            Button {
                findOnlineVersion(for: rec)
            } label: {
                Label("Find Online Version",
                      systemImage: "externaldrive.badge.checkmark")
            }
            .help("Locate a copy of this file on a volume that is mounted right now and show it in the catalog.")
            .accessibilityIdentifier("catalog.row.findOnlineVersion")
        }
    }

    /// Find ▸ (2026-10-07): Find Similar Footage…, Show this file's
    /// journey, Show in Archive. A later "Original Material…" joins here.
    @ViewBuilder
    private func findMenu(rec: VideoRecord) -> some View {
        Menu("Find") {
            // Find Similar Footage (2026-09-23): the group this
            // file is in — likely original, roles, evidence —
            // in a read-only sheet (ellipsis: a sheet opens).
            Button {
                footageSheetRequest = FootageSheetRequest(recordID: rec.id)
            } label: {
                Label("Find Similar Footage…", systemImage: "square.stack.3d.up")
            }
            .help("Show the files that are probably the same footage as this one — copies, re-encodes, transcodes, exports — and which is likely the original.")
            .accessibilityIdentifier("catalog.row.findSimilarFootage")
            // §2 Provenance & Audit Trail — the File Journey
            // timeline. Works on every active row, including
            // ones with no relocate history (Origin → Current).
            Button {
                fileJourneyPayload = model.makeFileJourney(for: rec)
            } label: {
                Label("Show this file's journey",
                      systemImage: "mappin.and.ellipse")
            }
            .accessibilityIdentifier("catalog.row.showJourney")
            Button {
                onShowInArchive?(rec)
            } label: {
                Label("Show in Archive", systemImage: "archivebox")
            }
            // (Room for "Original Material…" — not built yet.)
        }
    }
}

/// The names typed into People ▸ New Person… / New Family… (Rick
/// 2026-10-09), remembered per Mac so they show up in the menu next time.
/// A convenience list only — the tags themselves live on the records; losing
/// this list loses nothing but the shortcut. (For Rick: a tiny persisted
/// string array, like a recent-items list.)
enum TagNameMemory {
    enum Kind: String { case people = "peopleMenu.otherPeople", families = "peopleMenu.families" }

    static var people: [String] { names(.people) }
    static var families: [String] { names(.families) }

    static func names(_ kind: Kind) -> [String] {
        (UserDefaults.standard.stringArray(forKey: kind.rawValue) ?? [])
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    static func remember(_ name: String, _ kind: Kind) {
        var list = UserDefaults.standard.stringArray(forKey: kind.rawValue) ?? []
        guard !list.contains(where: { $0.compare(name, options: .caseInsensitive) == .orderedSame }) else { return }
        list.append(name)
        UserDefaults.standard.set(list, forKey: kind.rawValue)
    }

    /// Ask for a name (modal: a menu item can't host a text field), remember
    /// it, and return it; nil on Cancel or an empty name.
    @MainActor
    static func ask(title: String, example: String, kind: Kind) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = "For example \u{201C}\(example)\u{201D}. This only tags the selected videos; "
            + "it doesn't add a card to the People tab."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "Name"
        alert.accessoryView = field
        alert.addButton(withTitle: "Tag")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        remember(name, kind)
        return name
    }
}
