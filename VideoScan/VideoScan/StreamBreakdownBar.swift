import SwiftUI

/// Horizontal stacked bar showing stream type distribution with legend.
struct StreamBreakdownBar: View {
    let counts: [String: Int]

    private static let categories: [(key: String, label: String, color: Color)] = [
        (StreamType.videoAndAudio.rawValue, "V+A",     .green),
        (StreamType.videoOnly.rawValue,     "V-only",  .orange),
        (StreamType.audioOnly.rawValue,     "A-only",  .yellow),
        (StreamType.noStreams.rawValue,      "None",    .gray),
        (StreamType.ffprobeFailed.rawValue,  "Failed",  .red),
    ]

    private var total: Int {
        counts.values.reduce(0, +)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Stream Types")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)

            if total > 0 {
                // Stacked bar
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        ForEach(Self.categories, id: \.key) { cat in
                            let count = counts[cat.key] ?? 0
                            if count > 0 {
                                let fraction = CGFloat(count) / CGFloat(total)
                                RoundedRectangle(cornerRadius: 2)
                                    .fill(cat.color)
                                    .frame(width: max(fraction * geo.size.width, 2))
                            }
                        }
                    }
                }
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 3))
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .fill(Color.gray.opacity(0.15))
                )

                // Legend
                HStack(spacing: 10) {
                    ForEach(Self.categories, id: \.key) { cat in
                        let count = counts[cat.key] ?? 0
                        if count > 0 {
                            HStack(spacing: 3) {
                                Circle()
                                    .fill(cat.color)
                                    .frame(width: 7, height: 7)
                                Text("\(cat.label) \(count)")
                                    .font(.system(size: 9, design: .monospaced))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            } else {
                Text("No data yet")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
    }
}
