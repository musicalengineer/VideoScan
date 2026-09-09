// ArchiveAngelStartSheet.swift
// Archive Angel — Stage 1 entry (docs/archive_angel_design.md §3): how
// many to consider, whether to make FFV1 lossless copies for at-risk
// formats (AMPAS/LOC practice; off by default for speed — Rick 2026-09-09,
// a later pass can add them), where the buffer lives.

import SwiftUI

/// `.sheet(item:)` payload — a struct with its own id, per the
/// chained-sheet rule (never `.sheet(isPresented:)` twice in a row).
struct ArchiveAngelStartRequest: Identifiable {
    let id = UUID()
}

struct ArchiveAngelStartSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @EnvironmentObject var fileOpsCenter: MediaFileOperationsCenter
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss

    @AppStorage("archiveAngel.count") private var count: Int = 25
    @AppStorage("archiveAngel.makeLossless") private var makeLossless: Bool = false

    static let choices = [10, 25, 35, 50]

    private var bufferRoot: URL { ArchiveAngelPlanStore.defaultBufferRoot }
    private var freeText: String {
        let probe = FileManager.default.fileExists(atPath: bufferRoot.path)
            ? bufferRoot
            : FileManager.default.homeDirectoryForCurrentUser
        return MediaBytes.display(ArchiveAngelPlanStore.freeBytes(at: probe)) + " free"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.orange)
                Text("Archive Angel")
                    .font(.system(size: 17, weight: .semibold))
            }
            Text("Walks the catalog for important videos that are not in the Master Archive yet — rated, tagged with people, dated, played, richly described — and prepares each one in a buffer: verifies the audio, balances it when it needs it, and makes an access copy. Nothing touches the archive until you review the batch and press Promote.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Consider", selection: $count) {
                ForEach(Self.choices, id: \.self) { n in
                    Text("\(n) videos").tag(n)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 360)

            Toggle("Also make a lossless (FFV1) copy for at-risk formats", isOn: $makeLossless)
                .font(.system(size: 12))
            Text("AMPAS / Library of Congress practice keeps a lossless preservation copy of formats at risk (DV, MPEG-2, Sorenson…). It is slow and large, so it is off by default — a later pass can add them to files already in the archive.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 20)

            Divider()
            HStack(spacing: 6) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text("Buffer: \(bufferRoot.path)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(freeText)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            // Phase 2: Archive Angel Assessment (AAA) — the background
            // assessment's evidence, its age, and "Assess Now". Fresh
            // evidence (< 24 h) lets the Angel pick its batch without
            // walking the catalog first.
            ArchiveAngelEvidenceLine(store: model.archiveAngelStore, sweep: model.archiveAngelSweep)
            if model.masterArchiveRootPath == nil {
                Label("Designate a Master Archive first (Archive tab → Initialize Master Archive…).", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.yellow)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") { start() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(model.isReadOnly || model.masterArchiveRootPath == nil)
                    .accessibilityIdentifier("archiveAngel.start")
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func start() {
        fileOpsCenter.startArchiveAngel(count: count, makeLossless: makeLossless, model: model)
        dismiss()
        MediaFileOperationsWindowOpener.openBehindMain(openWindow)
    }
}


/// "Evidence: 1,203 candidates of 18,142 · computed 12 min ago · Rescore now"
struct ArchiveAngelEvidenceLine: View {
    @ObservedObject var store: ArchiveAngelEvidenceStore
    @ObservedObject var sweep: ArchiveAngelSweep

    private var evidenceText: String {
        if case .scoring(let done, let total) = sweep.status {
            return "Scoring \(done.formatted()) of \(total.formatted())…"
        }
        guard let at = store.computedAt else {
            return "Archive Angel Assessment: not run yet — the Angel will walk the catalog first."
        }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        let fresh = store.isFresh(within: ArchiveAngelJob.evidenceFreshness)
        return "Archive Angel Assessment: scored \(store.consideredCount.formatted())"
            + " · \(store.candidateCount.formatted()) candidates"
            + " · updated \(f.localizedString(for: at, relativeTo: Date()))"
            + (fresh ? "" : " (stale — the Angel will walk)")
    }

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
                .foregroundStyle(.secondary)
            Text(evidenceText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button("Assess Now") { sweep.rescoreNow() }
                .buttonStyle(.link)
                .font(.system(size: 11))
                .disabled(sweep.status.isRunning)
                .accessibilityIdentifier("archiveAngel.assessNow")
        }
    }
}
