import SwiftUI

// MARK: - Dossier channel-dots indicator
//
// Per-record badge showing which of the four dossier channels are
// populated:
//
//   • Scene captions  (VLM)
//   • Audio transcript (Whisper)
//   • OCR text         (VLM)
//   • OCR date         (VLM)
//
// Lit (color) when populated, dim (low-contrast gray) when not.
// Hover tooltip names each channel and its state. Rendered both in
// the catalog table's "Dossier" column and (planned) in the Inspector
// header so the same indicator appears anywhere the record surfaces.

struct DossierChannelDots: View {

    let record: VideoRecord

    var body: some View {
        HStack(spacing: 3) {
            DotView(filled: record.hasSceneCaptions, color: .indigo)
            DotView(filled: record.hasAudioTranscript, color: .teal)
            DotView(filled: record.hasOcrText, color: .orange)
            DotView(filled: record.hasOcrDate, color: .purple)
        }
        .help(tooltipText)
    }

    /// Human-readable tooltip naming each channel and its state.
    private var tooltipText: String {
        let lines = [
            stateLine("Scene captions", record.hasSceneCaptions),
            stateLine("Audio transcript", record.hasAudioTranscript),
            stateLine("OCR text", record.hasOcrText),
            stateLine("OCR date", record.hasOcrDate)
        ]
        let summary = "\(record.dossierChannelCount)/4 channels populated"
        return ([summary] + lines).joined(separator: "\n")
    }

    private func stateLine(_ name: String, _ on: Bool) -> String {
        "\(on ? "●" : "○") \(name)\(on ? "" : " — empty")"
    }
}

// MARK: - Single dot

private struct DotView: View {
    let filled: Bool
    let color: Color

    var body: some View {
        Circle()
            .fill(filled ? color : Color.secondary.opacity(0.22))
            .frame(width: 8, height: 8)
            .overlay(
                Circle().stroke(
                    filled ? color.opacity(0.35) : Color.clear,
                    lineWidth: 0.5
                )
            )
    }
}

// MARK: - VideoRecord helpers

extension VideoRecord {

    /// True if the record has at least one scene caption from a VLM
    /// pass. Treats empty arrays as "not populated".
    var hasSceneCaptions: Bool { !sceneCaptions.isEmpty }

    /// True if Whisper produced a non-empty transcript. Empty string
    /// is a meaningful "ran but found no speech" signal in the
    /// AudioTranscript writeback contract, but here we treat empty
    /// as "no transcript signal" — visually, an empty transcript
    /// doesn't help the user find anything.
    var hasAudioTranscript: Bool { !(audioTranscript ?? "").isEmpty }

    /// True if the dossier pass captured any on-screen text. Same
    /// rule as scene captions — empty array means no signal.
    var hasOcrText: Bool { !ocrText.isEmpty }

    /// True if the dossier pass captured any burn-in date candidates.
    /// Distinct from `inferredRecordDate` — that's the triangulated
    /// answer, this is "did we have OCR evidence".
    var hasOcrDate: Bool { !ocrDateCandidates.isEmpty }

    /// Total number of populated channels (0-4). Used as the sort
    /// key for the catalog table's Dossier column.
    var dossierChannelCount: Int {
        var n = 0
        if hasSceneCaptions     { n += 1 }
        if hasAudioTranscript   { n += 1 }
        if hasOcrText           { n += 1 }
        if hasOcrDate           { n += 1 }
        return n
    }
}
