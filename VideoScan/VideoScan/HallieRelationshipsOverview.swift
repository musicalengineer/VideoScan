// HallieRelationshipsOverview.swift
// "tell me how rick is related to the people in the people tab" (live miss
// #12, 2026-08-29) — one SUBJECT (the owner, or a named People-tab profile)
// against the COLLECTIVE People tab. Until now the roster detector caught
// it ("tell … people tab") and read the name list back; the two-person
// relationship route needs exactly two people; nothing produced the
// overview. Here the merged kinship engine (FamilyKinshipInference) is
// asked once per other profile and the answers are grouped, nearest first:
//
//   Dad — your father · Ma — your mother · Matt, Mark, Dan, Beth — your
//   children · Donna — your wife · Tim — your brother · Anna — no
//   relationship recorded yet.
//
// Order = the engine's own hop rank for stored rows (parent < child <
// spouse < sibling), then derived single words by route length, then
// route text, then the unrecorded. Marks: "(derived)" for anything beyond
// a stored row; "(assumed — confirm in the review sheet)" when a word rests
// on an unattested sibling row; "(not attested — …)" when only a route can
// be shown for that reason. Works with no GEDCOM at all — the overlay is
// built from the profiles alone.
//
// C++ readers: a namespace of pure static functions over value types; the
// engine is built per turn from immutable snapshots (13 profiles → a few
// KB of adjacency), never from the MainActor display center.

import Foundation
import VideoScanCore

enum HallieRelationshipsOverview {

    typealias Result = HallieTurnExecutor.Result
    typealias Context = HallieTurnExecutor.Context
    typealias ProfileSnapshot = HallieTurnExecutor.ProfileSnapshot
    typealias PeopleTab = HallieTurnExecutor.PeopleTab
    typealias Node = FamilyKinshipOverlay.Node
    typealias Derived = FamilyKinshipInference.Derived

    /// What the sentence asked for.
    struct Ask: Equatable {
        enum Subject: Equatable {
            /// "I", "me", "my", or the owner's own name typed by the owner.
            case owner
            /// A name to resolve against the People tab ("Tim").
            case named(String)
        }
        let subject: Subject
    }

    // MARK: - Detection

    /// Words that make the far side of "related to" the whole People tab
    /// rather than one person. Matched as substrings of the normalized
    /// remainder (lower-cased, punctuation-free, "hallie"/"please" dropped).
    private static let collectiveMarkers: [String] = [
        "people tab", "people gallery", "everyone", "everybody", "every one",
        "the family", "my family", "our family", "his family", "her family", "whole family",
        "family members", "my relatives", "his relatives", "her relatives", "the relatives",
        "our relatives", "all the people", "all of the people", "the people you know",
        "the people i know", "the people we know", "the others", "the rest of the family",
        "all of them", "each person", "each of them", "the people",
    ]

    private static let relativesWords = "(?:relatives|relations|relationships|kin|family relationships|family)"
    private static let leadIn = "(?:(?:tell me|explain|show me|can you tell me|can you explain|could you tell me|i want to know|id like to know) )?"
    /// "am i" / "i am" / "is rick" / "rick is" / "tim breen is" / "are we"
    /// (we = the owner's side). Rick's own sentence is the inverted form:
    /// "tell me how rick is related to …".
    private static let subjectPhrase = "(am i|i am|is [a-z]+(?: [a-z]+)?|[a-z]+(?: [a-z]+)? is|are we|we are)"

