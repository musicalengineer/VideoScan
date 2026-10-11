// GedcomKinshipPath.swift (VideoScanCore)
// Multi-hop kinship over the GEDCOM graph: grandparents, great-grandparents,
// aunts/uncles, cousins, nieces/nephews, basic in-laws — with an optional
// maternal/paternal side applied at the FIRST hop.
//
// Rick demoed Hallie to Donna (2026-08-17): "who was donna's great
// grandmother on her maternal side?" failed in translation because the
// closed relation vocabulary stopped at one hop. The traversal here is
// deterministic and reports exactly which hop the tree lacks ("the tree
// records Donna's mother, but not her mother's mother") instead of guessing.

import Foundation

extension GedcomFamilyGraph {

    /// Which parent the FIRST hop goes through. `maternal` = through the
    /// mother; `paternal` = through the father. Ignored for relations that do
    /// not start by climbing to a parent (siblings, in-laws, nieces).
    public enum KinshipSide: String, Sendable, Equatable, CaseIterable {
        case maternal
        case paternal

        /// The parent the first hop climbs through.
        public var parentRelation: Relation {
            switch self {
            case .maternal: return .mother
            case .paternal: return .father
            }
        }
    }

    /// The closed multi-hop vocabulary. Raw values are the wire spellings the
    /// translator contract uses. The vocabulary is capped at great-great on
    /// purpose — a closed enum is honest about what the traversal can name.
    public enum ExtendedRelation: String, Sendable, Equatable, CaseIterable {
        case grandfather, grandmother, grandparents
        case greatGrandfather = "great-grandfather"
        case greatGrandmother = "great-grandmother"
        case greatGrandparents = "great-grandparents"
        case greatGreatGrandfather = "great-great-grandfather"
        case greatGreatGrandmother = "great-great-grandmother"
        case greatGreatGrandparents = "great-great-grandparents"
        case uncle, aunt
        case auntsAndUncles = "aunts-and-uncles"
        case cousin, cousins
        case nephew, niece
        case niecesAndNephews = "nieces-and-nephews"
        case fatherInLaw = "father-in-law"
        case motherInLaw = "mother-in-law"
        case parentsInLaw = "parents-in-law"
        case brotherInLaw = "brother-in-law"
        case sisterInLaw = "sister-in-law"
        case sonInLaw = "son-in-law"
        case daughterInLaw = "daughter-in-law"

        /// Whether the first hop climbs to a parent, which is the only place
        /// a maternal/paternal side has meaning.
        public var startsAtParents: Bool {
            switch self {
            case .grandfather, .grandmother, .grandparents,
                 .greatGrandfather, .greatGrandmother, .greatGrandparents,
                 .greatGreatGrandfather, .greatGreatGrandmother,
                 .greatGreatGrandparents,
                 .uncle, .aunt, .auntsAndUncles, .cousin, .cousins:
                return true
            default:
                return false
            }
        }

        /// The sex the word names — "M" for uncle, "F" for aunt — or nil
        /// for a pair word ("aunts-and-uncles", "cousins", "grandparents").
        public var relativeSex: String? {
            switch self {
            case .grandfather, .greatGrandfather, .greatGreatGrandfather,
                 .uncle, .nephew, .fatherInLaw, .brotherInLaw, .sonInLaw:
                return "M"
            case .grandmother, .greatGrandmother, .greatGreatGrandmother,
                 .aunt, .niece, .motherInLaw, .sisterInLaw, .daughterInLaw:
                return "F"
            case .grandparents, .greatGrandparents, .greatGreatGrandparents,
                 .auntsAndUncles, .cousin, .cousins, .niecesAndNephews,
                 .parentsInLaw:
                return nil
            }
        }

        /// How the relation is reached. `firstParent` is the parent hop the
        /// caller's side chose (`.mother`, `.father`, or `.parents` for both).
        /// (For Rick: the plan as data — one struct-like value per enum case
        /// — so `relatives` is a single walk instead of a growing switch.)
        func route(firstParent: Relation) -> KinshipRoute {
            switch self {
            case .grandfather, .grandmother, .grandparents:
                return .chain([firstParent, .parents])
            case .greatGrandfather, .greatGrandmother, .greatGrandparents:
                return .chain([firstParent, .parents, .parents])
            case .greatGreatGrandfather, .greatGreatGrandmother, .greatGreatGrandparents:
                return .chain([firstParent, .parents, .parents, .parents])
            case .uncle, .aunt, .auntsAndUncles:
                return .chain([firstParent, .siblings])
            case .cousin, .cousins:
                return .chain([firstParent, .siblings, .children])
            case .nephew, .niece, .niecesAndNephews:
                return .chain([.siblings, .children])
            case .fatherInLaw, .motherInLaw, .parentsInLaw:
                return .chain([.spouse, .parents])
            case .brotherInLaw:
                return .siblingInLaw(sex: "M")
            case .sisterInLaw:
                return .siblingInLaw(sex: "F")
            case .sonInLaw, .daughterInLaw:
                return .chain([.children, .spouse])
            }
        }
    }

