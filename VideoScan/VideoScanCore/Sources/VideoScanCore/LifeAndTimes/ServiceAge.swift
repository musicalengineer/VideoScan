// ServiceAge.swift (VideoScanCore)
// "Did the men serve in WWI?" — stage 1 does NOT answer that. It answers
// the question that comes first: who was OF MILITARY AGE, of the recorded
// sex, and living somewhere that fought, so a future overnight research job
// knows whom to look up (TNA WO 363/364/372, US draft registrations,
// Chronicling America). GH #238, Rick 2026-10-01.
//
// A candidate is a PROPOSAL, never a claim of service (CyberBrain
// discipline: findings are proposals until Rick confirms). Each candidate
// carries its reasoning as plain lines so the queue, and Rick, can see why.
//
// Age test, by intervals (birth "ABT 1890" = [1888, 1892]):
//   possible — some war year y has an age that COULD be in the band:
//              y ∈ [min + bLo, max + bHi] ∩ [bLo, dHi] ∩ war years;
//   strong   — some war year has an age PROVEN in the band while PROVEN
//              alive: y ∈ [min + bHi, max + bLo] ∩ [bHi + 1, dLo − 1] ∩ war
//              years (no death year: alive is taken as proven only within 60
//              years of birth — the same rule as the lived-through lines).
// Band edges are inclusive: 18 and 45 are both in an 18–45 band.
// Place test: one of the person's places is in a theatre's regions. Strong
// needs a strong place too — a dated residence or military fact near the
// war years, or born AND died in the theatre. Born in Ireland and died in
// Boston is "possible" for both the UK/Ireland and the US theatres: where he
// was in 1916 is exactly what the research is for.
//
// No network, no I/O. The `ResearchRequest` type is the queue's INPUT
// shape; nothing here sends it anywhere.

import Foundation

extension LifeAndTimes {

    /// A configurable age band, by sex as recorded ("M" / "F").
    public struct ServiceBand: Sendable, Codable, Equatable {
        public var minAge: Int
        public var maxAge: Int
        public var sexes: Set<String>

        public init(minAge: Int, maxAge: Int, sexes: Set<String> = ["M"]) {
            self.minAge = min(minAge, maxAge)
            self.maxAge = max(minAge, maxAge)
            self.sexes = Set(sexes.map { $0.uppercased() })
        }

        public var label: String { "\(minAge)–\(maxAge)" }
    }

    /// Where the research queue would look. Labels name the real record
    /// series; nothing here fetches them.
    public enum ResearchTarget: String, Sendable, Codable, CaseIterable, Hashable {
        case tnaWO363
        case tnaWO364
        case tnaWO372
        case usWWIDraftRegistration
        case usWWIIDraftRegistration
        case usCivilWarDraftRegistration
        case usRevolutionaryWarPensions
        case usWar1812Pensions
        case canadaCEFPersonnel
        case chroniclingAmerica

        public var label: String {
            switch self {
            case .tnaWO363: return "The National Archives WO 363 (British Army WWI service records)"
            case .tnaWO364: return "The National Archives WO 364 (British Army WWI pension records)"
            case .tnaWO372: return "The National Archives WO 372 (WWI medal index cards)"
            case .usWWIDraftRegistration: return "US WWI draft registration cards, 1917–1918 (NARA M1509)"
            case .usWWIIDraftRegistration: return "US WWII draft registration cards, 1940–1947"
            case .usCivilWarDraftRegistration: return "US Civil War draft registrations, 1863–1865 (NARA RG 110)"
            case .usRevolutionaryWarPensions: return "US Revolutionary War pension and bounty-land files (NARA M804)"
            case .usWar1812Pensions: return "US War of 1812 pension files (NARA)"
            case .canadaCEFPersonnel: return "Library and Archives Canada, CEF personnel files"
            case .chroniclingAmerica: return "Chronicling America (Library of Congress newspapers)"
            }
        }
    }

