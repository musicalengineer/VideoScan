// FamilyMapEuropeTests.swift
// The Western Europe stage of the family map (GH #227; Rick 2026-09-30:
// "Countries + regions"). Five dimensions:
//   LOGIC     every country / région / Land / province spelling the real
//             tree carries (generic places, no names) → its key; the old
//             French régions, provinces and départements fold to the 13
//             current régions; the refusals ("England or Wales or France",
//             a shared "Limburg" alone, a bare "Paris").
//   SCALE     100k synthetic records with European places through the
//             resolver under a TimingBudget (thread CPU, load-aware).
//   ISOLATION the resolver reads no global state: concurrent resolution
//             agrees with serial, and its source names no defaults / file /
//             environment / bundle API.
//   SENSOR    the old→new région rollup and the OR refusal are pinned; the
//             key set has exactly 13 French keys; the camera rule frames
//             Europe without changing a non-European tree's box.
//   MEDIA     n/a (no media files).
// Pure — no bundled file, no network (FamilyMapBundledDataTests reads the
// real borders).

import Foundation
import Testing
@testable import VideoScanCore

@Suite("FamilyMap Western Europe (#227)")
struct FamilyMapEuropeTests {

    typealias R = BirthplaceUnitResolver

    // MARK: Logic — the spellings → keys

