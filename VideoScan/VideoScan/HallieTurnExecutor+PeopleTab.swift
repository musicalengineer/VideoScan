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
// Identity when spellings collide (the real gallery lists "Timmy" as an
// alias of Tim and "Tim" as an alias of Timmy): there is ONE verdict,
// PersonResolver's (codex #778, Director-approved) — a spelling claimed by
// more than one profile is AMBIGUOUS and Hallie asks "which one?", never a
// silent canonical-name pick. The graph, overlay and presence routes give
// the same answer, so a question cannot change meaning by which route it
// happens to take.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {
    enum PeopleTab {

        // MARK: - "who do you know?"

        enum RosterScope: Sendable, Equatable {
            /// Everything Hallie can name as a source category. Only People
            /// profiles are spelled out; tree-only and family-told names stay
            /// private until the user asks about one of those sources.
            case knowledge
            /// The Catalog's People-tab roster only. This is deliberately
            /// narrower than `knowledge` and never consults media rows.
            case catalog
        }

        /// A spoken roster must remain useful and bounded even if a damaged
        /// or synthetic profile store contains thousands of entries.
        static let maxRosterEntries = 24
        /// This is the name-list portion, not the fixed explanation around
        /// it. Field caps below guarantee one corrupt profile cannot consume
        /// the whole allowance. `String.prefix` counts extended grapheme
        /// clusters, so truncation never cuts a displayed character in half.
        static let maxRosterListCharacters = 1_200
        private static let maxRosterNameCharacters = 80
        private static let maxRosterAliasCharacters = 60

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

        static func rosterScope(for text: String,
                                memory: ConversationMemory? = nil) -> RosterScope? {
            // "how is rick related to the people in the people tab" is an
            // overview of relationships, never the name list (live miss #12).
            if HallieRelationshipsOverview.detect(text) != nil { return nil }
            let question = normalizedQuestion(text)
            guard !question.isEmpty else { return nil }

            // A named media/file request belongs to presence or the one-record
            // route. A Family Tree roster belongs to the graph route. Keep
            // these exclusions ahead of every broad "people" phrase.
            let words = Set(question.split(separator: " ").map(String.init))
            let mediaWords: Set<String> = [
                "video", "videos", "photo", "photos", "picture", "pictures",
                "footage", "clip", "clips", "film", "films", "movie", "movies",
                "play", "watch", "find", "search", "showing", "appears", "appear",
            ]
            if question.contains("family tree") || question.contains("familytree")
                || !words.isDisjoint(with: mediaWords) {
                return nil
            }

            if rosterPhrases.contains(question) { return .knowledge }

            // The live catalog wording means the People-tab catalog roster,
            // not every person in the imported tree and not names mentioned
            // privately in family testimony.
            let mentionsCatalog = question.contains("catalog")
                || question.contains("people tab")
                || question.contains("people gallery")
            if mentionsCatalog {
                // The original long live utterance ended in this explicit
                // request after several family corrections. Claim that exact
                // tail even though the preamble is outside roster vocabulary.
                if question.contains("do you know the people"),
                   question.contains("read their names") {
                    return .catalog
                }
                let rosterVocabulary: Set<String> = [
                    "who", "whos", "which", "what", "is", "are", "the", "a",
                    "people", "person", "everyone", "everybody", "all", "in",
                    "from", "on", "catalog", "catalogue", "tab",
                    "gallery", "roster", "listed", "list", "show", "me", "tell",
                    "about", "read", "names", "name", "of", "do", "you", "know",
                    "can", "could", "would", "and", "their", "for", "have", "profiles",
                ]
                guard words.isSubset(of: rosterVocabulary) else { return nil }
                let asksForRoster = words.contains("people") || words.contains("person")
                    || words.contains("names") || words.contains("name")
                    || words.contains("everyone") || words.contains("everybody")
                    || words.contains("roster") || words.contains("listed")
                    || question.contains("who do you know")
                    || question == "who is in the catalog"
                    || question == "whos in the catalog"
                let opener = question.split(separator: " ").first.map(String.init) ?? ""
                let rosterOpeners: Set<String> = [
                    "who", "whos", "which", "what", "list", "show", "tell", "read",
                    "name", "names", "do", "can", "could", "would",
                ]
                if asksForRoster, rosterOpeners.contains(opener) { return .catalog }
            }

            // Close follow-ups from the live conversation. These remain
            // intentionally exact so "read their names in these videos"
            // stays a media question.
            let readNameFollowUps: Set<String> = [
                "read their names", "read their names for me",
                "can you read their names", "can you read their names for me",
                "could you read their names", "read me their names",
            ]
            if readNameFollowUps.contains(question) {
                // Fresh, this is Rick's explicit shorthand for reading the
                // People-tab roster. In a conversation it is a pronoun
                // follow-up: never steal the siblings, children, or search
                // result the preceding answer just established. A previous
                // roster may repeat the roster safely.
                if let exchange = memory?.lastExchange,
                   exchange.queryDescription != "shape=roster" {
                    return nil
                }
                return .catalog
            }

            // "who is in the people tab", "which people are in the people tab",
            // "show me the people tab" …
            if question.contains("people tab") || question.contains("people gallery"),
               let first = question.split(separator: " ").first,
               ["who", "whos", "which", "what", "list", "show", "tell"].contains(first) {
                return .catalog
            }
            return nil
        }

        static func isRosterQuestion(_ text: String) -> Bool {
            rosterScope(for: text) != nil
        }

        static func rosterAnswer(context: Context, scope: RosterScope = .knowledge) -> Result {
            rosterAnswer(profiles: context.profiles, graph: context.graph,
                         cyberBrain: context.cyberBrain, scope: scope)
        }

        static func rosterAnswer(profiles: [ProfileSnapshot]?,
                                 graph: GedcomFamilyGraph?,
                                 cyberBrain: CyberBrainIndex?,
                                 scope: RosterScope = .knowledge) -> Result {
            func result(_ prose: String, basis: String, outcome: Outcome = .answered,
                        offers: [OfferedAction] = []) -> Result {
                Result(route: .capability, outcome: outcome, prose: prose,
                       basisLine: basis, queryDescription: "shape=roster",
                       citations: [], catalogPersonName: nil, offeredActions: offers)
            }
            guard let profiles else {
                return result("I couldn't read the People tab just now, so I can't list who I know.",
                              basis: "Basis: People profiles were unreadable; no model call.",
                              outcome: .declined,
                              offers: scope == .catalog ? [.openPeopleTab] : [])
            }
            let people = Self.merged(profiles)
            guard !people.isEmpty else {
                return result("The People tab is empty so far — add people there and I'll know them by name.",
                              basis: "Basis: People profiles (0); no model call.",
                              offers: scope == .catalog ? [.openPeopleTab] : [])
            }
            var entries: [String] = []
            var listCharacters = 0
            for profile in people.prefix(maxRosterEntries) {
                let aliases = Self.alternateNames(profile)
                let canonical = Self.boundedRosterField(
                    profile.canonicalName, maximum: maxRosterNameCharacters)
                let entry: String
                if aliases.isEmpty {
                    entry = canonical
                } else {
                    let shown = aliases.prefix(3).map {
                        Self.boundedRosterField($0, maximum: maxRosterAliasCharacters)
                    }.joined(separator: ", ")
                    let more = aliases.count > 3 ? " and \(aliases.count - 3) more" : ""
                    entry = "\(canonical) (also \(shown)\(more))"
                }
                let separatorCharacters = entries.isEmpty ? 0 : 2
                guard listCharacters + separatorCharacters + entry.count
                        <= maxRosterListCharacters else { break }
                entries.append(entry)
                listCharacters += separatorCharacters + entry.count
            }
            let omitted = people.count - entries.count
            let boundedTail = omitted > 0
                ? " I read the first \(entries.count) alphabetically; \(omitted) more are in the People tab."
                : ""
            let lead = scope == .catalog
                ? "The People-tab catalog roster has \(people.count) \(people.count == 1 ? "person" : "people"): "
                : "I know \(people.count) \(people.count == 1 ? "person" : "people") from the People tab: "
            var sentences = [lead + entries.joined(separator: "; ") + "." + boundedTail]
            var basis = "Basis: People profiles (\(people.count))"
            if scope == .catalog {
                basis += "; catalog roster only — family-tree and family-told names not listed"
            } else if let graph, !graph.people.isEmpty {
                let treeSize = graph.people.count
                if let year = FamilyKnowledgeSupplement.latestBirthYear(in: graph) {
                    sentences.append("The family tree adds \(treeSize) more names, going up to people born in \(year).")
                } else {
                    sentences.append("The family tree adds \(treeSize) more names.")
                }
                basis += "; family tree (\(treeSize) people)"
            }
            if scope == .knowledge, let cyberBrain {
                let told = cyberBrain.archive.people.count
                if told > 0 {
                    sentences.append("And the family has told me about \(told) \(told == 1 ? "person" : "people") in their own words.")
                }
                basis += "; CyberBrain (\(told) people)"
            }
            sentences.append("Ask me about anyone by name.")
            return result(sentences.joined(separator: " "), basis: basis + "; no model call.",
                          offers: scope == .catalog ? [.openPeopleTab] : [])
        }

        // MARK: - One person, from the profile alone

        /// Who the People tab says a spelling is. (Think of it as a
        /// std::variant<Profile, std::vector<Profile>, std::monostate>.)
        enum Claim: Equatable {
            /// Exactly one profile owns the spelling — answer from it.
            case one(ProfileSnapshot)
            /// Several profiles claim it (canonical on one, alias on
            /// another, or the same spelling twice) — ask which.
            case ambiguous([ProfileSnapshot])
            /// Nobody in the People tab goes by it.
            case none
        }

        /// PersonResolver's verdict (#778), mapped back onto profiles. A
        /// selected People chip (`selected` = the continuation after a
        /// "which one?") names the profile directly and skips resolution.
        static func claim(_ typed: String,
                          selected: CandidateID? = nil,
                          in profiles: [ProfileSnapshot]) -> Claim {
            let people = merged(profiles)
            if case .profileStableID(let stableID) = selected {
                return people.first { $0.stableID == stableID }.map(Claim.one) ?? .none
            }
            let resolver = PersonResolver(people: people.map {
                ResolvablePerson(canonicalName: $0.canonicalName, aliases: $0.aliases)
            })
            switch resolver.resolve(typed) {
            case .resolved(let canonicalName):
                return owners(of: [canonicalName], in: people)
            case .ambiguous(let candidates):
                return owners(of: candidates, in: people)
            case .unknown:
                return .none
            }
        }

        /// The resolver speaks in canonical names; two profiles may share
        /// one (a duplicate gallery entry), which is itself ambiguous.
        private static func owners(of canonicalNames: [String],
                                   in people: [ProfileSnapshot]) -> Claim {
            let keys = Set(canonicalNames.map(normalizeName))
            let owners = people.filter { keys.contains(normalizeName($0.canonicalName)) }
            switch owners.count {
            case 0: return .none
            case 1: return .one(owners[0])
            default: return .ambiguous(owners)
            }
        }

        /// The unique owner of a spelling, or nil when nobody — or more than
        /// one profile — claims it. Never a canonical-wins tie-break.
        static func profile(claiming typed: String, in profiles: [ProfileSnapshot]) -> ProfileSnapshot? {
            if case .one(let profile) = claim(typed, in: profiles) { return profile }
            return nil
        }

        /// "Which one?" chips for an ambiguous claim — the same shape (and
        /// duplicate-name labelling) the temporal and graph routes use.
        static func candidates(_ profiles: [ProfileSnapshot]) -> [Candidate] {
            profileCandidates(profiles.map {
                ArchivistTemporalSubjectResolution.Candidate(
                    stableID: $0.stableID, canonicalName: $0.canonicalName)
            })
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
            case .birthPlace, .deathPlace:
                // A People profile carries a birth DATE and nothing else
                // about the event, so there is no place to give. Say that
                // rather than substituting the date for the place.
                outcome = .declined
                sentences.append(
                    "The People profile for \(name) doesn't record a place — "
                        + "it only carries a birth date.")
            case .kinship, .familyTree, .relationship, .commonAncestor:
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
                catalogPersonName: tagCount > 0 ? name : nil,
                // A People-tab person is living unless the profile records a
                // death (LifeStatus, 2026-09-01).
                subjectLifeStatus: LifeStatus.ofProfile(deathdate: profile.deathdate))
        }

        // MARK: - Helpers

        static func normalizeName(_ value: String) -> String {
            PersonResolver.normalize(value)
        }

        private static func boundedRosterField(_ value: String, maximum: Int) -> String {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard trimmed.count > maximum else { return trimmed }
            return String(trimmed.prefix(maximum - 1)) + "…"
        }

        /// One entry per stable ID, aliases merged and de-duplicated.
        static func merged(_ profiles: [ProfileSnapshot]) -> [ProfileSnapshot] {
            var byID: [String: ProfileSnapshot] = [:]
            var order: [String] = []
            var countsByID: [String: Int] = [:]
            countsByID.reserveCapacity(profiles.count)
            for profile in profiles {
                countsByID[profile.stableID, default: 0] += 1
            }
            // Corrupt stores can repeat a stable ID with conflicting names.
            // Pick the same canonical snapshot and sort its combined aliases
            // no matter which duplicate the decoder emitted first.
            func precedes(_ lhs: ProfileSnapshot, _ rhs: ProfileSnapshot) -> Bool {
                let lhsName = normalizeName(lhs.canonicalName)
                let rhsName = normalizeName(rhs.canonicalName)
                if lhsName != rhsName { return lhsName < rhsName }
                if lhs.canonicalName != rhs.canonicalName {
                    return lhs.canonicalName < rhs.canonicalName
                }
                let lhsAliases = lhs.aliases.map(normalizeName).sorted()
                let rhsAliases = rhs.aliases.map(normalizeName).sorted()
                return lhsAliases.lexicographicallyPrecedes(rhsAliases)
            }
            for profile in profiles {
                if let existing = byID[profile.stableID] {
                    let preferred = precedes(profile, existing) ? profile : existing
                    let fallback = preferred == profile ? existing : profile
                    byID[profile.stableID] = ProfileSnapshot(
                        stableID: preferred.stableID,
                        canonicalName: preferred.canonicalName,
                        aliases: existing.aliases + profile.aliases,
                        birthdate: preferred.birthdate ?? fallback.birthdate,
                        note: preferred.note.isEmpty ? fallback.note : preferred.note,
                        kinships: preferred.kinships + fallback.kinships,
                        sex: preferred.sex ?? fallback.sex,
                        uuid: preferred.uuid ?? fallback.uuid,
                        treeIdentity: preferred.treeIdentity ?? fallback.treeIdentity,
                        deathdate: preferred.deathdate ?? fallback.deathdate)
                } else {
                    byID[profile.stableID] = profile
                    order.append(profile.stableID)
                }
            }
            return order.compactMap { byID[$0] }.map { profile in
                let aliases: [String]
                if countsByID[profile.stableID, default: 0] > 1 {
                    aliases = profile.aliases.sorted {
                        let lhs = normalizeName($0)
                        let rhs = normalizeName($1)
                        return lhs == rhs ? $0 < $1 : lhs < rhs
                    }
                } else {
                    // A real profile's alias order is user-authored display
                    // order. Only corrupt duplicate snapshots lose it.
                    aliases = profile.aliases
                }
                return ProfileSnapshot(
                    stableID: profile.stableID,
                    canonicalName: profile.canonicalName,
                    aliases: aliases,
                    birthdate: profile.birthdate,
                    note: profile.note,
                    kinships: profile.kinships,
                    sex: profile.sex,
                    uuid: profile.uuid,
                    treeIdentity: profile.treeIdentity,
                    deathdate: profile.deathdate)
            }
                .sorted {
                    let lhs = normalizeName($0.canonicalName)
                    let rhs = normalizeName($1.canonicalName)
                    return lhs == rhs ? $0.stableID < $1.stableID : lhs < rhs
                }
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
