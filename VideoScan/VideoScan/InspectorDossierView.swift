import SwiftUI

// MARK: - Inspector Dossier section
//
// Renders the dossier signal channels populated by the dossier pipeline:
//
//   - inferredRecordDate + inferredDateConfidence (the triangulated date)
//   - sceneCaptions (VLM scene descriptions, one per frame)
//   - ocrDateCandidates (VLM-read burn-in timestamps)
//   - ocrText (other VLM-read on-screen text)
//   - audioTranscript (Whisper transcript)
//   - dossierProcessedBy + dossierProcessedAt (provenance)
//
// Only embedded by `InspectorPanel` when `record.dossierProcessedAt != nil`,
// so empty rows don't clutter the inspector for records that haven't been
// dossiered yet.

struct InspectorDossierView: View {

    let record: VideoRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {

            // MARK: Inferred date — the triangulated answer
            if let date = record.inferredRecordDate {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "calendar.badge.checkmark")
                        .foregroundColor(.purple)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Inferred date")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(InspectorDossierView.dateFormatter.string(from: date))
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .textSelection(.enabled)
                        if let conf = record.inferredDateConfidence {
                            ConfidenceBadge(value: conf)
                        }
                    }
                }
            }

            // MARK: Audio transcript (Whisper)
            if let transcript = record.audioTranscript, !transcript.isEmpty {
                dossierBlock(
                    title: "Audio transcript",
                    icon: "waveform.circle.fill",
                    color: .teal,
                    subtitle: "\(transcript.count) char(s) — \(record.audioTranscriptModel ?? "whisper")"
                ) {
                    ScrollView {
                        Text(transcript)
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                            .padding(8)
                    }
                    .frame(maxHeight: 200)
                    .background(Color.teal.opacity(0.06))
                    .cornerRadius(6)
                }
            }

            // MARK: Scene captions (VLM)
            if !record.sceneCaptions.isEmpty {
                dossierBlock(
                    title: "Scene captions",
                    icon: "text.bubble.fill",
                    color: .indigo,
                    subtitle: "\(record.sceneCaptions.count) frame(s) — \(record.sceneCaptionModel ?? "VLM")"
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(record.sceneCaptions.indices, id: \.self) { idx in
                            let cap = record.sceneCaptions[idx]
                            HStack(alignment: .top, spacing: 6) {
                                Text(formatTimestamp(cap.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                                Text(cap.text)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.indigo.opacity(0.06))
                    .cornerRadius(6)
                }
            }

            // MARK: OCR date candidates (VLM burn-in reads)
            if !record.ocrDateCandidates.isEmpty {
                dossierBlock(
                    title: "OCR date candidates",
                    icon: "calendar.badge.clock",
                    color: .purple,
                    subtitle: "\(record.ocrDateCandidates.count) hit(s) — burn-in timestamps"
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(record.ocrDateCandidates.indices, id: \.self) { idx in
                            let entry = record.ocrDateCandidates[idx]
                            HStack(alignment: .top, spacing: 6) {
                                Text(formatTimestamp(entry.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                                Text(entry.text)
                                    .font(.system(size: 12, design: .monospaced))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.purple.opacity(0.06))
                    .cornerRadius(6)
                }
            }

            // MARK: OCR text (signs, titles, screen content)
            if !record.ocrText.isEmpty {
                dossierBlock(
                    title: "OCR text",
                    icon: "textformat",
                    color: .orange,
                    subtitle: "\(record.ocrText.count) hit(s) — signs / screen content"
                ) {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(record.ocrText.indices, id: \.self) { idx in
                            let entry = record.ocrText[idx]
                            HStack(alignment: .top, spacing: 6) {
                                Text(formatTimestamp(entry.timestamp))
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .frame(width: 50, alignment: .trailing)
                                Text(entry.text)
                                    .font(.system(size: 12))
                                    .textSelection(.enabled)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                    .padding(8)
                    .background(Color.orange.opacity(0.06))
                    .cornerRadius(6)
                }
            }

            // MARK: Provenance footer
            if let processedAt = record.dossierProcessedAt {
                HStack(alignment: .center, spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Text("Processed \(InspectorDossierView.dateFormatter.string(from: processedAt))")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                    Spacer()
                    if let stack = record.dossierProcessedBy {
                        Text(stack)
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    // MARK: - Helpers

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Format a seconds-into-clip timestamp as "m:ss" for compact display.
    private func formatTimestamp(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        let m = s / 60
        return String(format: "%d:%02d", m, s % 60)
    }

    /// One titled block with subtitle + content. Reused for each channel
    /// so they all render consistently.
    @ViewBuilder
    private func dossierBlock<Content: View>(
        title: String,
        icon: String,
        color: Color,
        subtitle: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
            content()
        }
    }
}

// MARK: - Confidence badge

private struct ConfidenceBadge: View {
    let value: Float

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(color)
                .frame(width: 6, height: 6)
            Text(String(format: "%.0f%% confidence", value * 100))
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(color)
        }
    }

    /// Rough buckets matching pfInferRecordDate's heuristics — high
    /// confidence (≥0.85, OCR consensus) is green, medium (≥0.5, single
    /// signal) is yellow, low (file mtime fallback) is gray.
    private var color: Color {
        if value >= 0.85 { return .green }
        if value >= 0.5  { return .yellow }
        return .gray
    }

    private var label: String {
        if value >= 0.85 { return "strong" }
        if value >= 0.5  { return "fair" }
        return "weak"
    }
}
