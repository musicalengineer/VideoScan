import SwiftUI

// MARK: - InspectorFamilyTagsView
//
// "Family Tags" section of the catalog Inspector. v1 of roadmap item
// #3 (2026-06-04). Three tag tiers + manual-confirm workflow:
//
//   - detectedPeople     (auto): blue chips — what the engine saw
//   - suspectedPeople    (auto): italic gray — borderline matches
//   - confirmedByUserPeople (Rick): bold blue + checkmark — ground truth
//   - rejectedPeople     (Rick): red strikethrough — explicit "not them"
//
// Edit-mode toggle keeps the UI calm during browsing — a stray click
// on the inspector's tag chips shouldn't promote / reject anything.
// Add Confirmed Tag picker offers names from POIProfile.listAll()
// so manual tags merge naturally with the POI gallery used by the
// face-recognition engine.

struct InspectorFamilyTagsView: View {

    // VideoRecord is a plain class (not ObservableObject); the
    // existing InspectorPanel mutates record fields through Binding
    // get/set and lets the parent catalog @Published republishing
    // refresh the UI. Same pattern here, with a local refreshTick
    // that forces an immediate self-redraw after any mutation so the
    // chip rows reflect the new state without waiting on the parent.
    let record: VideoRecord
    @State private var editMode: Bool = false
    @State private var refreshTick: Int = 0
    /// Free-text "New Person…" prompt (Rick 2026-08-01: tagging "Dan"
    /// was impossible when Dan had no POI gallery profile).
    @State private var showNewPersonPrompt = false
    @State private var newPersonName = ""

