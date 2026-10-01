// HistoricalTimeline.swift (VideoScanCore)
// The offline table of "interesting times", ~1600–2000 (GH #238 stage 1,
// Rick 2026-10-01: "who was alive during interesting times").
//
// Curated, modest, and DATA: one row per event, year precision, with the
// region(s) it touched, a kind, an interest weight (1 = footnote … 5 =
// everyone's family story mentions it) and a source note. The package
// ships no resource bundles today (Package.swift has no `resources:`), so
// the table is a Swift literal — the same choice WorldKnowledge made.
//
// Rules for adding a row:
//   • years are the commonly cited span (start of hostilities → end; for a
//     one-day event start == end);
//   • scope lists the places whose families LIVED it, not every country
//     that had an opinion — `.world` only for events that reached
//     everyone (the world wars, the 1918 flu, the Depression, the moon);
//   • the source note names a standard reference a reader can check;
//   • ids are stable (a stored decoration refers to them) — never reuse
//     or rename one; retire a row by deleting it and bumping
//     `LifeAndTimes.version`.
//
// Memory: ~100 small structs, built once (a `static let` is lazily
// initialised exactly once, thread-safely — C++ "magic static").

import Foundation

extension LifeAndTimes {

    public enum EventKind: String, Sendable, Codable, CaseIterable, Hashable {
        case war
        case famine
        case epidemic
        case migration
        case invention        // an invention or a famous "first"
        case disaster
        case politics         // a law, a declaration, an assassination
        case economy          // depressions, prohibition, gold rushes
    }

    public struct HistoricalEvent: Sendable, Codable, Hashable, Identifiable {
        /// Stable key (stored decorations refer to it).
        public let id: String
        /// Short name: "Great Famine".
        public let name: String
        /// How a sentence names it: "the Great Famine in Ireland".
        public let phrase: String
        public let startYear: Int
        public let endYear: Int
        public let regions: [Region]
        public let kind: EventKind
        /// 1 (footnote) … 5 (every family story mentions it).
        public let weight: Int
        /// Where a reader can check the dates.
        public let source: String
        /// The larger event this one is an episode of ("pearl-harbor" →
        /// "ww2"). Ranking keeps one line per family unless the episode is
        /// a regional event that touched the person's own place and the
        /// parent is worldwide (the Blitz for a Londoner).
        public let partOf: String?

        public init(id: String, name: String, phrase: String, startYear: Int, endYear: Int,
                    regions: [Region], kind: EventKind, weight: Int, source: String, partOf: String? = nil) {
            self.id = id
            self.name = name
            self.phrase = phrase
            self.startYear = startYear
            self.endYear = max(startYear, endYear)
            self.regions = regions
            self.kind = kind
            self.weight = min(5, max(1, weight))
            self.source = source
            self.partOf = partOf
        }

        /// The family key ranking de-duplicates on.
        var family: String { partOf ?? id }

        public var isSingleYear: Bool { startYear == endYear }
        /// "1845–1852" or "1912".
        public var yearsLabel: String { isSingleYear ? "\(startYear)" : "\(startYear)–\(endYear)" }

        /// True when the event touched someone in `place`.
        public func touches(_ place: Region) -> Bool { regions.contains { $0.covers(place) } }
        public var isWorldwide: Bool { regions.contains(.world) }
    }

    /// The curated table. Chronological by start year.
    public static let timeline: [HistoricalEvent] = HistoricalTimeline.rows

    /// Lookup by id.
    public static func event(id: String) -> HistoricalEvent? { HistoricalTimeline.byID[id] }
}

enum HistoricalTimeline {
    typealias E = LifeAndTimes.HistoricalEvent
    typealias R = LifeAndTimes.Region

    static let uk: [R] = [.england, .scotland, .wales]
    static let ukAndIreland: [R] = [.england, .scotland, .wales, .ireland]

