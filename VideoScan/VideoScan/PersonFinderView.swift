// PersonFinderView.swift
// Multi-volume person-finding UI — jobs list, progress bars, results, console.

import SwiftUI
import AppKit
import PhotosUI

// MARK: - Main View

struct PersonFinderView: View {
    @EnvironmentObject var dashboard: DashboardState
    @State private var model = PersonFinderModel()
    @State private var selectedJobID: UUID? = nil
    @State private var showSettings = false
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var isImportingFromPhotos = false
    @State private var autoRejectPct: Int = 60

    var selectedJob: ScanJob? { model.jobs.first { $0.id == selectedJobID } }

    var body: some View {
        VStack(spacing: 0) {
            referenceBar
            Divider()
            outputBar
            Divider()
            settingsBar
            Divider()
            jobsSection
            Divider()
            VSplitView {
                resultsTable
                consolePane
            }
        }
        .frame(minWidth: 960, minHeight: 650)
        .onAppear { model.dashboard = dashboard }
    }

    // MARK: Reference bar — who are we looking for?

    var referenceBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.rectangle.stack")
                    .font(.title2)
                    .foregroundColor(.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Reference Photos").font(.headline)
                    Text("Add photos from any source — they accumulate")
                        .font(.caption).foregroundColor(.secondary)
                }

