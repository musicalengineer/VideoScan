// HallieServiceQuestion.swift
// Recognises questions about military service — ONE person's ("did my dad
// serve in the marines?") or the whole family's ("who in our family served
// in the Civil War?", "was anyone in the family in World War 2?") — and
// which war, if any, the question names.
//
// History:
//   2026-09-11 (Rick: "I'd like Hallie to mention my dad's Marine Corps
//   service in the 1940s"). Eight phrasings replayed against the live build
//   that day and every one missed: three declined the resolved father with
//   "one person at a time", two fuzzy-matched "dad" to Dafydd ab Einion
//   (b. ~1360), one read "marine corps" as a surname, and "Richard Breen
//   Sr's time in the Marine Corps" answered with his birth and death.
//   2026-09-23 (Rick: "I'd like hallie to be able to answer those family
//   queries re: american war for independence, the american civil war,
//   world war 1 and world war 2"). The four wars and their everyday names
//   ("the Revolution", "the War Between the States", "the Great War",
//   "WW2"), and family-wide asks that name one.
//
// This file only RECOGNISES the shape and names its subject / war. A one-
// person subject travels the ordinary person-fact road (bare kin word →
// owner's relative; possessive; known name; which-one chips); the answer is
// composed in HallieTurnExecutor+Service from the family's service records
// and passages, and from military facts the family tree itself records.
// Nothing here is a fact about the family.
//
// What is deliberately NOT claimed: a war question with no family in it
// ("tell me about the Civil War", "who won World War II") is general
// knowledge; a life event dated by a war ("who in the family was born
// during the Civil War") is not service; a media ask ("videos from the
// Civil War reenactment") is a catalog search.

import Foundation
import VideoScanCore

enum HallieServiceQuestion {

    // MARK: - The wars

    /// The wars Rick asked about by name. Everyday names map here; any
    /// other war a question names is `FamilyAsk.otherWar`.
    enum War: String, CaseIterable, Sendable, Equatable {
        case americanRevolution, civilWar, worldWarI, worldWarII

        var conflict: CyberBrainServiceRecord.Conflict {
            switch self {
            case .americanRevolution: return .americanRevolution
            case .civilWar: return .civilWar
            case .worldWarI: return .worldWarI
            case .worldWarII: return .worldWarII
            }
        }

        init?(_ conflict: CyberBrainServiceRecord.Conflict) {
            switch conflict {
            case .americanRevolution: self = .americanRevolution
            case .civilWar: self = .civilWar
            case .worldWarI: self = .worldWarI
            case .worldWarII: self = .worldWarII
            case .other: return nil
            }
        }

        /// How Hallie names it in a sentence.
        var name: String {
            switch self {
            case .americanRevolution: return "the American Revolution"
            case .civilWar: return "the Civil War"
            case .worldWarI: return "World War I"
            case .worldWarII: return "World War II"
            }
        }

        /// The dated world fact (WorldKnowledge) — its year span decides
        /// which family-tree military facts are listed under this war.
        var worldFact: WorldFact? { WorldKnowledge.war(conflict) }

        /// Everyday names, as a regex over lower-cased text with straight
        /// apostrophes. `\b` keeps "world war i" from matching inside
        /// "world war ii".
        fileprivate var pattern: String {
            switch self {
            case .americanRevolution:
                return #"\b(?:(?:the )?american revolution(?:ary war)?|(?:the )?revolutionary war|(?:the )?(?:american )?war (?:for|of) (?:american )?independence|the revolution|(?:the )?continental army)\b"#
            case .civilWar:
                // Not another country's civil war.
                return #"\b(?:(?<!english )(?<!spanish )(?<!irish )(?<!russian )(?<!greek )(?<!chinese )(?<!finnish )(?<!syrian )civil war|(?:the )?war between the states|(?:the )?war of the rebellion|the confedera(?:cy|te army)|confederate (?:army|side|soldiers?)|the union army)\b"#
            case .worldWarI:
                return #"\b(?:world war (?:i|1|one)|(?:the )?first world war|wwi|ww1|ww 1|(?:the )?great war)\b"#
            case .worldWarII:
                return #"\b(?:world war (?:ii|2|two)|(?:the )?second world war|wwii|ww2|ww 2)\b"#
            }
        }
    }

