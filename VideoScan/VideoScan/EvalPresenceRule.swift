// EvalPresenceRule.swift
// POI improvement cycle 03 — minimum-hit confirmation floor (EVAL-ONLY).
//
// Video-level presence rule for the Person Evaluation CLI. The ONE change
// this cycle: an opt-in `minimumHits` mode where a person is CONFIRMED
// present in a video iff the raw matched face-observation count (`totalHits`;
// multiple observations can land in one frame) reaches an explicit
// floor. No hit-rate gate, no median-distance gate — cycle 1's compound
// gates are deliberately absent so any grade delta is attributable to the
// count floor alone.
//
//     legacyAnyHit (default): presence = "confirmed" ⇔ hits > 0
//     minimumHits(N):         presence = "confirmed" ⇔ hits ≥ N
//     otherwise:              presence = "none"
//
// This type is used ONLY by PersonEvaluationCLI. Production scan behavior
// (PersonFinderModel and friends) is untouched and remains legacy.
//
// Pure O(1) math over an already-computed counter — no I/O, no actors, no
// global state, no per-observation allocation. Worst-case memory: the
// struct itself (a tag + one optional Int).

import Foundation

/// The aggregation rule the eval CLI both EXECUTES and EMITS. A single value
/// travels from argument parsing to the presence decision to the JSON output,
/// so the emitted configuration can never diverge from the effective one
/// (cycle 2's provenance lesson).
///
/// C++ analogy: a small POD with a tag enum; `Codable` ≈ compiler-generated
/// serialize/deserialize keyed on the property names below.
struct EvalPresenceRule: Codable, Equatable, Sendable {

    enum Mode: String, Codable, Equatable, Sendable {
        /// Pre-cycle behavior: any single hit ⇒ confirmed.
        case legacyAnyHit
        /// Cycle-03 candidate: confirmed ⇔ hits ≥ minHits.
        case minimumHits
    }

    /// Exact presence spellings the external grader matches on. The grader
    /// counts ONLY `confirmed` as a positive; everything else is `none`.
    static let confirmedSpelling = "confirmed"
    static let noneSpelling = "none"

    let mode: Mode
    /// Confirmation floor. Present (non-nil) iff `mode == .minimumHits`;
    /// encoded/omitted accordingly so the canonical JSON carries exactly the
    /// meaningful fields for the mode that actually ran.
    let minHits: Int?

    /// The default rule and the A/B legacy arm. Canonical JSON:
    /// `{"mode":"legacyAnyHit"}`.
    static let legacy = EvalPresenceRule(mode: .legacyAnyHit, minHits: nil)

    /// The cycle-03 candidate rule. Canonical JSON for floor 7:
    /// `{"minHits":7,"mode":"minimumHits"}`.
    /// The floor is validated at the CLI boundary (positive integer, no
    /// silent default); this constructor is the only way to reach the mode.
    static func minimumHits(floor: Int) -> EvalPresenceRule {
        EvalPresenceRule(mode: .minimumHits, minHits: floor)
    }

    /// Field set spelled out as an explicit contract — renaming a property
    /// cannot silently change the evaluator-hashed JSON.
    enum CodingKeys: String, CodingKey {
        case mode, minHits
    }

    /// Canonical byte-stable JSON: sorted keys, no whitespace, nil fields
    /// omitted. The CLI embeds this struct in its output via the same
    /// sortedKeys encoder, so the emitted bytes match this string; the
    /// external evaluator hashes it to attribute results to an exact
    /// configuration.
    func canonicalJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(self),
              let json = String(bytes: data, encoding: .utf8) else { return "{}" }
        return json
    }

    /// The video-level presence decision. Pure comparison — the raw matched
    /// face-observation counter (`hits`) is reported unchanged alongside
    /// this; only the confirmed/none classification differs between modes.
    func presence(hits: Int) -> String {
        switch mode {
        case .legacyAnyHit:
            return hits > 0 ? Self.confirmedSpelling : Self.noneSpelling
        case .minimumHits:
            // Fail CLOSED if the floor is somehow absent (unreachable via
            // the public constructors; pinned by tests): never a silent
            // confirm under a half-specified rule.
            guard let floor = minHits else { return Self.noneSpelling }
            return hits >= floor ? Self.confirmedSpelling : Self.noneSpelling
        }
    }
}