    /// Place → expected key; a bare country key means country-only. The
    /// shapes are the ones in the real tree (2026-09-30 survey), with
    /// generic towns.
    static let table: [(place: String, key: String)] = [
        // ---- France, the country, every way it is written ----------------
        ("France", "fra"), ("FRANCE", "fra"), ("France.", "fra"), ("france", "fra"),
        ("Of France", "fra"), ("Kingdom of France", "fra"), ("Vendome France", "fra"),
        ("Francia", "fra"), ("Some Village, France", "fra"),
        // ---- the 13 current régions, native and English -------------------
        ("Lyon, Rhône, Auvergne-Rhône-Alpes, France", "fra-auvergne-rhone-alpes"),
        ("Auvergne-Rhone-Alpes, France", "fra-auvergne-rhone-alpes"),
        ("Auvergne-Rhône-Alpes, Française", "fra-auvergne-rhone-alpes"),
        ("Auvergne-Rhône-Alpes, Francia", "fra-auvergne-rhone-alpes"),
        ("Nouvelle-Aquitaine, France", "fra-nouvelle-aquitaine"),
        ("Île-de-France, France", "fra-ile-de-france"),
        ("Ile-de-France, France", "fra-ile-de-france"),
        ("Ile-de-France, FRANCE", "fra-ile-de-france"),
        ("l'Ile-de-France, France", "fra-ile-de-france"),
        ("Centre-Val de Loire, France", "fra-centre-val-de-loire"),
        ("Centre-Val de Loire, FRANCE", "fra-centre-val-de-loire"),
        ("Centre-Val de Loire, France.", "fra-centre-val-de-loire"),
        ("Hauts-de-France, France", "fra-hauts-de-france"),
        ("Occitanie, France", "fra-occitania"),
        ("Pays de la Loire, France", "fra-pays-de-la-loire"),
        ("Grand Est, FRANCE", "fra-grand-est"),
        ("Bourgogne-Franche-Comté, France", "fra-bourgogne-franche-comte"),
        ("Provence-Alpes-Côte d'Azur, France", "fra-provence-alpes-cote-d-azur"),
        ("Brittany, France", "fra-brittany"), ("Bretagne, France", "fra-brittany"),
        ("Normandy, France", "fra-normandy"), ("Normandie", "fra-normandy"),
        ("Corse, France", "fra-corsica"),
        // ---- the old 22 régions (pre-2016) fold into today's 13 -----------
        ("Rhône-Alpes, France", "fra-auvergne-rhone-alpes"),
        ("Rhone-Alpes, France", "fra-auvergne-rhone-alpes"),
        ("Rhône-Alpes (Région), France", "fra-auvergne-rhone-alpes"),
        ("Auvergne, France", "fra-auvergne-rhone-alpes"),
        ("Basse-Normandie, France.", "fra-normandy"),
        ("Haute-Normandie, France", "fra-normandy"),
        ("Lower Normandy, France", "fra-normandy"),
        ("Poitou-Charentes, France", "fra-nouvelle-aquitaine"),
        ("Poitou-Charentes, Kingdom of France", "fra-nouvelle-aquitaine"),
        ("Aquitaine, France", "fra-nouvelle-aquitaine"),
        ("Limousin, France", "fra-nouvelle-aquitaine"),
        ("Centre, France", "fra-centre-val-de-loire"),
        ("Nord-Pas-de-Calais, France", "fra-hauts-de-france"),
        ("Picardie, France", "fra-hauts-de-france"),
        ("Languedoc-Roussillon, France", "fra-occitania"),
        ("Midi-Pyrénées, France", "fra-occitania"),
        ("Midi-Pyrenees, France", "fra-occitania"),
        ("Bourgogne, France", "fra-bourgogne-franche-comte"),
        ("Franche-Comté, France", "fra-bourgogne-franche-comte"),
        ("Alsace, France", "fra-grand-est"),
        ("Lorraine, France", "fra-grand-est"),
        ("Champagne-Ardenne, France", "fra-grand-est"),
        // ---- pre-1790 provinces ------------------------------------------
        ("Picardy, France", "fra-hauts-de-france"),
        ("French Flanders, France", "fra-hauts-de-france"),
        ("Pale of Calais, France", "fra-hauts-de-france"),
        ("Anjou, France", "fra-pays-de-la-loire"),
        ("Touraine, France", "fra-centre-val-de-loire"),
        ("Berry, France", "fra-centre-val-de-loire"),
        ("Poitou, France", "fra-nouvelle-aquitaine"),
        ("Dauphiné, France", "fra-auvergne-rhone-alpes"),
        ("Languedoc, France", "fra-occitania"),
        ("Upper Languedoc, France", "fra-occitania"),
        ("Provence, France", "fra-provence-alpes-cote-d-azur"),
        ("Burgundy, France", "fra-bourgogne-franche-comte"),
        // ---- départements (with France to their right) -------------------
        ("Seine-Maritime, France", "fra-normandy"),
        ("Haute-Loire, France", "fra-auvergne-rhone-alpes"),
        ("Corrèze, France", "fra-nouvelle-aquitaine"),
        ("Deux Sevres, France", "fra-nouvelle-aquitaine"),
        ("Deux-Sèvres, France", "fra-nouvelle-aquitaine"),
        ("Vienne, France", "fra-nouvelle-aquitaine"),
        ("Gard, France", "fra-occitania"),
        ("Lot, France", "fra-occitania"),
        ("Puy-de-Dôme, France", "fra-auvergne-rhone-alpes"),
        ("Cher, France", "fra-centre-val-de-loire"),
        ("Ille-et-Vilaine, France", "fra-brittany"),
        ("Seine-Et-Marne, France", "fra-ile-de-france"),
        ("Seine-et-Oise, France", "fra-ile-de-france"),
        ("Corse-du-Sud, France", "fra-corsica"),
        ("Paris, France", "fra-ile-de-france"),
        ("Paris, Paris, Île-de-France, France", "fra-ile-de-france"),

        // ---- Germany -------------------------------------------------------
        ("Germany", "deu"), ("Deutschland", "deu"), ("Some Town, Germany", "deu"),
        ("Prussia", "deu"), ("Prussia, Germany", "deu"),
        ("Koblenz, Rhineland, Prussia", "deu"),
        ("Rhineland, Prussia", "deu"),
        ("Württemberg, Germany", "deu-baden-wurttemberg"),
        ("Baden-Württemberg, Germany", "deu-baden-wurttemberg"),
        ("Baden-Wuerttemberg, Germany", "deu-baden-wurttemberg"),
        ("Baden, Germany", "deu-baden-wurttemberg"),
        ("Bavaria, Germany", "deu-bavaria"), ("Bayern", "deu-bavaria"),
        ("Rhineland-Palatinate, Germany", "deu-rhineland-palatinate"),
        ("Rheinland-Pfalz, Deutschland", "deu-rhineland-palatinate"),
        ("Pfalz, Germany", "deu-rhineland-palatinate"),
        ("North Rhine-Westphalia, Germany", "deu-north-rhine-westphalia"),
        ("Westphalia, Germany", "deu-north-rhine-westphalia"),
        ("Niedersachsen, Germany", "deu-lower-saxony"),
        ("Hanover, Germany", "deu-lower-saxony"),
        ("Saarland, Deutschland", "deu-saarland"),
        ("Hesse, Germany", "deu-hesse"),
        ("Berlin, Germany", "deu-berlin"),
        ("Hamburg, Germany", "deu-hamburg"),
        ("Stuttgart, Württemberg", "deu-baden-wurttemberg"),

        // ---- Netherlands ---------------------------------------------------
        ("Netherlands", "nld"), ("Nederland", "nld"), ("Holland, Netherlands", "nld"),  // bare "Holland" is nil (Holland, MI)
        ("Noord-Brabant, Nederland", "nld-north-brabant"),
        ("North Brabant, Netherlands", "nld-north-brabant"),
        ("Bergen Op Zoom (Noord-Brabant) Nl", "nld-north-brabant"),
        ("Zeeland, Netherlands", "nld-zeeland"),
        ("Limburg, Netherlands", "nld-limburg"),
        ("Zuid-Holland, Nederland", "nld-south-holland"),

        // ---- Belgium -------------------------------------------------------
        ("Belgium", "bel"), ("België", "bel"), ("Belgique", "bel"),
        ("Hainaut, Belgium", "bel-hainaut"),
        ("East Flanders, Belgium", "bel-east-flanders"),
        ("Oost-Vlaanderen, Belgium", "bel-east-flanders"),
        ("Brabant, Belgium", "bel"),
        ("Vlaanderen, België", "bel"),
        ("Wallonië, België", "bel"),
        ("Ghent, County of Flanders", "bel"),
        ("Limburg, Belgium", "bel-limburg"),
        ("Luxembourg, Belgium", "bel-luxembourg"),
        ("Liège, Belgium", "bel-liege"),
        ("Brussels, Belgium", "bel-brussels"),

        // ---- outline-only countries -------------------------------------
        ("Luxembourg", "lux"),
        ("Denmark", "dnk"), ("Thisted, Denmark", "dnk"), ("Danmark", "dnk"),
        ("Italy", "ita"), ("Italia", "ita"), ("Puglia, Itália", "ita"), ("Napoli, Italy", "ita"),
        ("Sicily, Italy", "ita"), ("Palermo, Sicily", "ita"),
        ("Spain", "esp"), ("España", "esp"), ("Castilla-La Mancha, Spain", "esp"),
        ("Norway", "nor"), ("Rogaland, Norway", "nor"),
        ("Switzerland", "che"), ("Austria", "aut"), ("Sweden", "swe"),
        ("Portugal", "prt"), ("Aveiro, Portugal", "prt"),
    ]

