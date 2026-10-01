// LivedThrough.swift (VideoScanCore)
// "Was N during X" — the events a person was alive for, their age at each,
// and whether the event touched where they lived (GH #238 stage 1).
//
// DATES ARE INTERVALS. A birth of "ABT 1833" is [1831, 1835]; "BEF 1840"
// is (−∞, 1839]. Every claim is PROVEN by the interval or downgraded:
//   certain   — the person was alive for at least one whole calendar year
//               inside the event: [max(start, bHi+1), min(end, dLo−1)] ≠ ∅;
//   likely    — born or died within the event's years (alive for part of
//               a year the event spans), or a presumed-deceased person's
//               event in their first 60 years;
//   possible  — the intervals merely overlap (the dates don't settle it).
// The age keeps the birth's qualifier: ABT → "about 12", BEF → "at least
// 12", AFT → "no more than 12", BET → "between 10 and 12".
//
// PLACE RELEVANCE is read from the person's own places (birth, dated
// residences, death) — see `PlaceRelevance`. A regional event that touched
// none of their places is not a line about them.
//
// RANKING: interest weight first, then how surely and how closely it
// touched them, then the "story" bonuses (born during a famine, of service
// age in a war, a child during it). The top `maxLines` survive, at most two
// per kind, and an event inside a chosen one of the same kind (Pearl Harbor
// inside WWII) only survives on its own regional merit. Output is in date
// order.
//
// Pure value code. C++ readers: `struct` = value type (copied like a POD);
// `Optional<Int>` = std::optional<int>; `guard … else { return }` = an early
// return after a failed precondition.

import Foundation

extension LifeAndTimes {

    // MARK: - Dates

    /// The qualifier a GEDCOM date carried, Codable for decorations.
    public enum DateQualifier: String, Sendable, Codable, Equatable {
        case exact, before, after, about, between, unknown

        init(_ q: GedcomYearInterval.Qualifier) {
            switch q {
            case .exact: self = .exact
            case .before: self = .before
            case .after: self = .after
            case .about, .calculated, .estimated: self = .about
            case .between, .range: self = .between
            }
        }
    }

    /// A year with its proof interval. `lower`/`upper` nil = unbounded.
    public struct DatedYear: Sendable, Codable, Equatable {
        public let lower: Int?
        public let upper: Int?
        public let anchor: Int?
        public let qualifier: DateQualifier
        /// The raw GEDCOM text, verbatim.
        public let raw: String?

        public init(lower: Int?, upper: Int?, anchor: Int?, qualifier: DateQualifier, raw: String? = nil) {
            self.lower = lower
            self.upper = upper
            self.anchor = anchor
            self.qualifier = qualifier
            self.raw = raw
        }

        public static func exact(_ y: Int) -> DatedYear {
            DatedYear(lower: y, upper: y, anchor: y, qualifier: .exact, raw: "\(y)")
        }

        /// Nil when the raw text carries no year.
        public static func parse(_ raw: String?) -> DatedYear? {
            guard let raw, let i = GedcomYearInterval.parse(raw) else { return nil }
            return DatedYear(lower: i.lower, upper: i.upper, anchor: i.anchor,
                             qualifier: DateQualifier(i.qualifier), raw: raw)
        }

        /// "1833", "about 1833", "before 1840" — GedcomYearInterval's words.
        public var spoken: String {
            switch qualifier {
            case .exact: return anchor.map(String.init) ?? "an unknown year"
            case .about: return "about \(anchor ?? lower ?? 0)"
            case .before: return "before \(anchor ?? upper ?? 0)"
            case .after: return "after \(anchor ?? lower ?? 0)"
            case .between:
                switch (lower, upper) {
                case let (l?, u?): return l == u ? "\(l)" : "between \(l) and \(u)"
                case let (l?, nil): return "\(l) or later"
                case let (nil, u?): return "\(u) or earlier"
                default: return "an unknown year"
                }
            case .unknown: return "an unknown year"
            }
        }
    }

    /// An age that keeps its date's uncertainty.
    public struct QualifiedAge: Sendable, Codable, Equatable {
        public enum Kind: String, Sendable, Codable, Equatable {
            /// The birth year is exact; the age is year arithmetic (a birthday
            /// later in the year makes the true age one less — genealogical
            /// convention speaks the year difference).
            case exact
            case about
            case atLeast
            case atMost
            case between
        }
        public let kind: Kind
        /// The number a sentence speaks (for `between`, the low end).
        public let nominal: Int
        /// Proven bounds (nil = unbounded on that side), clamped at 0.
        public let low: Int?
        public let high: Int?

