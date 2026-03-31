// PersonFinderView.swift
// Multi-volume person-finding UI — jobs list, progress bars, results, console.

import SwiftUI
import AppKit
import PhotosUI

// MARK: - Main View

struct PersonFinderView: View {
    @State private var model = PersonFinderModel()
    @State private var selectedJobID: UUID? = nil
    @State private var showSettings = false
    @State private var photosPickerItems: [PhotosPickerItem] = []
    @State private var isImportingFromPhotos = false

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

                TextField("Folder of reference photos…", text: $model.settings.referencePath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

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

                if !model.referenceFeaturePrints.isEmpty {
                    Button("Clear All", role: .destructive) { model.clearReference() }
                        .controlSize(.large)
                }

                Divider().frame(height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Person Name").font(.headline)
                    Text("Used for filenames")
                        .font(.caption).foregroundColor(.secondary)
                }
                TextField("e.g. Donna", text: $model.settings.personName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 110)
            }

            // Source chips + status
            if !model.referenceFeaturePrints.isEmpty || model.referenceLoadError != nil {
                HStack(spacing: 8) {
                    if !model.referenceFeaturePrints.isEmpty {
                        Label("\(model.referencePhotoCount) reference faces loaded",
                              systemImage: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.callout.weight(.medium))
                        Text("—")
                            .foregroundColor(.secondary)
                        ForEach(model.referenceSources, id: \.self) { src in
                            Text(src)
                                .font(.caption)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.12))
                                .cornerRadius(5)
                        }
                    }
                    if let err = model.referenceLoadError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                            .font(.callout)
                    }
                    Spacer()
                }
                .padding(.horizontal, 4)
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
                text: $model.settings.outputDir
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
                        Slider(value: $model.settings.threshold, in: 0.3...0.9, step: 0.05)
                            .frame(width: 130)
                        Text(String(format: "%.2f", model.settings.threshold))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 38)
                    }
                    LabeledControl("Min Face Confidence") {
                        Slider(value: $model.settings.minFaceConfidence.asDouble, in: 0.3...1.0, step: 0.05)
                            .frame(width: 110)
                        Text(String(format: "%.2f", model.settings.minFaceConfidence))
                            .font(.system(.body, design: .monospaced))
                            .frame(width: 38)
                    }
                    LabeledControl("Min Presence") {
                        TextField("", value: $model.settings.minPresenceSecs, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 64)
                        Text("sec")
                    }
                    LabeledControl("Frame Step") {
                        TextField("", value: $model.settings.frameStep, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 54)
                        Text("frames")
                    }
                    LabeledControl("Concurrency") {
                        TextField("", value: $model.settings.concurrency, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 54)
                        Text("threads")
                    }
                    Spacer()
                }
                HStack(spacing: 24) {
                    Toggle("Primary face only", isOn: $model.settings.requirePrimary)
                    Toggle("Compile to one video", isOn: $model.settings.concatOutput)
                        .disabled(model.settings.decadeChapters)
                    Toggle("Decade chapter video", isOn: $model.settings.decadeChapters)
                    Toggle("Scan iMovie/FCP bundles", isOn: Binding(
                        get: { !model.settings.skipBundles },
                        set: { model.settings.skipBundles = !$0 }
                    ))
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

                Button(action: { model.addJob() }) {
                    Label("Add Folder / Volume", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)

                Button(action: { model.startAll() }) {
                    Label("Start All", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(model.jobs.isEmpty || model.referenceFeaturePrints.isEmpty)

                Button(action: { model.stopAll() }) {
                    Label("Stop All", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .disabled(!model.jobs.contains { $0.status.isActive })
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
                                onStart: { model.startJob(job) },
                                onStop: { model.stopJob(job) },
                                onReset: { job.reset() },
                                onRemove: { model.removeJob(job) }
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

// MARK: - Scan Job Row

struct ScanJobRow: View {
    @Bindable var job: ScanJob
    let isSelected: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onReset: () -> Void
    let onRemove: () -> Void

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
                    Button(action: onStop) {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
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

            // Progress bar
            if job.videosTotal > 0 {
                HStack(spacing: 8) {
                    ProgressView(value: job.progress)
                        .progressViewStyle(.linear)
                    if job.status.isActive, !job.currentFile.isEmpty {
                        Text(job.currentFile)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text(job.status.label)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            } else if job.status.isActive {
                HStack(spacing: 8) {
                    ProgressView()
                        .progressViewStyle(.linear)
                        .scaleEffect(x: 1, y: 0.8)
                    Text(job.status.label)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
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

// MARK: - Binding helpers

extension Binding where Value == Float {
    var asDouble: Binding<Double> {
        Binding<Double>(
            get: { Double(wrappedValue) },
            set: { wrappedValue = Float($0) }
        )
    }
}