    /// One country-group's part in a war: when it fought and where to look.
    public struct Theatre: Sendable, Codable, Equatable {
        public var regions: [Region]
        public var startYear: Int
        public var endYear: Int
        public var targets: [ResearchTarget]
        public var note: String?

        public init(regions: [Region], startYear: Int, endYear: Int,
                    targets: [ResearchTarget] = [], note: String? = nil) {
            self.regions = regions
            self.startYear = startYear
            self.endYear = max(startYear, endYear)
            self.targets = targets
            self.note = note
        }

        var label: String { regions.map(\.label).joined(separator: "/") + " \(startYear)–\(endYear)" }
        func covers(_ r: Region) -> Bool { r.touched(by: regions, in: startYear) }
    }

    public struct ServiceWar: Sendable, Codable, Equatable, Identifiable {
        /// The timeline event id ("ww1").
        public var id: String
        public var name: String
        public var band: ServiceBand
        public var theatres: [Theatre]
        /// Where the band comes from.
        public var source: String

        public init(id: String, name: String, band: ServiceBand, theatres: [Theatre], source: String) {
            self.id = id
            self.name = name
            self.band = band
            self.theatres = theatres
            self.source = source
        }
    }

    /// The default wars and bands. Configurable: pass your own to
    /// `Options.wars` (e.g. widen WWI to 18–51 for the 1918 UK extension).
    public static let defaultWars: [ServiceWar] = [
        ServiceWar(id: "american-revolution", name: "the American Revolution",
                   band: ServiceBand(minAge: 16, maxAge: 60),
                   theatres: [Theatre(regions: [.unitedStates], startYear: 1775, endYear: 1783,
                                      targets: [.usRevolutionaryWarPensions])],
                   source: "Colonial militia acts enrolled men 16–60 (e.g. Massachusetts)"),
        ServiceWar(id: "war-of-1812", name: "the War of 1812",
                   band: ServiceBand(minAge: 18, maxAge: 45),
                   theatres: [Theatre(regions: [.unitedStates], startYear: 1812, endYear: 1815,
                                      targets: [.usWar1812Pensions]),
                              Theatre(regions: [.canada], startYear: 1812, endYear: 1815)],
                   source: "US Militia Act of 1792 (men 18–45)"),
        ServiceWar(id: "us-civil-war", name: "the Civil War",
                   band: ServiceBand(minAge: 18, maxAge: 45),
                   theatres: [Theatre(regions: [.unitedStates], startYear: 1861, endYear: 1865,
                                      targets: [.usCivilWarDraftRegistration, .chroniclingAmerica])],
                   source: "Militia Act of 1862 (18–45); Enrollment Act of 1863 (20–45)"),
        ServiceWar(id: "ww1", name: "the First World War",
                   band: ServiceBand(minAge: 18, maxAge: 45),
                   theatres: [Theatre(regions: [.england, .scotland, .wales, .ireland, .britain],
                                      startYear: 1914, endYear: 1918,
                                      targets: [.tnaWO363, .tnaWO364, .tnaWO372],
                                      note: "Conscription never applied in Ireland; Irishmen served as volunteers"),
                              Theatre(regions: [.unitedStates], startYear: 1917, endYear: 1918,
                                      targets: [.usWWIDraftRegistration, .chroniclingAmerica]),
                              Theatre(regions: [.canada], startYear: 1914, endYear: 1918,
                                      targets: [.canadaCEFPersonnel]),
                              Theatre(regions: [.france, .germany, .italy], startYear: 1914, endYear: 1918)],
                   source: "UK Military Service Act 1916 (18–41, to 51 in 1918); US registrations 1917–18 (18–45)"),
        ServiceWar(id: "ww2", name: "the Second World War",
                   band: ServiceBand(minAge: 18, maxAge: 45),
                   theatres: [Theatre(regions: [.unitedStates], startYear: 1941, endYear: 1945,
                                      targets: [.usWWIIDraftRegistration, .chroniclingAmerica]),
                              Theatre(regions: [.england, .scotland, .wales, .britain], startYear: 1939, endYear: 1945),
                              Theatre(regions: [.canada], startYear: 1939, endYear: 1945),
                              Theatre(regions: [.ireland], startYear: 1939, endYear: 1945,
                                      note: "Ireland was neutral; many Irish volunteered in British forces")],
                   source: "US Selective Training and Service Act 1940 (widened to 18–45 in 1942); UK National Service Act 1939 (18–41)"),
        ServiceWar(id: "korean-war", name: "the Korean War",
                   band: ServiceBand(minAge: 18, maxAge: 35),
                   theatres: [Theatre(regions: [.unitedStates], startYear: 1950, endYear: 1953),
                              Theatre(regions: [.england, .scotland, .wales, .britain, .canada], startYear: 1950, endYear: 1953)],
                   source: "US Universal Military Training and Service Act 1951 (18½–35)"),
    ]

