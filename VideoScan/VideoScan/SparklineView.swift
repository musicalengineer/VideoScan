import SwiftUI

/// Mini line chart showing throughput over time.
/// Auto-scales Y axis. Gradient fill under the line for visual weight.
struct SparklineView: View {
    let samples: [ThroughputSample]
    var height: CGFloat = 40

    private var maxY: Double {
        max(samples.map(\.filesPerSecond).max() ?? 1, 0.1)
    }

    private var currentRate: Double {
        samples.last?.filesPerSecond ?? 0
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Throughput")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.secondary)
                Spacer()
                Text(String(format: "%.1f files/sec", currentRate))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundColor(.cyan)
            }

            GeometryReader { geo in
                let w = geo.size.width
                let h = geo.size.height
                let count = samples.count
                guard count > 1 else {
                    return AnyView(Color.clear)
                }
                let stepX = w / CGFloat(count - 1)

                return AnyView(
                    ZStack {
                        // Fill
                        Path { path in
                            path.move(to: CGPoint(x: 0, y: h))
                            for (i, s) in samples.enumerated() {
                                let x = CGFloat(i) * stepX
                                let y = h - CGFloat(s.filesPerSecond / maxY) * h
                                path.addLine(to: CGPoint(x: x, y: y))
                            }
                            path.addLine(to: CGPoint(x: CGFloat(count - 1) * stepX, y: h))
                            path.closeSubpath()
                        }
                        .fill(
                            LinearGradient(
                                colors: [.blue.opacity(0.25), .cyan.opacity(0.08)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )

                        // Line
                        Path { path in
                            for (i, s) in samples.enumerated() {
                                let x = CGFloat(i) * stepX
                                let y = h - CGFloat(s.filesPerSecond / maxY) * h
                                if i == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
                            }
                        }
                        .stroke(
                            LinearGradient(
                                colors: [.blue, .cyan],
                                startPoint: .leading, endPoint: .trailing
                            ),
                            lineWidth: 1.5
                        )
                    }
                )
            }
            .frame(height: height)
        }
    }
}