    /// The plan for one extended relation.
    enum KinshipRoute: Sendable, Equatable {
        /// One chain of hops from the subject; the last hop names the relative.
        case chain([Relation])
        /// A spouse's sibling OR a sibling's spouse — two routes, not one chain.
        case siblingInLaw(sex: String)
    }

    /// One hop of a resolved path: the relation word used to get here plus
    /// the person reached. `label` is already phrased for prose ("mother",
    /// "her mother", "his brother").
    public struct KinshipHop: Sendable, Equatable {
        public let label: String
        public let person: Person

        public init(label: String, person: Person) {
            self.label = label
            self.person = person
        }
    }

    /// One complete route from the subject to a relative.
    public struct KinshipPath: Sendable, Equatable {
        public let hops: [KinshipHop]
        public var relative: Person { hops[hops.count - 1].person }

        /// "Donna Breen → mother Elaine Bowser → her mother Ann Smith".
        public func describe(from subject: Person) -> String {
            ([subject.name] + hops.map { "\($0.label) \($0.person.name)" })
                .joined(separator: " → ")
        }
    }

    public enum KinshipResolution: Sendable, Equatable {
        /// At least one relative reached; every path is listed.
        case found([KinshipPath])
        /// The traversal died at a hop. `reached` is the longest partial
        /// path (possibly empty), `missingHop` says what was not recorded
        /// ("her mother's mother").
        case missingHop(reached: [KinshipHop], missingHop: String)
    }

    /// Resolve an extended relation with an optional first-hop side.
    public func relatives(
        _ relation: ExtendedRelation,
        side: KinshipSide?,
        of subject: Person
    ) -> KinshipResolution {
        switch relation.route(firstParent: side?.parentRelation ?? .parents) {
        case .siblingInLaw(let sex):
            return inLawSiblings(of: subject, sex: sex)
        case .chain(let steps):
            switch walk(steps, finalSex: relation.relativeSex, from: subject) {
            case .stopped(let resolution):
                return resolution
            case .reached(let frontier):
                return select(from: frontier, relation: relation, side: side, subject: subject)
            }
        }
    }

    private enum Walk {
        /// Every hop existed; the partial paths that reached the end.
        case reached(frontier: [[KinshipHop]])
        /// A hop was not recorded; the missing-hop resolution, already phrased.
        case stopped(KinshipResolution)
    }

    /// Breadth-first over partial paths. A step that yields nothing for
    /// every path is the missing hop; the deepest partial path names it.
    private func walk(_ steps: [Relation], finalSex: String?, from subject: Person) -> Walk {
        var frontier: [[KinshipHop]] = [[]]
        for (index, step) in steps.enumerated() {
            var next: [[KinshipHop]] = []
            for path in frontier {
                let from = path.last?.person ?? subject
                for person in relatives(step, of: from) {
                    let label = Self.hopLabel(
                        step, from: path.last?.person, reached: person)
                    next.append(path + [KinshipHop(label: label, person: person)])
                }
            }
            if next.isEmpty {
                let reached = frontier.max { $0.count < $1.count } ?? []
                let isLast = index == steps.count - 1
                return .stopped(.missingHop(
                    reached: reached,
                    missingHop: Self.chain(
                        reached, then: step, subject: subject,
                        finalSex: isLast ? finalSex : nil)))
            }
            frontier = next
        }
        return .reached(frontier: frontier)
    }

    /// The people the word names among those reached: never the subject,
    /// the right sex when the word has one, one path per person.
    private func select(from frontier: [[KinshipHop]], relation: ExtendedRelation,
                        side: KinshipSide?, subject: Person) -> KinshipResolution {
        let finalSex = relation.relativeSex
        var paths = frontier
            .filter { !$0.isEmpty }
            .filter { $0.last.map { $0.person.id != subject.id } ?? false }
        if let finalSex {
            paths = paths.filter { $0.last?.person.sex == finalSex }
        }
        let unique = Self.uniqueByRelative(paths)
        guard !unique.isEmpty else {
            // Every hop existed but nobody of the requested sex is there
            // ("uncle" when the parents only have sisters).
            let reached = frontier.max { $0.count < $1.count } ?? []
            let word = finalSex == "M" ? "a male " : finalSex == "F" ? "a female " : "a "
            return .missingHop(
                reached: Array(reached.dropLast()),
                missingHop: word + relation.rawValue
                    + (side.map { " on the \($0.rawValue) side" } ?? ""))
        }
        return .found(unique)
    }

