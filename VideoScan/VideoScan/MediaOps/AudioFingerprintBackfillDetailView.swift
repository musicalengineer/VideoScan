// AudioFingerprintBackfillDetailView.swift
// Double-click detail for the "Fingerprint sound" MFO row: the running
// totals (files, GB read, landmarks, sidecar bytes, rate), one line per
// drive (N of M, reading / finished / disconnected), every file that could
// not be done with its reason, then the first files stamped (the job keeps
// at most AudioFingerprintBackfillJob.sampleCap). Pure presentation over the
// job's published arrays — no model access, no I/O, nothing O(catalog) in
// the body.

import SwiftUI

struct AudioFingerprintBackfillDetailView: View {
    @ObservedObject var job: AudioFingerprintBackfillJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(job.totals.line)
                .font(.system(size: 12, weight: .medium))
                .fixedSize(horizontal: false, vertical: true)
            ForEach(job.lanes) { laneRow($0) }
            if job.problems.isEmpty && job.sample.isEmpty {
                Text(job.state.isActive ? "Nothing done yet…" : "No file needed a sound fingerprint.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(job.problems) { row($0) }
                        ForEach(job.sample) { row($0) }
                        let shown = job.sample.count
                        let stampedQuietly = job.totals[.fingerprinted] + job.totals[.shared] + job.totals[.noAudio]
                        if stampedQuietly > shown {
                            Text("…and \((stampedQuietly - shown).formatted()) more stamped")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6)
            .fill(Color(NSColor.textBackgroundColor).opacity(0.5)))
        .accessibilityIdentifier("mfo.fingerprintSound.detail")
    }

    private func laneRow(_ lane: AudioFingerprintBackfillLaneStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "externaldrive")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(lane.label)
                .font(.system(size: 12, weight: .medium))
            Text("\(lane.done.formatted()) of \(lane.planned.formatted()) · \(Self.words(lane.phase))")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
    }

    private func row(_ item: AudioFingerprintBackfillItemRow) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: Self.icon(item.result))
                .foregroundStyle(Self.color(item.result))
                .font(.system(size: 12))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.archived ? "\(item.filename)  ·  \(item.drive)  ·  archive" : "\(item.filename)  ·  \(item.drive)")
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(item.path)
                Text(item.result.isStamped && item.result != .partial ? item.detail : "\(item.result.words) — \(item.detail)")
                    .font(.system(size: 11))
                    .foregroundStyle(item.result == .failed ? Self.color(.failed) : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
    }

    static func words(_ phase: AudioFingerprintBackfillLaneStatus.Phase) -> String {
        switch phase {
        case .waiting: return "waiting"
        case .reading: return "reading"
        case .finished: return "finished"
        case .disconnected: return "drive not connected"
        case .stopped: return "stopped"
        }
    }

    static func icon(_ result: AudioFingerprintBackfillResult) -> String {
        switch result {
        case .fingerprinted: return "waveform.circle.fill"
        case .shared: return "doc.on.doc.fill"
        case .noAudio: return "speaker.slash.circle"
        case .partial: return "waveform.badge.exclamationmark"
        case .failed: return "xmark.octagon.fill"
        case .driveNotConnected: return "externaldrive.badge.xmark"
        case .missing: return "questionmark.folder"
        case .recordChanged, .cancelled: return "arrow.triangle.2.circlepath"
        }
    }

    static func color(_ result: AudioFingerprintBackfillResult) -> Color {
        switch result {
        case .fingerprinted, .shared: return Color(red: 0.10, green: 0.45, blue: 0.25)
        case .failed: return Color(red: 0.80, green: 0.10, blue: 0.10)
        case .partial: return Color(red: 0.75, green: 0.42, blue: 0.00)
        default: return .secondary
        }
    }
}
