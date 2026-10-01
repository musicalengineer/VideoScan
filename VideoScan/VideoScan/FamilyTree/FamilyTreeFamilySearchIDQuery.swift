// FamilyTreeFamilySearchIDQuery.swift
// Search the tree by FamilySearch ID (Rick 2026-10-01). Typing or pasting
// an ID like "KCGS-M89" into the Family Tree's search field finds the one
// record carrying it and focuses that person.
//
// THE SHAPE: 4 letters/digits, a dash, 3 letters/digits — case-insensitive,
// surrounding whitespace ignored ("kcgs-m89 " works). Anything else is not
// an ID query and goes to the ordinary name search untouched.
//
// AN ID-SHAPED QUERY THAT NOBODY CARRIES also falls through to the name
// search: "Anne-Mar" has the shape, and must still find Anne-Marie by name.
//
// COST: the shape check is a few character tests; the lookup is the graph's
// FamilySearch-ID index (`GedcomFamilyGraph.person(familySearchID:)`, O(1),
// built at parse). Nothing here scans the people.
//
// (For Rick: an `enum` with no cases ≈ a C++ namespace of static functions.)

import Foundation
import VideoScanCore

enum FamilyTreeFamilySearchIDQuery {

    /// The canonical (upper-cased, trimmed) FamilySearch ID when `text` is
    /// shaped like one, else nil. Pure; the matcher the search uses.
    static func normalizedID(_ text: String) -> String? {
        let key = text.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        // Quick reject before the full check: an ID is exactly 8 characters.
        guard key.count == 8 else { return nil }
        return GedcomFamilyGraph.isFamilySearchID(key) ? key : nil
    }

    /// The person in `graph` whose FamilySearch ID is EXACTLY the typed one
    /// (case-insensitive), or nil — not ID-shaped, or no one carries it.
    static func match(_ text: String, in graph: GedcomFamilyGraph) -> GedcomFamilyGraph.Person? {
        guard let id = normalizedID(text) else { return nil }
        return graph.person(familySearchID: id)
    }
}
