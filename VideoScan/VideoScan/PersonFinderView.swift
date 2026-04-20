// PersonFinderView.swift
// Multi-volume person-finding UI — jobs list, progress bars, results, console.

import SwiftUI
import AppKit
import PhotosUI

// MARK: - Helpers

/// Format elapsed seconds as "1h 23m 45s" / "23m 45s" / "45s".
private func formatElapsed(_ secs: Double) -> String {
    let t = Int(secs); let h = t/3600; let m = (t%3600)/60; let s = t%60
    return h > 0 ? "\(h)h \(m)m \(s)s" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
}

// MARK: - Main View

struct PersonFinderView: View {
    @EnvironmentObject var dashboard: DashboardState
    @EnvironmentObject var model: PersonFinderModel
    @State private var selectedResultIDs = Set<UUID>()
    @State private var inspectedResult: ClipResult? = nil
    @State private var resultSortOrder = [KeyPathComparator(\ClipResult.videoFilename)]

    var selectedJobID: UUID? {
        get { model.selectedJobID }
        nonmutating set { model.selectedJobID = newValue }
    }
    var expandedJobIDs: Set<UUID> {
        get { model.expandedJobIDs }
        nonmutating set { model.expandedJobIDs = newValue }
    }
    var selectedJob: ScanJob? { model.jobs.first { $0.id == selectedJobID } }
    var hasAnyResults: Bool { model.jobs.contains { !$0.results.isEmpty } }

    var body: some View {
        VStack(spacing: 0) {
            peopleGallery
            Divider()
            loadedFacesStrip
            Divider()
            outputBar
            Divider()
            jobsSection
            Divider()
            resultsTable
        }
        .frame(minWidth: 960, maxHeight: .infinity, alignment: .top)
        .onAppear {
            model.dashboard = dashboard
            // Don't auto-load a person on launch — let user choose via gallery or Find Person
        }
    }

    // MARK: People Gallery — saved family profiles

    @State private var confirmDeleteProfile: POIProfile? = nil
    @State private var editingProfile: POIProfile? = nil
    /// The original name of the profile being edited (nil when adding new).
    @State private var editingOriginalName: String? = nil
    /// Briefly set after a profile save to flash confirmation on the card.
    @State private var justSavedProfileID: String? = nil
    /// Alert message shown when user tries to edit/switch during a scan.
    @State private var scanLockMessage: String? = nil

