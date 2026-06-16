// ConfirmPersonSheet.swift
// Interactive UI for the Confirm-Person workflow. The user is shown
// one candidate at a time — a thumbnail, the catalog signals that
// surfaced it, and four rating buttons (Definitely / Likely / Unsure /
// Unlikely). Each rating persists to ValidationLabelStore, and the
// "positive" ratings (Definitely → confirmedByUserPeople, Likely →
// suspectedPeople) also write back to the catalog so search lights up
// immediately.
//
// Layout reference: CombineSheet / DeleteConfirmedJunkConfirmSheet —
// modal sheet, fixed width, primary content on the left, action
// affordances on the right.
//
// Rick 2026-06-16.

import AVKit
import AppKit
import SwiftUI

/// Identifiable wrapper so `.sheet(item:)` can drive the sheet from
/// PersonFinderView. The id is per-presentation, not per-profile, so
/// re-opening the sheet for the same profile produces a fresh round.
struct ConfirmSheetTarget: Identifiable {
    let id = UUID()
    let profile: POIProfile
}

struct ConfirmPersonSheet: View {

    let profile: POIProfile
    @EnvironmentObject var personFinderModel: PersonFinderModel
    @EnvironmentObject var catalogModel: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    @State private var candidates: [PersonCandidateScore] = []
    @State private var currentIndex: Int = 0
    /// Local round state — paths the user has labeled THIS session.
    /// Used so the in-sheet summary at the end is for this round only,
    /// not the cumulative store. The store has every label across
    /// sessions; this captures the slice the user just produced.
    @State private var roundStart: Date = Date()
    @State private var roundLabels: [(path: String, rating: ConfirmRating, signals: [String])] = []
    @State private var thumbnail: NSImage?
    @State private var thumbnailLoadTask: Task<Void, Never>?
    @State private var showSummary: Bool = false
    @State private var loadError: String?

    /// Sheet phase. .setup shows the round-size picker and availability
    /// stats; .labeling is the existing per-candidate review; .summary
    /// is the end-of-round report. Rick 2026-06-16.
    @State private var phase: Phase = .setup
    enum Phase { case setup, labeling, summary }

    /// Stats from round assembly — shown in the setup pane.
    @State private var stats: ConfirmRoundStats?

    /// User's pick from the round-size picker. Default 25; bumped to
    /// 100 if the user picks the long-round option.
    @State private var roundSize: Int = 25

    /// Held during setup so we don't re-score the catalog on every
    /// roundSize tick. Recomputed when the sheet appears; the picker
    /// just slices off the front.
    @State private var fullCandidatePool: [PersonCandidateScore] = []

