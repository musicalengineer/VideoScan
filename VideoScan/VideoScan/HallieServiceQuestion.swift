// HallieServiceQuestion.swift
// "did my dad serve in the marines?" — a question about ONE person's
// military service (Rick 2026-09-11: "I'd like Hallie to mention my dad's
// Marine Corps service in the 1940s"). Eight phrasings replayed against
// the live build that day and every one missed: three declined the
// resolved father with "one person at a time", two fuzzy-matched "dad" to
// Dafydd ab Einion (b. ~1360), one read "marine corps" as a surname, and
// "Richard Breen Sr's time in the Marine Corps" answered with his birth
// and death — the tree's biography, not the family's passage.
//
// This file only RECOGNISES the shape and names its subject. The subject
// then travels the ordinary person-fact road (bare kin word → owner's
// relative; possessive; known name; which-one chips), and the answer is
// composed from CyberBrain passages that mention service
// (HallieTurnExecutor+Service). No tree fact is ever read as service.

import Foundation

enum HallieServiceQuestion {

    /// Branches and service words a question must name to be about service.
    private static let branch =
        #"(?:military|service|armed forces|marines|marine corps|the corps|army|navy|air force|coast guard|national guard|usmc|reserves)"#
    /// Wars a question may name instead of a branch ("did dad fight in WWII").
    private static let war =
        #"(?:(?:world )?war(?: (?:two|ii|2|one|i|1))?|wwii|ww2|wwi|ww1|korea|the korean war|vietnam)"#
    /// One person's role ("was grampa a marine").
    private static let role =
        #"(?:marine|soldier|sailor|veteran|vet|airman|serviceman|servicewoman|coast guardsman|gi|officer)"#
    /// Adjectives that make "service"/"record"/"time" a service ask.
    private static let serviceAdjective =
        #"(?:military|marine corps|marine|marines|army|navy|naval|air force|coast guard|wartime|war|service)"#

    /// Regexes whose FIRST capture group is the subject, in the shape
    /// HalliePersonFactQuestion already understands ("dad", "my dad",
    /// "grampa breen", "richard breen sr"). Order matters only for speed.
    static let subjectPatterns: [String] = [
        // did my dad serve in the marines / did dad fight in WWII / has my father ever served in the military
        #"^(?:did|does|was|were|is|has|had) (.+?) (?:ever )?(?:serve|served|enlist|enlisted|fight|fought)(?: in| with| for| during)? (?:the )?(?:"# + branch + "|" + war + #")(?: .*)?$"#,
        // was my father in the military / is dad in the reserves
        #"^(?:was|were|is) (.+?) (?:ever )?(?:in|with) the (?:"# + branch + "|" + war + #")(?: .*)?$"#,
        // was grampa breen a marine / is dad a veteran
        #"^(?:was|were|is) (.+?) (?:ever )?(?:a|an) "# + role + #"(?: .*)?$"#,
        // tell me about my dad's military service / describe dad's marine corps record
        #"^(?:tell me about|what (?:do you know|can you tell me) about|what about|describe|talk about) (.+?)(?:'s|s') "# + serviceAdjective + #" (?:service|record|time|years|career|days|enlistment|history)$"#,
        // tell me about richard breen sr's time in the marine corps
        #"^(?:tell me about|what (?:do you know|can you tell me) about|what about|describe|talk about) (.+?)(?:'s|s') (?:service|time|years|days|enlistment|stint) (?:in|with) the "# + branch + #"$"#,
        // tell me about dad's time as a marine
        #"^(?:tell me about|what (?:do you know|can you tell me) about|what about|describe|talk about) (.+?)(?:'s|s') (?:service|time|years|days) as (?:a|an) "# + role + #"$"#,
        // what branch of the service was dad in / which branch did my father serve in
        #"^(?:what|which) (?:service )?branch(?: of (?:the )?(?:service|military|armed forces))? (?:was|were|did|is) (.+?)(?: in| serve in| serve with| join)?$"#,
        // when was dad in the marines / when did my father join the navy
        #"^when (?:was|were|did) (.+?) (?:ever )?(?:in|serve in|serve with|join|enlist in|with) the (?:"# + branch + "|" + war + #")(?: .*)?$"#,
        // when did dad serve
        #"^when did (.+?) serve$"#,
        // where was dad stationed / where did my father serve
        #"^where (?:was|were|did) (.+?) (?:serve|stationed|deployed|posted)(?: .*)?$"#,
        // what did dad do in the war / in the navy
        #"^what did (.+?) do (?:in|during) (?:the )?(?:"# + branch + "|" + war + #")$"#,
    ]

    /// Questions about the whole family, no subject: "who in the family
    /// served in the marine corps?", "did anyone in the family serve?".
    private static let familyWidePatterns: [String] = [
        #"^(?:who|which (?:of us|family members?|relatives?)) (?:in (?:the|our|my) family |among (?:us|the family) |of (?:us|the family) )?(?:has |have |had |ever )?(?:served|was|were|is|are|been) (?:in |with )?(?:the )?(?:"# + branch + "|" + war + #")(?: .*)?$"#,
        #"^(?:who|which (?:of us|family members?|relatives?)) (?:in (?:the|our|my) family |among (?:us|the family) |of (?:us|the family) )?(?:was|were|is|are) (?:a |an )?(?:marines?|soldiers?|sailors?|veterans?|vets)$"#,
        #"^(?:did|has|have) (?:anyone|anybody|someone|any of (?:us|the family))(?: in (?:the|our|my) family)? (?:ever )?(?:serve|served)(?: in| with)?(?: the)?(?: "# + branch + "| " + war + #")?$"#,
        #"^(?:who|which (?:of us|family members?|relatives?)) (?:in (?:the|our|my) family |among (?:us|the family) |of (?:us|the family) )?(?:has |have |had |ever )?(?:served|fought)(?: in the (?:"# + war + #"))?$"#,
    ]

    /// Words that mark a CyberBrain passage as being about service.
    private static let passagePattern =
        #"\b(?:marines?|marine corps|usmc|military|army|navy|naval|air force|coast guard|national guard|served|serving|enlisted|enlistment|veteran|soldier|sailor|airman|wwii|ww2|wwi|world war|korean war|vietnam war|armed forces|drafted|stationed|deployed)\b"#

    private static func normalized(_ question: String) -> String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
            .replacingOccurrences(of: "’", with: "'")
    }

    private static func match(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The subject of a one-person service question, as typed; nil when
    /// the question is not about service.
    static func subject(in question: String) -> String? {
        guard question.count <= 512 else { return nil }
        let text = normalized(question)
        for pattern in subjectPatterns {
            guard let found = match(pattern, in: text),
                  let range = Range(found.range(at: 1), in: text) else { continue }
            let subject = String(text[range]).trimmingCharacters(in: .whitespaces)
            guard !subject.isEmpty else { continue }
            return subject
        }
        return nil
    }

    /// True for any one-person service question, whatever the subject.
    static func isServiceQuestion(_ question: String) -> Bool {
        subject(in: question) != nil
    }

    /// "who in the family served in the marine corps?"
    static func isFamilyWideAsk(_ question: String) -> Bool {
        guard question.count <= 512 else { return false }
        let text = normalized(question)
        return familyWidePatterns.contains { match($0, in: text) != nil }
    }

    /// A CyberBrain passage that speaks about service.
    static func mentionsService(_ passage: String) -> Bool {
        match(passagePattern, in: passage) != nil
    }
}
