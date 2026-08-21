// HallieTurnExecutor+Presence.swift
// Presence and cross-evidence turns: paging, refinement notes, and the
// deterministic "as a baby" → birth-year band step. Everything the model
// could not know (birth years) is resolved here from profiles / CyberBrain /
// GEDCOM and cited in the basis line.

import Foundation
import VideoScanCore

extension HallieTurnExecutor {

    /// Where a birth year came from, for the basis line.
    struct BirthYearEvidence: Sendable, Equatable {
        let personName: String
        let year: Int
        let source: String
    }

    static func executePresenceLike(
        _ payload: ArchivistQueryAST.Presence,
        route: Route,
        request: Request,
        context: Context,
        dependencies: Dependencies
    ) async throws -> Result {
        var effective = payload
        var notes: [String] = []

        // "videos of my dad": a first-person relative is resolved through the
        // speaker and the family tree, or declined by name (+SpeakerKinship).
        let kin = SpeakerKinship.rebind(
            people: payload.people ?? [],
            question: request.intent.originalQuestion,
            speakers: context.speakers,
            graph: context.graph,
            cyberBrain: context.cyberBrain)
        if let failure = kin.failure {
            return Result(
                route: route,
                outcome: .declined,
                prose: failure,
                basisLine: "Basis: the question names a relative of the speaker that the family tree could not resolve; no catalog query was performed.",
                queryDescription: description(of: request.intent.ast),
                citations: [],
                catalogPersonName: nil)
        }
        if !kin.notes.isEmpty {
            effective.people = kin.people
            notes.append(contentsOf: kin.notes)
        }

        // "as a baby" / "as a kid" / "as a teenager" → a year band from the
        // FIRST named person's birth year. Only when the AST has no explicit
        // years (an explicit year is the user's word and wins) and only when
        // exactly one source vouches for the birth year.
        if payload.yearStart == nil, payload.yearEnd == nil,
           let detection = ArchivistAgePhrase.detect(in: payload.keywords ?? []),
           let person = payload.people?.first {
            if let evidence = birthYear(of: person, context: context),
               let years = ArchivistAgePhrase.years(
                   birthYear: evidence.year, band: detection.band) {
                effective.yearStart = years.lowerBound
                effective.yearEnd = years.upperBound
                effective.keywords = (payload.keywords ?? []).filter {
                    $0 != detection.keyword
                }
                if effective.keywords?.isEmpty == true { effective.keywords = nil }
                notes.append(
                    "using \(evidence.personName)'s birth year \(evidence.year) "
                    + "from \(evidence.source) "
                    + "(“\(detection.keyword)” = \(years.lowerBound)–\(years.upperBound))")
            } else {
                notes.append(
                    "I don't know \(person)'s birth year, so “\(detection.keyword)” "
                    + "was searched as a word")
            }
        }

        let query = ArchivistPresenceQuery(
            effective, citationOffset: request.intent.citationOffset)
        let records = context.presenceRecords
        let execute = dependencies.executePresence
        let result = try await detached {
            execute(query, records)
        }
        let answer = ArchivistPresenceAnswerComposer.compose(result)

        var prose = answer.prose
        let offset = request.intent.citationOffset
        let shown = result.evidence.citations.count
        let total = result.evidence.totalMatchCount
        if result.conclusion == .present, offset > 0 {
            prose = shown == 0
                ? "That's all of them — I've already shown all \(total)."
                : "Here are \(shown) more (items \(offset + 1)–\(offset + shown) of \(total))."
        } else if let change = request.intent.refinementChange {
            // A refined turn says what changed and what is left:
            // "Narrowed to Westford, around 2005 — 3 catalog items."
            prose = result.conclusion == .present
                ? "\(change) — \(total) catalog item\(total == 1 ? "" : "s")."
                : "\(change) — nothing matched. " + ArchivistPresenceAnswerComposer.noEvidenceProse
        }

        var basis = answer.basisLine
        var prefixes: [String] = []
        if let note = request.intent.refinementNote { prefixes.append(note) }
        prefixes.append(contentsOf: notes)
        if !prefixes.isEmpty {
            basis = "Basis: " + prefixes.joined(separator: "; ") + "; "
                + basis.dropFirst("Basis: ".count)
        }

        let citations = normalize(result.evidence.citations)
        // The typed plan behind the list answer: the count sentence plus
        // each cited item and why it matched. A model may rephrase these
        // and nothing else (HallieGroundedComposer); the basis line stays
        // deterministic.
        let plan: HallieAnswerPlan? = result.conclusion == .present
            ? HallieAnswerPlan.presenceList(
                route: route,
                prose: prose,
                totalMatchCount: total,
                shownCount: shown,
                citations: citations)
            : nil
        return Result(
            route: route,
            outcome: result.conclusion == .present ? .answered : .declined,
            prose: prose,
            basisLine: basis,
            queryDescription: result.interpretedQuery,
            citations: citations,
            catalogPersonName: nil,
            matchCount: result.conclusion == .present ? total : 0,
            answerPlan: plan)
    }

    /// One vouched birth year for a typed name, or nil when nobody knows it or
    /// more than one identity answers to the name (never guess between them).
    /// Order: People profile → CyberBrain (→ GEDCOM pointer) → GEDCOM name.
    static func birthYear(of typedName: String, context: Context) -> BirthYearEvidence? {
        let key = PersonResolver.normalize(typedName)
        guard !key.isEmpty else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        if let profiles = context.profiles {
            let matches = profiles.filter {
                ([$0.canonicalName] + $0.aliases).contains {
                    PersonResolver.normalize($0) == key
                }
            }
            let ids = Set(matches.map(\.stableID))
            if ids.count == 1, let profile = matches.first,
               let birthdate = profile.birthdate {
                return BirthYearEvidence(
                    personName: profile.canonicalName,
                    year: calendar.component(.year, from: birthdate),
                    source: "the People profile")
            }
            if ids.count > 1 { return nil }
        }
        if let cyberBrain = context.cyberBrain {
            switch cyberBrain.resolve(typedName) {
            case .resolved(let person):
                if let gedcomID = person.gedcomPersonID,
                   let gedcomPerson = context.graph?.people[gedcomID],
                   let year = gedcomPerson.birthYear {
                    return BirthYearEvidence(
                        personName: person.canonicalName,
                        year: year,
                        source: "the family tree")
                }
            case .ambiguous:
                return nil
            case .notFound:
                break
            }
        }
        if let graph = context.graph {
            let matches = graph.people(matching: typedName)
            if matches.count == 1, let year = matches[0].birthYear {
                return BirthYearEvidence(
                    personName: matches[0].name,
                    year: year,
                    source: "the family tree")
            }
        }
        return nil
    }

    /// Whether the presence/cross payload carries an age phrase — the app
    /// coordinator uses this to decide whether profiles/GEDCOM/CyberBrain
    /// need loading for a presence turn at all.
    static func needsBirthYearSources(_ ast: ArchivistQueryAST) -> Bool {
        switch ast {
        case .presence(let payload):
            return payload.yearStart == nil && payload.yearEnd == nil
                && payload.people?.isEmpty == false
                && ArchivistAgePhrase.detect(in: payload.keywords ?? []) != nil
        case .cross(let payload):
            return payload.yearStart == nil && payload.yearEnd == nil
                && payload.people?.isEmpty == false
                && ArchivistAgePhrase.detect(
                    in: (payload.keywords ?? []) + (payload.transcript ?? [])) != nil
        default:
            return false
        }
    }
}
