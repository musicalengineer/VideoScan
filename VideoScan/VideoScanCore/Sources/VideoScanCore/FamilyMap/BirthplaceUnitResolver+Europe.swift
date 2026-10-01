// BirthplaceUnitResolver+Europe.swift (VideoScanCore/FamilyMap)
// The Western Europe stage of the family map (GH #227; Rick 2026-09-30:
// "Countries + regions"). The DATA the resolver adds for Europe — the
// tables only; the scan itself is unchanged and lives in
// BirthplaceUnitResolver.swift.
//
// WHAT IS ON THE MAP
//   • France by its 13 CURRENT (2016) metropolitan régions. Every older
//     name a tree carries folds into the région that contains it today:
//       – the 22 pre-2016 régions (Rhône-Alpes + Auvergne → Auvergne-Rhône-
//         Alpes; Basse- / Haute-Normandie → Normandy; Poitou-Charentes,
//         Aquitaine, Limousin → Nouvelle-Aquitaine; Centre → Centre-Val de
//         Loire; Nord-Pas-de-Calais + Picardie → Hauts-de-France; Alsace,
//         Lorraine, Champagne-Ardenne → Grand Est; Languedoc-Roussillon +
//         Midi-Pyrénées → Occitania; Bourgogne + Franche-Comté →
//         Bourgogne-Franche-Comté);
//       – the pre-1790 provinces whose ground lies inside one région today
//         (Brittany, Normandy, Anjou, Touraine, Berry, Poitou, Dauphiné,
//         Languedoc, Provence, Picardy, Artois, Champagne …); Gascony,
//         Guyenne and the old Maine (also a US state) are NOT mapped and
//         fall back to France's outline;
//       – the 96 metropolitan départements (and the pre-1968 Seine /
//         Seine-et-Oise, the old "-Inférieure" names) → their région.
//   • Germany by Land; the Netherlands and Belgium by province (Brussels
//     as its own unit).
//   • Luxembourg, Switzerland, Austria, Denmark, Norway, Sweden, Italy,
//     Spain and Portugal as country outlines only.
//
// JUDGMENT CALLS (also in the stage report for Rick)
//   • Prussia, the German Empire, "Deutschland" → GERMANY, country-only
//     unless a Land resolves to their left — the same "today's flag" policy
//     as a colonial birth under 🇺🇸.
//   • TODAY'S GROUND WINS (Manager ruling 2026-09-30): a historic
//     subregion is placed where it is today, whatever country is written
//     to its right. "Strasbourg, Alsace, Germany" → Grand Est; "Trieste,
//     Austria" / "Bozen, South Tyrol, Austria" → Italy; "Nice, Sardinia" →
//     Provence-Alpes-Côte d'Azur (`europeTodayTokens`). Ground in no mapped
//     country today — East / West Prussia, Danzig, Königsberg, Posen,
//     Silesia, Pomerania / Stettin, Bohemia / Prague, Moravia, Galicia /
//     Lemberg — is nil even with Germany, Prussia or Austria to its right
//     (`europeOutside`). Bare "Prussia" stays Germany; bare "Austria"
//     stays Austria.
//   • NEW-WORLD NAMESAKES are never European: a European name right after
//     "New" / "Nieuw" / "Nueva" / "Nouvelle" / "Neu" is skipped ("New
//     Bavaria, Ohio"), and the colonies are named outright (New Netherland
//     and New Sweden → USA; New Amsterdam → New York; New Spain and New
//     Holland → off the map) (`newWorldColonyTokens`).
//   • "Rhineland" / the Rhine Province spans North Rhine-Westphalia,
//     Rhineland-Palatinate and Saarland → Germany, country-only.
//     "Palatinate" / "Pfalz" → Rhineland-Palatinate; "Upper Palatinate" →
//     Bavaria; "Westphalia" → North Rhine-Westphalia; "Hanover",
//     "Oldenburg", "Brunswick", "East Frisia" → Lower Saxony; "Württemberg",
//     "Baden" → Baden-Württemberg; "Franconia" → Bavaria.
//   • "Holland" is the two Holland provinces → Netherlands, country-only —
//     but bare "Holland" is nil (Holland, Michigan); likewise bare
//     "Flanders" (New Jersey) and "Piedmont" (the Carolinas)
//     (`europeCoarse`). "Brabant" alone (the old duchy: North Brabant AND
//     Belgium) is not a unit; "Vlaanderen" / "Wallonia" → Belgium,
//     country-only (a region, not a province — like Ulster for Ireland).
//     "French Flanders" → Hauts-de-France.
//   • "Limburg" is a province of BOTH the Netherlands and Belgium, and
//     "Luxembourg" is a country AND a Belgian province: each resolves only
//     with the country to its right ("Limburg" alone is nil; "Luxembourg"
//     alone is the country).
//   • The Holy Roman Empire and Austria-Hungary stay recognised-but-off-the-
//     map (BirthplaceClassifier): they span today's borders, so the resolver
//     refuses rather than guesses.
//
// NAMES THAT NEED A COUNTRY. A département ("Lot", "Var", "Nord", "Jura"),
// a Land whose name is also a town in North America ("Berlin", "Hamburg",
// "Bremen", "Hanover", "Mecklenburg", "Brandenburg", "Oldenburg"), "Paris"
// (Texas, Maine, Ontario), "Nice", "Savoy", "Anjou" (a Montréal borough),
// "Centre", "Berry", "Baden", "Zeeland" / "Zealand", "Friesland", "Antwerp"
// (all also North American or Danish places) — each is
// accepted ONLY with a country to its right, exactly like "Middlesex"
// (`europeNeedsCountry` is merged into `ambiguousWithoutCountry`).
//
// Display names (and so keys) are the builder's: English where English
// readers use an English name (Brittany, Normandy, Bavaria, North
// Brabant, East Flanders), the official name otherwise (Île-de-France,
// Grand Est). Native spellings are aliases.
//
// (C++ readers: an `extension` adds members to the existing type, like
// splitting one class's static tables into a second translation unit.)

