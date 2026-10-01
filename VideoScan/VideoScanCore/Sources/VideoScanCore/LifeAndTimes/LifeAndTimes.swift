// LifeAndTimes.swift (VideoScanCore)
// Life & Times enrichment, stage 1 (GH #238, Rick 2026-10-01): for the
// family's DECEASED, what history they lived through, who was of military
// age in a war, and what work they did. Pure logic over the tree; no
// network, no model, no I/O. Consumers: Hallie, Person of the Day, and the
// future "Tell me a story" (#236). A tree walk can store `PersonFacts`
// (Codable) beside its decorations later.
//
// THE FACADE
//   let ctx = LifeAndTimes.Context(graph: g, details: GedcomLifeDetails(gedcomText: text),
//                                  options: .init(currentYear: 2026))
//   LifeAndTimes.facts(for: person, in: ctx)          → PersonFacts? (nil = skipped)
//   LifeAndTimes.serviceScan(in: ctx, people: …)      → candidates + counts
//   LifeAndTimes.researchQueue(in: ctx, people: …)    → [ResearchRequest] (input only)
//   LifeAndTimes.aggregate(label: "Irish line", people: …, in: ctx) → OccupationAggregate
//
// PRIVACY — the living are skipped, by a rule STRICTER than LifeStatus's
// presumption: anyone with no recorded death whose LATEST possible birth
// year is after currentYear − 100 — or whose birth is not dated at all — is
// treated as living, whatever their relatives' dates say. The boundary is
// the app's own (LifeStatus: born ≤ currentYear − 100 → presumed deceased):
// in 2026 a birth in 1926 is presumed deceased, 1927 is living. Stricter
// only in ignoring the relatives rules (3–5) and in reading "ABT 1925" by
// its latest year (1927 → living). A
// skipped person produces no facts, no service candidacy, no research
// request, and no occupation count (they are counted only as "living
// skipped"). Pinned by the LifeAndTimesPrivacy sensor suite.
//
// NO GLOBAL STATE: the current year comes in through `Options`; every table
// is an immutable `static let`. C++ readers: `enum LifeAndTimes {}` with no
// cases is a namespace; the nested structs are plain value types.

import Foundation

public enum LifeAndTimes {

    /// Bump when the meaning of any stored field changes (a stored
    /// PersonFacts with an older version is stale).
    public static let version = 1

    // MARK: - Input

    /// One person as Life & Times reads them. Build from a graph Person +
    /// GedcomLifeDetails, or directly (tests, other sources).
    public struct Subject: Sendable, Equatable {
        public var id: String
        public var name: String
        public var surname: String?
        /// "M" / "F" / "" as recorded.
        public var sex: String
        public var birthDate: String?
        public var deathDate: String?
        public var birthPlace: String?
        public var deathPlace: String?
        public var residences: [GedcomLifeDetails.Residence]
        public var occupations: [GedcomLifeDetails.Occupation]
        public var notes: [String]
        public var militaryFacts: [GedcomFamilyGraph.MilitaryFact]

        public init(id: String, name: String, surname: String? = nil, sex: String,
                    birthDate: String?, deathDate: String?,
                    birthPlace: String? = nil, deathPlace: String? = nil,
                    residences: [GedcomLifeDetails.Residence] = [],
                    occupations: [GedcomLifeDetails.Occupation] = [],
                    notes: [String] = [],
                    militaryFacts: [GedcomFamilyGraph.MilitaryFact] = []) {
            self.id = id
            self.name = name
            self.surname = surname
            self.sex = sex
            self.birthDate = birthDate
            self.deathDate = deathDate
            self.birthPlace = birthPlace
            self.deathPlace = deathPlace
            self.residences = residences
            self.occupations = occupations
            self.notes = notes
            self.militaryFacts = militaryFacts
        }

        public init(person: GedcomFamilyGraph.Person, details: GedcomLifeDetails.Details? = nil) {
            self.init(id: person.id, name: person.name, surname: person.surname, sex: person.sex,
                      birthDate: person.birthDate, deathDate: person.deathDate,
                      birthPlace: person.birthPlace, deathPlace: person.deathPlace,
                      residences: details?.residences ?? [], occupations: details?.occupations ?? [],
                      notes: details?.notes ?? [], militaryFacts: person.militaryFacts)
        }