    private let controlK: Int = 5

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 720, height: 540)
        .onAppear(perform: prepareSetup)
        .onDisappear { thumbnailLoadTask?.cancel() }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "person.crop.circle.badge.checkmark")
                .font(.title2)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text("Confirm \(profile.name)")
                    .font(.headline)
                Text("Rate each candidate — your labels train the model and update the catalog.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            if phase == .labeling && !candidates.isEmpty {
                Text("\(currentIndex + 1) of \(candidates.count)")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .setup:
            setupView
        case .labeling:
            if candidates.isEmpty {
                emptyState
            } else {
                let candidate = candidates[currentIndex]
                HStack(alignment: .top, spacing: 16) {
                    thumbnailView(for: candidate)
                        .frame(width: 320)
                    signalsView(for: candidate)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            }
        case .summary:
            summaryView
        }
    }

    private var setupView: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let stats {
                statsCard(stats)
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Scoring catalog…")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
            roundSizePicker
            Spacer()
        }
        .padding(20)
    }

    private func statsCard(_ s: ConfirmRoundStats) -> some View {
        let availOnline = fullCandidatePool.filter { $0.reachable }.count
        return VStack(alignment: .leading, spacing: 6) {
            Text("Available for \(profile.name)")
                .font(.subheadline.weight(.medium))
            statRow(symbol: "magnifyingglass", color: .blue,
                    text: "\(s.candidatesSurfaced) candidates surfaced by catalog signal")
            statRow(symbol: "arrow.triangle.merge", color: .secondary,
                    text: "\(s.dupesCollapsed) duplicates collapsed (same content across volumes)")
            statRow(symbol: "checkmark.seal", color: .green,
                    text: "\(s.alreadyLabeled) already labeled in prior rounds — skipped")
            if s.offlineSkipped > 0 {
                statRow(
                    symbol: "externaldrive.badge.exclamationmark", color: .orange,
                    text: "\(s.offlineSkipped) offline — mount " +
                          s.offlineVolumes.joined(separator: ", ") +
                          " to include them"
                )
            }
            Divider().padding(.vertical, 4)
            statRow(symbol: "checkmark.circle", color: .accentColor,
                    text: "\(availOnline) candidates ready to review now")
        }
        .padding(12)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    private func statRow(symbol: String, color: Color, text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundColor(color).frame(width: 18)
            Text(text).font(.callout)
            Spacer()
        }
    }

    private var roundSizePicker: some View {
        let availOnline = fullCandidatePool.filter { $0.reachable }.count
        let options: [Int] = {
            var opts: [Int] = []
            for size in [10, 25, 50, 100] where size <= availOnline {
                opts.append(size)
            }
            if !opts.contains(availOnline) && availOnline > 0 { opts.append(availOnline) }
            return opts
        }()
        return VStack(alignment: .leading, spacing: 6) {
            Text("How many would you like to review now?")
                .font(.subheadline.weight(.medium))
            HStack(spacing: 8) {
                ForEach(options, id: \.self) { n in
                    Button {
                        roundSize = n
                    } label: {
                        Text(n == availOnline ? "All (\(n))" : "\(n)")
                            .frame(minWidth: 48)
                            .padding(.vertical, 4)
                    }
                    .buttonStyle(.bordered)
                    .tint(roundSize == n ? .accentColor : .secondary)
                }
                Spacer()
            }
            // Time estimate — 30 sec/candidate is conservative; real
            // rates from Rick's rounds were ~12-15 sec/candidate.
            Text("Estimated time: ~\(estimateMinutes()) minutes")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    private func estimateMinutes() -> Int {
        // 25 sec per candidate including thumbnail loads and ratings.
        let seconds = roundSize * 25
        return max(1, seconds / 60)
    }

    private func thumbnailView(for candidate: PersonCandidateScore) -> some View {
        VStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.black.opacity(0.05))
                    .aspectRatio(16.0/9.0, contentMode: .fit)
                if let img = thumbnail {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(8)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            Text(candidate.filename)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(2)
                .truncationMode(.middle)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                Button {
                    openInQuickTime(candidate.recordPath)
                } label: {
                    Label("Open in QuickTime", systemImage: "play.rectangle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Watch the full video before rating")
                Button {
                    revealInFinder(candidate.recordPath)
                } label: {
                    Image(systemName: "folder")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .help("Reveal in Finder")
                Spacer()
            }
        }
    }

    private func signalsView(for candidate: PersonCandidateScore) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Why this candidate")
                .font(.subheadline.weight(.medium))
            VStack(alignment: .leading, spacing: 4) {
                ForEach(candidate.signals, id: \.self) { sig in
                    HStack(spacing: 6) {
                        Image(systemName: iconForSignal(sig))
                            .foregroundColor(.accentColor)
                            .frame(width: 14)
                        Text(sig)
                            .font(.system(size: 12))
                    }
                }
            }
            Text("Score: \(candidate.score)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
            if !candidate.reachable {
                Label("Volume offline — open won't work", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Spacer()
            ratingButtons(for: candidate)
        }
    }

    private func ratingButtons(for candidate: PersonCandidateScore) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Is \(profile.name) in this video?")
                .font(.system(size: 12).weight(.medium))
            ForEach(ConfirmRating.userFacing) { rating in
                Button {
                    apply(rating: rating, to: candidate)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: rating.symbol)
                            .foregroundColor(rating.color)
                        Text(rating.rawValue)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(rating.keyboardKey)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.bordered)
                .help(rating.hint)
            }
            HStack {
                Button("Back") { goBack() }
                    .buttonStyle(.borderless)
                    .disabled(currentIndex == 0)
                    .help("Return to the previous candidate (after an accidental skip or to re-rate)")
                Spacer()
                Button("Skip") { advance() }
                    .buttonStyle(.borderless)
                    .help("Move to the next candidate without labeling this one")
            }
            .font(.caption)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "magnifyingglass.circle")
                .font(.system(size: 36))
                .foregroundColor(.secondary)
            Text("No candidates")
                .font(.headline)
            Text("The catalog has no records with signal for \(profile.name). Run a scan with the Find Person verb first, then come back.")
                .font(.callout)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            if let err = loadError {
                Text(err)
                    .font(.caption)
                    .foregroundColor(.red)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var summaryView: some View {
        let summary = personFinderModel.validationLabels.roundSummary(
            for: profile.name, since: roundStart
        )
        return VStack(alignment: .leading, spacing: 14) {
            Text("Round summary — \(summary.total) labels")
                .font(.title3.weight(.semibold))
            VStack(spacing: 6) {
                ForEach(ConfirmRating.userFacing) { rating in
                    HStack {
                        Image(systemName: rating.symbol)
                            .foregroundColor(rating.color)
                            .frame(width: 18)
                        Text(rating.rawValue)
                            .frame(width: 110, alignment: .leading)
                        Text("\(summary.counts[rating, default: 0])")
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                }
            }
            if !summary.signalsByPositive.isEmpty {
                Divider()
                Text("Where \(profile.name) was confirmed — signal sources")
                    .font(.subheadline.weight(.medium))
                ForEach(summary.signalsByPositive.sorted { $0.value > $1.value }, id: \.key) { sig, count in
                    HStack {
                        Image(systemName: iconForSignal(sig))
                            .foregroundColor(.accentColor)
                            .frame(width: 18)
                        Text(sig)
                            .frame(width: 160, alignment: .leading)
                        Text("\(count)")
                            .font(.system(.body, design: .monospaced))
                        Spacer()
                    }
                    .font(.system(size: 12))
                }
            }
            Spacer()
            Text("Catalog updated. \(profile.name) tags wrote back to confirmedByUserPeople (Definitely) and suspectedPeople (Likely). Run Find Person next to combine these labels with face inference.")
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(20)
    }

    private var footer: some View {
        HStack {
            // Roll-up of labels saved this round — present from the
            // first rating onward so the user always knows their
            // progress is real, even if they Cancel mid-round.
            if !roundLabels.isEmpty {
                Text("\(roundLabels.count) labeled this round \u{00B7} saved")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
            Spacer()
            switch phase {
            case .setup:
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
                Button("Begin \u{2192}") { startRound() }
                    .buttonStyle(.borderedProminent)
                    .disabled(stats == nil || (stats?.candidatesSurfaced ?? 0) == 0)
                    .keyboardShortcut(.return, modifiers: [])
            case .labeling:
                Button("Finish & Show Summary") { phase = .summary }
                    .disabled(roundLabels.isEmpty)
                Button(roundLabels.isEmpty ? "Cancel" : "Save & Close") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            case .summary:
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Round lifecycle

    private func prepareSetup() {
        roundStart = Date()
        // Score in the background — for 16k records this is ~1-2 sec.
        // Keep the @MainActor scope clean by hopping out and back.
        Task { @MainActor in
            let already = Set(personFinderModel.validationLabels
                .labeledByPath(for: profile.name).keys)
            var rng = SystemRandomNumberGenerator()
            let result = pfConfirmRound(
                name: profile.name,
                records: catalogModel.records,
                topN: 100,   // upper bound; the roundSize picker trims
                controlK: controlK,
                alreadyLabeled: already,
                rng: &rng
            )
            self.fullCandidatePool = result.candidates
            self.stats = result.stats
            // Default to a sensible round size if 25 isn't reachable.
            let availOnline = result.candidates.filter { $0.reachable }.count
            if availOnline < self.roundSize {
                self.roundSize = max(min(availOnline, 25), 1)
            }
        }
    }

    private func startRound() {
        // Slice the pre-scored pool to the user's chosen round size.
        let onlineOnly = fullCandidatePool.filter { $0.reachable }
        candidates = Array(onlineOnly.prefix(roundSize))
        currentIndex = 0
        phase = .labeling
        if !candidates.isEmpty {
            loadThumbnail(for: candidates[0])
        }
    }

    private func apply(rating: ConfirmRating, to candidate: PersonCandidateScore) {
        // Persist label
        personFinderModel.validationLabels.record(
            recordPath: candidate.recordPath,
            person: profile.name,
            rating: rating,
            signals: candidate.signals,
            score: candidate.score
        )
        roundLabels.append((candidate.recordPath, rating, candidate.signals))

        // Catalog writeback per rating tier
        catalogWriteback(rating: rating, candidate: candidate)

        advance()
    }

    private func catalogWriteback(rating: ConfirmRating, candidate: PersonCandidateScore) {
        guard let rec = catalogModel.records.first(where: { $0.id == candidate.recordID })
        else { return }
        let p = profile.name
        // Each writeback path enforces "this person belongs in EXACTLY
        // ONE tier" — confirmedByUserPeople, suspectedPeople, or
        // rejectedPeople — and cleans up the other two. This makes
        // re-rating (via the Back button) idempotent: the catalog
        // state always reflects the user's most recent decision.
        switch rating.writebackTier {
        case .confirmed:
            removePerson(p, from: &rec.suspectedPeople)
            removePerson(p, from: &rec.rejectedPeople)
            if !rec.confirmedByUserPeople.contains(where: {
                $0.name.caseInsensitiveCompare(p) == .orderedSame
            }) {
                rec.confirmedByUserPeople.append(ConfirmedTag(name: p, confirmedAt: Date()))
            }
            catalogModel.saveCatalogDebounced()
        case .suspected:
            removeConfirmed(p, from: &rec.confirmedByUserPeople)
            removePerson(p, from: &rec.rejectedPeople)
            if !rec.suspectedPeople.contains(where: {
                $0.caseInsensitiveCompare(p) == .orderedSame
            }) {
                rec.suspectedPeople.append(p)
            }
            catalogModel.saveCatalogDebounced()
        case .rejected:
            removeConfirmed(p, from: &rec.confirmedByUserPeople)
            removePerson(p, from: &rec.suspectedPeople)
            // Also remove from detectedPeople so a stale PF tag from
            // a prior scan doesn't keep this video showing up in
            // people:donna search after the user explicitly said No.
            removePerson(p, from: &rec.detectedPeople)
            if !rec.rejectedPeople.contains(where: {
                $0.caseInsensitiveCompare(p) == .orderedSame
            }) {
                rec.rejectedPeople.append(p)
            }
            catalogModel.saveCatalogDebounced()
        case .none:
            // Legacy Unsure/Unlikely — no catalog mutation. Label is
            // still in the sidecar for training-data purposes.
            break
        }
    }

    private func removePerson(_ name: String, from arr: inout [String]) {
        arr.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func removeConfirmed(_ name: String, from arr: inout [ConfirmedTag]) {
        arr.removeAll { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }

    private func advance() {
        thumbnailLoadTask?.cancel()
        thumbnail = nil
        if currentIndex + 1 < candidates.count {
            currentIndex += 1
            loadThumbnail(for: candidates[currentIndex])
        } else {
            // Out of candidates — show the summary automatically
            phase = .summary
        }
    }

    private func goBack() {
        // Pure navigation — go back to the previous candidate whether
        // it was labeled or skipped (Rick 2026-06-16: an accidental
        // Skip needs to be recoverable, not just an accidental rating).
        // If the previous candidate WAS labeled this round, pop its
        // entry from roundLabels so the user can re-rate without
        // double-counting in the summary. The label sidecar's most-
        // recent-wins semantics handles the duplicate-label case
        // cleanly on the next .apply call.
        guard currentIndex > 0 else { return }
        let prevPath = candidates[currentIndex - 1].recordPath
        if let last = roundLabels.last, last.path == prevPath {
            roundLabels.removeLast()
        }
        thumbnailLoadTask?.cancel()
        currentIndex -= 1
        loadThumbnail(for: candidates[currentIndex])
    }

    // MARK: - Thumbnail loading

    private func loadThumbnail(for candidate: PersonCandidateScore) {
        guard candidate.reachable else { return }
        let path = candidate.recordPath
        thumbnailLoadTask = Task { @MainActor in
            let img = await Self.generateThumbnail(for: path)
            if !Task.isCancelled {
                self.thumbnail = img
            }
        }
    }

    private static func generateThumbnail(for path: String) async -> NSImage? {
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 480, height: 270)
        let durationSeconds: Double
        do {
            durationSeconds = try await asset.load(.duration).seconds
        } catch {
            return nil
        }
        let midpoint = CMTime(seconds: max(durationSeconds * 0.5, 0.5), preferredTimescale: 600)
        return await withCheckedContinuation { (cont: CheckedContinuation<NSImage?, Never>) in
            generator.generateCGImageAsynchronously(for: midpoint) { cg, _, _ in
                if let cg {
                    cont.resume(returning: NSImage(cgImage: cg, size: .zero))
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Helpers

    private func openInQuickTime(_ path: String) {
        guard let qtURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: "com.apple.QuickTimePlayerX"
        ) else { return }
        NSWorkspace.shared.open(
            [URL(fileURLWithPath: path)],
            withApplicationAt: qtURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    private func revealInFinder(_ path: String) {
        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
    }

    private func iconForSignal(_ signal: String) -> String {
        if signal.hasPrefix("PF-") || signal == "user-confirmed" { return "person.crop.square" }
        if signal == "filename" { return "doc" }
        if signal == "directory" { return "folder" }
        if signal.hasPrefix("transcript") { return "waveform" }
        if signal.hasPrefix("captions") { return "text.bubble" }
        if signal.hasPrefix("ocr") { return "textformat.size" }
        if signal == "control" { return "minus.circle" }
        return "circle"
    }
}