    @Test func everyEuropeanSpellingResolvesToItsUnit() {
        for row in Self.table {
            let hit = R.resolve(row.place)
            #expect(hit?.unitKey == row.key, "\(row.place) → \(hit?.unitKey ?? "nil"), expected \(row.key)")
            guard let hit else { continue }
            #expect(hit.isCountryOnly == FamilyMapKey.isCountryKey(row.key), "\(row.place)")
            #expect(hit.country == FamilyMapKey.country(of: row.key), "\(row.place)")
            #expect(hit.kind == (hit.isCountryOnly ? .country : hit.country.unitKind), "\(row.place)")
        }
    }

    // MARK: Logic — refusals

    @Test(arguments: [
        // Alternatives: never a guess between two places.
        "ENGLAND OR Wales or France",
        "England or France",
        "England Or Wales",
        "Paris or Lyon, France",
        "Normandy or Brittany, France",
        // Ground that spans today's borders.
        "Hainaut, Holy Roman Empire",
        "Holy Roman Empire",
        "Königsberg, East Prussia",
        "Stettin, Pomerania",
        // A shared or ambiguous name with no country to its right.
        "Limburg", "Holland", "Flanders", "Paris", "Berlin", "Hanover", "Lot", "Nord", "Vienne", "Savoy", "Anjou", "Centre", "Baden",
        // Off the map.
        "Warsaw, Poland", "Europe", "Western Europe, Europe", "Fort-de-France, Martinique",
    ])
    func refusedPlacesAreNil(_ place: String) {
        #expect(R.resolve(place) == nil, "\(place) → \(R.resolve(place)?.unitKey ?? "nil")")
    }

