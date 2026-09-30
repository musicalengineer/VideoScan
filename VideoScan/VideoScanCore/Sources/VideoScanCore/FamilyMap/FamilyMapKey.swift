// FamilyMapKey.swift (VideoScanCore/FamilyMap)
// The family map (GH #227, docs/family_map_design_2026-09-29.md): regions
// of the world shaded by how many ancestors were born there. This file is
// the VOCABULARY the whole feature shares — the seven countries in scope,
// the kinds of unit, a coordinate, a bounding box — and the ONE rule that
// turns a unit's name into its key.
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
// (C++ readers: `enum FamilyMap` / `enum FamilyMapKey` with no cases are
// namespaces; the structs are plain values.)

import Foundation

public enum FamilyMap {

    /// The countries the map shades, by ISO-3166-2-style code. England,
    /// Scotland, Wales and Northern Ireland are separate because the map
    /// goes one level below them (historic counties) and because that is
    /// how a New England family's story is told.
    public enum Country: String, Sendable, Codable, CaseIterable, Equatable, Hashable {
        case england = "ENG"
        case scotland = "SCT"
        case wales = "WLS"
        case northernIreland = "NIR"
        case ireland = "IRL"
        case unitedStates = "USA"
        case canada = "CAN"

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
            }
        }

        /// What the country's second-level units are called.
        public var unitKind: UnitKind {
            switch self {
            case .unitedStates: return .state
            case .canada: return .province
            default: return .county
            }
        }
    }

    public enum UnitKind: String, Sendable, Codable, CaseIterable, Equatable {
        case county, state, province, country
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
    /// handled — nothing in scope (the British Isles, the US mainland and
    /// Canada) crosses ±180°, and Alaska's Aleutians are simplified away
    /// at 1:50m.
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

    /// The slug of a unit name. THE RULE (the Python builder implements the
    /// same one, character for character):
    ///   1. strip diacritics (NFKD, drop combining marks: "Québec" → "Quebec",
    ///      "Ynys Môn" → "Ynys Mon");
    ///   2. lower-case;
    ///   3. every maximal run of characters that is not an ASCII letter or
    ///      digit becomes ONE "-" (space, apostrophe, hyphen, period, and any
    ///      letter that has no ASCII base such as "ø" or "ß");
    ///   4. drop leading and trailing "-".
    /// "East Lothian" → "east-lothian"; "Inverness-shire" → "inverness-shire";
    /// "St. John's" → "st-john-s"; "Ross and Cromarty" → "ross-and-cromarty".
    public static func slug(_ name: String) -> String {
        let folded = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).lowercased()
        var out = ""
        out.reserveCapacity(folded.utf8.count)
        var pendingDash = false
        for scalar in folded.unicodeScalars {
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
    /// England); nil for a malformed key.
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
