// PersonEditSheet.swift
// Edit/create a person-of-interest profile — name, aliases, reference photos,
// cover crop, notes.

import SwiftUI
import PhotosUI

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