    var peopleGallery: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "person.2.fill")
                    .font(.title3)
                    .foregroundColor(.accentColor)
                Text("Family")
                    .font(.headline)
                Spacer()
                if !model.savedProfiles.isEmpty {
                    Text("\(model.savedProfiles.count) people")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
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
                                        .frame(width: 64, height: 64)
                                    Image(systemName: "plus")
                                        .font(.system(size: 22, weight: .medium))
                                        .foregroundColor(.secondary)
                                }
                                Text("Add Person")
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundColor(.secondary)
                            }
                            .frame(width: 80)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)

                        // Build set of all people currently being scanned across all active jobs
                        let scanningNames = Set(model.jobs.filter { $0.status.isActive }.compactMap { $0.assignedProfile?.name.lowercased() })
                        ForEach(model.savedProfiles) { profile in
                            let isBeingScanned = scanningNames.contains(profile.name.lowercased())
                            let isActive = isBeingScanned
                            PersonCard(profile: profile, isActive: isActive, justSaved: justSavedProfileID == profile.id)
                                .opacity(isBeingScanned ? 0.7 : 1.0)
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
                                .contextMenu {
                                    Button("Search for \(profile.name)\u{2026}") {
                                        addJobForPerson(profile)
                                    }
                                    Divider()
                                    Button("Edit \(profile.name)\u{2026}") {
                                        editingOriginalName = profile.name
                                        editingProfile = profile
                                    }
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
                                    Button("Delete \(profile.name)", role: .destructive) {
                                        confirmDeleteProfile = profile
                                    }
                                }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(height: 110)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
        .alert("Delete Person", isPresented: Binding(
            get: { confirmDeleteProfile != nil },
            set: { if !$0 { confirmDeleteProfile = nil } }
        )) {
            Button("Cancel", role: .cancel) { confirmDeleteProfile = nil }
            Button("Delete", role: .destructive) {
                if let p = confirmDeleteProfile {
                    model.deletePOI(p)
                    confirmDeleteProfile = nil
                }
            }
        } message: {
            Text("Delete \(confirmDeleteProfile?.name ?? "")? This removes the saved profile but not the reference photos.")
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
            PersonEditSheet(profile: profile) { updated in
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
    }

    // MARK: Loaded Faces Strip — compact scan-readiness indicator

    @State private var showFailures = false
    @AppStorage("faceThumbnailSize") private var thumbSize: Double = 58
    @AppStorage("facesStripHeight") private var facesStripHeight: Double = 90
    @State private var inspectedFace: ReferenceFace? = nil

    @ViewBuilder
    var loadedFacesStrip: some View {
        if model.referenceFaces.isEmpty && !model.isLoadingReference && model.referenceLoadError == nil {
            // Empty state — no person loaded yet
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text("Click a person above to load their reference faces, or use Find Person below to start a search")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if model.isLoadingReference {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading reference photos\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if !model.referenceFaces.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.body)
                        Text("\(model.settings.personName)")
                            .font(.body.weight(.semibold))
                        Text("\u{2014} \(model.referencePhotoCount) faces loaded")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        let good = model.referenceFaces.filter { $0.quality == .good }.count
                        let fair = model.referenceFaces.filter { $0.quality == .fair }.count
                        let poor = model.referenceFaces.filter { $0.quality == .poor }.count
                        HStack(spacing: 6) {
                            if good > 0 { Text("\(good) good").foregroundColor(.green).font(.callout) }
                            if fair > 0 { Text("\(fair) fair").foregroundColor(.yellow).font(.callout) }
                            if poor > 0 { Text("\(poor) poor").foregroundColor(.red).font(.callout) }
                        }
                    }

                    if let err = model.referenceLoadError {
                        Label(err, systemImage: "info.circle.fill")
                            .foregroundColor(.orange)
                            .font(.callout)
                    }

                    if !model.referenceLoadFailures.isEmpty {
                        Button {
                            showFailures.toggle()
                        } label: {
                            Label("\(model.referenceLoadFailures.count) skipped",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showFailures) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Photos Without Usable Faces")
                                    .font(.headline)
                                    .padding(.bottom, 4)
                                ForEach(model.referenceLoadFailures) { f in
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                        Text(f.filename)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .lineLimit(1)
                                        Text("\u{2014} \(f.reason)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(minWidth: 320, maxHeight: 300)
                        }
                    }
                    Spacer()

                    // Thumbnail size slider
                    if !model.referenceFaces.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "photo")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                            Slider(value: $thumbSize, in: 40...140, step: 2)
                                .frame(width: 80)
                            Image(systemName: "photo")
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                // Face thumbnails — wrapping grid in a resizable pane
                if !model.referenceFaces.isEmpty {
                    let cellSize = CGFloat(thumbSize)
                    let columns = [GridItem(.adaptive(minimum: cellSize + 4), spacing: 6)]
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(model.referenceFaces) { face in
                                CompactFaceThumbnail(face: face, size: cellSize, onRemove: {
                                    model.removeReferenceFace(id: face.id)
                                })
                                .onTapGesture(count: 2) {
                                    inspectedFace = face
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 4)
                    }
                    .frame(height: facesStripHeight)
                    .popover(item: $inspectedFace) { face in
                        faceDetailPopover(face)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            // Drag handle to resize the faces pane
            if !model.referenceFaces.isEmpty {
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 5)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() }
                        else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                facesStripHeight = max(60, min(500, facesStripHeight + value.translation.height))
                            }
                    )
            }
        } // else (faces loaded)
    }

    // MARK: Output bar — where does output go?

    var outputBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.badge.gearshape")
                .font(.title3)
                .foregroundColor(.secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text("Output Folder").font(.headline)
                Text("Where clips and compiled video are saved")
                    .font(.caption).foregroundColor(.secondary)
            }

            TextField(
                "Default: ~/Desktop/\(pfSanitize(model.settings.personName))_clips",
                text: model.settingsBinding.outputDir
            )
            .textFieldStyle(.roundedBorder)
            .font(.system(.body, design: .monospaced))

            Button("Browse…") { browseForOutput() }
                .controlSize(.large)

            if !model.settings.outputDir.isEmpty {
                Button("Reveal") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: model.settings.outputDir))
                }
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Jobs section

    var jobsSection: some View {
        return VStack(spacing: 0) {
            // Compact header: + Find Person, batch controls, windows
            HStack(spacing: 10) {
                Menu {
                    ForEach(model.savedProfiles) { profile in
                        Button {
                            addJobForPerson(profile)
                        } label: {
                            Label(profile.name, systemImage: "person.circle")
                        }
                    }
                    if model.savedProfiles.isEmpty {
                        Text("Add people in the gallery above first")
                    }
                } label: {
                    Label("Find Person", systemImage: "person.fill.viewfinder")
                        .font(.title3.weight(.semibold))
                }
                .menuStyle(.borderedButton)
                .controlSize(.large)
                .disabled(model.savedProfiles.isEmpty)

                Spacer()

                if model.jobs.count > 1 {
                    Button(action: {
                        model.startAll()
                        if selectedJobID == nil { selectedJobID = model.jobs.first?.id }
                    }) {
                        Label("Start All", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(model.jobs.isEmpty)

                    Button(action: { model.stopAll() }) {
                        Label("Stop All", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(!model.jobs.contains { $0.status.isActive })
                }

                Divider().frame(height: 20)

                Button {
                    PreviewWindowController.shared.show(model: model)
                } label: {
                    Label("Face Detection", systemImage: "eye.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.jobs.isEmpty)

                Button {
                    JobConsoleWindowController.shared.show(model: model, focusJobID: selectedJobID)
                } label: {
                    Label("Console", systemImage: "terminal")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.jobs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if model.jobs.isEmpty {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.up.left")
                        .font(.body).foregroundColor(.secondary)
                    Text("Click \"Find Person\" to start searching")
                        .font(.body).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.jobs) { job in
                            ScanJobRow(
                                job: job,
                                model: model,
                                isSelected: selectedJobID == job.id,
                                isExpanded: expandedJobIDs.contains(job.id),
                                threshold: model.settings.threshold,
                                savedProfiles: model.savedProfiles,
                                onToggleExpand: {
                                    withAnimation(.easeInOut(duration: 0.2)) {
                                        if expandedJobIDs.contains(job.id) {
                                            expandedJobIDs.remove(job.id)
                                        } else {
                                            expandedJobIDs.insert(job.id)
                                        }
                                    }
                                },
                                onStart: { selectedJobID = job.id; expandedJobIDs.insert(job.id); model.startJob(job) },
                                onStop: { model.stopJob(job) },
                                onPause: { model.togglePauseJob(job) },
                                onReset: { job.reset() },
                                onRemove: { expandedJobIDs.remove(job.id); model.removeJob(job) },
                                onPreview: { PreviewWindowController.shared.show(model: model, focusJobID: job.id) }
                            )
                            .contentShape(Rectangle())
                            // simultaneousGesture (not onTapGesture) so the row's
                            // selection tap doesn't steal taps from the per-row
                            // Start/Stop/Pause/Reset/Trash buttons living inside it.
                            .simultaneousGesture(
                                TapGesture().onEnded { selectedJobID = job.id }
                            )
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 90, maxHeight: hasAnyResults ? 260 : .infinity)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
        .fixedSize(horizontal: false, vertical: model.jobs.isEmpty)
    }

    // MARK: Results table

    var resultsTable: some View {
        let results = selectedJob?.results ?? model.jobs.flatMap { $0.results }
        return Group {
            if results.isEmpty {
                HStack(spacing: 6) {
                    let anyDone = model.jobs.contains { $0.status == .done || $0.status == .cancelled }
                    let anyActive = model.jobs.contains { $0.status.isActive }
                    Image(systemName: "tray")
                        .foregroundColor(.secondary)
                    Text(anyDone && !anyActive
                         ? "No matches found"
                         : anyActive
                         ? "Results will appear as matches are found"
                         : "Results will appear here when matches are found")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
            } else {
                Table(results.sorted(using: resultSortOrder), selection: $selectedResultIDs, sortOrder: $resultSortOrder) {
                    TableColumn("Video File", value: \.videoFilename) { r in
                        Text(r.videoFilename)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                            .help(r.videoPath)
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("Duration", value: \.videoDuration) { r in
                        Text(pfFormatDuration(r.videoDuration))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Presence", value: \.presenceSecs) { r in
                        Text(pfFormatDuration(r.presenceSecs))
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .foregroundColor(.green)
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Clips", value: \.segmentCount) { r in
                        Text("\(r.segmentCount)")
                            .font(.body)
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("Best Match", value: \.bestDistance) { r in
                        Text(String(format: "%.3f", r.bestDistance))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(r.bestDistance < 0.5 ? .green : r.bestDistance < 0.65 ? .yellow : .orange)
                    }
                    .width(min: 80, ideal: 90)
                }
                .contextMenu(forSelectionType: UUID.self) { ids in
                    if let id = ids.first,
                       let rec = results.first(where: { $0.id == id }) {
                        Button("Reveal in Finder") {
                            NSWorkspace.shared.selectFile(rec.videoPath, inFileViewerRootedAtPath: "")
                        }
                        Button("Open in QuickTime Player") {
                            if let qtURL = NSWorkspace.shared.urlForApplication(
                                withBundleIdentifier: "com.apple.QuickTimePlayerX"
                            ) {
                                NSWorkspace.shared.open(
                                    [URL(fileURLWithPath: rec.videoPath)],
                                    withApplicationAt: qtURL,
                                    configuration: NSWorkspace.OpenConfiguration()
                                )
                            }
                        }
                        if !rec.clipFiles.isEmpty {
                            Button("Reveal Clips in Finder") {
                                revealClips(for: rec)
                            }
                        }
                        Divider()
                        Button("More Info…") {
                            inspectedResult = rec
                        }
                        Divider()
                        Button("Copy Path") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(rec.videoPath, forType: .string)
                        }
                    }
                }
                .frame(minHeight: 160)
                .popover(item: $inspectedResult, arrowEdge: .trailing) { rec in
                    resultInfoPopover(rec)
                }
            }
        }
    }

    // Console pane removed from main window — use the Console toolbar
    // button which opens a floating window with a per-job picker.

    // MARK: Result Info Popover

    func resultInfoPopover(_ rec: ClipResult) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(rec.videoFilename)
                .font(.headline)
            Divider()
            infoRow("Path", rec.videoPath)
            infoRow("Duration", pfFormatDuration(rec.videoDuration))
            infoRow("Presence", pfFormatDuration(rec.presenceSecs))
            infoRow("Clips", "\(rec.segmentCount)")
            infoRow("Best Match", String(format: "%.3f", rec.bestDistance))
            if !rec.outputDir.isEmpty {
                infoRow("Output Dir", rec.outputDir)
            }
            if !rec.clipFiles.isEmpty {
                Divider()
                Text("Clip Files")
                    .font(.subheadline.weight(.medium))
                ForEach(rec.clipFiles, id: \.self) { clip in
                    Text(clip)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding()
        .frame(minWidth: 320, maxWidth: 480)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .trailing)
            Text(value)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
        }
    }

    func faceDetailPopover(_ face: ReferenceFace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(cgImage: face.thumbnail, size: NSSize(width: 120, height: 120)))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(face.sourceFilename)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(face.quality == .good ? .green : face.quality == .fair ? .orange : .red)
                            .frame(width: 8, height: 8)
                        Text(face.quality == .good ? "Good" : face.quality == .fair ? "Fair" : "Poor")
                            .font(.callout.weight(.medium))
                    }
                    Text(face.angleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            infoRow("Confidence", String(format: "%.0f%%", face.confidence * 100))
            infoRow("Yaw", String(format: "%.1f°", face.yawDeg))
            infoRow("Pitch", String(format: "%.1f°", face.pitchDeg))
            infoRow("Roll", String(format: "%.1f°", face.rollDeg))
            infoRow("Face Area", String(format: "%.1f%% of image", face.faceAreaPct))
        }
        .padding()
        .frame(minWidth: 300, maxWidth: 400)
    }

    // MARK: Helpers

    /// Add a search row for a specific person, expanded and ready for volume selection.
    func addJobForPerson(_ profile: POIProfile) {
        model.selectedPersonForNewJobs = profile
        model.addJob()
        if let job = model.jobs.last {
            expandedJobIDs.insert(job.id)
            selectedJobID = job.id
        }
    }

    /// Mounted volumes (excluding system volumes) for the volume picker.
    static var mountedVolumes: [URL] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsLocalKey, .volumeIsRemovableKey]
        guard let vols = fm.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                               options: [.skipHiddenVolumes]) else { return [] }
        return vols.filter { url in
            // Skip the boot volume (/) and system partials
            url.path != "/" && !url.path.hasPrefix("/System")
        }
    }

    /// Recently used search paths, persisted across sessions.
    static let recentPathsKey = "PersonFinder.recentSearchPaths"
    static var recentPaths: [String] {
        UserDefaults.standard.stringArray(forKey: recentPathsKey) ?? []
    }
    static func recordRecentPath(_ path: String) {
        var paths = recentPaths.filter { $0 != path }
        paths.insert(path, at: 0)
        if paths.count > 10 { paths = Array(paths.prefix(10)) }
        UserDefaults.standard.set(paths, forKey: recentPathsKey)
    }

    func browseForOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose folder where clips and compiled video will be saved"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.outputDir = url.path
                model.settings.save()
            }
        }
    }

    func browsePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the Python executable (e.g. venv/bin/python)"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.pythonPath = url.path
                model.settings.save()
            }
        }
    }

    func browseScript() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.plainText]
        panel.message = "Select the face_recognize.py script"
        panel.prompt = "Select"
        panel.begin { [model] response in
            if response == .OK, let url = panel.url {
                model.settings.recognitionScript = url.path
                model.settings.save()
            }
        }
    }

    func revealClips(for result: ClipResult) {
        let dir = result.outputDir
        if let first = result.clipFiles.first(where: { !$0.isEmpty }) {
            let fullPath = (dir as NSString).appendingPathComponent(first)
            if FileManager.default.fileExists(atPath: fullPath) {
                NSWorkspace.shared.selectFile(fullPath, inFileViewerRootedAtPath: dir)
            } else {
                NSWorkspace.shared.open(URL(fileURLWithPath: dir))
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: dir))
        }
    }
}