    static let byID: [String: E] = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })

    /// Episodes of a larger event (see `HistoricalEvent.partOf`).
    static let parents: [String: String] = [
        "boston-massacre": "american-revolution", "boston-tea-party": "american-revolution",
        "declaration-of-independence": "american-revolution", "loyalist-exodus": "american-revolution",
        "famine-emigration": "great-famine",
        "emancipation-proclamation": "us-civil-war", "lincoln-assassination": "us-civil-war",
        "lusitania": "ww1", "pearl-harbor": "ww2", "the-blitz": "ww2",
        "dust-bowl": "great-depression",
    ]

    static let rows: [E] = baseRows.map {
        E(id: $0.id, name: $0.name, phrase: $0.phrase, startYear: $0.startYear, endYear: $0.endYear,
          regions: $0.regions, kind: $0.kind, weight: $0.weight, source: $0.source, partOf: parents[$0.id])
    }

    // swiftlint:disable line_length
    static let baseRows: [E] = [
        // 1600s
        E(id: "thirty-years-war", name: "Thirty Years' War", phrase: "the Thirty Years' War", startYear: 1618, endYear: 1648,
          regions: [.germany], kind: .war, weight: 3, source: "Britannica, 'Thirty Years' War'"),
        E(id: "mayflower", name: "Mayflower voyage", phrase: "the Mayflower's voyage to Plymouth", startYear: 1620, endYear: 1620,
          regions: [.unitedStates, .england], kind: .migration, weight: 5, source: "Bradford, 'Of Plymouth Plantation'; Britannica, 'Mayflower'"),
        E(id: "puritan-great-migration", name: "Puritan Great Migration", phrase: "the Puritan Great Migration to New England", startYear: 1630, endYear: 1640,
          regions: [.unitedStates, .england], kind: .migration, weight: 4, source: "Anderson, 'The Great Migration' (NEHGS)"),
        E(id: "english-civil-war", name: "English Civil Wars", phrase: "the English Civil Wars", startYear: 1642, endYear: 1651,
          regions: ukAndIreland, kind: .war, weight: 3, source: "Britannica, 'English Civil Wars'"),
        E(id: "cromwell-ireland", name: "Cromwellian conquest of Ireland", phrase: "Cromwell's conquest of Ireland", startYear: 1649, endYear: 1653,
          regions: [.ireland], kind: .war, weight: 4, source: "Britannica, 'Cromwellian conquest of Ireland'"),
        E(id: "great-plague-london", name: "Great Plague of London", phrase: "the Great Plague of London", startYear: 1665, endYear: 1666,
          regions: [.england], kind: .epidemic, weight: 4, source: "Britannica, 'Great Plague of London'"),
        E(id: "great-fire-london", name: "Great Fire of London", phrase: "the Great Fire of London", startYear: 1666, endYear: 1666,
          regions: [.england], kind: .disaster, weight: 3, source: "Britannica, 'Great Fire of London'"),
        E(id: "king-philips-war", name: "King Philip's War", phrase: "King Philip's War in New England", startYear: 1675, endYear: 1676,
          regions: [.unitedStates], kind: .war, weight: 3, source: "Lepore, 'The Name of War' (1998)"),
        E(id: "williamite-war", name: "Williamite War", phrase: "the Williamite War in Ireland (the Boyne)", startYear: 1689, endYear: 1691,
          regions: [.ireland], kind: .war, weight: 3, source: "Britannica, 'Battle of the Boyne'"),
        E(id: "salem-witch-trials", name: "Salem witch trials", phrase: "the Salem witch trials", startYear: 1692, endYear: 1693,
          regions: [.unitedStates], kind: .politics, weight: 4, source: "Britannica, 'Salem witch trials'"),
        // 1700s
        E(id: "great-storm-1703", name: "Great Storm of 1703", phrase: "the Great Storm of 1703", startYear: 1703, endYear: 1703,
          regions: [.england, .wales], kind: .disaster, weight: 2, source: "Met Office, 'The Great Storm of 1703'"),
        E(id: "act-of-union-1707", name: "Act of Union (Scotland)", phrase: "the union of Scotland and England", startYear: 1707, endYear: 1707,
          regions: [.scotland, .england], kind: .politics, weight: 3, source: "UK Parliament, 'Union with Scotland Act 1706/1707'"),
        E(id: "ulster-scots-migration", name: "Ulster-Scots migration", phrase: "the great Ulster-Scots migration to America", startYear: 1717, endYear: 1775,
          regions: [.ireland, .scotland, .unitedStates], kind: .migration, weight: 3, source: "Library of Congress, 'Scots-Irish' immigration"),
        E(id: "boston-smallpox-1721", name: "Boston smallpox epidemic", phrase: "the Boston smallpox epidemic", startYear: 1721, endYear: 1721,
          regions: [.unitedStates], kind: .epidemic, weight: 3, source: "Harvard Library, 'Contagion: Smallpox in Boston 1721'"),
        E(id: "irish-famine-1740", name: "Irish famine of 1740–41", phrase: "the 'Year of the Slaughter' famine in Ireland", startYear: 1740, endYear: 1741,
          regions: [.ireland], kind: .famine, weight: 3, source: "Dickson, 'Arctic Ireland' (1997)"),
        E(id: "jacobite-rising-1745", name: "Jacobite rising", phrase: "the Jacobite rising of 1745 (Culloden)", startYear: 1745, endYear: 1746,
          regions: [.scotland, .england], kind: .war, weight: 3, source: "Britannica, 'Jacobite rebellion'"),
        E(id: "highland-clearances", name: "Highland Clearances", phrase: "the Highland Clearances", startYear: 1750, endYear: 1860,
          regions: [.scotland], kind: .migration, weight: 3, source: "National Records of Scotland, 'Highland Clearances'"),
        E(id: "french-indian-war", name: "French and Indian War", phrase: "the French and Indian War", startYear: 1754, endYear: 1763,
          regions: [.unitedStates, .canada], kind: .war, weight: 3, source: "Britannica, 'French and Indian War'"),
        E(id: "seven-years-war", name: "Seven Years' War", phrase: "the Seven Years' War", startYear: 1756, endYear: 1763,
          regions: [.england, .scotland, .france, .germany], kind: .war, weight: 2, source: "Britannica, 'Seven Years' War'"),
        E(id: "boston-massacre", name: "Boston Massacre", phrase: "the Boston Massacre", startYear: 1770, endYear: 1770,
          regions: [.unitedStates], kind: .politics, weight: 2, source: "Britannica, 'Boston Massacre'"),
        E(id: "boston-tea-party", name: "Boston Tea Party", phrase: "the Boston Tea Party", startYear: 1773, endYear: 1773,
          regions: [.unitedStates], kind: .politics, weight: 3, source: "Britannica, 'Boston Tea Party'"),
        E(id: "american-revolution", name: "American Revolutionary War", phrase: "the American Revolution", startYear: 1775, endYear: 1783,
          regions: [.unitedStates], kind: .war, weight: 5, source: "Britannica, 'American Revolution'"),
        E(id: "declaration-of-independence", name: "Declaration of Independence", phrase: "the Declaration of Independence", startYear: 1776, endYear: 1776,
          regions: [.unitedStates], kind: .politics, weight: 4, source: "National Archives, 'Declaration of Independence'"),
        E(id: "loyalist-exodus", name: "Loyalist exodus", phrase: "the Loyalist exodus to Canada", startYear: 1783, endYear: 1784,
          regions: [.unitedStates, .canada], kind: .migration, weight: 3, source: "Canadian Encyclopedia, 'Loyalists'"),
        E(id: "french-revolution", name: "French Revolution", phrase: "the French Revolution", startYear: 1789, endYear: 1799,
          regions: [.france], kind: .politics, weight: 4, source: "Britannica, 'French Revolution'"),
        E(id: "philadelphia-yellow-fever", name: "Philadelphia yellow fever", phrase: "the Philadelphia yellow fever epidemic", startYear: 1793, endYear: 1793,
          regions: [.unitedStates], kind: .epidemic, weight: 2, source: "Powell, 'Bring Out Your Dead' (1949)"),
        E(id: "irish-rebellion-1798", name: "Irish Rebellion of 1798", phrase: "the 1798 Rebellion in Ireland", startYear: 1798, endYear: 1798,
          regions: [.ireland], kind: .war, weight: 4, source: "Britannica, 'Irish Rebellion of 1798'"),
        // 1800s
        E(id: "act-of-union-1801", name: "Act of Union (Ireland)", phrase: "the union of Ireland with Great Britain", startYear: 1801, endYear: 1801,
          regions: [.ireland], kind: .politics, weight: 3, source: "UK Parliament, 'Act of Union (Ireland) 1800'"),
        E(id: "napoleonic-wars", name: "Napoleonic Wars", phrase: "the Napoleonic Wars", startYear: 1803, endYear: 1815,
          regions: [.europe], kind: .war, weight: 3, source: "Britannica, 'Napoleonic Wars'"),
        E(id: "war-of-1812", name: "War of 1812", phrase: "the War of 1812", startYear: 1812, endYear: 1815,
          regions: [.unitedStates, .canada], kind: .war, weight: 3, source: "Britannica, 'War of 1812'"),
        E(id: "year-without-summer", name: "Year Without a Summer", phrase: "the 'Year Without a Summer'", startYear: 1816, endYear: 1816,
          regions: [.unitedStates, .canada, .england, .scotland, .wales, .ireland, .france, .germany], kind: .disaster, weight: 3, source: "Britannica, 'Year Without a Summer' (Tambora eruption 1815)"),
        E(id: "lowell-mills", name: "Lowell mills", phrase: "the opening of the Lowell mills, America's first planned mill town", startYear: 1823, endYear: 1823,
          regions: [.unitedStates], kind: .invention, weight: 2, source: "National Park Service, Lowell National Historical Park"),
        E(id: "stockton-darlington", name: "First passenger railway", phrase: "the first public steam railway (Stockton and Darlington)", startYear: 1825, endYear: 1825,
          regions: uk, kind: .invention, weight: 3, source: "Science Museum Group, 'Stockton & Darlington Railway'"),
        E(id: "erie-canal", name: "Erie Canal opens", phrase: "the opening of the Erie Canal", startYear: 1825, endYear: 1825,
          regions: [.unitedStates], kind: .invention, weight: 2, source: "New York State Canal Corporation history"),
        E(id: "cholera-1832", name: "Cholera of 1832", phrase: "the cholera epidemic of 1832", startYear: 1832, endYear: 1832,
          regions: [.england, .scotland, .wales, .ireland, .unitedStates, .canada, .france], kind: .epidemic, weight: 3, source: "Britannica, 'cholera' (second pandemic)"),
        E(id: "slavery-abolition-act", name: "Slavery Abolition Act", phrase: "the abolition of slavery across the British Empire", startYear: 1833, endYear: 1833,
          regions: uk + [.canada], kind: .politics, weight: 2, source: "UK Parliament, 'Slavery Abolition Act 1833'"),
        E(id: "victoria-reign", name: "Queen Victoria's reign", phrase: "Queen Victoria's reign", startYear: 1837, endYear: 1901,
          regions: ukAndIreland + [.canada], kind: .politics, weight: 2, source: "Royal Collection Trust, 'Queen Victoria'"),
        E(id: "night-of-big-wind", name: "Night of the Big Wind", phrase: "the Night of the Big Wind in Ireland", startYear: 1839, endYear: 1839,
          regions: [.ireland], kind: .disaster, weight: 3, source: "Met Éireann, 'The Night of the Big Wind, 6–7 January 1839'"),
        E(id: "morse-telegraph", name: "First telegraph message", phrase: "the first long-distance telegraph message", startYear: 1844, endYear: 1844,
          regions: [.unitedStates], kind: .invention, weight: 2, source: "Library of Congress, 'What hath God wrought'"),
        E(id: "great-famine", name: "Great Famine", phrase: "the Great Famine in Ireland", startYear: 1845, endYear: 1852,
          regions: [.ireland], kind: .famine, weight: 5, source: "Britannica, 'Great Famine'; Kinealy, 'This Great Calamity' (1994)"),
        E(id: "famine-emigration", name: "Famine emigration", phrase: "the great wave of Irish emigration after the Famine", startYear: 1845, endYear: 1855,
          regions: [.ireland, .unitedStates, .canada, .england], kind: .migration, weight: 4, source: "Miller, 'Emigrants and Exiles' (1985)"),
        E(id: "highland-potato-famine", name: "Highland Potato Famine", phrase: "the Highland Potato Famine", startYear: 1846, endYear: 1856,
          regions: [.scotland], kind: .famine, weight: 3, source: "Devine, 'The Great Highland Famine' (1988)"),
        E(id: "mexican-american-war", name: "Mexican–American War", phrase: "the Mexican–American War", startYear: 1846, endYear: 1848,
          regions: [.unitedStates], kind: .war, weight: 2, source: "Britannica, 'Mexican-American War'"),
        E(id: "german-emigration-1848", name: "German emigration wave", phrase: "the great wave of German emigration after 1848", startYear: 1848, endYear: 1854,
          regions: [.germany, .unitedStates], kind: .migration, weight: 3, source: "Library of Congress, 'German Immigration'"),
        E(id: "gold-rush", name: "California Gold Rush", phrase: "the California Gold Rush", startYear: 1848, endYear: 1855,
          regions: [.unitedStates], kind: .economy, weight: 3, source: "Britannica, 'California Gold Rush'"),
        E(id: "crimean-war", name: "Crimean War", phrase: "the Crimean War", startYear: 1853, endYear: 1856,
          regions: ukAndIreland + [.france], kind: .war, weight: 2, source: "National Army Museum, 'Crimean War'"),
        E(id: "transatlantic-cable", name: "Transatlantic telegraph cable", phrase: "the first transatlantic telegraph cable", startYear: 1858, endYear: 1858,
          regions: [.unitedStates, .canada, .ireland, .england], kind: .invention, weight: 2, source: "Britannica, 'transatlantic cable' (1858; lasting 1866)"),
        E(id: "us-civil-war", name: "American Civil War", phrase: "the Civil War", startYear: 1861, endYear: 1865,
          regions: [.unitedStates], kind: .war, weight: 5, source: "National Park Service, 'Civil War Overview'"),
        E(id: "emancipation-proclamation", name: "Emancipation Proclamation", phrase: "the Emancipation Proclamation", startYear: 1863, endYear: 1863,
          regions: [.unitedStates], kind: .politics, weight: 3, source: "National Archives, 'The Emancipation Proclamation'"),
        E(id: "lincoln-assassination", name: "Lincoln assassinated", phrase: "Lincoln's assassination", startYear: 1865, endYear: 1865,
          regions: [.unitedStates], kind: .politics, weight: 4, source: "Library of Congress, 'Lincoln assassination'"),
        E(id: "franco-prussian-war", name: "Franco-Prussian War", phrase: "the Franco-Prussian War", startYear: 1870, endYear: 1871,
          regions: [.france, .germany], kind: .war, weight: 3, source: "Britannica, 'Franco-German War'"),
        E(id: "great-chicago-fire", name: "Great Chicago Fire", phrase: "the Great Chicago Fire", startYear: 1871, endYear: 1871,
          regions: [.unitedStates], kind: .disaster, weight: 3, source: "Chicago History Museum, 'Great Chicago Fire'"),
        E(id: "great-boston-fire", name: "Great Boston Fire", phrase: "the Great Boston Fire", startYear: 1872, endYear: 1872,
          regions: [.unitedStates], kind: .disaster, weight: 2, source: "Boston Fire Historical Society, 'Great Fire of 1872'"),
        E(id: "telephone", name: "The telephone", phrase: "the invention of the telephone", startYear: 1876, endYear: 1876,
          regions: [.world], kind: .invention, weight: 3, source: "Library of Congress, Bell telephone patent 1876"),
        E(id: "electric-light", name: "Electric light", phrase: "Edison's electric light", startYear: 1879, endYear: 1879,
          regions: [.world], kind: .invention, weight: 3, source: "Smithsonian, 'Edison's incandescent lamp' (1879)"),
        E(id: "ellis-island-era", name: "Ellis Island era", phrase: "the great Ellis Island era of immigration", startYear: 1892, endYear: 1924,
          regions: [.unitedStates, .ireland, .italy, .germany, .otherEurope], kind: .migration, weight: 4, source: "National Park Service, 'Ellis Island History' (to the 1924 Immigration Act)"),
        E(id: "spanish-american-war", name: "Spanish–American War", phrase: "the Spanish–American War", startYear: 1898, endYear: 1898,
          regions: [.unitedStates], kind: .war, weight: 2, source: "Library of Congress, 'The World of 1898'"),
        E(id: "boer-war", name: "Second Boer War", phrase: "the Boer War", startYear: 1899, endYear: 1902,
          regions: ukAndIreland + [.canada], kind: .war, weight: 2, source: "National Army Museum, 'Boer War'"),
        // 1900s
        E(id: "wright-brothers", name: "First powered flight", phrase: "the Wright brothers' first flight", startYear: 1903, endYear: 1903,
          regions: [.world], kind: .invention, weight: 4, source: "Smithsonian NASM, '1903 Wright Flyer'"),
        E(id: "sf-earthquake", name: "San Francisco earthquake", phrase: "the San Francisco earthquake", startYear: 1906, endYear: 1906,
          regions: [.unitedStates], kind: .disaster, weight: 3, source: "USGS, 'The Great 1906 San Francisco Earthquake'"),
        E(id: "model-t", name: "Model T", phrase: "the arrival of Ford's Model T", startYear: 1908, endYear: 1908,
          regions: [.unitedStates], kind: .invention, weight: 3, source: "The Henry Ford, 'Model T' (Oct 1908)"),
        E(id: "great-migration-us", name: "Great Migration (US)", phrase: "the Great Migration north", startYear: 1910, endYear: 1970,
          regions: [.unitedStates], kind: .migration, weight: 2, source: "National Archives, 'The Great Migration'"),
        E(id: "titanic", name: "Titanic", phrase: "the sinking of the Titanic", startYear: 1912, endYear: 1912,
          regions: [.world], kind: .disaster, weight: 4, source: "Encyclopedia Titanica; Britannica, 'Titanic'"),
        E(id: "ww1", name: "First World War", phrase: "the First World War", startYear: 1914, endYear: 1918,
          regions: [.world], kind: .war, weight: 5, source: "Imperial War Museums, 'First World War'"),
        E(id: "lusitania", name: "Lusitania sunk", phrase: "the sinking of the Lusitania", startYear: 1915, endYear: 1915,
          regions: [.unitedStates, .ireland, .england, .scotland, .wales], kind: .disaster, weight: 3, source: "Britannica, 'Lusitania'"),
        E(id: "easter-rising", name: "Easter Rising", phrase: "the Easter Rising in Dublin", startYear: 1916, endYear: 1916,
          regions: [.ireland], kind: .war, weight: 5, source: "National Library of Ireland, 'The 1916 Rising'"),
        E(id: "halifax-explosion", name: "Halifax Explosion", phrase: "the Halifax Explosion", startYear: 1917, endYear: 1917,
          regions: [.canada, .unitedStates], kind: .disaster, weight: 3, source: "Canadian Encyclopedia, 'Halifax Explosion'"),
        E(id: "flu-1918", name: "1918 flu", phrase: "the 1918 influenza pandemic", startYear: 1918, endYear: 1920,
          regions: [.world], kind: .epidemic, weight: 5, source: "CDC, '1918 Pandemic (H1N1 virus)'"),
        E(id: "uk-suffrage-1918", name: "Votes for women (UK)", phrase: "the first votes for women in Britain and Ireland", startYear: 1918, endYear: 1918,
          regions: ukAndIreland, kind: .politics, weight: 3, source: "UK Parliament, 'Representation of the People Act 1918'"),
        E(id: "irish-war-of-independence", name: "Irish War of Independence", phrase: "the Irish War of Independence", startYear: 1919, endYear: 1921,
          regions: [.ireland], kind: .war, weight: 5, source: "National Archives of Ireland; Britannica, 'Anglo-Irish War'"),
        E(id: "molasses-flood", name: "Great Molasses Flood", phrase: "Boston's Great Molasses Flood", startYear: 1919, endYear: 1919,
          regions: [.unitedStates], kind: .disaster, weight: 2, source: "Puleo, 'Dark Tide' (2003)"),
        E(id: "prohibition", name: "Prohibition", phrase: "Prohibition", startYear: 1920, endYear: 1933,
          regions: [.unitedStates], kind: .economy, weight: 3, source: "National Archives, 18th and 21st Amendments"),
        E(id: "us-suffrage-1920", name: "Votes for women (US)", phrase: "the 19th Amendment giving women the vote", startYear: 1920, endYear: 1920,
          regions: [.unitedStates], kind: .politics, weight: 3, source: "National Archives, '19th Amendment'"),
        E(id: "first-radio-broadcast", name: "First commercial radio", phrase: "the first commercial radio broadcast", startYear: 1920, endYear: 1920,
          regions: [.unitedStates], kind: .invention, weight: 3, source: "Library of Congress, KDKA Pittsburgh, 2 Nov 1920"),
        E(id: "irish-civil-war", name: "Irish Civil War", phrase: "the Irish Civil War", startYear: 1922, endYear: 1923,
          regions: [.ireland], kind: .war, weight: 4, source: "Britannica, 'Irish Civil War'"),
        E(id: "lindbergh", name: "Lindbergh's flight", phrase: "Lindbergh's solo flight across the Atlantic", startYear: 1927, endYear: 1927,
          regions: [.world], kind: .invention, weight: 3, source: "Smithsonian NASM, 'Spirit of St. Louis'"),
        E(id: "penicillin", name: "Penicillin", phrase: "the discovery of penicillin", startYear: 1928, endYear: 1928,
          regions: [.world], kind: .invention, weight: 3, source: "American Chemical Society landmark, Fleming 1928"),
        E(id: "great-depression", name: "Great Depression", phrase: "the Great Depression", startYear: 1929, endYear: 1939,
          regions: [.world], kind: .economy, weight: 5, source: "Federal Reserve History, 'The Great Depression'"),
        E(id: "dust-bowl", name: "Dust Bowl", phrase: "the Dust Bowl", startYear: 1930, endYear: 1936,
          regions: [.unitedStates], kind: .disaster, weight: 3, source: "Library of Congress, 'Dust Bowl'"),
        E(id: "bbc-television", name: "First television service", phrase: "the first regular television service", startYear: 1936, endYear: 1936,
          regions: uk, kind: .invention, weight: 2, source: "BBC History, 'BBC Television Service, 2 Nov 1936'"),
        E(id: "hindenburg", name: "Hindenburg disaster", phrase: "the Hindenburg disaster", startYear: 1937, endYear: 1937,
          regions: [.unitedStates, .germany], kind: .disaster, weight: 2, source: "Smithsonian NASM, 'Hindenburg'"),
        E(id: "hurricane-1938", name: "New England Hurricane", phrase: "the Great New England Hurricane of 1938", startYear: 1938, endYear: 1938,
          regions: [.unitedStates], kind: .disaster, weight: 3, source: "NOAA, 'The Great New England Hurricane of 1938'"),
        E(id: "ww2", name: "Second World War", phrase: "the Second World War", startYear: 1939, endYear: 1945,
          regions: [.world], kind: .war, weight: 5, source: "Imperial War Museums; National WWII Museum"),
        E(id: "the-blitz", name: "The Blitz", phrase: "the Blitz", startYear: 1940, endYear: 1941,
          regions: uk, kind: .war, weight: 4, source: "Imperial War Museums, 'The Blitz'"),
        E(id: "pearl-harbor", name: "Pearl Harbor", phrase: "the attack on Pearl Harbor", startYear: 1941, endYear: 1941,
          regions: [.unitedStates], kind: .war, weight: 4, source: "National Archives, 'Pearl Harbor'"),
        E(id: "cocoanut-grove", name: "Cocoanut Grove fire", phrase: "Boston's Cocoanut Grove fire", startYear: 1942, endYear: 1942,
          regions: [.unitedStates], kind: .disaster, weight: 2, source: "Boston Fire Historical Society, 'Cocoanut Grove'"),
        E(id: "korean-war", name: "Korean War", phrase: "the Korean War", startYear: 1950, endYear: 1953,
          regions: [.unitedStates, .canada, .england, .scotland, .wales], kind: .war, weight: 3, source: "National Archives, 'Korean War'"),
        E(id: "polio-vaccine", name: "Polio vaccine", phrase: "the announcement of the polio vaccine", startYear: 1955, endYear: 1955,
          regions: [.world], kind: .invention, weight: 3, source: "Smithsonian NMAH, 'Salk vaccine, 12 April 1955'"),
        E(id: "sputnik", name: "Sputnik", phrase: "the launch of Sputnik", startYear: 1957, endYear: 1957,
          regions: [.world], kind: .invention, weight: 3, source: "NASA History, 'Sputnik'"),
        E(id: "jfk-assassination", name: "Kennedy assassinated", phrase: "President Kennedy's assassination", startYear: 1963, endYear: 1963,
          regions: [.unitedStates, .ireland], kind: .politics, weight: 4, source: "JFK Library, 'November 22, 1963'"),
        E(id: "vietnam-war", name: "Vietnam War", phrase: "the Vietnam War", startYear: 1964, endYear: 1973,
          regions: [.unitedStates], kind: .war, weight: 3, source: "National Archives, Vietnam War (US combat 1964–1973)"),
        E(id: "the-troubles", name: "The Troubles", phrase: "the Troubles in Northern Ireland", startYear: 1968, endYear: 1998,
          regions: [.ireland], kind: .war, weight: 3, source: "CAIN Archive, Ulster University"),
        E(id: "moon-landing", name: "Moon landing", phrase: "the first moon landing", startYear: 1969, endYear: 1969,
          regions: [.world], kind: .invention, weight: 5, source: "NASA, 'Apollo 11'"),
        E(id: "falklands-war", name: "Falklands War", phrase: "the Falklands War", startYear: 1982, endYear: 1982,
          regions: uk, kind: .war, weight: 2, source: "National Army Museum, 'Falklands War'"),
        E(id: "challenger", name: "Challenger disaster", phrase: "the Challenger disaster", startYear: 1986, endYear: 1986,
          regions: [.unitedStates], kind: .disaster, weight: 3, source: "NASA, 'Challenger STS-51L'"),
        E(id: "chernobyl", name: "Chernobyl", phrase: "the Chernobyl disaster", startYear: 1986, endYear: 1986,
          regions: [.europe], kind: .disaster, weight: 2, source: "IAEA, 'Chernobyl'"),
        E(id: "berlin-wall-falls", name: "Fall of the Berlin Wall", phrase: "the fall of the Berlin Wall", startYear: 1989, endYear: 1989,
          regions: [.world], kind: .politics, weight: 3, source: "Britannica, 'Berlin Wall'"),
        E(id: "gulf-war", name: "Gulf War", phrase: "the Gulf War", startYear: 1990, endYear: 1991,
          regions: [.unitedStates, .england, .scotland, .wales], kind: .war, weight: 2, source: "National Archives, 'Persian Gulf War'"),
    ]
    // swiftlint:enable line_length
}