import Foundation

extension BirthplaceUnitResolver {

    /// One unit with its aliases. `name` is the builder's display name and
    /// so the key (via FamilyMapKey.unitKey); the aliases are accepted on
    /// their own unless they are also listed in `needsCountry`.
    struct EuropeUnit {
        let country: FamilyMap.Country
        let name: String
        let aliases: [String]
        /// Aliases accepted ONLY with this unit's country to their right.
        let needsCountry: [String]
        init(_ country: FamilyMap.Country, _ name: String, _ aliases: [String] = [], needsCountry: [String] = []) {
            self.country = country
            self.name = name
            self.aliases = aliases
            self.needsCountry = needsCountry
        }
    }

    // MARK: France — the 13 régions of 2016

    static let franceRegions: [EuropeUnit] = [
        EuropeUnit(.france, "Auvergne-Rhône-Alpes",
                   ["Auvergne-Rhone-Alpes", "Rhône-Alpes", "Rhone-Alpes", "Auvergne", "Dauphiné", "Dauphine",
                    "Lyonnais", "Bourbonnais", "Forez", "Vivarais", "Beaujolais"],
                   // Savoy is also a town in Berkshire County, Massachusetts.
                   needsCountry: ["Savoy"]),
        EuropeUnit(.france, "Bourgogne-Franche-Comté",
                   ["Bourgogne-Franche-Comte", "Bourgogne", "Burgundy", "Franche-Comté", "Franche-Comte",
                    "Nivernais", "Duchy of Burgundy", "County of Burgundy"]),
        EuropeUnit(.france, "Brittany", ["Bretagne", "Duchy of Brittany", "Province of Brittany"]),
        EuropeUnit(.france, "Centre-Val de Loire",
                   ["Centre Val de Loire", "Touraine", "Orléanais", "Orleanais", "Blésois", "Blesois"],
                   needsCountry: ["Centre", "Berry", "Region Centre"]),
        EuropeUnit(.france, "Corsica", ["Corse"]),
        EuropeUnit(.france, "Grand Est",
                   // Alsace and Lorraine are `europeToday` names (German 1871–1918).
                   ["Grand-Est", "Champagne-Ardenne", "Champagne-Ardennes", "Champagne",
                    "Alsace-Champagne-Ardenne-Lorraine"]),
        EuropeUnit(.france, "Hauts-de-France",
                   ["Hauts de France", "Nord-Pas-de-Calais", "Nord-Pas de Calais", "Picardie", "Picardy",
                    "Nord-Pas-de-Calais-Picardie", "Artois", "French Flanders", "Flandre française",
                    "Flandre francaise", "Pale of Calais", "Calaisis"]),
        EuropeUnit(.france, "Île-de-France",
                   ["Ile-de-France", "Isle-de-France", "l'Île-de-France", "l'Ile-de-France", "Region Parisienne",
                    "Région parisienne"],
                   needsCountry: ["Paris", "Seine", "Seine-et-Oise"]),
        EuropeUnit(.france, "Normandy",
                   ["Normandie", "Basse-Normandie", "Haute-Normandie", "Lower Normandy", "Upper Normandy",
                    "Duchy of Normandy", "Province of Normandy"],
                   needsCountry: ["Seine-Inférieure", "Seine-Inferieure"]),
        EuropeUnit(.france, "Nouvelle-Aquitaine",
                   ["Aquitaine", "Limousin", "Poitou-Charentes", "Poitou", "Aunis", "Saintonge", "Angoumois",
                    "Périgord", "Perigord", "Béarn", "Bearn", "Aquitaine-Limousin-Poitou-Charentes"],
                   needsCountry: ["Charente-Inférieure", "Charente-Inferieure", "Basses-Pyrénées", "Basses-Pyrenees"]),
        EuropeUnit(.france, "Occitania",
                   ["Occitanie", "Languedoc-Roussillon", "Languedoc", "Upper Languedoc", "Lower Languedoc",
                    "Haut-Languedoc", "Bas-Languedoc", "Midi-Pyrénées", "Midi-Pyrenees", "Roussillon", "Quercy",
                    "Rouergue", "Languedoc-Roussillon-Midi-Pyrénées", "Languedoc-Roussillon-Midi-Pyrenees"]),
        EuropeUnit(.france, "Pays de la Loire", ["Pays-de-la-Loire"],
                   needsCountry: ["Anjou", "Loire-Inférieure", "Loire-Inferieure"]),
        EuropeUnit(.france, "Provence-Alpes-Côte d'Azur",
                   ["Provence-Alpes-Côte-d'Azur", "Provence-Alpes-Cote d'Azur", "Provence-Alpes-Cote-d'Azur",
                    "PACA", "Provence", "Côte d'Azur", "Cote d'Azur", "Comtat Venaissin"],
                   // Nice is a `europeToday` name (Sardinian until 1860) and a
                   // town name: it needs a country to its right.
                   needsCountry: ["Basses-Alpes", "Nice", "Nizza"]),
    ]

