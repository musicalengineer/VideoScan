// FileDossierView.swift — everything the catalog knows about one file, in
// three disclosure groups (the chevrons): Technical · Patterns & events ·
// Across the collection (docs/design/file_dossier_view.md, phase 1).
//
// Rick's calls (2026-11-05): all three groups start collapsed, each group's
// label is its one-line summary, so a file reads in three lines. Each line
// names who said it; an ⓘ opens the evidence. Grey and blue, never yellow
// (DECISIONS 2026-11-03): facts in the primary colour, a machine
// observation's source in blue with "unconfirmed", a missing reading in
// grey with the reason.
//
// Opening it runs nothing: it reads stored facts through FileDossierStore
// (off the main actor) — NO O(records) work and no I/O in this body.
// Built from three places through one door (FileDossierLoader.production):
// the inspector's Dossier section, the Dossier window's completed rows, the
// Results sheet (FileDossierSensorTests).
//
// (For Rick: `@StateObject` ≈ the view owns its controller, like a
// std::unique_ptr member created once per view; `.task(id:)` ≈ a worker
// restarted whenever the key changes, cancelled when the view goes away.)

import SwiftUI
import VideoScanCore

struct FileDossierView: View {

    /// The file's catalog id (`files.id` = VideoRecord.id); nil = not in this catalog.
    let fileID: UUID?
    let loader: FileDossierLoader

    @StateObject private var store = FileDossierStore()
    /// Rick 11/05: every group starts collapsed; kept while this view lives.
    @State private var expanded: Set<FileDossier.Layer> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch store.shown {
            case .idle, .loading:
                Text("Reading the catalog…").font(.caption).foregroundStyle(.secondary)
            case .notStored:
                Text("Not in catalog.sqlite yet — this file has no whole-file hash, so nothing is stored for it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .failed(let why):
                Text("The dossier could not be read: \(why)")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            case .loaded(let dossier):
                ForEach(dossier.sections) { section in
                    group(section)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: fileID) { await store.show(fileID: fileID, loader: loader) }
        .onDisappear { store.cancel() }
        .accessibilityIdentifier("fileDossier.view")
    }

    private func group(_ section: FileDossier.Section) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expanded.contains(section.layer) },
            set: { open in if open { expanded.insert(section.layer) } else { expanded.remove(section.layer) } })) {
            VStack(alignment: .leading, spacing: 6) {
                if section.lines.isEmpty {
                    Text(section.summary).font(.caption).foregroundStyle(.secondary)
                }
                ForEach(section.lines) { line in
                    FileDossierLineView(line: line)
                }
            }
            .padding(.leading, 4)
            .padding(.top, 4)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(section.layer.title).font(.system(size: 12, weight: .semibold))
                Text("— " + section.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(section.summary)
            }
        }
        .accessibilityIdentifier("fileDossier.group.\(section.layer.rawValue)")
    }
}

/// One line: label · value (→ what it suggests) · source ⓘ, then its body.
struct FileDossierLineView: View {
    let line: FileDossier.Line
    @State private var showEvidence = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(line.label)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 104, alignment: .leading)
                Text(line.value)
                    .font(.system(size: 12))
                    .foregroundStyle(line.standing == .missing ? Color.secondary : Color.primary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 6)
                source
            }
            if let reading = line.reading {
                Text("→ " + reading)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 110)
            }
            if !line.body.isEmpty { bodyView.padding(.leading, 110) }
        }
    }

    private var source: some View {
        HStack(spacing: 3) {
            Text(line.source)
                .font(.system(size: 10))
                .foregroundStyle(line.standing == .observation ? Color.blue : Color.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(line.source)
            if let evidence = line.evidence {
                Button { showEvidence.toggle() } label: {
                    Image(systemName: "info.circle").font(.system(size: 10)).foregroundStyle(.blue)
                }
                .buttonStyle(.borderless)
                .help("The evidence")
                .popover(isPresented: $showEvidence, arrowEdge: .trailing) {
                    Text(evidence)
                        .font(.callout)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 340, alignment: .leading)
                        .padding(12)
                }
                .accessibilityIdentifier("fileDossier.evidence.\(line.label)")
            }
        }
    }

    /// Captions and OCR reads by frame time; the transcript as one block.
    private var bodyView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(line.body.indices, id: \.self) { i in
                    let item = line.body[i]
                    HStack(alignment: .top, spacing: 6) {
                        if let at = item.at {
                            Text(Self.time(at))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 40, alignment: .trailing)
                        }
                        Text(item.text)
                            .font(.system(size: 11))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: 160)
        .background(Color.secondary.opacity(0.06))
        .cornerRadius(5)
    }

    /// "m:ss" for a seconds-into-clip time (the old inspector's format).
    static func time(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
