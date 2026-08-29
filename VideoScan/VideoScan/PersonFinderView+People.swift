// PersonFinderView+People.swift
// The People gallery — saved family profiles, the inline undo banner, the
// person-card sizing math, and the gallery's alerts/sheets — extracted
// verbatim from PersonFinderView's body in PersonFinderView.swift
// (refactor 2026-06-24). A cross-file `extension` can't see `private`
// members, so the handful of PersonFinderView members this code shares
// with the other split files were widened to internal in the main file.
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here
// means file-private to THIS file.)
//
// 2026-07-25: added the holdout Review badge — nag-button pattern: the
// badge IS the entry point that performs the review (one verb, one
// meaning). It appears on a person's card only while the newest blind
// holdout queue (HoldoutReviewQueue.discover) is for that person and has
// pending rows; it opens ConfirmPersonSheet in blind holdout mode and
// disappears once every row is answered.
//
// 2026-08-29: the gallery shows one GEDCOM concept: a green check means the
// profile has a usable, collision-free `.pinned` tree identity. The header's
// session-only "Show Missing GEDCOM" checkbox filters to every other reducer
// state. Rich derived/ambiguous/problem diagnostics remain in the editor.

import SwiftUI
import AppKit

extension PersonFinderView {

    /// Image diameter scales linearly with the gallery height, leaving
    /// ~70pt headroom for the name label and padding. Clamped so cards
    /// stay tappable at the floor and don't overflow at the ceiling.
    var personImageSize: CGFloat {
        CGFloat(min(max(peopleGalleryHeight - 70, 56), 260))
    }
    var personCardWidth: CGFloat {
        max(personImageSize + 24, 96)
    }
    var personNameFontSize: CGFloat {
        min(max(11 + (personImageSize - 64) * 0.07, 11), 20)
    }

    /// Per-profile tree-link badges, memoised by TreeIdentityCenter on
    /// (tree generation, identity signature, pinsRevision, derivation
    /// pass). Reading it in the body is a key compare + dictionary return.
    var treeLinkBadges: [String: TreeLinkBadge] {
        identityCenter.treeLinkBadges(for: model.savedProfiles)
    }