    private func inLawSiblings(of subject: Person, sex: String) -> KinshipResolution {
        var paths: [[KinshipHop]] = []
        for spouse in relatives(.spouse, of: subject) {
            for sibling in relatives(.siblings, of: spouse) where sibling.sex == sex {
                paths.append([
                    KinshipHop(label: Self.hopLabel(.spouse, from: nil, reached: spouse),
                               person: spouse),
                    KinshipHop(label: Self.hopLabel(.siblings, from: spouse, reached: sibling),
                               person: sibling),
                ])
            }
        }
        for sibling in relatives(.siblings, of: subject) {
            for spouse in relatives(.spouse, of: sibling) where spouse.sex == sex {
                paths.append([
                    KinshipHop(label: Self.hopLabel(.siblings, from: nil, reached: sibling),
                               person: sibling),
                    KinshipHop(label: Self.hopLabel(.spouse, from: sibling, reached: spouse),
                               person: spouse),
                ])
            }
        }
        let unique = Self.uniqueByRelative(paths)
        guard !unique.isEmpty else {
            let word = sex == "M" ? "brother-in-law" : "sister-in-law"
            let hasSpouse = !relatives(.spouse, of: subject).isEmpty
            let hasSiblings = !relatives(.siblings, of: subject).isEmpty
            let missing = !hasSpouse && !hasSiblings
                ? "a spouse or sibling (needed to reach a \(word))"
                : "a \(word)"
            return .missingHop(reached: [], missingHop: missing)
        }
        return .found(unique)
    }

    /// De-duplicate relatives reached by more than one route (shared
    /// spouses, half-siblings); keep the first path per person in a stable
    /// order.
    private static func uniqueByRelative(_ paths: [[KinshipHop]]) -> [KinshipPath] {
        var seen: Set<String> = []
        var unique: [KinshipPath] = []
        for path in paths.sorted(by: pathOrder) {
            guard let last = path.last, seen.insert(last.person.id).inserted
            else { continue }
            unique.append(KinshipPath(hops: path))
        }
        return unique
    }

    /// "mother" for the first hop, "her mother" / "his brother" / "their
    /// child" afterwards — the possessive belongs to the person we came from,
    /// the noun to the person reached.
    private static func hopLabel(
        _ relation: Relation,
        from previous: Person?,
        reached: Person
    ) -> String {
        let noun: String
        switch relation {
        case .father, .mother, .parents:
            noun = reached.sex == "M" ? "father"
                : reached.sex == "F" ? "mother" : "parent"
        case .brother, .sister, .siblings:
            noun = reached.sex == "M" ? "brother"
                : reached.sex == "F" ? "sister" : "sibling"
        case .son, .daughter, .children:
            noun = reached.sex == "M" ? "son"
                : reached.sex == "F" ? "daughter" : "child"
        case .husband, .wife, .spouse:
            noun = reached.sex == "M" ? "husband"
                : reached.sex == "F" ? "wife" : "spouse"
        }
        guard let previous else { return noun }
        return possessive(previous) + noun
    }

    private static func possessive(_ person: Person) -> String {
        switch person.sex {
        case "M": return "his "
        case "F": return "her "
        default: return "their "
        }
    }

    /// "her mother's mother" — the hop that was not recorded, phrased as a
    /// possessive chain through everyone actually reached; "a mother" when
    /// even the first hop is missing.
    private static func chain(
        _ reached: [KinshipHop],
        then relation: Relation,
        subject: Person,
        finalSex: String?
    ) -> String {
        var word: String
        switch relation {
        case .mother: word = "mother"
        case .father: word = "father"
        case .parents: word = "parents"
        case .siblings, .brother, .sister: word = "siblings"
        case .children, .son, .daughter: word = "children"
        case .spouse, .husband, .wife: word = "spouse"
        }
        // The last hop names the person asked for ("her mother's mother"),
        // not the whole set ("her mother's parents").
        if let finalSex {
            switch relation {
            case .parents: word = finalSex == "M" ? "father" : "mother"
            case .siblings: word = finalSex == "M" ? "brother" : "sister"
            case .children: word = finalSex == "M" ? "son" : "daughter"
            case .spouse: word = finalSex == "M" ? "husband" : "wife"
            default: break
            }
        }
        guard !reached.isEmpty else { return "a " + word }
        let chainWords = reached.map { hop -> String in
            String(hop.label.split(separator: " ").last ?? Substring(hop.label))
        }
        return possessive(subject)
            + chainWords.joined(separator: "'s ") + "'s " + word
    }