// MARK: - Live Frame Preview

struct LiveFramePreview: View {
    let frame: CGImage
    let matchedRects: [CGRect]      // Vision normalized, bottom-left origin
    let unmatchedRects: [CGRect]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)

                Canvas { ctx, size in
                    let sw = size.width
                    let sh = size.height

                    func draw(_ rects: [CGRect], color: Color, lineWidth: CGFloat) {
                        for r in rects {
                            // Vision coords: origin bottom-left, y increases upward
                            let display = CGRect(
                                x: r.minX * sw,
                                y: (1 - r.maxY) * sh,
                                width: r.width * sw,
                                height: r.height * sh
                            )
                            ctx.stroke(Path(display), with: .color(color), lineWidth: lineWidth)
                            // Corner ticks
                            let tick: CGFloat = min(display.width, display.height) * 0.2
                            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                                (CGPoint(x: display.minX, y: display.minY + tick),
                                 CGPoint(x: display.minX, y: display.minY),
                                 CGPoint(x: display.minX + tick, y: display.minY)),
                                (CGPoint(x: display.maxX - tick, y: display.minY),
                                 CGPoint(x: display.maxX, y: display.minY),
                                 CGPoint(x: display.maxX, y: display.minY + tick)),
                                (CGPoint(x: display.minX, y: display.maxY - tick),
                                 CGPoint(x: display.minX, y: display.maxY),
                                 CGPoint(x: display.minX + tick, y: display.maxY)),
                                (CGPoint(x: display.maxX - tick, y: display.maxY),
                                 CGPoint(x: display.maxX, y: display.maxY),
                                 CGPoint(x: display.maxX, y: display.maxY - tick))
                            ]
                            for (a, b, c) in corners {
                                var p = Path(); p.move(to: a); p.addLine(to: b); p.addLine(to: c)
                                ctx.stroke(p, with: .color(color), lineWidth: lineWidth + 1)
                            }
                        }
                    }

                    draw(unmatchedRects, color: .yellow, lineWidth: 1.5)
                    draw(matchedRects,   color: .green,  lineWidth: 2.5)
                }
            }
        }
    }
}

// MARK: - Reference Face Card

struct ReferenceFaceCard: View {
    let face: ReferenceFace
    let onRemove: () -> Void

    var thumbnail: NSImage {
        NSImage(cgImage: face.thumbnail, size: NSSize(width: 80, height: 80))
    }

    var qualityColor: Color {
        switch face.quality {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(qualityColor, lineWidth: 3)
                    )
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(2)
            }

            // Confidence % — large and legible
            Text(String(format: "%.0f%%", face.confidence * 100))
                .font(.system(.callout, design: .rounded).weight(.bold))
                .foregroundColor(qualityColor)

            Text(face.sourceFilename)
                .font(.system(size: 8))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .center)
        }
        .frame(width: 88)
        .padding(4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .help(face.sourceFilename)
    }
}

// MARK: - Person Card (People Gallery)

struct PersonCard: View {
    let profile: POIProfile
    let isActive: Bool
    var justSaved: Bool = false

    private var ringGradient: AngularGradient {
        AngularGradient(
            colors: [.blue, .cyan, .blue.opacity(0.7), .cyan, .blue],
            center: .center
        )
    }

