// PersonFinderView.swift
// Multi-volume person-finding UI — jobs list, progress bars, results, console.

import SwiftUI
import AppKit
import UniformTypeIdentifiers

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
                                CompactFaceThumbnail(
                                    face: face,
                                    size: cellSize,
                                    onRemove: { model.removeReferenceFace(id: face.id) },
                                    sourceFileURL: referenceFaceURL(for: face)
                                )
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

                // Start All / Stop All visibility mirrors state:
                // hide Start All once nothing is idle (matches "Stop All is
                // disabled when nothing is active"), so the header doesn't
                // dangle an enabled-looking Start button during a live search.
                let anyIdle   = model.jobs.contains { $0.status.isIdle }
                let anyActive = model.jobs.contains { $0.status.isActive }
                if model.jobs.count > 1 && anyIdle {
                    Button(action: {
                        model.startAll()
                        if selectedJobID == nil { selectedJobID = model.jobs.first?.id }
                    }) {
                        Label("Start All", systemImage: "play.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                }
                if model.jobs.count > 1 && anyActive {
                    Button(action: { model.stopAll() }) {
                        Label("Stop All", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
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

    /// Resolve a reference face back to its source image on disk. Returns
    /// nil if the file doesn't actually exist where expected — don't surface
    /// a broken Show-in-Finder item in that case.
    private func referenceFaceURL(for face: ReferenceFace) -> URL? {
        let refPath = model.settings.referencePath
        guard !refPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: refPath).appendingPathComponent(face.sourceFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
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
    /// Optional full path to the source image on disk. When set, a
    /// "Show in Finder" item appears in the context menu so users can
    /// see where the reference photo actually lives.
    var sourceFileURL: URL? = nil

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
            if let sourceFileURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([sourceFileURL])
                }
            }
            if let onRemove {
                Button("Remove This Face", role: .destructive) { onRemove() }
            }
            Divider()
            Text("\(face.sourceFilename)")
            Text(face.quality == .good ? "Good quality" : face.quality == .fair ? "Fair quality" : "Poor quality")
        }
        .help("\(face.sourceFilename) — \(String(format: "%.0f%%", face.confidence * 100))")
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
