// PersonEditSheet.swift
// Edit/create a person-of-interest profile — name, aliases, reference photos,
// cover crop, notes, and (2026-08-27) typed local relationships.

import SwiftUI
import PhotosUI
import VideoScanCore

/// Pure save gate shared by the sheet and regression tests. The UI owns
/// presentation and dismissal; this seam owns only validation and the
/// three-way decision, like a small command validator in C++.
enum PersonEditSheetKinshipSave {
    enum Decision: String, Equatable {
        case blocked
        case warningConfirmationRequired
        case save
    }

    struct Evaluation {
        let profile: POIProfile
        let findings: [KinshipValidation.Finding]
        let decision: Decision
    }

    /// New row values win, while an existing row's free-form note survives
    /// an edit. Sibling basis is part of the new row value and is never
    /// overwritten by the old row.
    static func preservingNotes(in rows: [Kinship], from currentRows: [Kinship]) -> [Kinship] {
        rows.map { row in
            var result = row
            if let existing = currentRows.first(where: {
                $0.relation == row.relation && $0.relativeTo == row.relativeTo
            }) {
                result.note = existing.note
            }
            return result
        }
    }

    static func evaluate(
        profile: POIProfile,
        otherProfiles: [POIProfile],
        graph: GedcomFamilyGraph?,
        currentRows: [Kinship],
        warningsAcknowledged: Bool
    ) -> Evaluation {
        // PersonFinderView passes the complete saved-profile array, including
        // the original version of the subject being edited. Replace that
        // snapshot in place; appending the edited copy would leave two rows
        // for one logical person and let validation select stale kinships.
        var validationProfiles = otherProfiles
        if let subjectIndex = validationProfiles.firstIndex(where: { $0.uuid == profile.uuid }) {
            validationProfiles[subjectIndex] = profile
        } else {
            validationProfiles.append(profile)
        }
        let results = KinshipValidation.validate(
            batch: profile.kinships,
            subjectProfileStableID: profile.id,
            profiles: validationProfiles,
            graph: graph,
            currentRows: currentRows)
        let findings = results.flatMap(\.findings)
        let decision: Decision
        if findings.blocksSave {
            decision = .blocked
        } else if !findings.isEmpty, !warningsAcknowledged {
            decision = .warningConfirmationRequired
        } else {
            decision = .save
        }
        return Evaluation(profile: profile, findings: findings, decision: decision)
    }

    /// Privacy-safe audit records. Finding messages contain names and dates,
    /// so only stable rule identifiers and severity cross the log boundary.
    static func resultLine(
        _ evaluation: Evaluation,
        elapsed: Duration
    ) -> String {
        let rules = Set(evaluation.findings.map {
            "\($0.severity.rawValue):\($0.rule.rawValue)"
        }).sorted()
        let elapsedMS = max(0, Int((elapsed / .milliseconds(1)).rounded()))
        return "[kinship-save] validation result=\(evaluation.decision.rawValue) "
            + "elapsed_ms=\(elapsedMS) rows=\(evaluation.profile.kinships.count) "
            + "rules=\(rules.isEmpty ? "none" : rules.joined(separator: ","))"
    }
}

// MARK: - Person Edit Sheet

struct PersonEditSheet: View {
    let originalProfile: POIProfile
    /// Every saved profile (including this one) — the relationship picker's
    /// "of whom" choices, and the derived-line preview's overlay input.
    let otherProfiles: [POIProfile]
    let onSave: (POIProfile) -> Void
    /// Family-tree names for tree-anchored relationships; loads once in the
    /// background. (`@ObservedObject` ≈ subscribe to someone else's object —
    /// the sheet does NOT own it.)
    @ObservedObject var kinshipCenter: KinshipDisplayCenter
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var notes: String
    @State private var aliasText: String
    @State private var coverFilename: String?
    @State private var referencePath: String
    // Identity metadata (feeds match plausibility ranking — see
    // IdentityNarrowing.swift). All optional; nil = not set.
    @State private var birthdate: Date?
    @State private var deathdate: Date?
    @State private var sex: PersonSex?
    @State private var hairColor: HairColor?
    @State private var eyeColor: EyeColor?
    @State private var identityNotes: String
    // Relationships — one editable row per stored Kinship. Rows carry a
    // UUID so SwiftUI can track them across reorders/deletes (the stored
    // Kinship has no id of its own; it doesn't need one on disk).
    @State private var kinshipRows: [KinshipRow]
    @State private var treeSearchRowID: UUID?
    @State private var treeSearchText = ""
    // Photo import
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var imageFilenamesCache: [String]?

