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
            default: return false
            }
        }

        var isEuropean: Bool {
            switch self {
            case .europe, .britain, .ireland, .england, .scotland, .wales,
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