    private static let shapes: [NSRegularExpression] = {
        let patterns = [
            // "how am i related to everyone in the people tab"
            "^\(leadIn)(?:how|in what way|in what ways) \(subjectPhrase) related to (.+)$",
            // "how are the people in the people tab related to me"
            "^\(leadIn)how (?:are|is) (.+) related to (me|i|us|[a-z]+)$",
            // "who am i related to (in the people tab)"
            "^\(leadIn)(?:who|whom) \(subjectPhrase) related to(?: (?:in|from|on) the (?:people tab|people gallery|family))?$",
            // "list my relatives", "what are ricks relationships to the people tab"
            "^\(leadIn)(?:list|show|show me|name|give me|what are|whats|what is|tell me) (my|our|[a-z]+s) \(relativesWords)(?: (?:in|from|on) the (?:people tab|people gallery))?(?: (?:to|with) (.+))?$",
            // "who are my relatives (in the people tab)"
            "^\(leadIn)who are (my|our|[a-z]+s) \(relativesWords)(?: (?:in|from|on) the (?:people tab|people gallery))?$",
        ]
        return patterns.map { try! NSRegularExpression(pattern: $0) }
    }()

    static func detect(_ question: String) -> Ask? {
        let text = PeopleTab.normalizedQuestion(question)
        guard !text.isEmpty else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        for (index, shape) in shapes.enumerated() {
            guard let match = shape.firstMatch(in: text, range: range) else { continue }
            func group(_ n: Int) -> String? {
                guard n < match.numberOfRanges, let r = Range(match.range(at: n), in: text) else { return nil }
                return String(text[r])
            }
            switch index {
            case 0:
                guard let phrase = group(1), let object = group(2), isCollective(object) else { continue }
                return Ask(subject: subject(fromPhrase: phrase))
            case 1:
                guard let object = group(1), let who = group(2), isCollective(object) else { continue }
                if ["me", "i", "us"].contains(who) { return Ask(subject: .owner) }
                return Ask(subject: .named(who))
            case 2:
                guard let phrase = group(1) else { continue }
                return Ask(subject: subject(fromPhrase: phrase))
            case 3:
                guard let owner = group(1) else { continue }
                if let object = group(2), !isCollective(object) { continue }
                return Ask(subject: subject(fromPossessive: owner))
            case 4:
                guard let owner = group(1) else { continue }
                return Ask(subject: subject(fromPossessive: owner))
            default:
                continue
            }
        }
        return nil
    }

    private static func isCollective(_ remainder: String) -> Bool {
        collectiveMarkers.contains { remainder.contains($0) }
    }

    /// "am i" / "i am" / "are we" / "we are" → owner; "is rick" / "rick is"
    /// → named "rick".
    private static func subject(fromPhrase phrase: String) -> Ask.Subject {
        if ["am i", "i am", "are we", "we are"].contains(phrase) { return .owner }
        var name = phrase
        if name.hasPrefix("is ") { name = String(name.dropFirst(3)) }
        if name.hasSuffix(" is") { name = String(name.dropLast(3)) }
        return .named(name)
    }

    /// "my"/"our" → owner; "ricks" → named "rick" (apostrophes were stripped).
    private static func subject(fromPossessive word: String) -> Ask.Subject {
        if word == "my" || word == "our" { return .owner }
        return .named(word.hasSuffix("s") ? String(word.dropLast()) : word)
    }

    // MARK: - Answer

