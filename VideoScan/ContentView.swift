import SwiftUI

// MARK: - Root (Tab switcher)

struct ContentView: View {
    var body: some View {
        TabView {
            CatalogView()
                .tabItem { Label("Video Catalog", systemImage: "film.stack") }
            PersonFinderView()
                .tabItem { Label("Person Finder", systemImage: "person.crop.rectangle.stack") }
        }
        .frame(minWidth: 900, minHeight: 600)
    }
}

// MARK: - Catalog Tab (original app)

struct CatalogView: View {
    @StateObject private var model = VideoScanModel()
    @State private var folderPath: String = ""
    @State private var selectedIDs: Set<UUID> = []
    @State private var showCombineSheet = false
    @State private var sortOrder = [KeyPathComparator(\VideoRecord.filename)]

    var body: some View {
        VStack(spacing: 0) {

            // MARK: Toolbar
            HStack(spacing: 10) {
                TextField("Volume or folder path...", text: $folderPath)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))

                Button("Browse…") { browseForFolder() }
                    .disabled(model.isScanning)

                Divider().frame(height: 22)

                Button(action: { model.startScan(root: folderPath) }) {
                    Label("Scan", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isScanning || folderPath.isEmpty)

                Button(action: { model.stopScan() }) {
                    Label("Stop", systemImage: "stop.fill")
                }
                .buttonStyle(.bordered)
                .disabled(!model.isScanning)

                Divider().frame(height: 22)

                Button(action: runCorrelate) {
                    Label("Correlate", systemImage: "arrow.triangle.2.circlepath")
                }
                .buttonStyle(.bordered)
                .disabled(model.isScanning || model.records.isEmpty)

                Button(action: { showCombineSheet = true }) {
                    Label("Combine", systemImage: "rectangle.stack.badge.plus")
                }
                .buttonStyle(.bordered)
                .disabled(!canCombine)

                if !model.outputCSVPath.isEmpty {
                    Button(action: revealCSV) {
                        Label("Show CSV", systemImage: "doc.text")
                    }
                    .buttonStyle(.bordered)
                }

                Spacer()

                if model.isScanning || model.isCombining {
                    ProgressView().scaleEffect(0.7)
                }
            }
            .padding(10)
            .background(Color(NSColor.windowBackgroundColor))

            Divider()

            // MARK: Split — Table top, Console bottom
            VSplitView {

                // MARK: Results Table
                Table(model.records, selection: $selectedIDs, sortOrder: $sortOrder) {
                    TableColumn("Filename", value: \.filename) { rec in
                        Text(rec.filename)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                    }
                    .width(min: 200, ideal: 260)

                    TableColumn("Stream Type", value: \.streamTypeRaw) { rec in
                        Text(rec.streamTypeRaw)
                            .foregroundColor(streamTypeColor(rec.streamType))
                            .bold(rec.streamType.needsCorrelation)
                    }
                    .width(min: 100, ideal: 110)

                    TableColumn("Duration", value: \.duration)
                        .width(min: 70, ideal: 80)

                    TableColumn("Resolution", value: \.resolution)
                        .width(min: 90, ideal: 100)

                    TableColumn("Timecode", value: \.timecode)
                        .width(min: 100, ideal: 110)

                    TableColumn("Paired With") { rec in
                        Text(rec.pairedWith?.filename ?? "—")
                            .foregroundColor(rec.pairedWith != nil ? .green : .secondary)
                            .font(.system(.body, design: .monospaced))
                    }
                    .width(min: 200, ideal: 260)

                    TableColumn("Size", value: \.size)
                        .width(min: 70, ideal: 80)

                    TableColumn("Video Codec", value: \.videoCodec)
                        .width(min: 80, ideal: 90)

                    TableColumn("Audio Codec", value: \.audioCodec)
                        .width(min: 80, ideal: 90)

                    TableColumn("Directory", value: \.directory) { rec in
                        Text(rec.directory)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .width(min: 200, ideal: 300)
                }
                .onChange(of: sortOrder) {
                    model.records.sort(using: sortOrder)
                }
                .frame(minHeight: 300)

                // MARK: Console
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.consoleOutput.isEmpty ? "Output will appear here..." : model.consoleOutput)
                            .font(.system(.body, design: .monospaced))
                            .foregroundColor(model.consoleOutput.isEmpty ? .secondary : .primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                            .id("bottom")
                    }
                    .background(Color(NSColor.textBackgroundColor))
                    .frame(minHeight: 150)
                    .onChange(of: model.consoleOutput) {
                        withAnimation { proxy.scrollTo("bottom", anchor: .bottom) }
                    }
                }
            }
        }
        .sheet(isPresented: $showCombineSheet) {
            CombineSheet(model: model, selectedIDs: selectedIDs)
        }
    }

    // MARK: - Helpers

    var canCombine: Bool {
        guard !model.isScanning && !model.isCombining else { return false }
        let selected = model.records.filter { selectedIDs.contains($0.id) }
        let hasVideo = selected.contains { $0.streamType == .videoOnly }
        let hasAudio = selected.contains { $0.streamType == .audioOnly }
        return hasVideo && hasAudio
    }

    func streamTypeColor(_ st: StreamType) -> Color {
        switch st {
        case .videoOnly:     return .orange
        case .audioOnly:     return .yellow
        case .ffprobeFailed: return .red
        default:             return .primary
        }
    }

    func runCorrelate() {
        model.log("\nCorrelating audio-only and video-only files...")
        model.correlate()
    }

    func browseForFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select the volume or folder to catalogue"
        panel.prompt = "Select"
        if panel.runModal() == .OK, let url = panel.url {
            folderPath = url.path
        }
    }

    func revealCSV() {
        NSWorkspace.shared.selectFile(model.outputCSVPath, inFileViewerRootedAtPath: "")
    }
}