    /// The one war a question names, or nil (none, or more than one).
    static func war(in question: String) -> War? {
        let text = normalized(question).lowercased()
        let named = War.allCases.filter { match($0.pattern, in: text) != nil }
        return named.count == 1 ? named[0] : nil
    }

    /// Wars outside the four, named so Hallie can answer honestly about
    /// THAT war instead of a different one.
    private static let otherWars: [(pattern: String, name: String)] = [
        (#"\b(?:the )?korean war\b|\bkorea\b"#, "the Korean War"),
        (#"\b(?:the )?vietnam(?: war)?\b"#, "the Vietnam War"),
        (#"\b(?:the )?(?:persian )?gulf war\b"#, "the Gulf War"),
        (#"\b(?:the )?war of 1812\b"#, "the War of 1812"),
        (#"\b(?:the )?spanish[- ]american war\b"#, "the Spanish–American War"),
        (#"\b(?:the )?french and indian war\b"#, "the French and Indian War"),
    ]

    // MARK: - One person's service

    /// Branches and service words a question must name to be about service.
    private static let branch =
        #"(?:military|service|armed forces|marines|marine corps|the corps|army|navy|air force|coast guard|national guard|usmc|reserves|british army|confederate army|union army|continental army)"#
    /// Wars a question may name instead of a branch ("did dad fight in WWII").
    private static let war =
        #"(?:(?:world )?war(?: (?:two|ii|2|one|i|1))?|wwii|ww2|wwi|ww1|korea|the korean war|vietnam|civil war|(?:american )?revolution(?:ary war)?|(?:american )?war (?:for|of) independence|war between the states|great war|(?:first|second) world war)"#
    /// One person's role ("was grampa a marine").
    private static let role =
        #"(?:marine|soldier|sailor|veteran|vet|airman|serviceman|servicewoman|coast guardsman|gi|officer|confederate(?: soldier)?|union soldier|redcoat)"#
    /// Adjectives that make "service"/"record"/"time" a service ask.
    private static let serviceAdjective =
        #"(?:military|marine corps|marine|marines|army|navy|naval|air force|coast guard|wartime|war|service|civil war|world war (?:i|ii|1|2|one|two)|wwii|ww2|wwi|ww1|revolutionary war)"#
    private static let tellAbout =
        #"(?:tell me(?: more)? about|what (?:do you know|can you tell me) about|what about|describe|talk about)"#

    /// Regexes whose FIRST capture group is the subject, in the shape
    /// HalliePersonFactQuestion already understands ("dad", "my dad",
    /// "grampa breen", "richard breen sr"). Order matters only for speed.
    static let subjectPatterns: [String] = [
        // did my dad serve in the marines / did dad fight in WWII / has my father ever served in the military
        #"^(?:did|does|was|were|is|has|had) (.+?) (?:ever )?(?:serve|served|enlist|enlisted|fight|fought)(?: in| with| for| during)? (?:the )?(?:"# + branch + "|" + war + #")(?: .*)?$"#,
        // did my dad serve / has grampa ever served / did dad serve his country
        #"^(?:did|has|had) (.+?) (?:ever )?(?:serve|served|enlist|enlisted)(?: (?:his|her|their|the) country)?$"#,
        // was my father in the military / is dad in the reserves / was dad in the civil war
        #"^(?:was|were|is) (.+?) (?:ever )?(?:in|with) the (?:"# + branch + "|" + war + #")(?: .*)?$"#,
        // was grampa breen a marine / is dad a veteran
        #"^(?:was|were|is) (.+?) (?:ever )?(?:a|an) "# + role + #"(?: .*)?$"#,
        // tell me about my dad's military service / describe dad's marine corps record
        #"^"# + tellAbout + #" (.+?)(?:'s|s') "# + serviceAdjective + #" (?:service|record|time|years|career|days|enlistment|history|story)$"#,
        // tell me about richard breen sr's time in the marine corps
        #"^"# + tellAbout + #" (.+?)(?:'s|s') (?:service|time|years|days|enlistment|stint) (?:in|with) the "# + branch + #"$"#,
        // tell me about dad's time as a marine
        #"^"# + tellAbout + #" (.+?)(?:'s|s') (?:service|time|years|days) as (?:a|an) "# + role + #"$"#,
        // tell me about how dad served / tell me how John Robert Latta served his country
        #"^tell me(?: more)?(?: about)? how (.+?) served(?: (?:his|her|their|the) country| in the (?:"# + branch + "|" + war + #"))?$"#,
        // how did dad serve / how did Chris O'Connor serve his country
        #"^how did (.+?) serve(?: (?:his|her|their|the) country)?$"#,
        // what branch of the service was dad in / which branch did my father serve in
        #"^(?:what|which) (?:service )?branch(?: of (?:the )?(?:service|military|armed forces))? (?:was|were|did|is) (.+?)(?: in| serve in| serve with| join)?$"#,
        // which side did John Robert Latta fight on
        #"^(?:which|what) side (?:was|did) (.+?) (?:on|fight on|fight for|serve on)$"#,
        // when was dad in the marines / when did my father join the navy
        #"^when (?:was|were|did) (.+?) (?:ever )?(?:in|serve in|serve with|join|enlist in|with) the (?:"# + branch + "|" + war + #")(?: .*)?$"#,
        // when did dad serve
        #"^when did (.+?) serve$"#,
        // where was dad stationed / where did my father serve
        #"^where (?:was|were|did) (.+?) (?:serve|stationed|deployed|posted)(?: .*)?$"#,
        // what did dad do in the war / in the navy
        #"^what did (.+?) do (?:in|during) (?:the )?(?:"# + branch + "|" + war + #")$"#,
    ]

    /// Subjects that are the whole family, not one person: "did ANYONE
    /// serve in the Civil War" is a family-wide ask.
    private static let familySubjects: Set<String> = [
        "anyone", "anybody", "someone", "somebody", "any of us", "any of them",
        "the family", "our family", "my family", "the breens", "any relatives",
        "any relative", "any ancestors", "any ancestor", "any family members",
        "any family member", "any of our ancestors", "any of my ancestors",
        "any of our relatives", "any of my relatives", "anyone in the family",
        "anyone in our family", "anyone in my family", "anybody in the family",
        "anybody in our family", "anybody in my family", "someone in the family",
        "someone in our family", "someone in my family", "our ancestors",
        "my ancestors", "our relatives", "my relatives", "we",
    ]

    fileprivate static func normalized(_ question: String) -> String {
        question.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "?.!"))
            .replacingOccurrences(of: "’", with: "'")
            .replacingOccurrences(of: "‘", with: "'")
    }

    fileprivate static func match(_ pattern: String, in text: String) -> NSTextCheckingResult? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
        return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// The subject of a one-person service question, as typed; nil when
    /// the question is not about service, or its subject is the whole
    /// family ("did anyone serve…" is `familyAsk`).
    static func subject(in question: String) -> String? {
        guard question.count <= 512 else { return nil }
        let text = normalized(question)
        for pattern in subjectPatterns {
            guard let found = match(pattern, in: text),
                  let range = Range(found.range(at: 1), in: text) else { continue }
            let subject = String(text[range]).trimmingCharacters(in: .whitespaces)
            guard !subject.isEmpty else { continue }
            if familySubjects.contains(subject.lowercased()) { return nil }
            return subject
        }
        return nil
    }

    /// True for any one-person service question, whatever the subject.
    static func isServiceQuestion(_ question: String) -> Bool {
        subject(in: question) != nil
    }

    // MARK: - The whole family's service

    /// A family-wide service ask and the war / branch it is about, if any.
    struct FamilyAsk: Sendable, Equatable {
        /// One of the four wars, when the question names exactly one.
        let war: War?
        /// Another war the question names ("the Korean War"); nil otherwise.
        let otherWar: String?
        /// The branch the question names ("who served in the marines");
        /// nil when it names none or several.
        var branch: Branch? = nil
    }

    /// A branch of service a family-wide question may name. Matching is on
    /// the record's own `force` text and the passage's / tree fact's words —
    /// "the Marine Corps" never lists someone who served in the British Army.
    enum Branch: String, CaseIterable, Sendable, Equatable {
        case marines, britishArmy, army, navy, airForce, coastGuard

        /// How Hallie names it ("who served in the Marine Corps").
        var name: String {
            switch self {
            case .marines: return "the Marine Corps"
            case .britishArmy: return "the British Army"
            case .army: return "the Army"
            case .navy: return "the Navy"
            case .airForce: return "the Air Force"
            case .coastGuard: return "the Coast Guard"
            }
        }

        fileprivate var questionPattern: String {
            switch self {
            case .marines: return #"\b(?:marines?|marine corps|usmc|the corps)\b"#
            case .britishArmy: return #"\bbritish army\b"#
            case .army: return #"\b(?:army|soldiers?)\b"#
            case .navy: return #"\b(?:navy|naval|sailors?)\b"#
            case .airForce: return #"\b(?:air force|airm[ae]n)\b"#
            case .coastGuard: return #"\bcoast ?guard(?:sman|smen)?\b"#
            }
        }

        /// True when a force name or a passage's words are this branch.
        func matches(_ text: String) -> Bool {
            let lower = text.lowercased()
            switch self {
            case .marines: return lower.contains("marine") || lower.contains("usmc")
            case .britishArmy: return lower.contains("british army")
            case .army: return lower.range(of: #"\barmy\b"#, options: .regularExpression) != nil
            case .navy: return lower.contains("navy") || lower.contains("naval")
            case .airForce: return lower.contains("air force")
            case .coastGuard: return lower.contains("coast guard")
            }
        }
    }

    /// The one branch a question names; "British Army" outranks "army".
    static func namedBranch(in question: String) -> Branch? {
        let text = normalized(question).lowercased()
        if match(Branch.britishArmy.questionPattern, in: text) != nil { return .britishArmy }
        let named = Branch.allCases.filter { $0 != .britishArmy && match($0.questionPattern, in: text) != nil }
        return named.count == 1 ? named[0] : nil
    }

    /// Words that put the whole family in scope.
    private static let familyScopePattern =
        #"\b(?:famil(?:y|ies|y's|ys)|ancestors?|ancestry|relatives?|forefathers|forebears|anyone|anybody|someone|somebody|any of us|grandparents|great[- ]grandparents|kin|the breens)\b"#

    /// Service in the military sense, unambiguous on its own.
    private static let strongServicePattern =
        #"\b(?:military|veterans?|vets|soldiers?|sailors?|marines|marine corps|army|navy|air force|coast guard|armed forces|enlisted|drafted|fought|fight|fighting|battles?|combat|war (?:service|record|history|stories|story|veterans?)|served (?:(?:his|her|their|our|the) )?country|service in the|served in the|serve in the|serving in the|redcoats?|continental army|confedera(?:cy|te)|union army)\b"#

    /// "served" / "service" with nothing after it that makes it another
    /// kind of service: "who in the family served?", "any family service
    /// history?" is not enough; the bare verb at the END is.
    private static let bareServedAtEndPattern =
        #"\b(?:served|serve|serving|service)$"#

    /// A war named with a preposition that means taking part ("in the
    /// Civil War", "at Fort Wagner", "during WW2" is NOT one — see below).
    private static let inAWarPattern =
        #"\b(?:in|at|for|with|of|from) (?:the |a |any )?(?:wars?|"# + war + #")\b"#

    /// Life-event and time words: a war used as a DATE ("born during the
    /// Civil War", "married after the war") is not a service ask.
    private static let lifeEventPattern =
        #"\b(?:born|birth|births|die|died|death|deaths|dead|married|marriage|wedding|lived|live|living|moved|immigrated|emigrated|during|after|before|since)\b"#

    /// Other meanings of "service" that must never read as military.
    private static let otherServicePattern =
        #"\b(?:church|funeral|memorial|mass|wedding|dinner|lunch|breakfast|food|catering|customer|civil service|community service|public service|room service|streaming|reenactment|re-enactment|reenactors?)\b"#

    /// The 2026-09-11 family-wide shapes, VERBATIM (with that day's war
    /// list): "who served in the marines", "who was a marine", "who served
    /// in WWII". In Hallie a "who …" about a branch or role means the
    /// family even with no family word, and these answered that way before
    /// 2026-09-23 — kept so nothing that worked regresses. The wars added
    /// on 2026-09-23 are NOT in this list on purpose: "who fought in the
    /// Civil War" with no family in it is world history.
    private static let legacyWar =
        #"(?:(?:world )?war(?: (?:two|ii|2|one|i|1))?|wwii|ww2|wwi|ww1|korea|the korean war|vietnam)"#
    private static let legacyBranch =
        #"(?:military|service|armed forces|marines|marine corps|the corps|army|navy|air force|coast guard|national guard|usmc|reserves)"#
    private static let legacyFamilyWidePatterns: [String] = [
        #"^(?:who|which (?:of us|family members?|relatives?)) (?:in (?:the|our|my) family |among (?:us|the family) |of (?:us|the family) )?(?:has |have |had |ever )?(?:served|was|were|is|are|been) (?:in |with )?(?:the )?(?:"# + legacyBranch + "|" + legacyWar + #")(?: .*)?$"#,
        #"^(?:who|which (?:of us|family members?|relatives?)) (?:in (?:the|our|my) family |among (?:us|the family) |of (?:us|the family) )?(?:was|were|is|are) (?:a |an )?(?:marines?|soldiers?|sailors?|veterans?|vets)$"#,
        #"^(?:did|has|have) (?:anyone|anybody|someone|any of (?:us|the family))(?: in (?:the|our|my) family)? (?:ever )?(?:serve|served)(?: in| with)?(?: the)?(?: "# + legacyBranch + "| " + legacyWar + #")?$"#,
        #"^(?:who|which (?:of us|family members?|relatives?)) (?:in (?:the|our|my) family |among (?:us|the family) |of (?:us|the family) )?(?:has |have |had |ever )?(?:served|fought)(?: in the (?:"# + legacyWar + #"))?$"#,
    ]

    /// The family-wide ask, or nil.
    static func familyAsk(_ question: String) -> FamilyAsk? {
        guard question.count <= 512 else { return nil }
        let text = normalized(question).lowercased()
        guard !text.isEmpty else { return nil }
        // A named person's service is the one-person shape.
        if subject(in: text) != nil { return nil }
        // Media and non-military "service" are other lanes' questions.
        if HallieMediaVocabulary.containsMediaWord(text) { return nil }
        if match(otherServicePattern, in: text) != nil { return nil }
        // A war used only as a date is not a service ask.
        if match(lifeEventPattern, in: text) != nil,
           match(#"\b(?:served|serve|serving|service|fought|fight|veterans?|soldiers?|military)\b"#, in: text) == nil {
            return nil
        }
        let named = war(in: text)
        let other = named == nil ? otherWars.first { match($0.pattern, in: text) != nil }?.name : nil
        // A war names a whole era: "the Confederate army" is the Civil War,
        // not a branch filter. A branch filters only when no war is named.
        let branchFilter = named == nil && other == nil ? namedBranch(in: text) : nil
        if legacyFamilyWidePatterns.contains(where: { match($0, in: text) != nil }) {
            return FamilyAsk(war: named, otherWar: other, branch: branchFilter)
        }
        let scoped = match(familyScopePattern, in: text) != nil
            || text.hasPrefix("who in our ") || text.hasPrefix("which of us")
        guard scoped else { return nil }
        let serviceWords = match(strongServicePattern, in: text) != nil
            || match(bareServedAtEndPattern, in: text) != nil
            || match(inAWarPattern, in: text) != nil
            || text.contains("military history") || text.contains("war history")
        guard serviceWords || named != nil || other != nil else { return nil }
        // A named war with no service word must still read as taking part
        // ("anyone in the American Revolution", "was anyone in WW2").
        if !serviceWords, named != nil || other != nil,
           match(#"\b(?:in|at|for|with)\b"#, in: text) == nil { return nil }
        return FamilyAsk(war: named, otherWar: other, branch: branchFilter)
    }

    /// "who in the family served in the marine corps?"
    static func isFamilyWideAsk(_ question: String) -> Bool {
        familyAsk(question) != nil
    }

    // MARK: - Passages

    /// Words that mark a CyberBrain passage as being about service.
    private static let passagePattern =
        #"\b(?:marines?|marine corps|usmc|military|army|navy|naval|air force|coast guard|national guard|served|serving|enlisted|enlistment|veteran|soldier|sailor|airman|wwii|ww2|wwi|world war|korean war|vietnam war|armed forces|drafted|stationed|deployed|confederate|civil war|revolutionary war|fort wagner)\b"#

    /// A CyberBrain passage that speaks about service.
    static func mentionsService(_ passage: String) -> Bool {
        match(passagePattern, in: passage) != nil
    }

    /// The one war a free-text passage or tree fact names, or nil.
    static func war(namedIn text: String) -> War? {
        war(in: text)
    }
}
