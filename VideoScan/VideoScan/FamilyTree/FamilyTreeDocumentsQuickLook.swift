// FamilyTreeDocumentsQuickLook.swift
// Quick Look for a person's documents (Rick, 2026-10-01): click a row in
// the inspector's Documents list and the macOS Quick Look panel opens on
// it — PDFs (every page), PNGs, JPEGs — with ALL of that person's
// documents loaded, so the arrow keys walk through them like a small
// browser. Nothing is copied or converted; Quick Look reads the files where
// they are filed.
//
// HOW QUICK LOOK FINDS ITS DATA. `QLPreviewPanel` is a shared panel that
// asks the key window's RESPONDER CHAIN who controls it
// (`acceptsPreviewPanelControl`), then calls that object's
// `beginPreviewPanelControl` to be handed a data source. SwiftUI views are
// not responders, so a zero-size AppKit view (`QuickLookAnchorView`) sits
// behind the panel, becomes first responder on a click, and hands Quick
// Look the list. (C++: registering a callback object with a framework
// singleton, scoped to "while I have focus".)
//
// MEMORY: the controller holds file URLs only (one person's documents);
// Quick Look renders and pages on its own.

import AppKit
// `@preconcurrency` ≈ "this ObjC framework predates Swift's thread-safety
// annotations; don't treat its types as unchecked cross-thread hazards".
// Every Quick Look call here happens on the main thread.
@preconcurrency import Quartz
import QuickLookThumbnailing
import SwiftUI

/// The list Quick Look shows and where it starts. `@MainActor` ≈ "touched
/// only on the UI thread" — Quick Look calls its data source there.
@MainActor
final class DocumentQuickLookController: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    private(set) var urls: [URL] = []
    private(set) var startIndex = 0
    /// The anchor view; weak, the view hierarchy owns it.
    weak var anchor: QuickLookAnchorView?

    /// True while the shared panel is showing OUR list.
    var isShowing: Bool {
        QLPreviewPanel.sharedPreviewPanelExists()
            && QLPreviewPanel.shared()?.isVisible == true
            && QLPreviewPanel.shared()?.dataSource === self
    }

    /// Open Quick Look on `urls[index]`, with every URL reachable by the
    /// arrow keys. A no-op for an empty list or a view not yet in a window.
    func show(_ urls: [URL], at index: Int) {
        guard !urls.isEmpty, let anchor, let window = anchor.window,
              let panel = QLPreviewPanel.shared() else { return }
        self.urls = urls
        self.startIndex = min(max(0, index), urls.count - 1)
        window.makeFirstResponder(anchor)
        if panel.isVisible, panel.dataSource === self {
            panel.reloadData()
            panel.currentPreviewItemIndex = startIndex
        } else {
            panel.updateController()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    /// Close the panel if it is showing our list (the person changed).
    func closeIfShowing() {
        guard isShowing else { return }
        QLPreviewPanel.shared()?.orderOut(nil)
    }

    // MARK: QLPreviewPanelDataSource

    nonisolated func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        MainActor.assumeIsolated { urls.count }
    }

    nonisolated func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        MainActor.assumeIsolated {
            guard urls.indices.contains(index) else { return nil }
            return urls[index] as NSURL
        }
    }
}

/// The zero-size responder Quick Look talks to (see the header).
final class QuickLookAnchorView: NSView {
    weak var controller: DocumentQuickLookController?

    override var acceptsFirstResponder: Bool { true }

    // These three come from an Objective-C informal protocol and are not
    // marked main-actor, but AppKit only ever calls them on the main
    // thread; `MainActor.assumeIsolated` states that (and traps if wrong).

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool {
        MainActor.assumeIsolated { controller != nil }
    }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            guard let controller, let panel else { return }
            panel.dataSource = controller
            panel.delegate = controller
            panel.currentPreviewItemIndex = controller.startIndex
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel?.dataSource = nil
            panel?.delegate = nil
        }
    }
}

/// SwiftUI wrapper: place it (zero size) in the panel's background.
/// `NSViewRepresentable` ≈ an adapter that lets SwiftUI host an AppKit view.
struct QuickLookAnchor: NSViewRepresentable {
    let controller: DocumentQuickLookController

    func makeNSView(context: Context) -> QuickLookAnchorView {
        let view = QuickLookAnchorView(frame: .zero)
        view.controller = controller
        controller.anchor = view
        return view
    }

    func updateNSView(_ view: QuickLookAnchorView, context: Context) {
        view.controller = controller
        controller.anchor = view
    }
}

/// A small Quick Look thumbnail of a document's first page, generated off
/// the main actor by the system (QLThumbnailGenerator); the kind's symbol
/// until it lands or when it cannot be made. Worst case per row: one
/// 64 × 64 pt image (≈ 64 KB at 2×).
struct PersonDocumentThumbnail: View {
    let url: URL?
    let kind: PersonDocumentKind
    /// False → always the symbol (the panel caps how many rows get one).
    let wantsThumbnail: Bool

    static let side: CGFloat = 34

    @State private var image: NSImage?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.10))
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: 3))
            } else {
                Image(systemName: kind.symbolName)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: Self.side, height: Self.side)
        .task(id: wantsThumbnail ? url : nil) {
            image = nil
            guard wantsThumbnail, let url else { return }
            image = await Self.thumbnail(for: url)
        }
        .accessibilityHidden(true)
    }

    private static func thumbnail(for url: URL) async -> NSImage? {
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: side, height: side),
            scale: NSScreen.main?.backingScaleFactor ?? 2,
            representationTypes: .thumbnail)
        do {
            let representation = try await QLThumbnailGenerator.shared.generateBestRepresentation(for: request)
            return representation.nsImage
        } catch {
            return nil
        }
    }
}
