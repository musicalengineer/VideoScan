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
// skip ("v1|<bytes>|<count>"). The case id is stable across launches (the
// drive root / duplicate group id / footage group id / junk reason +
// drive). A value that cannot be read (another build's, a hand edit) is
// treated as "not skipped" — the case is shown again rather than hidden
// forever — and never crashes. Keys of cases that no longer exist are left
// behind; they are a few bytes each.
//
// Tests hand in their own UserDefaults suite; the app passes `.standard`.
//
// (For Rick: a small value type wrapping a `UserDefaults*` — no state of
// its own, so two copies of it always agree.)

import Foundation

struct StewardSkipStore {
    static let keyPrefix = "steward.skipped."
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

    // MARK: Reading

    /// The facts remembered for a case, or nil (never skipped, or the
    /// stored value cannot be read).
    func rememberedFacts(caseID: String) -> StewardFacts? {
        guard let raw = defaults.object(forKey: Self.key(for: caseID)) as? String else { return nil }
        return Self.decode(raw)
    }

    /// Skipped, and the facts have not moved materially since.
    func isSkipped(_ c: StewardCase) -> Bool {
        guard let then = rememberedFacts(caseID: c.id) else { return false }
        return !Self.isMaterialChange(from: then, to: c.facts)
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