    public enum CandidateStrength: String, Sendable, Codable, Comparable, CaseIterable {
        case possible, strong
        public static func < (a: CandidateStrength, b: CandidateStrength) -> Bool { a == .possible && b == .strong }
    }

    /// One person × one war: why they might have served.
    public struct ServiceCandidate: Sendable, Codable, Equatable {
        public let personID: String
        public let name: String
        public let warID: String
        public let warName: String
        public let strength: CandidateStrength
        /// Age when the (earliest matching) theatre's war began / ended.
        public let ageAtStart: QualifiedAge?
        /// What `ageAtStart` is measured at, as words: "when the Second World
        /// War began (1939)" or, when the matching theatre opened later,
        /// "when the United States entered the Second World War (1941)"
        /// (QA P1-B — never re-date the start of the war).
        public let startPhrase: String
        public let ageAtEnd: QualifiedAge?
        public let regions: [Region]
        public let targets: [ResearchTarget]
        /// Plain reasoning lines, in order: sex, age, place, tree evidence.
        public let reasons: [String]
        /// Military facts the tree already records in the war's years.
        public let recordedMilitary: [String]
    }

    /// The research queue's INPUT (stage 1 builds it; nothing sends it).
    public struct ResearchRequest: Sendable, Codable, Equatable, Identifiable {
        public enum Status: String, Sendable, Codable { case proposed }
        /// "personID|warID" — stable, so a re-run de-duplicates.
        public let id: String
        public let personID: String
        public let name: String
        public let surname: String?
        public let birth: DatedYear
        public let birthPlace: String?
        public let deathPlace: String?
        public let residencePlaces: [String]
        public let warID: String
        public let targets: [ResearchTarget]
        public let strength: CandidateStrength
        public let reasons: [String]
        /// Always `.proposed` — a finding becomes fact only when Rick confirms.
        public let status: Status
    }

    /// Why people were not candidates — so the counts can be stated.
    public struct ServiceScanCounts: Sendable, Codable, Equatable {
        public var considered = 0
        public var skippedLiving = 0
        public var skippedNoBirthDate = 0
        public var excludedBySex = 0
        public var excludedUnknownSex = 0
        public var outOfAgeOrLife = 0
        public var noMatchingPlace = 0
        public var candidates = 0
        public init() {}
    }

    public enum ServiceExclusion: Sendable, Equatable {
        case sex, unknownSex, age, place
    }

    // MARK: - Computation

    /// One theatre the person matches: age-possible and a place inside it.
    struct TheatreMatch {
        var theatre: Theatre
        var strongAge: Bool
        var strongPlace: Bool
        var basis: String
    }

