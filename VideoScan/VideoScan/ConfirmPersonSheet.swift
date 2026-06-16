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

    /// Top-N highest-score candidates to surface, plus controlK
    /// random low-score controls. Tunable later if Rick wants finer
    /// control; defaults match what the metrics agent suggested.
    private let topN: Int = 30
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
        .onAppear(perform: startRound)
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
            if !showSummary && !candidates.isEmpty {
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
        if showSummary {
            summaryView
        } else if candidates.isEmpty {
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
            ForEach(ConfirmRating.allCases) { rating in
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
                Button("Skip") { advance() }
                    .buttonStyle(.borderless)
                Spacer()
                Button("Undo") { undoLast() }
                    .buttonStyle(.borderless)
                    .disabled(roundLabels.isEmpty)
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
                ForEach(ConfirmRating.allCases) { rating in
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
            Spacer()
            if showSummary {
                Button("Done") { dismiss() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return, modifiers: [])
            } else {
                Button("Finish & Show Summary") {
                    showSummary = true
                }
                .disabled(roundLabels.isEmpty)
                Button("Cancel") { dismiss() }
                    .buttonStyle(.bordered)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: - Round lifecycle

    private func startRound() {
        roundStart = Date()
        let already = Set(personFinderModel.validationLabels
            .labeledByPath(for: profile.name).keys)
        var rng = SystemRandomNumberGenerator()
        let round = pfConfirmRound(
            name: profile.name,
            records: catalogModel.records,
            topN: topN,
            controlK: controlK,
            alreadyLabeled: already,
            rng: &rng
        )
        candidates = round
        currentIndex = 0
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
        switch rating.writebackTier {
        case .confirmed:
            // Append to confirmedByUserPeople if not already there
            let already = rec.confirmedByUserPeople.contains {
                $0.name.caseInsensitiveCompare(profile.name) == .orderedSame
            }
            if !already {
                rec.confirmedByUserPeople.append(
                    ConfirmedTag(name: profile.name, confirmedAt: Date())
                )
            }
            // Also promote out of suspectedPeople if present
            if let idx = rec.suspectedPeople.firstIndex(where: {
                $0.caseInsensitiveCompare(profile.name) == .orderedSame
            }) {
                rec.suspectedPeople.remove(at: idx)
            }
            catalogModel.saveCatalogDebounced()
        case .suspected:
            let already = rec.suspectedPeople.contains {
                $0.caseInsensitiveCompare(profile.name) == .orderedSame
            }
            if !already {
                rec.suspectedPeople.append(profile.name)
                catalogModel.saveCatalogDebounced()
            }
        case .none:
            break
        }
    }

    private func advance() {
        thumbnailLoadTask?.cancel()
        thumbnail = nil
        if currentIndex + 1 < candidates.count {
            currentIndex += 1
            loadThumbnail(for: candidates[currentIndex])
        } else {
            // Out of candidates — show the summary automatically
            showSummary = true
        }
    }

    private func undoLast() {
        // Lightweight undo: pop last labelled, go back one. We DON'T
        // un-write the catalog tag — that's a harder operation and the
        // label sidecar keeps the most-recent-wins semantics, so
        // re-rating overwrites cleanly on the next round.
        guard !roundLabels.isEmpty, currentIndex > 0 else { return }
        roundLabels.removeLast()
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