    /// The 96 metropolitan départements, by région (generated from the same
    /// Natural Earth file the borders are built from, its two typos fixed:
    /// "Seien-et-Marne", "Haute-Rhin"). Each is accepted only with France
    /// to its right — "Lot", "Var", "Nord", "Jura" are words or places
    /// elsewhere.
    static let franceDepartements: [(region: String, departements: [String])] = [
        ("Auvergne-Rhône-Alpes", ["Ain", "Allier", "Ardèche", "Cantal", "Drôme", "Isère", "Loire", "Haute-Loire",
                                  "Puy-de-Dôme", "Rhône", "Savoie", "Haute-Savoie"]),
        ("Bourgogne-Franche-Comté", ["Côte-d'Or", "Doubs", "Jura", "Nièvre", "Haute-Saône", "Saône-et-Loire", "Yonne",
                                    "Territoire de Belfort"]),
        ("Brittany", ["Côtes-d'Armor", "Côtes-du-Nord", "Finistère", "Ille-et-Vilaine", "Morbihan"]),
        ("Centre-Val de Loire", ["Cher", "Eure-et-Loir", "Indre", "Indre-et-Loire", "Loir-et-Cher", "Loiret"]),
        ("Corsica", ["Corse-du-Sud", "Haute-Corse"]),
        ("Grand Est", ["Ardennes", "Aube", "Marne", "Haute-Marne", "Meurthe-et-Moselle", "Meuse", "Moselle", "Bas-Rhin",
                       "Haut-Rhin", "Vosges"]),
        ("Hauts-de-France", ["Aisne", "Nord", "Oise", "Pas-de-Calais", "Somme"]),
        ("Normandy", ["Calvados", "Eure", "Manche", "Orne", "Seine-Maritime"]),
        ("Nouvelle-Aquitaine", ["Charente", "Charente-Maritime", "Corrèze", "Creuse", "Dordogne", "Gironde", "Landes",
                                "Lot-et-Garonne", "Pyrénées-Atlantiques", "Deux-Sèvres", "Vienne", "Haute-Vienne"]),
        ("Occitania", ["Ariège", "Aude", "Aveyron", "Gard", "Haute-Garonne", "Gers", "Hérault", "Lot", "Lozère",
                       "Hautes-Pyrénées", "Pyrénées-Orientales", "Tarn", "Tarn-et-Garonne"]),
        ("Pays de la Loire", ["Loire-Atlantique", "Maine-et-Loire", "Mayenne", "Sarthe", "Vendée"]),
        ("Provence-Alpes-Côte d'Azur", ["Alpes-de-Haute-Provence", "Hautes-Alpes", "Alpes-Maritimes",
                                        "Bouches-du-Rhône", "Var", "Vaucluse"]),
        ("Île-de-France", ["Seine-et-Marne", "Yvelines", "Essonne", "Hauts-de-Seine", "Seine-Saint-Denis",
                           "Val-de-Marne", "Val-d'Oise"]),
    ]

