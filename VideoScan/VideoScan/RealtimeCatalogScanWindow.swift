// RealtimeCatalogScanWindow.swift
// Live "what is the catalog scanner doing right now" window — visual analog
// of the Realtime Face Detection window so the parallel scan + FD demo
// has eye candy on both sides.

import SwiftUI
import AppKit

// MARK: - Window Content

struct RealtimeCatalogScanContent: View {
    @ObservedObject var dashboard: DashboardState

    private var phaseColor: Color {
        switch dashboard.scanPhase {
        case .idle:        return .gray
        case .discovering: return .orange
        case .probing:     return .cyan
        case .paused:      return .cyan
        case .writingCSV:  return .blue
        case .complete:    return .green
        }
    }

    private var isActive: Bool {
        dashboard.scanPhase == .discovering || dashboard.scanPhase == .probing || dashboard.scanPhase == .paused
    }

    private var fraction: Double {
        guard dashboard.scanTotal > 0 else { return 0 }
        return Double(dashboard.scanCompleted) / Double(dashboard.scanTotal)
    }

    private var avgFps: Double {
        guard !dashboard.throughputSamples.isEmpty else { return 0 }
        let sum = dashboard.throughputSamples.reduce(0.0) { $0 + $1.filesPerSecond }
        return sum / Double(dashboard.throughputSamples.count)
    }

    private var totalProbed: Int {
        dashboard.scanCacheHits + dashboard.scanCacheMisses
    }