    /// The candidacy of one person for one war, or the reason it fails.
    static func candidate(subject: Subject, lifespan: Lifespan, presences: [Presence],
                          war: ServiceWar) -> Result<ServiceCandidate, ServiceExclusionBox> {
        let sex = subject.sex.uppercased()
        guard sex == "M" || sex == "F" else { return .failure(.init(.unknownSex)) }
        guard war.band.sexes.contains(sex) else { return .failure(.init(.sex)) }

        var matches: [TheatreMatch] = []
        var anyAge = false
        for theatre in war.theatres {
            guard let strongAge = ageWindow(lifespan: lifespan, band: war.band, theatre: theatre) else { continue }
            anyAge = true
            guard let (strongPlace, basis) = placeBasis(presences: presences, theatre: theatre) else { continue }
            matches.append(TheatreMatch(theatre: theatre, strongAge: strongAge, strongPlace: strongPlace, basis: basis))
        }
        guard let first = matches.min(by: { $0.theatre.startYear < $1.theatre.startYear }) else {
            return .failure(.init(anyAge ? .place : .age))
        }

        let military = recordedMilitary(subject, during: war)
        let startPhrase = Self.startPhrase(war: war, theatre: first.theatre)
        let ageAtStart = QualifiedAge.at(first.theatre.startYear, birth: lifespan.birth)
        let ageAtEnd = QualifiedAge.at(min(first.theatre.endYear, lifespan.deathHigh), birth: lifespan.birth)
        let strong = !military.isEmpty || matches.contains { $0.strongAge && $0.strongPlace }

        // The PERSON's places that put them in a matching theatre (not the
        // theatre's whole list: "ties to Ireland and the United States").
        var regions: [Region] = []
        var targets: [ResearchTarget] = []
        for m in matches {
            for p in presences where m.theatre.covers(p.region) && !regions.contains(p.region) { regions.append(p.region) }
            for t in m.theatre.targets where !targets.contains(t) { targets.append(t) }
        }
        let reasons = serviceReasons(sex: sex, lifespan: lifespan, war: war, startPhrase: startPhrase,
                                     first: first, matches: matches,
                                     ageAtStart: ageAtStart, ageAtEnd: ageAtEnd, military: military, strong: strong)
        return .success(ServiceCandidate(
            personID: subject.id, name: subject.name, warID: war.id, warName: war.name,
            strength: strong ? .strong : .possible, ageAtStart: ageAtStart, startPhrase: startPhrase,
            ageAtEnd: ageAtEnd,
            regions: regions, targets: targets, reasons: reasons, recordedMilitary: military))
    }

    /// The war's own start: the earliest theatre or the timeline row.
    static func warStartYear(_ war: ServiceWar) -> Int {
        let theatres = war.theatres.map(\.startYear).min() ?? Int.max
        return min(theatres, LifeAndTimes.event(id: war.id)?.startYear ?? Int.max)
    }

    static func startPhrase(war: ServiceWar, theatre: Theatre) -> String {
        if theatre.startYear > warStartYear(war), let who = theatre.regions.first {
            return "when \(who.label) entered \(war.name) (\(theatre.startYear))"
        }
        return "when \(war.name) began (\(theatre.startYear))"
    }

    /// Nil when no year of the theatre can put them in the band while
    /// possibly alive; otherwise whether some year PROVES it (see header).
    static func ageWindow(lifespan: Lifespan, band: ServiceBand, theatre: Theatre) -> Bool? {
        let bLo = lifespan.birthLow, bHi = lifespan.birthHigh
        let ts = theatre.startYear, te = theatre.endYear
        let pLo = max(band.minAge + bLo, bLo, ts)
        let pHi = min(band.maxAge + bHi, lifespan.deathHigh, te)
        guard pLo <= pHi else { return nil }
        let provenAliveUntil = lifespan.deathLow.map { $0 - 1 } ?? lifespan.birth.upper.map { $0 + 60 }
        guard lifespan.birth.lower != nil, lifespan.birth.upper != nil, let alive = provenAliveUntil else { return false }
        let sLo = max(band.minAge + bHi, bHi + 1, ts)
        let sHi = min(band.maxAge + bLo, alive, te)
        return sLo <= sHi
    }

