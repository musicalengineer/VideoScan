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
    @EnvironmentObject var personFinderModel: PersonFinderModel

    /// Plan computed at the moment the user clicks "Save & Promote" — held
    /// here so the confirmation sheet has something to display and execute.
    @State private var pendingPlan: [IdentifyFamilyModel.PromotionAction] = []
    @State private var showPromoteSheet = false
    @State private var promotionResult: String?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            if let result = promotionResult {
                Divider()
                HStack {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(result).font(.callout)
                    Spacer()
                    Button("Dismiss") { promotionResult = nil }.buttonStyle(.borderless)
                }
                .padding(.horizontal, 16).padding(.vertical, 8)
                .background(Color.green.opacity(0.08))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .sheet(isPresented: $showPromoteSheet) {
            PromotePreviewSheet(
                plan: pendingPlan,
                onConfirm: {
                    let summary = model.executePromotion(pendingPlan)
                    personFinderModel.savedProfiles = POIProfile.listAll()
                    promotionResult = summary
                    showPromoteSheet = false
                },
                onCancel: {
                    showPromoteSheet = false
                }
            )
        }
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
                    .frame(minWidth: 60, alignment: .trailing)
                Button("Cancel") { model.cancel() }
            }

            HStack(spacing: 18) {
                bigStat(value: "\(model.processedVideos)",
                        sub: "of \(max(model.totalVideos, model.processedVideos))",
                        label: "videos scanned")
                bigStat(value: "\(model.totalFaces)",
                        sub: model.facesPerSecond.map { String(format: "%.1f / sec", $0) } ?? "",
                        label: "faces extracted")
                bigStat(value: formatElapsed(model.elapsedSecs),
                        sub: "",
                        label: "elapsed")
                bigStat(value: model.scanETA.map(formatElapsed) ?? "—",
                        sub: "",
                        label: "remaining")
                Spacer()
            }

            if !model.currentFile.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("now scanning")
                        .font(.caption).foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    Text(model.currentFile)
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.primary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color(NSColor.controlBackgroundColor),
                            in: RoundedRectangle(cornerRadius: 6))
            }

            consoleScroll
        }
        .padding(16)
    }

    private func bigStat(value: String, sub: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
            if !sub.isEmpty {
                Text(sub)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
        }
        .frame(minWidth: 110, alignment: .leading)
    }

    private func formatElapsed(_ secs: TimeInterval) -> String {
        guard secs.isFinite, secs >= 0 else { return "—" }
        let s = Int(secs)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
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
                Button {
                    model.resetToIdle()
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)

                Text("Found \(realClusterCount) people-shaped clusters")
                    .font(.headline)
                if let noise = model.clusters.first(where: { $0.id == -1 }) {
                    Text("(\(noise.faceCount) unclustered faces)")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if !model.runName.isEmpty {
                    Button {
                        model.loadExistingRun(named: model.runName)
                    } label: {
                        Label("Reload from Disk", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .help("Re-read cluster_summary.csv — useful if the CSV was written after the in-app scan finished (race with a parallel scan).")
                }
                if let runDir = model.runDir {
                    Button {
                        NSWorkspace.shared.open(runDir)
                    } label: {
                        Label("Reveal Run Folder", systemImage: "folder")
                    }
                    .buttonStyle(.bordered)
                }
                Button("Save Names") { model.saveNames() }
                    .disabled(realClusterCount == 0)
                Button {
                    model.saveNames()
                    pendingPlan = model.planPromotion()
                    showPromoteSheet = true
                } label: {
                    Label("Save & Promote to People", systemImage: "person.crop.circle.badge.plus")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(realClusterCount == 0)
                .help("Persist names AND copy each named cluster's faces into a POI in the People tab — creates new POIs or merges into existing ones.")
            }
            .padding(12)
            Divider()

            if realClusterCount == 0 {
                emptyClustersDiagnostic
            } else {
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
    }

    /// Shown when reviewView is reached but no real clusters loaded — surfaces
    /// what we read so the user (or future-debugger) can see the actual state
    /// instead of staring at "Found 0" with no recourse.
    private var emptyClustersDiagnostic: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("No clusters loaded into the review view", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            if let runDir = model.runDir {
                Text("Run folder: \(runDir.path)")
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
            }
            if !model.lastLoadDiagnostic.isEmpty {
                Text(model.lastLoadDiagnostic)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Text("If the run folder contains cluster_001/, cluster_002/, etc. on disk but they did not load, the CSV parse failed. Use Reveal Run Folder above to inspect, then send the path so we can fix the parser.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(20)
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
