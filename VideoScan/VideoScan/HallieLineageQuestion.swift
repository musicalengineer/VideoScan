// HallieLineageQuestion.swift
// Deterministic routes for the lineage shapes Rick asked for on 2026-08-22:
//   "show Rick's maternal line back 5 generations"
//   "show the family tree for the Latta family" / "starting with the Lattas"
//   "trace the family back to Ireland"
//   "what is GEDCOM?" / "where does your family tree come from?"
//
// These run BEFORE the model translator (HallieTurnExecutor.preTranslation)
// because the translator's closed graph vocabulary has no generation
// counts, surname roots, or place trails — and a deterministic answer with a
// card is exactly what the family wants to see. Detection is narrow on
// purpose: when the shape is not really ours (a person where a surname was
// expected) `HallieLineageAnswer.answer` returns nil and the question goes
// on as typed.

import Foundation
import VideoScanCore

enum HallieLineageQuestion: Equatable, Sendable {
    /// `person` nil = the owner ("my", "Rick's" when Rick is the owner is
    /// still a name and resolves normally).
    case ancestorLine(person: String?, line: GedcomFamilyGraph.Line, generations: Int)
    case surnameTree(surname: String)
    case originTrail(person: String?, country: String?)
    case gedcomAwareness

    static let defaultGenerations = 5
    static let maxGenerations = 12
    static let treeDepth = 6

    // MARK: Detection (pure text)

