// BirthplaceUnitResolver.swift (VideoScanCore/FamilyMap)
// A recorded birthplace → the map unit it shades (GH #227). "Sheffield,
// West Riding, Yorkshire, England" → eng-yorkshire; "Boston, Suffolk,
// Massachusetts Bay Colony, British Colonial America" → usa-massachusetts;
// "England" alone → eng (the country's outline, `isCountryOnly`).
//
// THE RULE, right to left like `BirthplaceClassifier.region` (largest place
// first):
//   0. A place that offers ALTERNATIVES ("England or Wales or France",
//      "Paris or Lyon, France") is refused outright: nil, counted as
//      recorded-but-unresolved. A guess between two countries is worse
//      than an honest blank (`offersAlternatives`).
//   1. Find the COUNTRY. A fine country (England, Ireland, Canada, USA,
//      France, Germany …) fixes which unit table the rest of the string
//      may hit. A coarse one ("United Kingdom", "Great Britain") only
//      narrows it to the four home nations. A recognised country OUTSIDE
//      the map (Australia, Poland, "Russia") ends the search with nil —
//      "Perth, WA, Australia" must never land on Washington State. The
//      RIGHTMOST recognised supported country wins: a country token to its
//      LEFT cannot be a unit of it and is skipped ("France, England" →
//      England, country only; "Quebec, France, Canada" → Quebec). Codex
//      #1782 (2).
//   2. Keep scanning left for the finest recognised UNIT of that country.
//      The first unit hit wins: units are written coarse-to-fine going
//      left, so the rightmost unit is the county / state, and the riding /
//      town / parish to its left is never consulted. "Yorkshire, Virginia,
//      United States" is Virginia.
//   3. No unit but a country → the country unit. Nothing → nil.
//
// WITHOUT A COUNTRY a unit name is accepted only when it names one place
// in the world that people write in a birthplace: "Yorkshire", "Fife",
// "Massachusetts" — but NOT "Middlesex", "Suffolk", "Essex", "Perth" or
// "Antrim", which are also counties or towns of New England, Ontario or
// Michigan. Those need the country to their right; without it the answer
// is honestly nil rather than a guess. Decoration does not change that:
// "County Middlesex", "Suffolk County" and "Co. Essex" are checked with
// the wrapping stripped (`undecorated`), so they refuse exactly as the
// bare name does (codex #1782 (1)). "-shire" is a spelling, not a
// decoration — "Somersetshire" stands alone.
//
// A COMPONENT ("Lowell Mass. U.S.A.") is tried whole, then as phrases of
// up to four whitespace tokens from the right — the same idea as
// `regionOfComponent`, extended to multi-word names ("Massachusetts Bay
// Colony" inside one comma part).
//
// The Hit keeps the component that decided (`matchedComponent`); the
// CALLER keeps the raw place string for any detail text — the map shows
// "recorded as Massachusetts Bay Colony" from the raw, never from the key.
//
// TABLES. Aliases are the REAL spellings in Rick's 39k-person tree (design
// §1) plus the pre-1974 / pre-1975 county names and the abbreviations
// FamilySearch users type. Each alias points at a canonical unit NAME and
// the key is derived ONCE, at table build, with `FamilyMapKey.unitKey`, so
// the resolver and the bundled border file can only ever agree or disagree
// through that one function. `allUnitKeys` lets a test (and the data
// build) prove the file covers everything the resolver can say.
//
// Decisions worth knowing (also in the Stage 1 report):
//   • London / Greater London / City of London → eng-middlesex. The
//     Historic County Borders data has no London unit; the City sits in
//     Middlesex historically (Southwark births would be Surrey, but the
//     string "London" cannot say which side of the river).
//   • Yorkshire's ridings and the 1974 counties (West / North / South /
//     East Yorkshire, Humberside, Cleveland) → eng-yorkshire; East / West
//     Sussex → eng-sussex.
//   • Ulster / Munster / Leinster / Connacht alone → country-only Ireland;
//     a Northern Ireland county to the left wins ("Belfast, Antrim,
//     Ulster, Ireland" → nir-antrim) because "Ireland" searches both IRL
//     and NIR tables.
//   • "Carolina" / "Province of Carolina" → country-only USA (it split in
//     1712); "New Netherland" and "New England" likewise (they span
//     states). "New France" and "Acadia" → country-only Canada.
//   • "Lothian" alone → country-only Scotland (three counties share it).
//   • Ross and Cromarty → sct-ross-shire (the HCBP draws Ross-shire and
//     Cromartyshire separately; "Cromarty" → sct-cromartyshire).
//   • Modern 1974 names that swallow a historic county are folded to it
//     (Cumbria → Cumberland, Greater Manchester / Merseyside → Lancashire,
//     Gwent → Monmouthshire); modern names that span several are not
//     mapped (Avon, Powys, Dyfed) and fall through to the country.
//   • Western Europe (2026-09-30): France by its 13 current régions (the
//     old 22 régions, the old provinces and the départements fold in),
//     Germany by Land, the Netherlands and Belgium by province, nine more
//     countries as outlines — tables and judgment calls (Prussia →
//     Germany, Rhineland → Germany country-only, Limburg / Luxembourg
//     shared) in BirthplaceUnitResolver+Europe.swift.
//
// COST. ~2 µs per place in a Debug build (UTF-8 byte work, one dictionary
// probe per component on a hit, five on a miss; no Foundation call on the
// ASCII path); 40k places well under 100 ms, measured in
// FamilyMapResolverTests. Pure; no I/O. (C++: a namespace of static
// functions over const tables.)

import Foundation

public enum BirthplaceUnitResolver {

    public struct Hit: Sendable, Equatable {
        /// "eng-yorkshire", "usa-massachusetts", or a bare country "eng".
        public let unitKey: String
        public let country: FamilyMap.Country
        /// `.county` / `.state` / `.province`, or `.country` when only the
        /// country was recognised.
        public let kind: FamilyMap.UnitKind
        /// The recorded text that decided the unit (or the country, when
        /// country-only), trimmed: "Massachusetts Bay Colony", "Yorks.".
        /// The raw place string stays with the caller.
        public let matchedComponent: String

