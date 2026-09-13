// HallieMode.swift
// The two families of question Hallie answers, as a SESSION state
// (docs/hallie_two_mode_design.md §3.1). Rick, 2026-09-13: "Hallie kinda
// needs 2 modes (automatically switching): catalog/archive questions and
// family-tree questions (including bios)." The mode lives on
// ConversationMemory so every client (app, shell, web) gets it through
// the `record` call it already makes; it is never persisted.

import Foundation

/// C++ analogy: a plain scoped enum with a string backing so it prints
/// in logs and transcripts as "tree" / "catalog" / "unknown".
enum HallieMode: String, Sendable, Equatable, Codable, CaseIterable {
    /// Session start, or a turn that no signal settles. Unknown means
    /// "today's chain, unchanged": the classifier never guesses.
    case unknown
    /// Videos / photos / files / counts / play / reveal.
    case catalog
    /// People, relations, vital facts, biographies.
    case tree

    /// The user-facing label for the header pill / shell diagnostics.
    var label: String {
        switch self {
        case .unknown: return "Listening"
        case .catalog: return "Catalog"
        case .tree: return "Family tree"
        }
    }
}

/// What a turn asks conversation memory to do with the FORCED mode
/// (design §3.6, "correction by talking"). Rides on the Intent or the
/// Result of the turn that asked, so every client's existing
/// `memory.record` call applies it — the pill and ":mode" call
/// `force`/`unforce` directly instead.
enum HallieModeForce: Sendable, Equatable {
    /// Hold this family until reset, Automatic, or the other family is
    /// named.
    case force(HallieMode)
    /// Back to automatic: the sentence named the OTHER family than the
    /// one currently forced.
    case unforce
}