    /// Relatives read alphabetically (the person asked about first), then by
    /// route for repeated names — the same stable order the biography policy
    /// uses, so prose and evidence never disagree.
    private static func pathOrder(_ lhs: [KinshipHop], _ rhs: [KinshipHop]) -> Bool {
        func key(_ hop: KinshipHop) -> String {
            FamilyIdentityText.normalized(hop.person.name) + hop.person.id
        }
        if let l = lhs.last, let r = rhs.last, key(l) != key(r) {
            return key(l) < key(r)
        }
        return lhs.map(key).lexicographicallyPrecedes(rhs.map(key))
    }

    /// Colloquial spellings → the closed vocabulary. Also returns a side when
    /// the phrase carries one ("maternal great-grandmother"). Nil for words
    /// the vocabulary does not name; callers must decline, never guess.
    public static func extendedRelation(
        fromPhrase phrase: String
    ) -> (relation: ExtendedRelation, side: KinshipSide?)? {
        var text = FamilyIdentityText.normalized(phrase)
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(of: "'", with: "")
            .replacingOccurrences(of: "’", with: "")
        var side: KinshipSide?
        for (marker, value) in [("maternal ", KinshipSide.maternal),
                                ("paternal ", .paternal),
                                ("mothers side ", .maternal),
                                ("fathers side ", .paternal)] {
            if text.hasPrefix(marker) {
                side = value
                text = String(text.dropFirst(marker.count))
            }
        }
        text = text.replacingOccurrences(of: "great great", with: "greatgreat")
            .replacingOccurrences(of: "great ", with: "great")
            .replacingOccurrences(of: " in laws", with: "inlaws")
            .replacingOccurrences(of: " in law", with: "inlaw")
            .replacingOccurrences(of: "in laws", with: "inlaws")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        let table: [String: ExtendedRelation] = [
            "grandfather": .grandfather, "grandpa": .grandfather,
            "granddad": .grandfather, "grandad": .grandfather,
            "grampa": .grandfather, "grandpop": .grandfather,
            "grandmother": .grandmother, "grandma": .grandmother,
            "granny": .grandmother, "nana": .grandmother, "gram": .grandmother,
            "grandparents": .grandparents, "grandparent": .grandparents,
            "greatgrandfather": .greatGrandfather,
            "greatgrandpa": .greatGrandfather,
            "greatgranddad": .greatGrandfather,
            "greatgrandmother": .greatGrandmother,
            "greatgrandma": .greatGrandmother,
            "greatgranny": .greatGrandmother,
            "greatgrandparents": .greatGrandparents,
            "greatgrandparent": .greatGrandparents,
            "greatgreatgrandfather": .greatGreatGrandfather,
            "greatgreatgrandpa": .greatGreatGrandfather,
            "greatgreatgranddad": .greatGreatGrandfather,
            "greatgreatgrandmother": .greatGreatGrandmother,
            "greatgreatgrandma": .greatGreatGrandmother,
            "greatgreatgranny": .greatGreatGrandmother,
            "greatgreatgrandparents": .greatGreatGrandparents,
            "greatgreatgrandparent": .greatGreatGrandparents,
            "uncle": .uncle, "uncles": .uncle,
            "aunt": .aunt, "aunts": .aunt, "auntie": .aunt,
            "aunts and uncles": .auntsAndUncles,
            "uncles and aunts": .auntsAndUncles,
            "cousin": .cousin, "cousins": .cousins,
            "first cousin": .cousin, "first cousins": .cousins,
            "nephew": .nephew, "nephews": .nephew,
            "niece": .niece, "nieces": .niece,
            "nieces and nephews": .niecesAndNephews,
            "nephews and nieces": .niecesAndNephews,
            "fatherinlaw": .fatherInLaw, "motherinlaw": .motherInLaw,
            "parentsinlaw": .parentsInLaw, "inlaws": .parentsInLaw,
            "brotherinlaw": .brotherInLaw, "sisterinlaw": .sisterInLaw,
            "soninlaw": .sonInLaw, "daughterinlaw": .daughterInLaw,
        ]
        guard let relation = table[text] else { return nil }
        return (relation, side)
    }
}