        public var isCountryOnly: Bool { kind == .country }

        public init(unitKey: String, country: FamilyMap.Country, kind: FamilyMap.UnitKind, matchedComponent: String) {
            self.unitKey = unitKey
            self.country = country
            self.kind = kind
            self.matchedComponent = matchedComponent
        }
    }

    // MARK: - Resolve

    /// The unit a recorded place shades, or nil when nothing on the map
    /// was recognised (blank, a town alone, Poland, "Europe") or the place
    /// offers alternatives ("England or Wales").
    public static func resolve(_ raw: String?) -> Hit? {
        // Blank is `FamilyMapTally.hasText`'s blank (Unicode White_Space),
        // the same test the tally applies — one definition, not two.
        guard let raw, FamilyMapTally.hasText(raw) else { return nil }
        // Work on the string's own UTF-8 bytes: no Substring, no String
        // per component, no index arithmetic — a byte pointer and ranges.
        // (C++: `const char*` + offsets over the original buffer.)
        var text = raw
        if !text.isContiguousUTF8 { text.makeContiguousUTF8() }
        let result: Hit?? = text.utf8.withContiguousStorageIfAvailable { bytes -> Hit? in
            if offersAlternatives(bytes) { return nil }
            var scan = Scan(bytes: bytes)
            var hasComma = false
            var i = 0
            while i < bytes.count { if bytes[i] == 0x2C { hasComma = true; break }; i += 1 }
            let outcome = hasComma ? scan.scanCommaParts() : scan.scanPeriodParts(of: raw)
            switch outcome {
            case .hit(let hit): return hit
            case .stopped: return nil
            case .exhausted: return scan.countryOnlyHit
            }
        }
        return result.flatMap { $0 }
    }

    /// Every key the resolver can produce — the border file must carry
    /// each one (a pytest on the data build and a Swift sensor check it).
    public static let allUnitKeys: Set<String> = {
        var keys = Set(FamilyMap.Country.allCases.map(\.key))
        func collect(_ token: Token) {
            switch token {
            case .unit(_, _, let key): keys.insert(key)
            case .alternatives(let options): options.forEach(collect)
            case .today(let inner): collect(inner)
            default: break
            }
        }
        tables.values.forEach(collect)
        return keys
    }()

    // The "or" alternatives check (`offersAlternatives`) is in the extension
    // at the end of this file.

    // MARK: - The scan (one place string)

    /// What one recognised phrase means.
    enum Token: Equatable {
        /// A county / state / province of `country`, by canonical name,
        /// with its key precomputed.
        case unit(FamilyMap.Country, name: String, key: String)
        /// A country in scope. `searches` = which unit tables a name to
        /// the left may hit (Ireland the island → IRL and NIR).
        case country(FamilyMap.Country, searches: Set<FamilyMap.Country>)
        /// A country-level name that is not itself a unit ("United
        /// Kingdom"): narrows the search, shades nothing by itself.
        case coarse(Set<FamilyMap.Country>)
        /// A recognised country off the map (Poland, Australia): stop.
        case foreign
        /// One name, several meanings (2026-09-30): "Limburg" is a Dutch
        /// AND a Belgian province; "Luxembourg" a country AND a Belgian
        /// province. A `.unit` option is taken only when its country is
        /// the one established to the right; without one the units are
        /// ambiguous and only the non-unit options (a country) apply.
        indirect case alternatives([Token])
        /// A historic subregion placed where its ground is TODAY, whatever
        /// country is written to its right (Manager ruling 2026-09-30, the
        /// card's "today's flag" policy): "Strasbourg, Alsace, Germany" →
        /// Grand Est; "Trieste, Austria" → Italy. The inner token is a
        /// `.unit` (shaded) or a `.country` (country-only).
        indirect case today(Token)
        /// Ground that is in NO mapped country today (East Prussia,
        /// Silesia, Bohemia …): ends the scan with nil even when Germany /
        /// Prussia / Austria stands to its right — unless the established
        /// country is in `except` ("Galicia, Spain" is Spain's Galicia).
        case outside(except: Set<FamilyMap.Country>)
    }
    // `newWorldPrefixes` and `isEuropean` (the "New Bavaria" rule) live in
    // BirthplaceUnitResolver+Europe.swift.

    /// The state of one right-to-left pass over a place's bytes. Lives
    /// only inside `withContiguousStorageIfAvailable`; the buffer never
    /// escapes it.
    struct Scan {
        let bytes: UnsafeBufferPointer<UInt8>
        var country: FamilyMap.Country?
        var countryRange: Range<Int> = 0..<0
        var searches: Set<FamilyMap.Country>?
        var stopped = false

        init(bytes: UnsafeBufferPointer<UInt8>) { self.bytes = bytes }

        var countryOnlyHit: Hit? {
            guard let country else { return nil }
            return Hit(unitKey: country.key, country: country, kind: .country, matchedComponent: text(countryRange))
        }

        /// The recorded text of a byte range. These are a String's own
        /// UTF-8 bytes cut at ASCII commas and spaces, so the decode is
        /// lossless (the lint rule is aimed at Data of unknown encoding).
        func text(_ r: Range<Int>) -> String {
            // swiftlint:disable:next optional_data_string_conversion
            String(decoding: UnsafeBufferPointer(rebasing: bytes[r]), as: UTF8.self)
        }

        enum Outcome { case hit(Hit), stopped, exhausted }

        /// Right to left, one comma part at a time.
        mutating func scanCommaParts() -> Outcome {
            var end = bytes.count
            var i = bytes.count
            while i > 0 {
                i -= 1
                if bytes[i] == 0x2C {
                    if let hit = consume(range: (i + 1)..<end) { return .hit(hit) }
                    if stopped { return .stopped }
                    end = i
                }
            }
            if let hit = consume(range: 0..<end) { return .hit(hit) }
            return stopped ? .stopped : .exhausted
        }