    // Cover crop
    @State private var cropScale: Double
    @State private var cropOffset: CGSize
    @State private var showCropEditor = false

    // Photo deletion — confirmation alert
    @State private var photoPendingDeletion: String?

    struct KinshipRow: Identifiable, Equatable {
        let id = UUID()
        var relation: KinshipRelation
        var anchor: KinshipAnchor?
        /// Sibling rows only (design amendment 2): round-trips through the
        /// sheet unchanged unless Rick attests it here.
        var basis: SiblingBasis = .unspecified

        var kinship: Kinship? {
            anchor.map { Kinship(relation: relation, relativeTo: $0,
                                 basis: relation == .sibling ? basis : .unspecified) }
        }
    }

    /// Save-time findings (KinshipValidation.validate(batch:)) shown above
    /// the buttons; errors block Save, warnings are shown once.
    @State private var saveFindings: [KinshipValidation.Finding] = []
    @State private var warningsAcknowledged = false

    init(profile: POIProfile,
         otherProfiles: [POIProfile] = [],
         kinshipCenter: KinshipDisplayCenter,
         onSave: @escaping (POIProfile) -> Void) {
        self.originalProfile = profile
        self.otherProfiles = otherProfiles
        self.onSave = onSave
        self.kinshipCenter = kinshipCenter
        _name = State(initialValue: profile.name)
        _notes = State(initialValue: profile.notes)
        _aliasText = State(initialValue: profile.aliases.joined(separator: ", "))
        _coverFilename = State(initialValue: profile.coverImageFilename)
        _referencePath = State(initialValue: profile.referencePath)
        _cropScale = State(initialValue: profile.coverCropScale)
        _cropOffset = State(initialValue: CGSize(width: profile.coverCropOffsetX, height: profile.coverCropOffsetY))
        _birthdate = State(initialValue: profile.birthdate)
        _deathdate = State(initialValue: profile.deathdate)
        _sex = State(initialValue: profile.sex)
        _hairColor = State(initialValue: profile.hairColor)
        _eyeColor = State(initialValue: profile.eyeColor)
        _identityNotes = State(initialValue: profile.identityNotes ?? "")
        _kinshipRows = State(initialValue: profile.kinships.map {
            KinshipRow(relation: $0.relation, anchor: $0.relativeTo, basis: $0.basis)
        })
    }

    private var imageFilenames: [String] {
        if let cached = imageFilenamesCache { return cached }
        return currentProfile.referenceImageFilenames
    }

    /// Build a profile from current sheet state (does NOT write to disk).
    private var currentProfile: POIProfile {
        var p = originalProfile
        p.name = name.trimmingCharacters(in: .whitespaces)
        p.notes = notes
        p.aliases = aliasText
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        p.coverImageFilename = coverFilename
        p.referencePath = referencePath
        p.coverCropScale = cropScale
        p.coverCropOffsetX = cropOffset.width
        p.coverCropOffsetY = cropOffset.height
        p.birthdate = birthdate
        p.deathdate = deathdate
        p.sex = sex
        p.hairColor = hairColor
        p.eyeColor = eyeColor
        let trimmedIdentity = identityNotes.trimmingCharacters(in: .whitespacesAndNewlines)
        p.identityNotes = trimmedIdentity.isEmpty ? nil : trimmedIdentity
        // Rows without a chosen person are dropped on save, never stored
        // half-filled. Notes on existing rows survive untouched.
        p.kinships = PersonEditSheetKinshipSave.preservingNotes(
            in: kinshipRows.compactMap(\.kinship),
            from: originalProfile.kinships)
        return p
    }

