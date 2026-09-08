import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

// MARK: - CouplePortrait
//
// The two people who joined the two trees. Rick asked (2026-09-08) for a
// small photo of him and Donna beside the Family Tree title and again on
// the People tab, so the app reads as being about them — and for the
// choice to belong to whoever is running the app, not to the repo.
//
// Storage rule: the chosen photo is re-encoded once (bounded, JPEG) into
// ~/Library/Application Support/VideoScan/portrait/, and UserDefaults
// holds only the file NAME plus a caption. Nothing personal touches git
// (privacy scrub 2026-08-03), and another user on another Mac simply sees
// the placeholder until they pick their own.

/// What the two views draw from: a resolved file plus the caption.
struct CouplePortraitChoice: Equatable {
    let url: URL
    let caption: String
}

/// Persistence for the couple portrait. Pure functions over an explicit
/// `UserDefaults` + directory so tests never touch real prefs.
enum CouplePortraitPreference {
    static let fileNameKey = "portrait.fileName"
    static let captionKey = "portrait.caption"

    /// Long-side bound for the stored copy. The views draw it at ≤ 120 pt,
    /// so 1600 px leaves room for a Retina detail pop-up later without
    /// ever holding a 7 MB TIFF in memory.
    static let storedMaxPixels = 1600

    enum ImportError: Error, Equatable {
        case notAnImage
        case encodeFailed
    }

    /// `~/Library/Application Support/VideoScan/portrait/`
    static func defaultDirectory(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan/portrait", isDirectory: true)
    }

    /// A file name we are willing to resolve inside `directory`: a single
    /// path component, no traversal. A hand-edited plist or a stale value
    /// from another build must not be able to point outside the folder.
    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty
            && !name.contains("/")
            && !name.contains("\\")
            && name != "." && name != ".."
            && !name.hasPrefix(".")
    }

    /// The current choice, or nil when nothing is set or the file is gone
    /// (a user who cleared App Support gets the placeholder, not a crash).
    static func load(from defaults: UserDefaults = .standard,
                     directory: URL? = nil,
                     fileManager: FileManager = .default) -> CouplePortraitChoice? {
        guard let name = defaults.string(forKey: fileNameKey), isSafeFileName(name) else { return nil }
        let url = (directory ?? defaultDirectory(fileManager: fileManager))
            .appendingPathComponent(name, isDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return CouplePortraitChoice(url: url, caption: caption(from: defaults))
    }

    static func caption(from defaults: UserDefaults = .standard) -> String {
        defaults.string(forKey: captionKey) ?? ""
    }

    static func saveCaption(_ caption: String, to defaults: UserDefaults = .standard) {
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: captionKey)
        } else {
            defaults.set(trimmed, forKey: captionKey)
        }
    }

    /// Copy `source` in as a bounded JPEG, point the preference at it, and
    /// drop the previous copy. Returns the stored file's URL.
    @discardableResult
    static func importPhoto(at source: URL,
                            into directory: URL? = nil,
                            defaults: UserDefaults = .standard,
                            fileManager: FileManager = .default) throws -> URL {
        let dir = directory ?? defaultDirectory(fileManager: fileManager)
        guard let image = CropRenderer.boundedImage(at: source, maxPixels: storedMaxPixels)
        else { throw ImportError.notAnImage }
        guard let data = CropRenderer.jpegData(image, quality: 0.92)
        else { throw ImportError.encodeFailed }

        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let name = "portrait-\(UUID().uuidString).jpg"
        let destination = dir.appendingPathComponent(name, isDirectory: false)
        try data.write(to: destination, options: .atomic)

        let previous = load(from: defaults, directory: dir, fileManager: fileManager)?.url
        defaults.set(name, forKey: fileNameKey)
        CouplePortraitImageCache.shared.invalidate()
        if let previous, previous != destination {
            try? fileManager.removeItem(at: previous)
        }
        return destination
    }

    /// Forget the photo and delete our copy. The caption stays — it is
    /// cheap to re-type but annoying to lose.
    static func remove(from defaults: UserDefaults = .standard,
                       directory: URL? = nil,
                       fileManager: FileManager = .default) {
        let dir = directory ?? defaultDirectory(fileManager: fileManager)
        if let current = load(from: defaults, directory: dir, fileManager: fileManager)?.url {
            try? fileManager.removeItem(at: current)
        }
        defaults.removeObject(forKey: fileNameKey)
        CouplePortraitImageCache.shared.invalidate()
    }
}

// MARK: - Decoded-image cache

/// One decoded portrait per process. The tile is drawn on two tabs and
/// every tab switch rebuilds the view, so without this the photo was
/// re-decoded from disk on each visit and the tile sat empty meanwhile
/// (Rick, 2026-09-08: "cache that family photo too"). Keyed by file name;
/// import/remove invalidate it.
final class CouplePortraitImageCache: @unchecked Sendable {
    static let shared = CouplePortraitImageCache()
    private let lock = NSLock()
    private var images: [String: NSImage] = [:]

