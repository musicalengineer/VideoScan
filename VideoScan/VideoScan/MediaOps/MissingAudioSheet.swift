// MissingAudioSheet.swift
// "Find Missing Audio…" — the review sheet for one video-only record
// (GH #111, Rick 2026-09-11). Presentation only: the search lives in
// MissingAudioFinder (pure, tested) and the catalog mutation in
// VideoScanModel+MissingAudio. Same `.sheet(item:)` discipline as the
// other catalog sheets (chained-sheet antipattern memo).
//
// Flow: the search starts on appear with live progress (tier, entries
// walked, ffprobe runs) and a Cancel; candidates list with the tier, the
// rubric reasons, the duration delta, and where the file stands in the
// catalog; "Pair" hands the selected candidate to the normal Correlate.
// Nothing here muxes or moves a file.

import SwiftUI

struct MissingAudioSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    let videoID: UUID

    // `enum` with payloads ≈ a tagged union; the sheet is a small state
    // machine over it.
    private enum Phase: Equatable {
        case searching
        case done
        case pairing
        case paired
    }

    @State private var phase: Phase = .searching
    @State private var searchTask: Task<Void, Never>?
    @State private var progress: MissingAudioFinder.Progress?
    @State private var result: MissingAudioFinder.Result?
    @State private var selectedID: UUID?
    @State private var outcomeMessage: String?
    @State private var outcomeIsSuccess = false

    private var video: VideoRecord? { model.record(forID: videoID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(minWidth: 720, idealWidth: 820, minHeight: 420, idealHeight: 520)
        .onAppear(perform: startSearch)
        .onDisappear { searchTask?.cancel() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "waveform.badge.magnifyingglass")
                .font(.system(size: 20))
                .foregroundColor(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Find Missing Audio")
                    .font(.headline)
                if let v = video {
                    Text("\(v.filename) · \(Self.durationText(v.durationSeconds)) · \(v.directory)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(16)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        let candidates = result?.candidates ?? []
        if phase == .searching {
            VStack(spacing: 10) {
                ProgressView()
                    .controlSize(.small)
                Text(progressText)
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("Cheapest first: set-aside and removed records, then this video's folder and its neighbours, then every reachable scan root.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if candidates.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 28))
                    .foregroundColor(.secondary)
                Text("No audio found for this video.")
                    .foregroundColor(.secondary)
                Text(summaryText)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(candidates, selection: $selectedID) { c in
                candidateRow(c)
                    .tag(c.id)
            }
            .listStyle(.inset)
        }
    }

    private func candidateRow(_ c: MissingAudioFinder.Candidate) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text(c.tier.label)
                .font(.system(size: 9, weight: .bold))
                .padding(.horizontal, 5)
                .padding(.vertical, 2)
                .background(tierColor(c.tier).opacity(0.15),
                            in: RoundedRectangle(cornerRadius: 3))
                .foregroundColor(tierColor(c.tier))
                .frame(width: 118, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(c.filename)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(c.directory)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.head)
                Text(whyText(c))
                    .font(.system(size: 10))
                    .foregroundColor(c.correlateWillAccept ? .secondary : .orange)
                    .lineLimit(2)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("score \(c.score)")
                    .font(.system(size: 11, design: .monospaced))
                Text(c.catalogState.label)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            if let msg = outcomeMessage {
                Label(msg, systemImage: outcomeIsSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle")
                    .font(.system(size: 11))
                    .foregroundColor(outcomeIsSuccess ? .green : .orange)
                    .lineLimit(2)
            } else if phase == .done {
                Label(summaryText, systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
            Spacer()
            if phase == .searching {
                Button("Cancel Search") { searchTask?.cancel() }
            }
            Button(phase == .paired ? "Done" : "Close") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button("Pair") { pairSelected() }
                .buttonStyle(.borderedProminent)
                .tint(.teal)
                .disabled(selectedCandidate == nil || phase != .done || model.isReadOnly)
                .help("Put this audio in the catalog (restoring it if it was set aside or removed) and record the pair through the normal Correlate. Nothing is muxed or moved — Combine is a separate step.")
                .accessibilityIdentifier("missingAudio.pair")
        }
        .padding(12)
    }

    // MARK: Actions

    private func startSearch() {
        guard searchTask == nil else { return }
        phase = .searching
        searchTask = Task { @MainActor in
            let r = await model.findMissingAudio(for: videoID) { p in
                Task { @MainActor in progress = p }
            }
            result = r
            if r == nil {
                outcomeMessage = VideoScanModel.MissingAudioPairOutcome.videoUnavailable.message
            }
            phase = .done
        }
    }

    private var selectedCandidate: MissingAudioFinder.Candidate? {
        guard let id = selectedID else { return nil }
        return result?.candidates.first { $0.id == id }
    }

    private func pairSelected() {
        guard let c = selectedCandidate else { return }
        phase = .pairing
        Task { @MainActor in
            let outcome = await model.pairMissingAudio(videoID: videoID, candidate: c)
            outcomeMessage = outcome.message
            if case .paired = outcome {
                outcomeIsSuccess = true
                phase = .paired
            } else {
                outcomeIsSuccess = false
                phase = .done
            }
        }
    }

    // MARK: Text helpers

    private var progressText: String {
        guard let p = progress else { return "Checking set-aside and removed records…" }
        switch p.tier {
        case .hiddenCatalogRecords:
            return "\(p.detail) · \(p.candidatesSoFar) candidate(s)"
        case .nearbyFolders:
            return "Nearby folders · \(p.filesProbed) ffprobe run(s) · \(p.candidatesSoFar) candidate(s)\n\(p.detail)"
        case .allScanRoots:
            return "Scan roots · \(p.entriesWalked) entries walked · \(p.filesProbed) ffprobe run(s) · \(p.candidatesSoFar) candidate(s)\n\(p.detail)"
        }
    }

    private var summaryText: String {
        guard let r = result else { return "" }
        var parts: [String] = []
        for rep in r.reports {
            var s = "\(rep.tier.label): \(rep.matched) of \(rep.examined)"
            if rep.durationRefused > 0 { s += " (\(rep.durationRefused) refused on duration)" }
            if rep.truncated { s += " — cut short by the cap" }
            parts.append(s)
        }
        var text = parts.joined(separator: " · ")
        text += " · \(r.filesProbed) ffprobe run(s)"
        if r.cancelled { text += " · cancelled" }
        return text
    }

    private func whyText(_ c: MissingAudioFinder.Candidate) -> String {
        var bits = c.reasons.map { reasonLabel($0) }
        if let d = c.durationDelta {
            bits.append(String(format: "Δ %.2f s", d))
        } else if let dur = c.durationSeconds {
            bits.append("audio \(Self.durationText(dur))")
        } else {
            bits.append("duration not probed")
        }
        if !c.correlateWillAccept {
            bits.append("Correlate may decline (no duration or key match)")
        }
        return bits.joined(separator: " · ")
    }

    private func reasonLabel(_ r: String) -> String {
        switch r {
        case "filename": return "same clip name"
        case "stem": return "name stem matches"
        case "duration": return "same length"
        case "timestamp": return "same time"
        case "timecode": return "same timecode"
        case "directory": return "same folder"
        case "tape": return "same tape"
        default: return r
        }
    }

    private func tierColor(_ t: MissingAudioFinder.Tier) -> Color {
        switch t {
        case .hiddenCatalogRecords: return .teal
        case .nearbyFolders: return .blue
        case .allScanRoots: return .purple
        }
    }

    static func durationText(_ seconds: Double) -> String {
        guard seconds > 0, seconds.isFinite else { return "length unknown" }
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