    static func answer(_ ask: Ask, context: Context) -> Result {
        let description = "shape=relationships-overview subject=\(describe(ask.subject))"
        func plain(_ prose: String, basis: String, outcome: HallieTurnExecutor.Outcome,
                   offers: [HallieTurnExecutor.OfferedAction] = []) -> Result {
            Result(route: .capability, outcome: outcome, prose: prose, basisLine: basis,
                   queryDescription: description, citations: [], catalogPersonName: nil,
                   offeredActions: offers)
        }
        guard let profiles = context.profiles else {
            return plain("I couldn't read the People tab just now, so I can't work out who is related to whom.",
                         basis: "Basis: People profiles were unreadable; no model call.", outcome: .declined)
        }
        let people = PeopleTab.merged(profiles)
        guard !people.isEmpty else {
            return plain("The People tab is empty so far — add people there, record their relationships, and I'll lay them out.",
                         basis: "Basis: People profiles (0); no model call.", outcome: .declined,
                         offers: [.openPeopleTab])
        }

        // The subject: the owner's profile, or the named one.
        let subject: ProfileSnapshot
        let isOwner: Bool
        switch ask.subject {
        case .owner:
            guard let ownerName = context.speakers.ownerName else {
                return plain("I don't know who “I” is yet — tell me your name (right-click my portrait → “Who is talking to her…”) and ask again.",
                             basis: "Basis: no owner is set, so “me” could not be bound; nothing was looked up.",
                             outcome: .declined)
            }
            switch ownerClaim(ownerName, in: people) {
            case .one(let profile):
                subject = profile
                isOwner = true
            case .ambiguous(let candidates):
                return whichOne(ownerName, candidates: candidates, description: description)
            case .none:
                return plain("I know you're \(ownerName), but there's no People-tab profile by that name — add one and record your relationships there, and I'll lay them out.",
                             basis: "Basis: owner “\(ownerName)”; People profiles (\(people.count)) — none claims that name; no model call.",
                             outcome: .declined, offers: [.openPeopleTab])
            }
        case .named(let typed):
            // The owner's own name, typed by the owner, is still "you".
            let ownerTyped = HallieOwnerResolver.isOwnerSpelling(typed, owner: context.speakers.ownerName)
            switch PeopleTab.claim(typed, in: people) {
            case .one(let profile):
                subject = profile
                isOwner = ownerTyped
            case .ambiguous(let candidates):
                return whichOne(typed, candidates: candidates, description: description)
            case .none:
                if ownerTyped, let ownerName = context.speakers.ownerName,
                   case .one(let profile) = ownerClaim(ownerName, in: people) {
                    subject = profile
                    isOwner = true
                } else {
                    return plain("I don't have a People-tab profile for “\(HallieWhichOne.display(typed))”, so I can't lay out their relationships. Add one there and I'll know the name.",
                                 basis: "Basis: People profiles (\(people.count)) — none claims “\(typed)”; no model call.",
                                 outcome: .declined, offers: [.openPeopleTab])
                }
            }
        }

        let others = people.filter { $0.stableID != subject.stableID }
        let subjectName = subject.canonicalName
        let possessive = isOwner ? "your" : KinshipDisplay.possessive(subjectName)
        guard !others.isEmpty else {
            return plain("\(isOwner ? "You're" : "\(subjectName) is") the only person in the People tab so far, so there's nobody to relate \(isOwner ? "you" : "them") to yet.",
                         basis: "Basis: People profiles (1); no model call.", outcome: .declined,
                         offers: [.openPeopleTab])
        }

        let inference = FamilyKinshipInference(
            snapshots: people.map(graphSnapshot), graph: context.graph)
        let overlay = inference.overlay
        guard let subjectNode = overlay.node(profileStableID: subject.stableID) else {
            return plain("I couldn't place \(subjectName) in the People-tab relationships just now.",
                         basis: "Basis: People profiles (\(people.count)); the kinship overlay has no vertex for “\(subjectName)”; no model call.",
                         outcome: .declined)
        }

        var entries: [Entry] = []
        var unrecorded: [String] = []
        for other in others {
            guard let node = overlay.node(profileStableID: other.stableID),
                  let derived = inference.relation(from: subjectNode, to: node) else {
                unrecorded.append(other.canonicalName)
                continue
            }
            entries.append(Entry(name: other.canonicalName, sex: other.sex, derived: derived))
        }

        let lines = groupedLines(entries, possessive: possessive)
        var pieces = lines.map { "\($0.names.joined(separator: ", ")) — \($0.text)" }
        if !unrecorded.isEmpty {
            pieces.append("\(unrecorded.joined(separator: ", ")) — no relationship recorded yet")
        }
        let related = entries.count
        let derivedCount = entries.filter { $0.derived.route.count > 1 }.count
        let assumedCount = entries.filter { !$0.derived.caveats.isEmpty }.count

        var sentences: [String] = []
        let who = isOwner ? "You're" : "\(subjectName) is"
        sentences.append("\(who) related to \(related) of the \(others.count) other \(others.count == 1 ? "person" : "people") in the People tab.")
        sentences.append("Nearest first: " + pieces.joined(separator: " · ") + ".")
        sentences.append(isOwner
            ? "That's from your entries in the People tab; derived where marked."
            : "That's from the entries in the People tab; derived where marked.")
        // The review sheet's own asks, when the subject's sibling rows are
        // not attested and a sibling has recorded parents.
        for proposal in inference.proposals(for: subjectNode) {
            sentences.append(proposal.text + ".")
        }

        var basis = "Basis: People-tab relationships (\(people.count) profiles; \(related) linked to \(subjectName), \(unrecorded.count) unrecorded"
        if derivedCount > 0 { basis += "; \(derivedCount) derived" }
        if assumedCount > 0 { basis += "; \(assumedCount) resting on an unattested sibling row" }
        basis += ")"
        basis += context.graph == nil ? "; no family tree installed (local-only)" : "; family tree installed"
        basis += "; no model call."

        var offers: [HallieTurnExecutor.OfferedAction] = [.openPeopleTab]
        let chipNames = lines.flatMap(\.names) + unrecorded   // nearest first, like the prose
        for name in chipNames.prefix(HallieWhichOne.cap) {
            offers.append(.ask(question: "who is \(name)?", label: "tell me about \(name)"))
        }
        return Result(route: .capability, outcome: .answered,
                      prose: sentences.joined(separator: " "),
                      basisLine: basis, queryDescription: description,
                      citations: [], catalogPersonName: nil, offeredActions: offers)
    }