    func image(for fileName: String) -> NSImage? {
        lock.withLock { images[fileName] }
    }

    func store(_ image: NSImage, for fileName: String) {
        lock.withLock { images[fileName] = image }
    }

    func invalidate() {
        lock.withLock { images.removeAll() }
    }

    var count: Int { lock.withLock { images.count } }
}

// MARK: - View

/// The portrait tile: a rounded, top-anchored crop (faces survive a small
/// frame) with the caption beside it. Right-click to change; the empty
/// placeholder is a button so a new user finds it without a manual.
struct CouplePortraitView: View {
    enum Placement: String {
        case familyTree
        case people
    }

    let placement: Placement
    /// Tile height in points; width follows a 4:5 portrait ratio.
    var height: CGFloat = 44
    var showsCaption = true

    @AppStorage(CouplePortraitPreference.fileNameKey) private var fileName = ""
    @AppStorage(CouplePortraitPreference.captionKey) private var caption = ""
    @State private var image: NSImage?

    init(placement: Placement, height: CGFloat = 44, showsCaption: Bool = true) {
        self.placement = placement
        self.height = height
        self.showsCaption = showsCaption
        // Already decoded once this process? Start with it, so a rebuilt
        // view (every tab switch) never shows the empty tile first.
        let name = UserDefaults.standard.string(forKey: CouplePortraitPreference.fileNameKey) ?? ""
        _image = State(initialValue: CouplePortraitImageCache.shared.image(for: name))
    }
    @State private var editingCaption = false
    @State private var captionDraft = ""

    private var tileWidth: CGFloat { (height * 0.8).rounded() }
    private var corner: CGFloat { max(4, height * 0.14) }

    /// Small tiles (a title row) put the caption beside the photo; large
    /// ones (their own row) put it underneath, like a framed print.
    private var captionBelow: Bool { height >= 80 }

    var body: some View {
        Group {
            if captionBelow {
                VStack(spacing: 6) {
                    tile
                    captionText
                }
            } else {
                HStack(spacing: 8) {
                    tile
                    captionText
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("portrait.\(placement.rawValue)")
        .task(id: fileName) { await loadImage() }
        .alert("Portrait Caption", isPresented: $editingCaption) {
            TextField("Rick & Donna", text: $captionDraft)
            Button("Save") { CouplePortraitPreference.saveCaption(captionDraft) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("A few words under the photo — names, a place, a year.")
        }
    }

    @ViewBuilder
    private var captionText: some View {
        if showsCaption, !caption.isEmpty {
            Text(caption)
                .font(captionBelow ? .callout : .caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(captionBelow ? .center : .leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: captionBelow ? tileWidth + 24 : height * 2.6,
                       alignment: captionBelow ? .center : .leading)
        }
    }

    @ViewBuilder
    private var tile: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: tileWidth, height: height, alignment: .top)
                .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                )
                .help(caption.isEmpty ? "Right-click to change the photo or add a caption"
                                      : "\(caption) — right-click to change")
                .contextMenu { menu }
        } else {
            Button(action: choosePhoto) {
                ZStack {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .foregroundStyle(.tertiary)
                    Image(systemName: "person.2")
                        .font(.system(size: max(10, height * 0.34)))
                        .foregroundStyle(.tertiary)
                }
                .frame(width: tileWidth, height: height)
            }
            .buttonStyle(.plain)
            .help("Add a photo of the two people at the center of this tree")
            .contextMenu { menu }
        }
    }

    @ViewBuilder
    private var menu: some View {
        Button(image == nil ? "Choose Photo\u{2026}" : "Change Photo\u{2026}", action: choosePhoto)
        Button(caption.isEmpty ? "Add Caption\u{2026}" : "Edit Caption\u{2026}") {
            captionDraft = caption
            editingCaption = true
        }
        if image != nil {
            Divider()
            Button("Remove Photo", role: .destructive) {
                CouplePortraitPreference.remove()
            }
        }
    }

    private func choosePhoto() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.title = "Choose the Couple's Portrait"
        panel.message = "A photo of the two people who joined the trees. A copy is kept in the app's own folder."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try CouplePortraitPreference.importPhoto(at: url)
            if caption.isEmpty {
                captionDraft = ""
                editingCaption = true
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "That file could not be used as a photo"
            alert.informativeText = url.lastPathComponent
            alert.runModal()
        }
    }

    private func loadImage() async {
        guard let choice = CouplePortraitPreference.load() else {
            image = nil
            return
        }
        let url = choice.url
        let name = url.lastPathComponent
        if let cached = CouplePortraitImageCache.shared.image(for: name) {
            image = cached
            return
        }
        // Decode off the main actor, bounded to what a 2× tile can show.
        let decoded = await Task.detached(priority: .userInitiated) { () -> NSImage? in
            guard let cg = CropRenderer.boundedImage(at: url, maxPixels: 480) else { return nil }
            return NSImage(cgImage: cg, size: .zero)
        }.value
        if let decoded { CouplePortraitImageCache.shared.store(decoded, for: name) }
        if !Task.isCancelled { image = decoded }
    }
}