// MARK: - Combine Sheet

struct CombineSheet: View {
    @ObservedObject var model: VideoScanModel
    let selectedIDs: Set<UUID>
    @Environment(\.dismiss) var dismiss

    @State private var container: String = "mov"
    @State private var outputURL: URL? = nil

    let containers = ["mov", "mp4", "mxf", "mkv"]

    var selectedRecords: [VideoRecord] {
        model.records.filter { selectedIDs.contains($0.id) }
    }

    var videoRecord: VideoRecord? {
        selectedRecords.first { $0.streamType == .videoOnly }
    }

    var audioRecord: VideoRecord? {
        selectedRecords.first { $0.streamType == .audioOnly }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Combine Audio + Video")
                .font(.headline)

            GroupBox("Selected Files") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "film")
                        Text("Video: ").bold()
                        Text(videoRecord?.filename ?? "None selected")
                            .font(.system(.body, design: .monospaced))
                    }
                    HStack {
                        Image(systemName: "waveform")
                        Text("Audio: ").bold()
                        Text(audioRecord?.filename ?? "None selected")
                            .font(.system(.body, design: .monospaced))
                    }
                }
                .padding(6)
            }

            HStack {
                Text("Output container:")
                Picker("", selection: $container) {
                    ForEach(containers, id: \.self) { c in
                        Text(".\(c)").tag(c)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 100)
            }

            HStack {
                Text("Output file:")
                Text(outputURL?.lastPathComponent ?? "Not chosen")
                    .foregroundColor(.secondary)
                    .font(.system(.body, design: .monospaced))
                Spacer()
                Button("Choose…") { chooseSaveLocation() }
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)

                Button("Combine") {
                    guard let v = videoRecord, let a = audioRecord, let out = outputURL else { return }
                    model.combine(video: v, audio: a, outputURL: out, container: container)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(videoRecord == nil || audioRecord == nil || outputURL == nil)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            // Pre-fill output filename based on video file
            if let v = videoRecord {
                let base = URL(fileURLWithPath: v.fullPath)
                    .deletingPathExtension()
                    .lastPathComponent
                outputURL = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Desktop")
                    .appendingPathComponent("\(base)_combined.\(container)")
            }
        }
        .onChange(of: container) {
            // Update extension when container changes
            if let current = outputURL {
                outputURL = current.deletingPathExtension().appendingPathExtension(container)
            }
        }
    }

    func chooseSaveLocation() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = outputURL?.lastPathComponent ?? "combined.\(container)"
        panel.message = "Choose where to save the combined file"
        if panel.runModal() == .OK, let url = panel.url {
            outputURL = url
        }
    }
}
