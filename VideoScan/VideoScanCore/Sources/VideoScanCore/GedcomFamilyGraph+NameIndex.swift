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
        let tokens = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(typed))
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
    /// Inverted token → person index over every NAME record. Since
    /// 2026-08-28 this is a thin view over the graph's shared `TreeIndex`
    /// (`likeTokens` postings): constructing one no longer builds a
    /// second index, and `people(namedLike:)` here and on the graph are
    /// the same code path.
    public struct NameIndex: Sendable {
        private let graph: GedcomFamilyGraph

        public init(graph: GedcomFamilyGraph) {
            self.graph = graph
            _ = graph.index
        }

        /// Same result, same order, as `graph.people(namedLike:)`.
        public func people(namedLike typed: String) -> [Person] {
            graph.people(namedLike: typed)
        }
    }
}