    // MARK: Germany — the 16 Länder

    static let germanStates: [EuropeUnit] = [
        EuropeUnit(.germany, "Baden-Württemberg",
                   ["Baden-Wuerttemberg", "Baden-Wurttemberg", "Württemberg", "Wuerttemberg", "Wurttemberg",
                    "Kingdom of Württemberg", "Kingdom of Wurttemberg", "Duchy of Württemberg", "Grand Duchy of Baden",
                    "Hohenzollern"],
                   needsCountry: ["Baden"]),
        EuropeUnit(.germany, "Bavaria",
                   ["Bayern", "Kingdom of Bavaria", "Upper Bavaria", "Lower Bavaria", "Oberbayern", "Niederbayern",
                    "Franconia", "Franken", "Upper Franconia", "Middle Franconia", "Lower Franconia", "Oberfranken",
                    "Mittelfranken", "Unterfranken", "Upper Palatinate", "Oberpfalz"]),
        EuropeUnit(.germany, "Berlin", needsCountry: ["Berlin"]),
        EuropeUnit(.germany, "Brandenburg", ["Province of Brandenburg", "Mark Brandenburg", "Margraviate of Brandenburg"],
                   needsCountry: ["Brandenburg"]),
        EuropeUnit(.germany, "Bremen", ["Free Hanseatic City of Bremen"], needsCountry: ["Bremen"]),
        EuropeUnit(.germany, "Hamburg", ["Free and Hanseatic City of Hamburg"], needsCountry: ["Hamburg"]),
        EuropeUnit(.germany, "Hesse",
                   ["Hessen", "Hesse-Kassel", "Hesse-Cassel", "Hessen-Kassel", "Hesse-Darmstadt", "Hessen-Darmstadt",
                    "Grand Duchy of Hesse", "Hesse-Nassau", "Hessen-Nassau", "Electorate of Hesse", "Kurhessen"]),
        EuropeUnit(.germany, "Lower Saxony",
                   ["Niedersachsen", "Kingdom of Hanover", "Kingdom of Hannover", "Province of Hanover",
                    "Grand Duchy of Oldenburg", "Duchy of Brunswick", "East Frisia", "East Friesland", "Ostfriesland",
                    "Schaumburg-Lippe"],
                   needsCountry: ["Hanover", "Hannover", "Oldenburg", "Brunswick", "Braunschweig"]),
        EuropeUnit(.germany, "Mecklenburg-Vorpommern",
                   ["Mecklenburg-Western Pomerania", "Mecklenburg-West Pomerania", "Mecklenburg-Schwerin",
                    "Mecklenburg-Strelitz", "Western Pomerania", "Vorpommern"],
                   needsCountry: ["Mecklenburg"]),
        EuropeUnit(.germany, "North Rhine-Westphalia",
                   ["Nordrhein-Westfalen", "North Rhine Westphalia", "Westphalia", "Westfalen", "Province of Westphalia"],
                   needsCountry: ["Lippe"]),
        EuropeUnit(.germany, "Rhineland-Palatinate",
                   ["Rheinland-Pfalz", "Palatinate", "Pfalz", "Rhenish Palatinate", "Rheinpfalz", "Electoral Palatinate",
                    "Kurpfalz", "Rhenish Hesse", "Rheinhessen"]),
        EuropeUnit(.germany, "Saarland", ["Saar Province", "Territory of the Saar Basin"], needsCountry: ["Saar"]),
        EuropeUnit(.germany, "Saxony", ["Sachsen", "Kingdom of Saxony", "Electorate of Saxony", "Free State of Saxony"]),
        EuropeUnit(.germany, "Saxony-Anhalt", ["Sachsen-Anhalt", "Anhalt", "Province of Saxony"]),
        EuropeUnit(.germany, "Schleswig-Holstein", ["Duchy of Holstein"], needsCountry: ["Holstein"]),
        EuropeUnit(.germany, "Thuringia", ["Thüringen", "Thuringen", "Thueringen"]),
    ]

