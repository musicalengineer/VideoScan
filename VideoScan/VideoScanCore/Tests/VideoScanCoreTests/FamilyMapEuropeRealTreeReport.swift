// FamilyMapEuropeRealTreeReport.swift
// SENSOR (read-only, opt-in): resolve every birthplace in Rick's real tree
// and PRINT how the Western Europe stage places it — per country, fine vs
// country-only, and the European strings it could not place. Nothing is
// pinned: the tree changes with every FamilySearch refresh. Never writes
// anything; prints place text and counts only, never a name or an id.
//
//   env VS_REAL_GEDCOM=~/Downloads/familysearch-tree.ged \
//       swift test --package-path VideoScan/VideoScanCore --filter FamilyMapEuropeRealTreeReport

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMapEuropeRealTreeReport")
struct FamilyMapEuropeRealTreeReport {
    @Test func reportOnTheRealTree() throws {
        guard let path = ProcessInfo.processInfo.environment["VS_REAL_GEDCOM"] else {
            print("[europe] set VS_REAL_GEDCOM to run the real-tree report")
            return
        }
        let graph = try #require(GedcomFamilyGraph(fileURL: URL(fileURLWithPath: (path as NSString).expandingTildeInPath)))
        var fine: [FamilyMap.Country: Int] = [:]
        var countryOnly: [FamilyMap.Country: Int] = [:]
        var unresolved: [String: Int] = [:]
        var withPlace = 0
        for person in graph.people.values {
            guard let place = person.birthPlace, FamilyMapTally.hasText(place) else { continue }
            withPlace += 1
            if let hit = BirthplaceUnitResolver.resolve(place) {
                if hit.isCountryOnly { countryOnly[hit.country, default: 0] += 1 } else { fine[hit.country, default: 0] += 1 }
            } else if Self.looksEuropean(place) {
                unresolved[place, default: 0] += 1
            }
        }
        print("[europe] \(graph.people.count) people, \(withPlace) with a birthplace")
        for c in FamilyMap.Country.allCases {
            let f = fine[c] ?? 0, k = countryOnly[c] ?? 0
            guard f + k > 0 else { continue }
            print("[europe] \(c.rawValue) \(c.label): placed \(f + k) (finer \(f), country-only \(k))")
        }
        let total = unresolved.values.reduce(0, +)
        print("[europe] unresolved European-looking strings: \(total) (\(unresolved.count) distinct); top 20:")
        for (place, n) in unresolved.sorted(by: { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }).prefix(20) {
            print("[europe]   \(n)\t\(place)")
        }
    }

    /// A place the classifier puts in continental Europe (or Europe at all,
    /// outside the British Isles), or that names a Western European word.
    static func looksEuropean(_ place: String) -> Bool {
        let c = BirthplaceClassifier.classify(place)
        if c.continent == .europe, c.country != BirthplaceClassifier.unitedKingdom, c.country != "Ireland" { return true }
        let folded = place.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return ["france", "germany", "deutschland", "prussia", "holland", "nederland", "belgi", "europe", "holy roman",
                "italia", "espan", "danmark", "luxemb", "schweiz", "suisse", "osterreich"].contains { folded.contains($0) }
    }
}