    /// A US place with a European name keeps its US meaning; the word "or"
    /// that is really Oregon or part of "Côte d'Or" is not an alternative.
    @Test func americanPlacesWithEuropeanNamesAndHarmlessOrs() {
        #expect(R.resolve("Paris, Texas")?.unitKey == "usa-texas")
        #expect(R.resolve("Berlin, Hartford, Connecticut")?.unitKey == "usa-connecticut")
        #expect(R.resolve("Hanover, Grafton, New Hampshire, United States")?.unitKey == "usa-new-hampshire")
        #expect(R.resolve("Savoy, Berkshire, Massachusetts")?.unitKey == "usa-massachusetts")
        #expect(R.resolve("Holland, Ottawa, Michigan")?.unitKey == "usa-michigan")
        #expect(R.resolve("Portland, OR")?.unitKey == "usa-oregon")
        #expect(R.resolve("Portland OR USA")?.unitKey == "usa-oregon")
        #expect(R.resolve("Dijon, Côte-d'Or, France")?.unitKey == "fra-bourgogne-franche-comte")
        #expect(R.resolve("Beaune, Côte d Or, France") != nil, "'d Or' is not an alternative")
        // The established countries still win over a European token to their left.
        #expect(R.resolve("France, England")?.unitKey == "eng")
        #expect(R.resolve("Normandy, England")?.unitKey == "eng", "a French région is no unit of England")
        #expect(R.resolve("Quebec, France, Canada")?.unitKey == "can-quebec")
    }

    /// "Limburg" is a Dutch AND a Belgian province; "Luxembourg" is a
    /// country AND a Belgian province. The country to the right decides.
    @Test func sharedNamesAreDecidedByTheirCountry() {
        #expect(R.resolve("Maastricht, Limburg, Netherlands")?.unitKey == "nld-limburg")
        #expect(R.resolve("Hasselt, Limburg, Belgium")?.unitKey == "bel-limburg")
        #expect(R.resolve("Limburg") == nil)
        #expect(R.resolve("Limburg, Germany")?.unitKey == "deu", "no Limburg unit of Germany: country-only")
        #expect(R.resolve("Arlon, Luxembourg, Belgium")?.unitKey == "bel-luxembourg")
        #expect(R.resolve("Luxembourg")?.unitKey == "lux")
        #expect(R.resolve("Luxemburg")?.unitKey == "lux")
        #expect(R.resolve("Grand Duchy of Luxembourg")?.unitKey == "lux")
    }

    // MARK: Sensors

    /// Pins the France rollup: the 22 pre-2016 régions each fold into the
    /// 2016 région that contains them, and France can only ever produce the
    /// 13 current keys (never "fra-rhone-alpes").
    @Test func oldFrenchRegionsRollUpToTheCurrentThirteen() {
        let rollup: [String: String] = [
            "Alsace": "fra-grand-est", "Aquitaine": "fra-nouvelle-aquitaine", "Auvergne": "fra-auvergne-rhone-alpes",
            "Basse-Normandie": "fra-normandy", "Bourgogne": "fra-bourgogne-franche-comte", "Bretagne": "fra-brittany",
            "Centre": "fra-centre-val-de-loire", "Champagne-Ardenne": "fra-grand-est", "Corse": "fra-corsica",
            "Franche-Comté": "fra-bourgogne-franche-comte", "Haute-Normandie": "fra-normandy",
            "Île-de-France": "fra-ile-de-france", "Languedoc-Roussillon": "fra-occitania",
            "Limousin": "fra-nouvelle-aquitaine", "Lorraine": "fra-grand-est", "Midi-Pyrénées": "fra-occitania",
            "Nord-Pas-de-Calais": "fra-hauts-de-france", "Pays de la Loire": "fra-pays-de-la-loire",
            "Picardie": "fra-hauts-de-france", "Poitou-Charentes": "fra-nouvelle-aquitaine",
            "Provence-Alpes-Côte d'Azur": "fra-provence-alpes-cote-d-azur", "Rhône-Alpes": "fra-auvergne-rhone-alpes",
        ]
        #expect(rollup.count == 22)
        for (old, key) in rollup {
            #expect(R.resolve("\(old), France")?.unitKey == key, "\(old) → \(R.resolve("\(old), France")?.unitKey ?? "nil")")
        }
        let current: Set<String> = [
            "fra-auvergne-rhone-alpes", "fra-bourgogne-franche-comte", "fra-brittany", "fra-centre-val-de-loire",
            "fra-corsica", "fra-grand-est", "fra-hauts-de-france", "fra-ile-de-france", "fra-normandy",
            "fra-nouvelle-aquitaine", "fra-occitania", "fra-pays-de-la-loire", "fra-provence-alpes-cote-d-azur",
        ]
        #expect(Set(R.allUnitKeys.filter { $0.hasPrefix("fra-") }) == current)
        // Every one of the 96 départements reaches one of them.
        var departements = 0
        for (region, names) in R.franceDepartements {
            let key = FamilyMapKey.unitKey(country: .france, name: region)
            #expect(current.contains(key), "\(region)")
            for d in names {
                departements += 1
                #expect(R.resolve("\(d), France")?.unitKey == key, "\(d) → \(R.resolve("\(d), France")?.unitKey ?? "nil")")
            }
        }
        // 96 metropolitan départements, less Paris (an alias of Île-de-France
        // itself, needing the country), plus the pre-1990 name Côtes-du-Nord.
        #expect(departements == 96)
        #expect(R.resolve("Paris, France")?.unitKey == "fra-ile-de-france")
    }

