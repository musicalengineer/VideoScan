// HallieAttachment.swift
// Things to LOOK at beside an answer (Rick 2026-08-22: "when I have my
// granddaughter or brother over and I need Hallie to show something, she
// seems very limited" — crests, tree views, photos).
//
// RULE: attachments are presentation, never evidence. Nothing here reaches
// the translator prompt, the grounded composer, or the fact basis — the
// same contract `ArchivistBiographyPhoto` already follows. Every card is
// built from GEDCOM pointers by Swift; a model never writes one.
//
// Three renderers read this one type: the Mac chat bubble
// (HallieAttachmentView), the iPad page (HallieWebBridge → JSON, images
// by token), and the shell (HallieShellCLI+Render, text outline for the
// eval harness).

import Foundation
import VideoScanCore

enum HallieAttachment: Sendable, Equatable {
    /// A verified image file (a People-tab cover, or a person photo from
    /// the family asset store).
    case photo(HalliePhotoAttachment)
    /// A family crest / emblem for a surname, from the asset store.
    case crest(surname: String, fileURL: URL)
    /// Generations walking UP from a root (maternal / paternal / both).
    case lineage(HallieLineageCard)
    /// A descendant outline walking DOWN from one or more roots.
    case tree(HallieTreeCard)
    /// "Do you have a photo of X? Put it here." — with the folder to reveal.
    case photoRequest(personName: String, folderURL: URL)

    /// Short kind tag for logs / JSON.
    var kind: String {
        switch self {
        case .photo: return "photo"
        case .crest: return "crest"
        case .lineage: return "lineage"
        case .tree: return "tree"
        case .photoRequest: return "photoRequest"
        }
    }
}

struct HalliePhotoAttachment: Sendable, Equatable {
    let personName: String
    let fileURL: URL
    var caption: String? = nil
    var cropOffsetX: Double = 0
    var cropOffsetY: Double = 0
    var cropScale: Double = 1
    /// The tree record the photo was shown FOR (2026-08-26), so "this photo
    /// is me and my family" can exclude it for that person. Nil when the
    /// producer had no unique tree match.
    var personGedcomID: String? = nil
}

/// One person on a card. Built from a GEDCOM record; `gedcomID` is the
/// evidence pointer ("@I12@") so a card is always traceable to the tree.
struct HalliePersonCard: Sendable, Equatable, Identifiable {
    let gedcomID: String
    let name: String
    /// "1902–1983", "b. 1959", "d. 1977", or nil when the tree has no dates.
    let years: String?
    let birthPlace: String?
    var photoURL: URL? = nil
    var id: String { gedcomID }

    init(_ person: GedcomFamilyGraph.Person, photoURL: URL? = nil) {
        gedcomID = person.id
        name = person.name
        years = HalliePersonCard.yearsText(person)
        birthPlace = person.birthPlace
        self.photoURL = photoURL
    }

    static func yearsText(_ p: GedcomFamilyGraph.Person) -> String? {
        let b = p.birthYear.map(String.init)
        let d = p.deathYear.map(String.init)
        switch (b, d) {
        case let (b?, d?): return "\(b)–\(d)"
        case let (b?, nil): return "b. \(b)"
        case let (nil, d?): return "d. \(d)"
        default: return nil
        }
    }
}

/// "Rick's maternal line, 5 generations back".
struct HallieLineageCard: Sendable, Equatable {
    struct Generation: Sendable, Equatable, Identifiable {
        /// 1 = parents. Matches GedcomFamilyGraph.AncestorGeneration.
        let generation: Int
        /// "mother", "grandmother", "great-grandmother", "parents"…
        let label: String
        let people: [HalliePersonCard]
        var id: Int { generation }
    }
    let title: String
    let root: HalliePersonCard
    let line: GedcomFamilyGraph.Line
    let generations: [Generation]
    /// Generations that were asked for but the tree does not record.
    let requested: Int
    var reachedAll: Bool { generations.count >= requested }
}

