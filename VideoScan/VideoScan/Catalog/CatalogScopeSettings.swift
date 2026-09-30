import Foundation

// MARK: - Catalog Scope Settings (video-only catalog, 2026-07-15)
//
// ONE user-facing toggle: "keep the catalog to videos and their audio"
// (DEFAULT ON — Rick's directive) with the legacy escape hatch of
// turning it off to catalog everything the scan finds, like older
// versions did.
//
// Persistence follows the AnalysisScope explicit-save pattern:
// restored(from:) at startup, save(to:) on every user change, defaults
// INJECTED so tests never touch the real preferences plist
// (settings-pollution class). No didSet magic — @Published owners must
// call save explicitly (@Observable/@Published kill didSet reliability).

struct CatalogScopeSettings: Equatable {

    /// The single toggle. ON (default): the catalog admits only video,
    /// extensionless candidates (Avid recovery), and audio with strict
    /// evidence of belonging to video (CatalogScopePolicy). OFF: legacy
    /// behavior — catalog everything the scan options admit.
    var videoAndLinkedAudioOnly: Bool = true

    // MARK: Persistence (explicit-save pattern)

    static let videoOnlyKey = "catalogScope_videoAndLinkedAudioOnly"

    static func restored(from defaults: UserDefaults) -> CatalogScopeSettings {
        var s = CatalogScopeSettings()
        // object(forKey:) nil-check distinguishes "never set" (keep the
        // ON default) from a stored false (the user's escape hatch).
        if defaults.object(forKey: videoOnlyKey) != nil {
            s.videoAndLinkedAudioOnly = defaults.bool(forKey: videoOnlyKey)
        }
        return s
    }

    func save(to defaults: UserDefaults) {
        defaults.set(videoAndLinkedAudioOnly, forKey: Self.videoOnlyKey)
    }
}