    /// Pins the "OR" refusal at the real string, case variants included.
    @Test func theAlternativesRefusalIsPinned() {
        #expect(R.resolve("ENGLAND OR Wales or France") == nil)
        #expect(R.resolve("england or wales or france") == nil)
        #expect(R.resolve("Kent, England or Wales") == nil)
        // The same places without the alternative do resolve.
        #expect(R.resolve("England") != nil && R.resolve("Wales") != nil && R.resolve("France") != nil)
    }

    /// Key sanity for the European units: every key the resolver can emit
    /// for Europe is `<iso3>-<slug(name)>`, the builder's one rule.
    @Test func europeanKeysFollowTheOneKeyRule() {
        for u in R.europeUnits {
            let key = FamilyMapKey.unitKey(country: u.country, name: u.name)
            #expect(R.allUnitKeys.contains(key), "\(key)")
            #expect(key.hasPrefix(u.country.key + "-"))
            #expect(key == FamilyMapKey.slug(key), "\(key) is slug-shaped")
        }
        #expect(FamilyMapKey.unitKey(country: .germany, name: "Baden-Württemberg") == "deu-baden-wurttemberg")
        #expect(FamilyMapKey.unitKey(country: .belgium, name: "Hainaut") == "bel-hainaut")
        #expect(FamilyMapKey.unitKey(country: .netherlands, name: "North Brabant") == "nld-north-brabant")
        #expect(FamilyMap.Country.france.unitKind == .region && FamilyMap.Country.germany.unitKind == .state)
        #expect(FamilyMap.Country.netherlands.unitKind == .province && FamilyMap.Country.belgium.unitKind == .province)
        #expect(!FamilyMap.Country.italy.hasSubdivisions && FamilyMap.Country.france.hasSubdivisions)
        #expect(FamilyMap.Country.allCases.filter(\.isWesternEurope).count == 13)
    }

    // MARK: Camera — Europe joins the frame, nothing else changes

    static func square(_ key: String, _ country: FamilyMap.Country, _ kind: FamilyMap.UnitKind,
                       lat: ClosedRange<Double>, lon: ClosedRange<Double>) -> FamilyMapUnits.Unit {
        let ring = [FamilyMap.Coordinate(latitude: lat.lowerBound, longitude: lon.lowerBound),
                    FamilyMap.Coordinate(latitude: lat.lowerBound, longitude: lon.upperBound),
                    FamilyMap.Coordinate(latitude: lat.upperBound, longitude: lon.upperBound),
                    FamilyMap.Coordinate(latitude: lat.upperBound, longitude: lon.lowerBound)]
        return FamilyMapUnits.Unit(key: key, name: key, country: country, kind: kind, polygons: [FamilyMapUnits.Polygon(outer: ring)])
    }

    static let cameraUnits = FamilyMapUnits(units: [
        square("eng", .england, .country, lat: 50...56, lon: -6...2),
        square("eng-yorkshire", .england, .county, lat: 53...55, lon: -2...0),
        square("usa", .unitedStates, .country, lat: 25...49, lon: -125...(-66)),
        square("usa-massachusetts", .unitedStates, .state, lat: 41.5...43, lon: -73.5...(-70)),
        square("fra", .france, .country, lat: 42...51, lon: -5...8),
        square("fra-normandy", .france, .region, lat: 48...50, lon: -2...2),
        square("ita", .italy, .country, lat: 36...47, lon: 6...19),
        square("deu", .germany, .country, lat: 47...55, lon: 6...15),
    ])

