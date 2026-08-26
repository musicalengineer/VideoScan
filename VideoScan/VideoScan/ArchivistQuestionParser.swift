import Foundation
import VideoScanCore

enum ArchivistGeneralQuestion: Equatable {
    case ancestry
    case lifeDate(personText: String, birth: Bool)
    case biography(personText: String)
}

struct ArchivistKinshipQuestion {
    struct PossessorCandidate: Equatable {
        let personText: String
        let matchedPhrase: String
    }

    let relation: GedcomFamilyGraph.Relation
    let relationWord: String
    /// Longest plausible suffix first. The handler asks the injected family
    /// identity resolver which suffix is a real person; carrier words such as
    /// "show videos of" therefore never become part of the identity.
    let possessors: [PossessorCandidate]
}

/// Pure parsing seam for the local, deterministic family-question routes.
/// It deliberately extracts text rather than deciding identity: only the
/// POI/GEDCOM resolver is allowed to say which family member a name denotes.
enum ArchivistQuestionParser {
    static let maxPossessorWords = 6

    static func general(_ text: String) -> ArchivistGeneralQuestion? {
        // The chat currently asks the general parser before the kinship
        // parser. Decline nested possessive relations here so questions such
        // as "Who was Rick's father?" reach the relation resolver first;
        // after it substitutes the father's canonical name, the rewritten
        // "Who was …?" question returns here for the biography answer.
        if kinship(text) != nil { return nil }
        // Multi-hop possessives ("Rick's great great grandpa on his paternal
        // side") are not biographies of a person called "Rick's great great
        // grandpa" either; HallieLineageQuestion.kinshipQuestion owns them.
        if hasAncestorPossessive(text) { return nil }

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = trimmed.lowercased()
        if lower.contains("family tree") || lower.contains("ancestry")
            || lower.contains("family history") {
            return .ancestry
        }

        if let match = trimmed.firstMatch(
            of: /when (?:was|did)\s+(.+?)\s+(born|die|died)/.ignoresCase()) {
            let person = cleanName(String(match.1))
            guard !person.isEmpty else { return nil }
            return .lifeDate(
                personText: person,
                birth: String(match.2).lowercased() == "born")
        }

        for prefix in ["who is ", "who was ", "tell me about "] {
            guard lower.hasPrefix(prefix) else { continue }
            let start = trimmed.index(trimmed.startIndex,
                                      offsetBy: prefix.count)
            let person = cleanName(String(trimmed[start...]))
            guard !person.isEmpty else { return nil }
            return .biography(personText: person)
        }
        return nil
    }

    static func kinship(_ text: String) -> ArchivistKinshipQuestion? {
        guard let match = text.firstMatch(
            of: /(.+?)(['’]s\s+)([A-Za-z]+)/),
              let relation = GedcomFamilyGraph.relation(
                fromWord: String(match.3)) else { return nil }

        let prefix = match.1
        let words = prefix.split(whereSeparator: { $0.isWhitespace })
        guard !words.isEmpty else { return nil }
        let firstAllowed = max(0, words.count - maxPossessorWords)
        var candidates: [ArchivistKinshipQuestion.PossessorCandidate] = []
        for startOffset in firstAllowed..<words.count {
            let candidateSlice = prefix[words[startOffset].startIndex...]
            let person = cleanName(String(candidateSlice))
            guard !person.isEmpty else { continue }
            candidates.append(.init(
                personText: person,
                matchedPhrase: String(candidateSlice)
                    + String(match.2) + String(match.3)))
        }
        guard !candidates.isEmpty else { return nil }
        return ArchivistKinshipQuestion(
            relation: relation,
            relationWord: String(match.3),
            possessors: candidates)
    }

    /// "<person>'s [maternal|paternal] (great )*grand<x>" / "my grand<x>":
    /// a multi-word ancestor relation the single-word `kinship` parser
    /// cannot type. Mirrors HallieLineageQuestion.kinshipQuestion's shape.
    static func hasAncestorPossessive(_ text: String) -> Bool {
        let lower = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        guard let m = lower.firstMatch(
            of: /(?:^|\s)(?:my|our|[a-z][a-z .'-]*?'s?)\s+(?:(?:maternal|paternal|mother'?s|father'?s)\s+)?((?:great[- ]?)*grand[a-z]+)\b/)
        else { return false }
        let words = String(m.1).replacingOccurrences(of: "-", with: " ")
        return GedcomFamilyGraph.extendedRelation(fromPhrase: words)?.relation.startsAtParents == true
    }

    private static func cleanName(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!,:;"))
    }
}
