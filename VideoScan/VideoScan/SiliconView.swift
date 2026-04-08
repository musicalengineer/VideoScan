import SwiftUI
import Combine

// MARK: - Load → color helpers

private func loadColor(_ load: Double) -> Color {
    let c = max(0, min(1, load))
    if c < 0.40 { return Color(red: 0.20, green: 0.85, blue: 0.35) }   // green
    if c < 0.75 { return Color(red: 0.95, green: 0.80, blue: 0.20) }   // yellow
    if c < 0.95 { return Color(red: 0.95, green: 0.55, blue: 0.15) }   // orange
    return Color(red: 0.95, green: 0.25, blue: 0.20)                   // red
}

private struct SiliconBlock: Identifiable {
    let id = UUID()
    let label: String
    let rect: CGRect          // in unit coords (0..1)
    var load: Double          // 0..1
    var active: Bool          // breathes if true
    var glow: Bool = false    // forced bright (e.g. match flash on ANE)
}

// MARK: - Full chip view

struct SiliconChipView: View {
    @ObservedObject var dashboard: DashboardState

    @State private var pulse: Double = 0
    @State private var matchFlashStrength: Double = 0
    private let pulseTimer = Timer.publish(every: 1.0/30.0, on: .main, in: .common).autoconnect()

    private var pCoreLoad: Double {
        // cpuLoad1 is system-wide load average, scale by core count
        let cores = max(1, Double(ProcessInfo.processInfo.activeProcessorCount))
        return min(1.0, dashboard.cpuLoad1 / cores)
    }

    private var memLoad: Double {
        dashboard.memTotalGB > 0 ? dashboard.memUsedGB / dashboard.memTotalGB : 0
    }

    /// Vision/ANE intensity 0..1, mapped from fps (30 fps ≈ saturated).
    private var aneLoad: Double {
        guard dashboard.visionActive else { return 0 }
        return min(1.0, dashboard.visionFPS / 30.0)
    }

    private var gpuLoad: Double {
        // No direct signal; co-light with ANE since Vision uses GPU passes.
        guard dashboard.visionActive else { return 0 }
        return min(1.0, dashboard.visionFPS / 45.0)
    }

    private var blocks: [SiliconBlock] {
        // Layout in unit space (chip occupies entire canvas with insets)
        // Bottom row:  P-cores (large)        | E-cores
        // Top row:     GPU (large)            | ANE | Memory
        [
            SiliconBlock(label: "P-CORES",
                         rect: CGRect(x: 0.05, y: 0.55, width: 0.50, height: 0.40),
                         load: pCoreLoad, active: pCoreLoad > 0.05),
            SiliconBlock(label: "E-CORES",
                         rect: CGRect(x: 0.58, y: 0.55, width: 0.37, height: 0.40),
                         load: pCoreLoad * 0.6, active: pCoreLoad > 0.05),
            SiliconBlock(label: "GPU",
                         rect: CGRect(x: 0.05, y: 0.08, width: 0.40, height: 0.42),
                         load: gpuLoad, active: gpuLoad > 0.02),
            SiliconBlock(label: "ANE",
                         rect: CGRect(x: 0.48, y: 0.08, width: 0.22, height: 0.42),
                         load: aneLoad, active: dashboard.visionActive,
                         glow: matchFlashStrength > 0.01),
            SiliconBlock(label: "MEM",
                         rect: CGRect(x: 0.73, y: 0.08, width: 0.22, height: 0.42),
                         load: memLoad, active: true),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "cpu.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.secondary)
                Text(dashboard.chipName.isEmpty ? "Apple Silicon" : dashboard.chipName)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundColor(.secondary)
                Spacer()
            }
            chipCanvas
                .frame(height: 150)
        }
        .onReceive(pulseTimer) { _ in
            pulse += 1.0/30.0
            // Decay match flash
            if let last = dashboard.lastMatchFlashAt {
                let age = Date().timeIntervalSince(last)
                matchFlashStrength = age < 0.7 ? max(0, 1.0 - age / 0.7) : 0
            } else {
                matchFlashStrength = 0
            }
        }
    }

    private var chipCanvas: some View {
        Canvas { ctx, size in
            // Outer die package
            let pad: CGFloat = 6
            let dieRect = CGRect(x: pad, y: pad,
                                 width: size.width - pad*2,
                                 height: size.height - pad*2)
            let diePath = Path(roundedRect: dieRect, cornerRadius: 12)
            ctx.fill(diePath, with: .color(Color(red: 0.10, green: 0.11, blue: 0.13)))
            ctx.stroke(diePath, with: .color(Color.white.opacity(0.10)), lineWidth: 1)

            // Substrate dots (subtle)
            for i in 0..<24 {
                for j in 0..<6 {
                    let x = dieRect.minX + 8 + CGFloat(i) * (dieRect.width - 16) / 23
                    let y = dieRect.minY + 4 + CGFloat(j) * 2
                    let r = CGRect(x: x, y: y, width: 1, height: 1)
                    ctx.fill(Path(ellipseIn: r), with: .color(Color.white.opacity(0.06)))
                }
            }

            // Breathing factor 0.85..1.15
            let breathe = 1.0 + 0.15 * sin(pulse * 2 * .pi * 0.5)

            for block in blocks {
                let r = CGRect(
                    x: dieRect.minX + block.rect.minX * dieRect.width,
                    y: dieRect.minY + block.rect.minY * dieRect.height,
                    width: block.rect.width * dieRect.width,
                    height: block.rect.height * dieRect.height
                )
                let path = Path(roundedRect: r.insetBy(dx: 3, dy: 3), cornerRadius: 6)

                // Base fill
                let base = loadColor(block.load)
                let intensity: Double = block.active ? (0.45 + 0.45 * block.load) * breathe : 0.18
                let fillColor = base.opacity(min(1.0, intensity))
                ctx.fill(path, with: .color(fillColor))

                // Match-flash overlay (only blocks with glow=true)
                if block.glow {
                    let glowColor = Color(red: 0.30, green: 1.0, blue: 0.45)
                        .opacity(matchFlashStrength)
                    ctx.fill(path, with: .color(glowColor))
                }

                // Inner stroke
                ctx.stroke(path, with: .color(Color.white.opacity(0.18)), lineWidth: 0.8)

                // Label
                let label = Text(block.label)
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.92))
                ctx.draw(label, at: CGPoint(x: r.midX, y: r.midY - 4), anchor: .center)

                // Load percent
                let pct = Int(block.load * 100)
                let pctText = Text("\(pct)%")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .foregroundColor(.white.opacity(0.85))
                ctx.draw(pctText, at: CGPoint(x: r.midX, y: r.midY + 7), anchor: .center)
            }
        }
    }
}

