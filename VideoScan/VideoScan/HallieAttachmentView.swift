// HallieAttachmentView.swift
// Mac chat rendering of HallieAttachment cards (2026-08-22). Big type for
// the family; every card is a plain list the eye can follow. No O(records)
// work — cards are tiny value types built off-main by the executor.

import AppKit
import PhotosUI
import SwiftUI

struct HallieAttachmentsView: View {
    let attachments: [HallieAttachment]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(attachments.enumerated()), id: \.offset) { _, a in
                switch a {
                case .photo(let p): HallieImageCard(url: p.fileURL, caption: p.caption ?? p.personName, maxHeight: 260)
                case .crest(let surname, let url): HallieImageCard(url: url, caption: "Saved \(surname) crest reference", maxHeight: 160)
                case .lineage(let card): HallieLineageCardView(card: card)
                case .tree(let card): HallieTreeCardView(card: card)
                case .photoRequest(let name, let folder): HalliePhotoRequestView(name: name, folder: folder)
                }
            }
        }
        .padding(.top, 4)
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
