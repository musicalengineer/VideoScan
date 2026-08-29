// PersonFinderSubviews.swift
// Standalone subviews extracted from PersonFinderView.swift (Rick 2026-06-15).
// These five `View` structs sat at the trailing end of PersonFinderView
// and have no `private` access into the parent struct, so the lift is
// behavior-preserving. PersonFinderView dropped from 1831 → ~1525
// lines after the move and the SwiftLint type_body warning on the
// main `PersonFinderView` struct cleared.
//
// What lives here:
//   - ReferenceFaceCard   — single reference face thumbnail with
//                            quality-tinted border + remove button
//                            (used by the reference-photo strip).
//   - PersonCard          — People Gallery card with cover circle,
//                            saved/active ring animation, name label.
//   - CompactFaceThumbnail — loaded-faces strip thumbnail with
//                            context-menu Show-in-Finder + Remove.
//   - ScanTargetPOIBadge  — "for <person> (N faces)" header chip with
//                            pulsing ring when isScanning.
//   - SpinningRing        — small rotation-based progress arc, used
//                            wherever the macOS-buggy scale/opacity
//                            pulsation would have been used.

import SwiftUI
import AppKit

// MARK: - Reference Face Card

struct ReferenceFaceCard: View {
    let face: ReferenceFace
    let onRemove: () -> Void

    var thumbnail: NSImage {
        NSImage(cgImage: face.thumbnail, size: NSSize(width: 80, height: 80))
    }

    var qualityColor: Color {
        switch face.quality {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 4) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: thumbnail)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 80, height: 80)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(qualityColor, lineWidth: 3)
                    )
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(Color.white, Color.black.opacity(0.55))
                }
                .buttonStyle(.plain)
                .padding(2)
            }

            // Confidence % — large and legible
            Text(String(format: "%.0f%%", face.confidence * 100))
                .font(.system(.callout, design: .rounded).weight(.bold))
                .foregroundColor(qualityColor)

            Text(face.sourceFilename)
                .font(.system(size: 8))
                .lineLimit(1)
                .truncationMode(.middle)
                .foregroundColor(.secondary)
                .frame(width: 80, alignment: .center)
        }
        .frame(width: 88)
        .padding(4)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
        .help(face.sourceFilename)
    }
}

// MARK: - Person Card (People Gallery)

struct PersonCard: View {
    let profile: POIProfile
    let isActive: Bool
    var justSaved: Bool = false
    /// Image diameter — driven by the parent gallery's drag-resizable height.
    var imageSize: CGFloat = 64
    /// Card width — should accommodate the image plus a little breathing room.
    var cardWidth: CGFloat = 80
    /// Name label point size — scales with image size.
    var nameFontSize: CGFloat = 13
    /// Derived "Relationships" caption ("Rick's younger brother"), nil when
    /// the profile has none. Computed by the gallery, never stored.
    var relationshipsLine: String? = nil
    /// Non-blocking data nudge (a relational alias like "Dad" on a profile
    /// that isn't Dad). Shown as a small badge whose tooltip says what to do.
    var aliasWarning: String? = nil
    /// The resolved portrait (one photo per person, 2026-08-29): the Family
    /// Tree's explicit choice when it is the latest, else the cover. Nil
    /// (no resolver consulted) falls back to the profile cover as before.
    var portrait: PersonPhotoResolution? = nil

    private var ringGradient: AngularGradient {
        AngularGradient(
            colors: [.blue, .cyan, .blue.opacity(0.7), .cyan, .blue],
            center: .center
        )
    }

    private var savedGradient: AngularGradient {
        AngularGradient(
            colors: [.green, .mint, .green.opacity(0.7), .mint, .green],
            center: .center
        )
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                if let portrait, let img = NSImage(contentsOf: portrait.url) {
                    CroppedCircleImage(
                        image: img,
                        scale: portrait.cropScale,
                        offset: portrait.cropOffset
                    )
                    .frame(width: imageSize, height: imageSize)
                } else if let img = profile.coverImage {
                    CroppedCircleImage(
                        image: img,
                        scale: profile.coverCropScale,
                        offset: CGSize(width: profile.coverCropOffsetX, height: profile.coverCropOffsetY)
                    )
                    .frame(width: imageSize, height: imageSize)
                } else {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: imageSize, height: imageSize)
                    Text(String(profile.name.prefix(1)).uppercased())
                        .font(.system(size: imageSize * 0.42, weight: .bold, design: .rounded))
                        .foregroundColor(.accentColor)
                }
            }
            .overlay(
                Circle()
                    .stroke(
                        justSaved ? savedGradient
                            : isActive ? ringGradient
                            : AngularGradient(colors: [.clear], center: .center),
                        lineWidth: (justSaved || isActive) ? max(3.5, imageSize * 0.045) : 0
                    )
                    .animation(.easeInOut(duration: 0.3), value: justSaved)
            )
            .shadow(color: justSaved ? Color.green.opacity(0.6) : isActive ? Color.blue.opacity(0.5) : .clear,
                    radius: 6, y: 1)
            .animation(.easeInOut(duration: 0.3), value: justSaved)

            HStack(spacing: 3) {
                if let aliasWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: max(9, nameFontSize * 0.7)))
                        .foregroundColor(.orange)
                        .help(aliasWarning)
                        .accessibilityLabel(aliasWarning)
                }
                if justSaved {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: max(9, nameFontSize * 0.7)))
                        .foregroundColor(.green)
                        .transition(.scale.combined(with: .opacity))
                }
                Text(justSaved ? "Saved" : profile.name)
                    .font(.system(size: nameFontSize, weight: isActive ? .bold : .medium))
                    .lineLimit(1)
                    .foregroundColor(justSaved ? .green : isActive ? .blue : .primary)
            }
            .animation(.easeInOut(duration: 0.3), value: justSaved)

            if let relationshipsLine {
                Text(relationshipsLine)
                    .font(.system(size: max(9, nameFontSize * 0.78)))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(relationshipsLine)
            }
        }
        .frame(width: cardWidth)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

