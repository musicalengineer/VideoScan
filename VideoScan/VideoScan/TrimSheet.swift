import AppKit
import SwiftUI

// MARK: - Trim Master sheet
//
// Presented via `.sheet(item:)` from the catalog row's "Trim Master…"
// item (never chained isPresented sheets — documented antipattern).
// Lets Rick pick the in/out points of a stream-copy trim with honest,
// codec-aware accuracy language, then hands the job to the Media File
// Operations window.
//
// NO AVKit here, deliberately: AVPlayer cannot decode FFV1/Matroska —
// the exact archival masters this feature exists for. All preview
// imagery comes from ffmpeg frame extraction via the existing
// `extractFramesForCaptioning` machinery (AVFoundation fast path with
// automatic ffmpeg fallback), reused rather than duplicated:
//   - a strip of 10 evenly-spaced thumbnails for orientation
//   - the exact frame AT each cut point, re-extracted (debounced,
//     cached) as the user types/nudges timecodes
//
// Memory budget (bounded, explicit): every extracted frame is
// downscaled to ≤ 480 px in the SAME off-main hop that decoded it, so
// full-resolution frames never accumulate. Worst case in memory:
// 10 filmstrip thumbs + 2 point previews + 48 cache entries ≈ 60 images
// × ~0.6 MB (480×360 BGRA) ≈ 36 MB, independent of source resolution
// or file size.
//
// Concurrency: `extractFramesForCaptioning` is `nonisolated async`,
// which in this repo's Approachable Concurrency configuration runs on
// the CALLER's actor — calling it straight from this @MainActor view
// would decode video on the main thread (the documented trap). The
// `@concurrent` static hop below forces the global executor; only the
// finished CGImage (Sendable) crosses back.

// MARK: - Request

/// A pending sheet presentation. Fresh ID per menu click (same shape as
/// TranscodeRequest / CleanupRequest). The destination is computed ONCE
/// here and handed to BOTH the sheet (display) and the job (planned
/// output), so the sheet never promises a name the job doesn't plan to
/// use; the job's publish step re-uniquifies as the last word.
struct TrimRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
    /// Planned `<stem>_trimmed.<same ext>` beside the original.
    let destinationURL: URL
    /// By-name accuracy class (the banner's starting point — the
    /// keyframe probe can downgrade it once it completes).
    let codecClass: TrimCodecClass

    @MainActor
    init(record: VideoRecord) {
        self.record = record
        self.destinationURL = TrimJob.trimmedOutputURL(forSourcePath: record.fullPath)
        self.codecClass = TrimCodecClassifier.classify(videoCodec: record.videoCodec)
    }
}

// MARK: - Bounded thumbnail cache

/// Insertion-order (FIFO) bounded cache for extracted point-preview
/// frames, keyed by timecode milliseconds. Deliberately tiny and pure —
/// the checklist's "cache must be bounded" test drives it directly.
/// (≈ a C++ std::unordered_map + std::deque eviction queue.)
final class TrimThumbnailCache<Value> {
    let capacity: Int
    private var storage: [Int64: Value] = [:]
    private var order: [Int64] = []

    init(capacity: Int = 48) {
        self.capacity = max(1, capacity)
    }

    var count: Int { storage.count }

    func value(forMilliseconds key: Int64) -> Value? {
        storage[key]
    }

    func insert(_ value: Value, forMilliseconds key: Int64) {
        if storage[key] == nil {
            order.append(key)
        }
        storage[key] = value
        while storage.count > capacity, let oldest = order.first {
            order.removeFirst()
            storage.removeValue(forKey: oldest)
        }
    }

    /// Stable key for a timecode: milliseconds, so 2.0004 and 2.0 hit
    /// the same entry (well inside any codec's frame duration).
    static func key(forSeconds seconds: Double) -> Int64 {
        Int64((seconds * 1000).rounded())
    }
}

// MARK: - Sheet

