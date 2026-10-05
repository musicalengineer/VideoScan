// CatalogRowContextMenu+Organize.swift
// Rename / tag / people / music / notes / duplicates / navigation items
// of the Catalog row menu, cut out of the single rowContextMenu builder
// section by section (R1 refactor, GH #281).
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)

import SwiftUI

extension CatalogContent {

    /// The active-only half of the full row menu (pure-active selections
    /// only): rename, tagging, people, music, notes, duplicates and
    /// navigation (R1 split, GH #281).
    @ViewBuilder
    func organizeItems(rec: VideoRecord, selection: CatalogRowMenuSelection) -> some View {
        renameAndDispositionItems(rec: rec, selectedRecs: selection.selected)

        workflowTagsMenu(selectedRecs: selection.selected)

        peopleItems(selectedRecs: selection.selected)

        familyMusicItems(activeRecs: selection.active)

        findAndTagAndNotesItems(rec: rec, selectedRecs: selection.selected)

        duplicateMatchItems(rec: rec)

        findCopyItems(rec: rec)
        navigationItems(rec: rec)
    }

    /// Rename… and the disposition Tag ▸ submenu.
    @ViewBuilder
    private func renameAndDispositionItems(rec: VideoRecord, selectedRecs: [VideoRecord]) -> some View {
        Divider()

        Button("Rename…") {
            renameTarget = rec
            renameText = (rec.filename as NSString).deletingPathExtension
            showRenameSheet = true
        }

        Divider()

        Menu("Tag") {
            Button {
                for r in selectedRecs { r.mediaDisposition = .important }
                model.saveCatalogDebounced()
            } label: {
                Label("Important", systemImage: "star.fill")
            }
            Button {
                for r in selectedRecs { r.mediaDisposition = .recoverable }
                model.saveCatalogDebounced()
            } label: {
                Label("Recoverable", systemImage: "wrench.and.screwdriver.fill")
            }

            Divider()

            Button {
                for r in selectedRecs { r.mediaDisposition = .suspectedJunk }
                model.saveCatalogDebounced()
            } label: {
                Label("Suspected Junk", systemImage: "exclamationmark.triangle")
            }
            Button {
                for r in selectedRecs { r.mediaDisposition = .confirmedJunk }
                model.saveCatalogDebounced()
            } label: {
                Label("Junk", systemImage: "xmark.circle.fill")
            }

            Divider()

            Button {
                for r in selectedRecs { r.mediaDisposition = .unreviewed }
                model.saveCatalogDebounced()
            } label: {
                Label("Clear Tag", systemImage: "arrow.counterclockwise")
            }
        }
    }

    /// Workflow Tags ▸ submenu.
    @ViewBuilder
    private func workflowTagsMenu(selectedRecs: [VideoRecord]) -> some View {
        // Workflow tags (2026-07-23) — separate from the
        // disposition "Tag" menu above: dispositions are
        // one-of (keep/junk verdicts), these are any-of
        // markers ("Follow Up", "Gold", your own words).
        // Each quick-pick toggles across the WHOLE
        // selection; a mixed selection applies to all.
        Menu("Tags") {
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
            Divider()
            Button("Custom Tag\u{2026}") {
                customTagTargetIDs = Set(selectedRecs.map(\.id))
                customTagText = ""
                showCustomTagAlert = true
            }
            if selectedRecs.contains(where: { !$0.tags.isEmpty }) {
                Divider()
                Button("Remove All Tags") {
                    model.removeAllTags(from: selectedRecs)
                }
            }
        }
    }

    /// Show in People Tab ▸ and People ▸.
    @ViewBuilder
    private func peopleItems(selectedRecs: [VideoRecord]) -> some View {
        // People (Rick 2026-08-01): confirmed person tags,
        // POI-database names ONLY — controlled vocabulary
        // keeps manual tags joined to the recognition
        // gallery. Multi-select toggles across the whole
        // selection, same semantics as the Tags menu.
        // Hand-pick for a person's People-tab page
        // (Rick 2026-10-04, GH #272) — separate from
        // tagging: a tag says "in it", this says "show it".
        ShowInPeopleTabMenu(records: selectedRecs)
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
    }