// MARK: - Compact Face Thumbnail (for loaded-faces strip)

struct CompactFaceThumbnail: View {
    let face: ReferenceFace
    var size: CGFloat = 58
    var onRemove: (() -> Void)?
    /// Optional full path to the source image on disk. When set, a
    /// "Show in Finder" item appears in the context menu so users can
    /// see where the reference photo actually lives.
    var sourceFileURL: URL?

    private var borderColor: Color {
        switch face.quality {
        case .good: return .green
        case .fair: return .orange
        case .poor: return .red
        }
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack(alignment: .topTrailing) {
                Image(nsImage: NSImage(cgImage: face.thumbnail, size: NSSize(width: size, height: size)))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(borderColor, lineWidth: size > 80 ? 3 : 2)
                    )
                if let onRemove {
                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: size > 80 ? 16 : 14))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.white, Color.black.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                    .offset(x: 4, y: -4)
                }
            }
            Text(String(format: "%.0f%%", face.confidence * 100))
                .font(.system(size: size > 80 ? 11 : 9, weight: .medium, design: .monospaced))
                .foregroundColor(borderColor)
        }
        .contextMenu {
            if let sourceFileURL {
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([sourceFileURL])
                }
            }
            if let onRemove {
                Button("Remove This Face", role: .destructive) { onRemove() }
            }
            Divider()
            Text("\(face.sourceFilename)")
            Text(face.quality == .good ? "Good quality" : face.quality == .fair ? "Fair quality" : "Poor quality")
        }
        .help("\(face.sourceFilename) — \(String(format: "%.0f%%", face.confidence * 100))")
    }
}

// MARK: - Scan Target POI Badge

/// Shows who we're searching for next to "Scan Targets".
/// Pulsates the ring when a scan is actively running.
struct ScanTargetPOIBadge: View {
    let personName: String
    let coverImage: NSImage?
    let isScanning: Bool
    let faceCount: Int

    @State private var pulseScale: CGFloat = 1.0

    var body: some View {
        HStack(spacing: 6) {
            Text("for")
                .font(.callout)
                .foregroundStyle(.secondary)

            ZStack {
                // Pulse ring (behind avatar)
                if isScanning {
                    Circle()
                        .stroke(Color.blue.opacity(0.3), lineWidth: 2)
                        .frame(width: 32, height: 32)
                        .scaleEffect(pulseScale)
                        .opacity(2.0 - Double(pulseScale))
                }

                if let img = coverImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 28, height: 28)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Color.blue, lineWidth: isScanning ? 2 : 1.5))
                } else {
                    Circle()
                        .fill(Color.accentColor.opacity(0.15))
                        .frame(width: 28, height: 28)
                        .overlay(
                            Text(String(personName.prefix(1)).uppercased())
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(.accentColor)
                        )
                        .overlay(Circle().stroke(Color.blue, lineWidth: isScanning ? 2 : 1.5))
                }
            }

            Text(personName)
                .font(.callout.weight(.semibold))
                .foregroundColor(.blue)

            if faceCount > 0 {
                Text("(\(faceCount) faces)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onAppear { startPulse() }
        .onChange(of: isScanning) { _, scanning in
            if scanning { startPulse() }
        }
    }

    private func startPulse() {
        guard isScanning else {
            pulseScale = 1.0
            return
        }
        pulseScale = 1.0
        withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: false)) {
            pulseScale = 1.6
        }
    }
}

// MARK: - Pulsating Ring (self-contained animation)

/// A spinning arc indicator — rotation animations are reliable on macOS SwiftUI.
struct SpinningRing: View {
    let color: Color
    var size: CGFloat = 22
    @State private var rotation: Double = 0

    var body: some View {
        ZStack {
            // Faint background track
            Circle()
                .stroke(color.opacity(0.15), lineWidth: 2.5)
                .frame(width: size, height: size)
            // Spinning arc
            Circle()
                .trim(from: 0, to: 0.3)
                .stroke(color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .frame(width: size, height: size)
                .rotationEffect(.degrees(rotation))
        }
        .onAppear {
            withAnimation(.linear(duration: 1.0).repeatForever(autoreverses: false)) {
                rotation = 360
            }
        }
    }
}