        /// No comma: the classifier's period rule ("Quebec. Canada") —
        /// usually one part; otherwise each part's bytes are located in
        /// order and scanned right to left.
        mutating func scanPeriodParts(of raw: String) -> Outcome {
            let parts = BirthplaceClassifier.periodComponents(of: raw)
            var ranges: [Range<Int>] = []
            if parts.count <= 1 {
                ranges = [0..<bytes.count]
            } else {
                var from = 0
                for part in parts {
                    if let r = find(Array(part.utf8), in: bytes, from: from) { ranges.append(r); from = r.upperBound }
                }
            }
            for r in ranges.reversed() {
                if let hit = consume(range: r) { return .hit(hit) }
                if stopped { return .stopped }
            }
            return .exhausted
        }

        /// One comma component, whole first, then phrases of up to four
        /// whitespace tokens from the right.
        mutating func consume(range: Range<Int>) -> Hit? {
            let r = trimmedWhitespace(range, in: bytes)
            guard !r.isEmpty else { return nil }
            let whole = key(r)
            if let token = classify(key: whole, range: r, wholeComponent: true) {
                return apply(token, key: whole, range: r)
            }
            // Token ranges, by whitespace bytes.
            var tokens: [Range<Int>] = []
            var start: Int? = nil
            var i = r.lowerBound
            while i < r.upperBound {
                let space = isSpace(bytes[i])
                if space, let s = start { tokens.append(s..<i); start = nil }
                if !space, start == nil { start = i }
                i += 1
            }
            if let s = start { tokens.append(s..<r.upperBound) }
            guard tokens.count > 1 else { return nil }
            var end = tokens.count
            while end > 0 {
                var matched = false
                var length = end < 4 ? end : 4
                while length >= 1 {
                    let phrase = tokens[end - length].lowerBound..<tokens[end - 1].upperBound
                    let k = key(phrase)
                    if let token = classify(key: k, range: phrase, wholeComponent: phrase == r) {
                        // "New Bavaria", "Nieuw Nederland": a European name
                        // after "New" is a New-World namesake — not this
                        // phrase, and not the "New" either (QA P1-B).
                        let before = end - length - 1
                        if before >= 0, isEuropean(token), newWorldPrefixes.contains(key(tokens[before])) {
                            end = before
                            matched = true
                            break
                        }
                        if let hit = apply(token, key: k, range: phrase) { return hit }
                        if stopped { return nil }
                        end -= length
                        matched = true
                        break
                    }
                    length -= 1
                }
                if !matched { end -= 1 }
            }
            return nil
        }

        /// The normalised key of a byte range (see `normalizedKey`).
        func key(_ r: Range<Int>) -> String {
            var i = r.lowerBound
            while i < r.upperBound { if bytes[i] >= 0x80 { return slowNormalizedKey(text(r)) }; i += 1 }
            return asciiKey(r, in: bytes)
        }

        /// Fold one recognised phrase into the scan; a Hit ends it.
        mutating func apply(_ token: Token, key: String, range: Range<Int>) -> Hit? {
            switch token {
            case .unit(let unitCountry, _, let unitKey):
                if let searches {
                    guard searches.contains(unitCountry) else { return nil }
                } else if ambiguousWithoutCountry.contains(BirthplaceUnitResolver.undecorated(key)) {
                    // "County Middlesex" is as ambiguous as "Middlesex".
                    return nil
                }
                return Hit(unitKey: unitKey, country: unitCountry, kind: unitCountry.unitKind, matchedComponent: text(range))
            case .country(let c, let set):
                // "France, United Kingdom": a European country that the
                // coarse name to its right rules out is a contradiction,
                // refused exactly as it was while France was off the map.
                if country == nil, c.isWesternEurope, let searches, searches.isDisjoint(with: set) {
                    stopped = true
                    return nil
                }
                if country == nil {
                    country = c
                    countryRange = range
                    searches = set
                }
                return nil
            case .coarse(let set):
                if searches == nil { searches = set }
                return nil
            case .foreign:
                // A foreign country ends the search ONLY while no supported
                // country stands to its right. Once one is established the
                // token cannot be a unit of it and is skipped: "Quebec,
                // Poland, Canada" is still Quebec (codex #1782 (2)).
                if country == nil { stopped = true }
                return nil
            case .alternatives(let options):
                return applyAlternatives(options, key: key, range: range)
            case .today(let inner):
                return applyToday(inner, key: key, range: range)
            case .outside(let except):
                if let country, except.contains(country) { return nil }
                stopped = true
                return nil
            }
        }

        /// A shared name ("Limburg"): a unit only for the country already
        /// established; never a unit on its own.
        mutating func applyAlternatives(_ options: [Token], key: String, range: Range<Int>) -> Hit? {
            if let searches {
                for option in options {
                    if case .unit(let c, _, _) = option, searches.contains(c) {
                        return apply(option, key: key, range: range)
                    }
                }
            }
            for option in options {
                if case .unit = option { continue }
                if let hit = apply(option, key: key, range: range) { return hit }
                if stopped { return nil }
            }
            return nil
        }

        /// Where the ground is today, whatever is written to the right —
        /// but a name that needs its country ("Nice") still needs SOME
        /// country to its right.
        func applyToday(_ inner: Token, key: String, range: Range<Int>) -> Hit? {
            if searches == nil, ambiguousWithoutCountry.contains(BirthplaceUnitResolver.undecorated(key)) { return nil }
            switch inner {
            case .unit(let c, _, let unitKey):
                return Hit(unitKey: unitKey, country: c, kind: c.unitKind, matchedComponent: text(range))
            case .country(let c, _):
                return Hit(unitKey: c.key, country: c, kind: .country, matchedComponent: text(range))
            default:
                return nil
            }
        }

