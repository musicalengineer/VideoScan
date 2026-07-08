import SwiftUI

// MARK: - Clean Up Video confirmation sheet
//
// Presented via `.sheet(item:)` from the catalog row's "Clean Up Video"
// submenu (NEVER chained isPresented sheets — documented antipattern).
// Shows, in plain family language: what the recipe does step by step,
// that the original is never changed, and exactly where the cleaned copy
// will go. "Clean Up" starts a CleanupJob in the Media File Operations
// window, which owns the determinate progress bar + Cancel.
//
// Text sizes are deliberately generous (.title2/.body, nothing smaller
// than .callout) — large readable text is an accessibility need here,
// not polish.

/// A pending sheet presentation. Fresh ID per menu click so choosing a
/// different recipe while a prior sheet is dismissing creates a new
/// presentation cycle (same shape as TranscodeRequest).
///
/// m3: the destination is computed ONCE here and handed to BOTH the sheet
/// (display) and the job (planned output), so the sheet never promises a
/// name the job doesn't use. The job's publish step re-uniquifies as the
/// last word if a collision appears mid-render.
struct CleanupRequest: Identifiable {
    let id = UUID()
    let record: VideoRecord
    let recipe: CleanupRecipe
    /// Planned `<stem>_cleaned.mov` beside the original, uniquified
    /// against files existing right now.
    let destinationURL: URL

    /// @MainActor on the INIT only (the stored lets stay nonisolated so
    /// the Identifiable conformance doesn't cross actors): construction
    /// reads the record and lists the destination directory once.
    @MainActor
    init(record: VideoRecord, recipe: CleanupRecipe) {
        self.record = record
        self.recipe = recipe
        self.destinationURL = CleanupJob.cleanedOutputURL(
            forSourcePath: record.fullPath)
    }
}

struct CleanupSheet: View {
    @EnvironmentObject private var fileOpsCenter: MediaFileOperationsCenter
    // Forwarded to MediaFileOperationsCenter when the cleanup job starts
    // (same intentional forwarding as TranscodeSheet).
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow

    let request: CleanupRequest

    /// Computed once in CleanupRequest (m3) — the same URL the job
    /// receives as its planned output.
    private var destinationURL: URL { request.destinationURL }

    /// Whether the deinterlace step will auto-skip (source already
    /// progressive) — surfaced so the step list is honest.
    private var deinterlaceSkipped: Bool {
        CleanupFFmpegEngine.isProgressive(fieldOrder: request.record.scanType)
    }

    /// M4: whether the source's audio codec is playback-safe to copy —
    /// drives the honest audio row below.
    private var audioWillBeCopied: Bool {
        CleanupFFmpegEngine.audioCopyAllowed(codec: request.record.audioCodec)
    }

    private var sourceHasAudio: Bool {
        request.record.streamType == .videoAndAudio
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(request.recipe.displayName)
                .font(.title2.weight(.semibold))
                .accessibilityIdentifier("cleanupSheet.title")

            Text(request.record.filename)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)

            Text(request.recipe.familyDescription)
                .font(.body)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    Text("What it will do")
                        .font(.headline)
                    ForEach(request.recipe.steps) { step in
                        stepRow(step)
                    }
                    if sourceHasAudio {
                        audioRow
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Label {
                        Text("Your original file is never changed.")
                            .font(.body.weight(.medium))
                    } icon: {
                        Image(systemName: "lock.shield.fill")
                            .foregroundColor(.green)
                    }
                    Label {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("The cleaned copy will be saved next to it as:")
                                .font(.body)
                            Text(destinationURL.lastPathComponent)
                                .font(.body.monospaced())
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    } icon: {
                        Image(systemName: "doc.badge.plus")
                            .foregroundColor(.accentColor)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Clean Up") { startCleanup() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.return)
                    .accessibilityIdentifier("cleanupSheet.cleanUpButton")
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 560)
    }

    @ViewBuilder
    private func stepRow(_ step: CleanupStep) -> some View {
        let skipped = step.kind == .deinterlace && deinterlaceSkipped
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: skipped ? "minus.circle" : "checkmark.circle.fill")
                .foregroundColor(skipped ? .secondary : .accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.familyLabel)
                    .font(.body)
                    .foregroundColor(skipped ? .secondary : .primary)
                if skipped {
                    Text("Skipped — this video has no comb lines to fix.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// M4: honest audio disposition. Copy for allowlisted playback-safe
    /// codecs; everything else is modernized to PCM so the cleaned copy
    /// plays everywhere (vorbis/opus would fail the .mov mux, QDM2-class
    /// codecs would mux silently but not play).
    private var audioRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: audioWillBeCopied
                  ? "speaker.wave.2.circle.fill"
                  : "speaker.wave.2.circle")
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(audioWillBeCopied
                     ? "Sound: kept exactly as it is"
                     : "Sound: audio will be modernized so it plays everywhere")
                    .font(.body)
                if !audioWillBeCopied {
                    Text("This tape's audio format is too old for today's players; the picture cleanup is unaffected.")
                        .font(.callout)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .accessibilityIdentifier("cleanupSheet.audioRow")
    }

    private func startCleanup() {
        fileOpsCenter.startCleanup(record: request.record,
                                   recipe: request.recipe,
                                   model: model,
                                   plannedOutput: request.destinationURL)
        dismiss()
        // Same handoff TranscodeSheet uses: open the operations window
        // (progress + Cancel live there) after the sheet's dismissal
        // animation starts.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            openWindow(id: "combine")
        }
    }
}