// MARK: - Mini chip (toolbar)

struct MiniSiliconChipView: View {
    @ObservedObject var dashboard: DashboardState

    @State private var matchFlashStrength: Double = 0
    private let pulseTimer = Timer.publish(every: 1.0/15.0, on: .main, in: .common).autoconnect()

    private var aneLoad: Double {
        guard dashboard.visionActive else { return 0 }
        return min(1.0, dashboard.visionFPS / 30.0)
    }
    private var memLoad: Double {
        dashboard.memTotalGB > 0 ? dashboard.memUsedGB / dashboard.memTotalGB : 0
    }
    private var cpuLoad: Double {
        let cores = max(1, Double(ProcessInfo.processInfo.activeProcessorCount))
        return min(1.0, dashboard.cpuLoad1 / cores)
    }

    var body: some View {
        Canvas { ctx, size in
            let r = CGRect(origin: .zero, size: size).insetBy(dx: 1, dy: 1)
            let die = Path(roundedRect: r, cornerRadius: 3)
            ctx.fill(die, with: .color(Color(red: 0.10, green: 0.11, blue: 0.13)))
            ctx.stroke(die, with: .color(Color.white.opacity(0.15)), lineWidth: 0.6)

            // Three pads: CPU | ANE | MEM
            let cellW = (r.width - 4) / 3
            let cellH = r.height - 4
            let loads = [cpuLoad, aneLoad, memLoad]
            for i in 0..<3 {
                let cell = CGRect(x: r.minX + 2 + CGFloat(i) * cellW,
                                  y: r.minY + 2,
                                  width: cellW - 1,
                                  height: cellH)
                let path = Path(roundedRect: cell, cornerRadius: 1.5)
                let base = loadColor(loads[i])
                let alpha = 0.30 + 0.55 * loads[i]
                ctx.fill(path, with: .color(base.opacity(alpha)))
                if i == 1 && matchFlashStrength > 0.01 {
                    ctx.fill(path, with: .color(Color(red: 0.30, green: 1.0, blue: 0.45)
                        .opacity(matchFlashStrength)))
                }
            }
        }
        .frame(width: 32, height: 18)
        .help(dashboard.chipName.isEmpty ? "Apple Silicon" : dashboard.chipName)
        .onReceive(pulseTimer) { _ in
            if let last = dashboard.lastMatchFlashAt {
                let age = Date().timeIntervalSince(last)
                matchFlashStrength = age < 0.7 ? max(0, 1.0 - age / 0.7) : 0
            } else {
                matchFlashStrength = 0
            }
        }
    }
}
