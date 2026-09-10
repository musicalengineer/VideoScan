import Foundation

/// Keep an explicit person fact in the knowledge domain before model translation.
/// The identity oracle includes GEDCOM/CyberBrain, not just video-tagged people.
enum HalliePersonFactQuestion {
    static func detect(_ question: String, isKnownPerson: (String) -> Bool) -> ArchivistQueryAST.Graph? {
        guard question.count <= 512 else { return nil }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
            .replacingOccurrences(of: "’", with: "'")
        let patterns: [(String, ArchivistQueryAST.Graph.Operation)] = [
            (#"^(?:where|what (?:country|town|city|place)) (?:was|were) (.+?) born(?: in)?$"#, .birthPlace),
            (#"^where (?:did|was) (.+?) (?:die|died)$"#, .deathPlace),
            (#"^when (?:was|were) (.+?) born$"#, .birth),
            (#"^when did (.+?) die$"#, .death),
            (#"^(?:tell me about|who is|who was) (.+?)$"#, .biography)
        ]
        for (pattern, operation) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: 1), in: text) else { continue }
            var subject = String(text[range]).trimmingCharacters(in: .whitespaces)
            // One person, two requested facts. Biography already carries the
            // supported life facts; do not turn either clause into keywords.
            if operation == .biography,
               let suffix = subject.range(of: #"\s+and where (?:she|he|they) (?:was|were) born$"#,
                                          options: [.regularExpression, .caseInsensitive]) {
                subject = String(subject[..<suffix.lowerBound])
            }
            let relative = subject.range(
                of: #"^(?:my|our) (?:(?:maternal|paternal) )?(?:great[ -]){0,2}(?:grandmother|grandma|gramma|granny|grandfather|grandpa|grampa)$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
            guard relative || isKnownPerson(subject) else { return nil }
            return .init(people: [subject], operation: operation)
        }
        return nil
    }

    static func isTreeCorrection(_ question: String) -> Bool {
        guard question.count <= 512 else { return false }
        let text = question.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?"))
        return text.range(
            of: #"^(?:(?:please|can you|could you) )?(?:look(?: it)?(?: up)?(?: in| at)?|check|use|try)(?: the)? (?:family )?tree$"#,
            options: .regularExpression) != nil
    }
}
