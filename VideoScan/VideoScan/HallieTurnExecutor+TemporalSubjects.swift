// HallieTurnExecutor+TemporalSubjects.swift
// "were the boys born yet when this was shot" / "how old would my dad have
// been in this video" / "how old were the boys then" (eval tm008, tm014,
// tm019, 2026-09-01) all declined with "I need to know who you mean": the
// temporal route resolved its subject only by exact profile name, so a
// group word ("the boys") or a first-person relative ("my dad") never
// reached the People-tab relationships that the presence and family-tree
// routes already use (+SpeakerKinship).
//
// This file turns those phrases into concrete People profiles — model-free
// — before the age arithmetic runs:
//   • "the boys / kids / children / sons / daughters / girls" (also "our" /
//     "my" / "all the …") = the owner's children AND the owner's spouse's
//     children in the People tab. The overlay deliberately does not invent
//     step relations (codex #778), so a household's children can be split
//     between the two parents' cards; "the boys" means the household's boys
//     and the basis line says whose card each came from.
//   • "my dad / mom / father / mother / …" = SpeakerKinship.rebind, the same
//     binding "videos of my dad" uses.
// Anything else is left to the existing single-name resolution.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    enum TemporalSubjects {

        struct Resolved: Equatable, Sendable {
            /// What the question called them, quoted in the basis ("'the boys'").
            let phrase: String
            /// Oldest first; the answer names them in this order.
            let subjects: [ArchivistTemporalSubjectSnapshot]
            /// The binding, for the basis line.
            let note: String
        }

        enum Outcome: Equatable, Sendable {
            case resolved(Resolved)
            /// The phrase was ours but the People tab cannot say who it means.
            case declined(prose: String, basis: String)
            /// Not a group or first-person phrase: resolve the subject as typed.
            case notApplicable
        }

        /// The child words and the sex each implies (nil = either).
        static let childWords: [String: PersonSex?] = [
            "boys": .male, "sons": .male, "girls": .female, "daughters": .female,
            "kids": nil, "children": nil, "kiddos": nil,
        ]

        /// ("the boys", .male) when the text names the household's children.
        static func childrenPhrase(in text: String) -> (phrase: String, word: String, sex: PersonSex?)? {
            let lowered = text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            let pattern = #"\b(?:(?:all|both|any|each) (?:of )?)?(?:the|our|my) (boys|kids|children|sons|daughters|girls|kiddos)\b"#
            guard let range = lowered.range(of: pattern, options: .regularExpression) else {
                // A bare subject the translator trimmed to the noun ("boys").
                let bare = lowered.trimmingCharacters(in: .whitespacesAndNewlines)
                if let sex = childWords[bare] { return ("the \(bare)", bare, sex) }
                return nil
            }
            let phrase = String(lowered[range])
            let word = phrase.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
            guard let sex = childWords[word] else { return nil }
            return (phrase, word, sex)
        }

        /// Resolve the question's subject when it is a group or first-person
        /// phrase. A subject that already names a known profile ("Donna" in
        /// "how old was Donna when my dad died") is left alone.
        static func resolve(question: String, subject: String, context: Context) -> Outcome {
            let profiles = context.profiles ?? []
            let typed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
            let subjectIsKnown: Bool = {
                if case .resolved = temporalResolution(
                    typed, profiles: profiles, selectedIdentity: nil, graph: context.graph) {
                    return true
                }
                if case .ambiguous = temporalResolution(
                    typed, profiles: profiles, selectedIdentity: nil, graph: context.graph) {
                    return true
                }
                return false
            }()
            let key = typed.lowercased()

            if let hit = childrenPhrase(in: subject) ?? childrenPhrase(in: question) {
                let subjectIsThePhrase = childrenPhrase(in: subject) != nil
                if subjectIsThePhrase || !subjectIsKnown {
                    return children(hit, context: context)
                }
            }
            if let (phrase, _) = SpeakerKinship.kinshipPhrase(in: subject)
                ?? SpeakerKinship.kinshipPhrase(in: question) {
                let kinWord = phrase.split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                let subjectIsThePhrase = key == phrase || key == kinWord
                    || HallieTurnExecutor.isSpeakerPronoun(key)
                if subjectIsThePhrase || !subjectIsKnown {
                    return relative(phrase, question: question, context: context)
                }
            }
            return .notApplicable
        }

        // MARK: Children of the household

        private static func children(
            _ hit: (phrase: String, word: String, sex: PersonSex?), context: Context
        ) -> Outcome {
            let quoted = "“\(hit.phrase)”"
            let basisNoOwner = "Basis: \(quoted) needs the archive owner's People-tab relationships; none could be read."
            guard let owner = context.speakers.ownerName else {
                return .declined(
                    prose: "I don't know who \(quoted) are — no one has told me who is using the archive. Set your name in Hallie's settings and I'll read your children off the People tab.",
                    basis: basisNoOwner)
            }
            guard let overlay = kinshipOverlay(context: context), !overlay.isEmpty else {
                return .declined(
                    prose: "I can't tell who \(quoted) are — the People tab doesn't record any family relationships yet. Add “child of \(owner)” on each of their profiles and I'll know.",
                    basis: basisNoOwner)
            }
            let owners = overlay.nodes(claiming: owner, ownerName: owner)
            guard owners.count == 1 else {
                return .declined(
                    prose: owners.isEmpty
                        ? "I don't find you (\(owner)) in the People tab, so I can't tell who \(quoted) are."
                        : "More than one People profile matches your name (\(owner)), so I can't tell who \(quoted) are.",
                    basis: basisNoOwner)
            }
            let ownerNode = owners[0]
            let ownerDisplay = overlay.member(ownerNode)?.name ?? owner

            // The owner's own children, then the spouse's — a household's
            // children can be split between the two cards (no step
            // relations are inferred by the overlay).
            var seen: Set<FamilyKinshipOverlay.Node> = []
            var members: [(member: FamilyKinshipOverlay.Member, via: String)] = []
            for child in overlay.relatives(of: ownerNode, relation: .child, sex: hit.sex)
            where !seen.contains(child.member.node) {
                seen.insert(child.member.node)
                members.append((child.member, ownerDisplay))
            }
            for spouse in overlay.relatives(of: ownerNode, relation: .spouse) {
                for child in overlay.relatives(of: spouse.member.node, relation: .child, sex: hit.sex)
                where !seen.contains(child.member.node) && child.member.node != ownerNode {
                    seen.insert(child.member.node)
                    members.append((child.member, spouse.member.name))
                }
            }
            guard !members.isEmpty else {
                return .declined(
                    prose: "The People tab doesn't list any \(hit.word) for \(ownerDisplay), so I can't tell who \(quoted) are. Add “child of \(ownerDisplay)” on their profiles and I'll know.",
                    basis: "Basis: \(quoted) = children of \(ownerDisplay) in the People tab relationships; none are recorded.")
            }

            // Profiles carry the birthdates; a tree-only member is kept by
            // name so the answer can say it has no birthdate for them.
            var subjects: [ArchivistTemporalSubjectSnapshot] = []
            for entry in members {
                if let id = entry.member.profileStableID,
                   case .resolved(_, let snapshot) = temporalResolution(
                       entry.member.name, profiles: context.profiles ?? [],
                       selectedIdentity: .profileStableID(id), graph: context.graph) {
                    subjects.append(snapshot)
                } else {
                    subjects.append(.init(
                        stableID: entry.member.node.auditID,
                        canonicalName: entry.member.name,
                        birthdate: entry.member.birthdate,
                        sex: entry.member.sex))
                }
            }
            subjects = oldestFirst(subjects)

            // "'the boys' = Dan, Mark (children of Rick) and Matt, Timmy
            // (children of Donna) in the People tab relationships".
            var byParent: [(parent: String, names: [String])] = []
            for entry in members {
                if let index = byParent.firstIndex(where: { $0.parent == entry.via }) {
                    byParent[index].names.append(entry.member.name)
                } else {
                    byParent.append((entry.via, [entry.member.name]))
                }
            }
            let note = "'\(hit.phrase)' = " + byParent.map {
                "\($0.names.joined(separator: ", ")) (\($0.names.count == 1 ? "child" : "children") of \($0.parent))"
            }.joined(separator: " and ") + " in the People tab relationships"
            return .resolved(Resolved(phrase: "'\(hit.phrase)'", subjects: subjects, note: note))
        }

        // MARK: A first-person relative ("my dad")

        private static func relative(_ phrase: String, question: String, context: Context) -> Outcome {
            let kin = SpeakerKinship.rebind(
                people: [phrase],
                question: question.lowercased().contains(phrase) ? question : "videos of \(phrase)",
                speakers: context.speakers,
                graph: context.graph,
                cyberBrain: context.cyberBrain,
                kinshipOverlay: kinshipOverlay(context: context))
            if let failure = kin.failure {
                return .declined(
                    prose: failure,
                    basis: "Basis: the question names a relative of the speaker that the People tab and family tree could not resolve.")
            }
            guard !kin.notes.isEmpty, let name = kin.people.first else { return .notApplicable }
            switch temporalResolution(
                name, profiles: context.profiles ?? [], selectedIdentity: nil,
                graph: context.graph) {
            case .resolved(_, let snapshot):
                return .resolved(Resolved(phrase: "'\(phrase)'", subjects: [snapshot], note: kin.notes.joined(separator: "; ")))
            case .ambiguous(_, let candidates):
                let names = candidates.map(\.canonicalName).joined(separator: ", ")
                return .declined(
                    prose: "“\(phrase)” is \(name), but more than one People profile answers to that name (\(names)). Which one do you mean?",
                    basis: "Basis: " + kin.notes.joined(separator: "; ") + "; subject resolution matched multiple People profiles.")
            case .missing:
                // Known from the tree, but no People profile → no birthdate.
                return .declined(
                    prose: "I know “\(phrase)” is \(name), but there's no People profile with a birthdate for \(name), so I can't work out an age.",
                    basis: "Basis: " + kin.notes.joined(separator: "; ") + "; no People profile carries that name.")
            }
        }

        /// Oldest first (a person with no birthdate goes last), then by name.
        static func oldestFirst(_ subjects: [ArchivistTemporalSubjectSnapshot]) -> [ArchivistTemporalSubjectSnapshot] {
            subjects.sorted { lhs, rhs in
                switch (lhs.birthdate, rhs.birthdate) {
                case (let a?, let b?) where a != b: return a < b
                case (nil, .some): return false
                case (.some, nil): return true
                default:
                    return PersonResolver.normalize(lhs.canonicalName) < PersonResolver.normalize(rhs.canonicalName)
                }
            }
        }
    }
}