    // MARK: - Grouping

    struct Entry {
        let name: String
        let sex: PersonSex?
        let derived: Derived
    }

    /// One rendered line: the names sharing it and the text after the dash.
    struct Line: Equatable {
        let names: [String]
        let text: String
    }

    static func groupedLines(_ entries: [Entry], possessive: String) -> [Line] {
        struct Group {
            let key: String
            let rank: (Int, Int)
            var names: [String] = []
            var sexes: [PersonSex?] = []
            let named: KinshipChainNamer.Named?
            let half: Bool
            let age: String?
            let derived: Bool
            let assumed: Bool
        }
        var groups: [Group] = []
        var singles: [(rank: (Int, Int), line: Line)] = []

        for entry in entries {
            let route = entry.derived.route
            let relations = route.map(\.relation)
            let assumed = !entry.derived.caveats.isEmpty
            if let term = entry.derived.term {
                let named = KinshipChainNamer.name(relations)
                let half = term.contains("half-")
                let age = ["older ", "younger "].first { term.hasPrefix($0) }.map { String($0.dropLast()) }
                let neutral = named?.term(sex: nil, half: half, age: age) ?? term
                let key = neutral + (assumed ? "|assumed" : "")
                let rank: (Int, Int) = route.count == 1
                    ? (0, kindRank(relations[0]))
                    : (1, route.count)
                if let i = groups.firstIndex(where: { $0.key == key }) {
                    groups[i].names.append(entry.name)
                    groups[i].sexes.append(entry.sex)
                } else {
                    groups.append(Group(key: key, rank: rank, names: [entry.name], sexes: [entry.sex],
                                        named: named, half: half, age: age,
                                        derived: route.count > 1, assumed: assumed))
                }
            } else {
                var text = entry.derived.routeText
                text += assumed
                    ? " (not attested — confirm the shared parents in the review sheet)"
                    : " (derived)"
                singles.append((rank: (2, route.count), line: Line(names: [entry.name], text: text)))
            }
        }

        var out: [(rank: (Int, Int), order: Int, line: Line)] = []
        for (order, group) in groups.enumerated() {
            var word: String
            if group.names.count > 1, let named = group.named {
                let sexes = Set(group.sexes.map { $0.map(String.init(describing:)) ?? "" })
                let sex: PersonSex? = sexes.count == 1 ? group.sexes[0] : nil
                word = plural(named.term(sex: sex, half: group.half, age: group.age))
            } else if group.names.count > 1 {
                word = plural(group.key.replacingOccurrences(of: "|assumed", with: ""))
            } else {
                word = entries.first { $0.name == group.names[0] }?.derived.term ?? group.key
            }
            var text = "\(possessive) \(word)"
            if group.derived { text += " (derived)" }
            if group.assumed { text += " (assumed — confirm in the review sheet)" }
            out.append((rank: group.rank, order: order, line: Line(names: group.names, text: text)))
        }
        for (order, single) in singles.enumerated() {
            out.append((rank: single.rank, order: groups.count + order, line: single.line))
        }
        return out.sorted { lhs, rhs in
            if lhs.rank.0 != rhs.rank.0 { return lhs.rank.0 < rhs.rank.0 }
            if lhs.rank.1 != rhs.rank.1 { return lhs.rank.1 < rhs.rank.1 }
            return lhs.order < rhs.order
        }.map(\.line)
    }