        /// One phrase → what it means, or nil.
        func classify(key: String, range: Range<Int>, wholeComponent: Bool) -> Token? {
            guard !key.isEmpty else { return nil }
            if let token = tables[key] { return token }
            // "County Durham", "Co. Cork", "Suffolk County".
            if key.hasPrefix("county "), let token = tables[String(key.dropFirst(7))] { return token }
            if key.hasPrefix("co "), let token = tables[String(key.dropFirst(3))] { return token }
            if key.hasSuffix(" county"), let token = tables[String(key.dropLast(7))] { return token }
            // "Somersetshire", "Dorsetshire", "Aberdeen-shire" — the -shire
            // form of a county whose name stands alone.
            if key.hasSuffix("shire"), let token = tables[String(key.dropLast(5))], case .unit = token { return token }
            if key.hasSuffix("-shire"), let token = tables[String(key.dropLast(6))], case .unit = token { return token }
            // Two-letter postal codes ("MA", "N.Y.", "Ma." — never "ma"):
            // the classifier's case rule, then Canada's. Only short text
            // can be one, so the Character walk is skipped otherwise.
            // "Halifax NS", "Toronto ON", "Charlottetown PEI" place as they
            // always did. The ONE exception (QA P1-A): with no country
            // known, Newfoundland's NL / NF counts only as a whole comma
            // part — inside a longer part "Nl" is the Netherlands' code:
            // "Bergen Op Zoom (Noord-Brabant) Nl" (a real tree string).
            if range.count <= 6 {
                let recorded = text(range)
                let usAllowed = searches?.contains(.unitedStates) ?? true
                // The shared US reader's case rule: postal codes and the
                // word-like short forms ("Del.", "Mont.") only upper-case or
                // Capitalised with the period. The case-free written forms
                // are table aliases (below), so they never reach here.
                if usAllowed, let name = USPlaceNames.stateName(recorded: recorded) {
                    return .unit(.unitedStates, name: name, key: FamilyMapKey.unitKey(country: .unitedStates, name: name))
                }
                let canadaKnown = searches == [.canada]
                if canadaKnown || searches == nil, let name = canadianCode(recorded, countryKnown: canadaKnown) {
                    let newfoundlandInsideAPart = name == "Newfoundland and Labrador" && !canadaKnown && !wholeComponent
                    if !newfoundlandInsideAPart {
                        return .unit(.canada, name: name, key: FamilyMapKey.unitKey(country: .canada, name: name))
                    }
                }
            }
            return nil
        }
    }

    static let homeNations: Set<FamilyMap.Country> = [.england, .scotland, .wales, .northernIreland]

    /// A normalised key with its "County " / "Co " prefix or " County"
    /// suffix removed — what the ambiguity rule looks at, so "County
    /// Middlesex" is as ambiguous as "Middlesex" (codex #1782 (1)). The
    /// "-shire" suffix is NOT a decoration: "Somersetshire" names one place.
    static func undecorated(_ key: String) -> String {
        if key.hasPrefix("county "), key.utf8.count > 7 { return String(key.dropFirst(7)) }
        if key.hasPrefix("co "), key.utf8.count > 3 { return String(key.dropFirst(3)) }
        if key.hasSuffix(" county"), key.utf8.count > 7 { return String(key.dropLast(7)) }
        return key
    }

    /// Canadian two-letter codes. With the country known any case goes
    /// ("nb"); bare, the code must be upper-case or Capitalised ("Nb" is in
    /// the tree) and must not be the word "On".
    static func canadianCode(_ recorded: String, countryKnown: Bool) -> String? {
        let letters = recorded.filter { $0.isLetter }
        guard letters.count == 2 || letters.count == 3,
              recorded.allSatisfy({ $0.isLetter || $0 == "." || $0 == " " }) else { return nil }
        let code = letters.uppercased()
        guard let name = canadianCodes[code] else { return nil }
        if countryKnown { return name }
        if letters == code { return name }
        if letters.first?.isUppercase == true, code != "ON" { return name }
        return nil
    }

    static let canadianCodes: [String: String] = [
        "AB": "Alberta", "BC": "British Columbia", "MB": "Manitoba", "NB": "New Brunswick",
        "NL": "Newfoundland and Labrador", "NF": "Newfoundland and Labrador", "NS": "Nova Scotia",
        "NT": "Northwest Territories", "NU": "Nunavut", "ON": "Ontario", "PE": "Prince Edward Island",
        "PEI": "Prince Edward Island", "QC": "Quebec", "PQ": "Quebec", "SK": "Saskatchewan", "YT": "Yukon",
    ]

    // MARK: - Normalisation (bytes)

    @inline(__always) static func isSpace(_ b: UInt8) -> Bool { b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D }

    /// `needle` located in `bytes` at or after `from`, or nil.
    static func find(_ needle: [UInt8], in bytes: UnsafeBufferPointer<UInt8>, from: Int) -> Range<Int>? {
        guard !needle.isEmpty, needle.count <= bytes.count else { return nil }
        var i = from
        while i + needle.count <= bytes.count {
            var k = 0
            while k < needle.count, bytes[i + k] == needle[k] { k += 1 }
            if k == needle.count { return i..<(i + needle.count) }
            i += 1
        }
        return nil
    }

    /// Leading / trailing ASCII whitespace off.
    static func trimmedWhitespace(_ r: Range<Int>, in bytes: UnsafeBufferPointer<UInt8>) -> Range<Int> {
        var lo = r.lowerBound, hi = r.upperBound
        while lo < hi, isSpace(bytes[lo]) { lo += 1 }
        while hi > lo, isSpace(bytes[hi - 1]) { hi -= 1 }
        return lo..<hi
    }