    // MARK: Netherlands — the 12 provinces (Limburg is shared, below)

    static let dutchProvinces: [EuropeUnit] = [
        EuropeUnit(.netherlands, "Drenthe"),
        EuropeUnit(.netherlands, "Flevoland"),
        // Friesland, Zeeland and Antwerp are also North American places
        // (QA P2-D): alone they need their country.
        EuropeUnit(.netherlands, "Friesland", ["Fryslân", "Fryslan", "Vriesland"], needsCountry: ["Friesland"]),
        EuropeUnit(.netherlands, "Gelderland", ["Guelders", "Gelre", "Guelderland"]),
        EuropeUnit(.netherlands, "Groningen"),
        EuropeUnit(.netherlands, "North Brabant", ["Noord-Brabant", "Noordbrabant", "North-Brabant"]),
        EuropeUnit(.netherlands, "North Holland", ["Noord-Holland", "Noordholland", "North-Holland"]),
        EuropeUnit(.netherlands, "Overijssel", ["Overyssel"]),
        EuropeUnit(.netherlands, "South Holland", ["Zuid-Holland", "Zuidholland", "South-Holland"]),
        EuropeUnit(.netherlands, "Utrecht"),
        EuropeUnit(.netherlands, "Zeeland", needsCountry: ["Zeeland", "Zealand"]),
    ]

    // MARK: Belgium — 10 provinces + Brussels (Limburg and Luxembourg are shared, below)

    static let belgianProvinces: [EuropeUnit] = [
        EuropeUnit(.belgium, "Antwerp", ["Antwerpen", "Anvers", "Province of Antwerp"], needsCountry: ["Antwerp"]),
        EuropeUnit(.belgium, "East Flanders", ["Oost-Vlaanderen", "Oostvlaanderen", "Flandre-Orientale",
                                               "Flandre orientale", "East-Flanders"]),
        EuropeUnit(.belgium, "West Flanders", ["West-Vlaanderen", "Westvlaanderen", "Flandre-Occidentale",
                                               "Flandre occidentale", "West-Flanders"]),
        EuropeUnit(.belgium, "Flemish Brabant", ["Vlaams-Brabant", "Brabant flamand"]),
        EuropeUnit(.belgium, "Walloon Brabant", ["Waals-Brabant", "Brabant wallon"]),
        EuropeUnit(.belgium, "Hainaut", ["Henegouwen", "Hennegau", "County of Hainaut", "Province of Hainaut"]),
        EuropeUnit(.belgium, "Liège", ["Liege", "Luik", "Lüttich", "Luttich", "Province of Liège", "Prince-Bishopric of Liège"]),
        EuropeUnit(.belgium, "Namur", ["Namen", "Province of Namur"]),
        EuropeUnit(.belgium, "Brussels", ["Bruxelles", "Brussel", "Brussels-Capital", "Brussels-Capital Region",
                                          "Brussels Capital Region", "Région de Bruxelles-Capitale"]),
    ]