    private var savedGradient: AngularGradient {
        AngularGradient(
            colors: [.green, .mint, .green.opacity(0.7), .mint, .green],
            center: .center
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let img = profile.coverImage {
                    CroppedCircleImage(
                        image: img,
                        scale: profile.coverCropScale,
                        offset: CGSize(width: profile.coverCropOffsetX, height: profile.coverCropOffsetY)
                    )
                    .frame(width: 64, height: 64)
                } else {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 64, height: 64)
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: 26, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                }
            }
            .overlay(
                Circle()
                    .stroke(
                        justSaved ? savedGradient
                            : isActive ? ringGradient
                            : AngularGradient(colors: [.clear], center: .center),
                        lineWidth: (justSaved || isActive) ? 3.5 : 0
                    )
                    .animation(.easeInOut(duration: 0.3), value: justSaved)
            )
            .shadow(color: justSaved ? Color.green.opacity(0.6) : isActive ? Color.blue.opacity(0.5) : .clear,
                    radius: 6, y: 1)
            .animation(.easeInOut(duration: 0.3), value: justSaved)

            HStack(spacing: 3) {
                if justSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 9))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(justSaved ? "Saved" : profile.name)
                    .font(.system(size: 13, weight: isActive ? .bold : .medium))
                    .lineLimit(1)
                    .foregroundColor(justSaved ? .green : isActive ? .blue : .primary)
            }
            .animation(.easeInOut(duration: 0.3), value: justSaved)
        }
        .frame(width: 80)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Compact Face Thumbnail (for loaded-faces strip)

struct CompactFaceThumbnail: View {
    let face: ReferenceFace
    var size: CGFloat = 58
    var onRemove: (() -> Void)? = nil

    private var borderColor: Color {
        switch face.quality {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSImage(cgImage: face.thumbnail, size: NSSize(width: size, height: size)))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(borderColor, lineWidth: size > 80 ? 3 : 2)
                    )
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: size > 80 ? 16 : 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }
            Text(String(format: "%.0f%%", face.confidence * 100))
                .font(.system(size: size > 80 ? 11 : 9, weight: .medium, design: .monospaced))
                .foregroundColor(borderColor)
        }
        .contextMenu {
            if let onRemove {
                Button("Remove This Face", role: .destructive) { onRemove() }
            }
            Button("Info") {}
                .disabled(true)
            Text("\(face.sourceFilename)")
            Text(face.quality == .good ? "Good quality" : face.quality == .fair ? "Fair quality" : "Poor quality")
        }
        .help("\(face.sourceFilename) — \(String(format: "%.0f%%", face.confidence * 100))")
    }
}

// MARK: - Person Edit Sheet

struct PersonEditSheet: View {
    let originalProfile: POIProfile
    let onSave: (POIProfile) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var notes: String
    @State private var aliasText: String
    @State private var coverFilename: String?
    @State private var referencePath: String
    // Photo import
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var isImporting = false
    @State private var imageFilenamesCache: [String]? = nil

    // Cover crop
    @State private var cropScale: Double
    @State private var cropOffset: CGSize
    @State private var showCropEditor = false

    init(profile: POIProfile, onSave: @escaping (POIProfile) -> Void) {
        self.originalProfile = profile
        self.onSave = onSave
        _name = State(initialValue: profile.name)
        _notes = State(initialValue: profile.notes)
        _aliasText = State(initialValue: profile.aliases.joined(separator: ", "))
        _coverFilename = State(initialValue: profile.coverImageFilename)
        _referencePath = State(initialValue: profile.referencePath)
        _cropScale = State(initialValue: profile.coverCropScale)
        _cropOffset = State(initialValue: CGSize(width: profile.coverCropOffsetX, height: profile.coverCropOffsetY))
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
        return p
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
                    Text("Reference Photos")
                } footer: {
                    if !imageFilenames.isEmpty {
                        Text("Click a photo to set it as the cover image. \(imageFilenames.count) photo\(imageFilenames.count == 1 ? "" : "s") available.")
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
                    onSave(currentProfile)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(16)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 560, height: 720)
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
    }

    // MARK: Browse & Import

    /// Canonical local folder for this person's reference photos.
    /// Always under ~/dev/VideoScan/poi_photos/<name>/.
    private func ensureLocalPhotoFolder() -> URL {
        let sanitized = name.trimmingCharacters(in: .whitespaces)
            .lowercased().replacingOccurrences(of: " ", with: "_")
        let folderName = sanitized.isEmpty ? "reference" : sanitized
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("dev/VideoScan/poi_photos/\(folderName)")
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

        // Use a timestamp prefix to avoid overwriting previous imports
        let stamp = Int(Date().timeIntervalSince1970)
        for (i, item) in photosPickerItems.enumerated() {
            if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
                let dest = destDir.appendingPathComponent("apple_\(stamp)_\(i).\(ext)")
                try? data.write(to: dest)
            }
        }

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

// MARK: - Scan Target POI Badge

/// Shows who we're searching for next to "Scan Targets".
/// Pulsates the ring when a scan is actively running.
struct ScanTargetPOIBadge: View {
    let personName: String
    let coverImage: NSImage?
    let isScanning: Bool
    let faceCount: Int

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 6) {
            Text("for")
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack {
                // Pulse ring (behind avatar)
                if isScanning {
                    Circle()
                        .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                        .frame(width: 32, height: 32)
                        .scaleEffect(pulseScale)
                        .opacity(2.0 - Double(pulseScale))
                }

                if let img = coverImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.blue, lineWidth: isScanning ? 2 : 1.5))
                } else {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Text(String(personName.prefix(1)).uppercased())
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.accentColor)
                        )
                        .overlay(Circle().stroke(Color.blue, lineWidth: isScanning ? 2 : 1.5))
                }
            }

            Text(personName)
                .font(.callout.weight(.semibold))
                .foregroundColor(.blue)

            if faceCount > 0 {
                Text("(\(faceCount) faces)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { startPulse() }
        .onChange(of: isScanning) { _, scanning in
            if scanning { startPulse() }
        }
    }

    private func startPulse() {
        guard isScanning else {
            pulseScale = 1.0
            return
        }
        pulseScale = 1.0
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
            pulseScale = 1.6
        }
    }
}

// MARK: - Pulsating Ring (self-contained animation)

/// A spinning arc indicator — rotation animations are reliable on macOS SwiftUI.
struct SpinningRing: View {
    let color: Color
    var size: CGFloat = 22
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // Faint background track
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 2.5)
                .frame(width: size, height: size)
            // Spinning arc
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}

// MARK: - Scan Job Row

struct ScanJobRow: View {
    @ObservedObject var job: ScanJob
    @ObservedObject var model: PersonFinderModel
    let isSelected: Bool
    let isExpanded: Bool
    let threshold: Float
    let savedProfiles: [POIProfile]
    let onToggleExpand: () -> Void
    let onStart: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    let onReset: () -> Void
    let onRemove: () -> Void
    var onPreview: (() -> Void)? = nil

    @State private var showSettingsPopover = false
    @State private var startAlert: String? = nil

    private var isIdle: Bool { job.status.isIdle }
    private var isActive: Bool { job.status.isActive }
    private var isScanning: Bool { job.status == .scanning }

    private var personName: String { job.assignedProfile?.name ?? "—" }
    private var volName: String { (job.searchPath as NSString).lastPathComponent }
    private var engineName: String { job.effectiveEngine.rawValue }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Always visible: collapsed summary row
            collapsedRow
                .contentShape(Rectangle())
                .onTapGesture { onToggleExpand() }

