// FamilyMapKey.swift (VideoScanCore/FamilyMap)
// The family map (GH #227, docs/design/family_map_design_2026-09-29.md): regions
// of the world shaded by how many ancestors were born there. This file is
// the VOCABULARY the whole feature shares — the countries in scope, the
// kinds of unit, a coordinate, a bounding box — and the ONE rule that turns
// a unit's name into its key.
//
// Why the key rule lives here and nowhere else: the bundled border file
// (`family-map-units.geojson`, built by scripts/build_family_map_units.py)
// carries a `key` per feature, and the resolver turns a birthplace string
// into a key. The two are joined by string equality. If the Python script
// and this file ever disagreed on "East Lothian" → "sct-east-lothian", a
// whole county would silently show zero births. So the rule is small,
// written out in full in the doc comment, and pinned by a sensor test the
// script's own test repeats.
//
// WESTERN EUROPE (Rick 2026-09-30, "Countries + regions"): France by its 13
// current régions, Germany by Land, the Netherlands and Belgium by province;
// Luxembourg, Switzerland, Austria, Denmark, Norway, Sweden, Italy, Spain
// and Portugal as country outlines only (`hasSubdivisions == false`). Keys
// follow the same rule — "fra-normandy", "deu-bavaria", "nld-north-brabant",
// "bel-hainaut", "ita" — never a second, abbreviation-based scheme.
//
// (C++ readers: `enum FamilyMap` / `enum FamilyMapKey` with no cases are
// namespaces; the structs are plain values.)

import Foundation

public enum FamilyMap {

    /// The countries the map shades, by ISO-3166-style code. England,
    /// Scotland, Wales and Northern Ireland are separate because the map
    /// goes one level below them (historic counties) and because that is
    /// how a New England family's story is told. The Western Europe stage
    /// uses ISO 3166-1 alpha-3 codes (FRA, DEU …).
    public enum Country: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
        case england = "ENG"
        case scotland = "SCT"
        case wales = "WLS"
        case northernIreland = "NIR"
        case ireland = "IRL"
        case unitedStates = "USA"
        case canada = "CAN"
        // Western Europe (2026-09-30).
        case france = "FRA"
        case germany = "DEU"
        case netherlands = "NLD"
        case belgium = "BEL"
        case luxembourg = "LUX"
        case switzerland = "CHE"
        case austria = "AUT"
        case denmark = "DNK"
        case norway = "NOR"
        case sweden = "SWE"
        case italy = "ITA"
        case spain = "ESP"
        case portugal = "PRT"

        /// The country's own unit key ("eng") — what a birth shades when
        /// the country is known but the county / state is not.
        public var key: String { rawValue.lowercased() }

        public var label: String {
            switch self {
            case .england: return "England"
            case .scotland: return "Scotland"
            case .wales: return "Wales"
            case .northernIreland: return "Northern Ireland"
            case .ireland: return "Ireland"
            case .unitedStates: return "United States"
            case .canada: return "Canada"
            case .france: return "France"
            case .germany: return "Germany"
            case .netherlands: return "Netherlands"
            case .belgium: return "Belgium"
            case .luxembourg: return "Luxembourg"
            case .switzerland: return "Switzerland"
            case .austria: return "Austria"
            case .denmark: return "Denmark"
            case .norway: return "Norway"
            case .sweden: return "Sweden"
            case .italy: return "Italy"
            case .spain: return "Spain"
            case .portugal: return "Portugal"
            }
        }

        /// What the country's second-level units are called. For a country
        /// drawn only as an outline the answer is `.region` and is never
        /// shown (see `hasSubdivisions`).
        public var unitKind: UnitKind {
            switch self {
            case .unitedStates, .germany: return .state
            case .canada, .netherlands, .belgium: return .province
            case .england, .scotland, .wales, .northernIreland, .ireland: return .county
            case .france, .luxembourg, .switzerland, .austria, .denmark, .norway, .sweden,
                 .italy, .spain, .portugal: return .region
            }
        }

