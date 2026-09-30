// PersonFinderView+Faces.swift
// The loaded-faces strip — the compact scan-readiness indicator, its
// thumbnail grid, the face-detail popover, and the reference-face URL
// resolver — extracted verbatim from PersonFinderView's body in
// PersonFinderView.swift (refactor 2026-06-24). Members shared with the
// other split files are internal in the main file; `private` here is
// file-private to THIS file.

import SwiftUI
import AppKit

extension PersonFinderView {

    /// Derive thumbnail cell size from the pane height: photos scale with
    /// the drag-resizable strip. Clamped so thumbs stay usable at extremes.
    /// Issue #38 — replaced the explicit thumbnail-size slider.
    private var derivedThumbSize: CGFloat {
        CGFloat(min(max(facesStripHeight * 0.55, 40), 140))
    }

    @ViewBuilder
    var loadedFacesStrip: some View {
        if model.referenceFaces.isEmpty && !model.isLoadingReference && model.referenceLoadError == nil {
            // Empty state — no person loaded yet
            HStack(spacing: 8) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.body)
                    .foregroundColor(.secondary)
                Text("Click a person above to load their reference faces, or use Find Person below to start a search")
                    .font(.callout)
                    .foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(NSColor.controlBackgroundColor))
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    if model.isLoadingReference {
                        ProgressView().scaleEffect(0.7)
                        Text("Loading reference photos\u{2026}")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if !model.referenceFaces.isEmpty {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.green)
                            .font(.body)
                        Text("\(model.settings.personName)")
                            .font(.body.weight(.semibold))
                        Text("\u{2014} \(model.referencePhotoCount) faces loaded")
                            .font(.body)
                            .foregroundStyle(.secondary)

                        let good = model.referenceFaces.filter { $0.quality == .good }.count
                        let fair = model.referenceFaces.filter { $0.quality == .fair }.count
                        let poor = model.referenceFaces.filter { $0.quality == .poor }.count
                        HStack(spacing: 6) {
                            if good > 0 { Text("\(good) good").foregroundColor(.green).font(.callout) }
                            if fair > 0 { Text("\(fair) fair").foregroundColor(.yellow).font(.callout) }
                            if poor > 0 { Text("\(poor) poor").foregroundColor(.red).font(.callout) }
                        }
                    }

                    if let err = model.referenceLoadError {
                        Label(err, systemImage: "info.circle.fill")
                            .foregroundColor(.orange)
                            .font(.callout)
                    }

                    if !model.referenceLoadFailures.isEmpty {
                        Button {
                            showFailures.toggle()
                        } label: {
                            Label("\(model.referenceLoadFailures.count) skipped",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        .buttonStyle(.plain)
                        .popover(isPresented: $showFailures) {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Photos Without Usable Faces")
                                    .font(.headline)
                                    .padding(.bottom, 4)
                                ForEach(model.referenceLoadFailures) { f in
                                    HStack(spacing: 6) {
                                        Image(systemName: "xmark.circle.fill")
                                            .foregroundColor(.red)
                                            .font(.system(size: 11))
                                        Text(f.filename)
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .lineLimit(1)
                                        Text("\u{2014} \(f.reason)")
                                            .font(.system(size: 11))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                            .padding(12)
                            .frame(minWidth: 320, maxHeight: 300)
                        }
                    }
                    Spacer()

                    // Collapse / expand the reference grid. Sized and tinted
                    // so it's findable at a glance — the chevron alone read
                    // too small in usability testing.
                    if !model.referenceFaces.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                referencePaneCollapsed.toggle()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: referencePaneCollapsed
                                      ? "chevron.down.circle.fill"
                                      : "chevron.up.circle.fill")
                                    .font(.system(size: 22, weight: .semibold))
                                Text(referencePaneCollapsed ? "Show Photos" : "Hide Photos")
                                    .font(.callout.weight(.medium))
                            }
                            .foregroundColor(.white)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(Color.accentColor)
                            )
                        }
                        .buttonStyle(.plain)
                        .help(referencePaneCollapsed
                              ? "Show reference photos"
                              : "Hide reference photos — gives more room to the People gallery")
                    }
                }

                // Face thumbnails — wrapping grid in a resizable pane
                if !model.referenceFaces.isEmpty && !referencePaneCollapsed {
                    let cellSize = derivedThumbSize
                    let columns = [GridItem(.adaptive(minimum: cellSize + 4), spacing: 6)]
                    ScrollView(.vertical, showsIndicators: true) {
                        LazyVGrid(columns: columns, spacing: 6) {
                            ForEach(model.referenceFaces) { face in
                                CompactFaceThumbnail(
                                    face: face,
                                    size: cellSize,
                                    onRemove: { model.removeReferenceFace(id: face.id) },
                                    sourceFileURL: referenceFaceURL(for: face)
                                )
                                .onTapGesture(count: 2) {
                                    inspectedFace = face
                                }
                            }
                        }
                        .padding(.horizontal, 2)
                        .padding(.bottom, 4)
                    }
                    .frame(height: facesStripHeight)
                    .popover(item: $inspectedFace) { face in
                        faceDetailPopover(face)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .background(Color(NSColor.controlBackgroundColor))

            // Drag handle to resize the faces pane (hidden while collapsed)
            if !model.referenceFaces.isEmpty && !referencePaneCollapsed {
                Rectangle()
                    .fill(Color(NSColor.separatorColor))
                    .frame(height: 5)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeUpDown.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture(minimumDistance: 1)
                            .onChanged { value in
                                facesStripHeight = max(60, min(500, facesStripHeight + value.translation.height))
                            }
                    )
            }
        } // else (faces loaded)
    }

    func faceDetailPopover(_ face: ReferenceFace) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(nsImage: NSImage(cgImage: face.thumbnail, size: NSSize(width: 120, height: 120)))
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 120, height: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 6) {
                    Text(face.sourceFilename)
                        .font(.headline)
                    HStack(spacing: 4) {
                        Circle()
                            .fill(face.quality == .good ? .green : face.quality == .fair ? .orange : .red)
                            .frame(width: 8, height: 8)
                        Text(face.quality == .good ? "Good" : face.quality == .fair ? "Fair" : "Poor")
                            .font(.callout.weight(.medium))
                    }
                    Text(face.angleDescription)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Divider()
            infoRow("Confidence", String(format: "%.0f%%", face.confidence * 100))
            infoRow("Yaw", String(format: "%.1f°", face.yawDeg))
            infoRow("Pitch", String(format: "%.1f°", face.pitchDeg))
            infoRow("Roll", String(format: "%.1f°", face.rollDeg))
            infoRow("Face Area", String(format: "%.1f%% of image", face.faceAreaPct))
        }
        .padding()
        .frame(minWidth: 300, maxWidth: 400)
    }

    /// Resolve a reference face back to its source image on disk. Returns
    /// nil if the file doesn't actually exist where expected — don't surface
    /// a broken Show-in-Finder item in that case.
    private func referenceFaceURL(for face: ReferenceFace) -> URL? {
        let refPath = model.settings.referencePath
        guard !refPath.isEmpty else { return nil }
        let url = URL(fileURLWithPath: refPath).appendingPathComponent(face.sourceFilename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
}
