// HallieLineageAnswer+GedcomAwareness.swift
// What Hallie says about the imported tree itself — "do you have my
// GEDCOM?", "describe X", a person's photo or videos from the tree, provenance
// of the merged pulls. Moved out of HallieLineageQuestion.swift unchanged on
// 2026-09-07 night (codex #1182: result construction only, no contract
// change); the section used no private member of its neighbours.
import Foundation
import VideoScanCore

extension HallieLineageAnswer {
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
            if let merged = mergedProvenanceSentence(graph) { source += " " + merged }
            parts.append(source)
            parts.append("Drop a newer .ged file in that folder and I’ll read it next time.")
        } else {
            parts.append("No family tree is loaded right now — add a .ged file to the authorized 40_Family_Tree/GEDCOM folder and I’ll read it.")
        }
        return Result(
            route: .capability, outcome: .answered,
            prose: parts.joined(separator: " "),
            basisLine: "Basis: capability answer; the tree’s file name, folder and counts come from the loaded GEDCOM, nothing else was looked up.",
            queryDescription: "capability gedcom", citations: [], catalogPersonName: nil)
    }

    /// "describe X": the family's told accounts, quoted with their teller.
    /// Deterministic — shape .fixed, never the model. Confirmed archive
    /// passages read plainly; told-not-yet-verified ones carry the teller.
    static func personDescription(_ typed: String,
                                  focus: HallieLineageQuestion.DescriptionFocus = .general,
                                  context: HallieTurnExecutor.Context) -> Result? {
        guard let index = context.cyberBrain else { return nil }
        guard case .resolved(let person) = index.resolve(typed) else {
            // Unknown to the CyberBrain: let the normal biography route
            // answer (GEDCOM-only people still get dates and kin).
            return nil
        }
        let accounts = index.familyAccounts(
            forPersonID: person.id,
            privacyCeiling: HallieTurnExecutor.appPrivacyCeiling)
        guard !accounts.isEmpty else {
            return Result(
                route: .graph, outcome: .declined,
                prose: "No one has told me about \(person.canonicalName) that way yet. Say \u{201C}let me tell you about \(person.canonicalName)\u{201D} and I\u{2019}ll remember every word.",
                basisLine: "Basis: Breen Family CyberBrain — no family accounts recorded for this person.",
                queryDescription: "describe: \(person.canonicalName)",
                citations: [], catalogPersonName: person.canonicalName)
        }
        var sentences: [String] = []
        // Newest accounts first; under a focused ask ("physical
        // appearance"), accounts containing matching cue words rank ahead
        // regardless of age. Ranking only — nothing is edited or dropped.
        let cues: Set<String>
        switch focus {
        case .appearance: cues = HallieLineageQuestion.appearanceCues
        case .personality: cues = HallieLineageQuestion.personalityCues
        case .general: cues = []
        }
        func matchesFocus(_ account: CyberBrainIndex.FamilyAccount) -> Bool {
            guard !cues.isEmpty else { return false }
            let words = Set(account.text.lowercased()
                .split(whereSeparator: { !$0.isLetter }).map(String.init))
            return !words.isDisjoint(with: cues)
        }
        let ordered = accounts.sorted {
            let a = matchesFocus($0), b = matchesFocus($1)
            if a != b { return a }
            return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
        for account in ordered.prefix(3) {
            let quote = Self.trimmedQuote(account.text)
            if let teller = account.attribution, account.confidence != .confirmed {
                sentences.append("According to \(teller): \u{201C}\(quote)\u{201D}")
            } else if let teller = account.attribution {
                sentences.append("\(teller) recorded: \u{201C}\(quote)\u{201D}")
            } else {
                sentences.append("The family archive records: \u{201C}\(quote)\u{201D}")
            }
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: sentences.joined(separator: " "),
            basisLine: "Basis: Breen Family CyberBrain family accounts, quoted verbatim with their tellers; told items are family testimony, not yet verified against documents.",
            queryDescription: "describe: \(person.canonicalName)",
            citations: [], catalogPersonName: person.canonicalName)
    }

    /// First ~240 characters of an account, cut at a sentence end.
    static func trimmedQuote(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 240 else { return trimmed }
        let head = String(trimmed.prefix(240))
        if let cut = head.lastIndex(where: { ".!?".contains($0) }) {
            return String(head[...cut])
        }
        return head + "\u{2026}"
    }

    /// "show me a photo of X": the stored portrait as an attachment, or
    /// the folder prompt when there is none yet.
    static func personPhoto(_ typed: String,
                            context: HallieTurnExecutor.Context) -> Result? {
        guard let graph = context.graph else { return nil }
        // A pronoun that got this far had nothing to stand for
        // (preTranslation resolves the ones it can): ask, never look up "Him".
        if HalliePronounContinuity.isThirdPersonPronoun(typed) {
            return pronounAsk(typed)
        }
        switch resolveDetailed(typed, context: context, graph: graph) {
        case .failure(let result):
            // Not in the tree but exactly one People-tab profile goes by
            // that name (2026-09-10): the executor's photo ask answers
            // from the profile's reference folder; not the tree's decline.
            if HallieTurnExecutor.uniqueProfile(named: typed, in: context.profiles) != nil { return nil }
            return result
        case .success(let person, _): return personPhoto(person: person)
        case .ambiguous:
            // Several namesakes: not answered here — the executor's photo
            // ask offers the chips and resumes the ask for the chosen one
            // (preTranslation hands it over; +PhotoAsk).
            return nil
        }
    }

    /// The photo answer for a RESOLVED tree person: the whole gallery
    /// (every photo and document in the person's folders, 2026-09-10 —
    /// one photo still reads "Here's X."), the photography-floor line, or
    /// the folder card. Shared by the deterministic shape and the
    /// executor's photo ask (chips path). `store` defaults to the
    /// published archive snapshot; tests pass a fixture.
    static func personPhoto(person: GedcomFamilyGraph.Person,
                            store: FamilyAssetStore? = nil) -> Result {
        let store = store ?? FamilyAssetConfigurationCenter.shared.snapshot().makeStore()
        let asset = FamilyAssetPerson(person)
        let photos = store.photoURLs(for: asset)
        let documents = store.documentURLs(for: asset)
        if !photos.isEmpty || !documents.isEmpty {
            let folders = store.personFolders(for: asset)
            return HallieGalleryAnswer.result(
                personName: person.name, gedcomID: person.id,
                photos: photos, documents: documents, folders: folders,
                route: .graph,
                source: HallieGalleryAnswer.archiveSource(folderCount: folders.count),
                offeredActions: [.openFamilyTreePerson(personID: person.id, personName: person.name)])
        }
        // Died before photography (WorldKnowledge, photograph medium):
        // the honest line, and no folder card — there is nothing to ask
        // the family for except a painting, which the line already says.
        if let line = photographyFloorLine(person, medium: .photograph) {
            return Result(
                route: .graph, outcome: .declined,
                prose: line,
                basisLine: "Basis: family tree dates; \(WorldKnowledge.Medium.photograph.fact.statement) No search was run.",
                queryDescription: "photo: \(person.name) (before photography)",
                citations: [], catalogPersonName: person.name,
                offeredActions: [.openFamilyTreePerson(personID: person.id, personName: person.name)])
        }
        let folder = try? store.folderForPhotoRequest(person: person)
        return Result(
            route: .graph, outcome: .declined,
            prose: "I don\u{2019}t have a photo of \(person.name) yet.",
            basisLine: "Basis: no image in the archive\u{2019}s People folder for this person.",
            queryDescription: "photo: \(person.name)",
            citations: [], catalogPersonName: person.name,
            attachments: folder.map { [.photoRequest(personName: person.name, folderURL: $0)] } ?? [])
    }

    /// "videos of X" for a tree person who died before motion pictures
    /// (WorldKnowledge, FILM medium — its own fact, 1888, not the
    /// photograph's): one honest line instead of a presence search. Nil
    /// (= continue as typed) for anyone else, for an unresolved name, for
    /// an ambiguous one, and for an unknown death year — the presence
    /// route already owns those conversations.
    static func personVideos(_ typed: String,
                             context: HallieTurnExecutor.Context) -> Result? {
        guard let graph = context.graph else { return nil }
        if HalliePronounContinuity.isThirdPersonPronoun(typed) { return pronounAsk(typed) }
        guard case .success(let person, _) = resolve(typed, context: context, graph: graph),
              let line = photographyFloorLine(person, medium: .film) else { return nil }
        return Result(
            route: .graph, outcome: .declined,
            prose: line,
            basisLine: "Basis: family tree dates; \(WorldKnowledge.Medium.film.fact.statement) No search was run.",
            queryDescription: "videos: \(person.name) (before motion pictures)",
            citations: [], catalogPersonName: person.name,
            offeredActions: [.openFamilyTreePerson(personID: person.id, personName: person.name)])
    }

    /// "Who do you mean?" for a media ask whose person is a bare pronoun.
    static func pronounAsk(_ pronoun: String) -> Result {
        let key = pronoun.lowercased()
        return Result(
            route: .graph, outcome: .declined,
            prose: HalliePronounContinuity.whoDoYouMean(key),
            basisLine: "Basis: a pronoun names no one without a previous answer; nothing was looked up.",
            queryDescription: "media ask: pronoun \(key) (no subject)",
            citations: [], catalogPersonName: nil)
    }

    /// The WorldKnowledge floor for ONE medium, logged once per suppressed
    /// offer ("[hallie] film offer suppressed: Nathaniel Parker Sr (d. 1737
    /// < film 1888)"). Nil unless the person's KNOWN death year precedes
    /// that medium — an unknown death never suppresses.
    static func photographyFloorLine(_ person: GedcomFamilyGraph.Person,
                                     medium: WorldKnowledge.Medium) -> String? {
        guard let line = WorldKnowledge.photography.impossibilityLine(person: person, medium: medium),
              let note = WorldKnowledge.photography.impossibilityNote(person: person, medium: medium) else { return nil }
        appLog.write("[hallie] \(medium.rawValue) offer suppressed: \(person.name) (\(note))")
        return line
    }

    /// Deterministic pointer at the Get Family Tree sheet. Says what will
    /// happen (Terminal, your own password, install after it parses) so the
    /// chip is not a surprise; the app performs nothing until it is tapped.
    static func getFamilyTreeAnswer(_ graph: GedcomFamilyGraph?) -> Result {
        let have = graph.map { "The tree I have now holds \($0.people.count) people from \($0.sourceFileName ?? "the loaded GEDCOM"). " } ?? "I don’t have a family tree loaded yet. "
        return Result(
            route: .graph, outcome: .answered,
            prose: have
                + "I can fetch more from FamilySearch: tap Get Family Tree, choose how many ancestor steps, "
                + "and I’ll hand a getmyancestors command to Terminal — you type your FamilySearch password there, never here. "
                + "When the download finishes and parses, you can install it into the archive.",
            basisLine: "Basis: Get Family Tree (getmyancestors via Terminal); nothing was downloaded or changed; no model call.",
            queryDescription: "lineage: get family tree", citations: [], catalogPersonName: nil,
            offeredActions: [.getFamilyTree])
    }

    /// "did we only get the gedcom for Rick?" — what the loaded tree
    /// covers: its file, its first record (stated as the assumption it
    /// is), whether the named person is in it, and — the part that
    /// matters — how far the graph can actually WALK back from that
    /// person. Surname presence is never a traceability claim (codex on
    /// 0508bdab: the real Donna Hudson has no parents attached, and a
    /// 16k-person GEDCOM can hold unrelated Hudsons). Only the ancestor
    /// walk earns "I can trace". Deterministic; no model call.
    static func gedcomProvenance(person: String?, surname: String?,
                                 context: HallieTurnExecutor.Context) -> Result {
        guard let graph = context.graph else { return noTree(context) }
        var parts: [String] = []
        var source = "The tree I have comes from "
        source += graph.sourceFileName.map { "the GEDCOM file “\($0)”" } ?? "a GEDCOM file"
        let fromFamilySearch = graph.people.values.contains { $0.familySearchID != nil }
        source += " — \(graph.people.count) people and \(graph.familyCount) families."
        if fromFamilySearch {
            source += " Its records carry FamilySearch IDs, so I take it to be a FamilySearch export."
        }
        if let merged = mergedProvenanceSentence(graph) {
            source += " " + merged
        } else if let root = graph.rootPerson {
            let born = root.birthYear.map { " (b. \($0))" } ?? ""
            source += " Its first record is \(root.name)\(born); exports usually put the home person first, so I assume it was pulled for \(root.name) — the file doesn’t say."
        }
        parts.append(source)

        var offer = false
        let carriers = surname.map { graph.people(withSurname: $0) } ?? []
        let surnameDisplay = surname.map { carriers.first?.surname ?? HallieLineageQuestion.capitalizedName($0) }
        var ancestorIDs: Set<String> = []     // everyone the walk reached
        var selfIDs: Set<String> = []         // the named person's own record(s)
        var personFound = false

        if let person {
            // The same resolver the ancestor walks use: owner pinning,
            // CyberBrain aliases ("Rick" → "Richard Harding Breen Jr"),
            // indexed lookup. Several namesakes → all of them are walked
            // and the deepest speaks for the name.
            let found: [GedcomFamilyGraph.Person]
            switch resolveDetailed(person, context: context, graph: graph) {
            case .success(let p, _): found = [p]
            case .ambiguous(let people): found = people
            case .failure: found = []
            }
            if found.isEmpty {
                parts.append("I don’t find “\(person)” in it.")
                offer = true
            } else {
                personFound = true
                let shown = found.prefix(3).map { p in
                    p.name + (p.birthYear.map { " (b. \($0))" } ?? "")
                }.joined(separator: ", ")
                let more = found.count > 3 ? " and \(found.count - 3) more" : ""
                parts.append("\(person) is in it: \(shown)\(more).")
                // The walk is the evidence. Several namesakes → the
                // deepest one speaks for the name.
                var deepest = 0
                for p in found {
                    let walked = graph.ancestorLine(of: p, line: .both, generations: 60)
                    deepest = max(deepest, walked.count)
                    selfIDs.insert(p.id)
                    for gen in walked { for a in gen.people { ancestorIDs.insert(a.id) } }
                }
                let pronoun: String
                switch found.first?.sex {
                case "F": pronoun = "her"
                case "M": pronoun = "his"
                default: pronoun = "their"
                }
                if deepest > 0 {
                    parts.append("I can trace \(deepest) generation\(deepest == 1 ? "" : "s") back from \(person).")
                    if let surnameDisplay {
                        let connected = carriers.filter { ancestorIDs.contains($0.id) }.count
                        let stray = carriers.filter { !ancestorIDs.contains($0.id) && !selfIDs.contains($0.id) }.count
                        if connected > 0 {
                            parts.append("\(connected) of \(pronoun) recorded ancestors carr\(connected == 1 ? "ies" : "y") the surname \(surnameDisplay).")
                        } else if carriers.isEmpty {
                            parts.append("No one in it carries the surname \(surnameDisplay).")
                        }
                        if stray > 0 {
                            parts.append("The \(stray) other \(surnameDisplay)\(stray == 1 ? "" : "s") in the tree \(stray == 1 ? "isn’t" : "aren’t") among \(pronoun) recorded ancestors, so I can’t say they connect to \(person).")
                        }
                    }
                } else {
                    let lineName = surnameDisplay.map { "\($0) line" } ?? "line"
                    parts.append("But \(pronoun) record has no parents attached, so \(pronoun) \(lineName) stops there in this tree.")
                    let stray = carriers.filter { !selfIDs.contains($0.id) }.count
                    if let surnameDisplay, stray > 0 {
                        parts.append("The \(stray) other \(surnameDisplay)\(stray == 1 ? "" : "s") in the tree \(stray == 1 ? "isn’t" : "aren’t") connected to \(person).")
                    }
                    offer = true
                }
            }
        }
        if let surnameDisplay, !personFound {
            if carriers.isEmpty {
                parts.append("No one in it carries the surname \(surnameDisplay), so I can’t trace that line from this tree.")
                offer = true
            } else {
                parts.append("\(carriers.count) \(carriers.count == 1 ? "person carries" : "people carry") the surname \(surnameDisplay); whether they connect to anyone you mean, I can only tell from a named person’s record.")
            }
        }
        if offer {
            // Honest about what the sheet does (codex #754): it pulls for
            // the signed-in FamilySearch user and REPLACES the active tree;
            // it cannot add a side to this one.
            let side = person.map { HallieLineageQuestion.possessive($0) + " side" } ?? "that side"
            let record = person.map { "\($0)’s record" } ?? "a record on that side"
            parts.append("Get Family Tree pulls from the signed-in FamilySearch account; you can replace the current tree with it or add it to the current tree by FamilySearch ID, so covering \(side) means starting a pull from \(record) there and adding it.")
        }
        return Result(
            route: .graph, outcome: .answered,
            prose: parts.joined(separator: " "),
            basisLine: "Basis: the loaded GEDCOM’s file name and counts; its first record is ASSUMED to be the home person (a VideoScan merge names its roots explicitly) and FamilySearch IDs are taken as a sign of a FamilySearch export (neither is stated in the file); name/surname counts and an ancestor walk from the named person; nothing was downloaded or changed; no model call.",
            queryDescription: "lineage: gedcom provenance" + (person.map { " person=\($0)" } ?? "") + (surname.map { " surname=\($0)" } ?? ""),
            citations: [], catalogPersonName: nil,
            offeredActions: offer ? [.getFamilyTree] : [])
    }

    /// "It was merged by VideoScan from A and B by FamilySearch ID; its
    /// roots are Richard Harding Breen Jr and Donna Hudson, so it was
    /// pulled for both." Nil for an ordinary single-root export.
    static func mergedProvenanceSentence(_ graph: GedcomFamilyGraph) -> String? {
        let roots = graph.roots
        // A merge is recognised by its own flag / several source names —
        // never by root count: re-pulling Rick's tree and adding it to the
        // old one has ONE root and is still a derived artifact (codex #780).
        let merged = graph.isMergedArtifact || graph.sourceFileNames.count > 1
        guard merged || roots.count > 1 else { return nil }
        let names = HallieNameQualifier.joined(roots.map { r in
            r.name + (r.birthYear.map { " (b. \($0))" } ?? "")
        }, conjunction: "and")
        var s = ""
        if merged {
            let from = graph.sourceFileNames.isEmpty ? "two exports" : HallieNameQualifier.joined(graph.sourceFileNames.map { "“\($0)”" }, conjunction: "and")
            s += "It is a VideoScan merge artifact derived from \(from) by FamilySearch ID — lossy: names, vitals, links and FamilySearch IDs only; the source files remain the record. "
        } else {
            s += "It names \(roots.count) home people; "
        }
        if roots.count > 1 {
            s += "its roots are \(names), so I take it to have been pulled for " + HallieNameQualifier.joined(roots.map(\.name), conjunction: "and") + "."
        } else if let root = roots.first {
            s += "Its root is \(root.name)" + (root.birthYear.map { " (b. \($0))" } ?? "") + ", so I take it to have been pulled for \(root.name)."
        } else {
            s += "It names no home person."
        }
        return s
    }
}
