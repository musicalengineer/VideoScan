// GedcomFamilyGraph.swift (VideoScanCore)
// Minimal GEDCOM 5.5.1 reader + kinship resolver for the Family
// Archivist (Rick 2026-08-07: "I'd like the gedcom data to be
// available so a person can say 'show videos of rick's father'").
//
// Scope: exactly what kinship questions need — INDI names/sex and
// FAM husband/wife/children links, including alternate names, multiple
// parent-family links, and FamilySearch's stable `_FSFTID`. Beyond the dates
// and places below, sources, notes, and the rest of the standard are ignored.
// The graph is knowledge-in-DATA:
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
        /// Additional level-1 NAME records, in file order. FamilySearch
        /// exports commonly carry both a preferred and an alternate name;
        /// discarding the latter made otherwise valid searches fail.
        public var alternateNames: [String] = []
        public var sex: String          // "M" / "F" / ""
        public var childOfFamily: String?
        /// Every FAMC link, in file order. `childOfFamily` remains the first
        /// link for source compatibility, while kinship resolution consults
        /// all recorded birth/adoptive/step families instead of silently
        /// replacing one with another.
        public var childOfFamilies: [String] = []
        public var spouseOfFamilies: [String] = []
        /// Raw GEDCOM date strings ("4 Mar 1959") — displayed verbatim,
        /// never reinterpreted (honesty over formatting).
        public var birthDate: String?
        public var deathDate: String?
        /// Raw GEDCOM "2 PLAC" text under BIRT / DEAT ("Cork, Ireland"),
        /// verbatim like the dates (2026-08-22, "trace the family back to
        /// Ireland"). Nil when the record has none.
        public var birthPlace: String?
        public var deathPlace: String?
        /// The GEDCOM surname (the part between slashes: "Richard /Breen/ Jr"
        /// → "Breen"), kept separately so a surname question ("the Breens")
        /// can count people without guessing which name token is the family
        /// name. `nil` when the NAME line had no slashes.
        public var surname: String?
        /// Surnames present only in alternate NAME records.
        public var alternateSurnames: [String] = []
        /// FamilySearch's stable person identifier (for example GVQV-NW3).
        /// This survives new exports even when file-local @I…@ pointers move.
        public var familySearchID: String?

        /// Four-digit year pulled out of the raw GEDCOM birth date ("4 JUL
        /// 1962", "ABT 1944", "BET 1930 AND 1931" → first run wins). Nil when
        /// the date has none. The raw string stays the displayed fact.
        public var birthYear: Int? { GedcomFamilyGraph.year(in: birthDate) }
        /// Same for the raw death date.
        public var deathYear: Int? { GedcomFamilyGraph.year(in: deathDate) }
    }

    struct Family: Sendable {
        var husband: String?
        var wife: String?
        var children: [String] = []
        /// Raw GEDCOM "1 MARR / 2 DATE" text, displayed verbatim like
        /// birth/death dates (overnight cycle 6, 2026-08-22).
        var marriageDate: String?
    }

    /// One marriage a person is recorded in: the spouse (when the tree has
    /// them) and the raw date string (when the family has a MARR date).
    public struct Marriage: Sendable, Equatable {
        public let spouse: Person?
        public let date: String?
    }

    /// One recorded FAM involving a person. Keeping the family pointer and
    /// its own children together prevents renderers from accidentally
    /// assigning children from one marriage to another spouse.
    public struct FamilyUnit: Sendable, Equatable {
        public let id: String
        public let spouse: Person?
        public let children: [Person]
        public let marriageDate: String?
    }

    public private(set) var people: [String: Person] = [:]
    private var families: [String: Family] = [:]
    /// The FIRST `0 @…@ INDI` record in file order (2026-08-26, "trace …
    /// from …" resolved the owner as "Rick Breen" and declined). GEDCOM
    /// has no home-person tag; getmyancestors, FamilySearch, Ancestry and
    /// Gramps all write the home/root person first, so this is the best
    /// available "who is 'me'" hint when the owner's name has no exact
    /// tree record. It is an ASSUMPTION — callers say so in their basis
    /// line. Nil for a tree with no people.
    public private(set) var rootPersonID: String?
    /// `_FSFTID` → file-local pointer, built once at parse. FamilySearch's
    /// identifier survives re-exports when @I…@ pointers move, so it is the
    /// one stable way to say "this record is me" (2026-08-26, owner pin).
    private var personIDByFamilySearchID: [String: String] = [:]

    /// Where this tree came from, when loaded from a file (2026-08-22,
    /// "what is GEDCOM / where does your tree come from"). Nil for a
    /// graph parsed from text (tests, imports).
    public var sourceFileName: String?
    public var sourceDirectory: String?
    public var sourceModifiedAt: Date?
    /// Number of FAM records — the "families" figure in Hallie's answer.
    public var familyCount: Int { families.count }

    // MARK: Parse

    public init(gedcomText: String) {
        var currentIndi: Person?
        var currentFam: (id: String, family: Family)?
        /// Which level-1 event (BIRT/DEAT) a level-2 DATE belongs to.
        var pendingEvent: String?
        /// Same for a family record: MARR.
        var pendingFamilyEvent: String?

        func flush() {
            if let person = currentIndi {
                people[person.id] = person
                if let fsid = person.familySearchID, personIDByFamilySearchID[fsid] == nil {
                    personIDByFamilySearchID[fsid] = person.id
                }
            }
            if let fam = currentFam { families[fam.id] = fam.family }
            currentIndi = nil
            currentFam = nil
            pendingEvent = nil
            pendingFamilyEvent = nil
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
                        if rootPersonID == nil { rootPersonID = id }
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
                Self.applyPersonLine(level: level, tag: tag, value: value,
                                     person: &person, pendingEvent: &pendingEvent)
                currentIndi = person
            } else if var fam = currentFam {
                Self.applyFamilyLine(level: level, tag: tag, value: value,
                                     family: &fam.family,
                                     pendingEvent: &pendingFamilyEvent)
                currentFam = fam
            }
        }
        flush()
    }

    public init?(fileURL: URL) {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else {
            return nil
        }
        let records = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard let first = records.first, let last = records.last,
              first.trimmingCharacters(in: CharacterSet(charactersIn: "\u{feff}")) == "0 HEAD",
              last.uppercased() == "0 TRLR" else { return nil }
        self.init(gedcomText: text)
        sourceFileName = fileURL.lastPathComponent
        sourceDirectory = fileURL.deletingLastPathComponent().path
        sourceModifiedAt = (try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// Recorded family units in the person's FAMS order. Missing pointers
    /// are ignored; children never migrate between units.
    public func familyUnits(of person: Person) -> [FamilyUnit] {
        person.spouseOfFamilies.compactMap { familyID in
            guard let family = families[familyID] else { return nil }
            let isHusband = family.husband == person.id
            let isWife = family.wife == person.id
            // A FAMS pointer is evidence only when the reciprocal FAM record
            // names this person in exactly one partner role. Dangling pointers
            // and self-spouse records must not manufacture a family unit.
            guard isHusband != isWife else { return nil }
            let spouseID = isHusband ? family.wife : family.husband
            return FamilyUnit(
                id: familyID,
                spouse: spouseID.flatMap { people[$0] },
                // A corrupt self-child pointer must not render the root again
                // as their own descendant.
                children: family.children.compactMap {
                    $0 == person.id ? nil : people[$0]
                },
                marriageDate: family.marriageDate)
        }
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
        var key = FamilyIdentityText.normalized(FamilyNameNormalizer.normalizeSurname(typed))
        if key.hasPrefix("the ") { key.removeFirst(4) }
        key = key.trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty else { return [] }
        func matches(_ person: Person) -> Bool {
            ([person.surname].compactMap { $0 } + person.alternateSurnames).contains { surname in
                let normalized = FamilyIdentityText.normalized(surname)
                return normalized == key
                    || normalized + "s" == key
                    || normalized + "es" == key
            }
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
        let familySearchKey = typed.trimmingCharacters(in: .whitespacesAndNewlines)
            .uppercased()
        if Self.isFamilySearchID(familySearchKey) {
            return people.values.filter { $0.familySearchID == familySearchKey }
                .sorted { $0.id < $1.id }
        }
        // Typed spellings meet the parsed ones: "Mc Gill" finds "McGill".
        let tokens = FamilyIdentityText.tokens(FamilyNameNormalizer.normalizeName(typed))
        guard !tokens.isEmpty else { return [] }
        let matches = people.values.filter { person in
            // Identity lookup is token-exact, never substring based:
            // "Ann" must not silently resolve to "Joanne". Nicknames
            // belong in the explicit alias resolver, not in fuzzy GEDCOM
            // matching.
            return Self.allNames(of: person).contains { candidate in
                let nameTokens = Set(FamilyIdentityText.tokens(candidate))
                return tokens.allSatisfy { nameTokens.contains($0) }
            }
        }
        .sorted {
            $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name
        }

        // A complete canonical name is more specific than a token-subset
        // match ("Zoe River" must not become ambiguous with "Zoe River Jr").
        let exact = matches.filter { person in
            Self.allNames(of: person).contains {
                FamilyIdentityText.tokens($0) == tokens
            }
        }
        if !matches.isEmpty { return exact.isEmpty ? matches : exact }

        // Nothing token-exact (2026-08-24, Rick: "tell me about fred lamb"
        // declined although Frederick Burton Lamb is right there). Two
        // deterministic fallbacks, tried in order, still never substring
        // matching in the middle of a name:
        //   1. Diminutives: each token may expand through the curated
        //      table (fred → frederick). Exact-token match on the result.
        //   2. Unique prefix: every asked token (≥3 letters) must be a
        //      PREFIX of some name token ("ann" finds Anna and Ann — the
        //      caller's ambiguity handling asks which one).
        // Fuzzy fallbacks assert only a UNIQUE person. "rick" → "richard"
        // matching three Richards must read as not-found (so the People
        // tab or a "did you mean…?" list can answer), never as GEDCOM
        // ambiguity (regression caught 2026-08-24: "Which rick do you mean?").
        let expanded = tokens.map { Self.diminutives[$0] ?? $0 }
        if expanded != tokens {
            let byNickname = people.values.filter { person in
                Self.allNames(of: person).contains { candidate in
                    let nameTokens = Set(FamilyIdentityText.tokens(candidate))
                    return expanded.allSatisfy { nameTokens.contains($0) }
                }
            }
            if byNickname.count == 1 { return byNickname }
            if byNickname.count > 1 { return [] }
        }
        guard tokens.allSatisfy({ $0.count >= 3 }) else { return [] }
        let byPrefix = people.values.filter { person in
            Self.allNames(of: person).contains { candidate in
                let nameTokens = FamilyIdentityText.tokens(candidate)
                return tokens.allSatisfy { asked in
                    nameTokens.contains { $0.hasPrefix(asked) }
                }
            }
        }
        return byPrefix.count == 1 ? byPrefix : []
    }

    /// The root person record, when the tree has one (see `rootPersonID`).
    public var rootPerson: Person? { rootPersonID.flatMap { people[$0] } }

    /// The person carrying this FamilySearch ID ("GVQV-NW3"), case- and
    /// whitespace-tolerant. O(1) — indexed at parse. Nil for an empty or
    /// malformed ID or one the tree does not carry.
    public func person(familySearchID raw: String?) -> Person? {
        guard let raw else { return nil }
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard Self.isFamilySearchID(key), let id = personIDByFamilySearchID[key] else { return nil }
        return people[id]
    }

    /// Tokens that are generational suffixes, not names: ignored on both
    /// sides of `people(namedLike:)`.
    public static let nameSuffixes: Set<String> = ["jr", "sr", "ii", "iii", "iv", "junior", "senior"]

    /// Owner-style loose match (2026-08-26): every typed token, expanded
    /// through `diminutives`, must appear among the person's name tokens.
    /// A generational suffix (Jr/Sr/III) on the RECORD is ignored unless
    /// the typed name carries one — "Rick Breen" finds BOTH "Richard
    /// Harding Breen Jr" and "… Sr"; "Rick Breen Jr" finds only Jr. Middle
    /// names on the record side are allowed. Unlike `people(matching:)`,
    /// ambiguity is RETURNED (all candidates, name order) rather than
    /// collapsed to not-found, because the caller here has a tie-breaker
    /// (the tree root) and otherwise asks which one. Never
    /// substring-matches: "ann" still does not find "Joanne".
    public func people(namedLike typed: String) -> [Person] {
        // Predicate shared with `NameIndex` (see +NameIndex.swift) so the
        // indexed and linear paths can never drift apart.
        guard let tokens = Self.namedLikeTokens(typed) else { return [] }
        return people.values.filter { Self.personMatches($0, namedLikeTokens: tokens) }
        .sorted { $0.name == $1.name ? $0.id < $1.id : $0.name < $1.name }
    }

    /// Curated diminutive → formal-name table (lowercased tokens). Data,
    /// not heuristics: only pairs a family archivist would vouch for.
    public static let diminutives: [String: String] = [
        "fred": "frederick", "freddy": "frederick",
        "will": "william", "bill": "william", "billy": "william", "willie": "william",
        "dave": "david", "davey": "david",
        "dick": "richard", "rich": "richard", "richie": "richard", "rick": "richard", "ricky": "richard",
        "tim": "timothy", "timmy": "timothy",
        "tom": "thomas", "tommy": "thomas",
        "jim": "james", "jimmy": "james",
        "bob": "robert", "bobby": "robert", "rob": "robert", "robbie": "robert",
        "ted": "theodore", "teddy": "theodore",
        "ed": "edward", "eddie": "edward", "ned": "edward",
        "joe": "joseph", "joey": "joseph",
        "jack": "john", "johnny": "john",
        "steve": "stephen", "steven": "stephen",
        "mike": "michael", "mickey": "michael",
        "dan": "daniel", "danny": "daniel",
        "sam": "samuel", "sammy": "samuel",
        "nate": "nathaniel", "nat": "nathaniel",
        "chris": "christopher",
        "pete": "peter",
        "geo": "george",
        "kate": "katherine", "katie": "katherine", "kathy": "katherine", "kitty": "katherine",
        "liz": "elizabeth", "lizzie": "elizabeth", "beth": "elizabeth", "betty": "elizabeth", "betsy": "elizabeth", "eliza": "elizabeth",
        "maggie": "margaret", "meg": "margaret", "peggy": "margaret",
        "molly": "mary", "polly": "mary",
        "nellie": "ellen", "nell": "ellen",
        "abby": "abigail",
        "sue": "susan", "susie": "susan", "suzie": "susan",
        "nancy": "ann",
        "sally": "sarah",
        "hattie": "harriet",
        "millie": "mildred",
        "winnie": "winifred",
        "eileen": "eileen",
    ]

    // MARK: Kinship

    public enum Relation: String, CaseIterable, Sendable {
        case father, mother, parents, brother, sister, siblings
        case son, daughter, children, husband, wife, spouse
    }

    /// Resolve "<relation> of <person>" → the related people. Empty
    /// when the graph simply doesn't record it — the archivist answers
    /// honestly rather than guessing.
    /// Every marriage the tree records for a person, in file order.
    public func marriages(of person: Person) -> [Marriage] {
        person.spouseOfFamilies.compactMap { id -> Marriage? in
            guard let family = families[id] else { return nil }
            let spouseID = [family.husband, family.wife].compactMap { $0 }.first { $0 != person.id }
            return Marriage(spouse: spouseID.flatMap { people[$0] }, date: family.marriageDate)
        }
    }

    public func relatives(_ relation: Relation, of person: Person) -> [Person] {
        func lookup(_ id: String?) -> Person? {
            guard let id else { return nil }
            return people[id]
        }
        switch relation {
        case .father:
            return uniquePeople(parentFamilies(of: person).compactMap { lookup($0.husband) })
        case .mother:
            return uniquePeople(parentFamilies(of: person).compactMap { lookup($0.wife) })
        case .parents:
            return relatives(.father, of: person) + relatives(.mother, of: person)
        case .brother, .sister, .siblings:
            let sibs = uniquePeople(parentFamilies(of: person)
                .flatMap(\.children)
                .filter { $0 != person.id }
                .compactMap { people[$0] })
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

    private func parentFamilies(of person: Person) -> [Family] {
        let identifiers = person.childOfFamilies.isEmpty
            ? [person.childOfFamily].compactMap { $0 }
            : person.childOfFamilies
        return identifiers.compactMap { families[$0] }
    }

    private func uniquePeople(_ candidates: [Person]) -> [Person] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.id).inserted }
    }

    private static func allNames(of person: Person) -> [String] {
        [person.name] + person.alternateNames
    }

    private static func applyPersonLine(
        level: Int,
        tag: String,
        value: String,
        person: inout Person,
        pendingEvent: inout String?
    ) {
        if level == 1 { pendingEvent = (tag == "BIRT" || tag == "DEAT") ? tag : nil }
        if applyPersonEventDetail(level: level, tag: tag, value: value,
                                  person: &person, event: pendingEvent) { return }
        switch (level, tag) {
        case (1, "NAME"):
            applyName(value, to: &person)
        case (1, "SEX"):
            person.sex = value
        case (1, "FAMC"):
            if !value.isEmpty, person.childOfFamily == nil {
                person.childOfFamily = value
            }
            if !value.isEmpty, !person.childOfFamilies.contains(value) {
                person.childOfFamilies.append(value)
            }
        case (1, "FAMS"):
            if !value.isEmpty, !person.spouseOfFamilies.contains(value) {
                person.spouseOfFamilies.append(value)
            }
        case (1, "_FSFTID") where person.familySearchID == nil:
            let identifier = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .uppercased()
            if isFamilySearchID(identifier) { person.familySearchID = identifier }
        default:
            break
        }
    }

    private static func applyPersonEventDetail(
        level: Int,
        tag: String,
        value: String,
        person: inout Person,
        event: String?
    ) -> Bool {
        guard level == 2, let event else { return false }
        switch (tag, event) {
        case ("DATE", "BIRT") where person.birthDate == nil:
            person.birthDate = value
        case ("DATE", "DEAT") where person.deathDate == nil:
            person.deathDate = value
        case ("PLAC", "BIRT") where person.birthPlace == nil && !value.isEmpty:
            person.birthPlace = value
        case ("PLAC", "DEAT") where person.deathPlace == nil && !value.isEmpty:
            person.deathPlace = value
        default:
            return false
        }
        return true
    }

    private static func applyName(_ value: String, to person: inout Person) {
        let parsed = parseName(value)
        if person.name.isEmpty {
            person.name = parsed.display
            person.surname = parsed.surname
        } else if !parsed.display.isEmpty,
                  parsed.display != person.name,
                  !person.alternateNames.contains(parsed.display) {
            person.alternateNames.append(parsed.display)
            if let surname = parsed.surname,
               surname != person.surname,
               !person.alternateSurnames.contains(surname) {
                person.alternateSurnames.append(surname)
            }
        }
    }

    private static func applyFamilyLine(
        level: Int,
        tag: String,
        value: String,
        family: inout Family,
        pendingEvent: inout String?
    ) {
        if level == 1 { pendingEvent = tag == "MARR" ? tag : nil }
        switch (level, tag) {
        case (1, "HUSB"): family.husband = value
        case (1, "WIFE"): family.wife = value
        case (1, "CHIL"): family.children.append(value)
        case (2, "DATE") where pendingEvent == "MARR" && family.marriageDate == nil:
            family.marriageDate = value
        default: break
        }
    }

    /// Display and surname are the normalized spellings ("Mc Gill" →
    /// "McGill", see FamilyNameNormalizer); the raw NAME line is not kept.
    private static func parseName(_ value: String) -> (display: String, surname: String?) {
        guard let open = value.firstIndex(of: "/"),
              let close = value[value.index(after: open)...].firstIndex(of: "/") else {
            let display = value.split(separator: " ").joined(separator: " ")
            return (FamilyNameNormalizer.normalizeName(display), nil)
        }
        let raw = value[value.index(after: open)..<close]
            .trimmingCharacters(in: .whitespaces)
        let surname = raw.isEmpty ? nil : FamilyNameNormalizer.normalizeSurname(raw)
        // Rebuild the display from the three GEDCOM parts so the fused
        // surname lands in it whether or not the given name is normalized.
        let before = value[..<open].split(separator: " ").joined(separator: " ")
        let after = value[value.index(after: close)...].split(separator: " ").joined(separator: " ")
        let display = [FamilyNameNormalizer.normalizeName(before), surname ?? "", after]
            .filter { !$0.isEmpty }.joined(separator: " ")
        return (display, surname)
    }

    private static func isFamilySearchID(_ value: String) -> Bool {
        let parts = value.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 4, parts[1].count == 3 else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        return parts.joined().unicodeScalars.allSatisfy { allowed.contains($0) }
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