    /// Military facts the tree records in (or within a year of) the war.
    static func recordedMilitary(_ subject: Subject, during war: ServiceWar) -> [String] {
        let warStart = war.theatres.map(\.startYear).min() ?? 0
        let warEnd = war.theatres.map(\.endYear).max() ?? 0
        return subject.militaryFacts.filter { f in
            guard let y = f.year else { return false }
            return y >= warStart - 1 && y <= warEnd + 1
        }.map { f in [f.summary, f.year.map(String.init)].compactMap { $0 }.joined(separator: " ") }
    }

    /// The plain reasoning lines, in order: sex, age, death, place, tree.
    static func serviceReasons(sex: String, lifespan: Lifespan, war: ServiceWar, startPhrase: String,
                               first: TheatreMatch,
                               matches: [TheatreMatch], ageAtStart: QualifiedAge?, ageAtEnd: QualifiedAge?,
                               military: [String], strong: Bool) -> [String] {
        var reasons = [sex == "M" ? "male, as recorded" : "female, as recorded"]
        var ageLine = "born \(lifespan.birth.spoken)"
        if let a = ageAtStart { ageLine += " → \(a.spoken) \(startPhrase)" }
        if let a = ageAtEnd, first.theatre.endYear != first.theatre.startYear {
            ageLine += ", \(a.spoken) at its end (\(min(first.theatre.endYear, lifespan.deathHigh)))"
        }
        reasons.append(ageLine + "; band \(war.band.label)")
        if let d = lifespan.death { reasons.append("died \(d.spoken)") }
        for m in matches {
            reasons.append("\(m.basis) — \(m.theatre.label)" + (m.theatre.note.map { " (\($0))" } ?? ""))
        }
        reasons += military.map { "the tree records: \($0)" }
        if !strong {
            let why = matches.contains { $0.strongAge }
                ? "where they lived in those years is not recorded" : "the dates do not prove the age"
            reasons.append("possible only: \(why)")
        }
        return reasons
    }

    /// (strong place?, the basis sentence), or nil when no place is in the theatre.
    static func placeBasis(presences: [Presence], theatre: Theatre) -> (Bool, String)? {
        let inside = presences.filter { theatre.covers($0.region) }
        guard !inside.isEmpty else { return nil }
        for p in inside where p.source == .residence || p.source == .military {
            guard let y = p.year, y >= theatre.startYear - 10, y <= theatre.endYear + 10 else { continue }
            let verb = p.source == .military ? "military record in" : "lived in"
            return (true, "\(verb) \(p.region.label) in \(y)")
        }
        let birth = presences.first { $0.source == .birth }
        let death = presences.first { $0.source == .death }
        if let b = birth, let d = death, theatre.covers(b.region), theatre.covers(d.region) {
            return (true, "born and died in \(b.region == d.region ? b.region.label : "\(b.region.label) and \(d.region.label)")")
        }
        if let d = death, theatre.covers(d.region) {
            return (false, "died in \(d.region.label)")
        }
        if let b = birth, theatre.covers(b.region) {
            return (death == nil, "born in \(b.region.label)" + (death == nil ? "" : "; died elsewhere"))
        }
        let any = inside[0]
        return (false, "lived in \(any.region.label)")
    }

    /// `Result` needs an `Error` payload; this boxes the reason.
    struct ServiceExclusionBox: Error, Equatable {
        let reason: ServiceExclusion
        init(_ r: ServiceExclusion) { reason = r }
    }

    /// The research-queue input for a candidate.
    public static func researchRequest(for candidate: ServiceCandidate, subject: Subject) -> ResearchRequest? {
        guard let birth = DatedYear.parse(subject.birthDate) else { return nil }
        return ResearchRequest(
            id: "\(candidate.personID)|\(candidate.warID)",
            personID: candidate.personID, name: subject.name, surname: subject.surname,
            birth: birth, birthPlace: subject.birthPlace, deathPlace: subject.deathPlace,
            residencePlaces: subject.residences.map(\.place),
            warID: candidate.warID, targets: candidate.targets, strength: candidate.strength,
            reasons: candidate.reasons, status: .proposed)
    }
}
