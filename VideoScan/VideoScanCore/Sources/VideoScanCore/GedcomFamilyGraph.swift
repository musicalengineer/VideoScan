// GedcomFamilyGraph.swift (VideoScanCore)
// Minimal GEDCOM 5.5.1 reader + kinship resolver for the Family
// Archivist (Rick 2026-08-07: "I'd like the gedcom data to be
// available so a person can say 'show videos of rick's father'").
//
// Scope: exactly what kinship questions need — INDI names/sex and
// FAM husband/wife/children links. Dates, sources, notes, and the
// rest of the standard are ignored. The graph is knowledge-in-DATA:
// parsed fresh from the user's exported .ged (App Support
// family-tree/originals/), never baked into the app.
//
// Privacy: the .ged lives OUTSIDE the repo (2026-08-03 policy — it
// names living family). This file ships only the parser.
//
// codex owns adversarial parser tests (malformed lines, missing
// pointers, cycles); the happy-path contract is pinned here-adjacent
// in GedcomFamilyGraphTests.

import Foundation

public struct GedcomFamilyGraph: Sendable {

    public struct Person: Sendable, Equatable {
        public let id: String
        /// Display name with the GEDCOM slashes stripped:
        /// "Richard Harding /Breen/ Jr" → "Richard Harding Breen Jr".
        public var name: String
        public var sex: String          // "M" / "F" / ""
        public var childOfFamily: String?
        public var spouseOfFamilies: [String] = []
        /// Raw GEDCOM date strings ("4 Mar 1959") — displayed verbatim,
        /// never reinterpreted (honesty over formatting).
        public var birthDate: String?
        public var deathDate: String?
        /// The GEDCOM surname (the part between slashes: "Richard /Breen/ Jr"
        /// → "Breen"), kept separately so a surname question ("the Breens")
        /// can count people without guessing which name token is the family
        /// name. `nil` when the NAME line had no slashes.
        public var surname: String?

        /// Four-digit year pulled out of the raw GEDCOM birth date ("4 JUL
        /// 1962", "ABT 1944", "BET 1930 AND 1931" → first run wins). Nil when
        /// the date has none. The raw string stays the displayed fact.
        public var birthYear: Int? { GedcomFamilyGraph.year(in: birthDate) }
    }

    struct Family: Sendable {
        var husband: String?
        var wife: String?
        var children: [String] = []
    }

    public private(set) var people: [String: Person] = [:]
    private var families: [String: Family] = [:]

    // MARK: Parse