        /// A death is recorded (a year, or any text such as "Deceased").
        public var deathRecorded: Bool {
            !(deathDate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }
    }

    public struct Options: Sendable, Equatable {
        /// The year "now" — passed in, never read from a clock here.
        public var currentYear: Int
        /// Lived-through lines kept per person.
        public var maxLines: Int
        /// No death recorded + birth possibly within this many years = living.
        public var livingThresholdYears: Int
        public var timeline: [HistoricalEvent]
        public var wars: [ServiceWar]

        public init(currentYear: Int, maxLines: Int = 5, livingThresholdYears: Int = 100,
                    timeline: [HistoricalEvent] = LifeAndTimes.timeline,
                    wars: [ServiceWar] = LifeAndTimes.defaultWars) {
            self.currentYear = currentYear
            self.maxLines = max(0, maxLines)
            self.livingThresholdYears = max(100, livingThresholdYears)   // never looser than 100
            self.timeline = timeline
            self.wars = wars
        }
    }

    // MARK: - Privacy

    public enum SkipReason: String, Sendable, Codable, Equatable {
        /// Treated as living (conservative rule above).
        case living
        /// Deceased but no birth year: nothing to measure against.
        case noBirthDate
    }

    /// The conservative living rule. True = skip.
    public static func isTreatedAsLiving(_ subject: Subject, currentYear: Int, thresholdYears: Int = 100) -> Bool {
        if subject.deathRecorded { return false }
        guard let birth = GedcomYearInterval.parse(subject.birthDate) else { return true }
        // AFT 1900 (no upper bound) could be yesterday.
        guard let latest = birth.upper else { return true }
        // `>` matches LifeStatus (born ≤ currentYear − 100 → presumed deceased).
        return latest > currentYear - max(100, thresholdYears)
    }

    static func skipReason(_ subject: Subject, options: Options) -> SkipReason? {
        if isTreatedAsLiving(subject, currentYear: options.currentYear, thresholdYears: options.livingThresholdYears) {
            return .living
        }
        if DatedYear.parse(subject.birthDate) == nil { return .noBirthDate }
        return nil
    }

    // MARK: - Output

    public enum LifeStatusTag: String, Sendable, Codable, Equatable {
        /// A death is recorded.
        case deceased
        /// No death recorded, born ≥ 100 years ago.
        case presumedDeceased
    }

    /// Everything stage 1 knows about one person. Codable for decorations.
    public struct PersonFacts: Sendable, Codable, Equatable {
        public var version = LifeAndTimes.version
        public let personID: String
        public let name: String
        public let status: LifeStatusTag
        public let birth: DatedYear
        public let death: DatedYear?
        /// Regions their recorded places fall in, sorted.
        public let regions: [Region]
        /// The best few lines, in date order.
        public let livedThrough: [LivedThroughLine]
        public let service: [ServiceCandidate]
        public let occupations: [ClassifiedOccupation]
        /// Military facts the tree already records (verbatim summaries).
        public let recordedMilitary: [String]

        /// Sentences Hallie could say, deterministic and grounded:
        /// lived-through lines, then occupations, then service candidacy
        /// (phrased as a lead, never as service).
        public var storyLines: [String] {
            var out = livedThrough.map { $0.sentence(subject: name) }
            let jobs = occupations.filter(\.isOccupation)
            if !jobs.isEmpty {
                let words = jobs.map { o -> String in
                    var w = (o.term ?? o.raw)
                    if o.retired { w = "retired " + w }
                    return w
                }
                var unique: [String] = []
                for w in words where !unique.contains(w) { unique.append(w) }
                let fromNotes = jobs.allSatisfy { $0.evidence == .note }
                out.append("\(name) is recorded as \(LifeAndTimes.listPhrase(unique.map(LifeAndTimes.withArticle)))"
                           + (fromNotes ? " (from a note)" : "") + ".")
                if let doubt = jobs.compactMap(\.ambiguity).first { out.append("(\(doubt).)") }
            }
            for s in service {
                // No provable age (a birth that leaves the person possibly
                // not yet born — "BEF 1947" for 1941, generated-input F10):
                // the age window only says service was POSSIBLE, so say so.
                let age = s.ageAtStart.map { "was \($0.spoken) \(s.startPhrase)" }
                    ?? "may have been of military age during \(s.warName)"
                let where_ = s.regions.isEmpty ? "" : ", with ties to \(LifeAndTimes.listPhrase(s.regions.map(\.label)))"
                let lead = s.strength == .strong ? "a strong lead" : "a possible lead"
                out.append("\(name) \(age)\(where_) — \(lead) for service records, not yet checked.")
            }
            if !recordedMilitary.isEmpty {
                out.append("The tree records military service for \(name): \(recordedMilitary.joined(separator: "; ")).")
            }
            return out
        }
    }

