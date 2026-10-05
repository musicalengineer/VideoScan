//
//  FamilyEditSheet.swift
//  VideoScan
//
//  Edit a family group (Rick 2026-10-04): its name and its card photo, with
//  the same two photo sources as a person — "Browse Photos…" (Finder) and
//  "Apple Photos" (PhotosPicker). Opened by double-clicking a family card or
//  right-click ▸ Edit Family…. The photo is stored as a downsized copy
//  beside the family (FamilyGroupStore.setPhoto); originals are never
//  touched.
//

import AppKit
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct FamilyEditSheet: View {
    let familyUUID: UUID
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var photo: NSImage?
    @State private var pickerItem: PhotosPickerItem?
    @State private var isImporting = false
    @State private var problem: String?
    @State private var cropScale: Double = 1.0
    @State private var cropOffset: CGSize = .zero
    @State private var showCrop = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Family").font(.title2.weight(.semibold))

            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    Circle().fill(Color.accentColor.opacity(0.14))
                    if let photo {
                        CroppedCircleImage(image: photo, scale: cropScale, offset: cropOffset)
                    } else {
                        Image(systemName: "person.3.fill").font(.system(size: 40)).foregroundStyle(.tint)
                    }
                }
                .frame(width: 120, height: 120)

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Family name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 15))
                    HStack(spacing: 10) {
                        Button("Browse Photos\u{2026}") { browse() }
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Label(isImporting ? "Importing\u{2026}" : "Apple Photos",
                                  systemImage: "photo.on.rectangle.angled")
                        }
                        .disabled(isImporting)
                        if isImporting { ProgressView().controlSize(.small) }
                    }
                    if photo != nil {
                        // The same pan/zoom editor a person's cover uses.
                        Button("Adjust Photo…") { showCrop = true }
                            .popover(isPresented: $showCrop, arrowEdge: .bottom) {
                                if let photo { CoverCropEditor(image: photo, scale: $cropScale, offset: $cropOffset) }
                            }
                    }
                    if let problem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
            }

            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear(perform: loadCurrent)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await importFromApplePhotos(item) }
        }
    }

    private func loadCurrent() {
        guard let family = FamilyGroupStore.load(familyUUID) else { return }
        name = family.name
        photo = FamilyGroupStore.photoURL(for: family).flatMap { PortraitThumbnailCache.thumbnail(at: $0, maxPixels: 512) }
        cropScale = family.cropScale
        cropOffset = CGSize(width: family.cropOffsetX, height: family.cropOffsetY)
    }

    private func browse() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.message = "Choose a photo for \(name)"
        panel.prompt = "Use Photo"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            usePhoto(at: url, label: url.lastPathComponent)
        }
    }

    /// Apple Photos hands back data, not a file: write it to a temp file and
    /// take the same path as Browse.
    private func importFromApplePhotos(_ item: PhotosPickerItem) async {
        isImporting = true
        defer { isImporting = false; pickerItem = nil }
        guard let data = try? await item.loadTransferable(type: Data.self) else {
            problem = "Couldn't read that photo from Apple Photos."
            return
        }
        let ext = item.supportedContentTypes.first?.preferredFilenameExtension ?? "jpg"
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("family-photo-\(UUID().uuidString).\(ext)")
        do {
            try data.write(to: tmp)
            usePhoto(at: tmp, label: "Apple Photos")
            try? FileManager.default.removeItem(at: tmp)   // our own temp copy only
        } catch {
            problem = "Couldn't import that photo: \(error.localizedDescription)"
        }
    }

    private func usePhoto(at url: URL, label: String) {
        do {
            let updated = try FamilyGroupStore.setPhoto(from: url, for: familyUUID)
            photo = FamilyGroupStore.photoURL(for: updated).flatMap { PortraitThumbnailCache.thumbnail(at: $0, maxPixels: 512) }
            cropScale = 1.0; cropOffset = .zero
            problem = nil
            appLog.write("People: set photo for \(updated.name) from \(label)")
        } catch {
            problem = "Couldn't use that photo: \(error.localizedDescription)"
        }
    }

    private func save() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var family = FamilyGroupStore.load(familyUUID), !trimmed.isEmpty else { dismiss(); return }
        let old = family.name
        let cropChanged = family.cropScale != cropScale || family.cropOffsetX != cropOffset.width
            || family.cropOffsetY != cropOffset.height
        if family.name != trimmed || cropChanged {
            family.name = trimmed
            family.cropScale = cropScale
            family.cropOffsetX = cropOffset.width
            family.cropOffsetY = cropOffset.height
            do {
                try FamilyGroupStore.save(family)
                if old != trimmed { appLog.write("People: renamed family \(old) → \(trimmed)") }
                if cropChanged { appLog.write("People: adjusted \(trimmed)'s photo crop") }
            } catch {
                problem = "Couldn't save: \(error.localizedDescription)"
                return
            }
        }
        onDone()
        dismiss()
    }
}
