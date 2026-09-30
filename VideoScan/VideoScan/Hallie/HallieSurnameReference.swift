// HallieSurnameReference.swift
// Sourced public reference answers, kept separate from private family facts.

import Foundation

enum HallieSurnameReference {
    private struct Entry: Sendable {
        let surname: String
        let prose: String
        let citations: [HallieTurnExecutor.KnowledgeCitation]
    }

    static let supportedSurnames = entries.values.map(\.surname).sorted()

    static func answer(_ question: String) -> HallieTurnExecutor.Result? {
        let normalized = normalize(question)
        guard isHeritageQuestion(normalized) else { return nil }
        let matches = entries.values.filter {
            mentionsSurname($0.surname, in: normalized)
        }
        guard matches.count == 1, let entry = matches.first else { return nil }

        return HallieTurnExecutor.Result(
            route: .conversation,
            outcome: .answered,
            prose: entry.prose,
            basisLine: "Basis: public surname references; this is surname history, not a claim about the \(entry.surname) family tree.",
            queryDescription: "public surname history: \(entry.surname)",
            citations: [],
            knowledgeCitations: entry.citations,
            catalogPersonName: nil,
            offeredActions: [.openFamilyTreeSurname(entry.surname)])
    }

    private static func isHeritageQuestion(_ normalized: String) -> Bool {
        let cues = [
            "surname", "last name", "family name", "origin", "origins", "roots",
            "heritage", "etymology", "gaelic", "name mean", "name come from",
            "irish name", "scottish name", "english name", "o'brien", "o braoin",
        ]
        if cues.contains(where: normalized.contains) { return true }

        return entries.values.contains { entry in
            let surname = NSRegularExpression.escapedPattern(for: normalize(entry.surname))
            return normalized.range(
                of: "\\bwhere (does|did|are) (the )?\(surname)s?\\b",
                options: .regularExpression) != nil
        }
    }

    private static func mentionsSurname(_ surname: String, in normalized: String) -> Bool {
        let escaped = NSRegularExpression.escapedPattern(for: normalize(surname))
        return normalized.range(
            of: "\\b\(escaped)s?\\b",
            options: .regularExpression) != nil
    }

    private static func normalize(_ text: String) -> String {
        text.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "’", with: "'")
    }

    /// Public surname history is data, not a growing branch of special cases.
    /// Add an entry only when a defensible public source can travel with it.
    private static let entries: [String: Entry] = [
        "breen": Entry(
            surname: "Breen",
            prose: "The Breen surname is Irish and is generally traced to Ó Braoin, meaning ‘descendant of Braon.’ Historical surname sources describe several distinct Ó Braoin families. One line was sometimes recorded as O’Brien, but that spelling alone does not establish descent from the separate Ó Briain, or O’Brien, dynasty. To identify your family’s particular branch, I’d want to trace its county and documentary records.",
            citations: [
                .init(id: "public.woulfe.o-braoin",
                      title: "Ó Braoin — Irish Names and Surnames",
                      attribution: "Rev. Patrick Woulfe (1923)",
                      locator: "https://www.libraryireland.com/names/ob/o-braoin.php"),
                .init(id: "public.familysearch.breen",
                      title: "Breen Name Meaning",
                      attribution: "Dictionary of American Family Names via FamilySearch",
                      locator: "https://www.familysearch.org/en/surname?surname=breen"),
            ]),
        "hudson": Entry(
            surname: "Hudson",
            prose: "Hudson is an English patronymic surname: it comes from the Middle English personal name Hudde plus ‘son.’ The same surname also became established in Ireland. That describes the public history of the name; locating your Hudson branch still requires the family’s records and places.",
            citations: [
                .init(id: "public.familysearch.hudson",
                      title: "Hudson Name Meaning",
                      attribution: "Dictionary of American Family Names via FamilySearch",
                      locator: "https://www.familysearch.org/en/surname?surname=hudson"),
            ]),
        "latta": Entry(
            surname: "Latta",
            prose: "Latta has more than one recorded surname origin. The Scottish form is described as a variant of Lawtie, from an older word associated with honesty or loyalty. A Polish origin is also recorded but remains unexplained, and the surname is found in Germany as well. Your Latta family’s documents and locations are what can distinguish among those possibilities.",
            citations: [
                .init(id: "public.familysearch.latta",
                      title: "Latta Name Meaning",
                      attribution: "Dictionary of American Family Names via FamilySearch",
                      locator: "https://www.familysearch.org/en/surname?surname=latta"),
            ]),
        "mcgill": Entry(
            surname: "McGill",
            prose: "McGill has several documented Scottish and Irish Gaelic derivations, so it should not be assigned one origin without family records. Sources include Mac an Ghoill, ‘son of the stranger or lowlander,’ and Mac Giolla or Mac Gille forms associated with a servant, follower, or devotee, sometimes shortened from a longer saint’s name. Your McGill branch’s locations and records are needed to tell which history applies.",
            citations: [
                .init(id: "public.familysearch.mcgill",
                      title: "McGill Name Meaning",
                      attribution: "Dictionary of American Family Names via FamilySearch",
                      locator: "https://www.familysearch.org/en/surname?surname=mcgill"),
                .init(id: "public.woulfe.mac-giolla",
                      title: "Mac Giolla — Irish Names and Surnames",
                      attribution: "Rev. Patrick Woulfe (1923)",
                      locator: "https://www.libraryireland.com/names/macg/mac-giolla.php"),
            ]),
    ]
}
