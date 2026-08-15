// MusicTriageSheet.swift
// GH #124 layer 2 — the music-triage suggestion banner and its review
// sheet. Nag-button pattern (feedback_nag_button_pattern): the banner
// states the problem AND performs the fix on click — one press opens
// the review list, one more press soft-deletes the batch through the
// EXISTING purgeRecords path (files on disk untouched, existing purge
// undo banner arms, Show Removed → Restore always available).
//
// Detection logic lives in MusicTriage.swift (pure, tested); this file
// is presentation only.

import SwiftUI

// MARK: - Suggestion banner

/// Inline suggestion row above the catalog table — same visual family as
/// the purge/tidy undo banners in CatalogHelpers (teal palette so it
/// reads "suggestion", not "something happened"). Dismiss (×) hides it
/// for the current count; it reappears if the candidate count changes
/// (new music swept in) — nag semantics, not a permanent mute.
struct MusicTriageBanner: View {
    let count: Int
    let onReview: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "music.note.list")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.teal)
            Text("\(count) file\(count == 1 ? " looks" : "s look") like music-library audio (iTunes paths, mp3/m4a/…).")
                .font(.system(size: 12))
                .foregroundColor(.primary)
            Button("Review & Remove…") {
                onReview()
            }
            .buttonStyle(.borderedProminent)
            .tint(.teal)
            .controlSize(.small)
            .help("Show the list. Removing is the reversible soft-delete — files on disk are never touched, and Undo is one click.")

            Spacer()

            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(Color.secondary, Color.secondary.opacity(0.2))
            }
            .buttonStyle(.plain)
            .help("Dismiss this suggestion. It returns if the music count changes.")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.teal.opacity(0.12))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.teal.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

// MARK: - Review sheet

/// The filtered review list + the one-button batch remove. Candidates
/// are RESOLVED FRESH from the model at render time from the passed IDs
/// so a record purged/paired between banner click and sheet render
/// silently drops out rather than being double-processed.
struct MusicTriageSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    let candidateIDs: [UUID]

    /// The way out (Rick 2026-08-14): every row is CHECKED for removal by
    /// default, and unchecking keeps that file in the catalog. Stored
    /// inverted -- only the exceptions -- so an 80k-candidate set needs no
    /// prefilled Set and "all checked" costs nothing.
    @State private var keptIDs: Set<UUID> = []

    /// Live resolution of the candidate list. O(candidates) via the
    /// model's O(1) id index — no full-catalog walk in body.
    private var candidates: [VideoRecord] {
        candidateIDs.compactMap { id in
            guard let rec = model.record(forID: id),
                  !rec.isPurged, !rec.isSetAside else { return nil }
            return rec
        }
    }

    var body: some View {
        let recs = candidates
        let totalBytes = recs.reduce(into: Int64(0)) { $0 += $1.sizeBytes }
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "music.note.list")
                    .font(.system(size: 18))
                    .foregroundColor(.teal)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Music-Library Audio Review")
                        .font(.headline)
                    Text("\(recs.count) file\(recs.count == 1 ? "" : "s") · \(Formatting.humanSize(totalBytes)) cataloged")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            if recs.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 28))
                        .foregroundColor(.secondary)
                    Text("Nothing left to review.")
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // List is lazy, so an 80k-row candidate set renders only
                // the visible rows. Mostly confirm-the-batch — but each
                // row has a checkbox so one or two genuine keepers can be
                // spared without graduating into a full triage UI.
                List(recs) { rec in
                    HStack(spacing: 8) {
                        let kept = keptIDs.contains(rec.id)
                        Button {
                            if kept { keptIDs.remove(rec.id) } else { keptIDs.insert(rec.id) }
                        } label: {
                            Image(systemName: kept ? "square" : "checkmark.square.fill")
                                .font(.system(size: 14))
                                .foregroundColor(kept ? .secondary : .orange)
                        }
                        .buttonStyle(.plain)
                        .help(kept ? "Will stay in the catalog — click to include in removal"
                                   : "Will be removed — click to keep this one")
                        Text(rec.ext.uppercased())
                            .font(.system(size: 9, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(Color.teal.opacity(0.15),
                                        in: RoundedRectangle(cornerRadius: 3))
                            .foregroundColor(.teal)
                            .frame(width: 40)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rec.filename)
                                .font(.system(size: 12))
                                .lineLimit(1)
                            Text(rec.directory)
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        Text(rec.size)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                    .opacity(keptIDs.contains(rec.id) ? 0.45 : 1.0)
                }
                .listStyle(.inset)
            }

            Divider()

            HStack {
                Label("Removes from the catalog only — files on disk are never touched. Undo is one click on the banner afterward.",
                      systemImage: "info.circle")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                let removing = Set(recs.map(\.id)).subtracting(keptIDs)
                if !keptIDs.isEmpty {
                    Text("keeping \(recs.filter { keptIDs.contains($0.id) }.count)")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
                Button("Remove \(removing.count) from Catalog") {
                    // The EXISTING soft-delete: sets purgedAt, persists,
                    // arms the purge undo banner. No new machinery.
                    model.purgeRecords(ids: removing)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
                .disabled(removing.isEmpty)
            }
            .padding(12)
        }
        .frame(minWidth: 620, minHeight: 440)
    }
}
