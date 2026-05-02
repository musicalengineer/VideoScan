// RealtimeFaceDetectionWindow.swift
// Tear-off live face detection preview + per-job console windows.

import SwiftUI
import AppKit

// MARK: - Live Frame Preview

struct LiveFramePreview: View {
    let frame: CGImage
    let matchedRects: [CGRect]      // Vision normalized, bottom-left origin
    let unmatchedRects: [CGRect]

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack(alignment: .topLeading) {
                Image(decorative: frame, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: w, height: h)

                Canvas { ctx, size in
                    let sw = size.width
                    let sh = size.height

                    func draw(_ rects: [CGRect], color: Color, lineWidth: CGFloat) {
                        for r in rects {
                            // Vision coords: origin bottom-left, y increases upward
                            let display = CGRect(
                                x: r.minX * sw,
                                y: (1 - r.maxY) * sh,
                                width: r.width * sw,
                                height: r.height * sh
                            )
                            ctx.stroke(Path(display), with: .color(color), lineWidth: lineWidth)
                            // Corner ticks
                            let tick: CGFloat = min(display.width, display.height) * 0.2
                            let corners: [(CGPoint, CGPoint, CGPoint)] = [
                                (CGPoint(x: display.minX, y: display.minY + tick),
                                 CGPoint(x: display.minX, y: display.minY),
                                 CGPoint(x: display.minX + tick, y: display.minY)),
                                (CGPoint(x: display.maxX - tick, y: display.minY),
                                 CGPoint(x: display.maxX, y: display.minY),
                                 CGPoint(x: display.maxX, y: display.minY + tick)),
                                (CGPoint(x: display.minX, y: display.maxY - tick),
                                 CGPoint(x: display.minX, y: display.maxY),
                                 CGPoint(x: display.minX + tick, y: display.maxY)),
                                (CGPoint(x: display.maxX - tick, y: display.maxY),
                                 CGPoint(x: display.maxX, y: display.maxY),
                                 CGPoint(x: display.maxX, y: display.maxY - tick))
                            ]
                            for (a, b, c) in corners {
                                var p = Path(); p.move(to: a); p.addLine(to: b); p.addLine(to: c)
                                ctx.stroke(p, with: .color(color), lineWidth: lineWidth + 1)
                            }
                        }
                    }

                    draw(unmatchedRects, color: .yellow, lineWidth: 1.5)
                    draw(matchedRects, color: .green, lineWidth: 2.5)
                }
            }
        }
    }
}

// MARK: - Realtime Face Detection Window

struct RealtimeFaceDetectionContent: View {
    @ObservedObject var model: PersonFinderModel
    let initialJobID: UUID?
    @State private var selectedJobID: UUID?

    init(model: PersonFinderModel, initialJobID: UUID? = nil) {
        self.model = model
        self.initialJobID = initialJobID
        _selectedJobID = State(initialValue: initialJobID)
    }

    private var jobs: [ScanJob] { model.jobs }

    /// Resolve which job to display. Honor the user's explicit pick always.
    /// Otherwise auto-pick a scanning job.
    private var activeJob: ScanJob? {
        if let sel = selectedJobID,
           let j = jobs.first(where: { $0.id == sel }) {
            return j
        }
        return jobs.first(where: { $0.status == .scanning })
            ?? jobs.first(where: { $0.status.isActive })
            ?? jobs.first
    }

    var body: some View {
        // NOTE: The parent only re-renders when @State (selectedJobID) changes.
        // To get live frame updates, the active job must be observed via
        // @ObservedObject in a child view — that's ActiveJobFaceDetectView below.
        Group {
            if let job = activeJob {
                ActiveJobFaceDetectView(
                    job: job,
                    jobs: jobs,
                    selectedJobID: $selectedJobID,
                    fallbackEngineTitle: model.settings.recognitionEngine.title,
                    fallbackPersonName: model.settings.personName
                )
            } else {
                VStack(spacing: 0) {
                    ZStack {
                        Color.black
                        VStack(spacing: 12) {
                            Image(systemName: "face.dashed")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.5))
                            if jobs.contains(where: { $0.status.isActive }) {
                                ProgressView().colorScheme(.dark)
                                Text("Waiting for frames...")
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Start a scan to see realtime face detection")
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .aspectRatio(16/9, contentMode: .fit)
                }
            }
        }
        .frame(minWidth: 800, minHeight: 520)
    }
}

/// Inner view that owns an @ObservedObject reference to the active ScanJob, so
/// SwiftUI re-renders when liveFrame / status / counters mutate. The outer
/// RealtimeFaceDetectionContent does NOT observe the jobs (it just holds a
/// `let [ScanJob]`), which is why we need this child wrapper.
private struct ActiveJobFaceDetectView: View {
    @ObservedObject var job: ScanJob
    let jobs: [ScanJob]
    @Binding var selectedJobID: UUID?
    let fallbackEngineTitle: String
    let fallbackPersonName: String

