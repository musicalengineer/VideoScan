// StewardSkipStore.swift
// "Skip" on a steward card, remembered across launches (trial UI,
// 2026-10-03; design §5.6 — the Angel's attention-memory lesson: never
// re-propose what was declined).
//
// THE RULE, in one sentence: a skipped case stays out of the queue until
// the facts under it change materially — its file count or its size moves
// by a tenth or more (and by at least one file) — or the person brings it
// back with "Show skipped".
//
// Storage for the trial: UserDefaults, one key per case,
// `steward.skipped.<caseID>`, whose value is the facts at the moment of the
// skip ("v1|<bytes>|<count>"). The case id is chosen to outlive a re-check:
// the drive root; a duplicate set's KEEPER record id (the group id is
// renumbered by every duplicate check); the footage group id (the smallest
// member's record id, by FootageMembership's design); the junk reason +
// drive. A set whose keeper changes is a new case, and is shown again. A value that cannot be read (another build's, a hand edit) is
// treated as "not skipped" — the case is shown again rather than hidden
// forever — and never crashes. Keys of cases that no longer exist are left
// behind; they are a few bytes each.
//
// REVIEWED (QA F8, 2026-10-03). A "Probably not worth keeping" card is
// finished when a person has decided about every clip on it from "Review
// these below". Keep and Repair take a clip out of the cluster by
// themselves; Junk does not — the Triage Junk button writes the same
// Suspected Junk the analyzer writes, and the record does not carry who
// set it. So the Triage tab remembers which reviewed clips a person
// decided (`StewardReview`), and when all have been, it stores the card's
// facts as they will be rebuilt — the clips a person marked Junk — under
// `steward.reviewed.<caseID>`. The builder leaves the card out until those
// facts move materially (the same tenth rule as Skip). Not a skip: it is
// not offered under "Show skipped".
//
// Tests hand in their own UserDefaults suite; the app passes `.standard`.
//
// (For Rick: a small value type wrapping a `UserDefaults*` — no state of
// its own, so two copies of it always agree.)

import Foundation
import VideoScanCore

struct StewardSkipStore {
    static let keyPrefix = "steward.skipped."
    static let reviewedPrefix = "steward.reviewed."
    static let valueVersion = "v1"
    /// A tenth: the share of the count or the bytes that must move.
    static let materialFraction = 0.10

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    static func key(for caseID: String) -> String { keyPrefix + caseID }

    // MARK: Writing

    func skip(_ c: StewardCase) {
        defaults.set(Self.encode(c.facts), forKey: Self.key(for: c.id))
    }

    func bringBack(caseID: String) {
        defaults.removeObject(forKey: Self.key(for: caseID))
    }

    /// QA F8: every clip of a reviewed card has a person's decision; these
    /// are the facts the card will be rebuilt with (see the header).
    func markReviewed(caseID: String, facts: StewardFacts) {
        defaults.set(Self.encode(facts), forKey: Self.reviewedPrefix + caseID)
    }

    // MARK: Reading

    /// The facts remembered for a case, or nil (never skipped, or the
    /// stored value cannot be read).
    func rememberedFacts(caseID: String) -> StewardFacts? {
        guard let raw = defaults.object(forKey: Self.key(for: caseID)) as? String else { return nil }
        return Self.decode(raw)
    }

    /// Skipped, and the facts have not moved materially since.
    func isSkipped(_ c: StewardCase) -> Bool {
        Self.isSkipped(c, remembered: rememberedFacts(caseID: c.id))
    }

    nonisolated static func isSkipped(_ c: StewardCase, remembered: StewardFacts?) -> Bool {
        guard let remembered else { return false }
        return !isMaterialChange(from: remembered, to: c.facts)
    }

    /// Everything remembered, by case id — a Sendable copy for the case
    /// builder, so its per-kind limit is spent on what is NOT skipped.
    /// One pass over the defaults' keys; unreadable values are left out.
    func snapshot() -> [String: StewardFacts] { snapshot(prefix: Self.keyPrefix) }

    /// The reviewed cards (QA F8), by case id — for the builder.
    func reviewedSnapshot() -> [String: StewardFacts] { snapshot(prefix: Self.reviewedPrefix) }

    private func snapshot(prefix: String) -> [String: StewardFacts] {
        var out: [String: StewardFacts] = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix(prefix) {
            guard let raw = value as? String, let facts = Self.decode(raw) else { continue }
            out[String(key.dropFirst(prefix.count))] = facts
        }
        return out
    }

    /// The queue, split: what to show, and what was skipped (same order).
    func partition(_ cases: [StewardCase]) -> (active: [StewardCase], skipped: [StewardCase]) {
        var active: [StewardCase] = [], skipped: [StewardCase] = []
        for c in cases {
            if isSkipped(c) { skipped.append(c) } else { active.append(c) }
        }
        return (active, skipped)
    }

    // MARK: The rule (pure)

    /// True when the count moved by a tenth or more (and by at least one
    /// file), or the bytes moved by a tenth or more.
    nonisolated static func isMaterialChange(from old: StewardFacts, to new: StewardFacts) -> Bool {
        let countMove = abs(new.count - old.count)
        let countBar = max(1, Int((Double(old.count) * materialFraction).rounded(.up)))
        if countMove >= countBar { return true }
        let byteMove = abs(new.bytes - old.bytes)
        guard byteMove > 0 else { return false }
        return Double(byteMove) >= Double(max(old.bytes, 1)) * materialFraction
    }

    nonisolated static func encode(_ facts: StewardFacts) -> String {
        "\(valueVersion)|\(facts.bytes)|\(facts.count)"
    }

    nonisolated static func decode(_ raw: String) -> StewardFacts? {
        let parts = raw.split(separator: "|", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0] == valueVersion,
              let bytes = Int64(parts[1]), let count = Int(parts[2]), bytes >= 0, count >= 0 else { return nil }
        return StewardFacts(bytes: bytes, count: count)
    }
}

/// QA F8: what a person decided, from the Triage table, about the clips a
/// "Probably not worth keeping" card sent there ("Review these below").
/// Pure view state of the Triage tab; nothing here is stored.
struct StewardReview: Equatable {
    var caseID = ""
    var ids: Set<UUID> = []
    /// The last decision pressed on each reviewed clip (absent = none yet).
    var decided: [UUID: MediaDisposition] = [:]

    init() {}

    init(caseID: String, ids: Set<UUID>) {
        self.caseID = caseID
        self.ids = ids
    }

    var isActive: Bool { !caseID.isEmpty && !ids.isEmpty }

    /// A decision pressed on `pressed` (Keep, Repair, Junk, Confirm as
    /// Junk — or Undo, which takes it back). True when every reviewed clip
    /// now has a decision.
    mutating func note(_ disposition: MediaDisposition, on pressed: Set<UUID>) -> Bool {
        guard isActive else { return false }
        for id in pressed where ids.contains(id) {
            decided[id] = disposition == .unreviewed ? nil : disposition
        }
        return decided.count == ids.count
    }

    /// The clips a person marked Junk: the cluster is rebuilt from exactly
    /// these (the builder cannot tell them from the analyzer's suggestion).
    var markedJunk: Set<UUID> { Set(decided.filter { $0.value == .suspectedJunk }.keys) }
}