    /// The ASCII form of `normalizedKey`, written straight into the new
    /// String's buffer: lower-case; every run of period / space / other
    /// marks becomes one space, none leading or trailing; stray "-" / "'"
    /// / "&" at either end dropped ("Inverness-" style typos).
    static func asciiKey(_ r: Range<Int>, in bytes: UnsafeBufferPointer<UInt8>) -> String {
        guard !r.isEmpty else { return "" }
        return String(unsafeUninitializedCapacity: r.count) { out -> Int in
            var n = 0
            var pendingSpace = false
            var i = r.lowerBound
            while i < r.upperBound {
                var c = bytes[i]
                i += 1
                if c >= 0x41 && c <= 0x5A { c += 0x20 }                 // A-Z → a-z
                let alphanumeric = (c >= 0x61 && c <= 0x7A) || (c >= 0x30 && c <= 0x39)
                if alphanumeric || c == 0x27 || c == 0x2D || c == 0x26 { // letters, digits, ' - &
                    if pendingSpace, n > 0 { out[n] = 0x20; n += 1 }
                    pendingSpace = false
                    out[n] = c
                    n += 1
                } else {
                    pendingSpace = true
                }
            }
            while n > 0, out[n - 1] == 0x2D || out[n - 1] == 0x27 || out[n - 1] == 0x26 { n -= 1 }
            var start = 0
            while start < n, out[start] == 0x2D || out[start] == 0x27 || out[start] == 0x26 { start += 1 }
            if start > 0 {
                var k = 0
                while start + k < n { out[k] = out[start + k]; k += 1 }
                n -= start
            }
            return n
        }
    }

    /// `BirthplaceClassifier.normalize` (lower-case, diacritics folded,
    /// periods → spaces, spaces collapsed) plus stray punctuation trimmed
    /// off both ends ("(Wales)", "England>"). ASCII goes through
    /// `asciiKey`; anything else through Foundation's folding.
    static func normalizedKey(_ recorded: String) -> String {
        var text = recorded
        if !text.isContiguousUTF8 { text.makeContiguousUTF8() }
        return text.utf8.withContiguousStorageIfAvailable { bytes -> String in
            var i = 0
            while i < bytes.count { if bytes[i] >= 0x80 { return slowNormalizedKey(recorded) }; i += 1 }
            return asciiKey(0..<bytes.count, in: bytes)
        } ?? slowNormalizedKey(recorded)
    }

    static func slowNormalizedKey(_ recorded: String) -> String {
        let trimmed = recorded.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        return BirthplaceClassifier.normalize(trimmed)
    }

    // MARK: - Tables

    /// Unit names that are also counties, towns or provinces elsewhere in
    /// the English-speaking world, plus the European names that need their
    /// country (`europeNeedsCountry`: départements, "Berlin", "Paris" …).
    /// Accepted only with a country to their right. Normalised keys.
    static let ambiguousWithoutCountry: Set<String> = britishIslesAmbiguous.union(europeNeedsCountry)

    static let britishIslesAmbiguous: Set<String> = [
        // England ↔ New England / US counties and towns.
        "middlesex", "suffolk", "essex", "norfolk", "plymouth", "bristol", "worcester", "hampshire",
        "berkshire", "kent", "somerset", "cumberland", "lancaster", "york", "durham", "northumberland",
        "sussex", "surrey", "bedford", "huntingdon", "northampton", "hertford", "rutland", "dorset",
        "lincoln", "chester", "warwick", "gloucester", "buckingham", "cambridge", "oxford", "stafford",
        "nottingham", "london", "westmoreland", "derby", "cornwall", "richmond", "salisbury", "windsor",
        "hants", "bucks", "berks", "wilts", "beds", "herts", "notts", "hunts",
        // Scotland ↔ Ontario counties, US towns.
        "aberdeen", "perth", "elgin", "renfrew", "lanark", "inverness", "sutherland", "ayr", "banff",
        "dumfries", "berwick", "selkirk", "stirling", "kincardine", "ross", "glasgow", "edinburgh",
        "dundee", "bute", "nairn", "peebles", "roxburgh", "wigtown", "kinross", "clackmannan",
        // Wales ↔ US counties and towns.
        "monmouth", "montgomery", "pembroke", "cardigan", "radnor", "flint", "denbigh", "brecon",
        // Ireland ↔ US towns and counties.
        "antrim", "derry", "londonderry", "down", "tyrone", "dublin", "limerick", "galway", "waterford",
        "clare", "wexford", "roscommon", "donegal", "mayo", "armagh", "kildare",
    ]

    /// Normalised alias → token. Built once. Aliases with a hyphen also
    /// enter with the hyphen as a space and removed ("inverness-shire",
    /// "inverness shire", "invernessshire"). The classifier's own country
    /// vocabulary ("Eng.", "Inglaterra", "U.S.A.", "Dominion of Canada",
    /// Germany, "Russia") is merged in LAST, so a place is one dictionary
    /// probe: the map's entries win where the two overlap ("Northern
    /// Ireland", "Upper Canada").
    /// The normalised keys one alias is entered under: as written, and with
    /// each hyphen as a space and removed ("inverness-shire", "inverness
    /// shire", "invernessshire").
    static func aliasKeys(_ alias: String) -> [String] {
        let key = BirthplaceClassifier.normalize(alias)
        guard key.contains("-") else { return [key] }
        return [key, key.replacingOccurrences(of: "-", with: " "), key.replacingOccurrences(of: "-", with: "")]
    }