    static func detect(_ text: String) -> HallieLineageQuestion? {
        let lower = normalize(text)
        guard !lower.isEmpty else { return nil }

        if isGedcomAwareness(lower) { return .gedcomAwareness }

        // "trace (the|our|my|X's) (family|ancestors|roots|line) back to Ireland"
        if let m = lower.firstMatch(of: /\btrace\b(.*?)\bback(?:\s+to\s+([a-z][a-z .'-]*))?$/) {
            let subject = String(m.1)
            let country = m.2.map { String($0).trimmingCharacters(in: .whitespaces) }
            return .originTrail(person: possessor(in: subject), country: country?.capitalized)
        }
        if let m = lower.firstMatch(of: /\btrace\b(.*?)\b(?:ancestors|ancestry|family|roots|line|lineage)\b/) {
            return .originTrail(person: possessor(in: String(m.1)), country: nil)
        }
        // "where does the family come from" / "where did we come from originally"
        if lower.firstMatch(of: /\bwhere (?:did|does|do) (?:the |our |my |we |us )?(?:family|ancestors|people)?\s*(?:originally )?come from\b/) != nil
            || lower.firstMatch(of: /\bwhat country (?:did|does|is) (?:the |our |my )?family (?:come )?from\b/) != nil {
            return .originTrail(person: nil, country: nil)
        }

        // "(show me) rick's maternal line back 5 generations"
        if let m = lower.firstMatch(of: /(?:^|\s)(.*?)\b(maternal|paternal|mother'?s|father'?s)\s+(?:line|side|ancestors|ancestry|lineage)\b(.*)$/) {
            let line: GedcomFamilyGraph.Line = String(m.2).hasPrefix("m") ? .maternal : .paternal
            let gens = generations(in: String(m.3)) ?? defaultGenerations
            return .ancestorLine(person: possessor(in: String(m.1)), line: line, generations: gens)
        }
        // "rick's ancestors back 4 generations" / "my ancestry 6 generations"
        if let m = lower.firstMatch(of: /(?:^|\s)(.*?)\b(?:ancestors|ancestry|pedigree)\b(.*?\b(\d+|[a-z]+)\s+generations?)/) {
            let gens = generations(in: String(m.2)) ?? defaultGenerations
            return .ancestorLine(person: possessor(in: String(m.1)), line: .both, generations: gens)
        }

        // "family tree for the latta family" / "the lattas' family tree" /
        // "starting with the latta family" / "the hudson family tree"
        if let m = lower.firstMatch(of: /family tree (?:for|of|starting (?:with|from)) (?:the )?(?:current |present |whole |entire |modern |immediate |original |early )?([a-z][a-z'-]+?)s?(?:'s?)?(?:\s+family|\s+clan|\s+side)?\s*$/) {
            return .surnameTree(surname: String(m.1))
        }
        if let m = lower.firstMatch(of: /\bstarting (?:with|from) (?:the )?([a-z][a-z'-]+?)s?(?:\s+family|\s+clan)?\s*$/),
           lower.contains("tree") || lower.contains("descend") {
            return .surnameTree(surname: String(m.1))
        }
        if let m = lower.firstMatch(of: /\bthe ([a-z][a-z'-]+?) family(?:'s)? tree\b/) {
            return .surnameTree(surname: String(m.1))
        }
        if let m = lower.firstMatch(of: /\bthe ([a-z][a-z'-]+)s'? family tree\b/) {
            return .surnameTree(surname: String(m.1))
        }
        return nil
    }

    static func isGedcomAwareness(_ lower: String) -> Bool {
        if lower.contains("gedcom") {
            let cues = ["what is", "what's", "whats", "explain", "where", "which file", "come from",
                        "source", "how do you", "tell me about", "mean", "loaded", "using"]
            return cues.contains { lower.contains($0) } || lower.split(separator: " ").count <= 3
        }
        return lower.firstMatch(of: /\bwhere (?:does|did|is) (?:your|the) (?:family )?tree (?:come from|from|loaded)/) != nil
            || lower.firstMatch(of: /\bhow do you know (?:the|our|my) family tree\b/) != nil
            || lower.firstMatch(of: /\bwhat (?:family )?tree (?:file )?(?:are you|do you) (?:using|reading)\b/) != nil
    }

    // MARK: Helpers

    static func normalize(_ text: String) -> String {
        var s = text.lowercased()
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, "?!.".contains(last) { s.removeLast() }
        return s.trimmingCharacters(in: .whitespaces)
    }

    /// "show me rick's" → "rick"; "my" / "our" / "me" → nil (the owner);
    /// "the family" → nil. Strips leading verbs and articles.
    static func possessor(in fragment: String) -> String? {
        var s = fragment.trimmingCharacters(in: .whitespaces)
        for lead in ["please ", "hallie ", "show me ", "show ", "tell me ", "give me ", "what is ", "what's ", "list ", "can you ", "could you ", "draw ", "display ", "trace "] {
            while s.hasPrefix(lead) { s = String(s.dropFirst(lead.count)) }
        }
        // Trailing nouns the question attached to the person: "rick's
        // ancestors" → "rick's"; "the family" → "the".
        while let m = s.firstMatch(of: /\s*\b(?:family|ancestors|ancestry|roots|line|lineage|tree|people|side|pedigree)\b\s*$/) {
            s = String(s[s.startIndex..<m.range.lowerBound])
        }
        s = s.trimmingCharacters(in: .whitespaces)
        let owners: Set<String> = ["", "my", "our", "me", "mine", "us", "we", "the", "this", "that", "of"]
        if let m = s.firstMatch(of: /^(.+?)'s?$/) {
            let name = String(m.1).trimmingCharacters(in: .whitespaces)
            return owners.contains(name) ? nil : capitalizedName(name)
        }
        if owners.contains(s) || s.hasPrefix("the ") { return nil }
        if s.firstMatch(of: /^(?:of |for )?([a-z][a-z .'-]*)$/) != nil {
            let name = s.replacingOccurrences(of: "^(?:of |for )", with: "", options: .regularExpression)
            return owners.contains(name) ? nil : capitalizedName(name)
        }
        return nil
    }

    static func capitalizedName(_ name: String) -> String {
        name.split(separator: " ").map { $0.capitalized }.joined(separator: " ")
    }

    static func generations(in text: String) -> Int? {
        guard let m = text.firstMatch(of: /(\d+|one|two|three|four|five|six|seven|eight|nine|ten|twelve)\s+generations?/) else { return nil }
        let words = ["one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7,
                     "eight": 8, "nine": 9, "ten": 10, "twelve": 12]
        let raw = String(m.1)
        let n = Int(raw) ?? words[raw] ?? defaultGenerations
        return min(max(1, n), maxGenerations)
    }

    static func possessive(_ name: String) -> String {
        name.hasSuffix("s") ? name + "’" : name + "’s"
    }
}

// MARK: - Answers

enum HallieLineageAnswer {
    typealias Result = HallieTurnExecutor.Result

    /// Nil = not ours after all; let the question continue as typed.
    static func answer(_ question: HallieLineageQuestion,
                       context: HallieTurnExecutor.Context) -> Result? {
        switch question {
        case .gedcomAwareness:
            return gedcomAwareness(context.graph)
        case .surnameTree(let surname):
            guard let graph = context.graph else { return noTree() }
            return surnameTree(surname, graph: graph)
        case .ancestorLine(let person, let line, let generations):
            guard let graph = context.graph else { return noTree() }
            switch resolve(person, context: context, graph: graph) {
            case .failure(let r): return r
            case .success(let p): return ancestorLine(of: p, line: line, generations: generations, graph: graph)
            }
        case .originTrail(let person, let country):
            guard let graph = context.graph else { return noTree() }
            switch resolve(person, context: context, graph: graph) {
            case .failure(let r): return r
            case .success(let p): return originTrail(of: p, country: country, graph: graph)
            }
        }
    }

    // MARK: Person resolution (shared resolver, same rules as every graph route)

    private enum Resolved { case success(GedcomFamilyGraph.Person), failure(Result?) }

    private static func resolve(_ typed: String?,
                                context: HallieTurnExecutor.Context,
                                graph: GedcomFamilyGraph) -> Resolved {
        guard let name = typed ?? context.speakers.ownerName else {
            return .failure(Result(
                route: .graph, outcome: .needsClarification,
                prose: "Whose line would you like? For example: “show Donna’s maternal line back five generations.”",
                basisLine: "Basis: no person named and no owner is signed in; nothing was looked up.",
                queryDescription: "lineage: person missing", citations: [], catalogPersonName: nil))
        }
        // Same bridge the kinship routes use: the family CyberBrain knows
        // that "Rick" is a particular GEDCOM record even when the tree
        // spells him "Richard Harding Breen Jr".
        if let index = context.cyberBrain {
            switch index.resolve(name) {
            case .resolved(let known):
                if let id = known.gedcomPersonID, let p = graph.people[id] { return .success(p) }
            case .ambiguous(let people):
                let linked = people.compactMap { $0.gedcomPersonID.flatMap { graph.people[$0] } }
                if linked.count == 1 { return .success(linked[0]) }
                if linked.count > 1 {
                    return .failure(Result(
                        route: .graph, outcome: .needsClarification,
                        prose: "Which \(name) do you mean — " + linked.map(\.name).joined(separator: " or ") + "?",
                        basisLine: "Basis: Breen Family CyberBrain knows more than one person by that name; nothing was looked up.",
                        queryDescription: "lineage: resolve \(name)", citations: [], catalogPersonName: nil))
                }
            case .notFound:
                break
            }
        }
        let inputs = ArchivistGraphInputs(
            graph: graph,
            profiles: (context.profiles ?? []).map {
                ArchivistGraphProfileSnapshot(stableID: $0.stableID, canonicalName: $0.canonicalName, aliases: $0.aliases)
            })
        let query = ArchivistGraphQuery(people: [name], operation: .familyTree, relation: nil,
                                        side: nil, surname: nil, voices: [:])
        switch ArchivistGraphExecutor.resolveSubject(name, selection: .unresolved, inputs: inputs, query: query) {
        case .person(let p, _, _):
            return .success(p)
        case .result(let r):
            // The resolver's own honest answer (not found / which one?).
            return .failure(Result(
                route: .graph,
                outcome: r.conclusion == .answered ? .answered : .declined,
                prose: r.prose, basisLine: r.basisLine,
                queryDescription: "lineage: resolve \(name)", citations: [], catalogPersonName: nil))
        }
    }

    // MARK: Ancestor line

    static func ancestorLine(of person: GedcomFamilyGraph.Person,
                             line: GedcomFamilyGraph.Line,
                             generations: Int,
                             graph: GedcomFamilyGraph) -> Result {
        let card = HallieAttachmentBuilder.lineage(of: person, line: line, generations: generations, in: graph)
        var sentences: [String] = []
        if card.generations.isEmpty {
            let who = line == .maternal ? "mother" : line == .paternal ? "father" : "parents"
            sentences.append("The family tree doesn’t record \(HallieLineageQuestion.possessive(person.name)) \(who), so I can’t walk that line.")
        } else {
            sentences.append("Here is \(card.title), \(card.generations.count) generation\(card.generations.count == 1 ? "" : "s") back:")
            for gen in card.generations {
                let names = gen.people.map { p -> String in
                    var s = p.name
                    if let y = p.years { s += " (\(y))" }
                    if let place = p.birthPlace { s += ", born \(place)" }
                    return s
                }.joined(separator: "; ")
                sentences.append("\(gen.label.capitalized): \(names).")
            }
            if !card.reachedAll, let last = card.generations.last?.people.first {
                let who = line == .maternal ? "mother" : line == .paternal ? "father" : "parents"
                sentences.append("The tree stops there — no \(who) recorded for \(last.name).")
            }
        }
        return Result(
            route: .graph, outcome: card.generations.isEmpty ? .declined : .answered,
            prose: sentences.joined(separator: " "),
            basisLine: ArchivistBiographyPolicy.gedcomBasis,
            queryDescription: "lineage \(line.rawValue) ×\(generations): \(person.name)",
            citations: [], catalogPersonName: person.name,
            offeredActions: [.openFamilyTree(personName: person.name)],
            attachments: card.generations.isEmpty ? [] : [.lineage(card)])
    }

    // MARK: Surname tree

    static func surnameTree(_ typed: String, graph: GedcomFamilyGraph) -> Result? {
        guard let card = HallieAttachmentBuilder.tree(surname: typed, depth: HallieLineageQuestion.treeDepth, in: graph) else {
            // Not a surname in the tree → maybe a person ("family tree for
            // Donna"); let the normal route handle it.
            return nil
        }
        let surname = card.surname ?? typed.capitalized
        let all = graph.people(withSurname: typed)
        var sentences = ["In the family tree, the \(surname) family starts with "
            + card.roots.map { root -> String in
                var s = root.person.name
                if let y = root.person.years { s += " (\(y))" }
                if let place = root.person.birthPlace { s += ", born \(place)" }
                return s
            }.joined(separator: " and ") + "."]
        sentences.append("The tree records \(all.count) \(all.count == 1 ? "person" : "people") named \(surname); the card shows \(card.peopleCount) across \(card.depth + 1) generations from \(card.roots.count == 1 ? "that root" : "those roots").")
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: ArchivistBiographyPolicy.gedcomBasis,
            queryDescription: "family tree: surname \(surname)",
            citations: [], catalogPersonName: nil,
            offeredActions: [.openFamilyTreeSurname(surname)],
            attachments: [.tree(card)]
                + (HallieFamilyAssets.crestURL(surname: surname).map { [.crest(surname: surname, fileURL: $0)] } ?? []))
    }

    // MARK: Origin trail

    static func originTrail(of person: GedcomFamilyGraph.Person,
                            country: String?,
                            graph: GedcomFamilyGraph) -> Result {
        let maxGen = HallieLineageQuestion.maxGenerations
        let stops = graph.originTrail(of: person, country: country, maxGenerations: maxGen)
        let anyPlaces = graph.originTrail(of: person, country: nil, maxGenerations: maxGen)
        let who = HallieLineageQuestion.possessive(person.name)
        var sentences: [String] = []
        var card: HallieLineageCard? = nil

        func describe(_ s: GedcomFamilyGraph.OriginStop) -> String {
            var t = s.person.name
            if let y = HalliePersonCard.yearsText(s.person) { t += " (\(y))" }
            return t + ", " + HallieAttachmentBuilder.generationLabel(s.generation, line: .both).replacingOccurrences(of: "parents", with: "parent")
                + " — born \(s.place)"
        }
        func trailCard(to targets: [GedcomFamilyGraph.Person], title: String) -> HallieLineageCard? {
            let gens = graph.ancestorPaths(from: person, to: targets, maxGenerations: maxGen)
            guard !gens.isEmpty else { return nil }
            return HallieLineageCard(
                title: title,
                root: HalliePersonCard(person),
                line: .both,
                generations: gens.map { g in
                    HallieLineageCard.Generation(
                        generation: g.generation,
                        label: HallieAttachmentBuilder.generationLabel(g.generation, line: .both),
                        people: g.people.map { HalliePersonCard($0) })
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
            basisLine: ArchivistBiographyPolicy.gedcomBasis,
            queryDescription: "origin trail: \(person.name)" + (country.map { " → \($0)" } ?? ""),
            citations: [], catalogPersonName: person.name,
            offeredActions: [.openFamilyTree(personName: person.name)],
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

    // MARK: GEDCOM awareness

    static func gedcomAwareness(_ graph: GedcomFamilyGraph?) -> Result {
        let what = "GEDCOM is the standard text format family-tree programs use to exchange a tree — people, families, dates and places — so a tree built in one program can be read by another."
        var parts = [what]
        if let graph {
            var source = "My family tree comes from "
            if let name = graph.sourceFileName { source += "the GEDCOM file “\(name)”" } else { source += "a GEDCOM file" }
            if let dir = graph.sourceDirectory { source += " in \(dir)" }
            if let date = graph.sourceModifiedAt {
                source += " (last changed \(date.formatted(date: .abbreviated, time: .omitted)))"
            }
            source += ": \(graph.people.count) people and \(graph.familyCount) families."
            parts.append(source)
            parts.append("Drop a newer .ged file in that folder and I’ll read it next time.")
        } else {
            parts.append("No family tree is loaded right now — put a .ged file in Application Support/VideoScan/family-tree/originals and I’ll read it.")
        }
        return Result(
            route: .capability, outcome: .answered,
            prose: parts.joined(separator: " "),
            basisLine: "Basis: capability answer; the tree’s file name, folder and counts come from the loaded GEDCOM, nothing else was looked up.",
            queryDescription: "capability gedcom", citations: [], catalogPersonName: nil)
    }

    private static func noTree() -> Result {
        Result(route: .graph, outcome: .declined,
               prose: "I don’t have a family tree loaded, so I can’t walk the lines yet. Put a GEDCOM (.ged) file in Application Support/VideoScan/family-tree/originals and ask again.",
               basisLine: "Basis: no GEDCOM loaded; nothing was looked up.",
               queryDescription: "lineage: no tree", citations: [], catalogPersonName: nil)
    }
}