    /// Every European unit with its own aliases (not the shared names).
    static var europeUnits: [EuropeUnit] {
        franceRegions + germanStates + dutchProvinces + belgianProvinces
    }

    // MARK: Countries, their native and historic names

    static let europeCountries: [(FamilyMap.Country, [String])] = [
        (.france, ["France", "Française", "Francaise", "République française", "Republique francaise", "Francia",
                   "Frankreich", "Kingdom of France", "French Republic"]),
        (.germany, ["Germany", "Deutschland", "Allemagne", "Germania", "German Empire", "Deutsches Reich",
                    "Federal Republic of Germany", "West Germany", "East Germany", "German Democratic Republic",
                    "Prussia", "Preussen", "Preußen", "Kingdom of Prussia", "Free State of Prussia",
                    "Rhineland", "Rheinland", "Rhine Province", "Rheinprovinz", "Prussian Rhine Province",
                    "German Confederation"]),
        (.netherlands, ["Netherlands", "The Netherlands", "Nederland", "Pays-Bas", "Niederlande",
                        "Kingdom of the Netherlands", "Dutch Republic", "United Provinces", "Batavian Republic"]),
        (.belgium, ["Belgium", "België", "Belgie", "Belgique", "Belgien", "Kingdom of Belgium",
                    "Vlaanderen", "Flandre", "County of Flanders", "Flemish Region",
                    "Wallonia", "Wallonie", "Wallonië", "Walloon Region", "Spanish Netherlands", "Austrian Netherlands"]),
        (.luxembourg, ["Grand Duchy of Luxembourg", "Lëtzebuerg", "Letzebuerg"]),
        (.switzerland, ["Switzerland", "Schweiz", "Suisse", "Svizzera", "Helvetia", "Swiss Confederation"]),
        (.austria, ["Austria", "Österreich", "Osterreich", "Oesterreich", "Autriche", "Archduchy of Austria"]),
        (.denmark, ["Denmark", "Danmark", "Kingdom of Denmark", "Dänemark"]),
        (.norway, ["Norway", "Norge", "Noreg", "Kingdom of Norway"]),
        (.sweden, ["Sweden", "Sverige", "Kingdom of Sweden"]),
        (.italy, ["Italy", "Italia", "Itália", "Italie", "Kingdom of Italy", "Regno d'Italia"]),
        (.spain, ["Spain", "España", "Espana", "Espanha", "Kingdom of Spain", "Espagne"]),
        (.portugal, ["Portugal", "Kingdom of Portugal"]),
    ]

    // MARK: Where the ground is TODAY (Manager ruling 2026-09-30, QA P1-C)

    /// Ground that is in NO mapped country today. Each ends the scan with
    /// nil EVEN with Germany / Prussia / Austria written to its right:
    /// "Königsberg, East Prussia, Germany" is Kaliningrad, "Prague, Bohemia,
    /// Austria" is Czechia. `except`: the countries where the same name
    /// is a different, mapped place ("Galicia, Spain"). Cities are listed
    /// only where the record usually stops at the city ("Posen, Prussia");
    /// a Land to their right still wins first ("Königsberg, Bayern" is the
    /// Bavarian town).
    static let europeOutside: [(alias: String, except: Set<FamilyMap.Country>)] = [
        ("East Prussia", []), ("West Prussia", []), ("Ostpreussen", []), ("Ostpreußen", []),
        ("Westpreussen", []), ("Westpreußen", []), ("Province of Posen", []), ("Grand Duchy of Posen", []),
        ("Posen", []), ("Danzig", []), ("Free City of Danzig", []), ("Königsberg", []), ("Koenigsberg", []),
        ("Konigsberg", []), ("Memel", []), ("Memelland", []),
        ("Silesia", []), ("Schlesien", []), ("Upper Silesia", []), ("Lower Silesia", []), ("Breslau", []),
        ("Pomerania", []), ("Pommern", []), ("Farther Pomerania", []), ("Hinterpommern", []), ("Stettin", []),
        ("Bohemia", []), ("Böhmen", []), ("Prague", []), ("Prag", []), ("Praha", []), ("Moravia", []), ("Mähren", []),
        ("Galicia", [.spain]), ("Galizien", []), ("Lemberg", []), ("Lwów", []), ("Lwow", []),
    ]

