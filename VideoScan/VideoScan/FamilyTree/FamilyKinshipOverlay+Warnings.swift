// FamilyKinshipOverlay+Warnings.swift
// The overlay's warning READ side — the lookups that answer "what is wrong
// with this person's data?" for the People-tab badge popover, the editor
// and Hallie's basis line. Extracted verbatim from FamilyKinshipOverlay.swift
// (2026-09-13) to keep that type's body from growing further; the behaviour,
// the strings and the ordering are unchanged.
//
// What did NOT move, and why: the warning STORAGE (`warnings`,
// `structuredWarnings`, `warningsByLine`, `warningKeys`, `pinProblems`,
// `derivationProblems`, `warningsByNode`) stays in the main file — a Swift
// extension cannot declare stored properties — and so does `note(_:_:)`,
// the only writer, which runs during construction and keeps the invariant
// that every line is recorded exactly once under exactly one code.
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here means
// file-private to THIS file.) A cross-file extension can't see `private`
// members, so the six maps these lookups read were widened to
// `private(set)` in the main file: internal to read, still writable only
// where they are built.

import Foundation

extension FamilyKinshipOverlay {
    /// Why a profile's tree pin did not bridge, nil when it did (or none).
    func pinProblem(forProfileStableID stableID: String) -> String? { pinProblems[stableID] }

    /// Warnings involving this profile (for the card badge): its hygiene,
    /// dangling-row and pin lines, plus every derivation conflict its
    /// sibling set or parent rows are part of — in `warnings` order. Keyed
    /// by the profile's vertex and stableID (codex #1019 item 4), so a
    /// namesake elsewhere in the People tab never wears this badge.
    func warnings(forProfileStableID stableID: String) -> [String] {
        var nodes: [Node] = []
        if let node = nodeByProfileStableID[stableID] { nodes.append(node) }
        return warnings(for: nodes, stableIDs: [stableID])
    }

    /// The same by display name, for callers that hold only a name: the
    /// name is resolved to the profile vertex(es) carrying it as their
    /// canonical spelling — a name is not an identity, so when two profiles
    /// share one canonical name both profiles' warnings are returned. The
    /// card badge uses `warnings(forProfileStableID:)`.
    func warnings(forProfileNamed name: String) -> [String] {
        var nodes = nodesByCanonicalName[name] ?? []
        if nodes.isEmpty { nodes = canonicalNodesBySpelling[PersonResolver.normalize(name)] ?? [] }
        if nodes.isEmpty {
            // A placeholder left by a row that names nobody's profile.
            let placeholder = Node.profile(stableID: PersonResolver.normalize(name))
            if members[placeholder] != nil { nodes = [placeholder] }
        }
        let stableIDs = nodes.compactMap { members[$0]?.profileStableID }
        return warnings(for: nodes, stableIDs: stableIDs)
    }

    private func warnings(for nodes: [Node], stableIDs: [String]) -> [String] {
        var lines = Set<String>()
        for node in nodes { for line in warningsByNode[node] ?? [] { lines.insert(line) } }
        for id in stableIDs { if let why = pinProblems[id] { lines.insert(why) } }
        return warnings.filter(lines.contains)
    }

    /// `warnings(forProfileStableID:)` with each line classified — the
    /// People-tab popover's input. Same lookup, same vertex keying, same
    /// `warnings` order; the strings are untouched.
    func structuredWarnings(forProfileStableID stableID: String) -> [KinshipWarning] {
        classify(warnings(forProfileStableID: stableID))
    }

    /// The same by display name (a name is not an identity — see
    /// `warnings(forProfileNamed:)`).
    func structuredWarnings(forProfileNamed name: String) -> [KinshipWarning] {
        classify(warnings(forProfileNamed: name))
    }

    /// The classified form of `derivationWarnings(touching:)`.
    func structuredDerivationWarnings(touching nodes: [Node]) -> [KinshipWarning] {
        classify(derivationWarnings(touching: nodes))
    }

    /// Every line this overlay produced came through `note(_:_:)`, so the
    /// map always hits; `compactMap` is the honest fallback rather than an
    /// invented code.
    private func classify(_ lines: [String]) -> [KinshipWarning] {
        lines.compactMap { warningsByLine[$0] }
    }

    /// The derivation conflicts any of these vertices is involved in, in
    /// `warnings` order and without repeats — for Hallie's basis line when
    /// a question touches a sibling set that failed closed.
    func derivationWarnings(touching nodes: [Node]) -> [String] {
        var lines = Set<String>()
        for node in nodes { for line in derivationProblems[node] ?? [] { lines.insert(line) } }
        return warnings.filter(lines.contains)
    }
}
