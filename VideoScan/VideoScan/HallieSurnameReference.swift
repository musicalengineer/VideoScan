// HallieSurnameReference.swift
// Small, sourced public reference answers that should not be mistaken for
// private family-tree facts. These run before archive translation so Hallie
// can answer a surname-history question without inventing genealogy.

import Foundation

enum HallieSurnameReference {
    static func answer(_ question: String) -> HallieTurnExecutor.Result? {
        guard isBreenHeritageQuestion(question) else { return nil }

        return HallieTurnExecutor.Result(
            route: .conversation,
            outcome: .answered,
            prose: "The Breen surname is Irish and is generally traced to Ó Braoin, meaning ‘descendant of Braon.’ Historical surname sources describe several distinct Ó Braoin families. One line was sometimes recorded as O’Brien, but that spelling alone does not establish descent from the separate Ó Briain, or O’Brien, dynasty. To identify your family’s particular branch, I’d want to trace its county and documentary records.",
            basisLine: "Basis: public Irish surname references; this is surname history, not a claim about the Breen family tree.",
            queryDescription: "public surname history: Breen",
            citations: [],
            knowledgeCitations: [
                .init(
                    id: "public.woulfe.o-braoin",
                    title: "Ó Braoin — Irish Names and Surnames",
                    attribution: "Rev. Patrick Woulfe (1923)",
                    locator: "https://www.libraryireland.com/names/ob/o-braoin.php"),
                .init(
                    id: "public.familysearch.breen",
                    title: "Breen Name Meaning",
                    attribution: "Dictionary of American Family Names via FamilySearch",
                    locator: "https://www.familysearch.org/en/surname?surname=breen"),
            ],
            catalogPersonName: nil,
            offeredActions: [.openFamilyTreeSurname("Breen")])
    }

    private static func isBreenHeritageQuestion(_ question: String) -> Bool {
        let normalized = question
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .replacingOccurrences(of: "’", with: "'")
        guard normalized.range(
            of: #"\bbreens?\b"#,
            options: .regularExpression) != nil else { return false }

        let heritageCues = [
            "surname", "last name", "family name", "origin", "origins", "roots",
            "heritage", "etymology", "gaelic", "irish name", "name mean",
            "name come from", "o'brien", "o braoin",
        ]
        if heritageCues.contains(where: normalized.contains) { return true }

        return normalized.range(
            of: #"\bwhere (does|did|are) (the )?breens?\b"#,
            options: .regularExpression) != nil
    }
}