    /// Historic subregions placed where they are TODAY, whatever country is
    /// written to their right: Alsace-Lorraine (German 1871–1918) → Grand
    /// Est; Nice and Savoy (Sardinian until 1860) → France; South Tyrol,
    /// Trentino and Trieste (Austrian until 1918) → Italy; North Schleswig
    /// (Prussian 1864–1920) → Denmark; Eupen-Malmedy → Belgium; Swedish
    /// Pomerania → Mecklenburg-Vorpommern. The card's tooltip still says
    /// what was recorded.
    static func europeTodayTokens() -> [(alias: String, token: Token)] {
        func unit(_ c: FamilyMap.Country, _ name: String) -> Token {
            .today(.unit(c, name: name, key: FamilyMapKey.unitKey(country: c, name: name)))
        }
        func country(_ c: FamilyMap.Country) -> Token { .today(.country(c, searches: [c])) }
        var out: [(String, Token)] = []
        for a in ["Alsace", "Lorraine", "Alsace-Lorraine", "Elsass", "Elsaß", "Lothringen", "Elsass-Lothringen",
                  "Elsaß-Lothringen", "Reichsland Elsass-Lothringen", "Duchy of Lorraine", "Alsace-Moselle"] {
            out.append((a, unit(.france, "Grand Est")))
        }
        for a in ["Nice", "Nizza", "County of Nice", "Comté de Nice"] {
            out.append((a, unit(.france, "Provence-Alpes-Côte d'Azur")))
        }
        for a in ["Savoy", "Savoie", "Duchy of Savoy"] { out.append((a, unit(.france, "Auvergne-Rhône-Alpes"))) }
        for a in ["South Tyrol", "Südtirol", "Sudtirol", "Suedtirol", "Alto Adige", "Bozen", "Bolzano", "Trentino",
                  "Trient", "Trento", "Trieste", "Triest", "Gorizia", "Görz", "Goerz"] {
            out.append((a, country(.italy)))
        }
        for a in ["North Schleswig", "Nordschleswig", "Sønderjylland", "Sonderjylland", "Southern Jutland"] {
            out.append((a, country(.denmark)))
        }
        for a in ["Eupen", "Malmedy", "Eupen-Malmedy"] { out.append((a, country(.belgium))) }
        out.append(("Swedish Pomerania", unit(.germany, "Mecklenburg-Vorpommern")))
        return out
    }

    // MARK: Bare names shared with North America (QA P2-D)

    /// "Holland" (Michigan), "Flanders" (New Jersey), "Piedmont" (the
    /// Carolinas) alone are nil. With their country to the right they are
    /// that country, and to the LEFT of them a province of their country
    /// still places ("Leiden, Zuid-Holland, Holland") — a coarse token
    /// narrows the search like "United Kingdom" does, and shades nothing
    /// by itself.
    static let europeCoarse: [(alias: String, country: FamilyMap.Country)] = [
        ("Holland", .netherlands), ("Flanders", .belgium), ("Piedmont", .italy),
    ]

    // MARK: New-World colonies named after Europe (QA P1-B)

    /// Words that make the next name a NEW-WORLD namesake: "New Bavaria",
    /// "Nieuw Nederland", "Nueva España", "Neu Braunfels". A European unit
    /// or country right after one of them is never placed in Europe (the
    /// scan's phrase loop checks the token before each European match).
    static let newWorldPrefixes: Set<String> = ["new", "nieuw", "nieuwe", "nueva", "nuevo", "nouvelle", "nouveau",
                                                "neu", "neue", "nova"]

