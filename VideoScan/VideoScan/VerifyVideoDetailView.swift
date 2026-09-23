// VerifyVideoDetailView.swift
// Expanded result panel for a Verify Video row in the Media File
// Operations window: the verdict (OK / Warning / Broken), each reason in
// plain words, the recommendation, and the few technical facts the
// verdict rests on. Pure presentation over the job's published
// `diagnosis`; no model access, no I/O.

import SwiftUI

struct VerifyVideoDetailView: View {
    @ObservedObject var job: VerifyVideoJob

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let d = job.diagnosis {
                HStack(spacing: 8) {
                    Text(d.verdict.displayName)
                        .font(.system(size: 11, weight: .bold).smallCaps())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Self.color(d.verdict)))
                        .accessibilityIdentifier("mfo.verifyVideo.verdict")
                    Text(Self.facts(d.facts))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                if d.findings.isEmpty {
                    Text("Every check passed.")
                        .font(.system(size: 12))
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(d.findings.enumerated()), id: \.offset) { _, finding in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: Self.icon(VerifyVideoRules.severity(finding)))
                                    .foregroundStyle(Self.color(VerifyVideoRules.severity(finding)))
                                    .font(.system(size: 11))
                                    .frame(width: 14)
                                Text(VerifyVideoRules.noteFragment(for: finding))
                                    .font(.system(size: 12))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                Text(d.recommendation)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("mfo.verifyVideo.recommendation")
                if let errors = d.decode?.sampleErrors, !errors.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("First decoder messages:")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                        ForEach(Array(errors.enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                        }
                    }
                }
            } else if job.state.isActive {
                Text("Still checking…")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                Text("No verdict — nothing was recorded.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
    }

    // MARK: Presentation tables (static so tests can pin them)

    static func facts(_ f: VideoVerifyFacts) -> String {
        var parts: [String] = []
        if !f.videoCodec.isEmpty { parts.append(f.videoCodec) }
        if f.width > 0, f.height > 0 { parts.append("\(f.width)×\(f.height)") }
        let rate = f.avgFrameRate > 0 ? f.avgFrameRate : f.rFrameRate
        if rate > 0 { parts.append("\(VerifyVideoRules.fpsText(rate)) fps") }
        if let n = f.frameCount { parts.append("\(VerifyVideoRules.groupedInt(n)) frames") }
        if f.videoDurationSeconds > 0 { parts.append(VerifyVideoRules.durationText(f.videoDurationSeconds)) }
        if f.fileSizeBytes > 0 { parts.append(VerifyVideoRules.sizeText(f.fileSizeBytes)) }
        return parts.joined(separator: " · ")
    }

    static func color(_ v: VideoVerifyVerdict) -> Color {
        switch v {
        case .ok: return Color(red: 0.10, green: 0.55, blue: 0.25)
        case .warning: return Color(red: 0.80, green: 0.45, blue: 0.00)
        case .broken: return Color(red: 0.80, green: 0.10, blue: 0.10)
        }
    }

    static func color(_ s: VideoVerifySeverity) -> Color {
        switch s {
        case .info: return .secondary
        case .warning: return color(VideoVerifyVerdict.warning)
        case .broken: return color(VideoVerifyVerdict.broken)
        }
    }

    static func icon(_ s: VideoVerifySeverity) -> String {
        switch s {
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .broken: return "xmark.octagon.fill"
        }
    }
}