struct TrimSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    // Forwarded to MediaFileOperationsCenter when the trim job starts
    // (same intentional forwarding as TranscodeSheet / CleanupSheet).
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: TrimRequest

    // Cut points (seconds) + their editable text mirrors.
    @State private var inSeconds: Double = 0
    @State private var outSeconds: Double = 0
    @State private var inText: String = ""
    @State private var outText: String = ""

    // Preview imagery.
    @State private var filmstrip: [CGImage?] = Array(repeating: nil, count: TrimSheet.filmstripCount)
    @State private var inPreview: CGImage?
    @State private var outPreview: CGImage?

    // Keyframe probe verdict: nil = pending/undecidable (keep the
    // by-name classification), false = downgrade the accuracy claim.
    @State private var probeAllKeyframes: Bool?

    // Debounce tasks per cut point + the bounded frame cache.
    @State private var inPreviewTask: Task<Void, Never>?
    @State private var outPreviewTask: Task<Void, Never>?
    @State private var cache = TrimThumbnailCache<CGImage>()

    static let filmstripCount = 10
    private static let previewMaxDimension: CGFloat = 480

    private var duration: Double { max(0, request.record.durationSeconds) }

    /// One frame at the source's rate — the ±1-frame nudge step.
    private var frameStep: Double {
        1.0 / (TrimFrameRate.fps(fromDisplayString: request.record.frameRate) ?? 30.0)
    }

    /// Frame-accuracy claim = by-name intra AND the probe didn't say
    /// otherwise (default-GOP FFV1 probes false and downgrades honestly).
    private var isFrameAccurate: Bool {
        request.codecClass.claimsFrameAccuracy && probeAllKeyframes != false
    }

    private var rangeError: String? {
        do {
            try TrimPlan.validate(range: TrimRange(inSeconds: inSeconds, outSeconds: outSeconds),
                                  sourceDuration: duration)
            return nil
        } catch let err as TrimPlanError {
            return err.friendlyMessage
        } catch {
            return error.localizedDescription
        }
    }

    private var keptDuration: Double { max(0, outSeconds - inSeconds) }

    private var estimatedBytes: Int64 {
        TrimPlan.estimatedOutputBytes(sourceBytes: request.record.sizeBytes,
                                      sourceDuration: duration,
                                      range: TrimRange(inSeconds: inSeconds, outSeconds: outSeconds))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Trim Master")
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("trimSheet.title")

            Text(request.record.filename)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            accuracyBanner

            filmstripView

            HStack(alignment: .top, spacing: 14) {
                cutPointBox(title: "Keep from", isInPoint: true)
                cutPointBox(title: "Keep until", isInPoint: false)
            }

            summaryBox

            if let rangeError {
                Label(rangeError, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundColor(.red)
                    .accessibilityIdentifier("trimSheet.rangeError")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Trim") { startTrim() }
                    .buttonStyle(.borderedProminent)
                    .disabled(rangeError != nil)
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier("trimSheet.trimButton")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 680)
        .onAppear { initializePoints() }
        .task { await loadFilmstrip() }
        .task { await runKeyframeProbe() }
        .onDisappear {
            inPreviewTask?.cancel()
            outPreviewTask?.cancel()
        }
    }

    // MARK: Banner — the honest accuracy contract

    @ViewBuilder
    private var accuracyBanner: some View {
        if isFrameAccurate {
            Label {
                Text("Frame-accurate lossless trim (\(request.record.videoCodec.uppercased())) — the copy is cut exactly where you say, with zero quality loss.")
                    .font(.callout)
            } icon: {
                Image(systemName: "checkmark.seal.fill")
                    .foregroundColor(.green)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("trimSheet.accuracy.frameAccurate")
        } else {
            Label {
                Text("No quality is lost, but cut points will snap to the nearest keyframe — the trimmed copy can start up to a few seconds early. Nothing you asked to keep is ever dropped.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(.orange)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 6))
            .accessibilityIdentifier("trimSheet.accuracy.keyframeSnap")
        }
    }

    // MARK: Filmstrip

    private var filmstripView: some View {
        HStack(spacing: 2) {
            ForEach(0..<Self.filmstripCount, id: \.self) { index in
                Group {
                    if let cg = filmstrip[index] {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } else {
                        Rectangle()
                            .fill(Color.black.opacity(0.25))
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 60, height: 40)
                .clipped()
                .help(TrimTimecode.format(filmstripTimestamp(index)))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityIdentifier("trimSheet.filmstrip")
    }

    private func filmstripTimestamp(_ index: Int) -> Double {
        guard duration > 0 else { return 0 }
        // Centered sampling: (i + 0.5)/N — never the black first frame,
        // never past the end.
        return duration * (Double(index) + 0.5) / Double(Self.filmstripCount)
    }

    // MARK: Cut-point editor

    @ViewBuilder
    private func cutPointBox(title: String, isInPoint: Bool) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)

                // The exact frame at this timecode (extracted on demand,
                // debounced, cached).
                Group {
                    if let cg = isInPoint ? inPreview : outPreview {
                        Image(decorative: cg, scale: 1)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle()
                            .fill(Color.black.opacity(0.25))
                            .overlay(ProgressView().controlSize(.small))
                    }
                }
                .frame(width: 264, height: 176)
                .clipped()
                .cornerRadius(4)

                TextField("HH:MM:SS.mmm", text: isInPoint ? $inText : $outText)
                    .font(.body.monospaced())
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 150)
                    .onSubmit { commitText(isInPoint: isInPoint) }
                    .accessibilityIdentifier(isInPoint ? "trimSheet.inField" : "trimSheet.outField")

                HStack(spacing: 4) {
                    nudgeButton("−10s", -10, isInPoint: isInPoint)
                    nudgeButton("−1s", -1, isInPoint: isInPoint)
                    nudgeButton("−1f", -frameStep, isInPoint: isInPoint)
                    nudgeButton("+1f", frameStep, isInPoint: isInPoint)
                    nudgeButton("+1s", 1, isInPoint: isInPoint)
                    nudgeButton("+10s", 10, isInPoint: isInPoint)
                }
            }
            .padding(4)
        }
    }

    private func nudgeButton(_ label: String, _ delta: Double, isInPoint: Bool) -> some View {
        Button(label) {
            let current = isInPoint ? inSeconds : outSeconds
            setPoint(max(0, min(duration > 0 ? duration : .greatestFiniteMagnitude,
                                current + delta)),
                     isInPoint: isInPoint)
        }
        .font(.system(size: 11, design: .monospaced))
        .controlSize(.small)
    }

    // MARK: Summary

    private var summaryBox: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Label {
                    Text("Keeps \(TrimTimecode.format(keptDuration)) of \(TrimTimecode.format(duration)) — about \(Formatting.humanSize(estimatedBytes))")
                        .font(.body)
                } icon: {
                    Image(systemName: "scissors")
                        .foregroundColor(.accentColor)
                }
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your original file is never changed. The trimmed copy will be saved next to it as:")
                            .font(.body)
                        Text(request.destinationURL.lastPathComponent)
                            .font(.body.monospaced())
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                } icon: {
                    Image(systemName: "lock.shield.fill")
                        .foregroundColor(.green)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        }
    }

    // MARK: Point mutation + debounced preview

    private func initializePoints() {
        inSeconds = 0
        outSeconds = duration
        inText = TrimTimecode.format(inSeconds)
        outText = TrimTimecode.format(outSeconds)
        schedulePreview(isInPoint: true)
        schedulePreview(isInPoint: false)
    }

    private func commitText(isInPoint: Bool) {
        let text = isInPoint ? inText : outText
        guard let parsed = TrimTimecode.parse(text) else {
            // Unparseable → restore the last good value.
            if isInPoint { inText = TrimTimecode.format(inSeconds) } else { outText = TrimTimecode.format(outSeconds) }
            return
        }
        setPoint(parsed, isInPoint: isInPoint)
    }

    private func setPoint(_ seconds: Double, isInPoint: Bool) {
        if isInPoint {
            inSeconds = seconds
            inText = TrimTimecode.format(seconds)
        } else {
            outSeconds = seconds
            outText = TrimTimecode.format(seconds)
        }
        schedulePreview(isInPoint: isInPoint)
    }

    /// Debounced (250 ms) + cached frame extraction for one cut point.
    /// Rapid nudge clicks cancel the pending extraction; only the
    /// settled timecode costs an ffmpeg/AVF decode.
    private func schedulePreview(isInPoint: Bool) {
        let seconds = isInPoint ? inSeconds : outSeconds
        let key = TrimThumbnailCache<CGImage>.key(forSeconds: seconds)
        if let cached = cache.value(forMilliseconds: key) {
            if isInPoint { inPreview = cached } else { outPreview = cached }
            return
        }
        if isInPoint { inPreview = nil } else { outPreview = nil }

        let url = URL(fileURLWithPath: request.record.fullPath)
        let task = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            let frame = await Self.extractFrame(url: url, at: seconds,
                                                maxDimension: Self.previewMaxDimension)
            guard !Task.isCancelled, let frame else { return }
            cache.insert(frame, forMilliseconds: key)
            // Apply only if the point hasn't moved on while we decoded.
            let current = isInPoint ? inSeconds : outSeconds
            guard TrimThumbnailCache<CGImage>.key(forSeconds: current) == key else { return }
            if isInPoint { inPreview = frame } else { outPreview = frame }
        }
        if isInPoint {
            inPreviewTask?.cancel()
            inPreviewTask = task
        } else {
            outPreviewTask?.cancel()
            outPreviewTask = task
        }
    }

    // MARK: Filmstrip + probe loads

    private func loadFilmstrip() async {
        let url = URL(fileURLWithPath: request.record.fullPath)
        let stamps = (0..<Self.filmstripCount).map { filmstripTimestamp($0) }
        let frames = await Self.extractFrames(url: url, at: stamps, maxDimension: 240)
        guard !Task.isCancelled else { return }
        filmstrip = frames
    }

    /// Cheap honesty check: read the flags of the first 60 video packets
    /// (a few MB even on a 100 GB file). Any non-keyframe ⇒ the by-name
    /// intra claim is wrong for THIS file (default-GOP FFV1) ⇒ the
    /// banner downgrades to the keyframe-snap warning.
    private func runKeyframeProbe() async {
        guard request.codecClass.claimsFrameAccuracy else { return }
        let ffprobe = ToolLocator.ffprobePath
        guard FileManager.default.isExecutableFile(atPath: ffprobe) else { return }
        let result = await ProcessRunner.runProcess(
            executable: ffprobe,
            arguments: ["-v", "error",
                        "-select_streams", "v:0",
                        "-read_intervals", "%+#60",
                        "-show_entries", "packet=pts_time,flags",
                        "-of", "csv=p=0",
                        request.record.fullPath],
            deadlineSeconds: 30)
        guard result.exitCode == 0, let stdout = result.stdout else { return }
        probeAllKeyframes = TrimKeyframeProbe.allSampledPacketsAreKeyframes(csv: stdout)
    }

    // MARK: Off-main frame extraction

    /// Decode + downscale entirely off the main actor. `@concurrent`
    /// forces the global executor (the `nonisolated async` helper would
    /// otherwise run on the CALLER's actor — the documented repo trap);
    /// only the small Sendable CGImage crosses back.
    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func extractFrame(url: URL,
                                     at seconds: Double,
                                     maxDimension: CGFloat) async -> CGImage? {
        guard let results = try? await extractFramesForCaptioning(from: url,
                                                                  atTimestamps: [seconds]),
              case .success(let cg) = results.first?.frame else { return nil }
        return downscale(cg, maxDimension: maxDimension)
    }

    #if compiler(>=6.2)
    @concurrent
    #endif
    private static func extractFrames(url: URL,
                                      at timestamps: [Double],
                                      maxDimension: CGFloat) async -> [CGImage?] {
        guard let results = try? await extractFramesForCaptioning(from: url,
                                                                  atTimestamps: timestamps) else {
            return Array(repeating: nil, count: timestamps.count)
        }
        return results.map { entry in
            if case .success(let cg) = entry.frame {
                return downscale(cg, maxDimension: maxDimension)
            }
            return nil
        }
    }

    /// Downscale in the decoding hop so full-resolution frames never
    /// reach the sheet's state — this is what bounds the memory budget
    /// in the file header. No-op when already small.
    nonisolated private static func downscale(_ image: CGImage,
                                              maxDimension: CGFloat) -> CGImage {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = min(1, maxDimension / max(w, h))
        guard scale < 1 else { return image }
        let outW = max(1, Int(w * scale))
        let outH = max(1, Int(h * scale))
        guard let ctx = CGContext(data: nil, width: outW, height: outH,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { return image }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: outW, height: outH))
        return ctx.makeImage() ?? image
    }

    // MARK: Start

    private func startTrim() {
        guard rangeError == nil else { return }
        fileOpsCenter.startTrim(record: request.record,
                                range: TrimRange(inSeconds: inSeconds, outSeconds: outSeconds),
                                model: model,
                                plannedOutput: request.destinationURL)
        dismiss()
        // Same handoff TranscodeSheet/CleanupSheet use: open the
        // operations window (progress + Cancel live there) after the
        // sheet's dismissal animation starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: "combine")
        }
    }
}
