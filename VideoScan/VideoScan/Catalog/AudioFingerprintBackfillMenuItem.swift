// AudioFingerprintBackfillMenuItem.swift
// Catalog ▸ "Fingerprint Sound…" (Rick 2026-10-14) — the menu item opens a
// small confirm sheet (AudioFingerprintBackfillSheet, presented by
// ContentView through `showFingerprintSoundSheet`); Start there runs the
// whole-catalog sound-fingerprint backfill as a Media File Operation (the
// MFO window comes forward via `startedByUser`). Never starts on its own.
// Safe to stop: a stamped record is skipped next time, so running again
// continues where it stopped — no resume file.
//
// The sheet computes the plan ONCE on appear (O(records), not in the body)
// and shows: how many files need a look, how many GB will be read, that
// archived files go first, where the fingerprints are kept, Start.

import SwiftUI

struct AudioFingerprintBackfillMenuItem: View {
    @ObservedObject var model: VideoScanModel

    var body: some View {
        Button("Fingerprint Sound…") {
            model.showFingerprintSoundSheet = true
        }
        .disabled(model.isReadOnly)
        .help("Listen to every catalog file once and keep a small fingerprint of its sound, so copies and clips of the same recording can be told apart later. Archived files first, one reader per drive. Read only on media: nothing is moved, renamed or deleted. Safe to stop: running it again continues where it stopped.")
    }
}

struct AudioFingerprintBackfillSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    /// The non-observing center reference (CatalogView's pattern): this
    /// sheet only starts a job.
    @Environment(\.mediaFileOperationsCenterReference) private var center

    /// The one-shot plan, filled on appear. nil = not yet computed.
    @State private var plan: AudioFingerprintBackfillPlan?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Fingerprint Sound")
                .font(.title2.weight(.semibold))
            if let plan {
                Text(Self.headline(plan))
                    .font(.system(size: 13))
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 4) {
                    Label(Self.archiveLine(plan), systemImage: "archivebox")
                    Label("Each file is read once by ffmpeg; the fingerprint is a few hundred KB at most. Nothing is moved, renamed, deleted or written beside your files.",
                          systemImage: "lock.shield")
                    Label("Fingerprints are kept in \(model.audioFingerprintSidecarDirectory.appendingPathComponent(AudioFingerprintStore.fileName).path); each catalog entry gets a small stamp.",
                          systemImage: "internaldrive")
                    Label("Safe to stop at any time — running it again continues where it stopped.", systemImage: "arrow.clockwise")
                    if plan.noDigest > 0 {
                        Label("\(plan.noDigest.formatted()) file(s) have never been hashed by a scan and are left for a later run.",
                              systemImage: "questionmark.circle")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .labelStyle(.titleAndIcon)
                .fixedSize(horizontal: false, vertical: true)
            } else {
                ProgressView("Counting…")
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Start") {
                    _ = center?.startedByUser { $0.startAudioFingerprintBackfill(model: model) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(plan == nil || plan?.fileCount == 0)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { plan = model.audioFingerprintBackfillPlan() }
        .accessibilityIdentifier("sheet.fingerprintSound")
    }

    /// "3,210 files need a sound fingerprint — about 2.4 TB to read. 6,940 are already done."
    static func headline(_ plan: AudioFingerprintBackfillPlan) -> String {
        guard plan.fileCount > 0 else {
            return "Every file already has a sound fingerprint (\(plan.alreadyStamped.formatted()) done). Nothing to do."
        }
        var line = "\(plan.fileCount.formatted()) file\(plan.fileCount == 1 ? "" : "s") need a sound fingerprint — about "
            + "\(MediaBytes.display(plan.bytes)) to read."
        if plan.alreadyStamped > 0 { line += " \(plan.alreadyStamped.formatted()) are already done." }
        return line
    }

    /// "412 archived files go first, then the other 2,798 — drive by drive."
    static func archiveLine(_ plan: AudioFingerprintBackfillPlan) -> String {
        let rest = plan.fileCount - plan.archivedCount
        return "\(plan.archivedCount.formatted()) archived file\(plan.archivedCount == 1 ? " goes" : "s go") first, then the other "
            + "\(rest.formatted()) — drive by drive, one reader per drive."
    }
}
