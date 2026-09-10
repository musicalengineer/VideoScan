// HallieAttachmentView.swift
// Mac chat rendering of HallieAttachment cards (2026-08-22). Big type for
// the family; every card is a plain list the eye can follow. No O(records)
// work — cards are tiny value types built off-main by the executor.

import AppKit
import PhotosUI
import SwiftUI

struct HallieAttachmentsView: View {
    let attachments: [HallieAttachment]

    /// A gallery answer ("show all photos of X", 2026-09-10) carries many
    /// photos; three or more render as a grid of thumbnails instead of a
    /// column of 260 pt cards. Everything else keeps the column.
    static let gridThreshold = 3

    private var photos: [HalliePhotoAttachment] {
        attachments.compactMap { if case .photo(let p) = $0 { return p } else { return nil } }
    }

    var body: some View {
        let photos = self.photos
        let asGrid = photos.count >= Self.gridThreshold
        VStack(alignment: .leading, spacing: 10) {
            if asGrid { HalliePhotoGrid(photos: photos) }
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, a in
                switch a {
                case .photo(let p):
                    if !asGrid {
                        HallieImageCard(url: p.fileURL, caption: p.caption ?? p.personName, maxHeight: 260)
                    }
                case .crest(let surname, let url): HallieImageCard(url: url, caption: "Saved \(surname) crest reference", maxHeight: 160)
                case .lineage(let card): HallieLineageCardView(card: card)
                case .tree(let card): HallieTreeCardView(card: card)
                case .photoRequest(let name, let folder): HalliePhotoRequestView(name: name, folder: folder)
                case .document(let d): HallieDocumentCard(document: d)
                }
            }
        }
        .padding(.top, 4)
    }
}

/// Adaptive grid of ~160 pt thumbnails with captions, at most 520 pt wide
/// (the card width). Each cell decodes a bounded 320 px thumbnail off-main
/// — 24 cells (the gallery cap) ≈ 24 × 320² × 4 B ≈ 10 MB worst case.
struct HalliePhotoGrid: View {
    let photos: [HalliePhotoAttachment]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 170), spacing: 10)],
                  alignment: .leading, spacing: 12) {
            ForEach(Array(photos.enumerated()), id: \.offset) { _, p in
                HalliePhotoGridCell(url: p.fileURL, caption: p.caption ?? p.personName)
            }
        }
        .modifier(CardChrome())
    }
}

private struct HalliePhotoGridCell: View {
    let url: URL
    let caption: String
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Color.secondary.opacity(0.08)
                        .overlay { ProgressView().controlSize(.small) }
                }
            }
            .frame(width: 160, height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
            .onTapGesture { HallieAttachmentOpener.open(url) }
            .onHover { HallieAttachmentOpener.hover($0) }
            Text(caption).font(.system(size: 12)).foregroundStyle(.secondary)
                .lineLimit(2).frame(width: 160, alignment: .leading)
        }
        .accessibilityLabel(caption)
        .task(id: url) {
            guard image == nil else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                FamilyAssetImageValidator.thumbnail(url, maxPixelSize: 320)
            }.value
            if !Task.isCancelled, let decoded {
                image = NSImage(cgImage: decoded, size: .zero)
            }
        }
    }
}

/// Click-to-open for photo cards and grid cells (2026-09-10): the file is
/// re-verified as a regular image at the moment of the click, then handed
/// to the default app — never a path from a model, always a URL the
/// executor attached.
enum HallieAttachmentOpener {
    @MainActor static func open(_ url: URL) {
        guard let verified = FamilyAssetImageValidator.revalidatedURL(url) else { return }
        NSWorkspace.shared.open(verified)
    }

    /// A document is not an image: regular, non-symlink, allow-listed
    /// extension is the whole check — the bytes are the viewer app's.
    @MainActor static func openDocument(_ url: URL) {
        guard let verified = revalidatedDocumentURL(url) else { return }
        NSWorkspace.shared.open(verified)
    }

