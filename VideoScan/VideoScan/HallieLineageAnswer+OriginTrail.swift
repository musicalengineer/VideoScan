// HallieLineageAnswer+OriginTrail.swift
// "trace my line back to Europe" — the birthplace trail answers.
// Moved out of HallieLineageQuestion.swift unchanged on 2026-09-07 night
// (codex #1182 item 2: result construction only). The section read no
// private member of its neighbours; nothing is widened.

import Foundation
import VideoScanCore

extension HallieLineageAnswer {
    // MARK: Origin trail

    static func originTrail(of person: GedcomFamilyGraph.Person,
                            country: String?,
                            line: GedcomFamilyGraph.Line = .both,
                            graph: GedcomFamilyGraph,
                            basisNote: String? = nil,
                            lens: HallieVitalDates.Lens = .treeOnly) -> Result {
        let maxGen = HallieLineageQuestion.maxGenerations
        let anyPlaces = graph.originTrail(of: person, country: nil, line: line, maxGenerations: maxGen)
        // A CONTINENT IS NOT A COUNTRY (Rick, live 2026-09-07). "trace my line
        // back to europe" put "Europe" here as a country name; no place has a
        // country called Europe, so the match was empty and the answer read
        // "the tree records nobody born in Europe. The places it does reach:
        // … Ireland, the United Kingdom" — naming two European countries in
        // the sentence that denied them. His grandmother's generation was
        // born in Ireland; 12,045 of his ancestors were born in Europe.
        //
        // The classifier already knows the continent of every country, so
        // when the destination names one, membership decides instead of a
        // token match. The trail route above normally takes these questions
        // first; this is the backstop for phrasings that reach here without a
        // line word, and it is why the fix lives in the answer rather than
        // only in the cue.
        let askedContinent = country.flatMap { name in
            BirthplaceClassifier.Continent.allCases.first {
                $0.rawValue.compare(name, options: .caseInsensitive) == .orderedSame
            }
        }
        let stops: [GedcomFamilyGraph.OriginStop]
        if let askedContinent {
            stops = anyPlaces.filter {
                BirthplaceClassifier.classify($0.place).isIn(askedContinent)
            }
        } else {
            stops = graph.originTrail(of: person, country: country, line: line,
                                      maxGenerations: maxGen)
        }
        let who = HallieLineageQuestion.possessive(person.name)
        var sentences: [String] = []
        var card: HallieLineageCard? = nil

        func describe(_ s: GedcomFamilyGraph.OriginStop) -> String {
            var t = s.person.name
            if let y = lens.yearsText(s.person) { t += " (\(y))" }
            return t + ", " + HallieAttachmentBuilder.generationLabel(s.generation, line: .both).replacingOccurrences(of: "parents", with: "parent")
                + " — born \(s.place)"
        }
        func trailCard(to targets: [GedcomFamilyGraph.Person], title: String) -> HallieLineageCard? {
            let gens = graph.ancestorPaths(from: person, to: targets, maxGenerations: maxGen)
            guard !gens.isEmpty else { return nil }
            // `describe` four lines above spends `lens` on the prose; the
            // card built here defaulted to `.treeOnly` and drew the tree's
            // years beside it (2026-09-06). One turn, two stores, two
            // answers about the same person.
            return HallieLineageCard(
                title: title,
                root: HalliePersonCard(person, lens: lens),
                line: .both,
                generations: gens.map { g in
                    HallieLineageCard.Generation(
                        generation: g.generation,
                        label: HallieAttachmentBuilder.generationLabel(g.generation, line: .both),
                        people: g.people.map { HalliePersonCard($0, lens: lens) })
                },
                requested: gens.count)
        }

        if let country {
            if stops.isEmpty {
                sentences.append("Following \(who) ancestors back, the tree records nobody born in \(country).")
                if anyPlaces.isEmpty {
                    sentences.append("It records no birthplaces on those lines at all — places come from the GEDCOM’s PLAC lines, which this tree doesn’t have yet.")
                } else {
                    let countries = Self.countries(in: anyPlaces)
                    sentences.append("The places it does reach: " + countries.prefix(5).map(\.name).joined(separator: ", ") + ".")
                }
            } else {
                let nearest = Array(stops.prefix(4))
                sentences.append("The nearest of \(who) ancestors born in \(country) is \(describe(nearest[0])).")
                if nearest.count > 1 {
                    sentences.append("Further back: " + nearest.dropFirst().map(describe).joined(separator: "; ") + ".")
                }
                if stops.count > nearest.count {
                    sentences.append("\(stops.count - nearest.count) more \(country)-born ancestors lie further back.")
                }
                card = trailCard(to: nearest.map(\.person), title: "\(who) line back to \(country)")
            }
        } else {
            if anyPlaces.isEmpty {
                sentences.append("The tree records no birthplaces for \(who) ancestors, so I can’t trace where the family came from yet. Places come from the GEDCOM’s PLAC lines.")
            } else {
                let countries = Self.countries(in: anyPlaces)
                let abroad = countries.filter { !$0.isHome }
                if abroad.isEmpty {
                    sentences.append("Every recorded birthplace on \(who) lines is in " + countries.map(\.name).joined(separator: " and ") + ".")
                } else {
                    sentences.append("Following \(who) ancestors back, the lines reach " + abroad.prefix(5).map { c in
                        "\(c.name) (\(describe(c.nearest)))"
                    }.joined(separator: "; ") + ".")
                    card = trailCard(to: abroad.prefix(4).map(\.nearest.person), title: "\(who) lines abroad")
                }
            }
        }
        return Result(
            route: .graph, outcome: (country != nil ? !stops.isEmpty : !anyPlaces.isEmpty) ? .answered : .declined,
            prose: sentences.joined(separator: " "),
            basisLine: ArchivistBiographyPolicy.gedcomBasis + (basisNote.map { " " + $0 } ?? ""),
            queryDescription: "origin trail: \(person.name)" + (country.map { " → \($0)" } ?? ""),
            citations: [], catalogPersonName: person.name,
            offeredActions: [.openFamilyTreePerson(
                personID: person.id, personName: person.name)],
            attachments: card.map { [.lineage($0)] } ?? [])
    }