    /// Inline undo affordance for the most recent POI delete. Stays visible
    /// until the user clicks Undo / dismisses with the × / a new delete
    /// supersedes it / app relaunch (session-scope state). No auto-dismiss
    /// timer — Rick wants to take his time.
    @ViewBuilder
    var undoBanner: some View {
        if let snap = model.lastDeletedPOI {
            HStack(spacing: 10) {
                Image(systemName: "trash.slash")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(.orange)
                if let err = model.lastUndoError {
                    Text(err)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.red)
                } else {
                    Text("Deleted '\(snap.name)'.")
                        .font(.system(size: 12))
                        .foregroundColor(.primary)
                }
                Button("Undo") {
                    Task { @MainActor in
                        _ = await model.undoLastDelete()
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: .command)

                Spacer()

                Button {
                    model.dismissUndoBanner()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.secondary, Color.secondary.opacity(0.2))
                }
                .buttonStyle(.plain)
                .help("Dismiss — the POI stays in ~/dev/VideoScan/.trash/ for manual recovery")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.orange.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(Color.orange.opacity(0.35), lineWidth: 1)
            )
            .transition(.opacity.combined(with: .move(edge: .top)))
        }
    }

    /// Holdout Review badge — shown on a PersonCard while the newest
    /// blind review queue is for this person and still has pending rows.
    /// Clicking it opens the review directly (nag-button pattern: the
    /// badge performs the work). Visibility state lives in
    /// holdoutReview (PersonFinderView.swift); no file I/O happens here.
    ///
    /// PLACEMENT NOTE: currently overlaid top-trailing on the card —
    /// deliberately a self-contained view so moving it is a one-line
    /// change wherever Rick wants it after spot-test.
    @ViewBuilder
    func holdoutReviewBadge(for profile: POIProfile) -> some View {
        if let queue = holdoutReview.pendingQueue(for: profile.name) {
            Button {
                confirmTarget = ConfirmSheetTarget(profile: profile, holdoutQueue: queue)
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "eye.fill")
                    Text("Review \(queue.pendingCount)")
                }
                .font(.system(size: max(9, personNameFontSize * 0.72), weight: .semibold))
                .foregroundColor(.white)
                .padding(.horizontal, 7)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.purple))
                .overlay(
                    Capsule().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.5)
                )
            }
            .buttonStyle(.plain)
            .help("\(queue.pendingCount) holdout video\(queue.pendingCount == 1 ? "" : "s") awaiting your blind yes/no review — click to start")
            .accessibilityIdentifier("pf.holdout.review.\(profile.name)")
        }
    }

    var peopleGallery: some View {
        // Build the memoised reducer map once per gallery evaluation, then
        // perform at most one O(people) filter before entering card bodies.
        // Each card below does one dictionary lookup; no reducer work occurs
        // in the ForEach body.
        let treeLinks = treeLinkBadges
        let displayedProfiles = showMissingGEDCOM
            ? model.savedProfiles.filter { !TreeLinkBadge.hasGEDCOMID(treeLinks[$0.id]) }
            : model.savedProfiles

        return VStack(alignment: .leading, spacing: 6) {
            // Inline undo banner — armed by deletePOI, dismissed by undo /
            // dismiss / superseded by next delete / app relaunch. No timers.
            // Sits ABOVE the header so it never reflows the grid below
            // (the VStack just gets one more row).
            undoBanner

            HStack {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Family")
                    .font(.headline)
                Spacer()
                if !model.savedProfiles.isEmpty {
                    Label {
                        Text("GEDCOM ID")
                            .foregroundStyle(.secondary)
                    } icon: {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }
                    .font(.callout)
                    .help("A green check means this person has a usable GEDCOM ID in the current family tree")
                    .accessibilityLabel("Green check means GEDCOM ID linked")

                    Toggle("Show Missing GEDCOM", isOn: $showMissingGEDCOM)
                    .toggleStyle(.checkbox)
                    .controlSize(.small)
                    .fixedSize()
                    .help("Show only people who do not yet have a usable GEDCOM ID")
                    .accessibilityIdentifier("pf.people.showMissingGEDCOM")

                    Text(displayedProfiles.count == model.savedProfiles.count
                         ? "\(model.savedProfiles.count) people"
                         : "\(displayedProfiles.count) of \(model.savedProfiles.count) people")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }

            if let error = holdoutReview.errorMessage {
                Label("Blind review queue could not be loaded",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
                    .help(error)
                    .accessibilityValue(error)
            }

            // Durable trace of a background answer-write failure — the
            // review sheet may already be dismissed when a queued write
            // fails (QA 2026-07-26 🟠). Cleared when the review reopens.
            if let writeFailure = holdoutReview.answerWriteFailure {
                Label(writeFailure, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.red)
                    .help(writeFailure)
                    .accessibilityValue(writeFailure)
            }

            if model.savedProfiles.isEmpty {
                // Empty state — prominent Add Person button
                VStack(spacing: 10) {
                    Button {
                        editingOriginalName = nil
                        editingProfile = POIProfile(name: "", referencePath: "")
                    } label: {
                        Label("Add Person\u{2026}", systemImage: "person.badge.plus")
                            .font(.title3.weight(.medium))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)

                    Text("Add family members, choose their reference photos, and scan your video library to find them")
                        .font(.caption)
                        .foregroundColor(.secondary.opacity(0.8))
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 400)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        // Add Person — always left-aligned
                        Button {
                            editingOriginalName = nil
                            editingProfile = POIProfile(name: "", referencePath: "")
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                        .foregroundColor(.secondary.opacity(0.4))
                                        .frame(width: personImageSize, height: personImageSize)
                                    Image(systemName: "plus")
                                        .font(.system(size: personImageSize * 0.34, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                Text("Add Person")
                                    .font(.system(size: personNameFontSize, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: personCardWidth)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)

                        // Build set of all people currently being scanned across all active jobs
                        let scanningNames = Set(model.jobs.filter { $0.status.isActive }.compactMap { $0.assignedProfile?.name.lowercased() })
                        ForEach(displayedProfiles) { profile in
                            let isBeingScanned = scanningNames.contains(profile.name.lowercased())
                            let isActive = isBeingScanned
                            PersonCard(profile: profile,
                                       isActive: isActive,
                                       justSaved: justSavedProfileID == profile.id,
                                       imageSize: personImageSize,
                                       cardWidth: personCardWidth,
                                       nameFontSize: personNameFontSize,
                                       relationshipsLine: kinshipCenter.relationshipsLine(
                                           for: profile, among: model.savedProfiles),
                                       aliasWarning: kinshipCenter.aliasWarning(
                                           for: profile, among: model.savedProfiles),
                                       portrait: photoCenter.peoplePhoto(
                                           for: profile, among: model.savedProfiles,
                                           kinshipCenter: kinshipCenter))
                                // Holdout Review badge — top-trailing over
                                // the portrait. The Button in the overlay
                                // wins the click over the card's
                                // onTapGesture below (deepest view first).
                                .overlay(alignment: .topTrailing) {
                                    holdoutReviewBadge(for: profile)
                                }
                                // A green check is the only tree state shown
                                // in the gallery. Derived, ambiguous, broken,
                                // absent, and not-in-tree all appear only via
                                // "Show Missing GEDCOM" and editor details.
                                .overlay(alignment: .topLeading) {
                                    if let badge = treeLinks[profile.id],
                                       TreeLinkBadge.hasGEDCOMID(badge) {
                                        GEDCOMIDCheckView(badge: badge,
                                                          personName: profile.name) {
                                            showInFamilyTree(profile)
                                        }
                                        .accessibilityIdentifier("pf.treelink.\(profile.name)")
                                    }
                                }
                                .opacity(isBeingScanned ? 0.7 : 1.0)
                                // Gauntlet flow 1 right-clicks the card to
                                // reach "Search for <name>…". Test-only.
                                .accessibilityIdentifier("pf.person.\(profile.name)")
                                .onTapGesture {
                                    if isBeingScanned {
                                        scanLockMessage = "Cannot edit \(profile.name) while scanning for \(profile.name)."
                                        return
                                    }
                                    // Load this person's reference faces into the strip for inspection
                                    model.settings.applyProfile(profile)
                                    model.settings.save()
                                    model.referenceFaces.removeAll()
                                    model.referenceLoadFailures.removeAll()
                                    Task { await model.loadReference() }
                                }
                                .draggable(profile.id) {
                                    PersonCard(profile: profile,
                                               isActive: false,
                                               imageSize: personImageSize * 0.8,
                                               cardWidth: personCardWidth * 0.8,
                                               nameFontSize: personNameFontSize)
                                        .opacity(0.8)
                                }
                                .dropDestination(for: String.self) { items, _ in
                                    guard let fromID = items.first else { return false }
                                    model.reorderProfiles(fromID: fromID, toID: profile.id)
                                    draggingProfileID = nil
                                    return true
                                } isTargeted: { targeted in
                                    if targeted { draggingProfileID = profile.id }
                                }
                                .overlay(
                                    RoundedRectangle(cornerRadius: 8)
                                        .stroke(Color.accentColor, lineWidth: 2)
                                        .opacity(draggingProfileID == profile.id ? 1 : 0)
                                        .animation(.easeInOut(duration: 0.15), value: draggingProfileID)
                                )
                                .contextMenu {
                                    Button("Search for \(profile.name)\u{2026}") {
                                        addJobForPerson(profile)
                                    }
                                    Divider()
                                    Button("Show \(profile.name) in Family Tree") {
                                        showInFamilyTree(profile)
                                    }
                                    Divider()
                                    Button("Edit \(profile.name)\u{2026}") {
                                        editingOriginalName = profile.name
                                        editingProfile = profile
                                    }
                                    Divider()
                                    // ONE review entry point (unified-review
                                    // 2026-07-27): replaces the old
                                    // "Confirm <name>…" item. Holdout-first
                                    // when a blind queue is pending for this
                                    // person, straight to candidates
                                    // otherwise — same verb as the badge.
                                    Button("Review \(profile.name)\u{2026}") {
                                        confirmTarget = ConfirmSheetTarget(
                                            profile: profile,
                                            holdoutQueue: holdoutReview.pendingQueue(for: profile.name))
                                    }
                                    .help("Blind holdout review first (when one is pending), then rate catalog-flagged candidates Definitely / Likely / No. Builds the labeled set the classifier trains on.")
                                    Button("View Confirmations\u{2026}") {
                                        confirmationsTarget = ConfirmationsTarget(profile: profile)
                                    }
                                    .help("Cumulative progress: outcomes, signal precision, rounds, what remains.")
                                    if !model.referenceFaces.isEmpty && model.settings.personName.lowercased() == profile.name.lowercased() {
                                        Divider()
                                        Menu("Remove Low-Confidence Photos") {
                                            let poorCount = model.referenceFaces.filter { $0.confidence < 0.60 }.count
                                            let belowGoodCount = model.referenceFaces.filter { $0.confidence < 0.80 }.count
                                            Button("Below Fair (< 60%) — \(poorCount) photo\(poorCount == 1 ? "" : "s")") {
                                                model.removeReferenceFaces(belowConfidence: 0.60)
                                            }
                                            .disabled(poorCount == 0)
                                            Button("Below Good (< 80%) — \(belowGoodCount) photo\(belowGoodCount == 1 ? "" : "s")") {
                                                model.removeReferenceFaces(belowConfidence: 0.80)
                                            }
                                            .disabled(belowGoodCount == 0)
                                        }
                                    }
                                    Divider()
                                    Button("Delete \(profile.name)\u{2026}", role: .destructive) {
                                        confirmDeleteProfile = profile
                                    }
                                    .keyboardShortcut(.delete, modifiers: .command)
                                }
                        }

                        // Step 3: "Search for Family" — fan a scan across
                        // every saved POI profile against a folder picked
                        // via NSOpenPanel. One click, N parallel jobs.
                        // Disabled until at least one profile has photos
                        // loaded, otherwise enqueueFamilyJobs filters
                        // them all out and the click would no-op silently.
                        Button {
                            browseForFamilyScanFolder()
                        } label: {
                            VStack(spacing: 6) {
                                ZStack {
                                    Circle()
                                        .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [5, 3]))
                                        .foregroundColor(.accentColor.opacity(0.6))
                                        .frame(width: personImageSize, height: personImageSize)
                                    Image(systemName: "person.2.crop.square.stack.fill")
                                        .font(.system(size: personImageSize * 0.34, weight: .medium))
                                        .foregroundColor(.accentColor)
                                }
                                Text("Search for Family")
                                    .font(.system(size: personNameFontSize, weight: .medium))
                                    .foregroundColor(.accentColor)
                                    .lineLimit(1)
                            }
                            .frame(width: personCardWidth)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(model.savedProfiles.allSatisfy { $0.referencePath.isEmpty })
                        .help("Pick a folder or volume — every saved person will be scanned against it in parallel. Catalog rows for matched files get tagged with the detected name(s).")
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(height: peopleGalleryHeight)

                // Drag handle to resize the People gallery — the photos
                // grow/shrink with the pane height, so this is also the
                // size control. Mirrors the reference-faces-strip pattern.
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 5)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                peopleGalleryHeight = max(110, min(420, peopleGalleryHeight + value.translation.height))
                            }
                    )
                    .help("Drag to resize the People gallery — photos scale to fit")
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, model.savedProfiles.isEmpty ? 10 : 0)
        .background(Color(NSColor.windowBackgroundColor))
        // Discover the newest holdout queue off the view body — a tiny
        // directory scan + 36-row CSV parse, but it's still file I/O.
        .task { await holdoutReview.refresh() }
        // One-time background tree load so tree-anchored relationships show
        // a name, not a bare FamilySearch ID (KinshipDisplayCenter).
        .task { kinshipCenter.loadTreeIfNeeded() }
        // Auto-derive tree identities for unpinned profiles (off main,
        // memoised per tree generation + identity signature); owner / root
        // verdicts are pinned at once (TreeIdentityCenter).
        .task(id: identityCenter.refreshKey(for: model.savedProfiles)) {
            await identityCenter.refresh(profiles: model.savedProfiles)
        }
        .onChange(of: identityCenter.pinsRevision) { _, _ in
            model.savedProfiles = POIProfile.listAll()
        }
        .sheet(item: $identityPickTarget) { target in
            TreeIdentityPickerSheet(target: target, center: identityCenter,
                                    profiles: model.savedProfiles,
                                    onPinned: { candidate in
                                        identityPickTarget = nil
                                        focusFamilyTree(profileName: target.profile.name, candidate: candidate, banner: .pinned)
                                    },
                                    onDismiss: { identityPickTarget = nil })
        }
        .alert("Delete '\(confirmDeleteProfile?.name ?? "")' and all reference photos?",
               isPresented: Binding(
            get: { confirmDeleteProfile != nil },
            set: { if !$0 { confirmDeleteProfile = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmDeleteProfile = nil }
            Button("Delete", role: .destructive) {
                if let p = confirmDeleteProfile {
                    let name = p.name
                    Task { @MainActor in
                        let ok = await model.deletePOI(named: name)
                        if !ok {
                            scanLockMessage = "Could not move '\(name)' into .trash/. Check ~/dev/VideoScan/.trash/ permissions."
                        }
                    }
                    confirmDeleteProfile = nil
                }
            }
        } message: {
            Text("Data is moved to ~/dev/VideoScan/.trash/POI-\(POIStorage.sanitize(confirmDeleteProfile?.name ?? ""))-<UTC>/ and is recoverable until you empty the trash manually. Nothing is permanently deleted.")
        }
        .alert("Scan in Progress", isPresented: Binding(
            get: { scanLockMessage != nil },
            set: { if !$0 { scanLockMessage = nil } }
        )) {
            Button("OK", role: .cancel) { scanLockMessage = nil }
        } message: {
            Text(scanLockMessage ?? "")
        }
        .sheet(item: $editingProfile) { profile in
            PersonEditSheet(profile: profile,
                            otherProfiles: model.savedProfiles,
                            kinshipCenter: kinshipCenter,
                            treeLink: treeLinkBadges[profile.id]) { edited in
                // A cover edit is an explicit photo choice (one photo per
                // person, 2026-08-29): stamp it and, when this profile is
                // bridged to a tree person, copy it into the family archive
                // so the Family Tree card shows the same photo.
                var updated = edited
                PersonPhotoSync.applyCoverChoice(
                    to: &updated, previous: profile, profiles: model.savedProfiles,
                    graph: kinshipCenter.graph,
                    store: FamilyAssetConfigurationCenter.shared.snapshot().makeStore(),
                    fingerprint: { kinshipCenter.graphFingerprint })
                photoCenter.invalidate()
                model.updateProfile(updated, oldName: editingOriginalName)
                // If this person is now the active POI, reload their faces
                if model.settings.personName.lowercased() == updated.name.lowercased() {
                    Task { await model.loadPOI(updated) }
                }
                // Flash the saved indicator on the card
                justSavedProfileID = updated.id
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    justSavedProfileID = nil
                }
            }
        }
        .sheet(item: $confirmTarget, onDismiss: {
            // Re-read the queue CSV so the Review badge count drops as
            // answers land and the badge disappears when the queue is done.
            Task { await holdoutReview.refresh() }
        }) { target in
            ConfirmPersonSheet(profile: target.profile,
                               holdoutQueue: target.holdoutQueue,
                               onViewConfirmations: {
                // Summary-pane jump to the cumulative dashboard. The
                // review sheet dismisses itself first; setting the item
                // here presents the next sheet (both are .sheet(item:) —
                // chained-sheet antipattern avoided).
                confirmationsTarget = ConfirmationsTarget(profile: target.profile)
            })
                .environmentObject(model)
                .environmentObject(catalogModel)
                // Badge center rides along so post-dismissal write
                // failures have somewhere durable to land.
                .environmentObject(holdoutReview)
        }
        .sheet(item: $confirmationsTarget) { target in
            ConfirmationsView(profile: target.profile, onConfirmMore: {
                // Same unified session as the menu/badge — holdout rows
                // first when a blind queue is pending (one verb, one
                // meaning; the dashboard is not a bypass).
                confirmTarget = ConfirmSheetTarget(
                    profile: target.profile,
                    holdoutQueue: holdoutReview.pendingQueue(for: target.profile.name))
            })
            .environmentObject(model)
            .environmentObject(catalogModel)
        }
    }
}
