// CatalogFilenameCell.swift
// The Filename column's cell — the state glyph, the monospaced name, the
// focus-independent selection outline and the tooltip — and the glyph
// ladder as a value type. Extracted from CatalogContent.catalogTableBase
// (2026-10-10) so the column closure is one line and the state-priority
// ladder can be tested without a Table (CatalogRowStateIconTests).
// (Swift `enum` with computed properties ≈ a C++ enum class plus two
// lookup tables, kept next to the cases they describe.)

import SwiftUI

/// The small glyph before a filename, one per row state, HIGHEST priority
/// first: a purged row that is also set aside shows the trash glyph.
enum CatalogRowStateIcon: Equatable {
    /// Trash-slash makes the "removed" state obvious at a glance — even if
    /// the user's row colors are partially overridden by a high-contrast
    /// theme.
    case purged
    /// Archive-box = "set aside by catalog scope" (photo / music / audio
    /// with no matching video). Purple to stay distinct from purge-orange.
    case setAside
    /// Swap arrows = "a confirmed repair replaced this original" (GH #132).
    /// Brown to stay distinct from purge-orange and set-aside-purple.
    case superseded
    /// Red "!" — file's video / audio codec was deprecated by AVFoundation
    /// (svq3, qdm2, cinepak, etc.) so the analyzer can't decode it.
    /// Right-click → Reformat and Analyze to convert via ffmpeg. Rick
    /// 2026-06-14.
    case unanalyzable
    /// Hammer = "being worked on with external tools." Turquoise (.mint
    /// adapts for dark mode) marks the record as triage-active. Pass A —
    /// Rick 2026-06-14.
    case workspace
    /// Pairs-only view: the video half of a correlated A/V pair.
    case pairedVideo
    /// Pairs-only view: the audio half of a correlated A/V pair.
    case pairedAudio

    /// The glyph for a record, or nil for a plain row. `pairTint` is true
    /// in the Pairs-only view when the record has a paired partner.
    static func icon(for rec: VideoRecord, pairTint: Bool) -> CatalogRowStateIcon? {
        if rec.isPurged { return .purged }
        if rec.isSetAside { return .setAside }
        if rec.isSuperseded { return .superseded }
        if rec.isLikelyUnanalyzable { return .unanalyzable }
        if rec.workspaceActive { return .workspace }
        if pairTint { return rec.streamType == .videoOnly ? .pairedVideo : .pairedAudio }
        return nil
    }

    var systemImage: String {
        switch self {
        case .purged:       return "trash.slash"
        case .setAside:     return "archivebox"
        case .superseded:   return "arrow.triangle.swap"
        case .unanalyzable: return "exclamationmark.triangle.fill"
        case .workspace:    return "hammer.fill"
        case .pairedVideo:  return "film"
        case .pairedAudio:  return "waveform"
        }
    }

    var color: Color {
        switch self {
        case .purged:       return .orange
        case .setAside:     return .purple
        case .superseded:   return .brown
        case .unanalyzable: return .red
        case .workspace:    return .mint
        case .pairedVideo:  return .blue
        case .pairedAudio:  return .green
        }
    }
}

/// One Filename cell. Pure function of its inputs: the parent decides
/// selection, reachability, the pair tint and the tooltip text.
struct CatalogFilenameCell: View {
    let record: VideoRecord
    let isSelected: Bool
    let isOffline: Bool
    let pairTint: Bool
    let tooltip: String

    var body: some View {
        HStack(spacing: 4) {
            if let icon = CatalogRowStateIcon.icon(for: record, pairTint: pairTint) {
                Image(systemName: icon.systemImage)
                    .font(.system(size: 10))
                    .foregroundColor(icon.color)
            }
            Text(record.filename)
                .font(.system(.body, design: .monospaced))
                // Italic when offline OR purged — both signal "not the
                // active default state". Purge color (orange) wins over
                // both offline-secondary and pair-blue/green when set.
                // Workspace tint (.mint / turquoise) sits between
                // purged-orange (highest priority) and the rest.
                .italic(isOffline || record.isPurged || record.isSetAside || record.isSuperseded)
                .foregroundColor(CatalogContent.filenameColor(
                    for: record,
                    selected: isSelected,
                    offline: isOffline,
                    pairTint: pairTint))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
        // Rick 2026-10-05: "sometimes it's not clear which file I am
        // right clicking on" — the system selection turns grey when
        // the window isn't key (Hallie's window, the MFO window
        // brought forward). A light-blue marker behind the selected
        // file's name that does NOT depend on focus. O(1) per cell.
        .background {
            if isSelected {
                // Outline only (Rick 2026-10-10): a fill stacked
                // on the system highlight hid the filename.
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Color.accentColor, lineWidth: 1.5)
                    .padding(.horizontal, -4)
            }
        }
        .help(tooltip)
    }
}