    private var personName: String { job.assignedProfile?.name ?? fallbackPersonName }
    private var engineTitle: String {
        if let eng = job.assignedProfile?.engine, let re = RecognitionEngine(rawValue: eng) {
            return re.title
        }
        return fallbackEngineTitle
    }

    var body: some View {
        VStack(spacing: 0) {
            // Video frame area
            ZStack {
                Color.black

                if job.status == .done || job.status == .extracting {
                    // Scan finished — clear the frame and show completion message
                    VStack(spacing: 14) {
                        Image(systemName: job.status == .extracting ? "scissors" : "checkmark.circle")
                            .font(.system(size: 56))
                            .foregroundStyle(job.status == .extracting ? .orange : .green)

                        if job.status == .extracting {
                            Text("Generating Clips")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                            if !personName.isEmpty {
                                Text("for \(personName)")
                                    .font(.system(size: 18, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.8))
                            }
                            ProgressView()
                                .colorScheme(.dark)
                                .scaleEffect(1.2)
                        } else {
                            Text("Search Complete")
                                .font(.system(size: 24, weight: .semibold))
                                .foregroundStyle(.white)
                            if !personName.isEmpty {
                                Text(personName)
                                    .font(.system(size: 20, weight: .medium))
                                    .foregroundStyle(.white.opacity(0.85))
                            }
                            Text(engineTitle)
                                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.cyan)
                                .padding(.top, -6)
                        }

                        // Stats grid
                        HStack(spacing: 24) {
                            VStack(spacing: 2) {
                                Text("\(job.videosScanned)")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                Text("videos scanned")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            VStack(spacing: 2) {
                                Text("\(job.videosWithHits)")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(job.videosWithHits > 0 ? .green : .white)
                                Text("with matches")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            VStack(spacing: 2) {
                                Text("\(job.clipsFound)")
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(job.clipsFound > 0 ? .green : .white)
                                Text("clips found")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                            if job.presenceSecs > 0 {
                                VStack(spacing: 2) {
                                    Text(formatElapsed(job.presenceSecs))
                                        .font(.system(size: 20, weight: .bold, design: .monospaced))
                                        .foregroundStyle(.green)
                                    Text("presence")
                                        .font(.system(size: 12))
                                        .foregroundStyle(.white.opacity(0.5))
                                }
                            }
                            VStack(spacing: 2) {
                                Text(formatElapsed(job.elapsedSecs))
                                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                                    .foregroundStyle(.white)
                                Text("elapsed")
                                    .font(.system(size: 12))
                                    .foregroundStyle(.white.opacity(0.5))
                            }
                        }
                        .padding(.top, 4)

                        // Volume path
                        let vol = (job.searchPath as NSString).lastPathComponent
                        if !vol.isEmpty {
                            Text(vol)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.4))
                                .padding(.top, 2)
                        }
                    }
                } else if let frame = job.liveFrame {
                    LiveFramePreview(
                        frame: frame,
                        matchedRects: job.liveMatchedRects,
                        unmatchedRects: job.liveUnmatchedRects
                    )
                    .overlay(alignment: .topLeading) {
                        FaceDetectHUD(job: job)
                            .padding(10)
                    }
                    .overlay(alignment: .topTrailing) {
                        FaceDetectLegend(engineTitle: engineTitle, personName: personName)
                            .padding(10)
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "face.dashed")
                            .font(.system(size: 48))
                            .foregroundStyle(.secondary.opacity(0.5))
                        ProgressView().colorScheme(.dark)
                        Text("Waiting for frames...")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .aspectRatio(16/9, contentMode: .fit)

            // Display Rate toolbar
            if job.status == .scanning {
                HStack(spacing: 10) {
                    Text("Display Rate")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.secondary)
                    Slider(value: Binding(
                        get: { Double(job.previewRate) },
                        set: { job.previewRate = max(1, Int($0)) }
                    ), in: 1...10, step: 1)
                        .frame(width: 160)
                    Text("\(job.previewRate)")
                        .font(.system(size: 16, design: .monospaced))
                        .frame(width: 24)
                    Text(job.previewRate == 1 ? "every frame" : "every \(job.previewRate) frames")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .background(Color(NSColor.controlBackgroundColor))
            }

            // Bottom status bar
            HStack(spacing: 12) {
                if jobs.count > 1 {
                    Picker("Job", selection: Binding(
                        get: { selectedJobID ?? job.id },
                        set: { selectedJobID = $0 }
                    )) {
                        ForEach(jobs) { j in
                            let vol = (j.searchPath as NSString).lastPathComponent
                            let person = j.assignedProfile?.name
                            let status = j.status == .done ? " [Done]" :
                                         j.status == .scanning ? " [Scanning]" :
                                         j.status.isActive ? " [Active]" : ""
                            Text((person.map { "\($0) — \(vol)" } ?? vol) + status)
                                .font(.system(size: 14))
                                .tag(j.id)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 350)
                }

                Circle()
                    .fill(job.status == .scanning ? Color.green :
                          job.status == .done ? Color.green.opacity(0.5) : Color.secondary)
                    .frame(width: 12, height: 12)

                // Person being searched
                if !personName.isEmpty {
                    Text(personName)
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.primary)
                }

                Text(job.status.label)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)

                if !job.currentFile.isEmpty {
                    Text(job.currentFile)
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }

                Spacer()
                if job.videosTotal > 0 {
                    Text("\(job.videosScanned)/\(job.videosTotal) videos")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Text("\(job.videosWithHits) match(es)")
                        .font(.system(size: 14, design: .monospaced))
                        .foregroundStyle(job.videosWithHits > 0 ? .green : .secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color(NSColor.windowBackgroundColor))
        }
        // When the displayed job goes inactive, nudge the parent to re-evaluate
        // its computed activeJob (e.g. another job is now scanning).
        .onChange(of: job.status) { _, newStatus in
            if !newStatus.isActive {
                if let next = jobs.first(where: { $0.status == .scanning })
                    ?? jobs.first(where: { $0.status.isActive }) {
                    selectedJobID = next.id
                }
            }
        }
    }
}

/// Floating HUD showing live detection stats — compact single-line top-left badge
/// plus key stats below.
private struct FaceDetectHUD: View {
    @ObservedObject var job: ScanJob

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "circle.fill")
                    .font(.system(size: 7))
                    .foregroundColor(.red)
                Text("LIVE")
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.red)
                if job.videosTotal > 0 {
                    Text("\(job.videosScanned)/\(job.videosTotal)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
                Text(pfFormatDuration(job.elapsedSecs))
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(.white.opacity(0.6))
            }
            HStack(spacing: 10) {
                Text("Hits \(job.videosWithHits)")
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundColor(job.videosWithHits > 0 ? .green : .white.opacity(0.7))
                if job.bestDist < .greatestFiniteMagnitude {
                    Text(String(format: "Best %.3f", job.bestDist))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(.white.opacity(0.8))
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.55))
        .cornerRadius(6)
    }
}

/// Compact engine + legend badge — top-right corner.
private struct FaceDetectLegend: View {
    let engineTitle: String
    var personName: String = ""