    // MARK: - Context

    /// The graph plus the side details, with options. Build once per tree.
    public struct Context: Sendable {
        public let graph: GedcomFamilyGraph?
        public let details: GedcomLifeDetails
        public let options: Options

        public init(graph: GedcomFamilyGraph?, details: GedcomLifeDetails = GedcomLifeDetails(),
                    options: Options) {
            self.graph = graph
            self.details = details
            self.options = options
        }

        public func subject(for person: GedcomFamilyGraph.Person) -> Subject {
            Subject(person: person, details: details[person.id])
        }
    }

    // MARK: - Facade

    /// Facts for a tree person; nil when skipped (living / undated).
    public static func facts(for person: GedcomFamilyGraph.Person, in context: Context) -> PersonFacts? {
        facts(for: context.subject(for: person), options: context.options)
    }

    /// Facts for any subject; nil when skipped (living / undated).
    public static func facts(for subject: Subject, options: Options) -> PersonFacts? {
        guard skipReason(subject, options: options) == nil,
              let birth = DatedYear.parse(subject.birthDate) else { return nil }
        let death = DatedYear.parse(subject.deathDate)
        let lifespan = Lifespan(birth: birth, death: death, deathRecorded: subject.deathRecorded)
        let presences = Self.presences(of: subject)
        // Array == short-circuits on shared storage, so the default table
        // costs O(1) here; a custom table builds its own index.
        let byID = options.timeline == timeline ? HistoricalTimeline.byID
            : Dictionary(options.timeline.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let all = allLines(lifespan: lifespan, presences: presences, sex: subject.sex, timeline: options.timeline)
        let best = ranked(all, maxLines: options.maxLines, timeline: byID)
        var service: [ServiceCandidate] = []
        for war in options.wars {
            if case .success(let c) = candidate(subject: subject, lifespan: lifespan, presences: presences, war: war) {
                service.append(c)
            }
        }
        var regions: [Region] = []
        for p in presences where !regions.contains(p.region) { regions.append(p.region) }
        return PersonFacts(
            personID: subject.id, name: subject.name,
            status: subject.deathRecorded ? .deceased : .presumedDeceased,
            birth: birth, death: death, regions: regions.sorted(), livedThrough: best,
            service: service, occupations: occupations(of: subject),
            recordedMilitary: subject.militaryFacts.compactMap { f in
                guard let s = f.summary else { return f.year.map { "military record \($0)" } }
                return [s, f.year.map(String.init)].compactMap { $0 }.joined(separator: " ")
            })
    }

    /// Every recorded place → a presence (unknown places are dropped).
    public static func presences(of subject: Subject) -> [Presence] {
        var out: [Presence] = []
        if let p = subject.birthPlace, let r = region(ofPlace: p) {
            out.append(Presence(region: r, source: .birth, year: GedcomFamilyGraph.year(in: subject.birthDate), place: p))
        }
        for res in subject.residences {
            if let r = region(ofPlace: res.place) {
                out.append(Presence(region: r, source: .residence, year: res.year, place: res.place))
            }
        }
        for f in subject.militaryFacts {
            if let p = f.place, let r = region(ofPlace: p) {
                out.append(Presence(region: r, source: .military, year: f.year, place: p))
            }
        }
        if let p = subject.deathPlace, let r = region(ofPlace: p) {
            out.append(Presence(region: r, source: .death, year: GedcomFamilyGraph.year(in: subject.deathDate), place: p))
        }
        return out
    }

    // MARK: - Service scan

    public struct ServiceScan: Sendable, Codable, Equatable {
        public var candidates: [ServiceCandidate] = []
        public var counts = ServiceScanCounts()
    }

    /// Service-age candidates for one war (or all wars when `warID` is nil)
    /// among `subjects`, strongest first, with the exclusion counts.
    public static func serviceScan(subjects: [Subject], warID: String? = nil, options: Options) -> ServiceScan {
        var scan = ServiceScan()
        let wars = options.wars.filter { warID == nil || $0.id == warID }
        for subject in subjects {
            scan.counts.considered += 1
            switch skipReason(subject, options: options) {
            case .living?: scan.counts.skippedLiving += 1; continue
            case .noBirthDate?: scan.counts.skippedNoBirthDate += 1; continue
            case nil: break
            }
            guard let birth = DatedYear.parse(subject.birthDate) else { continue }
            let lifespan = Lifespan(birth: birth, death: DatedYear.parse(subject.deathDate),
                                    deathRecorded: subject.deathRecorded)
            let presences = Self.presences(of: subject)
            for war in wars {
                switch candidate(subject: subject, lifespan: lifespan, presences: presences, war: war) {
                case .success(let c): scan.candidates.append(c); scan.counts.candidates += 1
                case .failure(let why):
                    switch why.reason {
                    case .sex: scan.counts.excludedBySex += 1
                    case .unknownSex: scan.counts.excludedUnknownSex += 1
                    case .age: scan.counts.outOfAgeOrLife += 1
                    case .place: scan.counts.noMatchingPlace += 1
                    }
                }
            }
        }
        scan.candidates.sort { a, b in
            if a.strength != b.strength { return a.strength > b.strength }
            if a.warID != b.warID { return a.warID < b.warID }
            return a.personID < b.personID
        }
        return scan
    }

    public static func serviceScan(in context: Context, people: [GedcomFamilyGraph.Person],
                                   warID: String? = nil) -> ServiceScan {
        serviceScan(subjects: people.map(context.subject(for:)), warID: warID, options: context.options)
    }

    /// The research queue's input: one proposed request per candidate.
    public static func researchQueue(subjects: [Subject], warID: String? = nil, options: Options) -> [ResearchRequest] {
        let scan = serviceScan(subjects: subjects, warID: warID, options: options)
        let byID = Dictionary(subjects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return scan.candidates.compactMap { c in byID[c.personID].flatMap { researchRequest(for: c, subject: $0) } }
    }

    public static func researchQueue(in context: Context, people: [GedcomFamilyGraph.Person],
                                     warID: String? = nil) -> [ResearchRequest] {
        researchQueue(subjects: people.map(context.subject(for:)), warID: warID, options: context.options)
    }

    // MARK: - Occupation aggregates

    public struct OccupationAggregate: Sendable, Codable, Equatable {
        public let label: String
        /// People in the line, before skipping.
        public let people: Int
        public let skippedLiving: Int
        /// Deceased people considered.
        public let considered: Int
        /// Of those, with at least one real occupation.
        public let withOccupation: Int
        /// Only a status word (spinster, widow …).
        public let statusOnly: Int
        /// People per category (a person may be in two).
        public let counts: [OccupationCategory: Int]
        /// People per canonical term within each category.
        public let terms: [OccupationCategory: [String: Int]]

        /// "Irish line: 9 labourers, 2 soldiers, 1 printer — occupations
        /// recorded for 12 of 31 people (3 living skipped)."
        public var spoken: String {
            let ordered = counts.filter { $0.key != .status && $0.key != .unknown }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            var parts: [String] = []
            for (category, n) in ordered {
                let t = terms[category] ?? [:]
                if t.count == 1, let term = t.keys.first, !term.contains("(") {
                    parts.append("\(n) \(n == 1 ? term : LifeAndTimes.plural(term))")
                } else {
                    parts.append("\(n) \(n == 1 ? category.noun.one : category.noun.many)")
                }
            }
            var s = "\(label): " + (parts.isEmpty ? "no occupations recorded" : parts.joined(separator: ", "))
            s += " — occupations recorded for \(withOccupation) of \(considered) \(considered == 1 ? "person" : "people")"
            if skippedLiving > 0 { s += " (\(skippedLiving) living skipped)" }
            return s + "."
        }

        /// True when every recorded occupation is labourer/farming/domestic.
        public var allManualOrLand: Bool {
            let real = counts.filter { $0.key != .status && $0.key != .unknown && $0.value > 0 }
            return !real.isEmpty && real.keys.allSatisfy { [.labourer, .farming, .domesticService].contains($0) }
        }
    }

    public static func aggregate(label: String, subjects: [Subject], options: Options) -> OccupationAggregate {
        var skipped = 0, considered = 0, withOcc = 0, statusOnly = 0
        var counts: [OccupationCategory: Int] = [:]
        var terms: [OccupationCategory: [String: Int]] = [:]
        for s in subjects {
            if isTreatedAsLiving(s, currentYear: options.currentYear, thresholdYears: options.livingThresholdYears) {
                skipped += 1
                continue
            }
            considered += 1
            let occ = occupations(of: s)
            let real = occ.filter(\.isOccupation)
            if real.isEmpty {
                if occ.contains(where: { $0.category == .status }) { statusOnly += 1 }
                continue
            }
            withOcc += 1
            var seenCategories = Set<OccupationCategory>()
            var seenTerms = Set<String>()
            for o in real {
                if seenCategories.insert(o.category).inserted { counts[o.category, default: 0] += 1 }
                let term = o.term ?? o.raw
                if seenTerms.insert("\(o.category.rawValue)|\(term)").inserted {
                    terms[o.category, default: [:]][term, default: 0] += 1
                }
            }
        }
        if statusOnly > 0 { counts[.status] = statusOnly }
        return OccupationAggregate(label: label, people: subjects.count, skippedLiving: skipped,
                                   considered: considered, withOccupation: withOcc, statusOnly: statusOnly,
                                   counts: counts, terms: terms)
    }

    public static func aggregate(label: String, people: [GedcomFamilyGraph.Person], in context: Context) -> OccupationAggregate {
        aggregate(label: label, subjects: people.map(context.subject(for:)), options: context.options)
    }

    /// A "line": the ancestors of `person` up to `generations`, optionally
    /// only those with a recorded place in `region` (birth, residence or
    /// death) — "Rick's Irish line" = ancestors(of: rick, region: .ireland).
    /// The living are left out unless `includeLiving` (the aggregate asks
    /// for them only to COUNT them as skipped).
    public static func ancestors(of person: GedcomFamilyGraph.Person, in context: Context,
                                 generations: Int = 12, region: Region? = nil,
                                 includeLiving: Bool = false) -> [GedcomFamilyGraph.Person] {
        guard let graph = context.graph else { return [] }
        let options = context.options
        return graph.ancestorLine(of: person, line: .both, generations: generations).flatMap(\.people).filter { p in
            let subject = context.subject(for: p)
            if !includeLiving, isTreatedAsLiving(subject, currentYear: options.currentYear,
                                                 thresholdYears: options.livingThresholdYears) { return false }
            guard let region else { return true }
            return presences(of: subject).contains { region.covers($0.region) }
        }
    }

    /// "Rick's Irish line: …" in one call: the line's ancestors (living
    /// included only so the sentence can say how many were skipped).
    public static func aggregate(label: String, ancestorsOf person: GedcomFamilyGraph.Person, in context: Context,
                                 generations: Int = 12, region: Region? = nil) -> OccupationAggregate {
        aggregate(label: label,
                  people: ancestors(of: person, in: context, generations: generations, region: region,
                                    includeLiving: true),
                  in: context)
    }

    // MARK: - Words

    static func plural(_ term: String) -> String {
        if term.hasSuffix("s") || term.hasSuffix("sh") || term.hasSuffix("ch") { return term + "es" }
        if term.hasSuffix("man") { return String(term.dropLast(3)) + "men" }
        return term + "s"
    }

    static func withArticle(_ word: String) -> String {
        guard let first = word.lowercased().first else { return word }
        return ("aeiou".contains(first) ? "an " : "a ") + word
    }

    static func listPhrase(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2: return "\(items[0]) and \(items[1])"
        default: return items.dropLast().joined(separator: ", ") + " and " + items[items.count - 1]
        }
    }
}

extension LifeAndTimes.OccupationCategory: CodingKeyRepresentable {}
