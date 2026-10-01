// LifeAndTimesRegion.swift (VideoScanCore)
// Where a historical event happened, and where a person was — in the same
// coarse vocabulary, so "did the Famine touch this person?" is a set test
// (GH #238 stage 1, Rick 2026-10-01).
//
// A person's places are read with the existing classifiers, never a new
// guesser: BirthplaceClassifier.region (New England / rest of US / England /
// Ireland / Scotland / Wales / Canada / elsewhere) first, and for
// "elsewhere" the country classifier (France, Germany, …). Anything those
// tables do not know stays unknown and is never inside a scope.
//
// Umbrella regions: `.world` covers everyone; `.europe` covers every
// European region; `.britain` covers England, Scotland and Wales (NOT
// Ireland — an event that touched Ireland lists it explicitly, because
// Irish history before 1922 is not "British" history to an Irish family).
//
// Pure, table-driven. C++ readers: an enum with a raw String value is a
// scoped enum that also serialises as its name.

import Foundation

extension LifeAndTimes {

    public enum Region: String, Sendable, Codable, CaseIterable, Hashable, Comparable {
        case world
        case europe
        case britain
        case unitedStates
        case canada
        case ireland
        /// Belfast and the six counties. Part of Ireland for events before
        /// 1922; part of the United Kingdom for events from 1921 on.
        case northernIreland
        case england
        case scotland
        case wales
        case france
        case germany
        case italy
        case netherlands
        case otherEurope
        case elsewhere

        public static func < (a: Region, b: Region) -> Bool { a.order < b.order }
        private static let orderTable: [Region: Int] =
            Dictionary(uniqueKeysWithValues: allCases.enumerated().map { ($1, $0) })
        var order: Int { Self.orderTable[self] ?? 0 }

        public var label: String {
            switch self {
            case .world: return "the world"
            case .europe: return "Europe"
            case .britain: return "Britain"
            case .unitedStates: return "the United States"
            case .canada: return "Canada"
            case .ireland: return "Ireland"
            case .northernIreland: return "Northern Ireland"
            case .england: return "England"
            case .scotland: return "Scotland"
            case .wales: return "Wales"
            case .france: return "France"
            case .germany: return "Germany"
            case .italy: return "Italy"
            case .netherlands: return "the Netherlands"
            case .otherEurope: return "elsewhere in Europe"
            case .elsewhere: return "elsewhere"
            }
        }

        /// True when an event scoped to `self` touches a person in `place`.
        /// `world` touches everyone; umbrellas touch their members.
        public func covers(_ place: Region) -> Bool {
            if self == place { return true }
            switch self {
            case .world: return true
            case .europe: return place.isEuropean
            case .britain: return place == .england || place == .scotland || place == .wales
            case .ireland: return place == .northernIreland   // the island, for lines and filters
            default: return false
            }
        }

        static let greatBritain: Set<Region> = [.england, .scotland, .wales, .britain]

        /// Did an event scoped to `scope`, starting in `year`, touch a person
        /// recorded in `self`? Beyond `covers`:
        ///   • a place recorded only as "United Kingdom" (`.britain`) is
        ///     touched by any England/Scotland/Wales-scoped event;
        ///   • Northern Ireland is touched by Ireland-scoped events that began
        ///     before 1922 (the Famine, the Rising) and by UK-scoped events
        ///     from 1921 on (the Blitz era, 1941 Belfast) — not by the Irish
        ///     Free State's own later events.
        public func touched(by scope: [Region], in year: Int) -> Bool {
            switch self {
            case .britain:
                return scope.contains { $0 == .world || $0 == .europe || Self.greatBritain.contains($0) }
            case .northernIreland:
                return scope.contains { r in
                    switch r {
                    case .world, .europe, .northernIreland: return true
                    case .ireland: return year < 1922
                    case .england, .scotland, .wales, .britain: return year >= 1921
                    default: return false
                    }
                }
            default:
                return scope.contains { $0.covers(self) }
            }
        }

        var isEuropean: Bool {
            switch self {
            case .europe, .britain, .ireland, .northernIreland, .england, .scotland, .wales,
                 .france, .germany, .italy, .netherlands, .otherEurope: return true
            default: return false
            }
        }
    }

    /// One recorded place → its region, or nil when the tables do not know
    /// it (never guessed). "Cork, Ireland" → .ireland; "Lowell, Middlesex,
    /// Massachusetts, USA" → .unitedStates; "Lyon, France" → .france.
    public static func region(ofPlace raw: String?) -> Region? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let base = baseRegion(raw)
        // Belfast / the six counties, only when the place is otherwise Irish,
        // British or unplaced ("Antrim, New Hampshire" stays American).
        if base == nil || base == .ireland || base == .britain, isNorthernIrish(raw) { return .northernIreland }
        return base
    }

    static let northernIrishMarkers: Set<String> = [
        "northern ireland", "ni", "belfast", "antrim", "co antrim", "county antrim", "armagh", "co armagh",
        "county armagh", "co down", "county down", "fermanagh", "co fermanagh", "county fermanagh",
        "londonderry", "co londonderry", "county londonderry", "derry", "co derry", "county derry",
        "tyrone", "co tyrone", "county tyrone", "ulster northern ireland",
    ]

    static func isNorthernIrish(_ raw: String) -> Bool {
        raw.split(separator: ",").contains { northernIrishMarkers.contains(BirthplaceClassifier.normalize(String($0))) }
    }

    static func baseRegion(_ raw: String) -> Region? {
        switch BirthplaceClassifier.region(raw) {
        case .newEngland, .restOfUS, .unitedStatesUnspecified: return .unitedStates
        case .england: return .england
        case .ireland: return .ireland
        case .scotland: return .scotland
        case .wales: return .wales
        case .canada: return .canada
        case .unknown: return nil
        case .other:
            return europeanRegion(of: raw)
        }
    }

    /// "Elsewhere" places, refined by the country classifier.
    static func europeanRegion(of raw: String) -> Region? {
        let place = BirthplaceClassifier.classify(raw)
        switch place.country {
        case "France"?: return .france
        case "Germany"?: return .germany
        case "Italy"?: return .italy
        case "Netherlands"?: return .netherlands
        case BirthplaceClassifier.unitedKingdom?: return .britain   // UK, constituent country not recorded
        default:
            if place.continent == .europe { return .otherEurope }
            // "Europe" / native spellings the region table calls elsewhere.
            let key = BirthplaceClassifier.normalize(raw)
            if key.hasSuffix("france") { return .france }
            if key.hasSuffix("deutschland") { return .germany }
            if key.hasSuffix("italia") { return .italy }
            if key.hasSuffix("nederland") { return .netherlands }
            if key.hasSuffix("europe") { return .otherEurope }
            return place.isUnknown ? nil : .elsewhere
        }
    }
}