    var body: some View {
        HStack(spacing: 8) {
            if !personName.isEmpty {
                Text(personName)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.white)
            }
            Text(engineTitle)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundColor(.cyan)
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(.green)
                    .frame(width: 10, height: 10)
                Text("Match")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
            }
            HStack(spacing: 4) {
                RoundedRectangle(cornerRadius: 2).fill(.yellow)
                    .frame(width: 10, height: 10)
                Text("Face")
                    .font(.system(size: 11))
                    .foregroundColor(.white.opacity(0.8))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.black.opacity(0.5))
        .cornerRadius(6)
    }
}

@MainActor
class PreviewWindowController {
    static let shared = PreviewWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(model: PersonFinderModel, focusJobID: UUID? = nil) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        close()

        let content = RealtimeFaceDetectionContent(model: model, initialJobID: focusJobID)
        let hosting = NSHostingView(rootView: content)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // CRITICAL: NSWindow defaults to isReleasedWhenClosed=true, which
        // double-releases the window (AppKit releases on close, ARC releases
        // when our `window` ref drops). That leaves `self.window` pointing
        // at freed memory and the next show() crashes inside objc_retain.
        w.isReleasedWhenClosed = false
        w.title = "Realtime Face Detection"
        w.contentView = hosting
        w.setFrameAutosaveName("RealtimeFaceDetectV2")
        w.center()
        w.makeKeyAndOrderFront(nil)
        window = w
        // When the user closes via the red button, drop our reference so the
        // next show() builds a fresh window instead of trying to reopen one.
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

// MARK: - Job Console Window

/// Floating console window with a per-job picker. Mirrors the Realtime
/// Face Detection window pattern: outer view holds the picker selection;
/// an inner view observes the selected ScanJob so log appends repaint live.
struct JobConsoleContent: View {
    @ObservedObject var model: PersonFinderModel
    let initialJobID: UUID?
    @State private var selectedJobID: UUID?

