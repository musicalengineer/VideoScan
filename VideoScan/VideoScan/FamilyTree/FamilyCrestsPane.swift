import SwiftUI
import UniformTypeIdentifiers

/// A compact Family Tree sidebar section for locally owned crest images.
/// The parent view supplies the store so previews/tests never touch real data.
struct FamilyCrestsPane: View {
    private struct Row: Identifiable {
        let crest: FamilyCrest
        let thumbnail: NSImage?
        var id: String { crest.id }
    }

    let store: FamilyAssetStore

    @State private var rows: [Row] = []
    @State private var surname = ""
    @State private var errorMessage: String?
    @State private var reloadGeneration = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Family Crests", systemImage: "shield.checkered")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            if rows.isEmpty {
                Text("No family crests added yet.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(rows) { row in
                    HStack(spacing: 8) {
                        if let image = row.thumbnail {
                            Image(nsImage: image)
                                .resizable()
                                .scaledToFit()
                                .frame(width: 30, height: 30)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        Text(row.crest.surname)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            reveal(row.crest.fileURL)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.plain)
                        .help("Reveal in Finder")
                    }
                    .font(.system(size: 12))
                }
            }

            TextField("Surname", text: $surname)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))

            HStack(spacing: 8) {
                Button("Add crest…") { chooseCrest() }
                    .disabled(surname.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Reveal in Finder") { revealCrestsFolder() }
            }
            .controlSize(.small)

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: reload)
    }

    private func chooseCrest() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.image]
        panel.prompt = "Add Crest"
        panel.message = "Choose the crest image for the \(surname.trimmingCharacters(in: .whitespacesAndNewlines)) family"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        do {
            try store.importCrest(from: source, surname: surname)
            surname = ""
            errorMessage = nil
            reload()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func reload() {
        reloadGeneration &+= 1
        let generation = reloadGeneration
        let root = store.root
        let cacheRoot = store.cacheRoot
        let access = store.access
        Task {
            let loaded = await Task.detached(priority: .utility) {
                let backgroundStore = FamilyAssetStore(
                    root: root, cacheRoot: cacheRoot, access: access)
                return backgroundStore.crests().map { crest in
                    (crest, backgroundStore.makeThumbnail(
                        for: crest.fileURL, maxPixelSize: 120))
                }
            }.value
            guard generation == reloadGeneration else { return }
            rows = loaded.map { crest, thumbnail in
                Row(
                    crest: crest,
                    thumbnail: thumbnail.map { NSImage(cgImage: $0, size: .zero) })
            }
        }
    }

    private func reveal(_ url: URL) {
        guard let verified = store.revalidatedImageURL(url) else {
            errorMessage = "That crest is no longer available."
            reload()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([verified])
    }

    private func revealCrestsFolder() {
        if let folder = store.readableCrestsDirectory() {
            NSWorkspace.shared.open(folder)
            errorMessage = nil
            return
        }
        do {
            let folder = try store.ensureCrestsDirectory()
            NSWorkspace.shared.open(folder)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
