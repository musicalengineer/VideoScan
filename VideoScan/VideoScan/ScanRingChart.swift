// ScanRingChart.swift
// The live scan-progress ring + stats + best-distance calibration readout
// shown in an expanded job row — extracted verbatim from ScanJobRow.swift
// (refactor 2026-06-25). Standalone helper view; no shared state with
// ScanJobRow.

import SwiftUI

// MARK: - Scan Ring Chart

struct ScanRingChart: View {
    let total: Int
    let scanned: Int
    let hits: Int
    let elapsedSecs: Double
    let currentFile: String
    let bestDist: Float
    let threshold: Float

    private var scannedFrac: Double { total > 0 ? min(1, Double(scanned) / Double(total)) : 0 }
    private var hitsFrac: Double { total > 0 ? min(1, Double(hits)    / Double(total)) : 0 }
    private var vps: Double? { elapsedSecs > 2 && scanned > 2 ? Double(scanned) / elapsedSecs : nil }

    // Colour the best-dist reading relative to the active threshold
    private var distColor: Color {
        guard bestDist < .greatestFiniteMagnitude else { return .secondary }
        if bestDist <= threshold { return .green }   // within threshold — a hit
        if bestDist <= threshold + 0.10 { return .orange }  // close — might just need threshold nudge
        return .secondary
    }

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            // Ring
            ZStack {
                Circle()
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 10)
                Circle()
                    .trim(from: 0, to: scannedFrac)
                    .stroke(Color.blue.opacity(0.45),
                            style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: scannedFrac)
                Circle()
                    .trim(from: 0, to: hitsFrac)
                    .stroke(Color.green,
                            style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: hitsFrac)
                VStack(spacing: 0) {
                    Text("\(scanned)")
                        .font(.system(.footnote, design: .rounded).weight(.bold))
                    Text("/ \(total)")
                        .font(.system(size: 9)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 64, height: 64)

            // Stats + best dist
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text("\(hits) match\(hits == 1 ? "" : "es")")
                        .font(.callout.weight(.semibold)).foregroundColor(.green)
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.blue.opacity(0.5)).frame(width: 7, height: 7)
                    Text("\(scanned) scanned")
                        .font(.callout).foregroundStyle(.secondary)
                }
                HStack(spacing: 5) {
                    Circle().fill(Color.secondary.opacity(0.25)).frame(width: 7, height: 7)
                    Text("\(max(0, total - scanned)) remaining")
                        .font(.callout).foregroundStyle(.secondary)
                }
                if let v = vps {
                    Text(String(format: "%.1f vid/s", v))
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }

            Divider().frame(height: 56)

            // Best distance — the key calibration number
            VStack(alignment: .center, spacing: 2) {
                Text("BEST DIST")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(1)
                if bestDist < .greatestFiniteMagnitude {
                    Text(String(format: "%.3f", bestDist))
                        .font(.system(.title2, design: .monospaced).weight(.bold))
                        .foregroundColor(distColor)
                        .animation(.easeInOut(duration: 0.3), value: bestDist)
                } else {
                    Text("—")
                        .font(.system(.title2, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
                Text("thresh \(String(format: "%.2f", threshold))")
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.secondary)
                if !currentFile.isEmpty {
                    Text((currentFile as NSString).lastPathComponent)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: 160, alignment: .center)
                }
            }
            .frame(minWidth: 90)
        }
        .padding(.vertical, 4)
    }
}