    /// Does this token place anyone in Western Europe?
    static func isEuropean(_ token: Token) -> Bool {
        switch token {
        case .unit(let c, _, _), .country(let c, _): return c.isWesternEurope
        case .alternatives(let options): return options.contains(where: isEuropean)
        case .today(let inner): return isEuropean(inner)
        case .coarse(let set): return set.contains { $0.isWesternEurope }
        case .foreign, .outside: return false
        }
    }

    /// Recognised explicitly so their European namesake never matches:
    /// New Netherland / New Sweden span today's states (country-only USA,
    /// like "New England"); New Amsterdam, New Utrecht and German Flatts
    /// are New York; Fort Christina is Wilmington, Delaware; New Spain and
    /// New Holland (Dutch Brazil, old Australia) are off the map.
    static func newWorldColonyTokens() -> [(alias: String, token: Token)] {
        func state(_ name: String) -> Token {
            .unit(.unitedStates, name: name, key: FamilyMapKey.unitKey(country: .unitedStates, name: name))
        }
        let usa = Token.country(.unitedStates, searches: [.unitedStates])
        return [
            ("New Sweden", usa), ("New Sweden Colony", usa), ("Nya Sverige", usa),
            ("Nieuw Nederland", usa), ("Nieuw-Nederland", usa), ("Nieuw Nederlandt", usa),
            ("New Amsterdam", state("New York")), ("Nieuw Amsterdam", state("New York")),
            ("New Utrecht", state("New York")), ("Germany Flats", state("New York")),
            ("German Flats", state("New York")), ("German Flatts", state("New York")),
            ("Fort Christina", state("Delaware")),
            ("New Spain", .foreign), ("Nueva España", .foreign), ("Viceroyalty of New Spain", .foreign),
            ("New Holland", .foreign),
        ]
    }

    /// Unit names shared by two countries — accepted only when the country
    /// to their right says which ("Limburg, Netherlands" / "Limburg,
    /// Belgium"); "Luxembourg" alone is the COUNTRY, with Belgium to its
    /// right the province.
    static func europeSharedTokens() -> [(alias: String, token: Token)] {
        func unit(_ c: FamilyMap.Country, _ name: String) -> Token {
            .unit(c, name: name, key: FamilyMapKey.unitKey(country: c, name: name))
        }
        let limburg = Token.alternatives([unit(.netherlands, "Limburg"), unit(.belgium, "Limburg")])
        let luxembourg = Token.alternatives([.country(.luxembourg, searches: [.luxembourg]), unit(.belgium, "Luxembourg")])
        return [("Limburg", limburg), ("Limbourg", limburg),
                ("Luxembourg", luxembourg), ("Luxemburg", luxembourg)]
    }

    /// Normalised keys accepted only with a country to their right: every
    /// `needsCountry` alias and every département, in all the hyphen forms
    /// `aliasKeys` enters them under.
    static let europeNeedsCountry: Set<String> = {
        var s = Set<String>()
        for u in europeUnits { for a in u.needsCountry { s.formUnion(aliasKeys(a)) } }
        for (_, names) in franceDepartements { for d in names { s.formUnion(aliasKeys(d)) } }
        return s
    }()

    /// The classifier's present-day country name → the map's country, for
    /// the merge at the end of `tables` (so the classifier's historical
    /// entries — "bavaria" … "sicily" — land on the right country when the
    /// Europe tables above have no finer entry).
    static let classifierEuropeanCountries: [String: FamilyMap.Country] = [
        "France": .france, "Germany": .germany, "Netherlands": .netherlands, "Belgium": .belgium,
        "Luxembourg": .luxembourg, "Switzerland": .switzerland, "Austria": .austria, "Denmark": .denmark,
        "Norway": .norway, "Sweden": .sweden, "Italy": .italy, "Spain": .spain, "Portugal": .portugal,
    ]
}