    static let tables: [String: Token] = {
        var t: [String: Token] = [:]
        func put(_ alias: String, _ token: Token) {
            for key in aliasKeys(alias) { t[key] = token }
        }
        func unit(_ country: FamilyMap.Country, _ name: String, _ aliases: [String] = []) {
            let token = Token.unit(country, name: name, key: FamilyMapKey.unitKey(country: country, name: name))
            put(name, token)
            for a in aliases { put(a, token) }
        }
        func country(_ c: FamilyMap.Country, searches: Set<FamilyMap.Country>? = nil, _ aliases: [String]) {
            for a in aliases { put(a, .country(c, searches: searches ?? [c])) }
        }

        // ---- England: the 39 historic counties (+ Yorkshire whole) --------
        unit(.england, "Bedfordshire", ["Beds"])
        unit(.england, "Berkshire", ["Berks"])
        unit(.england, "Buckinghamshire", ["Bucks"])
        unit(.england, "Cambridgeshire", ["Cambs", "Isle of Ely"])
        unit(.england, "Cheshire", ["Chester"])
        unit(.england, "Cornwall")
        unit(.england, "Cumberland", ["Cumbria"])
        unit(.england, "Derbyshire", ["Derby"])
        unit(.england, "Devon", ["Devonshire"])
        unit(.england, "Dorset", ["Dorsetshire"])
        unit(.england, "Durham", ["County Durham", "Co Durham"])
        unit(.england, "Essex")
        unit(.england, "Gloucestershire", ["Glos", "Gloucs", "Gloucester", "Bristol"])
        unit(.england, "Hampshire", ["Hants", "Southampton", "Isle of Wight"])
        unit(.england, "Herefordshire", ["Hereford"])
        unit(.england, "Hertfordshire", ["Herts", "Hertford"])
        unit(.england, "Huntingdonshire", ["Hunts", "Huntingdon"])
        unit(.england, "Kent")
        unit(.england, "Lancashire", ["Lancs", "Lancaster", "Greater Manchester", "Merseyside"])
        unit(.england, "Leicestershire", ["Leics", "Leicester"])
        unit(.england, "Lincolnshire", ["Lincs", "Lincoln"])
        unit(.england, "Middlesex", ["Middx", "London", "Greater London", "City of London"])
        unit(.england, "Norfolk")
        unit(.england, "Northamptonshire", ["Northants", "Northampton", "Soke of Peterborough"])
        unit(.england, "Northumberland", ["Tyne and Wear"])
        unit(.england, "Nottinghamshire", ["Notts", "Nottingham"])
        unit(.england, "Oxfordshire", ["Oxon", "Oxford"])
        unit(.england, "Rutland")
        unit(.england, "Shropshire", ["Salop", "Shrops"])
        unit(.england, "Somerset", ["Somersetshire", "Som"])
        unit(.england, "Staffordshire", ["Staffs", "Stafford"])
        unit(.england, "Suffolk")
        unit(.england, "Surrey")
        unit(.england, "Sussex", ["East Sussex", "West Sussex"])
        unit(.england, "Warwickshire", ["Warwicks", "Warks", "Warwick", "West Midlands"])
        unit(.england, "Westmorland", ["Westmoreland"])
        unit(.england, "Wiltshire", ["Wilts"])
        unit(.england, "Worcestershire", ["Worcs", "Worcester"])
        unit(.england, "Yorkshire", ["Yorks", "York", "West Yorkshire", "North Yorkshire", "East Yorkshire",
                                     "South Yorkshire", "West Riding", "North Riding", "East Riding",
                                     "West Riding of Yorkshire", "North Riding of Yorkshire",
                                     "East Riding of Yorkshire", "Yorkshire West Riding",
                                     "Yorkshire North Riding", "Yorkshire East Riding", "Humberside", "Cleveland"])

        // ---- Scotland: the 33 historic counties (Ross and Cromarty as two)
        unit(.scotland, "Aberdeenshire", ["Aberdeen"])
        unit(.scotland, "Angus", ["Forfarshire", "Forfar", "Dundee"])
        unit(.scotland, "Argyllshire", ["Argyll", "Argyle", "Argyleshire"])   // the HCBP name
        unit(.scotland, "Ayrshire", ["Ayr"])
        unit(.scotland, "Banffshire", ["Banff"])
        unit(.scotland, "Berwickshire", ["Berwick"])
        unit(.scotland, "Buteshire", ["Bute", "Isle of Bute"])
        unit(.scotland, "Caithness")
        unit(.scotland, "Clackmannanshire", ["Clackmannan"])
        unit(.scotland, "Dumfriesshire", ["Dumfries", "Dumfries-shire"])
        unit(.scotland, "Dunbartonshire", ["Dumbartonshire", "Dunbarton", "Dumbarton"])
        unit(.scotland, "East Lothian", ["Haddingtonshire", "Haddington"])
        unit(.scotland, "Fife", ["Fifeshire"])
        unit(.scotland, "Inverness-shire", ["Inverness"])
        unit(.scotland, "Kincardineshire", ["Kincardine", "The Mearns", "Mearns"])
        unit(.scotland, "Kinross-shire", ["Kinross"])
        unit(.scotland, "Kirkcudbrightshire", ["Kirkcudbright", "Stewartry of Kirkcudbright"])
        unit(.scotland, "Lanarkshire", ["Lanark", "Glasgow"])
        unit(.scotland, "Midlothian", ["Edinburghshire", "Edinburgh", "Mid Lothian"])
        unit(.scotland, "Morayshire", ["Moray", "Elginshire", "Elgin"])
        unit(.scotland, "Nairnshire", ["Nairn"])
        unit(.scotland, "Orkney", ["Orkney Islands"])
        unit(.scotland, "Peeblesshire", ["Peebles"])
        unit(.scotland, "Perthshire", ["Perth"])
        unit(.scotland, "Renfrewshire", ["Renfrew"])
        unit(.scotland, "Ross-shire", ["Ross", "Ross and Cromarty", "Rossshire"])
        unit(.scotland, "Cromartyshire", ["Cromarty"])
        unit(.scotland, "Roxburghshire", ["Roxburgh"])
        unit(.scotland, "Selkirkshire", ["Selkirk"])
        unit(.scotland, "Shetland", ["Zetland", "Shetland Islands"])
        unit(.scotland, "Stirlingshire", ["Stirling"])
        unit(.scotland, "Sutherland", ["Sutherlandshire"])
        unit(.scotland, "West Lothian", ["Linlithgowshire", "Linlithgow"])
        unit(.scotland, "Wigtownshire", ["Wigtown", "Wigtonshire"])
        country(.scotland, ["Lothian", "The Lothians"])

        // ---- Wales: the 13 historic counties ------------------------------
        unit(.wales, "Anglesey", ["Ynys Mon", "Sir Fon"])
        unit(.wales, "Brecknockshire", ["Breconshire", "Brecon", "Brecknock"])
        unit(.wales, "Caernarfonshire", ["Caernarvonshire", "Carnarvonshire", "Caernarfon", "Caernarvon", "Carnarvon"])
        unit(.wales, "Cardiganshire", ["Ceredigion", "Cardigan"])
        unit(.wales, "Carmarthenshire", ["Carmarthen", "Sir Gaerfyrddin"])
        unit(.wales, "Denbighshire", ["Denbigh"])
        unit(.wales, "Flintshire", ["Flint"])
        unit(.wales, "Glamorgan", ["Glamorganshire", "Morgannwg", "South Glamorgan", "Mid Glamorgan", "West Glamorgan"])
        unit(.wales, "Merionethshire", ["Merioneth", "Meirionnydd"])
        unit(.wales, "Monmouthshire", ["Monmouth", "Gwent"])
        unit(.wales, "Montgomeryshire", ["Montgomery"])
        unit(.wales, "Pembrokeshire", ["Pembroke"])
        unit(.wales, "Radnorshire", ["Radnor"])

        // ---- Northern Ireland: the six counties ---------------------------
        unit(.northernIreland, "Antrim")
        unit(.northernIreland, "Armagh")
        unit(.northernIreland, "Down")
        unit(.northernIreland, "Fermanagh")
        unit(.northernIreland, "Londonderry", ["Derry"])
        unit(.northernIreland, "Tyrone")

        // ---- Ireland: the 26 counties -------------------------------------
        for name in ["Carlow", "Cavan", "Clare", "Cork", "Donegal", "Dublin", "Galway", "Kerry", "Kildare",
                     "Kilkenny", "Leitrim", "Limerick", "Longford", "Louth", "Mayo", "Meath", "Monaghan",
                     "Roscommon", "Sligo", "Tipperary", "Waterford", "Westmeath", "Wexford", "Wicklow"] {
            unit(.ireland, name)
        }
        unit(.ireland, "Laois", ["Leix", "Queen's County", "Queens County"])
        unit(.ireland, "Offaly", ["King's County", "Kings County"])
        // The provinces shade the island's outline; a county to their left
        // still wins because the search covers IRL and NIR.
        country(.ireland, searches: [.ireland, .northernIreland],
                ["Ulster", "Munster", "Leinster", "Connacht", "Connaught"])
        country(.northernIreland, ["Northern Ireland", "N Ireland", "N. Ireland"])

        // ---- United States: fifty states + DC, old short forms, colonies --
        // Postal codes are NOT aliases: "in", "or", "co", "me" are words.
        // They match only through `usAbbreviation`'s case rule in `classify`.
        for name in USStateCodes.names.values { unit(.unitedStates, name) }
        // The old written forms ("Conn.", "Penna.", "N. H.", "Wis.") are
        // the shared table every place reader uses (USPlaceNames); the
        // word-like ones ("Del.", "Mont.") are NOT aliases — they match
        // only through the case rule in `classify`.
        for (alias, name) in USPlaceNames.writtenForms { unit(.unitedStates, name, [alias]) }
        unit(.unitedStates, "Massachusetts", ["Massachusetts Bay Colony", "Massachusetts Bay", "Province of Massachusetts Bay",
                                              "Colony of Massachusetts Bay", "Plymouth Colony", "Plimoth Colony",
                                              "Plymouth Plantation", "New Plymouth", "Colony of New Plymouth",
                                              "Massachusetts Bay Province", "Massachusetts Colony"])
        unit(.unitedStates, "Connecticut", ["Connecticut Colony", "Colony of Connecticut", "New Haven Colony", "Saybrook Colony"])
        unit(.unitedStates, "New Hampshire", ["Province of New Hampshire", "New Hampshire Colony", "Colony of New Hampshire"])
        unit(.unitedStates, "Rhode Island", ["Rhode Island Colony", "Colony of Rhode Island",
                                             "Colony of Rhode Island and Providence Plantations",
                                             "Rhode Island and Providence Plantations", "Providence Plantations"])
        unit(.unitedStates, "Vermont", ["New Connecticut", "Republic of Vermont"])
        unit(.unitedStates, "Maine", ["Province of Maine", "District of Maine"])
        unit(.unitedStates, "New York", ["New York Colony", "Province of New York", "Colony of New York"])
        unit(.unitedStates, "Pennsylvania", ["Province of Pennsylvania", "Pennsylvania Colony"])
        unit(.unitedStates, "Virginia", ["Colony of Virginia", "Virginia Colony"])
        unit(.unitedStates, "Maryland", ["Province of Maryland", "Maryland Colony"])
        unit(.unitedStates, "New Jersey", ["Province of New Jersey", "New Jersey Colony"])
        unit(.unitedStates, "Delaware", ["Delaware Colony"])
        unit(.unitedStates, "Georgia", ["Province of Georgia", "Georgia Colony"])
        unit(.unitedStates, "North Carolina", ["Province of North Carolina"])
        unit(.unitedStates, "South Carolina", ["Province of South Carolina"])
        // Names that span states: the country outline, honestly.
        country(.unitedStates, ["Carolina", "Province of Carolina", "New England", "New Netherland", "New Netherlands",
                                "British Colonial America", "Colonial America", "American Colonies", "Thirteen Colonies"])

        // ---- Canada: provinces and territories, old names -----------------
        unit(.canada, "Alberta")
        unit(.canada, "British Columbia")
        unit(.canada, "Manitoba")
        unit(.canada, "New Brunswick", ["Colony of New Brunswick"])
        unit(.canada, "Newfoundland and Labrador", ["Newfoundland", "Labrador", "Colony of Newfoundland"])
        unit(.canada, "Nova Scotia", ["Colony of Nova Scotia"])
        unit(.canada, "Ontario", ["Upper Canada", "Canada West", "Province of Ontario"])
        unit(.canada, "Prince Edward Island")
        unit(.canada, "Quebec", ["Québec", "Lower Canada", "Canada East", "Province of Quebec", "Province of Québec"])
        unit(.canada, "Saskatchewan")
        unit(.canada, "Northwest Territories")
        unit(.canada, "Nunavut")
        unit(.canada, "Yukon", ["Yukon Territory"])
        country(.canada, ["New France", "Nouvelle-France", "Nouvelle France", "Acadia", "Acadie",
                          "Province of Canada", "Dominion of Canada"])

        // ---- Western Europe (BirthplaceUnitResolver+Europe.swift) ---------
        for u in europeUnits { unit(u.country, u.name, u.aliases + u.needsCountry) }
        for (region, departements) in franceDepartements { unit(.france, region, departements) }
        for (c, aliases) in europeCountries { country(c, aliases) }
        for (alias, token) in europeSharedTokens() { put(alias, token) }
        // After the units, so these meanings win over a plain alias.
        for (alias, except) in europeOutside { put(alias, .outside(except: except)) }
        for (alias, token) in europeTodayTokens() { put(alias, token) }
        for (alias, c) in europeCoarse { put(alias, .coarse([c])) }
        for (alias, token) in newWorldColonyTokens() { put(alias, token) }

        // ---- The classifier's vocabulary, where the map has no entry ------
        func merge(_ key: String, _ token: Token) { if t[key] == nil { t[key] = token } }
        for (key, region) in BirthplaceClassifier.regionTable {
            switch region {
            case .england: merge(key, .country(.england, searches: [.england]))
            case .scotland: merge(key, .country(.scotland, searches: [.scotland]))
            case .wales: merge(key, .country(.wales, searches: [.wales]))
            case .ireland: merge(key, .country(.ireland, searches: [.ireland, .northernIreland]))
            default: break   // New England / state spellings are units above
            }
        }
        for key in BirthplaceClassifier.coarseUS { merge(key, .country(.unitedStates, searches: [.unitedStates])) }
        for key in BirthplaceClassifier.coarseOther { merge(key, .coarse(homeNations)) }
        for (key, entry) in BirthplaceClassifier.countries {
            if entry.ambiguous { merge(key, .foreign); continue }
            switch entry.country {
            case BirthplaceClassifier.unitedStates?: merge(key, .country(.unitedStates, searches: [.unitedStates]))
            case BirthplaceClassifier.canada?: merge(key, .country(.canada, searches: [.canada]))
            case "Ireland"?: merge(key, .country(.ireland, searches: [.ireland, .northernIreland]))
            default:
                // "sicily" → Italy, "flanders" → Belgium: the classifier's
                // historical names of ground that is one mapped country
                // today. Anything else is off the map (Poland, Isle of Man,
                // the Holy Roman Empire …).
                if let name = entry.country, let c = classifierEuropeanCountries[name] {
                    merge(key, .country(c, searches: [c]))
                } else {
                    merge(key, .foreign)
                }
            }
        }
        return t
    }()
}