        /// False for the countries the map draws as an outline only
        /// (Italy, Denmark …): a count there is the whole count, and the
        /// panel must not say "region unresolved" about a map that has no
        /// regions to resolve to.
        public var hasSubdivisions: Bool {
            switch self {
            case .luxembourg, .switzerland, .austria, .denmark, .norway, .sweden, .italy, .spain, .portugal:
                return false
            default:
                return true
            }
        }

        /// The Western Europe stage (2026-09-30). The camera rule treats
        /// these outlines differently from the original seven — see
        /// `FamilyMapUnits.coverage(for:)`.
        public var isWesternEurope: Bool {
            switch self {
            case .england, .scotland, .wales, .northernIreland, .ireland, .unitedStates, .canada: return false
            default: return true
            }
        }
    }

    public enum UnitKind: String, Sendable, Codable, CaseIterable, Equatable {
        /// `region` = a French région (2026-09-30).
        case county, state, province, region, country
    }

    /// WGS84 degrees. GeoJSON writes positions as [lon, lat]; this struct
    /// names them so the order can never be confused again.
    public struct Coordinate: Sendable, Equatable, Hashable {
        public let latitude: Double
        public let longitude: Double
        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// An axis-aligned box in degrees. Antimeridian-crossing boxes are not
    /// handled — nothing in scope (the British Isles, Western Europe, the
    /// US mainland and Canada) crosses ±180°, and Alaska's Aleutians are
    /// simplified away at 1:50m.
    public struct BoundingBox: Sendable, Equatable {
        public var minLatitude: Double
        public var maxLatitude: Double
        public var minLongitude: Double
        public var maxLongitude: Double

        public init(minLatitude: Double, maxLatitude: Double, minLongitude: Double, maxLongitude: Double) {
            self.minLatitude = minLatitude
            self.maxLatitude = maxLatitude
            self.minLongitude = minLongitude
            self.maxLongitude = maxLongitude
        }

        /// The tightest box around `points`; nil for no points.
        public init?(around points: [Coordinate]) {
            guard let first = points.first else { return nil }
            var box = BoundingBox(minLatitude: first.latitude, maxLatitude: first.latitude,
                                  minLongitude: first.longitude, maxLongitude: first.longitude)
            for p in points.dropFirst() { box.expand(toInclude: p) }
            self = box
        }

        public mutating func expand(toInclude p: Coordinate) {
            if p.latitude < minLatitude { minLatitude = p.latitude }
            if p.latitude > maxLatitude { maxLatitude = p.latitude }
            if p.longitude < minLongitude { minLongitude = p.longitude }
            if p.longitude > maxLongitude { maxLongitude = p.longitude }
        }

        public func union(_ other: BoundingBox) -> BoundingBox {
            BoundingBox(minLatitude: min(minLatitude, other.minLatitude),
                        maxLatitude: max(maxLatitude, other.maxLatitude),
                        minLongitude: min(minLongitude, other.minLongitude),
                        maxLongitude: max(maxLongitude, other.maxLongitude))
        }

        /// Closed on every edge: a point on the boundary is inside.
        @inline(__always)
        public func contains(_ p: Coordinate) -> Bool {
            p.latitude >= minLatitude && p.latitude <= maxLatitude
                && p.longitude >= minLongitude && p.longitude <= maxLongitude
        }

        /// Square degrees — only ever COMPARED (enclave vs enclosure), so
        /// the cos(latitude) distortion does not matter.
        public var area: Double { (maxLatitude - minLatitude) * (maxLongitude - minLongitude) }

        public var center: Coordinate {
            Coordinate(latitude: (minLatitude + maxLatitude) / 2, longitude: (minLongitude + maxLongitude) / 2)
        }
    }
}

public enum FamilyMapKey {

