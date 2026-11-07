// FrameSearchView.swift — the Observations window's Frames mode body: the
// index's standing line (built, how many frames, or "index not built" and
// why), Index Frames…, and the hits as a grid of thumbnails, each with its
// file, its time in the clip and "SigLIP 2 (model), similarity 0.xx".
// Double-click shows the file in the Catalog; the context menu adds Show
// Dossier (the one dossier door) when there is one.
//
// NO O(records) work in this body: the hits (≤ 48) come from the store; each
// thumbnail loads in its own `.task` through the bounded thumbnail cache.
// Grey and blue, never yellow (DECISIONS 2026-11-03).
//
// (For Rick: `LazyVGrid` ≈ a virtualised grid control — tiles off screen are
// not built; `.task(id:)` ≈ start an async load when the tile appears and
// cancel it when it goes.)

import AppKit
import SwiftUI
import VideoScanCore

struct FrameSearchView: View {
    @ObservedObject var frames: FrameSearchStore
    let dossiers: FileDossierLoader?
    @State private var selection: FrameHit.ID?
    @State private var dossierHit: FrameHit?
    /// Mockup rendering (ImageRenderer draws a ScrollView blank): the hits as plain rows of four, thumbnails given.
    var mockupThumbnails: [String: CGImage]?

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            standing
            if frames.searching {
                ProgressView("Asking SigLIP 2…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let failure = frames.failure {
                Text("The frame search could not run: \(failure)").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if frames.query != nil, frames.hits.isEmpty, case .ready = frames.indexState {
                Text("No indexed frame in \(frames.scope.words) — index this scope first, or widen it.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if frames.hits.isEmpty {
                Text(Self.hint).font(.callout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else if mockupThumbnails != nil {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(stride(from: 0, to: frames.hits.count, by: 4)), id: \.self) { start in
                        HStack(alignment: .top, spacing: 12) {
                            ForEach(frames.hits[start..<min(start + 4, frames.hits.count)]) { hit in tile(hit).frame(width: 220) }
                        }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                        ForEach(frames.hits) { hit in tile(hit) }
                    }
                    .padding(.trailing, 6)
                }
            }
            if let timing = frames.timing { Text(timing).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            if let problem = frames.revealProblem { Text(problem).font(.caption).foregroundStyle(.secondary) }
        }
        .task { if frames.indexState == .loading { await frames.loadIndex() } }
        .sheet(item: $dossierHit) { hit in
            if let dossiers {
                FileDossierSheet(row: AnalysisResultsReport.FileRow(digest: hit.digest, recordID: hit.recordID, filename: hit.filename, path: hit.path,
                                                                     removed: hit.removed, value: "Frame at " + FileDossierLineView.time(hit.seconds),
                                                                     reason: hit.sourceWords),
                                 loader: dossiers, onShowInCatalog: { frames.reveal(hit) })
            }
        }
        .accessibilityIdentifier("observations.frames")
    }

    static let hint = "Describe a picture in plain words — \"a birthday cake with candles\", \"kids opening presents\", \"snow\". "
        + "SigLIP 2 compares the words with a few frames from every indexed video, on this Mac. "
        + "Similarity is a ranking, not a probability: good matches are often only 0.10–0.20."

    private var standing: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo.stack").foregroundStyle(.blue)
            switch frames.indexState {
            case .loading:
                Text("Reading the frame index…").font(.callout).foregroundStyle(.secondary)
            case .notBuilt(let why):
                Text(why).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            case .ready(let n, let contents):
                Text("\(n.formatted()) frames from \(contents.formatted()) videos, embedded by SigLIP 2 (\(frames.modelID)) on this Mac")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if let line = frames.jobLine { Text(line).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            Button(frames.job == nil ? "Index Frames…" : "Indexing…") { frames.buildIndex() }
                .disabled(frames.job != nil)
                .help("Index a few frames of every video in \(frames.scope.words) with SigLIP 2 — an MFO job you can pause or stop; a re-run resumes.")
                .accessibilityIdentifier("observations.frames.index")
        }
    }

    private func tile(_ hit: FrameHit) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Group {
                if let image = mockupThumbnails?[hit.id] {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
                } else {
                    FrameThumbnailView(path: hit.path, seconds: hit.seconds, load: frames.loader.thumbnail)
                }
            }
                .frame(height: 130)
                .frame(maxWidth: .infinity)
                .background(Color.secondary.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(selection == hit.id ? Color.accentColor : .clear, lineWidth: 2))
            HStack(spacing: 6) {
                Text(FileDossierLineView.time(hit.seconds)).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                Text(hit.filename).font(.system(size: 11)).foregroundStyle(hit.removed ? .secondary : .primary).lineLimit(1).truncationMode(.middle)
            }
            .help(hit.path)
            Text(hit.sourceWords).font(.system(size: 10)).foregroundStyle(.blue).lineLimit(1).truncationMode(.middle).help(hit.sourceWords)
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { frames.reveal(hit) }
        .onTapGesture { selection = hit.id }
        .contextMenu {
            Button("Show in Catalog") { frames.reveal(hit) }
            if dossiers != nil { Button("Show Dossier") { dossierHit = hit } }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: hit.path)]) }
        }
        .accessibilityIdentifier("observations.frames.hit")
    }
}

/// One thumbnail, loaded when shown.
struct FrameThumbnailView: View {
    let path: String
    let seconds: Double
    let load: @Sendable (String, Double) async -> CGImage?
    @State private var image: CGImage?
    @State private var tried = false

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else if tried {
                Image(systemName: "film").font(.title2).foregroundStyle(.secondary).help("The frame could not be read now (drive not connected?)")
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: "\(path)|\(seconds)") {
            image = await load(path, seconds)
            tried = true
        }
    }
}