    /// Countries reached by a place trail, nearest ancestor first per
    /// country. The "country" is the last comma component, normalised so
    /// "USA" / "United States" / "United States of America" / a bare US
    /// state read as home.
    struct CountryStop: Equatable { let name: String; let nearest: GedcomFamilyGraph.OriginStop; let isHome: Bool }
    static func countries(in stops: [GedcomFamilyGraph.OriginStop]) -> [CountryStop] {
        var seen: [String: CountryStop] = [:]
        var order: [String] = []
        for s in stops {
            // Last component; GEDCOMs sometimes carry "Quebec. Canada".
            let last = s.place.split(whereSeparator: { $0 == "," || $0 == "." })
                .map { String($0).trimmingCharacters(in: .whitespaces) }
                .last(where: { !$0.isEmpty }) ?? s.place
            let (name, home) = Self.canonicalCountry(last)
            if seen[name] == nil {
                seen[name] = CountryStop(name: name, nearest: s, isHome: home)
                order.append(name)
            }
        }
        return order.compactMap { seen[$0] }
    }

    static let usStates: Set<String> = ["massachusetts", "ma", "new york", "ny", "vermont", "vt", "connecticut", "ct", "new hampshire", "nh", "maine", "me", "rhode island", "ri", "kentucky", "ky", "north carolina", "nc", "south carolina", "sc", "virginia", "va", "mississippi", "ms", "pennsylvania", "pa", "new jersey", "nj", "ohio", "oh", "illinois", "il", "california", "ca", "texas", "tx", "florida", "fl", "georgia", "ga", "maryland", "md", "delaware", "de", "tennessee", "tn", "indiana", "in", "michigan", "mi", "wisconsin", "wi", "minnesota", "mn", "missouri", "mo", "iowa", "ia", "louisiana", "la", "alabama", "al", "arkansas", "ar", "colorado", "co", "oregon", "or", "washington", "wa", "nevada", "nv", "arizona", "az", "utah", "ut", "kansas", "ks", "nebraska", "ne", "oklahoma", "ok", "west virginia", "wv"]

    static func canonicalCountry(_ raw: String) -> (String, Bool) {
        let k = raw.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        switch k {
        case "usa", "us", "u.s.a", "united states", "united states of america", "america": return ("the United States", true)
        case "northern ireland", "ireland", "eire": return ("Ireland", false)
        case "united kingdom", "uk", "great britain": return ("the United Kingdom", false)
        default:
            if usStates.contains(k) { return ("the United States", true) }
            return (raw.trimmingCharacters(in: .whitespaces).capitalized, false)
        }
    }

    // GEDCOM awareness and the common-ancestor answers live in
    // HallieLineageAnswer+GedcomAwareness.swift and
    // HallieLineageAnswer+CommonAncestor.swift.
}
