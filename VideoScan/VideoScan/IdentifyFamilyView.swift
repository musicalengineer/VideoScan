// IdentifyFamilyView.swift
// Guided face-clustering flow inside the People tab.
//
// Four phases mirror IdentifyFamilyModel.Phase:
//  - idle:       pick a folder, optionally edit run name, hit Start
//  - scanning:   live progress (videos, faces, current file) + console
//  - clustering: brief spinner while HDBSCAN runs
//  - reviewing:  grid of cluster cards, each with its 4x4 montage and a
//                name field — one click + a name labels every face in that
//                cluster, instead of labeling thousands of frames one by one
//  - failed:     error message + retry

import SwiftUI

struct IdentifyFamilyView: View {
    @EnvironmentObject var model: IdentifyFamilyModel

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "wand.and.stars")
                .foregroundColor(.accentColor)
                .font(.title3)
            Text("Identify Family")
                .font(.title3.weight(.semibold))
            Text("— let the app cluster every face it finds, then you name each cluster once.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(12)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .idle:
            idleView
        case .scanning:
            scanningView
        case .clustering:
            clusteringView
        case .reviewing:
            reviewView
        case .failed(let msg):
            failedView(message: msg)
        }
    }

    // MARK: - Idle

    private var idleView: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("How this works")
                    .font(.headline)
                Text("""
                    1. Pick a folder of family videos (start small — one event, \
                    one decade, one volume).
                    2. The app finds every face and groups similar faces together.
                    3. You give each group a name. One label per person, not per frame.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            GroupBox("Folder") {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text(model.selectedFolder?.path ?? "No folder chosen")
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .foregroundStyle(model.selectedFolder == nil ? .secondary : .primary)
                        Spacer()
                        Button("Choose Folder…") { model.chooseFolder() }
                    }
                    HStack {
                        Text("Run name:")
                        TextField("Run name", text: $model.runName)
                            .textFieldStyle(.roundedBorder)
                            .frame(maxWidth: 320)
                        Spacer()
                    }
                    .disabled(model.selectedFolder == nil)
                }
                .padding(8)
            }

            HStack {
                Spacer()
                Button {
                    model.startScan()
                } label: {
                    Label("Start Scan", systemImage: "play.fill")
                        .padding(.horizontal, 8)
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.selectedFolder == nil)
            }

            existingRunsSection
        }
        .padding(20)
        .frame(maxWidth: 720, alignment: .topLeading)
    }

    @ViewBuilder
    private var existingRunsSection: some View {
        let runs = model.listExistingRuns()
        if !runs.isEmpty {
            GroupBox("Or load an existing run") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(runs, id: \.self) { name in
                        HStack {
                            Image(systemName: "tray.full")
                                .foregroundStyle(.secondary)
                            Text(name)
                            Spacer()
                            Button("Load") { model.loadExistingRun(named: name) }
                        }
                    }
                }
                .padding(8)
            }
        }
    }

    // MARK: - Scanning

    private var scanningView: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                ProgressView(value: scanProgressValue)
                    .progressViewStyle(.linear)
                Text(scanProgressLabel)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 24) {
                metric("Videos", value: "\(model.processedVideos)/\(max(model.totalVideos, model.processedVideos))")
                metric("Faces found", value: "\(model.totalFaces)")
                if !model.currentFile.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Current")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(model.currentFile)
                            .font(.callout).lineLimit(1).truncationMode(.middle)
                    }
                }
                Spacer()
                Button("Cancel") { model.cancel() }
            }

            consoleScroll
        }
        .padding(16)
    }

    private var scanProgressValue: Double {
        guard model.totalVideos > 0 else { return 0 }
        return Double(model.processedVideos) / Double(model.totalVideos)
    }
    private var scanProgressLabel: String {
        guard model.totalVideos > 0 else { return "starting…" }
        let pct = Int(scanProgressValue * 100)
        return "\(pct)%"
    }

    // MARK: - Clustering

    private var clusteringView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Clustering \(model.totalFaces) faces…")
                .font(.headline)
            Text("HDBSCAN groups faces by similarity. This is fast — usually a few seconds.")
                .font(.callout)
                .foregroundStyle(.secondary)
            consoleScroll
                .frame(maxHeight: 200)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Review

    private var reviewView: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Found \(realClusterCount) people-shaped clusters")
                    .font(.headline)
                if let noise = model.clusters.first(where: { $0.id == -1 }) {
                    Text("(\(noise.faceCount) unclustered faces)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Save Names") { model.saveNames() }
            }
            .padding(12)
            Divider()

            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 14)],
                          spacing: 14) {
                    ForEach(model.clusters) { cluster in
                        ClusterCard(cluster: cluster) { newName in
                            model.setName(newName, for: cluster.id)
                        }
                    }
                }
                .padding(14)
            }
        }
    }

    private var realClusterCount: Int {
        model.clusters.filter { $0.id != -1 }.count
    }

    // MARK: - Failed

    private func failedView(message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)
            Text("Something went wrong")
                .font(.headline)
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            Button("Back") { model.resetToIdle() }
        }
        .padding(20)
    }

    // MARK: - Bits

    private func metric(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit())
        }
    }

    private var consoleScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(model.consoleLines.enumerated()), id: \.offset) { item in
                        Text(item.element)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .id(item.offset)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
            }
            .background(Color(NSColor.textBackgroundColor).opacity(0.4))
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .onChange(of: model.consoleLines.count) { _, count in
                if count > 0 {
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }
}

// MARK: - Cluster card

private struct ClusterCard: View {
    let cluster: FaceCluster
    let onRename: (String) -> Void

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                if let url = cluster.gridImageURL,
                   let img = NSImage(contentsOf: url) {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.secondary.opacity(0.15))
                        .frame(height: 160)
                        .overlay(
                            Image(systemName: "person.crop.square.badge.questionmark")
                                .font(.title)
                                .foregroundStyle(.secondary)
                        )
                }
                Text(badgeText)
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }

            HStack(spacing: 6) {
                Text("\(cluster.faceCount) faces")
                    .font(.caption.monospacedDigit())
                Text("· \(cluster.videoCount) videos")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            if cluster.id == -1 {
                Text("Unclustered")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                TextField("Name (e.g. Donna)", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { onRename(name) }
                    .onChange(of: name) { _, new in onRename(new) }
            }
        }
        .padding(8)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(Color.secondary.opacity(0.2), lineWidth: 1)
        )
        .onAppear { name = cluster.name }
    }

    private var badgeText: String {
        cluster.id == -1 ? "noise" : String(format: "cluster %03d", cluster.id)
    }
}
