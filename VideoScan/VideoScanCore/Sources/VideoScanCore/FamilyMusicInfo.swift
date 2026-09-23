// FamilyMusicInfo.swift
// Family Music (Rick 2026-09-23): "I definitely don't mean iTunes or bought
// music, I mean my family music." A tiny, hand-curated shelf — at most a
// couple of dozen recordings of musically inclined family members (audio
// recordings, or videos of people playing).
//
// The ONLY way a file gets on the shelf is Rick's explicit right-click
// "Mark as Family Music…". Nothing automatic sets this field — no
// extension rule, no folder rule, no metadata rule — so purchased music
// (an iTunes / Music library, a ripped CD) can never appear by itself.
//
// Additive optional on VideoRecord (`familyMusic`): legacy catalogs decode
// nil and round-trip byte-identical, because the DTO writes the key only
// when the mark is present. It is a USER edit, so it survives Update
// Catalog (RescanPreservedFields) and rides snapshotClone.
//
// (For Rick: a plain value struct ≈ a C++ POD with an explicit
// serializer; `Codable` synthesizes the serializer from the member list.)

import Foundation

public struct FamilyMusicInfo: Codable, Equatable, Sendable {
    /// Who is playing / singing — free text ("Tim", "Rick & Donna").
    /// Optional: a group mark over several files may leave it blank.
    public var performer: String?
    /// What they are playing — free text. nil → the list shows the filename.
    public var title: String?
    /// When Rick marked it (for the ledger and "newest mark" questions).
    public var markedAt: Date

    public init(performer: String? = nil, title: String? = nil, markedAt: Date = Date()) {
        self.performer = Self.clean(performer)
        self.title = Self.clean(title)
        self.markedAt = markedAt
    }

    /// Trimmed, and empty → nil, so "" never masquerades as a performer.
    public static func clean(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }
}
