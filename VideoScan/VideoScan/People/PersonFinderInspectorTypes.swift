// PersonFinderInspectorTypes.swift
// StreamInspectInfo — value type used by the Person Finder inspector
// to render an ffprobe-derived per-file stream summary. Extracted from
// PersonFinderView.swift (Rick 2026-06-15). Pure value type with a
// nested StreamDetail and a static async `probe(path:)` constructor
// that wraps the ScanEngine ffprobe call — no parent-struct access,
// so the lift is behavior-preserving.

import SwiftUI
import Foundation

// MARK: - Stream Inspection

struct StreamInspectInfo: Identifiable {
    let id = UUID()
    let filename: String
    let formatName: String
    let duration: String
    let fileSize: String
    let bitrate: String
    let streams: [StreamDetail]
    let hasVideo: Bool
    let hasAudio: Bool
    let diagnosis: String?
    let diagnosisIsWarning: Bool

    struct StreamDetail {
        let icon: String
        let color: Color
        let summary: String
        let detail: String
    }

    static func probe(path: String) async -> StreamInspectInfo {
        let url = URL(fileURLWithPath: path)
        let filename = url.lastPathComponent
        let result = await ScanEngine.runFFProbe(url: url)

        guard let output = result.output else {
            let diag = ScanEngine.humanReadableDiagnosis(stderr: result.stderr)
            return StreamInspectInfo(
                filename: filename, formatName: "Unknown", duration: "—",
                fileSize: "—", bitrate: "—", streams: [], hasVideo: false,
                hasAudio: false, diagnosis: diag.detail.isEmpty ? "ffprobe failed" : diag.detail,
                diagnosisIsWarning: false
            )
        }

        let fmt = output.format
        let dur: String = {
            guard let d = fmt?.duration, let secs = Double(d) else { return "—" }
            let m = Int(secs) / 60
            let s = Int(secs) % 60
            return String(format: "%dm %02ds", m, s)
        }()
        let size: String = {
            guard let s = fmt?.size, let bytes = Int64(s) else { return "—" }
            return Formatting.humanSize(bytes)
        }()
        let br: String = {
            guard let b = fmt?.bit_rate, let bps = Int(b) else { return "—" }
            if bps > 1_000_000 { return String(format: "%.1f Mbps", Double(bps) / 1_000_000) }
            return String(format: "%d kbps", bps / 1_000)
        }()

        var details: [StreamDetail] = []
        var hasV = false, hasA = false

        for stream in output.streams ?? [] {
            let codec = stream.codec_name ?? "unknown"
            switch stream.codec_type {
            case "video":
                hasV = true
                let res: String = {
                    if let w = stream.width, let h = stream.height { return "\(w)×\(h)" }
                    return ""
                }()
                let fps: String = {
                    guard let r = stream.r_frame_rate, let slash = r.firstIndex(of: "/"),
                          let num = Double(r[r.startIndex..<slash]),
                          let den = Double(r[r.index(after: slash)...]),
                          den > 0 else { return "" }
                    return String(format: "%.1f fps", num / den)
                }()
                details.append(StreamDetail(
                    icon: "film", color: .blue,
                    summary: "Video: \(codec)",
                    detail: [res, fps, stream.color_space].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
                ))
            case "audio":
                hasA = true
                let ch = stream.channels.map { "\($0)ch" } ?? ""
                let sr = stream.sample_rate.map { "\($0) Hz" } ?? ""
                details.append(StreamDetail(
                    icon: "speaker.wave.2", color: .green,
                    summary: "Audio: \(codec)",
                    detail: [ch, sr].filter { !$0.isEmpty }.joined(separator: " · ")
                ))
            default:
                details.append(StreamDetail(
                    icon: "doc.text", color: .secondary,
                    summary: "\(stream.codec_type ?? "data"): \(codec)",
                    detail: ""
                ))
            }
        }

        let stderrDiag: String? = {
            let trimmed = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if hasV || hasA {
                let lower = trimmed.lowercased()
                if lower.contains("corrupt") || lower.contains("invalid")
                    || lower.contains("error") || lower.contains("mismatch") {
                    return "May have some bad frames"
                }
                return nil
            }
            let diag = ScanEngine.humanReadableDiagnosis(stderr: trimmed)
            return diag.detail.isEmpty ? nil : diag.detail
        }()
        let diagIsWarning = stderrDiag != nil && (hasV || hasA)

        return StreamInspectInfo(
            filename: filename, formatName: fmt?.format_long_name ?? fmt?.format_name ?? "Unknown",
            duration: dur, fileSize: size, bitrate: br, streams: details,
            hasVideo: hasV, hasAudio: hasA, diagnosis: stderrDiag,
            diagnosisIsWarning: diagIsWarning
        )
    }
}