    private var cacheRate: Double {
        totalProbed > 0 ? Double(dashboard.scanCacheHits) / Double(totalProbed) : 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                phaseHeader
                if !dashboard.volumeProgress.isEmpty {
                    volumesPane
                }
                currentFileRow
                statsRow
                if dashboard.netPrefetchCount > 0 {
                    networkPrefetchPane
                }
                streamTypesPane
                if dashboard.throughputSamples.count > 2 {
                    throughputPane
                }
            }
            .padding(14)
        }
        .frame(minWidth: 680, idealWidth: 800, minHeight: 420, idealHeight: 560)
        .background(Color(NSColor.windowBackgroundColor))
    }

    // MARK: Phase header

    private var phaseHeader: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(phaseColor.opacity(0.15))
                    .frame(width: 38, height: 38)
                Circle()
                    .fill(phaseColor)
                    .frame(width: 14, height: 14)
                    .shadow(color: phaseColor.opacity(0.6), radius: isActive ? 8 : 0)
                    .scaleEffect(isActive ? 1.1 : 1.0)
                    .animation(
                        isActive
                            ? .easeInOut(duration: 0.9).repeatForever(autoreverses: true)
                            : .default,
                        value: isActive
                    )
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(dashboard.scanPhase.rawValue.uppercased())
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundColor(phaseColor)
                if dashboard.scanTotal > 0 {
                    Text("\(dashboard.scanCompleted) / \(dashboard.scanTotal)  (\(Int(fraction * 100))%)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundColor(.secondary)
                } else {
                    Text(isActive ? "Walking volumes…" : "Idle")
                        .font(.system(size: 14))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.bottom, 2)
    }

    // MARK: Stats row (cache, errors, avg fps)

    private var statsRow: some View {
        HStack(spacing: 8) {
            statTile(
                icon: "bolt.fill",
                color: .yellow,
                value: "\(dashboard.scanCacheHits)",
                label: "cache hits",
                sub: totalProbed > 0 ? "\(Int(cacheRate * 100))% hit rate" : "—"
            )
            statTile(
                icon: "magnifyingglass",
                color: .blue,
                value: "\(dashboard.scanCacheMisses)",
                label: "ffprobed",
                sub: "fresh"
            )
            statTile(
                icon: "speedometer",
                color: .cyan,
                value: String(format: "%.1f", avgFps),
                label: "avg files/sec",
                sub: "since start"
            )
            statTile(
                icon: "exclamationmark.triangle.fill",
                color: dashboard.scanErrors > 0 ? .red : .secondary,
                value: "\(dashboard.scanErrors)",
                label: "errors",
                sub: dashboard.scanErrors > 0 ? "ffprobe failed" : "clean"
            )
        }
    }

    private func statTile(icon: String, color: Color, value: String, label: String, sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Image(systemName: icon)
                    .font(.system(size: 11))
                    .foregroundColor(color)
                Text(label.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            Text(value)
                .font(.system(size: 22, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(color)
            Text(sub)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(8)
    }

    // MARK: Network prefetch stats

    private var avgMBps: Double {
        dashboard.netPrefetchTotalSeconds > 0
            ? dashboard.netPrefetchTotalMB / dashboard.netPrefetchTotalSeconds
            : 0
    }

    private var networkPrefetchPane: some View {
        GroupBox {
            HStack(spacing: 8) {
                statTile(
                    icon: "arrow.down.circle.fill",
                    color: .mint,
                    value: "\(dashboard.netPrefetchCount)",
                    label: "prefetched",
                    sub: "files → RAM"
                )
                statTile(
                    icon: "internaldrive.fill",
                    color: .mint,
                    value: Formatting.humanMB(dashboard.netPrefetchTotalMB),
                    label: "copied",
                    sub: dashboard.netPrefetchCount > 0
                        ? "\(Formatting.humanMB(dashboard.netPrefetchTotalMB / Double(dashboard.netPrefetchCount))) avg"
                        : "—"
                )
                statTile(
                    icon: "speedometer",
                    color: .mint,
                    value: Formatting.humanMBps(avgMBps),
                    label: "throughput",
                    sub: "\(Formatting.humanMBps(dashboard.netPrefetchLastMBps)) last"
                )
                statTile(
                    icon: "clock.fill",
                    color: .mint,
                    value: String(format: "%.1fs", dashboard.netPrefetchTotalSeconds),
                    label: "I/O time",
                    sub: "network wait"
                )
            }
        } label: {
            Label("Network Prefetch (Ethernet → RAM Disk)", systemImage: "network")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.mint)
        }
    }

    // MARK: Current file (compact single line)

    private var currentFileRow: some View {
        GroupBox {
            HStack(spacing: 6) {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.cyan)
                if !dashboard.scanCurrentVolume.isEmpty {
                    Text(dashboard.scanCurrentVolume)
                        .font(.system(size: 12, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                }
                Text(dashboard.scanCurrentFile.isEmpty
                     ? "Waiting…"
                     : dashboard.scanCurrentFile)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundColor(.cyan)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }
        } label: {
            Label("Current File", systemImage: "scope")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.cyan)
        }
    }

    // MARK: Per-volume progress

    private var volumesPane: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(dashboard.volumeProgress) { vol in
                    VolumeMiniRow(volume: vol)
                }
            }
        } label: {
            Label("Volumes (\(dashboard.volumeProgress.count))", systemImage: "externaldrive.connected.to.line.below")
                .font(.system(size: 15, weight: .bold))
                .foregroundColor(.blue)
        }
    }

    // MARK: Stream type tiles

    private var streamTypesPane: some View {
        GroupBox {
            HStack(spacing: 8) {
                ForEach(streamCategories, id: \.key) { cat in
                    let count = dashboard.liveStreamCounts[cat.key] ?? 0
                    streamTile(label: cat.label, count: count, color: cat.color, icon: cat.icon)
                }
            }
        } label: {
            Label("Stream Types", systemImage: "film.stack")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.purple)
        }
    }

    private struct StreamCategory {
        let key: String
        let label: String
        let color: Color
        let icon: String
    }

    private var streamCategories: [StreamCategory] {
        [
            .init(key: StreamType.videoAndAudio.rawValue, label: "V+A",     color: .green,  icon: "play.rectangle.fill"),
            .init(key: StreamType.videoOnly.rawValue,     label: "V only",  color: .orange, icon: "video.fill"),
            .init(key: StreamType.audioOnly.rawValue,     label: "A only",  color: .yellow, icon: "waveform"),
            .init(key: StreamType.noStreams.rawValue,     label: "None",    color: .gray,   icon: "questionmark.square"),
            .init(key: StreamType.ffprobeFailed.rawValue, label: "Failed",  color: .red,    icon: "xmark.octagon"),
        ]
    }

    private func streamTile(label: String, count: Int, color: Color, icon: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(color)
            Text("\(count)")
                .font(.system(size: 18, weight: .bold, design: .rounded).monospacedDigit())
                .foregroundColor(count > 0 ? color : .secondary.opacity(0.5))
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(.secondary)
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(color.opacity(count > 0 ? 0.08 : 0.0))
        .cornerRadius(6)
    }

    // MARK: Throughput sparkline

    private var throughputPane: some View {
        GroupBox {
            SparklineView(samples: dashboard.throughputSamples)
                .frame(height: 50)
        } label: {
            Label("Throughput (last \(dashboard.throughputSamples.count)s)", systemImage: "waveform.path.ecg")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.cyan)
        }
    }
}

