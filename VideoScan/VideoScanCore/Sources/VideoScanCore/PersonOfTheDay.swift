// PersonOfTheDay.swift (VideoScanCore)
// PERSON OF THE DAY (Rick 2026-10-01): one person from the family tree,
// featured on the Family Tree tab — and, later, Hallie's opener ("Today's
// person is …"). Pure logic: no I/O, no clock, no UserDefaults. The caller
// hands in the candidates, the day, the recent-picks history and a lazy
// life-status rule; the answer is a pure function of those.
//
// THE PICK, in order — a lexicographic score, highest wins:
//   1. tier: an anniversary TODAY ("on this day": a day-precise birth,
//      death or marriage date whose month and day are today's) › a person
//      the family has a portrait of or notes about › everyone else;
//   2. documented deceased (a recorded death, or born 100+ years ago) —
//      Rick: "deceased ancestors are preferred";
//   3. a direct ancestor of either home person (line ≠ none);
//   4. a portrait or family notes (the tie-break inside the anniversary
//      tier — a face makes a better card);
//   5. today's side: Rick's line on even days, Donna's on odd days, so the
//      two sides alternate over a week ("draw from both sides");
//   6. a hash of (day, person) — the deterministic shuffle.
// Then ROTATION: anyone picked in the last `rotationDays` days is skipped,
// unless that would leave nobody (a tiny tree), when rotation is waived.
//
// STABLE ACROSS RELAUNCHES THE SAME DAY: the history records today's pick;
// asked again today, the recorded person is returned (if still in the tree
// and still allowed) — so a tree refresh at noon does not swap the card.
//
// PRIVACY (Rick: "never feature living people beyond the inner circle in
// any way that exposes private details"): `life` classifies a candidate,
// lazily, best-ranked first:
//   • deceased            → featured normally;
//   • livingInnerCircle   → featured ONLY on their own birthday, and then
//                           with no years, no birthplace, no age ("Birthday
//                           today");
//   • livingPrivate       → never featured.
// The lazy call matters: the app's full rule (LifeStatus) walks
// descendants, so it is asked about the handful at the top of the ranking,
// not all 39k people.
//
// DETERMINISM: no `hashValue` anywhere — Swift's Hasher is seeded per
// process (≈ a randomised std::hash), which would change the pick on every
// relaunch. The shuffle is FNV-1a + a splitmix finaliser over the bytes of
// "yyyy-mm-dd|id", identical on every run and machine.
//
// COST: O(n) to score + one sort of n UInt64 keys (score and index packed
// into one word, so the sort compares integers, not structs). The candidate
// dates are parsed once, in `Candidate.init`. Memory: one 8-byte key per
// candidate (800 KB at 100k), released on return.
//
// (C++ readers: `enum PersonOfTheDay` with no cases is a namespace; the
// structs are plain values.)

import Foundation

public enum PersonOfTheDay {

    // MARK: - The day

    /// A calendar day as (year, month, day) — the unit the whole feature
    /// keys on. Built from a `Date` in the caller's calendar (injectable,
    /// so a test pins the time zone), or parsed from its "yyyy-mm-dd" key.
    public struct Day: Sendable, Hashable, Comparable {
        public let year: Int
        public let month: Int
        public let day: Int

        public init?(year: Int, month: Int, day: Int) {
            guard (1...12).contains(month), day >= 1, day <= Self.daysIn(month: month, year: year) else { return nil }
            self.year = year
            self.month = month
            self.day = day
        }

        public init(date: Date, calendar: Calendar) {
            let c = calendar.dateComponents([.year, .month, .day], from: date)
            year = c.year ?? 1970
            month = c.month ?? 1
            day = c.day ?? 1
        }

