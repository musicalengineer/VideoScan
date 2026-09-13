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
