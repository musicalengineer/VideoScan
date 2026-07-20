// MediaKindFacet.swift
// GH #124 layer 1 — the catalog's media-kind facet.
//
// Rick's 2026-07-19 spot test: ~80k of ~103k catalog records were
// audio-only (iTunes trees swept in from backup volumes), so scrolling
// the catalog meant paging past 80,000 music rows before reaching any
// video. This facet makes "video-bearing records" the DEFAULT view and
// keeps audio-only one explicit click away — never gone (audio-only MXF
// halves matter for correlate/combine, which source their candidates
// from `model.records` directly and are untouched by any view filter).
//
// Facet semantics vs. the strict "video+audio, video-only" reading:
// `.videoBearing` excludes ONLY `.audioOnly`. Records whose probe FAILED
// (`.ffprobeFailed`) or found no streams (`.noStreams`) stay visible in
// the default view on purpose — damaged Avid RGBA MXFs that ffprobe
// can't parse ARE the app's core recovery mission, and Rick's issue text
// names "video-only/damaged/etc." as exactly what he scrolls to reach.
// Hiding them behind the facet would bury the patient with the noise.
// The truth table is pinned by MediaKindFacetTests.
//
// Search grammar: `type:` / `kind:` field tokens use the SAME spelling
// as this facet (the #117 v2 facet family):
//     type:video       → video-bearing with CONFIRMED video streams
//                        (videoAndAudio | videoOnly — a search is an
//                        assertion, so failed/no-stream rows don't match)
//     type:video-only  → videoOnly
//     type:audio       → audioOnly
//     type:both / :av  → videoAndAudio
//     type:failed      → ffprobeFailed        type:none → noStreams
// See pfMediaKindAliasMatches in CatalogQueries.swift.

import Foundation

// MARK: - CatalogKindFacet

/// The three-way media-kind view facet. `String` raw values are the
/// PERSISTED tokens (UserDefaults) — do not rename without a migration.
enum CatalogKindFacet: String, CaseIterable, Identifiable, Codable {
    /// Default: everything except audio-only. Keeps damaged/unknown rows
    /// visible (see header comment).
    case videoBearing = "videoBearing"
    /// Only audio-only records — the explicit door back to the 80k.
    case audioOnly = "audioOnly"
    /// No kind narrowing (the pre-#124 behavior).
    case everything = "everything"

    var id: String { rawValue }

    /// Menu label — friendly-family language, no jargon.
    var label: String {
        switch self {
        case .videoBearing: return "Videos"
        case .audioOnly:    return "Audio Only"
        case .everything:   return "All Kinds"
        }
    }

    var icon: String {
        switch self {
        case .videoBearing: return "film"
        case .audioOnly:    return "waveform"
        case .everything:   return "square.stack.3d.up"
        }
    }

    var help: String {
        switch self {
        case .videoBearing:
            return "Show video-bearing records (video+audio and video-only, plus damaged/unreadable files that may be video). Audio-only rows are hidden — the default."
        case .audioOnly:
            return "Show only audio-only records (music files, orphaned audio halves)."
        case .everything:
            return "Show every record regardless of stream kind."
        }
    }

    /// Truth table — pure so the same rule drives the table filter, the
    /// tests, and any future scripted queries.
    func matches(_ streamType: StreamType) -> Bool {
        switch self {
        case .videoBearing: return streamType != .audioOnly
        case .audioOnly:    return streamType == .audioOnly
        case .everything:   return true
        }
    }
}

/// Apply the kind facet to a record list. `.everything` short-circuits to
/// the identity so the default-off path costs nothing extra.
nonisolated func pfApplyKindFacet(
    _ records: [VideoRecord],
    facet: CatalogKindFacet
) -> [VideoRecord] {
    if facet == .everything { return records }
    return records.filter { facet.matches($0.streamType) }
}

// MARK: - Persistence (explicit-save pattern)

/// Persisted wrapper for the facet preference. Follows the
/// CatalogScopeSettings explicit-save pattern: restored(from:) at
/// startup, save(to:) on every user change, defaults INJECTED so tests
/// never touch the real preferences plist (settings-pollution class).
/// No didSet magic — the @Published owner (VideoScanModel) must call
/// saveKindFacetSetting() explicitly.
struct CatalogKindFacetSetting: Equatable {

    /// The facet the catalog table opens with. DEFAULT `.videoBearing`
    /// (GH #124: the whole point). Sensor test pins this default.
    var facet: CatalogKindFacet = .videoBearing

    static let facetKey = "catalogKindFacet"

    static func restored(from defaults: UserDefaults) -> CatalogKindFacetSetting {
        var s = CatalogKindFacetSetting()
        // Poisoned-state discipline: a missing key OR an unrecognized
        // stored token (future version, corrupted plist) falls back to
        // the videoBearing default instead of crashing or clearing.
        if let raw = defaults.string(forKey: facetKey),
           let restored = CatalogKindFacet(rawValue: raw) {
            s.facet = restored
        }
        return s
    }

    func save(to defaults: UserDefaults) {
        defaults.set(facet.rawValue, forKey: Self.facetKey)
    }
}