        public init(kind: Kind, nominal: Int, low: Int?, high: Int?) {
            self.kind = kind
            self.nominal = nominal
            self.low = low
            self.high = high
        }

        /// "12", "about 12", "at least 12", "no more than 12", "between 10 and 12".
        public var spoken: String {
            switch kind {
            case .exact: return "\(nominal)"
            case .about: return "about \(nominal)"
            case .atLeast: return "at least \(nominal)"
            case .atMost: return "no more than \(nominal)"
            case .between:
                if let l = low, let h = high, l != h { return "between \(l) and \(h)" }
                return "\(nominal)"
            }
        }

        /// The age in `year` for someone born `birth`; nil when they are
        /// PROVEN not yet born (the whole interval is after `year`).
        public static func at(_ year: Int, birth: DatedYear) -> QualifiedAge? {
            if let lo = birth.lower, lo > year { return nil }
            let low = birth.upper.map { max(0, year - $0) }
            let high = birth.lower.map { max(0, year - $0) }
            switch birth.qualifier {
            case .exact:
                guard let y = birth.anchor else { return nil }
                return QualifiedAge(kind: .exact, nominal: max(0, year - y), low: low, high: high)
            case .about:
                guard let y = birth.anchor else { return nil }
                return QualifiedAge(kind: .about, nominal: max(0, year - y), low: low, high: high)
            case .before:
                guard let l = low else { return nil }
                return QualifiedAge(kind: .atLeast, nominal: l, low: l, high: nil)
            case .after:
                guard let h = high else { return nil }
                return QualifiedAge(kind: .atMost, nominal: h, low: nil, high: h)
            case .between:
                switch (low, high) {
                case let (l?, h?): return QualifiedAge(kind: l == h ? .exact : .between, nominal: l, low: l, high: h)
                case let (l?, nil): return QualifiedAge(kind: .atLeast, nominal: l, low: l, high: nil)
                case let (nil, h?): return QualifiedAge(kind: .atMost, nominal: h, low: nil, high: h)
                default: return nil
                }
            case .unknown:
                return nil
            }
        }
    }

    // MARK: - Lifespan

    /// Birth and death as proof intervals, plus the bounds the overlap
    /// tests use. A missing death is NOT "still alive" — only a deceased or
    /// presumed-deceased person reaches here (the living are skipped first).
    public struct Lifespan: Sendable, Codable, Equatable {
        public let birth: DatedYear
        /// Nil when no death year is recorded.
        public let death: DatedYear?
        /// True when the record has a death (with or without a year).
        public let deathRecorded: Bool

        /// Longest life the "possible" bound allows when no death year.
        public static let maxLifespan = 105

        public init(birth: DatedYear, death: DatedYear?, deathRecorded: Bool) {
            self.birth = birth
            self.death = death
            self.deathRecorded = deathRecorded || death != nil
        }

        /// Earliest possible birth year.
        var birthLow: Int { birth.lower ?? (death?.lower.map { $0 - Self.maxLifespan } ?? ((birth.upper ?? 0) - 50)) }
        /// Latest possible birth year.
        var birthHigh: Int { birth.upper ?? death?.upper ?? ((birth.lower ?? 0) + 50) }
        /// Earliest PROVEN death year; nil = no proof of being alive past birth.
        var deathLow: Int? { death?.lower }
        /// Latest possible death year.
        var deathHigh: Int { death?.upper ?? (birthHigh + Self.maxLifespan) }
    }

    // MARK: - Place relevance

    public enum PlaceSource: String, Sendable, Codable, Equatable {
        case birth, residence, death, military
    }

    /// One place the person is recorded in.
    public struct Presence: Sendable, Codable, Equatable {
        public let region: Region
        public let source: PlaceSource
        /// For residences/military facts with a date; nil otherwise.
        public let year: Int?
        public let place: String

        public init(region: Region, source: PlaceSource, year: Int?, place: String) {
            self.region = region
            self.source = source
            self.year = year
            self.place = place
        }
    }