// MARK: - Alternatives ("England or Wales")

// An extension (≈ more static members of the same namespace) so the
// enum body stays within the lint length limit.
extension BirthplaceUnitResolver {

    /// True when some comma part has the word "or" (any case) BETWEEN two
    /// words: "ENGLAND OR Wales or France", "Paris or Lyon, France". Not an
    /// alternative: "Portland, OR" (the state code alone in its part),
    /// "Portland OR USA" (upper-case OR followed only by the US), "Côte d
    /// Or" (the "d" before it). A cheap byte scan first: unless an "o"/"O"
    /// is directly followed by "r"/"R" somewhere, nothing is split into
    /// words at all (most places — "Yorkshire" does pass the scan and pays
    /// for the word walk, which finds no standalone "or").
    static func offersAlternatives(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        let n = bytes.count
        var j = 0
        var sawOr = false
        while j + 1 < n {
            if bytes[j] | 0x20 == 0x6F, bytes[j + 1] | 0x20 == 0x72 { sawOr = true; break }
            j += 1
        }
        guard sawOr else { return false }
        var start = 0
        var i = 0
        while i <= n {
            if i == n || bytes[i] == 0x2C {
                if partOffersAlternatives(bytes, start..<i) { return true }
                start = i + 1
            }
            i += 1
        }
        return false
    }

