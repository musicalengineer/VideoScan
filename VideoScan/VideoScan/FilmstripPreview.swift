// FilmstripPreview.swift
// Filmstrip preview for AVPlayer-unplayable formats (2026-07-27).
//
// The playback surface for the catalog preview pane's filmstrip mode:
// AVKit cannot decode Matroska/FFV1 — clicking play on those records
// used to construct an AVPlayer that showed the crossed-out play glyph.
// Now the play button (CatalogHelpers) routes ffmpegDirect records to
// VideoScanModel.requestFilmstrip, and this view renders the result:
// ~16 frames auto-playing at ~1.5 fps, with a scrubber, per-frame
// timestamp, and a badge explaining WHY it isn't real playback.
//
// Purely presentational — frames arrive fully generated/selected from
// the model's filmstripState. All state here is view-local playback
// state (current index, auto-play flag); the parent applies `.id(path)`
// so switching rows rebuilds the view and can never show a stale index
// into another row's frames.

import SwiftUI

struct FilmstripPreviewView: View {

    /// Post-selection frames, ordered by offset (never empty — the
    /// model publishes .ready only with frames; the guard below is
    /// belt-and-suspenders).
    let frames: [PreviewFilmstrip.Frame]
    /// ffprobe codec/container names for the explainer badge. Empty
    /// strings render as generic wording.
    let videoCodec: String
    let container: String

    /// ~1.5 fps auto-advance.
    static let frameIntervalSeconds: Double = 0.65

    // `@State` ≈ view-local members that survive SwiftUI re-creating
    // the (value-type) view struct on every render — the framework
    // owns the storage, keyed by view identity.
    @State private var index = 0
    @State private var isAutoPlaying = true

    private var safeIndex: Int {
        min(max(index, 0), frames.count - 1)
    }

    var body: some View {
        if frames.isEmpty {
            EmptyView()
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                Image(decorative: frames[safeIndex].image, scale: 1)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .cornerRadius(6)
                    .shadow(radius: 3)
                    .accessibilityLabel("Filmstrip frame \(safeIndex + 1) of \(frames.count)")

                Text(timestampLabel)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 4))
                    .padding(6)
            }

            Text(badgeText)
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundColor(.orange)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack(spacing: 8) {
                Button {
                    isAutoPlaying.toggle()
                } label: {
                    Image(systemName: isAutoPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
                .help(isAutoPlaying ? "Pause the filmstrip" : "Resume the filmstrip")

                Slider(
                    value: Binding(
                        get: { Double(safeIndex) },
                        set: { index = Int($0.rounded()) }
                    ),
                    in: 0...Double(max(frames.count - 1, 1)),
                    step: 1,
                    onEditingChanged: { editing in
                        // Grabbing the scrubber pauses auto-advance —
                        // fighting a moving thumb is miserable.
                        if editing { isAutoPlaying = false }
                    }
                )
                .controlSize(.small)
                .disabled(frames.count < 2)

                Text("\(safeIndex + 1)/\(frames.count)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .monospacedDigit()
            }
        }
        .frame(maxWidth: 480)
        // `.task(id:)` ≈ an RAII-scoped worker: started when the view
        // appears (or when `id` changes), CANCELLED automatically on
        // disappear / id change — no NSTimer to remember to invalidate.
        // Restarting on pause-toggle keeps the loop trivially simple.
        .task(id: isAutoPlaying) {
            guard isAutoPlaying, frames.count > 1 else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.frameIntervalSeconds))
                if Task.isCancelled { return }
                index = (safeIndex + 1) % frames.count
            }
        }
    }

    private var badgeText: String {
        let codecLabel = videoCodec.isEmpty ? "this format" : videoCodec
        let containerLabel = container.isEmpty ? "this container" : container
        return "FILMSTRIP PREVIEW — macOS can't play \(codecLabel) in \(containerLabel)"
    }

    /// Current frame's source timestamp. TrimTimecode's HH:MM:SS
    /// (rounded to whole seconds — millisecond noise means nothing at
    /// 1.5 fps), with the hour field dropped while it's zero so typical
    /// home videos read as MM:SS.
    private var timestampLabel: String {
        let formatted = TrimTimecode.format(frames[safeIndex].offsetSeconds.rounded())
        return formatted.hasPrefix("00:") ? String(formatted.dropFirst(3)) : formatted
    }
}
