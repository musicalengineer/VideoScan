// FamilyPhotoAdjustSheet.swift
// "Adjust Photo…" for a Family Tree person (Rick 2026-08-26): drag to pan,
// pinch or slider to zoom, Center to reset, Save to write `<name>-card.jpg`
// next to the original in People/<person>/ and make it the card photo.
// Cancel touches nothing. All crop math is `CropGeometry`; the only
// rendering work here is one `cropped(_:)` call on Save.

import AppKit
import SwiftUI

/// What the sheet needs to start: a bounded (≤ 2048 px) decoded image, and
/// where it came from so the card file lands beside it.
struct FamilyPhotoAdjustSource: Identifiable {
    let id = UUID()
    let personID: String
    let personName: String
    let assetPerson: FamilyAssetPerson
    let image: CGImage
    /// The on-disk original, when there is one. Nil for a photo that only
    /// exists as this session's in-memory override.
    let originalURL: URL?
    /// Where Save writes: a SUPPLIER of a live store (codex #196), asked at
    /// Save. A live store bound to the archive it was opened on refuses if
    /// that archive is revoked or replaced while the sheet is up — it can
    /// never save into a different store.
    let makeStore: () -> FamilyAssetStore
    var store: FamilyAssetStore { makeStore() }
    /// Whose authority the sheet's writes run under: the PRESENTING MODEL's
    /// (its own access + injected centres), a supplier — never the process's
    /// (codex #198 F2). No default, so a presenter cannot forget it.
    let writeAuthority: () -> FamilyTreeWriteAuthority
}

extension FamilyPhotoAdjustSheet {
    /// The sheet's Save: the crop written as the card photo.
    static func saveCrop(_ data: Data, source: FamilyPhotoAdjustSource) throws -> URL {
        try source.writeAuthority().withWrite(.photo, path: "Adjust Photo (save crop)") {
            try source.store.saveCardPhoto(data, for: source.assetPerson, nextTo: source.originalURL)
        }
    }

    /// After Save: the crop recorded as THE choice.
    static func recordChoice(_ url: URL, source: FamilyPhotoAdjustSource) throws {
        try source.writeAuthority().withWrite(.photo, path: "Adjust Photo (record choice)") {
            try source.store.recordPhotoChoice(url, for: source.assetPerson, source: PersonPhotoChoiceSource.treeAdjust)
        }
    }
}

struct FamilyPhotoAdjustSheet: View {
    let source: FamilyPhotoAdjustSource
    /// Called with the cropped image AND the saved file (already written).
    let onSaved: (CGImage, URL) -> Void
    let onCancel: () -> Void

    /// Matches the card's circular portrait: a square viewport, shown with
    /// a circle overlay so what falls outside the circle is visibly cut.
    private static let viewport = CGSize(width: 300, height: 300)

    // `@State` ≈ view-owned mutable storage that survives re-render. The
    // geometry is a value type; every gesture mutates a copy and SwiftUI
    // redraws from it.
    @State private var geometry: CropGeometry
    @State private var dragStart: CGSize?
    @State private var zoomStart: CGFloat?
    @State private var errorText: String?
    @State private var saving = false

    init(source: FamilyPhotoAdjustSource,
         onSaved: @escaping (CGImage, URL) -> Void,
         onCancel: @escaping () -> Void) {
        self.source = source
        self.onSaved = onSaved
        self.onCancel = onCancel
        _geometry = State(initialValue: CropGeometry(
            viewport: Self.viewport,
            imageSize: CGSize(width: source.image.width, height: source.image.height)))
    }

    var body: some View {
        VStack(spacing: 14) {
            Text("Adjust photo for \(source.personName)")
                .font(.headline)

            cropViewport

            HStack(spacing: 12) {
                Image(systemName: "minus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Slider(value: Binding(
                    get: { geometry.zoom },
                    set: { geometry.setZoom($0) }),
                       in: CropGeometry.minZoom...CropGeometry.maxZoom)
                Image(systemName: "plus.magnifyingglass")
                    .foregroundStyle(.secondary)
                Button("Center") { geometry.center() }
                    .controlSize(.small)
            }

            Text("Drag to move, pinch or slide to zoom. Saves a new \(cardFileHint) beside the original; the original is kept.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)

            if let errorText {
                Text(errorText)
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Cancel", role: .cancel) { onCancel() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(saving || !geometry.isValid)
            }
        }
        .padding(20)
        .frame(width: 380)
    }

    private var cardFileHint: String {
        let stem = source.originalURL?.deletingPathExtension().lastPathComponent
            ?? source.assetPerson.name
        return "\(stem)-card.jpg"
    }

    private var cropViewport: some View {
        let displayed = geometry.displayedSize
        let offset = geometry.clampedOffset
        return ZStack {
            Image(decorative: source.image, scale: 1)
                .resizable()
                .interpolation(.high)
                .frame(width: displayed.width, height: displayed.height)
                .offset(x: offset.width, y: offset.height)
            // Everything outside the circle is dimmed: that is what the
            // card's circular mask will hide.
            Rectangle()
                .fill(Color.black.opacity(0.55))
                .mask(
                    Rectangle()
                        .overlay(Circle().padding(2).blendMode(.destinationOut))
                        .compositingGroup())
                .allowsHitTesting(false)
            Circle()
                .stroke(Color.cyan.opacity(0.9), lineWidth: 1.5)
                .padding(2)
                .allowsHitTesting(false)
        }
        .frame(width: Self.viewport.width, height: Self.viewport.height)
        .clipped()
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        // `DragGesture` ≈ mouse-down/drag/up callbacks; `translation` is the
        // distance from where the drag began, so we pan from a saved start.
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    if dragStart == nil { dragStart = geometry.clampedOffset }
                    geometry.pan(from: dragStart ?? .zero, by: value.translation)
                }
                .onEnded { _ in dragStart = nil }
        )
        // Trackpad pinch. `magnification` is a multiplier from the pinch's start.
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in
                    if zoomStart == nil { zoomStart = geometry.zoom }
                    geometry.setZoom((zoomStart ?? 1) * value.magnification)
                }
                .onEnded { _ in zoomStart = nil }
        )
    }

    private func save() {
        saving = true
        defer { saving = false }
        guard let cropped = geometry.cropped(source.image, maxPixels: 1024),
              let data = CropRenderer.jpegData(cropped, quality: 0.9) else {
            errorText = "Could not render the crop."
            return
        }
        do {
            let url = try Self.saveCrop(data, source: source)
            onSaved(cropped, url)
        } catch {
            errorText = error.localizedDescription
        }
    }
}