    /// The slug of a unit name. THE RULE — the Python builder
    /// (scripts/build_family_map_units.py `slug`) is the PRODUCER of the
    /// keys, and this is its algorithm step for step:
    ///   1. NFKD-decompose ("Québec" → "Que" + combining acute + "bec";
    ///      "ﬁ" → "fi"; fullwidth "Ａ" → "A");
    ///   2. lower-case;
    ///   3. drop every combining mark (Unicode canonical combining class ≠ 0
    ///      — Python's `unicodedata.combining(c)`), so the accents go:
    ///      "Ynys Môn" → "ynys mon";
    ///   4. every maximal run of characters that is not an ASCII letter or
    ///      digit becomes ONE "-": space, apostrophe, hyphen, period, AND any
    ///      letter that has no decomposition — "ß", "ø", "ł", "đ", "æ" are
    ///      word breaks, never "ss" / "o" / "l" / "d" / "ae";
    ///   5. no leading or trailing "-".
    /// "East Lothian" → "east-lothian"; "Inverness-shire" → "inverness-shire";
    /// "St. John's" → "st-john-s"; "Ross and Cromarty" → "ross-and-cromarty";
    /// "Straße" → "stra-e"; "Ørsted" → "rsted"; "Provence-Alpes-Côte d'Azur"
    /// → "provence-alpes-cote-d-azur". FamilyMapKeyTests and the script's
    /// pytest pin the same examples. (Until 2026-09-29 this used
    /// Foundation's diacritic-insensitive folding, which expands ß to "ss"
    /// and strips ø to "o" — a key the builder never writes.)
    public static func slug(_ name: String) -> String {
        let lowered = name.decomposedStringWithCompatibilityMapping.lowercased()
        var out = ""
        out.reserveCapacity(lowered.utf8.count)
        var pendingDash = false
        for scalar in lowered.unicodeScalars {
            // A combining mark (ccc ≠ 0) is neither a letter nor a break:
            // it is simply gone, as in the builder.
            if scalar.properties.canonicalCombiningClass != .notReordered { continue }
            let v = scalar.value
            let isASCIIAlphanumeric = (v >= 0x61 && v <= 0x7A) || (v >= 0x30 && v <= 0x39)
            if isASCIIAlphanumeric {
                if pendingDash && !out.isEmpty { out.append("-") }
                pendingDash = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingDash = true
            }
        }
        return out
    }

    /// The key of a unit: `<country>-<slug(name)>`, or just the country
    /// ("eng") when `name` is nil or blank. For Ireland and Northern Ireland
    /// a leading "County " is dropped first, because the Natural Earth
    /// names say "County Antrim" and people write "Antrim", "Co. Antrim" and
    /// "County Antrim" interchangeably — one key for all of them.
    public static func unitKey(country: FamilyMap.Country, name: String?) -> String {
        guard var name, !name.trimmingCharacters(in: .whitespaces).isEmpty else { return country.key }
        if country == .ireland || country == .northernIreland {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            if trimmed.lowercased().hasPrefix("county ") {
                name = String(trimmed.dropFirst("county ".count))
            }
        }
        let s = slug(name)
        return s.isEmpty ? country.key : country.key + "-" + s
    }

    /// The country a key belongs to ("eng-yorkshire" → England, "eng" →
    /// England, "fra-normandy" → France); nil for a malformed key.
    public static func country(of key: String) -> FamilyMap.Country? {
        let prefix = key.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? key
        return FamilyMap.Country(rawValue: prefix.uppercased())
    }

    /// True for a bare country key ("usa") — a birth whose state or county
    /// is not recorded. Byte count first: the tally asks 39k times.
    public static func isCountryKey(_ key: String) -> Bool {
        key.utf8.count == 3 && countryKeys.contains(key)
    }

    static let countryKeys: Set<String> = Set(FamilyMap.Country.allCases.map(\.key))
}