    /// Validate the COMPLETE relationship batch (codex #835 b) before
    /// writing anything: errors block; warnings are shown once and the
    /// next Save proceeds.
    private func attemptSave() {
        let p = currentProfile
        let clock = ContinuousClock()
        let start = clock.now
        let evaluation = PersonEditSheetKinshipSave.evaluate(
            profile: p, otherProfiles: otherProfiles, graph: kinshipCenter.graph,
            currentRows: originalProfile.kinships,
            warningsAcknowledged: warningsAcknowledged)
        appLog.write(PersonEditSheetKinshipSave.resultLine(
            evaluation, elapsed: clock.now - start))
        saveFindings = evaluation.findings
        switch evaluation.decision {
        case .blocked:
            return
        case .warningConfirmationRequired:
            warningsAcknowledged = true
            return
        case .save:
            onSave(evaluation.profile)
            dismiss()
        }
    }

    private var isNewPerson: Bool {
        originalProfile.name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack(spacing: 12) {
                coverAvatar
                VStack(alignment: .leading, spacing: 4) {
                    Text(isNewPerson ? "Add Person" : "Edit Person")
                        .font(.title2.weight(.semibold))
                    if !isNewPerson {
                        Text(originalProfile.name)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            .padding(20)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // Form content
            Form {
                Section("Identity") {
                    TextField("Name", text: $name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Aliases (comma-separated)", text: $aliasText)
                        .textFieldStyle(.roundedBorder)
                        .help("Alternate names that might appear in video filenames or metadata")
                }

                aboutSection

                relationshipsSection

                Section("Notes") {
                    TextEditor(text: $notes)
                        .font(.body)
                        .frame(minHeight: 60, maxHeight: 120)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(Color(NSColor.controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 0.5)
                        )
                }

                Section {
                    // Folder path
                    HStack {
                        Image(systemName: "folder")
                            .foregroundStyle(.secondary)
                        Text(referencePath.isEmpty ? "No folder selected" : referencePath)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(referencePath.isEmpty ? .secondary : .primary)
                        Spacer()
                    }

                    // Action buttons
                    HStack(spacing: 10) {
                        Button("Browse Photos\u{2026}") { browseForReferenceFolder() }
                            .controlSize(.regular)

                        PhotosPicker(
                            selection: $photosPickerItems,
                            maxSelectionCount: 50,
                            matching: .images
                        ) {
                            Label(isImporting ? "Importing\u{2026}" : "Apple Photos",
                                  systemImage: "photo.on.rectangle.angled")
                        }
                        .controlSize(.regular)
                        .disabled(isImporting)
                        .onChange(of: photosPickerItems) {
                            guard !photosPickerItems.isEmpty else { return }
                            Task { await importFromApplePhotos() }
                        }

                        if isImporting {
                            ProgressView().scaleEffect(0.7)
                        }

                        Spacer()
                    }

                    // Photo grid with cover selection
                    if !imageFilenames.isEmpty {
                        referencePhotoGrid
                    }
                } header: {
                    HStack {
                        Text("Reference Photos")
                        Spacer()
                        if !referencePath.isEmpty,
                           FileManager.default.fileExists(atPath: referencePath) {
                            Button {
                                NSWorkspace.shared.open(URL(fileURLWithPath: referencePath))
                            } label: {
                                Label("Show Folder in Finder", systemImage: "folder")
                                    .font(.caption)
                            }
                            .buttonStyle(.link)
                            .help(referencePath)
                        }
                    }
                } footer: {
                    if !imageFilenames.isEmpty {
                        Text("Click a photo to set it as the cover image. Right-click to delete or show in Finder. \(imageFilenames.count) photo\(imageFilenames.count == 1 ? "" : "s") in folder.")
                    }
                }

            }
            .formStyle(.grouped)

            Divider()

            // Action buttons
            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Save") {
                    attemptSave()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 560, height: 820)
        .task { kinshipCenter.loadTreeIfNeeded() }
        .alert(
            "Delete this reference photo?",
            isPresented: Binding(
                get: { photoPendingDeletion != nil },
                set: { if !$0 { photoPendingDeletion = nil } }
            ),
            presenting: photoPendingDeletion
        ) { filename in
            Button("Delete", role: .destructive) {
                deleteReferencePhoto(filename)
                photoPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                photoPendingDeletion = nil
            }
        } message: { filename in
            Text("\(filename) will be moved to the Trash. This photo will no longer be used when scanning for \(name.isEmpty ? "this person" : name).")
        }
    }

    // MARK: About section (identity metadata)
    //
    // Feeds the search-results plausibility ranking: birth/death dates
    // rule people out of videos they can't be in, sex + hair + eyes
    // re-rank against the video's scene description. Family language,
    // generous text size (title3 — Rick reads at a distance).

    /// A sensible starting point when Rick clicks "Add" — mid-century,
    /// matches the archive's era better than today's date would.
    private static let defaultBirthdate: Date = {
        var dc = DateComponents(); dc.year = 1970; dc.month = 1; dc.day = 1
        return Calendar.current.date(from: dc) ?? Date()
    }()

    /// Bridge Date? state into the non-optional Binding a DatePicker
    /// wants. ≈ C++: a proxy accessor pair over an std::optional<Date>.
    private func requiredDate(_ source: Binding<Date?>) -> Binding<Date> {
        Binding(
            get: { source.wrappedValue ?? Self.defaultBirthdate },
            set: { source.wrappedValue = $0 }
        )
    }

    @ViewBuilder
    private var aboutSection: some View {
        Section {
            Group {
                // Born — day precision offered, but scoring only uses years.
                if birthdate != nil {
                    HStack {
                        DatePicker("Born", selection: requiredDate($birthdate),
                                   displayedComponents: .date)
                        Button {
                            birthdate = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear birthday")
                    }
                } else {
                    LabeledContent("Born") {
                        Button("Add birthday\u{2026}") { birthdate = Self.defaultBirthdate }
                    }
                }

                // Passed away — quiet affordance; most profiles never
                // show a date field here, just a small link-style button.
                if deathdate != nil {
                    HStack {
                        DatePicker("Passed away", selection: requiredDate($deathdate),
                                   displayedComponents: .date)
                        Button {
                            deathdate = nil
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear date")
                    }
                } else {
                    Button("Add a date of passing\u{2026}") { deathdate = Date() }
                        .buttonStyle(.link)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                Picker("Sex", selection: $sex) {
                    Text("Not set").tag(PersonSex?.none)
                    ForEach(PersonSex.allCases, id: \.self) { s in
                        Text(s.label).tag(PersonSex?.some(s))
                    }
                }

                Picker("Hair", selection: $hairColor) {
                    Text("Not set").tag(HairColor?.none)
                    ForEach(HairColor.allCases, id: \.self) { c in
                        Text(c.label).tag(HairColor?.some(c))
                    }
                }
                .help("A match with the scene description boosts ranking — a mismatch never counts against them (hair changes over the decades)")

                Picker("Eyes", selection: $eyeColor) {
                    Text("Not set").tag(EyeColor?.none)
                    ForEach(EyeColor.allCases, id: \.self) { c in
                        Text(c.label).tag(EyeColor?.some(c))
                    }
                }

                TextField("Details", text: $identityNotes,
                          prompt: Text("e.g. blonde hair, blue eyes, always wore glasses"))
                    .textFieldStyle(.roundedBorder)
                    .help("Anything that helps recognize them on screen — kept for your reference")
            }
            .font(.title3)
        } header: {
            Text("About \(name.isEmpty ? "this person" : name)")
        } footer: {
            Text("Helps rank search matches — someone born after a video was filmed can't be in it. Just the year is enough.")
        }
    }

    // MARK: Relationships section
    //
    // Each row stores "<this person> is <relation> of <someone>". The
    // someone is another People profile or a family-tree person (by
    // FamilySearch ID). Words like "brother"/"sister" and "older"/"younger"
    // are derived from sex and birthdates at display time — see
    // FamilyKinshipOverlay — so this stays a plain typed fact. These rows
    // are local to the app and never written to GEDCOM / FamilySearch.

    /// Profiles this person can be related to (everyone but themself).
    private var relatableProfiles: [POIProfile] {
        let me = PersonResolver.normalize(name)
        let original = PersonResolver.normalize(originalProfile.name)
        return otherProfiles.filter {
            let key = PersonResolver.normalize($0.name)
            return key != me && key != original
        }
    }

    /// The derived line exactly as the People card will show it.
    private var derivedRelationshipsLine: String? {
        let me = currentProfile
        guard !me.kinships.isEmpty else { return nil }
        let everyone = relatableProfiles + [me]
        let overlay = FamilyKinshipOverlay(profiles: everyone, graph: kinshipCenter.graph)
        return overlay.relationshipsLine(
            forProfileStableID: me.id, kinships: me.kinships,
            defaultAnchor: kinshipCenter.defaultAnchor(in: overlay, profiles: everyone))
    }

    private func anchorLabel(_ anchor: KinshipAnchor?) -> String {
        switch anchor {
        case nil:
            return "Choose a person\u{2026}"
        case .profile(let id)?:
            return otherProfiles.first { $0.uuid == id }?.name ?? "a removed profile"
        case .profileName(let profileName)?:
            return profileName
        case .treePerson(let fsid)?:
            if let person = kinshipCenter.graph?.person(familySearchID: fsid) {
                return "\(person.name) (tree)"
            }
            return "FamilySearch \(fsid.uppercased())"
        case .treePointer(let pointer, let fingerprint)?:
            if fingerprint == kinshipCenter.graphFingerprint,
               let person = kinshipCenter.graph?.people[pointer] {
                return "\(person.name) (export-local)"
            }
            return "tree person \(pointer) (export changed — pick again)"
        }
    }

    @ViewBuilder
    private var relationshipsSection: some View {
        Section {
            ForEach($kinshipRows) { $row in
                HStack(spacing: 8) {
                    // Only the four primitives are entered (design: store
                    // primitives, derive everything else); a legacy derived
                    // row keeps showing its own word until Rick changes it.
                    Picker("", selection: $row.relation) {
                        ForEach(Self.enterableRelations(including: row.relation), id: \.self) { relation in
                            Text(relation.label).tag(relation)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)

                    if row.relation == .sibling {
                        Picker("", selection: Binding(
                            get: { row.basis == .attestedFull ? 1 : (row.basis == .unspecified ? 0 : 2) },
                            set: { if $0 == 1 { row.basis = .attestedFull } else if $0 == 0 { row.basis = .unspecified } }
                        )) {
                            Text("shared parents?").tag(0)
                            Text("full (same parents)").tag(1)
                            if case .attestedHalf = row.basis { Text("half").tag(2) }
                        }
                        .labelsHidden()
                        .frame(width: 150)
                        .help("Full: this sibling shares both parents, so ancestry is inherited through the link. Unspecified: the link is used for sibling / uncle / in-law words only.")
                    }

                    Text("of")
                        .foregroundStyle(.secondary)

                    Menu {
                        ForEach(relatableProfiles) { profile in
                            // `kinshipAnchor`, not `.profile(id: profile.uuid)`: a
                            // profile whose uuid failed to persist (codex #799)
                            // is anchored by name so nothing dangling is saved.
                            Button(profile.name) { row.anchor = profile.kinshipAnchor }
                        }
                        if relatableProfiles.isEmpty {
                            Text("No other people yet")
                        }
                        Divider()
                        Button("Family tree person\u{2026}") {
                            treeSearchText = ""
                            treeSearchRowID = row.id
                        }
                    } label: {
                        Text(anchorLabel(row.anchor))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .popover(isPresented: Binding(
                        get: { treeSearchRowID == row.id },
                        set: { if !$0 { treeSearchRowID = nil } }
                    )) {
                        treeSearchPopover { anchor in
                            row.anchor = anchor
                            treeSearchRowID = nil
                        }
                    }

                    Button {
                        kinshipRows.removeAll { $0.id == row.id }
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this relationship")
                }
            }

            Button {
                kinshipRows.append(KinshipRow(relation: .sibling, anchor: nil))
            } label: {
                Label("Add relationship", systemImage: "plus")
            }
            .buttonStyle(.link)
            if !saveFindings.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(saveFindings.enumerated()), id: \.offset) { _, finding in
                        Label(finding.message, systemImage: finding.isError ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(finding.isError ? Color.red : Color.orange)
                            .font(.callout)
                    }
                    if !saveFindings.blocksSave {
                        Text("Press Save again to keep these rows anyway.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Relationships")
        } footer: {
            if let line = derivedRelationshipsLine {
                Text("Shown as: \(line)")
            } else {
                Text("\(name.isEmpty ? "This person" : name) is … of … — kept in the app only, never sent to FamilySearch. Brother/sister and older/younger come from sex and birthdays.")
            }
        }
    }

    /// Search the imported family tree by name; picks a FamilySearch ID.
    /// When no tree is loaded (or the person has no FamilySearch ID) the
    /// ID can be typed directly.
    @ViewBuilder
    private func treeSearchPopover(onPick: @escaping (KinshipAnchor) -> Void) -> some View {
        let results = kinshipCenter.searchTreePeople(treeSearchText)
        let typedID = treeSearchText.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        VStack(alignment: .leading, spacing: 8) {
            TextField("Name or FamilySearch ID (e.g. GVQV-NW3)", text: $treeSearchText)
                .textFieldStyle(.roundedBorder)
            Text("People without a FamilySearch ID are export-local: the link only holds for this exact tree file.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if kinshipCenter.graph == nil {
                Text("No family tree is loaded — type a FamilySearch ID.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if Self.looksLikeFamilySearchID(typedID) {
                Button("Use ID \(typedID)") { onPick(.treePerson(familySearchID: typedID)) }
                    .buttonStyle(.link)
            }
            if !results.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(results) { person in
                            Button {
                                if let fsid = person.familySearchID {
                                    onPick(.treePerson(familySearchID: fsid))
                                } else {
                                    onPick(.treePointer(pointer: person.pointer,
                                                        sourceFingerprint: kinshipCenter.graphFingerprint ?? ""))
                                }
                            } label: {
                                HStack {
                                    Text(person.label).lineLimit(1)
                                    Spacer()
                                    Text(person.code)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 220)
            } else if !treeSearchText.isEmpty, kinshipCenter.graph != nil {
                Text("No one in the tree matches.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    private static func looksLikeFamilySearchID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 3 else { return false }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return parts.joined().unicodeScalars.allSatisfy { allowed.contains($0) }
    }

    // MARK: Cover avatar in header

    @ViewBuilder
    private var coverAvatar: some View {
        let profile = currentProfile
        ZStack {
            if let filename = coverFilename,
               let img = profile.referenceImage(named: filename) {
                CroppedCircleImage(image: img, scale: cropScale, offset: cropOffset)
                    .frame(width: 64, height: 64)
            } else {
                Circle()
                    .fill(Color.accentColor.opacity(0.15))
                    .frame(width: 64, height: 64)
                if !name.isEmpty {
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                } else {
                    Image(systemName: "person.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor.opacity(0.5))
                }
            }
        }
        .overlay(Circle().stroke(Color.accentColor, lineWidth: 2))
        .overlay(alignment: .bottomTrailing) {
            if coverFilename != nil {
                Button { showCropEditor = true } label: {
                    Image(systemName: "crop")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(.white)
                        .padding(4)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .offset(x: 2, y: 2)
            }
        }
        .popover(isPresented: $showCropEditor) {
            if let filename = coverFilename,
               let img = currentProfile.referenceImage(named: filename) {
                CoverCropEditor(image: img, scale: $cropScale, offset: $cropOffset)
            }
        }
    }

    // MARK: Reference photo grid (doubles as cover picker)

    @ViewBuilder
    private var referencePhotoGrid: some View {
        let filenames = imageFilenames
        let columns = [GridItem(.adaptive(minimum: 72, maximum: 80), spacing: 8)]
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(filenames, id: \.self) { filename in
                referencePhotoTile(filename)
            }
        }
        .padding(.vertical, 4)
    }

    private func referencePhotoTile(_ filename: String) -> some View {
        let isCover = coverFilename == filename
        let profile = currentProfile
        let fileURL = URL(fileURLWithPath: profile.referencePath)
            .appendingPathComponent(filename)
        return Button {
            coverFilename = isCover ? nil : filename
        } label: {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let img = profile.referenceImage(named: filename) {
                        Image(nsImage: img)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 72, height: 72)
                            .clipped()
                    } else {
                        Color.secondary.opacity(0.2)
                            .frame(width: 72, height: 72)
                            .overlay(Image(systemName: "photo")
                                .foregroundStyle(.secondary))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isCover ? Color.accentColor : Color.clear, lineWidth: 3)
                )
                .shadow(color: isCover ? Color.accentColor.opacity(0.3) : .clear, radius: 3)

                if isCover {
                    Image(systemName: "star.circle.fill")
                        .font(.system(size: 16))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, Color.accentColor)
                        .offset(x: 4, y: 4)
                }
            }
        }
        .buttonStyle(.plain)
        .help(isCover ? "\(filename) (cover photo)" : filename)
        .contextMenu {
            Button("Show in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([fileURL])
            }
            Button(isCover ? "Remove as Cover" : "Set as Cover") {
                coverFilename = isCover ? nil : filename
            }
            Divider()
            Button("Delete Photo\u{2026}", role: .destructive) {
                photoPendingDeletion = filename
            }
            Divider()
            Text(filename)
        }
    }

    /// Move a reference photo to the Trash and refresh the grid.
    /// If the deleted photo was the cover, clear the cover selection.
    /// Issue #37 — edit sheet must match scan-time photos, so user needs
    /// to remove ones that shouldn't feed face recognition.
    private func deleteReferencePhoto(_ filename: String) {
        let url = URL(fileURLWithPath: referencePath).appendingPathComponent(filename)
        do {
            try FileManager.default.trashItem(at: url, resultingItemURL: nil)
        } catch {
            NSLog("PersonEditSheet: failed to trash \(url.path): \(error)")
            return
        }
        if coverFilename == filename {
            coverFilename = nil
        }
        imageFilenamesCache = nil  // force refresh
    }

    // MARK: Browse & Import

    /// Canonical local folder for this person's reference photos.
    /// Lives at ~/Library/Application Support/VideoScan/POI/<name>/ — see
    /// POIStorage.swift. profile.json and photos share this folder.
    private func ensureLocalPhotoFolder() -> URL {
        let dir = POIStorage.folder(for: name)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copy image files from a source folder into the local poi_photos folder.
    private func copyPhotosToLocal(from sourceURL: URL) {
        let fm = FileManager.default
        let destDir = ensureLocalPhotoFolder()
        let imageExts: Set<String> = ["jpg", "jpeg", "png", "heic", "heif", "tiff", "tif", "bmp"]

        var sourceFiles: [URL] = []
        if sourceURL.hasDirectoryPath || (try? sourceURL.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true {
            sourceFiles = (try? fm.contentsOfDirectory(at: sourceURL, includingPropertiesForKeys: nil)) ?? []
            sourceFiles = sourceFiles.filter { imageExts.contains($0.pathExtension.lowercased()) }
        } else if imageExts.contains(sourceURL.pathExtension.lowercased()) {
            sourceFiles = [sourceURL]
        }

        for file in sourceFiles {
            let destFile = destDir.appendingPathComponent(file.lastPathComponent)
            if fm.fileExists(atPath: destFile.path) { continue }  // skip duplicates by name
            try? fm.copyItem(at: file, to: destFile)
        }

        referencePath = destDir.path
        imageFilenamesCache = nil
    }

    private func browseForReferenceFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = true
        panel.message = "Select photos or a folder of reference photos for \(name.isEmpty ? "this person" : name)"
        panel.prompt = "Select"
        panel.begin { response in
            if response == .OK, !panel.urls.isEmpty {
                for url in panel.urls {
                    self.copyPhotosToLocal(from: url)
                }
            }
        }
    }

    private func importFromApplePhotos() async {
        isImporting = true
        defer {
            isImporting = false
            photosPickerItems = []
        }

        let destDir = ensureLocalPhotoFolder()
        referencePath = destDir.path

        // Use a timestamp prefix to avoid overwriting previous imports.
        // Load photos concurrently via TaskGroup on a detached priority so we
        // don't compete with scan jobs for the cooperative thread pool.
        let stamp = Int(Date().timeIntervalSince1970)
        let items = photosPickerItems
        await Task.detached(priority: .userInitiated) {
            await withTaskGroup(of: Void.self) { group in
                for (i, item) in items.enumerated() {
                    group.addTask {
                        if let data = try? await item.loadTransferable(type: Data.self) {
                            let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                            let dest = destDir.appendingPathComponent("apple_\(stamp)_\(i).\(ext)")
                            try? data.write(to: dest)
                        }
                    }
                }
            }
        }.value

        imageFilenamesCache = nil  // force refresh
    }
}

// MARK: - Cropped Circle Image

/// Displays an image inside a circle with pan/zoom crop applied.
struct CroppedCircleImage: View {
    let image: NSImage
    var scale: Double = 1.0
    var offset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .scaleEffect(max(1.0, scale))
                .offset(offset)
                .frame(width: size, height: size)
                .clipShape(Circle())
        }
    }
}

// MARK: - Cover Crop Editor

/// Apple Contacts-style crop: drag to pan, scroll to zoom inside a circle.
struct CoverCropEditor: View {
    let image: NSImage
    @Binding var scale: Double
    @Binding var offset: CGSize
    @GestureState private var dragOffset: CGSize = .zero

    private let previewSize: CGFloat = 200

    var body: some View {
        VStack(spacing: 12) {
            Text("Adjust Cover Photo")
                .font(.headline)

            ZStack {
                Color(NSColor.controlBackgroundColor)

                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .scaleEffect(max(1.0, scale))
                    .offset(CGSize(
                        width: offset.width + dragOffset.width,
                        height: offset.height + dragOffset.height
                    ))
                    .frame(width: previewSize, height: previewSize)
                    .clipShape(Circle())
                    .gesture(
                        DragGesture()
                            .updating($dragOffset) { value, state, _ in
                                state = value.translation
                            }
                            .onEnded { value in
                                offset = CGSize(
                                    width: offset.width + value.translation.width,
                                    height: offset.height + value.translation.height
                                )
                            }
                    )

                // Circle guide ring
                Circle()
                    .stroke(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                    .frame(width: previewSize, height: previewSize)
            }
            .frame(width: previewSize + 24, height: previewSize + 24)

            HStack(spacing: 8) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: $scale, in: 1.0...3.0, step: 0.1)
                    .frame(width: 140)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
            }

            Button("Reset") {
                scale = 1.0
                offset = .zero
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
        .padding(16)
        .frame(width: 280)
    }
}

extension PersonEditSheet {
    /// The four storable primitives, plus the row's current relation when
    /// it is a legacy derived kind (so the picker can still show it).
    static func enterableRelations(including current: KinshipRelation) -> [KinshipRelation] {
        let primitives: [KinshipRelation] = [.parent, .child, .spouse, .sibling]
        return primitives.contains(current) ? primitives : primitives + [current]
    }
}