    static func partOffersAlternatives(_ bytes: UnsafeBufferPointer<UInt8>, _ r: Range<Int>) -> Bool {
        // Words = runs of non-space bytes.
        var words: [Range<Int>] = []
        var s: Int? = nil
        var i = r.lowerBound
        while i < r.upperBound {
            let space = isSpace(bytes[i])
            if space, let b = s { words.append(b..<i); s = nil }
            if !space, s == nil { s = i }
            i += 1
        }
        if let b = s { words.append(b..<r.upperBound) }
        guard words.count >= 3 else { return false }   // "x or y" needs a word each side
        for k in 1..<(words.count - 1) {
            let w = words[k]
            guard w.count == 2, bytes[w.lowerBound] | 0x20 == 0x6F, bytes[w.lowerBound + 1] | 0x20 == 0x72 else { continue }
            let previous = words[k - 1]
            if previous.count == 1, bytes[previous.lowerBound] | 0x20 == 0x64 { continue }   // "Côte d Or"
            if bytes[w.lowerBound] == 0x4F, bytes[w.lowerBound + 1] == 0x52 {                  // upper-case "OR"
                let rest = (words[k + 1].lowerBound..<r.upperBound)
                let tail = asciiKey(rest, in: bytes)
                if usCountryTails.contains(tail) { continue }                                   // "Portland OR USA"
            }
            return true
        }
        return false
    }

    /// What may follow the Oregon code in the same comma part.
    static let usCountryTails: Set<String> = ["usa", "us", "u s a", "u s", "united states", "united states of america"]
}
