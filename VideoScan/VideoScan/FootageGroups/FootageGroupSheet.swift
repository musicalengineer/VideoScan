// FootageGroupSheet.swift
// Right-click one file → "Find Similar Footage…" (Rick 2026-09-23). A
// READ-ONLY view of the file's footage group: the likely original, each
// member's role, its evidence as chips, its volume (online / offline), and
// Reveal / Play (Play opens the default player, so two files can sit side
// by side). The only writes are the person's answers — "Same footage" /
// "Not the same" / "Forget my answer" — stored on both records + the Media
// Ledger; each answer re-runs Find Similar Footage for the two files so the
// sheet shows the new grouping. No dates are written (Phase 1).
//
// The member list is computed in `.task` / `.onChange` (one O(records)
// filter), never in `body`.

import AppKit
import SwiftUI
import VideoScanCore

/// `.sheet(item:)` driver (the chained-sheet rule: one item, one sheet).
struct FootageSheetRequest: Identifiable, Equatable {
    let id = UUID()
    let recordID: UUID
}

struct FootageGroupSheet: View {
    let request: FootageSheetRequest
    @ObservedObject var model: VideoScanModel
    /// Starts the scoped re-run (nil when this window has no MFO center).
    let startRun: (FootageScope) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var members: [VideoRecord] = []
    @State private var separated: [VideoRecord] = []
    @State private var runRequested = false

    private var anchor: VideoRecord? { model.record(forID: request.recordID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if members.count > 1 {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(members, id: \.id) { rec in
                            FootageMemberRow(record: rec, anchorID: request.recordID,
                                             decision: anchor?.footageDecision(about: rec.id),
                                             onDecide: { decide($0, other: rec.id) })
                            Divider()
                        }
                    }
                }
            } else {
                emptyState
            }
            if !separated.isEmpty { separatedSection }
            HStack {
                Button("Look Again") { rerun() }
                    .help("Run Find Similar Footage for this file now (catalog metadata only).")
                    .disabled(model.isReadOnly)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 720, idealWidth: 820, minHeight: 360, idealHeight: 520)
        .task { reload(); autoRunIfNeverScanned() }
        .onChange(of: model.volumeAggregatesRevision) { _, _ in reload() }
    }

    // MARK: Pieces

    @ViewBuilder private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Similar Footage").font(.title2.weight(.semibold))
            if let a = anchor {
                Text(a.filename).font(.headline).lineLimit(1).truncationMode(.middle)
            }
            if let f = anchor?.footage, members.count > 1 {
                let original = members.first { $0.id == f.likelyOriginalID }
                Text("\(members.count) files are probably the same footage — \(f.confidence.label)")
                    .foregroundColor(.secondary)
                if let o = original {
                    Text(f.originalInCatalog
                         ? "Likely original: \(o.filename)"
                         : "The camera original is probably not in the catalog. Best available: \(o.filename)")
                        .foregroundColor(f.originalInCatalog ? .primary : .orange)
                }
                Text("Checked \(f.scannedAt.formatted(date: .abbreviated, time: .shortened)). Nothing here changes a file or a date.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            if runRequested {
                HStack { ProgressView().controlSize(.small); Text("Looking through the catalog…") }
            } else {
                Text("No other file in the catalog looks like the same footage.")
                Text("Find Similar Footage compares content signatures, recorded lineage, Final Cut media, and name + length (to ±2 frames). It reads catalog metadata only.")
                    .font(.caption).foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder private var separatedSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("You said these are NOT the same footage").font(.subheadline.weight(.semibold))
            ForEach(separated, id: \.id) { rec in
                HStack {
                    Text(rec.filename).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Forget my answer") { decide(nil, other: rec.id) }
                        .disabled(model.isReadOnly)
                }
            }
        }
    }

    // MARK: Actions

    private func reload() {
        guard let a = anchor else { members = []; separated = []; return }
        let found = model.footageGroupMembers(of: a)
        members = found.isEmpty ? [a] : found
        separated = a.footageDecisions.filter { $0.verdict == .notSame }.compactMap { model.record(forID: $0.otherID) }
        if members.count > 1 { runRequested = false }
    }

    /// First open of a never-checked file: look right away.
    private func autoRunIfNeverScanned() {
        guard let a = anchor, a.footage == nil, !model.isReadOnly else { return }
        rerun()
    }

    private func rerun() {
        runRequested = true
        startRun(.records([request.recordID]))
    }

    private func decide(_ verdict: FootageDecision.Verdict?, other: UUID) {
        model.setFootageDecision(verdict, between: request.recordID, and: other)
        runRequested = true
        startRun(.records([request.recordID, other]))
        reload()
    }
}

// MARK: - One member

private struct FootageMemberRow: View {
    let record: VideoRecord
    let anchorID: UUID
    let decision: FootageDecision?
    let onDecide: (FootageDecision.Verdict?) -> Void

    var body: some View {
        let online = VolumeReachability.isReachable(path: record.fullPath)
        let f = record.footage
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                if f?.rank == 0 {
                    Image(systemName: "star.fill").foregroundColor(.yellow).help("Likely original")
                }
                Text(record.filename)
                    .fontWeight(record.id == anchorID ? .bold : .regular)
                    .lineLimit(1).truncationMode(.middle)
                if let role = f?.role {
                    Text(role.label)
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                }
                Spacer()
                Circle().fill(online ? Color.green : Color.gray).frame(width: 7, height: 7)
                Text(VolumeReachability.displayLabel(forPath: record.fullPath) + (online ? "" : " (offline)"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Text([record.duration, record.videoCodec, record.resolution, record.size]
                    .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption).foregroundColor(.secondary)
            if let ev = f?.evidence, !ev.isEmpty {
                // Evidence chips, wrapped by the system in a flow of short capsules.
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(ev, id: \.self) { line in
                        Text(line)
                            .font(.system(size: 10))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.12)))
                    }
                }
            }
            HStack(spacing: 8) {
                Button("Reveal") {
                    NSWorkspace.shared.selectFile(record.fullPath, inFileViewerRootedAtPath: "")
                }
                .disabled(!online)
                Button("Play") {
                    NSWorkspace.shared.open(URL(fileURLWithPath: record.fullPath))
                }
                .disabled(!online)
                if record.id != anchorID {
                    Spacer()
                    if let d = decision {
                        Text(d.verdict == .same ? "You said: same footage" : "You said: not the same")
                            .font(.caption).foregroundColor(.secondary)
                        Button("Forget my answer") { onDecide(nil) }
                    } else {
                        Button("Same footage") { onDecide(.same) }
                            .help("Yes — this is the same recording. Every later run keeps them together.")
                        Button("Not the same") { onDecide(.notSame) }
                            .help("No — keep these apart on every later run, whatever the metadata says.")
                    }
                }
            }
            .controlSize(.small)
        }
    }
}