    @MainActor static func reveal(_ url: URL) {
        let fresh = URL(fileURLWithPath: url.path)
        guard let values = try? fresh.resourceValues(forKeys: [.isSymbolicLinkKey]),
              values.isSymbolicLink != true else { return }
        NSWorkspace.shared.activateFileViewerSelecting([fresh])
    }

    static func revalidatedDocumentURL(_ url: URL) -> URL? {
        let fresh = URL(fileURLWithPath: url.path, isDirectory: false)
        guard FamilyAssetStore.allowedDocumentExtensions.contains(fresh.pathExtension.lowercased()),
              let values = try? fresh.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else { return nil }
        return fresh
    }

    @MainActor static func hover(_ inside: Bool) {
        if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() }
    }
}

/// A paper in the person's folder: icon by extension, the title, Open and
/// Reveal in Finder. The file is never read here.
struct HallieDocumentCard: View {
    let document: HallieDocumentAttachment

    private var symbol: String {
        switch document.kind {
        case "pdf": return "doc.richtext"
        case "doc", "docx": return "doc.text"
        case "rtf": return "doc.append"
        case "md", "txt": return "doc.plaintext"
        default: return "doc"
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 18)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text(document.title).font(.system(size: 15, weight: .medium))
                Text("\(document.kind.uppercased()) · \(document.personName)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Open") { HallieAttachmentOpener.openDocument(document.fileURL) }
                .controlSize(.small)
            Button("Reveal in Finder") { HallieAttachmentOpener.reveal(document.fileURL) }
                .controlSize(.small)
        }
        .modifier(CardChrome())
        .accessibilityLabel("Document: \(document.title)")
    }
}

private struct CardChrome: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(12)
            .frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.08)))
    }
}

struct HallieImageCard: View {
    let url: URL
    let caption: String
    let maxHeight: CGFloat
    @State private var image: NSImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let image {
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 9))
                    // Click opens the original in its default app
                    // (2026-09-10); the hand cursor says it is clickable.
                    .contentShape(Rectangle())
                    .onTapGesture { HallieAttachmentOpener.open(url) }
                    .onHover { HallieAttachmentOpener.hover($0) }
            } else {
                Color.secondary.opacity(0.08).frame(height: 120)
                    .overlay { ProgressView().controlSize(.small) }
            }
            Text(caption).font(.system(size: 14)).foregroundStyle(.secondary)
        }
        .modifier(CardChrome())
        .accessibilityLabel(caption)
        .task(id: url) {
            guard image == nil else { return }
            let decoded = await Task.detached(priority: .userInitiated) {
                FamilyAssetImageValidator.thumbnail(url, maxPixelSize: 1200)
            }.value
            if !Task.isCancelled, let decoded {
                image = NSImage(cgImage: decoded, size: .zero)
            }
        }
    }
}

struct HallieLineageCardView: View {
    let card: HallieLineageCard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(card.title).font(.system(size: 17, weight: .semibold))
            personRow(card.root, emphasized: true)
            ForEach(card.generations) { gen in
                VStack(alignment: .leading, spacing: 3) {
                    Text(gen.label.uppercased())
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        .padding(.top, 4)
                    ForEach(gen.people) { personRow($0, emphasized: false) }
                }
            }
            if !card.reachedAll {
                Text("The tree stops here.").font(.system(size: 13)).foregroundStyle(.secondary)
            }
        }
        .modifier(CardChrome())
        .accessibilityElement(children: .combine)
    }

    private func personRow(_ p: HalliePersonCard, emphasized: Bool) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            if let url = p.photoURL {
                HalliePersonThumbnail(url: url)
            } else {
                Image(systemName: "person.fill").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(p.name).font(.system(size: 15, weight: emphasized ? .semibold : .regular))
            if let y = p.years { Text(y).font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary) }
            if let b = p.birthPlace { Text("· \(b)").font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1) }
        }
    }
}

struct HallieTreeCardView: View {
    let card: HallieTreeCard

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(card.title).font(.system(size: 17, weight: .semibold))
            Text("\(card.peopleCount) people · \(card.depth + 1) generations")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            ForEach(card.roots) { node in
                HallieTreeNodeView(node: node, depth: 0)
            }
        }
        .modifier(CardChrome())
    }
}

