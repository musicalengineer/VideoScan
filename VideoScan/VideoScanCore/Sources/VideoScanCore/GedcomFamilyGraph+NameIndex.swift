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

    /// The spellings a bare given name stands for (2026-08-29): a nickname
    /// means itself and its formal name ("rick" → rick, richard); a formal
    /// name means itself and every nickname the curated table maps to it
    /// ("richard" → richard, dick, rich, richie, rick, ricky). A nickname
    /// NEVER reaches a sibling nickname — Rick's father is Dick, two people.
    public static func givenNameForms(of token: String) -> [String] {
        if let formal = diminutives[token] { return [token, formal] }
        return [token] + diminutives.filter { $0.value == token }.map(\.key).sorted()
    }

    /// Bare given-name lookup (live 2026-08-28: "rick" on a 16k tree offered
    /// Catherine Auker b. 1374, whose alternate NAME record is the bare
    /// token "Rich" — `people(namedLike:)` expands RECORD tokens through
    /// the diminutive table too, so a surname or alternate-name stub "Rich"
    /// / "Dick" becomes "richard" and collides with typed "rick").
    ///
    /// The rule for ONE typed token: the person's PRIMARY NAME record's
    /// first token (the given name) is the typed token or — with
    /// `expandDiminutives` — one of `givenNameForms(of:)`. Surnames, middle
    /// names, alternate-name stubs and married names never match a bare
    /// token. Name order, like every lookup. O(log tokens + hits).
    /// C++ readers: the givenNames posting list narrows (any record's first
    /// token); the primary-record check is the exact predicate.
    public func people(givenName typed: String, expandDiminutives: Bool) -> [Person] {
        guard let token = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(typed)).first,
              !Self.nameSuffixes.contains(token) else { return [] }
        let keys = expandDiminutives ? Self.givenNameForms(of: token) : [token]
        let keySet = Set(keys)
        let index = self.index
        var ordinals: [Int32] = []
        for key in keys { ordinals = PostingTable.union(ordinals, index.givenNames.postings(for: key)) }
        let hits = ordinals.filter { o in
            let primary = index.records(of: o).lowerBound
            guard let first = index.tokenIDs(ofRecord: primary).first else { return false }
            return keySet.contains(index.tokens.keys[Int(first)])
        }
        return peopleInNameOrder(hits, index: index)
    }

    /// The linear form of `people(givenName:expandDiminutives:)`, for the
    /// equivalence test and any caller without an index.
    public static func personHasGivenName(_ person: Person, forms: Set<String>) -> Bool {
        guard let first = FamilyIdentityText.tokens(person.name).first else { return false }
        return forms.contains(first)
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
