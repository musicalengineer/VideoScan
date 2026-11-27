// VideoRecord+Presentation.swift
// VideoRecord's SwiftUI display-only accessors — the filename tint,
// row-background tint, and the archive-health traffic light — lifted
// verbatim OFF VideoRecord+Derived.swift (refactor 2026-06-26, model
// decomposition step 2). The derived/domain props stay Foundation-only
// in Models/VideoRecord+Derived.swift so the Models/ group can later be
// lifted into a Swift package; these UI accessors live in the app-side
// ModelsUI/ group.
//
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state, methods share the same `self`.)

import SwiftUI

extension VideoRecord {

    /// Filename tint color based on archival/disposition status.
    /// Priority: damaged (red) → sound needs attention (orange) → junk (gray)
    /// → archived (green) → master (blue) → in-progress (orange) → flagged
    /// (yellow) → default (primary).
    var filenameColor: Color {
        if streamType == .ffprobeFailed || streamType == .noStreams {
            return .red
        }
        // Verify Audio verdict (GH #128): damaged audio shares the
        // "damaged (red)" priority tier with unreadable files — the sound
        // is not usable as it stands (real damage — and a reference movie or
        // a sound that needs rebuilding stored "damaged" before 2026-11-27,
        // until verified again; the note says which), so the tint must
        // survive every softer disposition below.
        let sound = StoredAudioStatus(audioVerifyStatus).tint
        if sound == .damaged {
            return .red
        }
        // Verify Video "broken" verdict (2026-09-23) — the same damaged
        // tier: a broken picture must never read as an ordinary row.
        if videoVerifyStatus == "broken" {
            return .red
        }
        // "attention" (DECISIONS 2026-11-27): a reference movie or a sound
        // that needs rebuilding — not usable as it stands, not damage. Orange,
        // and like red it survives every softer disposition below.
        if sound == .attention {
            return .orange
        }
        if mediaDisposition == .confirmedJunk {
            return .secondary
        }
        if mediaDisposition == .suspectedJunk {
            return Color.secondary.opacity(0.7)
        }
        if archiveStage >= .backedUp && !backupDestinations.isEmpty {
            return .green
        }
        if archiveStage == .masterAssigned {
            return .blue
        }
        if mediaDisposition == .important || mediaDisposition == .recoverable
            || archiveStage >= .healthy {
            return .orange
        }
        return .primary
    }

    /// Quick archive-health traffic light: green (safe), yellow (in progress), red (needs attention).
    var archiveHealth: ArchiveHealth {
        if mediaDisposition == .confirmedJunk || mediaDisposition == .suspectedJunk {
            return .notApplicable
        }
        let hasAV = streamType == .videoAndAudio
        let isReviewed = mediaDisposition == .important || mediaDisposition == .recoverable
        let isArchived = archiveStage >= .backedUp
        let hasBackup = !backupDestinations.isEmpty

        if hasAV && isReviewed && isArchived && hasBackup {
            return .safe
        } else if isReviewed || archiveStage >= .healthy {
            return .inProgress
        } else {
            return .needsAttention
        }
    }

    var rowColor: Color {
        if let conf = pairConfidence {
            return conf.color
        }
        // Verify Audio damaged verdict (GH #128) — same red wash the
        // ffprobeFailed state uses (one damaged-row language).
        let sound = StoredAudioStatus(audioVerifyStatus).tint
        if sound == .damaged || videoVerifyStatus == "broken" {
            return Color.red.opacity(0.15)
        }
        // "attention": reference movie / sound that needs rebuilding — orange, not red.
        if sound == .attention {
            return Color.orange.opacity(0.18)
        }
        switch streamType {
        case .videoOnly:     return Color.yellow.opacity(0.25)
        case .audioOnly:     return Color.yellow.opacity(0.25)
        case .noStreams:     return Color.gray.opacity(0.15)
        case .ffprobeFailed: return Color.red.opacity(0.15)
        default:             return Color.clear
        }
    }
}