// MARK: - Mini volume row (compact, for the RT scan window)

private struct VolumeMiniRow: View {
    let volume: VolumeProgress

    private var fraction: Double {
        volume.totalFiles > 0 ? Double(volume.completedFiles) / Double(volume.totalFiles) : 0
    }

    private var icon: String {
        if volume.isWalking { return "folder.badge.gearshape" }
        if volume.rootPath.hasPrefix("/Volumes/") { return "externaldrive.fill" }
        return "internaldrive.fill"
    }

    private var iconColor: Color {
        volume.isWalking ? .orange : .blue
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(iconColor)
                    .font(.system(size: 16))
                Text(volume.volumeName)
                    .font(.system(size: 16, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if volume.isWalking {
                    Text("discovering…")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundColor(.orange)
                } else {
                    Text("\(volume.completedFiles) / \(volume.totalFiles)")
                        .font(.system(size: 14, weight: .medium, design: .monospaced))
                        .foregroundColor(.secondary)
                    Text("(\(Int(fraction * 100))%)")
                        .font(.system(size: 14, weight: .bold, design: .monospaced))
                        .foregroundColor(fraction >= 1.0 ? .green : .cyan)
                }
                if volume.cacheHits > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "bolt.fill").font(.system(size: 10))
                        Text("\(volume.cacheHits)").font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(.yellow)
                }
                if volume.errors > 0 {
                    HStack(spacing: 2) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
                        Text("\(volume.errors)").font(.system(size: 12, design: .monospaced))
                    }
                    .foregroundColor(.red)
                }
            }
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.gray.opacity(0.15))
                    .frame(height: 10)
                GeometryReader { geo in
                    RoundedRectangle(cornerRadius: 4)
                        .fill(LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(geo.size.width * fraction, 0), height: 10)
                        .animation(.easeInOut(duration: 0.3), value: fraction)
                }
                .frame(height: 10)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Window controller

@MainActor
class CatalogScanWindowController {
    static let shared = CatalogScanWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(dashboard: DashboardState) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        close()

        let content = RealtimeCatalogScanContent(dashboard: dashboard)
        let hosting = NSHostingView(rootView: content)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // NSWindow defaults to isReleasedWhenClosed=true → AppKit double-
        // releases on close, leaving `self.window` dangling and the next
        // show() crashes inside objc_retain.
        w.isReleasedWhenClosed = false
        w.title = "Realtime Catalog Scan"
        w.contentView = hosting
        w.setFrameAutosaveName("RealtimeCatalogScanV1")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: w,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.window = nil
            if let obs = self.closeObserver {
                NotificationCenter.default.removeObserver(obs)
                self.closeObserver = nil
            }
        }
    }

    func close() {
        if let obs = closeObserver {
            NotificationCenter.default.removeObserver(obs)
            closeObserver = nil
        }
        window?.close()
        window = nil
    }
}
