// HallieTurnExecutor+PeopleTab.swift
// The People tab is the family Hallie is most likely talking WITH (Rick
// 2026-08-22: "Hallie needs to know the main people in the People tab …
// alternate names are important. Tim Breen is my brother. Timmy Breen is
// my son."). Until now a People profile only served search and the
// nickname → GEDCOM bridge; anyone in the People tab but not in the tree
// got "I don't find Timmy in the family tree." Here the profile itself is
// a knowledge source: name, alternate names, birth date, how many catalog
// videos carry the tag — and the profile note, QUOTED and attributed,
// never asserted as a fact (the People-notes rule, #367, still holds).
//
// Identity precedence when spellings collide (the real gallery lists
// "Timmy" as an alias of Tim and "Tim" as an alias of Timmy): the profile
// whose canonical name IS the typed spelling wins; alias-only claims tie
// and stay a clarification.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {
    enum PeopleTab {

        // MARK: - "who do you know?"

        private static let rosterPhrases: Set<String> = [
            "who do you know", "who do you know about", "who all do you know",
            "who else do you know", "whom do you know", "who do you know of",
            "which people do you know", "which people do you know about",
            "what people do you know", "what people do you know about",
            "who are the people you know", "who are the people you know about",
            "who do you know in the family", "who do you know in this family",
            "who do you know in our family", "who in the family do you know",
            "who do you have profiles for", "whose profiles do you have",
            "who has a profile", "who has profiles",
            "list the people you know", "list everyone you know",
            "list the people", "list people", "tell me who you know",
            "who can i ask you about", "who can i ask about",
            "who can we ask you about", "who can we ask about",
            "which people can i ask about", "who are you familiar with",
            "who do you recognize", "who do you recognise",
            "who is in the family", "whos in the family", "who is in our family",
        ]

        /// Lower-cased, punctuation-free, single-spaced; "hallie" and
        /// "please" dropped so "Hallie, who do you know?" still matches.
        static func normalizedQuestion(_ text: String) -> String {
            let folded = text.lowercased()
                .replacingOccurrences(of: "’", with: "")
                .replacingOccurrences(of: "'", with: "")
            let words = folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .map(String.init)
                .filter { !["hallie", "please", "mae"].contains($0) }
            return words.joined(separator: " ")
        }

        static func isRosterQuestion(_ text: String) -> Bool {
            let question = normalizedQuestion(text)
            if rosterPhrases.contains(question) { return true }
            // "who is in the people tab", "which people are in the people tab",
            // "show me the people tab" …
            if question.contains("people tab") || question.contains("people gallery"),
               let first = question.split(separator: " ").first,
               ["who", "whos", "which", "what", "list", "show", "tell"].contains(first) {
                return true
            }
            return false
        }

        static func rosterAnswer(context: Context) -> Result {
            rosterAnswer(profiles: context.profiles, graph: context.graph,
                         cyberBrain: context.cyberBrain)
        }

        static func rosterAnswer(profiles: [ProfileSnapshot]?,
                                 graph: GedcomFamilyGraph?,
                                 cyberBrain: CyberBrainIndex?) -> Result {
            func result(_ prose: String, basis: String, outcome: Outcome = .answered) -> Result {
                Result(route: .capability, outcome: outcome, prose: prose,
                       basisLine: basis, queryDescription: "shape=roster",
                       citations: [], catalogPersonName: nil)
            }
            guard let profiles else {
                return result("I couldn't read the People tab just now, so I can't list who I know.",
                              basis: "Basis: People profiles were unreadable; no model call.",
                              outcome: .declined)
            }
            let people = Self.merged(profiles)
            guard !people.isEmpty else {
                return result("The People tab is empty so far — add people there and I'll know them by name.",
                              basis: "Basis: People profiles (0); no model call.")
            }
            let entries = people.map { profile -> String in
                let aliases = Self.alternateNames(profile)
                guard !aliases.isEmpty else { return profile.canonicalName }
                let shown = aliases.prefix(3).joined(separator: ", ")
                let more = aliases.count > 3 ? " and \(aliases.count - 3) more" : ""
                return "\(profile.canonicalName) (also \(shown)\(more))"
            }
            var sentences = [
                "I know \(people.count) \(people.count == 1 ? "person" : "people") from the People tab: "
                    + entries.joined(separator: "; ") + ".",
            ]
            var basis = "Basis: People profiles (\(people.count))"
            if let graph, !graph.people.isEmpty {
                let treeSize = graph.people.count
                if let year = FamilyKnowledgeSupplement.latestBirthYear(in: graph) {
                    sentences.append("The family tree adds \(treeSize) more names, going up to people born in \(year).")
                } else {
                    sentences.append("The family tree adds \(treeSize) more names.")
                }
                basis += "; family tree (\(treeSize) people)"
            }
            if let cyberBrain {
                let told = cyberBrain.archive.people.count
                if told > 0 {
                    sentences.append("And the family has told me about \(told) \(told == 1 ? "person" : "people") in their own words.")
                }
                basis += "; CyberBrain (\(told) people)"
            }
            sentences.append("Ask me about anyone by name.")
            return result(sentences.joined(separator: " "), basis: basis + "; no model call.")
        }

        // MARK: - One person, from the profile alone

        /// The profile that owns this spelling: the unique claimant, or — when
        /// several claim it — the one whose canonical name is that spelling.
        static func profile(claiming typed: String, in profiles: [ProfileSnapshot]) -> ProfileSnapshot? {
            let key = normalizeName(typed)
            guard !key.isEmpty else { return nil }
            let claimants = merged(profiles).filter { profile in
                normalizeName(profile.canonicalName) == key
                    || profile.aliases.contains { normalizeName($0) == key }
            }
            if claimants.count == 1 { return claimants[0] }
            let exact = claimants.filter { normalizeName($0.canonicalName) == key }
            return exact.count == 1 ? exact[0] : nil
        }

        /// The graph route's answer when the tree has nothing but the People
        /// tab does. Answered for biography / a known birth date; an honest
        /// decline (still naming what IS known) for relations and deaths.
        static func answer(profile: ProfileSnapshot,
                           payload: ArchivistQueryAST.Graph,
                           context: Context,
                           queryDescription: String) -> Result {
            let name = profile.canonicalName
            let aliases = alternateNames(profile)
            let born = profile.birthdate.map(birthText)
            let tagCount = taggedVideoCount(profile, in: context.presenceRecords)
            let videos = "\(tagCount) catalog \(tagCount == 1 ? "video" : "videos")"

            var sentences: [String] = []
            var outcome: Outcome = .answered
            switch payload.operation {
            case .biography:
                sentences.append(
                    "\(name) is one of the people in the People tab"
                        + (aliases.isEmpty ? "" : " — also known as \(aliases.joined(separator: ", "))")
                        + ".")
                if let born { sentences.append("\(name) was born \(born), according to the People profile.") }
                // No records supplied (a client that didn't load the catalog)
                // is not the same as "none tagged" — say nothing then.
                if tagCount > 0 {
                    sentences.append("\(name) is tagged in \(videos).")
                } else if !context.presenceRecords.isEmpty {
                    sentences.append("\(name) isn't tagged in any catalog videos yet.")
                }
                if let note = quotedNote(profile) { sentences.append(note) }
            case .birth:
                if let born {
                    sentences.append("\(name) was born \(born), according to the People profile.")
                } else {
                    outcome = .declined
                    sentences.append("The People profile for \(name) doesn't record a birth date.")
                }
            case .death:
                outcome = .declined
                sentences.append("The People profile for \(name) doesn't record that.")
            case .kinship, .familyTree, .relationship:
                outcome = .declined
                let what = payload.relation.map { "\($0.rawValue) " } ?? "relatives "
                sentences.append(
                    "\(name) is in the People tab"
                        + (aliases.isEmpty ? "" : " (also known as \(aliases.joined(separator: ", ")))")
                        + ", so I know the name — but I can't trace \(what)for \(name) yet.")
            }
            sentences.append(treeSentence(for: name, graph: context.graph))
            sentences.append("If you tell me more about \(name) — “let me tell you about \(name)” — I'll remember it.")

            var checked = "Checked: People profile “\(name)” (alternate names, birth date"
            if !profile.note.isEmpty, payload.operation == .biography {
                checked += ", note — quoted, not verified"
            }
            checked += "); family tree (no entry for \(name))"
            checked += context.presenceRecords.isEmpty ? "." : "; catalog tags (\(videos))."
            return Result(
                route: .graph,
                outcome: outcome,
                prose: sentences.joined(separator: " "),
                basisLine: checked,
                queryDescription: queryDescription,
                citations: [],
                catalogPersonName: tagCount > 0 ? name : nil)
        }

        // MARK: - Helpers

        static func normalizeName(_ value: String) -> String {
            PersonResolver.normalize(value)
        }

        /// One entry per stable ID, aliases merged and de-duplicated.
        static func merged(_ profiles: [ProfileSnapshot]) -> [ProfileSnapshot] {
            var byID: [String: ProfileSnapshot] = [:]
            var order: [String] = []
            for profile in profiles {
                if let existing = byID[profile.stableID] {
                    byID[profile.stableID] = ProfileSnapshot(
                        stableID: existing.stableID,
                        canonicalName: existing.canonicalName,
                        aliases: existing.aliases + profile.aliases,
                        birthdate: existing.birthdate ?? profile.birthdate,
                        note: existing.note.isEmpty ? profile.note : existing.note,
                        kinships: existing.kinships + profile.kinships,
                        sex: existing.sex ?? profile.sex)
                } else {
                    byID[profile.stableID] = profile
                    order.append(profile.stableID)
                }
            }
            return order.compactMap { byID[$0] }
                .sorted { normalizeName($0.canonicalName) < normalizeName($1.canonicalName) }
        }

        static func alternateNames(_ profile: ProfileSnapshot) -> [String] {
            let canonical = normalizeName(profile.canonicalName)
            var seen: Set<String> = []
            return profile.aliases.compactMap { alias in
                let key = normalizeName(alias)
                guard !key.isEmpty, key != canonical, seen.insert(key).inserted else { return nil }
                return alias.trimmingCharacters(in: .whitespaces)
            }
        }

        static func taggedVideoCount(_ profile: ProfileSnapshot,
                                     in records: [ArchivistPresenceRecordSnapshot]) -> Int {
            let keys = Set(([profile.canonicalName] + profile.aliases).map(normalizeName))
            return records.filter { record in
                record.confirmedPeople.contains { keys.contains(normalizeName($0.name)) }
            }.count
        }

        /// GEDCOM-style day-month-year so it reads like the tree's own dates.
        static func birthText(_ date: Date) -> String {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = "d MMM yyyy"
            return formatter.string(from: date)
        }

        static func quotedNote(_ profile: ProfileSnapshot) -> String? {
            let note = profile.note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty else { return nil }
            let trimmed = note.count > 240 ? String(note.prefix(240)) + "…" : note
            return "The note on the profile says: “\(trimmed)” — that's a note, not something I've verified."
        }

        /// Never "the tree only goes up to people born in YYYY" (live
        /// 2026-08-26): FamilySearch strips living people's dates, so the
        /// latest birth year says nothing about who is in the tree — Rick
        /// IS in it, undated. Only the honest fact: no record matched.
        static func treeSentence(for name: String, graph: GedcomFamilyGraph?) -> String {
            guard let graph, !graph.people.isEmpty else {
                return "I don't have an imported family tree to place \(name) in."
            }
            return "I couldn't match \(name) to a record in the family tree I have."
        }
    }
}
