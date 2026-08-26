// GedcomFamilyGraph+NameIndex.swift
// The `people(namedLike:)` predicate, factored out so an inverted index can
// answer the same question in O(tokens) instead of O(people) (Family Tree
// notes pane, 2026-08-26: a 16k-person tree × every CyberBrain alias must
// resolve once per brain load, not once per selection).
//
// Semantics are identical to `people(namedLike:)` — the index only narrows
// the candidates; every survivor is re-checked with the exact predicate
// (per-NAME-record token containment, diminutive expansion, suffix rule).

import Foundation

extension GedcomFamilyGraph {

    /// Typed-name tokens after diminutive expansion, or nil when the name
    /// is nothing but generational suffixes ("Jr", "III").
    public static func namedLikeTokens(_ typed: String) -> [String]? {
        let tokens = FamilyIdentityText.tokens(typed)
            .map { diminutives[$0] ?? $0 }
        guard tokens.contains(where: { !nameSuffixes.contains($0) }) else { return nil }
        return tokens
    }

    /// The `people(namedLike:)` predicate for one person: some single NAME
    /// record (preferred or alternate) contains every typed token.
    public static func personMatches(_ person: Person, namedLikeTokens tokens: [String]) -> Bool {
        ([person.name] + person.alternateNames).contains { candidate in
            let nameTokens = Set(FamilyIdentityText.tokens(candidate)
                .map { diminutives[$0] ?? $0 })
            return tokens.allSatisfy { nameTokens.contains($0) }
        }
    }

    /// Inverted token → person-id index over every NAME record. Built once
    /// per graph (O(people × name tokens), ~tens of ms for 16k people);
    /// lookups touch only the people who share a token with the query.
    ///
    /// Memory: one Set entry per (token, person) pair — a 16k-person tree
    /// with ~4 tokens/name is ~100k small strings, well under 10 MB.
    public struct NameIndex: Sendable {
        private let idsByToken: [String: Set<String>]
        private let people: [String: Person]

        public init(graph: GedcomFamilyGraph) {
            var idsByToken: [String: Set<String>] = [:]
            for (id, person) in graph.people {
                for name in [person.name] + person.alternateNames {
                    for token in FamilyIdentityText.tokens(name) {
                        idsByToken[GedcomFamilyGraph.diminutives[token] ?? token, default: []].insert(id)
                    }
                }
            }
            self.idsByToken = idsByToken
            self.people = graph.people
        }

        /// Same result, same order, as `graph.people(namedLike:)`.
        public func people(namedLike typed: String) -> [Person] {
            guard let tokens = GedcomFamilyGraph.namedLikeTokens(typed) else { return [] }
            // Narrow: candidates must carry EVERY token somewhere in their
            // names. Start from the rarest token so the intersection is small.
            var sets = tokens.compactMap { idsByToken[$0] }
            guard sets.count == tokens.count else { return [] }
            sets.sort { $0.count < $1.count }
            var candidates = sets[0]
            for set in sets.dropFirst() {
                candidates.formIntersection(set)
                if candidates.isEmpty { return [] }
            }
            // Confirm with the exact per-NAME-record predicate.
            return candidates.compactMap { people[$0] }
                .filter { GedcomFamilyGraph.personMatches($0, namedLikeTokens: tokens) }
                .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
        }
    }
}