    /// How the event touched the person's places.
    public enum PlaceRelevance: String, Sendable, Codable, Comparable, CaseIterable {
        /// A worldwide event; no regional tie needed.
        case world
        /// One of their places is in scope but the timing is not shown.
        case maybe
        /// Born there and a child at the time, or died there not long after.
        case likely
        /// A dated residence there at the time, or born AND died there.
        case lived

        // A switch, not allCases.firstIndex: this runs ~10^7 times at scale
        // and allCases builds an array on every call.
        var rank: Int {
            switch self {
            case .world: return 0
            case .maybe: return 1
            case .likely: return 2
            case .lived: return 3
            }
        }
        public static func < (a: PlaceRelevance, b: PlaceRelevance) -> Bool { a.rank < b.rank }
    }

    public enum Certainty: String, Sendable, Codable, Comparable, CaseIterable {
        case possible, likely, certain
        var rank: Int {
            switch self {
            case .possible: return 0
            case .likely: return 1
            case .certain: return 2
            }
        }
        public static func < (a: Certainty, b: Certainty) -> Bool { a.rank < b.rank }
    }

    public enum LifeMoment: String, Sendable, Codable, Equatable {
        /// Born within the event's years.
        case bornDuring
        /// Died within the event's years.
        case diedDuring
        /// Alive before it began and after it ended (proven).
        case livedThrough
        /// Alive for part of it.
        case aliveDuring
    }

    /// One "lived through" line.
    public struct LivedThroughLine: Sendable, Codable, Equatable {
        public let eventID: String
        public let eventName: String
        public let eventPhrase: String
        public let years: String
        public let kind: EventKind
        public let moment: LifeMoment
        public let certainty: Certainty
        public let relevance: PlaceRelevance
        /// Age when the event began (nil when born during it).
        public let ageAtStart: QualifiedAge?
        /// Age when a multi-year event ended (nil for one-year events, or
        /// when they died during it).
        public let ageAtEnd: QualifiedAge?
        /// Why the place counts: "born in Ireland", "lived in England in 1915".
        public let placeReason: String?
        /// Ranking score (higher = more interesting). Stored for audit.
        public let score: Int

        /// The predicate, without the subject: "was about 12 when the Great
        /// Famine in Ireland began (1845–1852)". Hallie prefixes the name.
        public var spoken: String {
            let single = !years.contains("–")
            switch moment {
            case .bornDuring:
                return "was born during \(eventPhrase) (\(years))"
            case .diedDuring:
                // Never implies a cause: "died while", not "died of".
                return single
                    ? "died in the year of \(eventPhrase) (\(years))"
                    : "died while \(eventPhrase) was under way (\(years))"
            case .livedThrough, .aliveDuring:
                guard let age = ageAtStart else { return "lived through \(eventPhrase) (\(years))" }
                if certainty == .possible {
                    return single
                        ? "would have been \(age.spoken) at the time of \(eventPhrase) (\(years)), if still living"
                        : "would have been \(age.spoken) when \(eventPhrase) began (\(years)), if still living"
                }
                return single
                    ? "was \(age.spoken) at the time of \(eventPhrase) (\(years))"
                    : "was \(age.spoken) when \(eventPhrase) began (\(years))"
            }
        }

        /// "Seamus Testperson was about 12 when …" (+ place reason).
        public func sentence(subject: String) -> String {
            var s = "\(subject) \(spoken)"
            if let placeReason, relevance >= .likely { s += " — \(placeReason)" }
            return s + "."
        }
    }

    // MARK: - Computation

    /// Every event the person was possibly alive for, scored, unranked.
    static func allLines(lifespan: Lifespan, presences: [Presence], sex: String,
                         timeline: [HistoricalEvent]) -> [LivedThroughLine] {
        var out: [LivedThroughLine] = []
        out.reserveCapacity(16)
        let anchors = PresenceAnchors(presences)
        for event in timeline {
            if let line = line(for: event, lifespan: lifespan, presences: presences, anchors: anchors, sex: sex) {
                out.append(line)
            }
        }
        return out
    }

    /// Birth / death regions, looked up once per person, not per event.
    struct PresenceAnchors {
        let birth: Region?
        let death: Region?
        init(_ presences: [Presence]) {
            birth = presences.first { $0.source == .birth }?.region
            death = presences.first { $0.source == .death }?.region
        }
    }