private struct HallieTreeNodeView: View {
    let node: HallieTreeCard.Node
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if depth > 0 {
                    Text("└").foregroundStyle(.secondary).font(.system(size: 13))
                }
                if let url = node.person.photoURL { HalliePersonThumbnail(url: url) }
                Text(node.person.name).font(.system(size: 15, weight: depth == 0 ? .semibold : .regular))
                if let y = node.person.years { Text(y).font(.system(size: 14).monospacedDigit()).foregroundStyle(.secondary) }
                if !node.spouses.isEmpty {
                    Text("⚭ " + node.spouses.map(\.name).joined(separator: ", "))
                        .font(.system(size: 14)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            ForEach(node.children) { child in
                HallieTreeNodeView(node: child, depth: depth + 1).padding(.leading, 18)
            }
        }
    }
}

struct HalliePhotoRequestView: View {
    let name: String
    let folder: URL
    /// "Choose from Photos…" (Rick 2026-08-24: "I have a lot of nice
    /// photos there"). The pick is saved into the archive folder through
    /// the store, then Hallie shows it right away.
    @EnvironmentObject private var model: VideoScanModel
    @State private var pickedItem: PhotosPickerItem?
    @State private var status: String?
    /// The in-flight import. Tracked so a second pick or a vanished card
    /// cancels it instead of letting an orphan write into the archive and
    /// poke a dead view (codex #663).
    @State private var importTask: Task<Void, Never>?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "photo.badge.plus").font(.system(size: 16)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("Do you have a photo of \(name)?").font(.system(size: 15, weight: .medium))
                Text("Pick one from Photos, or put a file here and I’ll show it next time:")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
                Text(folder.path).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                if let status {
                    Text(status).font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: 6) {
                PhotosPicker(selection: $pickedItem, matching: .images) {
                    Text("Choose from Photos…")
                }
                .controlSize(.small)
                .accessibilityIdentifier("hallie.photoRequest.choosePhotos")
                Button("Reveal folder") {
                    let store = FamilyAssetConfigurationCenter.shared
                        .snapshot().makeStore()
                    guard let verified = store.revalidatedPhotoRequestFolder(folder) else {
                        return
                    }
                    NSWorkspace.shared.activateFileViewerSelecting([verified])
                }
                .controlSize(.small)
            }
        }
        .modifier(CardChrome())
        .onChange(of: pickedItem) { _, item in importPicked(item) }
        .onDisappear { importTask?.cancel() }
    }

    private func importPicked(_ item: PhotosPickerItem?) {
        guard let item else { return }
        importTask?.cancel()
        status = "Saving…"
        let folder = folder, name = name
        // All the work — Photos export, bounded read, archive write — runs
        // in HalliePhotoImport's detached worker; cancelling THIS task
        // cancels that worker (codex #675). Only the Sendable configuration
        // snapshot crosses over.
        let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
        importTask = Task { @MainActor in
            let outcome = await HalliePhotoImport.run(
                load: { try await item.loadTransferable(type: HalliePickedPhotoFile.self) },
                configuration: configuration,
                folder: folder)
            guard !Task.isCancelled else { return }
            switch outcome {
            case .success:
                status = "Saved to the archive."
                // Show it now instead of making the user ask again.
                model.archivistAskRequest = "show me a photo of \(name)"
            case .failure(let error):
                status = "Couldn’t save it: \(error.localizedDescription)"
            }
            pickedItem = nil
            importTask = nil
        }
    }
}

private struct HalliePersonThumbnail: View {
    let url: URL
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "person.fill").foregroundStyle(.secondary)
            }
        }
        .frame(width: 28, height: 28)
        .clipShape(Circle())
        .task(id: url) {
            let decoded = await Task.detached(priority: .utility) {
                FamilyAssetImageValidator.thumbnail(url, maxPixelSize: 96)
            }.value
            if !Task.isCancelled, let decoded {
                image = NSImage(cgImage: decoded, size: .zero)
            }
        }
    }
}
