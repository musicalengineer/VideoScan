import Foundation

/// Keep an explicit person fact in the knowledge domain before model translation.
/// The identity oracle includes GEDCOM/CyberBrain, not just video-tagged people.
enum HalliePersonFactQuestion {
    static func detect(_ question: String, isKnownPerson: (String) -> Bool) -> ArchivistQueryAST.Graph? {
        guard question.count <= 512 else { return nil }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
            .replacingOccurrences(of: "’", with: "'")
        // The person card wins (nightly 2026-09-12): "tell me about rick's
        // family tree, his brothers, sisters, parents, and grandparents" is
        // a person-tree ask (HallieLineageQuestion.personTree), never a
        // biography of the whole clause. This lane runs before the lineage
        // detector (e7d71578), so an identity oracle that accepts the
        // clause as a name used to hand the card to the graph biography.
        let lineage = HallieLineageQuestion.detect(question)
        if case .personTree? = lineage { return nil }
        // A PRONOUN-POSSESSED kin phrase is a kinship ask about the
        // remembered person, never a name for the identity oracle to accept
        // (strict-015, live replay 2026-09-13: "tell me about his parents").
        // The lineage detector claims it; this lane steps aside whatever the
        // oracle would have said about "his parents".
        if case .kinship(let person?, _, _)? = lineage,
           HalliePronounContinuity.isThirdPersonPronoun(person) { return nil }
        // Military-service shapes first (2026-09-11): "did my dad serve in
        // the marines" is a biography ask about ONE person whose subject
        // takes the same road as every other fact; the generic "tell me
        // about (.+)" below would otherwise swallow "my dad's military
        // service" whole and find nobody by that name.
        let patterns: [(String, ArchivistQueryAST.Graph.Operation)] =
            HallieServiceQuestion.subjectPatterns.map { ($0, .biography) } + [
            (#"^(?:where|what (?:country|town|city|place)) (?:was|were) (.+?) born(?: in)?$"#, .birthPlace),
            (#"^where (?:did|was) (.+?) (?:die|died)$"#, .deathPlace),
            (#"^when (?:was|were) (.+?) born$"#, .birth),
            (#"^when did (.+?) die$"#, .death),
            // "tell me all about Edward III" (strict-005, live replay
            // 2026-09-13): the opener was exactly "tell me about", so the
            // sentence reached the translator and "all about" became search
            // keywords (shape=presence person=edward iii keyword=all about).
            // The everyday widenings of the same request open the biography;
            // the remainder must still be a person the oracle knows, so
            // "tell me all about the wedding video" keeps its catalog road.
            // "what do you know about X" is NOT here: HallieAppV2Integration
            // relies on it as a phrasing outside this lane.
            (#"^(?:tell (?:me|us) (?:(?:all|more|everything) )?about|who is|who was) (.+?)$"#, .biography)
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
            // GH #180 (live 2026-09-10/11): "tell me about dad" had no owner
            // and fell to the model; the graph lane then fuzzy-matched
            // "dad" to Dafydd ab Einion (b. ~1360). A BARE kin word is the
            // owner's relative unless it is a known person's alias (Rick's
            // "Ma" is Eileen, "Mom" is Donna in the kids' videos) — the
            // alias wins, exactly as it does for any known name.
            if !isKnownPerson(subject), Self.isBareKinWord(subject) {
                return .init(people: ["my " + subject.lowercased()], operation: operation)
            }
            let relative = subject.range(
                of: #"^(?:my|our) (?:(?:maternal|paternal) )?(?:great[ -]){0,2}(?:grandmother|grandma|gramma|granny|grandfather|grandpa|grampa|gramps|grandad|granddad|mother|mom|mum|mama|ma|father|dad|daddy|papa|pa|nana|nan)$"#,
                options: [.regularExpression, .caseInsensitive]) != nil
            guard relative || isKnownPerson(subject) else { return nil }
            return .init(people: [subject], operation: operation)
        }
        return nil
    }

    private static let biographyOpener = try! NSRegularExpression(
        pattern: #"^(?:tell (?:me|us) (?:(?:all|more|everything) )?about|who is|who was) (.+?)$"#,
        options: .caseInsensitive)
    private static let notANameLead: Set<String> = [
        "the", "a", "an", "my", "our", "your", "his", "her", "their", "this",
        "that", "these", "those", "some", "any", "all", "every", "each",
    ]

    /// TREE MODE ONLY (docs/hallie_two_mode_design.md §3.4 C): the
    /// biography opener matched, the remainder reads as a proper name —
    /// one to five capitalisable words, no article or possessive lead, no
    /// kin word, media noun or pronoun — and the identity oracle knows no
    /// such person. Nil for everything else, including everything
    /// `detect` would have claimed. The caller turns it into an honest
    /// "not in the tree" instead of letting the translator make a catalog
    /// search of "all about".
    static func unresolvedBiographySubject(_ question: String, isKnownPerson: (String) -> Bool) -> String? {
        guard question.count <= 512 else { return nil }
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
            .replacingOccurrences(of: "’", with: "'")
        guard let match = biographyOpener.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        let subject = String(text[range]).trimmingCharacters(in: .whitespaces)
        let tokens = subject.lowercased().split(separator: " ").map(String.init)
        guard (1...5).contains(tokens.count), let lead = tokens.first,
              !notANameLead.contains(lead) else { return nil }
        guard tokens.allSatisfy({ token in
            token.allSatisfy { $0.isLetter || $0 == "'" || $0 == "-" || $0 == "." }
        }) else { return nil }
        guard !tokens.contains(where: { token in
            HallieMediaVocabulary.all.contains(token)
                || HalliePronounContinuity.kinNouns.contains(token)
                || HalliePronounContinuity.isThirdPersonPronoun(token)
                || HallieTurnExecutor.isSpeakerPronoun(token)
                || isBareKinWord(token)
        }) else { return nil }
        guard !isKnownPerson(subject) else { return nil }
        return subject
    }

    /// One word that names an immediate relative of the speaker with no
    /// possessive: dad, mom, ma, nana, grandpa… (a side or "great" prefix
    /// keeps the possessive path: "maternal grandmother" is not bare).
    static func isBareKinWord(_ subject: String) -> Bool {
        HallieTurnExecutor.RelativeFactSubject.bareKinWords[subject.lowercased()] != nil
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