    /// Mark / Unmark as Family Music.
    @ViewBuilder
    private func familyMusicItems(activeRecs: [VideoRecord]) -> some View {
        // Family Music (Rick 2026-09-23): the ONLY way a file
        // gets on the Archive tab's Music shelf — a human
        // mark, never a rule, so bought music never shows.
        // Mark opens a sheet (ellipsis); Unmark acts at once.
        // Active rows only; multi-select: one sheet for all.
        let markable = CatalogRowMenuRules.familyMusicMarkable(activeRecs)
        let markedRecs = CatalogRowMenuRules.familyMusicMarked(activeRecs)
        Button {
            familyMusicSheetRequest = FamilyMusicSheetRequest.make(for: markable)
        } label: {
            Label(FamilyMusicMenu.markTitle, systemImage: "music.note")
        }
        .disabled(markable.isEmpty || model.isReadOnly)
        .help("Put this recording (or video of someone playing) on the Family Music shelf in the Archive tab. Only files you mark ever appear there.")
        .accessibilityIdentifier("catalog.row.markFamilyMusic")
        if !markedRecs.isEmpty {
            Button {
                model.unmarkFamilyMusic(markedRecs.map(\.id))
            } label: {
                Label(FamilyMusicMenu.unmarkTitle, systemImage: "music.note")
            }
            .disabled(model.isReadOnly)
            .accessibilityIdentifier("catalog.row.unmarkFamilyMusic")
        }
    }

    /// Find and Tag ▸ and Notes….
    @ViewBuilder
    private func findAndTagAndNotesItems(rec: VideoRecord, selectedRecs: [VideoRecord]) -> some View {
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

        Button("Notes\u{2026}") {
            notesTarget = rec
            // userNotes split (2026-07-23): the sheet
            // edits YOUR note text; machine probe notes
            // stay read-only in the inspector.
            notesText = rec.userNotes
            showNotesSheet = true
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
        // ("Compare These Two Files…" moved to the
        // file-operations section near the top of this
        // menu — Rick 2026-06-10: all fileops verbs
        // grouped + alphabetized.)

        if rec.streamType.needsCorrelation {
            Divider()
            Button("Find A/V Pair") {
                onFindAVPair?(rec)
            }
            .help("Show this file's best matching pair in the catalog, including any online duplicates of either side.")
        }
        // ("Combine This Pair…" likewise lives in the
        // file-operations section now.)

        // Find Online Version — only offered when the
        // file itself is unreachable (the verb answers
        // "this one's offline, what CAN I use?").
        // Strict identity match, never the fuzzy
        // duplicate scorer — see OnlineCopyFinder.
        if !VolumeReachability.isReachable(path: rec.fullPath) {
            Divider()
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

    /// Show in Archive, Find Similar Footage…, journey, Copy Path.
    @ViewBuilder
    private func navigationItems(rec: VideoRecord) -> some View {
        Divider()
        Button {
            onShowInArchive?(rec)
        } label: {
            Label("Show in Archive", systemImage: "archivebox")
        }
        // §2 Provenance & Audit Trail — surface the
        // File Journey timeline for this record. Works
        // on every active row, including ones with no
        // relocate history (the timeline just shows
        // Origin → Current). Active-only — purged
        // rows don't need it.
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
        Button {
            fileJourneyPayload = model.makeFileJourney(for: rec)
        } label: {
            Label("Show this file's journey",
                  systemImage: "mappin.and.ellipse")
        }
        .accessibilityIdentifier("catalog.row.showJourney")
        Button("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(rec.fullPath, forType: .string)
        }
    }
}