    @Test func theCameraIncludesEuropeOnlyWhenEuropeHasPeople() throws {
        let u = Self.cameraUnits
        // Trees without Europe: exactly the old rule (fine units beat outlines).
        let legacy = try #require(u.coverage(for: ["eng", "eng-yorkshire", "usa", "usa-massachusetts"]))
        #expect(legacy.minLongitude == -73.5 && legacy.maxLongitude == 0 && legacy.maxLatitude == 55)
        // Italy (outline-only) beside Yorkshire: Italy joins the frame.
        let withItaly = try #require(u.coverage(for: ["eng-yorkshire", "ita"]))
        #expect(withItaly.maxLongitude == 19 && withItaly.minLatitude == 36 && withItaly.minLongitude == -2)
        // France country-only beside a counted Normandy: Normandy frames France.
        let france = try #require(u.coverage(for: ["eng-yorkshire", "fra", "fra-normandy"]))
        #expect(france.maxLongitude == 2 && france.minLatitude == 48, "the région, not the outline: \(france)")
        // Germany country-only (Prussia) with nothing finer: the outline.
        let prussia = try #require(u.coverage(for: ["deu"]))
        #expect(prussia == u.unit(forKey: "deu")?.cameraBox)
        // A European outline never displaces the legacy fine units.
        let both = try #require(u.coverage(for: ["eng", "eng-yorkshire", "ita"]))
        #expect(both.minLongitude == -2, "Yorkshire still the western edge, England's outline still ignored")
    }

    // MARK: Isolation

    /// The resolver is pure: the same answers from 8 concurrent tasks as
    /// from one, and its sources name no defaults, file, environment or
    /// bundle API that could make an answer depend on the machine.
    @Test func theResolverReadsNoGlobalState() async throws {
        let places = Self.table.map(\.place)
        let serial = places.map { R.resolve($0)?.unitKey }
        let results = await withTaskGroup(of: [String?].self) { group in
            for _ in 0..<8 { group.addTask { places.map { R.resolve($0)?.unitKey } } }
            var all: [[String?]] = []
            for await r in group { all.append(r) }
            return all
        }
        #expect(results.count == 8)
        for r in results { #expect(r == serial) }

        let dir = URL(fileURLWithPath: #filePath).deletingLastPathComponent()   // …/Tests/VideoScanCoreTests
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/VideoScanCore/FamilyMap")
        for name in ["BirthplaceUnitResolver.swift", "BirthplaceUnitResolver+Europe.swift"] {
            let src = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            for forbidden in ["UserDefaults", "FileManager", "ProcessInfo", "Bundle.", "URLSession", "Locale.current",
                              "getenv", "NSHomeDirectory"] {
                #expect(!src.contains(forbidden), "\(name) must not use \(forbidden)")
            }
        }
    }

    // MARK: Scale — 100k records with European places

    /// 100k birthplaces (European spellings + the original mix, the raw
    /// string varied so nothing is memoised) through the resolver. Thread
    /// CPU time against a load-aware Debug ceiling (GH #208), never flat
    /// wall clock: the CI runner is a 3-core VM.
    @Test func oneHundredThousandEuropeanPlacesUnderBudget() {
        let places = Self.table.map(\.place) + [
            "Sheffield, Yorkshire, England", "Boston, Suffolk, Massachusetts Bay Colony, British Colonial America",
            "Warsaw, Poland", "ENGLAND OR Wales or France", "", "Somewhere",
        ]
        let n = 100_000
        let inputs: [String] = (0..<n).map { i in
            let p = places[i % places.count]
            return i % 3 == 0 ? "Hamlet \(i), " + p : p
        }
        _ = R.allUnitKeys   // the tables are built once, outside the measured loop
        var resolved = 0
        var wall: Duration = .zero
        let cpu = TimingBudget.measureThreadCPUTime {
            wall = ContinuousClock().measure {
                for s in inputs where R.resolve(s) != nil { resolved += 1 }
            }
        }
        // Measured 2026-09-30 (M4 Max, Debug, quiet): see the printed line;
        // the ceiling is ~3× that.
        let ceiling = TimingBudget.loadAwareDebugCeiling(.milliseconds(900))
        print("[family-map] resolve 100k European: cpu \(cpu), wall \(wall), \(resolved) resolved (\(TimingBudget.loadDescription()))")
        #expect(cpu < ceiling, "100k resolves took \(cpu) cpu / \(wall) wall, ceiling \(ceiling) (\(TimingBudget.loadDescription()))")
        #expect(resolved > n * 9 / 10, "\(resolved) of \(n)")
    }
}