            // Expanded detail area
            if isExpanded {
                Divider().padding(.vertical, 4)
                expandedDetail
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(isSelected ? Color.accentColor.opacity(0.12) : Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.accentColor.opacity(0.4) : Color.clear, lineWidth: 1.5)
        )
        .alert("Cannot Start", isPresented: Binding(
            get: { startAlert != nil },
            set: { if !$0 { startAlert = nil } }
        )) {
            Button("OK") { startAlert = nil }
        } message: {
            Text(startAlert ?? "")
        }
    }

    // MARK: - Collapsed row (always visible)

    private var collapsedRow: some View {
        HStack(spacing: 8) {
            // Chevron
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.secondary)
                .frame(width: 16)

            // Status indicator — only on collapsed row (expanded has its own)
            if !isExpanded {
                if isScanning {
                    SpinningRing(color: statusColor, size: 14)
                } else {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 10, height: 10)
                }
            }

            if isIdle {
                // Idle: show inline pickers right on the collapsed row
                inlinePersonPicker
                inlineVolumePicker
                inlineEnginePicker
            } else if !isExpanded {
                // Active/done: read-only summary text (hidden when expanded — shown in expandedDetail instead)
                let prefix: String = {
                    switch job.status {
                    case .done: return "Done:"
                    case .cancelled: return "Stopped:"
                    case .failed: return "Failed:"
                    case .scanning, .extracting: return "Searching for"
                    case .paused: return "Paused:"
                    default: return ""
                    }
                }()
                Text(prefix)
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(personName)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)

                if !volName.isEmpty {
                    Text("on")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                    Text(volName)
                        .font(.title3.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Text("using")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                Text(engineName)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            // Compact stats on collapsed row
            if job.videosTotal > 0 {
                Text("\(job.videosWithHits)")
                    .font(.system(.body, design: .monospaced).weight(.bold))
                    .foregroundColor(.green)
                Text("/")
                    .font(.callout)
                    .foregroundColor(.secondary)
                Text("\(job.videosScanned)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            if job.elapsedSecs > 0 {
                Text(formatElapsed(job.elapsedSecs))
                    .font(.system(.callout, design: .monospaced))
                    .foregroundColor(.secondary)
            }

            // Status badge
            statusBadge

            // Compact action buttons — only when collapsed to avoid duplication
            if !isExpanded {
                if isActive {
                    Button(action: onPause) {
                        Image(systemName: job.status.isPaused ? "play.fill" : "pause.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)

                    Button(action: onStop) {
                        Image(systemName: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                } else if isIdle {
                    Button {
                        if job.assignedProfile == nil {
                            startAlert = "Select a person to search for"
                        } else if job.searchPath.isEmpty {
                            startAlert = "Select a volume to be scanned"
                        } else {
                            onStart()
                        }
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)

                    Button(action: onRemove) {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .foregroundColor(.red)
                }
            }
        }
    }

    // MARK: - Inline pickers (collapsed row, idle state)

    private var inlinePersonPicker: some View {
        Menu {
            ForEach(savedProfiles) { profile in
                Button {
                    job.assignedProfile = profile
                    if job.assignedEngine == nil,
                       let eng = RecognitionEngine(rawValue: profile.engine) {
                        job.assignedEngine = eng
                    }
                } label: {
                    Label(profile.name, systemImage: job.assignedProfile?.id == profile.id ? "checkmark.circle.fill" : "person.circle")
                }
            }
            if savedProfiles.isEmpty {
                Text("No people added yet")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .foregroundColor(job.assignedProfile != nil ? .accentColor : .secondary)
                Text(job.assignedProfile?.name ?? "Person…")
                    .fontWeight(job.assignedProfile != nil ? .medium : .regular)
                    .foregroundColor(job.assignedProfile != nil ? .primary : .secondary)
            }
            .font(.body)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var inlineVolumePicker: some View {
        Menu {
            let vols = PersonFinderView.mountedVolumes
            if !vols.isEmpty {
                Section("Mounted Volumes") {
                    ForEach(vols, id: \.path) { vol in
                        Button(vol.lastPathComponent) {
                            job.searchPath = vol.path
                            PersonFinderView.recordRecentPath(vol.path)
                        }
                    }
                }
            }
            let recents = PersonFinderView.recentPaths
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            job.searchPath = path
                        }
                    }
                }
            }
            Divider()
            Button("Browse…") {
                browsePath()
                if !job.searchPath.isEmpty {
                    PersonFinderView.recordRecentPath(job.searchPath)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .foregroundColor(!job.searchPath.isEmpty ? .accentColor : .secondary)
                Text(!job.searchPath.isEmpty ? (job.searchPath as NSString).lastPathComponent : "Volume…")
                    .fontWeight(!job.searchPath.isEmpty ? .medium : .regular)
                    .foregroundColor(!job.searchPath.isEmpty ? .primary : .secondary)
                    .lineLimit(1)
            }
            .font(.body)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    private var inlineEnginePicker: some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(
                get: { job.effectiveEngine },
                set: { job.assignedEngine = $0 }
            )) {
                ForEach(RecognitionEngine.allCases) { eng in
                    Text(eng.rawValue).tag(eng)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Button {
                showSettingsPopover.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                engineSettingsPopover
            }
        }
    }

    // MARK: - Per-row engine settings popover

    private var engineSettingsPopover: some View {
        let engine = job.effectiveEngine
        return VStack(alignment: .leading, spacing: 12) {
            Text("Settings — \(engine.rawValue)")
                .font(.headline)

            // Common settings
            Group {
                LabeledControl("Match Threshold") {
                    Slider(value: model.settingsBinding.threshold, in: 0.3...0.9, step: 0.05)
                        .frame(width: 140)
                    Text(String(format: "%.2f", model.settings.threshold))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 38)
                }
                LabeledControl("Min Face Confidence") {
                    Slider(value: model.settingsBinding.minFaceConfidence.asDouble, in: 0.3...1.0, step: 0.05)
                        .frame(width: 140)
                    Text(String(format: "%.2f", model.settings.minFaceConfidence))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 38)
                }
                LabeledControl("Frame Step") {
                    TextField("", value: model.settingsBinding.frameStep, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 54)
                    Text("frames")
                }
                LabeledControl("Min Presence") {
                    TextField("", value: model.settingsBinding.minPresenceSecs, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                    Text("sec")
                }
            }

            Divider()

            Toggle("Primary face only", isOn: model.settingsBinding.requirePrimary)
            Toggle("Skip background faces", isOn: model.settingsBinding.largestFaceOnly)

            Divider()

            // Engine-specific settings
            if engine == .dlib || engine == .hybrid {
                LabeledControl("Python Path") {
                    TextField("", text: model.settingsBinding.pythonPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                LabeledControl("Recognition Script") {
                    TextField("", text: model.settingsBinding.recognitionScript)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                if engine == .dlib {
                    HStack(spacing: 4) {
                        Image(systemName: model.settings.dlibReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(model.settings.dlibReady ? .green : .red)
                        Text(model.settings.dlibReady ? "dlib ready" : "dlib not configured")
                            .font(.callout)
                    }
                }
            }

            Divider()

            // Compile options
            Toggle("Compile to one video", isOn: model.settingsBinding.concatOutput)
                .disabled(model.settings.decadeChapters)
            Toggle("Decade chapter video", isOn: model.settingsBinding.decadeChapters)

            Divider()

            LabeledControl("Parallel Jobs") {
                TextField("", value: model.settingsBinding.concurrency, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 54)
                Stepper("", value: model.settingsBinding.concurrency, in: 1...32)
                    .labelsHidden()
            }

            Text("Settings apply when scan starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }

    // MARK: - Status badge

    @ViewBuilder
    private var statusBadge: some View {
        switch job.status {
        case .done:
            Label("Done", systemImage: "checkmark.circle.fill")
                .font(.body.weight(.semibold))
                .foregroundColor(.green)
        case .scanning:
            Text("Scanning")
                .font(.body.weight(.semibold))
                .foregroundColor(.blue)
        case .paused:
            Text("Paused")
                .font(.body.weight(.semibold))
                .foregroundColor(.yellow)
        case .extracting:
            Text("Extracting")
                .font(.body.weight(.semibold))
                .foregroundColor(.orange)
        case .failed:
            Text("Failed")
                .font(.body.weight(.semibold))
                .foregroundColor(.red)
        case .cancelled:
            Text("Stopped")
                .font(.body.weight(.semibold))
                .foregroundColor(.secondary)
        default:
            EmptyView()
        }
    }

    // MARK: - Expanded detail

    private var expandedDetail: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Status summary line for non-idle jobs
            if !isIdle {
                HStack(spacing: 10) {
                    if isScanning {
                        SpinningRing(color: statusColor, size: 22)
                    }

                    let prefix: String = {
                        switch job.status {
                        case .done: return "Done:"
                        case .cancelled: return "Stopped:"
                        case .failed: return "Failed:"
                        case .scanning, .extracting: return "Searching for"
                        case .paused: return "Paused:"
                        default: return ""
                        }
                    }()
                    Text(prefix)
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(personName)
                        .font(.title2.weight(.bold))
                    if !volName.isEmpty {
                        Text("on")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                        Text(volName)
                            .font(.title2.weight(.medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Text("using")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text(engineName)
                        .font(.title2.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }

            // Stats + full action buttons
            HStack(spacing: 10) {
                if job.videosTotal > 0 {
                    Label("\(job.videosWithHits) matches", systemImage: "person.fill.checkmark")
                        .font(.body.weight(.medium))
                        .foregroundColor(.green)
                    Text("\(job.videosScanned) / \(job.videosTotal) videos")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                if job.elapsedSecs > 0 {
                    Text(formatElapsed(job.elapsedSecs))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                Spacer()

                expandedActionButtons
            }

            // Progress ring
            if job.videosTotal > 0 {
                ScanRingChart(
                    total: job.videosTotal,
                    scanned: job.videosScanned,
                    hits: job.videosWithHits,
                    elapsedSecs: job.elapsedSecs,
                    currentFile: isActive ? job.currentFile : "",
                    bestDist: job.bestDist,
                    threshold: threshold
                )
            } else if isActive {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
                    Text(job.status.label).font(.callout).foregroundColor(.secondary)
                }
            }

            // Compiled outputs
            if !job.compiledVideoPaths.isEmpty {
                compiledOutputsView
            }
        }
    }

    // MARK: - Expanded action buttons (full labels)

    @ViewBuilder
    private var expandedActionButtons: some View {
        if isActive {
            Button(action: onPause) {
                Label(job.status.isPaused ? "Resume" : "Pause",
                      systemImage: job.status.isPaused ? "play.fill" : "pause.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            Button(action: onStop) {
                Label("Stop", systemImage: "stop.fill")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)

            if job.status == .scanning, let onPreview {
                Button { onPreview() } label: {
                    Label("Preview", systemImage: "eye.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
        } else {
            Button {
                if job.assignedProfile == nil {
                    startAlert = "Select a person to search for"
                } else if job.searchPath.isEmpty {
                    startAlert = "Select a volume to be scanned"
                } else {
                    onStart()
                }
            } label: {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)

            if !isIdle {
                Button(action: onReset) {
                    Label("Reset", systemImage: "arrow.counterclockwise")
                }
                .buttonStyle(.bordered)
                .controlSize(.regular)
            }
            Button(action: onRemove) {
                Image(systemName: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .foregroundColor(.red)
        }
    }

    // MARK: - Compiled outputs

    private var compiledOutputsView: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "film.stack")
                    .foregroundColor(.accentColor)
                Text("\(job.compiledVideoPaths.count) compilation\(job.compiledVideoPaths.count == 1 ? "" : "s")")
                    .font(.system(.callout, weight: .semibold))
                    .foregroundColor(.accentColor)
            }
            ForEach(job.compiledVideoPaths) { out in
                HStack(spacing: 8) {
                    Text((out.path as NSString).lastPathComponent)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text("\(out.clipCount) clip\(out.clipCount == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(pfFormatDuration(out.durationSecs))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(pfFormatBytes(out.bytesOnDisk))
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Spacer()
                    Button("Reveal") {
                        NSWorkspace.shared.selectFile(out.path, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    Button("Open") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: out.path))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(Color.accentColor.opacity(0.08))
        .cornerRadius(6)
    }

    var statusColor: Color {
        switch job.status {
        case .idle:       return .secondary
        case .loading:    return .yellow
        case .scanning:   return .blue
        case .paused:     return .yellow
        case .extracting: return .orange
        case .done:       return .green
        case .cancelled:  return .secondary
        case .failed:     return .red
        }
    }

    func browsePath() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a volume or folder to scan"
        panel.prompt = "Select"
        panel.begin { response in
            if response == .OK, let url = panel.url {
                self.job.searchPath = url.path
                PersonFinderView.recordRecentPath(url.path)
            }
        }
    }

}

// MARK: - Helper Views

struct LabeledControl<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 4) { content() }
        }
    }
}

struct RecognitionEnginePanel: View {
    let engine: RecognitionEngine
    @Binding var pythonPath: String
    @Binding var recognitionScript: String
    let dlibReady: Bool
    let dlibReadyForHybrid: Bool
    let browsePython: () -> Void
    let browseScript: () -> Void

    private var statusText: String {
        switch engine {
        case .vision:
            return "Built-in module is ready"
        case .arcface:
            return "ArcFace CoreML — local face identity model on ANE"
        case .dlib:
            return dlibReady ? "Python recognizer is ready" : "Set Python and Script paths to enable this module"
        case .hybrid:
            return dlibReadyForHybrid ? "Vision will fall back to dlib when needed" : "Running in Vision-only mode until dlib paths are configured"
        }
    }

    private var statusSymbol: String {
        switch engine {
        case .vision:
            return "checkmark.circle"
        case .arcface:
            return "brain"
        case .dlib:
            return dlibReady ? "checkmark.circle" : "exclamationmark.triangle"
        case .hybrid:
            return dlibReadyForHybrid ? "arrow.triangle.branch" : "info.circle"
        }
    }

    private var statusColor: Color {
        switch engine {
        case .vision:
            return .green
        case .arcface:
            return .green
        case .dlib:
            return dlibReady ? .green : .orange
        case .hybrid:
            return dlibReadyForHybrid ? .green : .secondary
        }
    }

    private var showsDlibConfig: Bool {
        engine == .dlib || engine == .hybrid
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: engine.symbolName)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 34, height: 34)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(engine.title)
                            .font(.headline)
                        Text(engine.shortLabel.uppercased())
                            .font(.system(size: 10, weight: .bold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                    }
                    Text(engine.subtitle)
                        .foregroundStyle(.secondary)
                    Label(statusText, systemImage: statusSymbol)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer(minLength: 0)
            }

            if showsDlibConfig {
                HStack(alignment: .top, spacing: 24) {
                    LabeledControl("Python") {
                        TextField("venv/bin/python…", text: $pythonPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 280)
                        Button("…") { browsePython() }
                            .controlSize(.small)
                    }
                    LabeledControl("Script") {
                        TextField("face_recognize.py…", text: $recognitionScript)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 280)
                        Button("…") { browseScript() }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }

            Text("Recognition engines are modular. Add a new case to the registry and implement the shared scan contract to plug another backend into this selector.")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text("Live scans use the settings captured when that scan starts. Changing modules while a job is paused or running does not switch the active engine mid-video.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if showsDlibConfig {
                Text("Heavy scans are auto-limited based on free RAM to avoid runaway memory use.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(NSColor.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

// MARK: - Scan Ring Chart

struct ScanRingChart: View {
    let total: Int
    let scanned: Int
    let hits: Int
    let elapsedSecs: Double
    let currentFile: String
    let bestDist: Float
    let threshold: Float

    private var scannedFrac: Double { total > 0 ? min(1, Double(scanned) / Double(total)) : 0 }
    private var hitsFrac:    Double { total > 0 ? min(1, Double(hits)    / Double(total)) : 0 }
    private var vps: Double? { elapsedSecs > 2 && scanned > 2 ? Double(scanned) / elapsedSecs : nil }

    // Colour the best-dist reading relative to the active threshold
    private var distColor: Color {
        guard bestDist < .greatestFiniteMagnitude else { return .secondary }
        if bestDist <= threshold          { return .green }   // within threshold — a hit
        if bestDist <= threshold + 0.10   { return .orange }  // close — might just need threshold nudge
        return .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: scannedFrac)
                    .stroke(Color.blue.opacity(0.45),
                            style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: scannedFrac)
                Circle()
                    .trim(from: 0, to: hitsFrac)
                    .stroke(Color.green,
                            style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: hitsFrac)
                VStack(spacing: 0) {
                    Text("\(scanned)")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                    Text("/ \(total)")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)

            // Stats + best dist
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("\(hits) match\(hits == 1 ? "" : "es")")
                        .font(.callout.weight(.semibold)).foregroundColor(.green)
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.blue.opacity(0.5)).frame(width: 7, height: 7)
                    Text("\(scanned) scanned")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
                    Text("\(max(0, total - scanned)) remaining")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let v = vps {
                    Text(String(format: "%.1f vid/s", v))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().frame(height: 56)

            // Best distance — the key calibration number
            VStack(alignment: .center, spacing: 2) {
                Text("BEST DIST")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                if bestDist < .greatestFiniteMagnitude {
                    Text(String(format: "%.3f", bestDist))
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .foregroundColor(distColor)
                        .animation(.easeInOut(duration: 0.3), value: bestDist)
                } else {
                    Text("—")
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("thresh \(String(format: "%.2f", threshold))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !currentFile.isEmpty {
                    Text((currentFile as NSString).lastPathComponent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .center)
                }
            }
            .frame(minWidth: 90)
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Realtime Face Detection Window

struct RealtimeFaceDetectionContent: View {
    @ObservedObject var model: PersonFinderModel
    let initialJobID: UUID?
    @State private var selectedJobID: UUID?

    init(model: PersonFinderModel, initialJobID: UUID? = nil) {
        self.model = model
        self.initialJobID = initialJobID
        _selectedJobID = State(initialValue: initialJobID)
    }

    private var jobs: [ScanJob] { model.jobs }

    /// Resolve which job to display. Honor the user's explicit pick always.
    /// Otherwise auto-pick a scanning job.
    private var activeJob: ScanJob? {
        if let sel = selectedJobID,
           let j = jobs.first(where: { $0.id == sel }) {
            return j
        }
        return jobs.first(where: { $0.status == .scanning })
            ?? jobs.first(where: { $0.status.isActive })
            ?? jobs.first
    }

    var body: some View {
        // NOTE: The parent only re-renders when @State (selectedJobID) changes.
        // To get live frame updates, the active job must be observed via
        // @ObservedObject in a child view — that's ActiveJobFaceDetectView below.
        Group {
            if let job = activeJob {
                ActiveJobFaceDetectView(
                    job: job,
                    jobs: jobs,
                    selectedJobID: $selectedJobID,
                    fallbackEngineTitle: model.settings.recognitionEngine.title,
                    fallbackPersonName: model.settings.personName
                )
            } else {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        VStack(spacing: 12) {
                            Image(systemName: "face.dashed")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.5))
                            if jobs.contains(where: { $0.status.isActive }) {
                                ProgressView().colorScheme(.dark)
                                Text("Waiting for frames...")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Start a scan to see realtime face detection")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 520)
    }
}

/// Inner view that owns an @ObservedObject reference to the active ScanJob, so
/// SwiftUI re-renders when liveFrame / status / counters mutate. The outer
/// RealtimeFaceDetectionContent does NOT observe the jobs (it just holds a
/// `let [ScanJob]`), which is why we need this child wrapper.
private struct ActiveJobFaceDetectView: View {
    @ObservedObject var job: ScanJob
    let jobs: [ScanJob]
    @Binding var selectedJobID: UUID?
    let fallbackEngineTitle: String
    let fallbackPersonName: String

    private var personName: String { job.assignedProfile?.name ?? fallbackPersonName }
    private var engineTitle: String {
        if let eng = job.assignedProfile?.engine, let re = RecognitionEngine(rawValue: eng) {
            return re.title
        }
        return fallbackEngineTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            // Video frame area
            ZStack {
                Color.black

                if job.status == .done || job.status == .extracting {
                    // Scan finished — clear the frame and show completion message
                    VStack(spacing: 14) {
                        Image(systemName: job.status == .extracting ? "scissors" : "checkmark.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(job.status == .extracting ? .orange : .green)

                        if job.status == .extracting {
                            Text("Generating Clips")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                            if !personName.isEmpty {
                                Text("for \(personName)")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            ProgressView()
                                .colorScheme(.dark)
                                .scaleEffect(1.2)
                        } else {
                            Text("Search Complete")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                            if !personName.isEmpty {
                                Text(personName)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            Text(engineTitle)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.cyan)
                                .padding(.top, -6)
                        }

                        // Stats grid
                        HStack(spacing: 24) {
                            VStack(spacing: 2) {
                                Text("\(job.videosScanned)")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                Text("videos scanned")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            VStack(spacing: 2) {
                                Text("\(job.videosWithHits)")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(job.videosWithHits > 0 ? .green : .white)
                                Text("with matches")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            VStack(spacing: 2) {
                                Text("\(job.clipsFound)")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(job.clipsFound > 0 ? .green : .white)
                                Text("clips found")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            if job.presenceSecs > 0 {
                                VStack(spacing: 2) {
                                    Text(formatElapsed(job.presenceSecs))
                                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.green)
                                    Text("presence")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            VStack(spacing: 2) {
                                Text(formatElapsed(job.elapsedSecs))
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                Text("elapsed")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.top, 4)

                        // Volume path
                        let vol = (job.searchPath as NSString).lastPathComponent
                        if !vol.isEmpty {
                            Text(vol)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.top, 2)
                        }
                    }
                } else if let frame = job.liveFrame {
                    LiveFramePreview(
                        frame: frame,
                        matchedRects: job.liveMatchedRects,
                        unmatchedRects: job.liveUnmatchedRects
                    )
                    .overlay(alignment: .topLeading) {
                        FaceDetectHUD(job: job)
                            .padding(10)
                    }
                    .overlay(alignment: .topTrailing) {
                        FaceDetectLegend(engineTitle: engineTitle, personName: personName)
                            .padding(10)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "face.dashed")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.5))
                        ProgressView().colorScheme(.dark)
                        Text("Waiting for frames...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(16/9, contentMode: .fit)

            // Display Rate toolbar
            if job.status == .scanning {
                HStack(spacing: 10) {
                    Text("Display Rate")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(job.previewRate) },
                        set: { job.previewRate = max(1, Int($0)) }
                    ), in: 1...10, step: 1)
                        .frame(width: 160)
                    Text("\(job.previewRate)")
                        .font(.system(size: 16, design: .monospaced))
                        .frame(width: 24)
                    Text(job.previewRate == 1 ? "every frame" : "every \(job.previewRate) frames")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
            }

            // Bottom status bar
            HStack(spacing: 12) {
                if jobs.count > 1 {
                    Picker("Job", selection: Binding(
                        get: { selectedJobID ?? job.id },
                        set: { selectedJobID = $0 }
                    )) {
                        ForEach(jobs) { j in
                            let vol = (j.searchPath as NSString).lastPathComponent
                            let person = j.assignedProfile?.name
                            let status = j.status == .done ? " [Done]" :
                                         j.status == .scanning ? " [Scanning]" :
                                         j.status.isActive ? " [Active]" : ""
                            Text((person != nil ? "\(person!) — \(vol)" : vol) + status)
                                .font(.system(size: 14))
                                .tag(j.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 350)
                }

                Circle()
                    .fill(job.status == .scanning ? Color.green :
                          job.status == .done ? Color.green.opacity(0.5) : Color.secondary)
                    .frame(width: 12, height: 12)

                // Person being searched
                if !personName.isEmpty {
                    Text(personName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                }

                Text(job.status.label)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                if !job.currentFile.isEmpty {
                    Text(job.currentFile)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }

                Spacer()
                if job.videosTotal > 0 {
                    Text("\(job.videosScanned)/\(job.videosTotal) videos")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(job.videosWithHits) match(es)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(job.videosWithHits > 0 ? .green : .secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        // When the displayed job goes inactive, nudge the parent to re-evaluate
        // its computed activeJob (e.g. another job is now scanning).
        .onChange(of: job.status) { _, newStatus in
            if !newStatus.isActive {
                if let next = jobs.first(where: { $0.status == .scanning })
                    ?? jobs.first(where: { $0.status.isActive }) {
                    selectedJobID = next.id
                }
            }
        }
    }
}

/// Floating HUD showing live detection stats — compact single-line top-left badge
/// plus key stats below.
private struct FaceDetectHUD: View {
    @ObservedObject var job: ScanJob

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundColor(.red)
                Text("LIVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                if job.videosTotal > 0 {
                    Text("\(job.videosScanned)/\(job.videosTotal)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
                Text(pfFormatDuration(job.elapsedSecs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            HStack(spacing: 10) {
                Text("Hits \(job.videosWithHits)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(job.videosWithHits > 0 ? .green : .white.opacity(0.7))
                if job.bestDist < .greatestFiniteMagnitude {
                    Text(String(format: "Best %.3f", job.bestDist))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55))
        .cornerRadius(6)
    }
}

/// Compact engine + legend badge — top-right corner.
private struct FaceDetectLegend: View {
    let engineTitle: String
    var personName: String = ""

    var body: some View {
        HStack(spacing: 8) {
            if !personName.isEmpty {
                Text(personName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
            Text(engineTitle)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.cyan)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(.green)
                    .frame(width: 10, height: 10)
                Text("Match")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(.yellow)
                    .frame(width: 10, height: 10)
                Text("Face")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5))
        .cornerRadius(6)
    }
}

@MainActor
class PreviewWindowController {
    static let shared = PreviewWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(model: PersonFinderModel, focusJobID: UUID? = nil) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        close()

        let content = RealtimeFaceDetectionContent(model: model, initialJobID: focusJobID)
        let hosting = NSHostingView(rootView: content)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // CRITICAL: NSWindow defaults to isReleasedWhenClosed=true, which
        // double-releases the window (AppKit releases on close, ARC releases
        // when our `window` ref drops). That leaves `self.window` pointing
        // at freed memory and the next show() crashes inside objc_retain.
        w.isReleasedWhenClosed = false
        w.title = "Realtime Face Detection"
        w.contentView = hosting
        w.setFrameAutosaveName("RealtimeFaceDetectV2")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        // When the user closes via the red button, drop our reference so the
        // next show() builds a fresh window instead of trying to reopen one.
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.window = nil
            if let obs = self.closeObserver {
                NotificationCenter.default.removeObserver(obs)
                self.closeObserver = nil
            }
        }
    }


    func close() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
        window?.close()
        window = nil
    }
}

// MARK: - Job Console Window

/// Floating console window with a per-job picker. Mirrors the Realtime
/// Face Detection window pattern: outer view holds the picker selection;
/// an inner view observes the selected ScanJob so log appends repaint live.
struct JobConsoleContent: View {
    @ObservedObject var model: PersonFinderModel
    let initialJobID: UUID?
    @State private var selectedJobID: UUID?

    init(model: PersonFinderModel, initialJobID: UUID? = nil) {
        self.model = model
        self.initialJobID = initialJobID
        _selectedJobID = State(initialValue: initialJobID)
    }

    private var jobs: [ScanJob] { model.jobs }

    /// Auto-pick a sensible default if the user hasn't chosen, preferring
    /// an actively scanning job.
    private var resolvedJob: ScanJob? {
        if let sel = selectedJobID,
           let j = jobs.first(where: { $0.id == sel }) {
            return j
        }
        return jobs.first(where: { $0.status == .scanning })
            ?? jobs.first(where: { $0.status.isActive })
            ?? jobs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundColor(.secondary)
                Text("Job:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $selectedJobID) {
                    ForEach(jobs) { job in
                        Text(jobMenuLabel(job))
                            .tag(Optional(job.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 420)

                Spacer()

                if let job = resolvedJob, job.status.isActive {
                    ProgressView().scaleEffect(0.6)
                    Text(job.status.label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if let job = resolvedJob {
                    Text("\(job.consoleLines.count) lines")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button("Clear") {
                        job.consoleLines.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if let job = resolvedJob {
                JobConsoleBody(job: job)
            } else {
                ZStack {
                    Color(NSColor.textBackgroundColor)
                    Text("No jobs yet — add a scan target to see console output.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 820, minHeight: 320, idealHeight: 480)
    }

    private func jobMenuLabel(_ job: ScanJob) -> String {
        let name = (job.searchPath as NSString).lastPathComponent
        let trimmed = name.isEmpty ? job.searchPath : name
        return "\(trimmed)  —  \(job.status.label)"
    }
}

/// Inner view observes the active ScanJob so SwiftUI re-renders when
/// consoleLines mutates. The outer JobConsoleContent only owns the picker
/// state and does not observe individual jobs.
private struct JobConsoleBody: View {
    @ObservedObject var job: ScanJob

    var body: some View {
        ConsoleView(lines: job.consoleLines)
            .background(Color(NSColor.textBackgroundColor))
    }
}

@MainActor
class JobConsoleWindowController {
    static let shared = JobConsoleWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(model: PersonFinderModel, focusJobID: UUID? = nil) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        close()

        let content = JobConsoleContent(model: model, initialJobID: focusJobID)
        let hosting = NSHostingView(rootView: content)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false  // see PreviewWindowController for rationale
        w.title = "Face Detection Console"
        w.contentView = hosting
        w.setFrameAutosaveName("JobConsoleV1")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.window = nil
            if let obs = self.closeObserver {
                NotificationCenter.default.removeObserver(obs)
                self.closeObserver = nil
            }
        }
    }

    func close() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
        window?.close()
        window = nil
    }
}

// MARK: - Binding helpers

extension Binding where Value == Float {
    var asDouble: Binding<Double> {
        Binding<Double>(
            get: { Double(wrappedValue) },
            set: { wrappedValue = Float($0) }
        )
    }
}