/// "The Latta family" — descendants from the earliest recorded Lattas.
struct HallieTreeCard: Sendable, Equatable {
    struct Node: Sendable, Equatable, Identifiable {
        let person: HalliePersonCard
        let spouses: [HalliePersonCard]
        let children: [Node]
        var id: String { person.gedcomID }
        var count: Int { 1 + children.reduce(0) { $0 + $1.count } }
    }
    let title: String
    let surname: String?
    let roots: [Node]
    let depth: Int
    var peopleCount: Int { roots.reduce(0) { $0 + $1.count } }
}

// MARK: - Builders (pure: graph walks → cards)

enum HallieAttachmentBuilder {

    /// Relation word for generation `g` on a line: mother / grandmother /
    /// great-grandmother / great-great-grandmother …; parents / grandparents
    /// / great-grandparents … for the pedigree.
    static func generationLabel(_ g: Int, line: GedcomFamilyGraph.Line) -> String {
        let base: String
        switch line {
        case .maternal: base = g == 1 ? "mother" : "grandmother"
        case .paternal: base = g == 1 ? "father" : "grandfather"
        case .both:     base = g == 1 ? "parents" : "grandparents"
        }
        guard g > 2 else { return base }
        return String(repeating: "great-", count: g - 2) + base
    }

    static func lineage(of person: GedcomFamilyGraph.Person,
                        line: GedcomFamilyGraph.Line,
                        generations requested: Int,
                        untilYear: Int? = nil,
                        in graph: GedcomFamilyGraph,
                        photo: (GedcomFamilyGraph.Person) -> URL? = { _ in nil }) -> HallieLineageCard {
        let found = graph.ancestorLine(of: person, line: line, generations: requested, untilYear: untilYear)
        let lineWord: String
        switch line {
        case .maternal: lineWord = "maternal line"
        case .paternal: lineWord = "paternal line"
        case .both:     lineWord = "ancestors"
        }
        return HallieLineageCard(
            title: "\(HallieLineageQuestion.possessive(person.name)) \(lineWord)",
            root: HalliePersonCard(person, photoURL: photo(person)),
            line: line,
            generations: found.map { gen in
                HallieLineageCard.Generation(
                    generation: gen.generation,
                    label: generationLabel(gen.generation, line: line),
                    people: gen.people.map { HalliePersonCard($0, photoURL: photo($0)) })
            },
            requested: requested)
    }

    static func tree(surname: String,
                     depth: Int,
                     in graph: GedcomFamilyGraph,
                     maxRoots: Int = 3,
                     photo: (GedcomFamilyGraph.Person) -> URL? = { _ in nil }) -> HallieTreeCard? {
        let roots = graph.rootAncestors(surname: surname)
        guard !roots.isEmpty else { return nil }
        let display = roots.first?.surname ?? surname
        func node(_ n: GedcomFamilyGraph.DescendantNode) -> HallieTreeCard.Node {
            HallieTreeCard.Node(
                person: HalliePersonCard(n.person, photoURL: photo(n.person)),
                spouses: n.spouses.map { HalliePersonCard($0, photoURL: photo($0)) },
                children: n.children.map(node))
        }
        return HallieTreeCard(
            title: "The \(display) family",
            surname: display,
            roots: roots.prefix(maxRoots).map { node(graph.descendants(of: $0, depth: depth)) },
            depth: depth)
    }

    static func tree(from person: GedcomFamilyGraph.Person,
                     depth: Int,
                     in graph: GedcomFamilyGraph,
                     photo: (GedcomFamilyGraph.Person) -> URL? = { _ in nil }) -> HallieTreeCard {
        func node(_ n: GedcomFamilyGraph.DescendantNode) -> HallieTreeCard.Node {
            HallieTreeCard.Node(
                person: HalliePersonCard(n.person, photoURL: photo(n.person)),
                spouses: n.spouses.map { HalliePersonCard($0, photoURL: photo($0)) },
                children: n.children.map(node))
        }
        return HallieTreeCard(
            title: "\(HallieLineageQuestion.possessive(person.name)) family",
            surname: person.surname,
            roots: [node(graph.descendants(of: person, depth: depth))],
            depth: depth)
    }
}