                TextField("Folder of reference photos…", text: model.settingsBinding.referencePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    .onSubmit { Task { await model.loadReference() } }

                Button("Browse Folder…") { browseForReference() }
                    .controlSize(.large)

                Button("Add Folder") {
                    Task { await model.loadReference() }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.settings.referencePath.isEmpty || model.isLoadingReference)

                PhotosPicker(
                    selection: $photosPickerItems,
                    maxSelectionCount: 50,
                    matching: .images
                ) {
                    Label(isImportingFromPhotos ? "Importing…" : "Add from Apple Photos",
                          systemImage: "photo.on.rectangle.angled")
                }
                .controlSize(.large)
                .disabled(isImportingFromPhotos)
                .onChange(of: photosPickerItems) {
                    guard !photosPickerItems.isEmpty else { return }
                    Task { await importFromApplePhotos(photosPickerItems) }
                }

                if model.isLoadingReference || isImportingFromPhotos {
                    ProgressView().scaleEffect(0.8)
                }

                if !model.referenceFaces.isEmpty {
                    HStack(spacing: 4) {
                        Text("Remove <")
                            .font(.callout).foregroundStyle(.secondary)
                        TextField("", value: $autoRejectPct, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 44)
                        Stepper("", value: $autoRejectPct, in: 1...99).labelsHidden()
                        Text("%")
                            .font(.callout).foregroundStyle(.secondary)
                        Button("Apply") {
                            model.removeReferenceFaces(belowConfidence: Float(autoRejectPct) / 100.0)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    Button("Clear All", role: .destructive) { model.clearReference() }
                        .controlSize(.large)
                }

                Divider().frame(height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Person Name").font(.headline)
                    Text("Used for filenames")
                        .font(.caption).foregroundColor(.secondary)
                }
                TextField("e.g. Donna", text: model.settingsBinding.personName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }

            // Status row + face grid
            if !model.referenceFaces.isEmpty || model.referenceLoadError != nil {
                HStack(spacing: 8) {
                    if !model.referenceFaces.isEmpty {
                        Label("\(model.referencePhotoCount) face(s) from \(model.referenceSources.count) source(s)",
                              systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.callout.weight(.medium))
                        let good = model.referenceFaces.filter { $0.quality == .good }.count
                        let fair = model.referenceFaces.filter { $0.quality == .fair }.count
                        let poor = model.referenceFaces.filter { $0.quality == .poor }.count
                        if good > 0 { Text("\(good) good").foregroundColor(.green).font(.caption) }
                        if fair > 0 { Text("\(fair) fair").foregroundColor(.yellow).font(.caption) }
                        if poor > 0 { Text("\(poor) poor").foregroundColor(.red).font(.caption) }
                    }
                    if let err = model.referenceLoadError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.callout)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        ForEach(model.referenceFaces) { face in
                            ReferenceFaceCard(face: face) {
                                model.removeReferenceFace(id: face.id)
                            }
                        }
                    }
                    .padding(.horizontal, 4)
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 124)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(NSColor.windowBackgroundColor))
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

    // MARK: Settings bar

    var settingsBar: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    LabeledControl("Match Threshold") {
                        Slider(value: model.settingsBinding.threshold, in: 0.3...0.9, step: 0.05)
                            .frame(width: 130)
                        Text(String(format: "%.2f", model.settings.threshold))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 38)
                    }
                    LabeledControl("Min Face Confidence") {
                        Slider(value: model.settingsBinding.minFaceConfidence.asDouble, in: 0.3...1.0, step: 0.05)
                            .frame(width: 110)
                        Text(String(format: "%.2f", model.settings.minFaceConfidence))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 38)
                    }
                    LabeledControl("Min Presence") {
                        TextField("", value: model.settingsBinding.minPresenceSecs, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 64)
                        Text("sec")
                    }
                    LabeledControl("Frame Step") {
                        TextField("", value: model.settingsBinding.frameStep, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 54)
                        Text("frames")
                    }
                    LabeledControl("Parallel Jobs") {
                        TextField("", value: model.settingsBinding.concurrency, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 54)
                        Stepper("", value: model.settingsBinding.concurrency, in: 1...32)
                            .labelsHidden()
                        Text("(max \(ProcessInfo.processInfo.processorCount) cores)")
                            .foregroundStyle(.secondary).font(.caption)
                    }
                    Spacer()
                }
                HStack(spacing: 24) {
                    Toggle("Primary face only", isOn: model.settingsBinding.requirePrimary)
                    Toggle("Skip background faces in references", isOn: model.settingsBinding.largestFaceOnly)
                    Toggle("Compile to one video", isOn: model.settingsBinding.concatOutput)
                        .disabled(model.settings.decadeChapters)
                    Toggle("Decade chapter video", isOn: model.settingsBinding.decadeChapters)
                    Toggle("Scan iMovie/FCP bundles", isOn: Binding(
                        get: { !model.settings.skipBundles },
                        set: { model.settings.skipBundles = !$0; model.settings.save() }
                    ))
                    Spacer()
                }

                // Recognition engine selector
                Divider()
                HStack(spacing: 24) {
                    LabeledControl("Recognition Engine") {
                        Picker("", selection: model.settingsBinding.recognitionEngine) {
                            ForEach(RecognitionEngine.allCases) { eng in
                                Text(eng.rawValue).tag(eng)
                            }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 280)
                    }

                    if model.settings.recognitionEngine == .dlib {
                        LabeledControl("Python") {
                            TextField("venv/bin/python…", text: model.settingsBinding.pythonPath)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 260)
                            Button("…") { browsePython() }.controlSize(.small)
                        }
                        LabeledControl("Script") {
                            TextField("face_recognize.py…", text: model.settingsBinding.recognitionScript)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 260)
                            Button("…") { browseScript() }.controlSize(.small)
                        }
                        if !model.settings.dlibReady {
                            Label("Set Python and Script paths to enable dlib scanning",
                                  systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.orange)
                                .font(.caption)
                        } else {
                            Label("dlib ready", systemImage: "checkmark.circle")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                        Text("Heavy scans are auto-limited based on free RAM to avoid runaway memory use.")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                    Spacer()
                }
            }
            .font(.body)
            .padding(.horizontal, 16)
            .padding(.bottom, 10)
        } label: {
            Label("Face Detection Settings", systemImage: "slider.horizontal.3")
                .font(.body.weight(.medium))
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Jobs section

    var jobsSection: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.connected.to.line.below")
                    .font(.title3).foregroundColor(.secondary)
                Text("Scan Targets")
                    .font(.title3.weight(.semibold))
                Spacer()

                Button(action: {
                    model.addJob()
                    selectedJobID = model.jobs.last?.id
                }) {
                    Label("Add Folder / Volume", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: {
                    model.startAll()
                    if selectedJobID == nil { selectedJobID = model.jobs.first?.id }
                }) {
                    Label("Start All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.jobs.isEmpty || model.referenceFaces.isEmpty)

                Button(action: {
                    if model.hasPausedJobs { model.resumeAll() }
                    else { model.pauseAll() }
                }) {
                    Label(model.hasPausedJobs ? "Resume All" : "Pause All",
                          systemImage: model.hasPausedJobs ? "play.fill" : "pause.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.hasActiveJobs && !model.hasPausedJobs)

                Button(action: { model.stopAll() }) {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.jobs.contains { $0.status.isActive })

                Divider().frame(height: 20)

                Button {
                    PreviewWindowController.shared.show(jobs: model.jobs)
                } label: {
                    Label("Face Detection", systemImage: "eye.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(model.jobs.isEmpty)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            if model.jobs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "externaldrive.badge.plus")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text("No scan targets yet")
                        .font(.headline).foregroundColor(.secondary)
                    Text("Click \"Add Folder / Volume\" to add a drive or folder to search.")
                        .font(.callout).foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.jobs) { job in
                            ScanJobRow(
                                job: job,
                                isSelected: selectedJobID == job.id,
                                threshold: model.settings.threshold,
                                onStart: { selectedJobID = job.id; model.startJob(job) },
                                onStop: { model.stopJob(job) },
                                onPause: { model.togglePauseJob(job) },
                                onReset: { job.reset() },
                                onRemove: { model.removeJob(job) },
                                onPreview: { PreviewWindowController.shared.show(jobs: [job]) }
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { selectedJobID = job.id }
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                }
                .frame(minHeight: 90, maxHeight: 260)
            }
        }
        .background(Color(NSColor.controlBackgroundColor))
    }

    // MARK: Results table

    var resultsTable: some View {
        let results = selectedJob?.results ?? model.jobs.flatMap { $0.results }
        return Group {
            if results.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: selectedJob == nil ? "play.circle" : "person.slash")
                        .font(.largeTitle).foregroundColor(.secondary)
                    Text(selectedJob == nil
                         ? "Run a scan to find matching videos"
                         : "No videos with matching face found yet")
                        .font(.headline).foregroundColor(.secondary)
                    if selectedJob == nil {
                        Text("Click a job row above to see its results, or Start All to begin.")
                            .font(.callout).foregroundColor(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(results) {
                    TableColumn("Video File") { r in
                        Text(r.videoFilename)
                            .font(.system(.body, design: .monospaced))
                            .lineLimit(1)
                    }
                    .width(min: 200, ideal: 300)

                    TableColumn("Duration") { r in
                        Text(pfFormatDuration(r.videoDuration))
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Presence") { r in
                        Text(pfFormatDuration(r.presenceSecs))
                            .font(.system(.body, design: .monospaced).weight(.medium))
                            .foregroundColor(.green)
                    }
                    .width(min: 70, ideal: 80)

                    TableColumn("Clips") { r in
                        Text("\(r.segmentCount)")
                            .font(.body)
                    }
                    .width(min: 50, ideal: 60)

                    TableColumn("Best Match") { r in
                        Text(String(format: "%.3f", r.bestDistance))
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(r.bestDistance < 0.5 ? .green : r.bestDistance < 0.65 ? .yellow : .orange)
                    }
                    .width(min: 80, ideal: 90)

                    TableColumn("Actions") { r in
                        Button("Show in Finder") {
                            revealClips(for: r)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    .width(min: 110, ideal: 120)
                }
                .frame(minHeight: 160)
            }
        }
    }

    // MARK: Console pane

    var consolePane: some View {
        let lines = selectedJob?.consoleLines ?? []
        return VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal")
                    .foregroundColor(.secondary)
                Text(selectedJob.map { "Output — \($0.searchPath)" } ?? "Console Output")
                    .font(.callout.weight(.medium))
                    .foregroundColor(.secondary)
                Spacer()
                if let job = selectedJob, job.status.isActive {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    Text(lines.isEmpty
                         ? "Select a job above to see its scan output here…"
                         : lines.joined(separator: "\n"))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(lines.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .id("consoleBottom")
                }
                .background(Color(NSColor.textBackgroundColor))
                .frame(minHeight: 130)
                .onChange(of: lines.count) {
                    withAnimation { proxy.scrollTo("consoleBottom", anchor: .bottom) }
                }
            }
        }
    }

    // MARK: Helpers

    func browseForReference() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder of reference photos, or a single photo of the person"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.referencePath = url.path
            model.settings.save()
            Task { await model.loadReference() }
        }
    }

    func importFromApplePhotos(_ items: [PhotosPickerItem]) async {
        isImportingFromPhotos = true
        defer { isImportingFromPhotos = false }

        let name = pfSanitize(model.settings.personName.isEmpty ? "reference" : model.settings.personName)
        let destDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PersonFinderRef_\(name)")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        var saved = 0
        for (i, item) in items.enumerated() {
            // Try HEIC/JPG/PNG data transfer
            if let data = try? await item.loadTransferable(type: Data.self) {
                let ext = (item.supportedContentTypes.first?.preferredFilenameExtension) ?? "jpg"
                let dest = destDir.appendingPathComponent("ref_\(i).\(ext)")
                try? data.write(to: dest)
                saved += 1
            }
        }

        if saved > 0 {
            await model.loadReference(from: destDir.path)
        }
        photosPickerItems = []
    }

    func browseForOutput() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose folder where clips and compiled video will be saved"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.outputDir = url.path
            model.settings.save()
        }
    }

    func browsePython() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the Python executable (e.g. venv/bin/python)"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.pythonPath = url.path
            model.settings.save()
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
        if panel.runModal() == .OK, let url = panel.url {
            model.settings.recognitionScript = url.path
            model.settings.save()
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
    }
}

// MARK: - Scan Job Row

struct ScanJobRow: View {
    @ObservedObject var job: ScanJob
    let isSelected: Bool
    let threshold: Float
    let onStart: () -> Void
    let onStop: () -> Void
    let onPause: () -> Void
    let onReset: () -> Void
    let onRemove: () -> Void
    var onPreview: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                // Status dot
                Circle()
                    .fill(statusColor)
                    .frame(width: 12, height: 12)
                    .shadow(color: statusColor.opacity(0.5), radius: 3)

                // Path (editable when idle)
                if job.status.isIdle {
                    HStack(spacing: 8) {
                        TextField("Volume or folder path…", text: $job.searchPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                        Button("Browse…") { browsePath() }
                            .controlSize(.regular)
                    }
                } else {
                    Text(job.searchPath)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Spacer()

                // Stats badges
                if job.videosTotal > 0 {
                    Label("\(job.videosWithHits) matches", systemImage: "person.fill.checkmark")
                        .font(.callout.weight(.medium))
                        .foregroundColor(.green)
                    Text("\(job.videosScanned) / \(job.videosTotal) videos")
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                if job.elapsedSecs > 0 {
                    Text(formatElapsed(job.elapsedSecs))
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.secondary)
                }

                // Action buttons
                if job.status.isActive {
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
                        Button {
                            onPreview()
                        } label: {
                            Label("Preview", systemImage: "eye.fill")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                } else {
                    Button(action: onStart) {
                        Label("Start", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                    .disabled(job.searchPath.isEmpty)

                    if !job.status.isIdle {
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

            // Progress: ring chart when videos are known, spinner when discovering
            if job.videosTotal > 0 {
                ScanRingChart(
                    total: job.videosTotal,
                    scanned: job.videosScanned,
                    hits: job.videosWithHits,
                    elapsedSecs: job.elapsedSecs,
                    currentFile: job.status.isActive ? job.currentFile : "",
                    bestDist: job.bestDist,
                    threshold: threshold
                )
            } else if job.status.isActive {
                HStack(spacing: 8) {
                    ProgressView().progressViewStyle(.circular).scaleEffect(0.7)
                    Text(job.status.label).font(.caption).foregroundColor(.secondary)
                }
            }

            // Inline live frame preview — auto-shows during scanning
            if job.status.isActive, let frame = job.liveFrame {
                LiveFramePreview(
                    frame: frame,
                    matchedRects: job.liveMatchedRects,
                    unmatchedRects: job.liveUnmatchedRects
                )
                .frame(height: 135)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .transition(.opacity)
                .animation(.easeInOut(duration: 0.3), value: job.liveFrame != nil)
            }

            // Compiled video path if present
            if let compiled = job.compiledVideoPath {
                HStack(spacing: 6) {
                    Image(systemName: "film.stack")
                        .foregroundColor(.accentColor)
                    Text((compiled as NSString).lastPathComponent)
                        .font(.system(.callout, design: .monospaced))
                        .foregroundColor(.accentColor)
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(compiled, inFileViewerRootedAtPath: "")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
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
        if panel.runModal() == .OK, let url = panel.url {
            job.searchPath = url.path
        }
    }

    func formatElapsed(_ secs: Double) -> String {
        let t = Int(secs); let h = t/3600; let m = (t%3600)/60; let s = t%60
        return h > 0 ? "\(h)h \(m)m \(s)s" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
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
    let jobs: [ScanJob]
    @State private var selectedJobID: UUID?

    /// Auto-select the first actively scanning job
    private var activeJob: ScanJob? {
        if let sel = selectedJobID, let j = jobs.first(where: { $0.id == sel }) { return j }
        return jobs.first(where: { $0.status == .scanning })
            ?? jobs.first(where: { $0.status.isActive })
    }

    var body: some View {
        VStack(spacing: 0) {
            // Video frame area
            ZStack {
                Color.black

                if let job = activeJob, let frame = job.liveFrame {
                    LiveFramePreview(
                        frame: frame,
                        matchedRects: job.liveMatchedRects,
                        unmatchedRects: job.liveUnmatchedRects
                    )
                    // Floating HUD overlay — top left
                    .overlay(alignment: .topLeading) {
                        FaceDetectHUD(job: job)
                            .padding(10)
                    }
                    // Legend — top right
                    .overlay(alignment: .topTrailing) {
                        FaceDetectLegend()
                            .padding(10)
                    }
                } else {
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
            }
            .aspectRatio(16/9, contentMode: .fit)

            // Display Rate toolbar — fixed position above status bar
            if let job = activeJob, job.status == .scanning {
                HStack(spacing: 8) {
                    Text("Display Rate")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(job.previewRate) },
                        set: { job.previewRate = max(1, Int($0)) }
                    ), in: 1...10, step: 1)
                        .frame(width: 120)
                    Text("\(job.previewRate)")
                        .font(.system(.caption, design: .monospaced))
                        .frame(width: 16)
                    Text(job.previewRate == 1 ? "every frame" : "every \(job.previewRate) frames")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(NSColor.controlBackgroundColor))
            }

            // Bottom status bar
            HStack(spacing: 10) {
                // Job picker (when multiple jobs exist)
                if jobs.count > 1 {
                    Picker("Job", selection: Binding(
                        get: { activeJob?.id ?? UUID() },
                        set: { selectedJobID = $0 }
                    )) {
                        ForEach(jobs) { job in
                            Text((job.searchPath as NSString).lastPathComponent)
                                .tag(job.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 180)
                }

                if let job = activeJob {
                    Circle()
                        .fill(job.status == .scanning ? Color.green : Color.secondary)
                        .frame(width: 8, height: 8)
                    Text(job.status.label)
                        .font(.caption).foregroundStyle(.secondary)

                    if !job.currentFile.isEmpty {
                        Text(job.currentFile)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                Spacer()
                if let job = activeJob, job.videosTotal > 0 {
                    Text("\(job.videosScanned)/\(job.videosTotal) videos")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(job.videosWithHits) match(es)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(job.videosWithHits > 0 ? .green : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(minWidth: 640, minHeight: 400)
    }
}

/// Floating HUD showing live detection stats
private struct FaceDetectHUD: View {
    @ObservedObject var job: ScanJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 6))
                    .foregroundColor(.red)
                Text("LIVE")
                    .font(.system(.caption2, design: .monospaced).weight(.bold))
                    .foregroundColor(.red)
            }
            if job.videosTotal > 0 {
                Text("Video \(job.videosScanned)/\(job.videosTotal)")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
            }
            Text("Hits: \(job.videosWithHits)")
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(job.videosWithHits > 0 ? .green : .white)
            if job.bestDist < .greatestFiniteMagnitude {
                Text(String(format: "Best: %.3f", job.bestDist))
                    .font(.system(.caption, design: .monospaced))
                    .foregroundColor(.white)
            }
            Text(pfFormatDuration(job.elapsedSecs))
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.white.opacity(0.7))
        }
        .padding(8)
        .background(.black.opacity(0.6))
        .cornerRadius(6)
    }
}

/// Color legend for bounding box colors
private struct FaceDetectLegend: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(.green)
                    .frame(width: 10, height: 10)
                Text("Match").font(.caption2).foregroundColor(.white)
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(.yellow)
                    .frame(width: 10, height: 10)
                Text("Face (no match)").font(.caption2).foregroundColor(.white)
            }
        }
        .padding(6)
        .background(.black.opacity(0.5))
        .cornerRadius(4)
    }
}

@MainActor
class PreviewWindowController {
    static let shared = PreviewWindowController()
    private var window: NSWindow?

    func show(jobs: [ScanJob]) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        close()

        let content = RealtimeFaceDetectionContent(jobs: jobs)
        let hosting = NSHostingView(rootView: content)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 500),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Realtime Face Detection"
        w.contentView = hosting
        w.setFrameAutosaveName("RealtimeFaceDetect")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
    }

    /// Legacy single-job entry point
    func show(job: ScanJob) {
        show(jobs: [job])
    }

    func close() {
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