    private var poiNames: [String] {
        POIProfile.listAll().map(\.name).sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Read-only chip rows. Always visible — these are the
            // "what does this record say" content the user came to
            // see. Edit mode just adds affordances on top.
            tagRow(
                label: "Detected",
                names: record.detectedPeople,
                color: .blue
            )
            tagRow(
                label: "Suspected",
                names: record.suspectedPeople.map { "?\($0)" },
                color: .secondary,
                italic: true
            )
            tagRow(
                label: "Confirmed by you",
                names: record.confirmedByUserPeople.map(\.name),
                color: .accentColor,
                bold: true,
                icon: "checkmark.seal.fill"
            )
            tagRow(
                label: "Rejected",
                names: record.rejectedPeople,
                color: .red,
                strikethrough: true
            )

            // Edit toggle. Default is read-only so accidental clicks
            // during browsing don't mutate state.
            Toggle("Edit Tags", isOn: $editMode.animation())
                .toggleStyle(.button)
                .controlSize(.small)
                .padding(.top, 4)

            if editMode {
                editModeControls
            }
        }
        .padding(.vertical, 4)
    }

    // MARK: - Tag row (read-only chip list)

    @ViewBuilder
    private func tagRow(
        label: String,
        names: [String],
        color: Color,
        bold: Bool = false,
        italic: Bool = false,
        strikethrough: Bool = false,
        icon: String? = nil
    ) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 110, alignment: .trailing)
            if names.isEmpty {
                Text("—")
                    .font(.system(size: 11))
                    .foregroundColor(.tertiaryLabel)
            } else {
                // Flow layout would be ideal but a horizontal HStack
                // wraps via SwiftUI's `LazyVGrid` would be heavy for
                // a few chips. Use a wrapped HStack via VStack of
                // single-line text; chips small enough to fit.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(names, id: \.self) { name in
                        HStack(spacing: 3) {
                            if let icon {
                                Image(systemName: icon)
                                    .font(.system(size: 9))
                                    .foregroundColor(color)
                            }
                            applyStyle(
                                Text(name),
                                color: color,
                                bold: bold,
                                italic: italic,
                                strikethrough: strikethrough
                            )
                            .font(.system(size: 11))
                            Spacer(minLength: 0)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func applyStyle(
        _ text: Text,
        color: Color,
        bold: Bool,
        italic: Bool,
        strikethrough: Bool
    ) -> Text {
        var t = text.foregroundColor(color)
        if bold { t = t.bold() }
        if italic { t = t.italic() }
        if strikethrough { t = t.strikethrough() }
        return t
    }

    // MARK: - Edit mode controls

    @ViewBuilder
    private var editModeControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Confirm-from-POI picker. Suggests existing POI gallery
            // names so manual tags merge cleanly with auto-tags, plus
            // a free-text "New Person…" for names with no gallery
            // profile yet (the tag still joins people: search
            // immediately; a POI profile can adopt it later).
            Menu {
                ForEach(poiNames, id: \.self) { name in
                    Button(name) { confirmTag(name: name) }
                }
                if !poiNames.isEmpty { Divider() }
                Button("New Person…") {
                    newPersonName = ""
                    showNewPersonPrompt = true
                }
            } label: {
                Label("Confirm Person…", systemImage: "checkmark.seal")
                    .font(.system(size: 11))
            }
            .controlSize(.small)
            .alert("Tag a New Person", isPresented: $showNewPersonPrompt) {
                TextField("Name", text: $newPersonName)
                Button("Add") {
                    confirmTag(name: newPersonName.trimmingCharacters(in: .whitespaces))
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Adds a confirmed person tag to this video — it matches people: searches right away.")
            }

            // Reject auto-detected people: each chip becomes a button
            // that moves it to rejectedPeople. v1 limits this to the
            // detectedPeople list (the most common mistake).
            if !record.detectedPeople.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Reject auto")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(record.detectedPeople, id: \.self) { name in
                            Button(action: { rejectAutoDetected(name: name) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 9))
                                    Text(name)
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(.red)
                            }
                            .buttonStyle(.plain)
                            .help("Mark '\(name)' as wrong on this record")
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            // Remove a confirmed tag (undo a manual confirm).
            if !record.confirmedByUserPeople.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Un-confirm")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(record.confirmedByUserPeople) { tag in
                            Button(action: { unconfirm(tagId: tag.id) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark.circle")
                                        .font(.system(size: 9))
                                    Text(tag.name)
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }

            // Un-reject. Useful when Rick clicks reject by mistake.
            if !record.rejectedPeople.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    Text("Un-reject")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                        .frame(width: 110, alignment: .trailing)
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(record.rejectedPeople, id: \.self) { name in
                            Button(action: { unreject(name: name) }) {
                                HStack(spacing: 4) {
                                    Image(systemName: "arrow.uturn.backward.circle")
                                        .font(.system(size: 9))
                                    Text(name)
                                        .font(.system(size: 11))
                                }
                                .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    // MARK: - Mutations

    private func confirmTag(name: String) {
        guard !name.isEmpty else { return }
        // Idempotent, case-insensitively: free-text "dan" must not
        // double-tag alongside a gallery "Dan".
        guard !record.confirmedByUserPeople.contains(where: {
            $0.name.compare(name, options: .caseInsensitive) == .orderedSame
        }) else { return }
        record.confirmedByUserPeople.append(ConfirmedTag(name: name, confirmedAt: Date()))
        // Confirming a name un-rejects it implicitly — the user
        // changed their mind.
        record.rejectedPeople.removeAll { $0 == name }
        save()
    }

    private func rejectAutoDetected(name: String) {
        // Add to rejectedPeople (idempotent), drop from detectedPeople.
        // Don't touch suspectedPeople — those are already low-
        // confidence; explicit rejection requires explicit click.
        if !record.rejectedPeople.contains(name) {
            record.rejectedPeople.append(name)
        }
        record.detectedPeople.removeAll { $0 == name }
        save()
    }

    private func unconfirm(tagId: String) {
        record.confirmedByUserPeople.removeAll { $0.id == tagId }
        save()
    }

    private func unreject(name: String) {
        record.rejectedPeople.removeAll { $0 == name }
        save()
    }

    private func save() {
        // Bump the redraw counter so the chip rows reflect the new
        // record state immediately. The notification below kicks the
        // catalog save through VideoScanModel's listener; passing the
        // record lets the listener refresh the search index entry so a
        // fresh confirm is people:-searchable NOW (gap found during the
        // 2026-08-01 archivist perf pass — tags used to stay unsearchable
        // until the next full rebuild).
        refreshTick &+= 1
        NotificationCenter.default.post(name: .videoScanCatalogMutated, object: record)
    }
}

extension Notification.Name {
    /// Posted when the inspector mutates a VideoRecord's tag fields.
    /// VideoScanModel listens for this and triggers a debounced save.
    static let videoScanCatalogMutated = Notification.Name("VideoScanCatalogMutated")
}

private extension Color {
    static var tertiaryLabel: Color { Color(NSColor.tertiaryLabelColor) }
}