    /// The engine's own hop order for stored rows.
    private static func kindRank(_ relation: KinshipRelation) -> Int {
        switch relation {
        case .parent:  return 0
        case .child:   return 1
        case .spouse:  return 2
        case .sibling: return 3
        default:       return 4
        }
    }

    /// "son" → "sons", "child" → "children", "wife" → "wives",
    /// "niece or nephew" → "nieces and nephews", "sister-in-law" →
    /// "sisters-in-law", "8th-great-grandmother" → "8th-great-grandmothers".
    static func plural(_ term: String) -> String {
        if let r = term.range(of: " or ") {
            return plural(String(term[..<r.lowerBound])) + " and " + plural(String(term[r.upperBound...]))
        }
        if let r = term.range(of: "-in-law") {
            return plural(String(term[..<r.lowerBound])) + "-in-law"
        }
        if term.hasSuffix("child") { return term + "ren" }
        if term.hasSuffix("wife") { return String(term.dropLast(2)) + "ves" }
        return term + "s"
    }

    // MARK: - Helpers

    /// The owner's profile: the configured name, then its first token
    /// ("Rick Breen" → "Rick"). PersonResolver's verdict both times.
    private static func ownerClaim(_ ownerName: String, in people: [ProfileSnapshot]) -> PeopleTab.Claim {
        let full = PeopleTab.claim(ownerName, in: people)
        if full != .none { return full }
        guard let first = FamilyIdentityText.tokens(ownerName).first else { return .none }
        return PeopleTab.claim(first, in: people)
    }

    private static func whichOne(_ typed: String, candidates: [ProfileSnapshot], description: String) -> Result {
        let labels = PeopleTab.candidates(candidates).map(\.label)
        var seen: Set<String> = []
        let offers: [HallieTurnExecutor.OfferedAction] = candidates.compactMap { profile in
            let spelling = PeopleTab.alternateNames(profile).first ?? profile.canonicalName
            guard seen.insert(PersonResolver.normalize(spelling)).inserted else { return nil }
            return .ask(question: "how is \(spelling) related to everyone in the people tab",
                        label: "\(profile.canonicalName) (\(spelling))")
        }
        return Result(route: .capability, outcome: .needsClarification,
                      prose: "Which \(HallieWhichOne.display(typed)) do you mean — " + HallieNameQualifier.joined(labels, conjunction: "or") + "?",
                      basisLine: "Basis: “\(typed)” is claimed by \(candidates.count) People-tab profiles; nothing was looked up.",
                      queryDescription: description, citations: [], catalogPersonName: nil,
                      offeredActions: offers)
    }

    private static func graphSnapshot(_ profile: ProfileSnapshot) -> ArchivistGraphProfileSnapshot {
        ArchivistGraphProfileSnapshot(
            stableID: profile.stableID, canonicalName: profile.canonicalName,
            aliases: profile.aliases, kinships: profile.kinships, sex: profile.sex,
            birthdate: profile.birthdate, uuid: profile.uuid, treeIdentity: profile.treeIdentity)
    }

    private static func describe(_ subject: Ask.Subject) -> String {
        switch subject {
        case .owner: return "owner"
        case .named(let name): return name
        }
    }
}