    public init(gedcomText: String) {
        var currentIndi: Person?
        var currentFam: (id: String, family: Family)?
        /// Which level-1 event (BIRT/DEAT) a level-2 DATE belongs to.
        var pendingEvent: String?

        func flush() {
            if let person = currentIndi { people[person.id] = person }
            if let fam = currentFam { families[fam.id] = fam.family }
            currentIndi = nil
            currentFam = nil
        }

        for rawLine in gedcomText.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let parts = line.split(separator: " ", maxSplits: 2,
                                   omittingEmptySubsequences: true)
            guard parts.count >= 2, let level = Int(parts[0]) else { continue }

            if level == 0 {
                flush()
                // "0 @I…@ INDI" / "0 @F…@ FAM"
                if parts.count == 3, parts[1].hasPrefix("@") {
                    let id = String(parts[1])
                    switch parts[2] {
                    case "INDI":
                        currentIndi = Person(id: id, name: "", sex: "",
                                             childOfFamily: nil)
                    case "FAM":
                        currentFam = (id, Family())
                    default:
                        break
                    }
                }
                continue
            }

            let tag = String(parts[1])
            let value = parts.count == 3 ? String(parts[2]) : ""

            if var person = currentIndi {
                if level == 1 { pendingEvent = (tag == "BIRT" || tag == "DEAT") ? tag : nil }
                if level == 2, tag == "DATE", let event = pendingEvent {
                    if event == "BIRT", person.birthDate == nil { person.birthDate = value }
                    if event == "DEAT", person.deathDate == nil { person.deathDate = value }
                    currentIndi = person
                    continue
                }
                switch (level, tag) {
                case (1, "NAME") where person.name.isEmpty:
                    person.name = value.replacingOccurrences(of: "/", with: " ")
                        .split(separator: " ").joined(separator: " ")
                    if let open = value.firstIndex(of: "/"),
                       let close = value[value.index(after: open)...]
                        .firstIndex(of: "/") {
                        let raw = value[value.index(after: open)..<close]
                            .trimmingCharacters(in: .whitespaces)
                        person.surname = raw.isEmpty ? nil : raw
                    }
                case (1, "SEX"):
                    person.sex = value
                case (1, "FAMC"):
                    person.childOfFamily = value
                case (1, "FAMS"):
                    person.spouseOfFamilies.append(value)
                default:
                    break
                }
                currentIndi = person
            } else if var fam = currentFam {
                switch (level, tag) {
                case (1, "HUSB"): fam.family.husband = value
                case (1, "WIFE"): fam.family.wife = value
                case (1, "CHIL"): fam.family.children.append(value)
                default: break
                }
                currentFam = fam
            }
        }
        flush()
    }

    public init?(fileURL: URL) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        self.init(gedcomText: text)
    }

    /// First four-digit run in a raw GEDCOM date string, or nil.
    static func year(in raw: String?) -> Int? {
        guard let raw else { return nil }
        var digits = ""
        for character in raw {
            if character.isNumber {
                digits.append(character)
            } else {
                if digits.count == 4, let year = Int(digits) { return year }
                digits.removeAll(keepingCapacity: true)
            }
        }
        return digits.count == 4 ? Int(digits) : nil
    }

    /// Everyone whose GEDCOM surname matches (case/diacritic-insensitive).
    /// "breens" and "the breens" are accepted spellings of "Breen" because
    /// that is how people ask ("the family tree for the Breens").
    public func people(withSurname typed: String) -> [Person] {
        var key = FamilyIdentityText.normalized(typed)
        if key.hasPrefix("the ") { key.removeFirst(4) }
        key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        func matches(_ person: Person) -> Bool {
            guard let surname = person.surname else { return false }
            let normalized = FamilyIdentityText.normalized(surname)
            return normalized == key
                || normalized + "s" == key
                || normalized + "es" == key
        }
        return people.values.filter(matches).sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }
    }

    // MARK: Lookup

    /// Loose name match: every typed token must appear in the person's
    /// name (case/diacritic-insensitive). "rick" won't match (nickname),
    /// but "richard" and "richard breen" will; ambiguity returns all.
    public func people(matching typed: String) -> [Person] {
        let tokens = FamilyIdentityText.tokens(typed)
        guard !tokens.isEmpty else { return [] }
        let matches = people.values.filter { person in
            let nameTokens = Set(FamilyIdentityText.tokens(person.name))
            // Identity lookup is token-exact, never substring based:
            // "Ann" must not silently resolve to "Joanne". Nicknames
            // belong in the explicit alias resolver, not in fuzzy GEDCOM
            // matching.
            return tokens.allSatisfy { nameTokens.contains($0) }
        }
        .sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }

        // A complete canonical name is more specific than a token-subset
        // match ("Zoe River" must not become ambiguous with "Zoe River Jr").
        let exact = matches.filter { FamilyIdentityText.tokens($0.name) == tokens }
        return exact.isEmpty ? matches : exact
    }

    // MARK: Kinship

    public enum Relation: String, CaseIterable, Sendable {
        case father, mother, parents, brother, sister, siblings
        case son, daughter, children, husband, wife, spouse
    }

    /// Resolve "<relation> of <person>" → the related people. Empty
    /// when the graph simply doesn't record it — the archivist answers
    /// honestly rather than guessing.
    public func relatives(_ relation: Relation, of person: Person) -> [Person] {
        func lookup(_ id: String?) -> Person? {
            guard let id else { return nil }
            return people[id]
        }
        switch relation {
        case .father:
            return [lookup(person.childOfFamily.flatMap { families[$0]?.husband })]
                .compactMap { $0 }
        case .mother:
            return [lookup(person.childOfFamily.flatMap { families[$0]?.wife })]
                .compactMap { $0 }
        case .parents:
            return relatives(.father, of: person) + relatives(.mother, of: person)
        case .brother, .sister, .siblings:
            guard let famID = person.childOfFamily,
                  let fam = families[famID] else { return [] }
            let sibs = fam.children
                .filter { $0 != person.id }
                .compactMap { people[$0] }
            switch relation {
            case .brother: return sibs.filter { $0.sex == "M" }
            case .sister:  return sibs.filter { $0.sex == "F" }
            default:       return sibs
            }
        case .son, .daughter, .children:
            let kids = person.spouseOfFamilies
                .compactMap { families[$0] }
                .flatMap(\.children)
                .compactMap { people[$0] }
            switch relation {
            case .son:      return kids.filter { $0.sex == "M" }
            case .daughter: return kids.filter { $0.sex == "F" }
            default:        return kids
            }
        case .husband, .wife, .spouse:
            let spouses = person.spouseOfFamilies
                .compactMap { families[$0] }
                .flatMap { [$0.husband, $0.wife].compactMap { $0 } }
                .filter { $0 != person.id }
                .compactMap { people[$0] }
            switch relation {
            case .husband: return spouses.filter { $0.sex == "M" }
            case .wife:    return spouses.filter { $0.sex == "F" }
            default:       return spouses
            }
        }
    }

    /// Colloquial synonyms → relations ("dad", "mom", "kids"…).
    public static func relation(fromWord word: String) -> Relation? {
        switch word.lowercased() {
        case "father", "dad", "daddy", "papa": return .father
        case "mother", "mom", "mommy", "mama": return .mother
        case "parents": return .parents
        case "brother": return .brother
        case "sister": return .sister
        case "siblings", "brothers", "sisters": return .siblings
        case "son": return .son
        case "daughter": return .daughter
        case "children", "kids", "sons", "daughters": return .children
        case "husband": return .husband
        case "wife": return .wife
        case "spouse": return .spouse
        default: return nil
        }
    }
}