    init(model: PersonFinderModel, initialJobID: UUID? = nil) {
        self.model = model
        self.initialJobID = initialJobID
        _selectedJobID = State(initialValue: initialJobID)
    }

    private var jobs: [ScanJob] { model.jobs }

    /// Auto-pick a sensible default if the user hasn't chosen, preferring
    /// an actively scanning job.
    private var resolvedJob: ScanJob? {
        if let sel = selectedJobID,
           let j = jobs.first(where: { $0.id == sel }) {
            return j
        }
        return jobs.first(where: { $0.status == .scanning })
            ?? jobs.first(where: { $0.status.isActive })
            ?? jobs.first
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "terminal")
                    .foregroundColor(.secondary)
                Text("Job:")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.secondary)
                Picker("", selection: $selectedJobID) {
                    ForEach(jobs) { job in
                        Text(jobMenuLabel(job))
                            .tag(Optional(job.id))
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(maxWidth: 420)

                Spacer()

                if let job = resolvedJob, job.status.isActive {
                    ProgressView().scaleEffect(0.6)
                    Text(job.status.label)
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }

                if let job = resolvedJob {
                    Text("\(job.consoleLines.count) lines")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                    Button("Clear") {
                        job.consoleLines.removeAll()
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()

            if let job = resolvedJob {
                JobConsoleBody(job: job)
            } else {
                ZStack {
                    Color(NSColor.textBackgroundColor)
                    Text("No jobs yet — add a scan target to see console output.")
                        .foregroundColor(.secondary)
                }
            }
        }
        .frame(minWidth: 600, idealWidth: 820, minHeight: 320, idealHeight: 480)
    }

    private func jobMenuLabel(_ job: ScanJob) -> String {
        let name = (job.searchPath as NSString).lastPathComponent
        let trimmed = name.isEmpty ? job.searchPath : name
        return "\(trimmed)  —  \(job.status.label)"
    }
}

/// Inner view observes the active ScanJob so SwiftUI re-renders when
/// consoleLines mutates. The outer JobConsoleContent only owns the picker
/// state and does not observe individual jobs.
private struct JobConsoleBody: View {
    @ObservedObject var job: ScanJob

    var body: some View {
        ConsoleView(lines: job.consoleLines)
            .background(Color(NSColor.textBackgroundColor))
    }
}

@MainActor
class JobConsoleWindowController {
    static let shared = JobConsoleWindowController()
    private var window: NSWindow?
    private var closeObserver: NSObjectProtocol?

    func show(model: PersonFinderModel, focusJobID: UUID? = nil) {
        if let w = window, w.isVisible {
            w.makeKeyAndOrderFront(nil)
            return
        }
        close()

        let content = JobConsoleContent(model: model, initialJobID: focusJobID)
        let hosting = NSHostingView(rootView: content)
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.isReleasedWhenClosed = false  // see PreviewWindowController for rationale
        w.title = "Face Detection Console"
        w.contentView = hosting
        w.setFrameAutosaveName("JobConsoleV1")
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

// MARK: - Helpers

/// Format elapsed seconds as "1h 23m 45s" / "23m 45s" / "45s".
func formatElapsed(_ secs: Double) -> String {
    let t = Int(secs); let h = t/3600; let m = (t%3600)/60; let s = t%60
    return h > 0 ? "\(h)h \(m)m \(s)s" : m > 0 ? "\(m)m \(s)s" : "\(s)s"
}