    static func line(for event: HistoricalEvent, lifespan: Lifespan, presences: [Presence],
                     anchors: PresenceAnchors? = nil, sex: String) -> LivedThroughLine? {
        let s = event.startYear, e = event.endYear
        let bLo = lifespan.birthLow, bHi = lifespan.birthHigh
        let dHi = lifespan.deathHigh
        // Possible overlap at all?
        guard max(s, bLo) <= min(e, dHi) else { return nil }

        // Born/died "during" only on REAL bounds, never the fallbacks.
        var bornDuring = false
        if let bl = lifespan.birth.lower, let bu = lifespan.birth.upper { bornDuring = bl >= s && bu <= e }
        var diedDuring = false
        if let d = lifespan.death, let dl = d.lower, let du = d.upper { diedDuring = dl >= s && du <= e }

        var certainty: Certainty = .possible
        if let dLo = lifespan.deathLow, lifespan.birth.upper != nil {
            if max(s, bHi + 1) <= min(e, dLo - 1) { certainty = .certain }
            else if bornDuring || diedDuring { certainty = .likely }
        } else if lifespan.birth.upper != nil {
            // No proven death year (presumed deceased, "Deceased", or
            // "BEF 1900"): alive past birth is not proven, but an event
            // early in life is likely (and never past a recorded bound).
            if bornDuring { certainty = .likely }
            else if bHi < s, s - bHi <= 60, s <= dHi { certainty = .likely }
        }

        let moment: LifeMoment
        if bornDuring { moment = .bornDuring }
        else if diedDuring { moment = .diedDuring }
        else if let dLo = lifespan.deathLow, bHi < s, dLo > e { moment = .livedThrough }
        else { moment = .aliveDuring }

        let ageAtStart = bornDuring ? nil : QualifiedAge.at(s, birth: lifespan.birth)
        let ageAtEnd: QualifiedAge? = (event.isSingleYear || diedDuring) ? nil : QualifiedAge.at(e, birth: lifespan.birth)

        guard let (relevance, reason) = placeRelevance(of: event, presences: presences,
                                                       anchors: anchors ?? PresenceAnchors(presences),
                                                       lifespan: lifespan, ageAtStart: ageAtStart) else {
            return nil
        }

        let score = Self.score(event: event, certainty: certainty, relevance: relevance, moment: moment,
                               ageAtStart: ageAtStart, ageAtEnd: ageAtEnd, sex: sex)
        return LivedThroughLine(eventID: event.id, eventName: event.name, eventPhrase: event.phrase,
                                years: event.yearsLabel, kind: event.kind, moment: moment,
                                certainty: certainty, relevance: relevance, ageAtStart: ageAtStart,
                                ageAtEnd: ageAtEnd, placeReason: reason, score: score)
    }

    /// Nil when a regional event touched none of the person's places.
    static func placeRelevance(of event: HistoricalEvent, presences: [Presence], anchors: PresenceAnchors,
                               lifespan: Lifespan, ageAtStart: QualifiedAge?) -> (PlaceRelevance, String?)? {
        // World scope: every presence "touches", so a regional reason would
        // be noise ("born in Ireland" for the moon landing).
        if event.isWorldwide { return (.world, nil) }
        var best: (PlaceRelevance, String?)?
        func consider(_ r: PlaceRelevance, _ why: String?) {
            if best == nil || r > best!.0 { best = (r, why) }
        }
        let birthRegion = anchors.birth
        let deathRegion = anchors.death
        for p in presences where event.touches(p.region) {
            switch p.source {
            case .residence, .military:
                if let y = p.year, y >= event.startYear - 10, y <= event.endYear + 10 {
                    consider(.lived, "\(p.source == .military ? "served" : "lived") in \(p.region.label) in \(y)")
                } else {
                    consider(.maybe, "lived in \(p.region.label)")
                }
            case .birth:
                if deathRegion == nil || deathRegion == p.region {
                    consider(deathRegion == nil ? .likely : .lived, "born in \(p.region.label)")
                } else if let age = ageAtStart, (age.high ?? age.nominal) <= 15 {
                    consider(.likely, "born in \(p.region.label)")
                } else if ageAtStart == nil {
                    consider(.likely, "born in \(p.region.label)")   // born during it
                } else {
                    consider(.maybe, "born in \(p.region.label)")
                }
            case .death:
                if birthRegion == p.region {
                    consider(.lived, "born and died in \(p.region.label)")
                } else if let dLo = lifespan.deathLow, event.startYear >= dLo - 30 {
                    consider(.likely, "died in \(p.region.label)")
                } else {
                    consider(.maybe, "died in \(p.region.label)")
                }
            }
        }
        return best
    }