        /// Strict "yyyy-mm-dd"; nil for anything else (a poisoned history
        /// line must not become a day).
        public init?(key: String) {
            let parts = key.split(separator: "-", omittingEmptySubsequences: false)
            guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
                  parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
                  let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]) else { return nil }
            self.init(year: y, month: m, day: d)
        }

        public var key: String { String(format: "%04d-%02d-%02d", year, month, day) }

        /// Days since 1970-01-01 in the proleptic Gregorian calendar
        /// (Howard Hinnant's days_from_civil) — pure integer arithmetic,
        /// so "N days ago" never depends on a time zone or DST.
        public var ordinal: Int {
            let y = month <= 2 ? year - 1 : year
            let era = (y >= 0 ? y : y - 399) / 400
            let yoe = y - era * 400
            let mp = (month + 9) % 12
            let doy = (153 * mp + 2) / 5 + day - 1
            let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
            return era * 146_097 + doe - 719_468
        }

        public static func isLeap(_ year: Int) -> Bool {
            (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
        }

        static func daysIn(month: Int, year: Int) -> Int {
            switch month {
            case 2: return isLeap(year) ? 29 : 28
            case 4, 6, 9, 11: return 30
            default: return 31
            }
        }

        public static func < (a: Day, b: Day) -> Bool { a.ordinal < b.ordinal }

        /// Does an event on (month, day) fall on this day's anniversary? A
        /// 29 February event is remembered on 28 February in a common year.
        func isAnniversary(month m: Int, day d: Int) -> Bool {
            if m == month && d == day { return true }
            return m == 2 && d == 29 && month == 2 && day == 28 && !Self.isLeap(year)
        }
    }

    // MARK: - Candidates

    public enum EventKind: String, Sendable, Codable, Equatable {
        case birth, death, marriage
    }

    /// One day-precise dated event of a candidate.
    struct Event: Sendable, Equatable {
        let kind: EventKind
        let year: Int
        let month: Int
        let day: Int
    }

    /// One person who could be featured. The caller fills in the facts and
    /// the signals; the dates are parsed here, once.
    public struct Candidate: Sendable, Equatable {
        public let id: String
        public let name: String
        /// "M" / "F" / "" — for "her" / "him" in a line.
        public let sex: String
        /// Raw GEDCOM dates and places, as recorded.
        public let birthDate: String?
        public let deathDate: String?
        public let birthPlace: String?
        public let deathPlace: String?
        public let marriageDates: [String]
        /// Which home person this is an ancestor of (the walk's line).
        public let line: TreeWalk.Line
        /// Generations above the nearer home person (nil = not an ancestor).
        public let generation: Int?
        /// "Rick's great-grandmother" — composed by the caller (it knows the
        /// home people's names); nil when not an ancestor.
        public let relation: String?
        /// The family has a portrait of them (a hint — the card still falls
        /// back to the birth flag if the photo cannot be read).
        public let hasPortrait: Bool
        /// Family notes (CyberBrain items) about them, visible to the family.
        public let storyCount: Int
        /// One of the people the family has said may be featured while
        /// living (the home people, their spouses and children).
        public let isInnerCircle: Bool

        let events: [Event]
        let birthYear: Int?
        let hasRecordedDeath: Bool

        public init(id: String, name: String, sex: String = "", birthDate: String? = nil,
                    deathDate: String? = nil, birthPlace: String? = nil, deathPlace: String? = nil,
                    marriageDates: [String] = [], line: TreeWalk.Line = .none, generation: Int? = nil,
                    relation: String? = nil, hasPortrait: Bool = false, storyCount: Int = 0,
                    isInnerCircle: Bool = false) {
            self.id = id
            self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            self.sex = sex
            self.birthDate = birthDate
            self.deathDate = deathDate
            self.birthPlace = birthPlace
            self.deathPlace = deathPlace
            self.marriageDates = marriageDates
            self.line = line
            self.generation = generation
            self.relation = relation
            self.hasPortrait = hasPortrait
            self.storyCount = max(0, storyCount)
            self.isInnerCircle = isInnerCircle
            var events: [Event] = []
            func add(_ raw: String?, _ kind: EventKind) {
                guard let e = Self.dayPrecise(raw, kind) else { return }
                events.append(e)
            }
            add(birthDate, .birth)
            add(deathDate, .death)
            for m in marriageDates { add(m, .marriage) }
            self.events = events
            self.birthYear = GedcomFamilyGraph.year(in: birthDate)
            self.hasRecordedDeath = !(deathDate?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        }

        /// A date that names its day ("4 MAR 1812"); qualified dates
        /// ("ABT 1812", "BEF 4 MAR 1812") never make an anniversary.
        static func dayPrecise(_ raw: String?, _ kind: EventKind) -> Event? {
            guard let raw, let d = TreeWalkDate.parse(raw), d.precision == .day,
                  let day = d.day, let lower = d.lowerMonth else { return nil }
            let month = lower - d.year * 12 + 1
            guard (1...12).contains(month) else { return nil }
            return Event(kind: kind, year: d.year, month: month, day: day)
        }

        /// A name worth printing: at least one letter, and not a GEDCOM
        /// placeholder ("?", "Unknown").
        var hasDisplayName: Bool {
            guard name.contains(where: \.isLetter) else { return false }
            let folded = name.lowercased()
            return folded != "unknown" && folded != "unknown unknown"
        }

        public static func == (a: Candidate, b: Candidate) -> Bool {
            a.id == b.id && a.name == b.name && a.sex == b.sex && a.birthDate == b.birthDate
                && a.deathDate == b.deathDate && a.birthPlace == b.birthPlace && a.deathPlace == b.deathPlace
                && a.marriageDates == b.marriageDates && a.line == b.line && a.generation == b.generation
                && a.relation == b.relation && a.hasPortrait == b.hasPortrait && a.storyCount == b.storyCount
                && a.isInnerCircle == b.isInnerCircle
        }
    }

    // MARK: - Life (privacy)

    /// How a candidate may be shown — see the header.
    public enum Life: String, Sendable, Equatable {
        case deceased
        case livingInnerCircle
        case livingPrivate
    }

    /// The cheap rule over the candidate's own dates: a recorded death or a
    /// birth 100+ years ago is deceased; otherwise living (inner circle or
    /// private). The app wraps this with its full LifeStatus rule for the
    /// people the dates do not settle.
    public static func lifeFromDates(_ c: Candidate, today: Day) -> Life {
        if isDocumentedDeceased(c, today: today) { return .deceased }
        return c.isInnerCircle ? .livingInnerCircle : .livingPrivate
    }

    static func isDocumentedDeceased(_ c: Candidate, today: Day) -> Bool {
        if c.hasRecordedDeath { return true }
        if let b = c.birthYear, b <= today.year - 100 { return true }
        return false
    }

    // MARK: - The pick

    public enum Reason: Sendable, Equatable {
        case bornOnThisDay(yearsAgo: Int)
        case diedOnThisDay(yearsAgo: Int)
        case marriedOnThisDay(yearsAgo: Int)
        /// A living inner-circle person on their birthday (no age shown).
        case birthday
        case portraitAndStory
        case portrait
        case story
        case rotation

        public var isOnThisDay: Bool {
            switch self {
            case .bornOnThisDay, .diedOnThisDay, .marriedOnThisDay, .birthday: return true
            default: return false
            }
        }
    }

    /// What the card (and Hallie) shows. Private details are already
    /// removed for a living person: `years` and `birthPlace` are nil.
    public struct Pick: Sendable, Equatable {
        public let personID: String
        public let name: String
        public let sex: String
        public let years: String?
        public let birthPlace: String?
        public let relation: String?
        public let line: TreeWalk.Line
        public let reason: Reason
        /// One line: "Born 212 years ago today in Cork, Ireland".
        public let whyToday: String
        public let day: Day
        public let isLiving: Bool
    }

    public struct Options: Sendable, Equatable {
        /// Nobody is featured twice within this many days (unless the tree
        /// is too small to rotate).
        public var rotationDays: Int
        /// The history keeps at most this many days.
        public var historyLimit: Int

        public init(rotationDays: Int = 90, historyLimit: Int = 400) {
            self.rotationDays = max(0, rotationDays)
            self.historyLimit = max(1, historyLimit)
        }
    }

    /// Today's person, or nil when no candidate may be shown. `life` is
    /// called lazily, best-ranked first (see the header).
    public static func pick(from candidates: [Candidate], on today: Day, history: History,
                            options: Options = Options(),
                            life: (Candidate) -> Life) -> Pick? {
        guard !candidates.isEmpty, candidates.count < (1 << indexBits) else { return nil }
        // Stability: today's recorded person wins while still allowed.
        if let recorded = history.entry(on: today),
           let c = candidates.first(where: { $0.id == recorded.personID }),
           let p = feature(c, today: today, life: life(c)) {
            return p
        }
        let recent = history.recentIDs(before: today, withinDays: options.rotationDays)
        if let p = ranked(candidates, today: today, excluding: recent, life: life) { return p }
        // Everyone allowed was featured recently (a tiny tree): rotation is
        // waived rather than showing nothing.
        return recent.isEmpty ? nil : ranked(candidates, today: today, excluding: [], life: life)
    }

    /// The opener Hallie can say: "Today's person is Mary Example
    /// (1812–1880), Rick's 3rd-great-grandmother. Born 214 years ago today
    /// in Cork, Ireland."
    public static func opener(for pick: Pick) -> String {
        if pick.isLiving { return "Today's person is \(pick.name) — it's their birthday today!" }
        var s = "Today's person is \(pick.name)"
        if let years = pick.years { s += " (\(years))" }
        if let relation = pick.relation { s += ", \(relation)" }
        s += ". " + pick.whyToday
        if !s.hasSuffix(".") { s += "." }
        return s
    }

    // MARK: - Ranking

    static let indexBits: UInt64 = 24

    /// The packed key: tier(2) · documented-deceased(1) · ancestor(1) ·
    /// media(1) · today's-side(1) · shuffle(34) · index(24). Sorting the
    /// UInt64s descending IS the lexicographic ranking.
    static func ranked(_ candidates: [Candidate], today: Day, excluding recent: Set<String>,
                       life: (Candidate) -> Life) -> Pick? {
        let preferredSide: TreeWalk.Line = today.ordinal % 2 == 0 ? .first : .second
        let dayBytes = Array((today.key + "|").utf8)
        var keys: [UInt64] = []
        keys.reserveCapacity(candidates.count)
        for (i, c) in candidates.enumerated() {
            guard c.hasDisplayName, !recent.contains(c.id) else { continue }
            let tier: UInt64 = anniversary(of: c, on: today) != nil ? 3 : (c.hasPortrait || c.storyCount > 0 ? 2 : 1)
            let deceased: UInt64 = isDocumentedDeceased(c, today: today) ? 1 : 0
            let ancestor: UInt64 = c.line == .none ? 0 : 1
            let media: UInt64 = c.hasPortrait || c.storyCount > 0 ? 1 : 0
            let side: UInt64 = (c.line == preferredSide || c.line == .both) ? 1 : 0
            let shuffle = stableHash(dayBytes, c.id) >> 30          // 34 bits
            let key = tier << 62 | deceased << 61 | ancestor << 60 | media << 59 | side << 58
                | shuffle << indexBits | UInt64(i)
            keys.append(key)
        }
        keys.sort(by: >)
        let mask: UInt64 = (1 << indexBits) - 1
        for key in keys {
            let c = candidates[Int(key & mask)]
            if let p = feature(c, today: today, life: life(c)) { return p }
        }
        return nil
    }

    /// Today's best anniversary for a candidate: birth › death › marriage,
    /// at least one year ago.
    static func anniversary(of c: Candidate, on today: Day) -> Event? {
        var best: Event?
        for e in c.events where e.year < today.year && today.isAnniversary(month: e.month, day: e.day) {
            if rank(e.kind) < (best.map { rank($0.kind) } ?? Int.max) { best = e }
        }
        return best
    }

    private static func rank(_ k: EventKind) -> Int {
        switch k {
        case .birth: return 0
        case .death: return 1
        case .marriage: return 2
        }
    }

    /// The card for a candidate, or nil when privacy forbids it.
    static func feature(_ c: Candidate, today: Day, life: Life) -> Pick? {
        guard c.hasDisplayName else { return nil }
        switch life {
        case .livingPrivate:
            return nil
        case .livingInnerCircle:
            // Their own birthday only, and nothing private on the card.
            guard let e = anniversary(of: c, on: today), e.kind == .birth else { return nil }
            return Pick(personID: c.id, name: c.name, sex: c.sex, years: nil, birthPlace: nil,
                        relation: nil, line: c.line, reason: .birthday, whyToday: "Birthday today",
                        day: today, isLiving: true)
        case .deceased:
            let reason: Reason
            if let e = anniversary(of: c, on: today) {
                let ago = today.year - e.year
                switch e.kind {
                case .birth: reason = .bornOnThisDay(yearsAgo: ago)
                case .death: reason = .diedOnThisDay(yearsAgo: ago)
                case .marriage: reason = .marriedOnThisDay(yearsAgo: ago)
                }
            } else if c.hasPortrait && c.storyCount > 0 {
                reason = .portraitAndStory
            } else if c.hasPortrait {
                reason = .portrait
            } else if c.storyCount > 0 {
                reason = .story
            } else {
                reason = .rotation
            }
            let place = clean(c.birthPlace)
            return Pick(personID: c.id, name: c.name, sex: c.sex,
                        years: GedcomFamilyGraph.lifeYearsLabel(birth: c.birthDate, death: c.deathDate),
                        birthPlace: place, relation: c.relation, line: c.line, reason: reason,
                        whyToday: whyToday(reason, candidate: c), day: today, isLiving: false)
        }
    }

    /// The one "why today" line.
    static func whyToday(_ reason: Reason, candidate c: Candidate) -> String {
        func ago(_ n: Int) -> String { "\(n.formatted()) year\(n == 1 ? "" : "s") ago today" }
        let pronoun: String
        switch c.sex.uppercased() {
        case "F": pronoun = "her"
        case "M": pronoun = "him"
        default: pronoun = "them"
        }
        switch reason {
        case .bornOnThisDay(let n):
            return "Born \(ago(n))" + (shortPlace(c.birthPlace).map { " in \($0)" } ?? "")
        case .diedOnThisDay(let n):
            return "Died \(ago(n))" + (shortPlace(c.deathPlace).map { " in \($0)" } ?? "")
        case .marriedOnThisDay(let n):
            return "Married \(ago(n))"
        case .birthday:
            return "Birthday today"
        case .portraitAndStory:
            return "A face and a story in the family archive"
        case .portrait:
            return "From the family's photographs"
        case .story:
            return c.storyCount == 1 ? "The family's notes mention \(pronoun)"
                                     : "The family's notes remember \(pronoun)"
        case .rotation:
            if let year = c.birthYear {
                return "Born in \(year)" + (shortPlace(c.birthPlace).map { " in \($0)" } ?? "")
            }
            return "Today's turn from the family tree"
        }
    }

    static func clean(_ place: String?) -> String? {
        guard let t = place?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    /// "Cork, County Cork, Ireland" → "Cork, Ireland"; "Sudbury, Middlesex,
    /// Massachusetts, United States" → "Sudbury, Massachusetts": the town
    /// and the most telling larger place, so the line stays one line.
    public static func shortPlace(_ place: String?) -> String? {
        guard let place = clean(place) else { return nil }
        let parts = place.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 2 else { return parts.joined(separator: ", ") }
        let usa: Set<String> = ["united states", "usa", "united states of america", "us"]
        let last = usa.contains(parts[parts.count - 1].lowercased()) ? parts[parts.count - 2] : parts[parts.count - 1]
        return parts[0] == last ? parts[0] : "\(parts[0]), \(last)"
    }

    /// FNV-1a over `prefix` + the id, then splitmix64's finaliser so close
    /// ids spread. Stable across processes and machines (unlike Hasher).
    static func stableHash(_ prefix: [UInt8], _ id: String) -> UInt64 {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in prefix { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        for b in id.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
        h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
        return h ^ (h >> 31)
    }
}