    static func score(event: HistoricalEvent, certainty: Certainty, relevance: PlaceRelevance,
                      moment: LifeMoment, ageAtStart: QualifiedAge?, ageAtEnd: QualifiedAge?,
                      sex: String) -> Int {
        var score = event.weight * 10
        switch relevance {
        case .lived: score += 25
        case .likely: score += 18
        case .maybe: score += 8
        case .world: score += 6
        }
        switch certainty {
        case .certain: score += 10
        case .likely: score += 6
        case .possible: score -= 8
        }
        let hard: Set<EventKind> = [.war, .famine, .epidemic, .disaster]
        // A long era (an emigration wave, a reign) is background: being
        // born or dying "during" it is not a story.
        let era = event.endYear - event.startYear > 20
        switch moment {
        case .bornDuring where !era: score += hard.contains(event.kind) ? 10 : 6
        case .diedDuring where !era: score += hard.contains(event.kind) ? 12 : 4
        default: break
        }
        if let age = ageAtStart {
            let a = age.nominal
            if (5...30).contains(a) { score += 6 }      // remembered it / lived it as a young person
            if a > 80 { score -= 6 }
            if event.kind == .war, sex.uppercased() == "M" {
                let hi = (ageAtEnd ?? age).high ?? (ageAtEnd ?? age).nominal
                let lo = age.low ?? age.nominal
                if lo <= 45, hi >= 18 { score += 12 }  // of fighting age during it
            }
        }
        if era { score -= 15 }  // background, not an event
        return score
    }

    /// The handful of best lines, in date order.
    static func ranked(_ lines: [LivedThroughLine], maxLines: Int, timeline: [String: HistoricalEvent]) -> [LivedThroughLine] {
        let sorted = lines.sorted { a, b in
            a.score != b.score ? a.score > b.score : a.eventID < b.eventID
        }
        var chosen: [LivedThroughLine] = []
        var perKind: [EventKind: Int] = [:]
        for line in sorted where chosen.count < maxLines {
            if perKind[line.kind, default: 0] >= 2 { continue }
            if let ev = timeline[line.eventID] {
                // One line per event family (the Famine OR its emigration;
                // the Civil War OR Lincoln) — unless this is a regional
                // episode of a WORLD event that touched their own place.
                func regionalEpisode(_ e: HistoricalEvent, _ l: LivedThroughLine) -> Bool {
                    e.partOf != nil && !e.isWorldwide && l.relevance >= .likely
                }
                let sameFamily = chosen.contains { c in
                    guard let cev = timeline[c.eventID], cev.family == ev.family else { return false }
                    // The one pair allowed: the world parent + a regional
                    // episode that touched them (WWII + the Blitz), either order.
                    let worldPlusEpisode =
                        (cev.isWorldwide && cev.partOf == nil && regionalEpisode(ev, line))
                        || (ev.isWorldwide && ev.partOf == nil && regionalEpisode(cev, c))
                    return !worldPlusEpisode
                }
                if sameFamily { continue }
                let nested = chosen.contains { c in
                    guard c.kind == line.kind, let cev = timeline[c.eventID], cev.id != ev.id else { return false }
                    let inside = cev.startYear <= ev.startYear && cev.endYear >= ev.endYear
                    // A regional event inside a WORLD one stands on its own
                    // regional merit (the Blitz for a Londoner).
                    let ownMerit = cev.isWorldwide && !ev.isWorldwide && line.relevance >= .likely
                    return inside && !ownMerit
                }
                if nested { continue }
            }
            chosen.append(line)
            perKind[line.kind, default: 0] += 1
        }
        return chosen.sorted { a, b in
            let ea = timeline[a.eventID]?.startYear ?? 0, eb = timeline[b.eventID]?.startYear ?? 0
            return ea != eb ? ea < eb : a.eventID < b.eventID
        }
    }
}
