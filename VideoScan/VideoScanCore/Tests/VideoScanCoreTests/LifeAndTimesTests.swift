// LifeAndTimesTests.swift
// GH #238 stage 1 — Life & Times: timeline, lived-through lines, service-age
// candidates, occupation classification, the GEDCOM side reader, privacy,
// isolation and scale. Synthetic people only (the repo is public): every
// name here is invented ("Testwright", "Placeholder", …).

import Foundation
import Testing
@testable import VideoScanCore

private typealias LT = LifeAndTimes

private let year2026 = LT.Options(currentYear: 2026)

private func person(_ id: String = "@I1@", _ name: String = "Cornelius Testwright", sex: String = "M",
                    born: String?, died: String?, bornIn: String? = nil, diedIn: String? = nil,
                    residences: [GedcomLifeDetails.Residence] = [],
                    occupations: [String] = [], notes: [String] = [],
                    military: [GedcomFamilyGraph.MilitaryFact] = []) -> LT.Subject {
    LT.Subject(id: id, name: name, surname: name.split(separator: " ").last.map(String.init), sex: sex,
               birthDate: born, deathDate: died, birthPlace: bornIn, deathPlace: diedIn,
               residences: residences, occupations: occupations.map { .init(value: $0) },
               notes: notes, militaryFacts: military)
}

private let cork = "Ballyfake, Cork, Ireland"
private let boston = "Boston, Suffolk, Massachusetts, United States"
private let leeds = "Leeds, Yorkshire, England"

// MARK: - Timeline

@Suite("LifeAndTimesTimeline")
struct LifeAndTimesTimelineTests {

    @Test func tableIsModestUniqueChronologicalAndSourced() {
        let t = LT.timeline
        #expect((60...100).contains(t.count), "timeline has \(t.count) rows")
        #expect(Set(t.map(\.id)).count == t.count, "duplicate ids")
        for e in t {
            #expect((1600...2000).contains(e.startYear), "\(e.id) starts \(e.startYear)")
            #expect(e.endYear >= e.startYear)
            #expect(!e.source.isEmpty && !e.phrase.isEmpty && !e.regions.isEmpty, "\(e.id) incomplete")
        }
        #expect(t.map(\.startYear) == t.map(\.startYear).sorted(), "rows must stay chronological")
    }

    @Test func requiredEventsArePresentWithTheirDates() throws {
        let expected: [(String, Int, Int)] = [
            ("great-famine", 1845, 1852), ("us-civil-war", 1861, 1865), ("ww1", 1914, 1918),
            ("flu-1918", 1918, 1920), ("ww2", 1939, 1945), ("titanic", 1912, 1912),
            ("great-depression", 1929, 1939), ("moon-landing", 1969, 1969), ("easter-rising", 1916, 1916),
            ("irish-war-of-independence", 1919, 1921), ("mayflower", 1620, 1620),
            ("american-revolution", 1775, 1783),
        ]
        for (id, s, e) in expected {
            let ev = try #require(LT.event(id: id), "missing \(id)")
            #expect(ev.startYear == s && ev.endYear == e, "\(id) is \(ev.yearsLabel)")
        }
        #expect(LT.event(id: "great-famine")?.regions == [.ireland])
        #expect(LT.event(id: "ww1")?.isWorldwide == true)
    }

    @Test func everyDefaultWarIsATimelineEvent() {
        for war in LT.defaultWars {
            #expect(LT.event(id: war.id) != nil, "\(war.id) has no timeline row")
        }
    }

    @Test func regionCoverage() {
        #expect(LT.Region.world.covers(.ireland))
        #expect(LT.Region.britain.covers(.scotland))
        #expect(!LT.Region.britain.covers(.ireland), "Ireland is never folded into Britain")
        #expect(LT.Region.europe.covers(.france))
        #expect(!LT.Region.ireland.covers(.unitedStates))
        #expect(LT.region(ofPlace: cork) == .ireland)
        #expect(LT.region(ofPlace: boston) == .unitedStates)
        #expect(LT.region(ofPlace: leeds) == .england)
        #expect(LT.region(ofPlace: "Lyon, Rhône, France") == .france)
        #expect(LT.region(ofPlace: "Somewhere Unheard Of") == nil)
        #expect(LT.region(ofPlace: nil) == nil)
    }
}

// MARK: - Lived through

@Suite("LifeAndTimesLivedThrough")
struct LifeAndTimesLivedThroughTests {

    /// The UNRANKED line for one event (ranking caps two per kind, so a
    /// ranked list is the wrong place to look for "is this a line at all").
    private func line(_ id: String, _ s: LT.Subject) -> LT.LivedThroughLine? {
        guard LT.facts(for: s, options: year2026) != nil,
              let birth = LT.DatedYear.parse(s.birthDate), let event = LT.event(id: id) else { return nil }
        let span = LT.Lifespan(birth: birth, death: LT.DatedYear.parse(s.deathDate), deathRecorded: s.deathRecorded)
        return LT.line(for: event, lifespan: span, presences: LT.presences(of: s), sex: s.sex)
    }

    @Test func exactBirthGivesPlainAgeAndCertainty() throws {
        let s = person(born: "4 MAR 1833", died: "1901", bornIn: cork, diedIn: cork)
        let l = try #require(line("great-famine", s))
        #expect(l.ageAtStart == LT.QualifiedAge(kind: .exact, nominal: 12, low: 12, high: 12))
        #expect(l.ageAtEnd?.nominal == 19)
        #expect(l.certainty == .certain)
        #expect(l.moment == .livedThrough)
        #expect(l.relevance == .lived)
        #expect(l.spoken == "was 12 when the Great Famine in Ireland began (1845–1852)")
        #expect(l.sentence(subject: "Cornelius") == "Cornelius was 12 when the Great Famine in Ireland began (1845–1852) — born in Ireland.")
    }

    @Test func qualifiedBirthsGiveQualifiedAges() throws {
        let about = try #require(line("great-famine", person(born: "ABT 1833", died: "1901", bornIn: cork, diedIn: cork)))
        #expect(about.ageAtStart?.spoken == "about 12")
        #expect(about.ageAtStart?.low == 10 && about.ageAtStart?.high == 14)

        let before = try #require(line("great-famine", person(born: "BEF 1833", died: "1901", bornIn: cork, diedIn: cork)))
        #expect(before.ageAtStart?.spoken == "at least 13")

        let after = try #require(line("great-famine", person(born: "AFT 1833", died: "1901", bornIn: cork, diedIn: cork)))
        #expect(after.ageAtStart?.spoken == "no more than 11")

        let between = try #require(line("great-famine", person(born: "BET 1830 AND 1834", died: "1901", bornIn: cork, diedIn: cork)))
        #expect(between.ageAtStart?.spoken == "between 11 and 15")

        let est = try #require(line("great-famine", person(born: "EST 1833", died: "1901", bornIn: cork, diedIn: cork)))
        #expect(est.ageAtStart?.spoken == "about 12")
    }

    @Test func qualifiedAgeArithmetic() {
        let exact = LT.DatedYear.exact(1900)
        #expect(LT.QualifiedAge.at(1918, birth: exact)?.spoken == "18")
        #expect(LT.QualifiedAge.at(1899, birth: exact) == nil, "not yet born")
        let about = LT.DatedYear.parse("ABT 1900")!
        #expect(LT.QualifiedAge.at(1899, birth: about)?.low == 0, "possibly born: clamped at 0")
    }

    @Test func eventsOutsideTheLifeAreNotLines() {
        let s = person(born: "1900", died: "1960", bornIn: boston, diedIn: boston)
        #expect(line("american-revolution", s) == nil)
        #expect(line("moon-landing", s) == nil)
        #expect(line("ww1", s) != nil)
        #expect(line("ww2", s) != nil)
    }

    @Test func bornDuringAndDiedDuring() throws {
        let born = try #require(line("great-famine", person(born: "1847", died: "1901", bornIn: cork, diedIn: cork)))
        #expect(born.moment == .bornDuring)
        #expect(born.ageAtStart == nil)
        #expect(born.spoken == "was born during the Great Famine in Ireland (1845–1852)")

        let died = try #require(line("flu-1918", person(born: "1880", died: "1919", bornIn: boston, diedIn: boston)))
        #expect(died.moment == .diedDuring)
        #expect(died.spoken == "died while the 1918 influenza pandemic was under way (1918–1920)",
                "never words a cause")
    }

    @Test func regionalEventsNeedARegionalTie() {
        let yankee = person(born: "1830", died: "1900", bornIn: boston, diedIn: boston)
        #expect(line("great-famine", yankee) == nil, "a Massachusetts life did not live the Famine")
        #expect(line("us-civil-war", yankee) != nil)
        let undocumentedPlace = person(born: "1830", died: "1900")
        #expect(line("great-famine", undocumentedPlace) == nil)
        #expect(line("telephone", undocumentedPlace) != nil, "worldwide events need no place")
    }

    @Test func emigrantRelevanceFollowsTheLifeStages() throws {
        let emigrant = person(born: "1838", died: "1915", bornIn: cork, diedIn: boston)
        let famine = try #require(line("great-famine", emigrant))
        #expect(famine.relevance == .likely, "a child born in Ireland")
        let civilWar = try #require(line("us-civil-war", emigrant))
        #expect(civilWar.relevance == .maybe, "where he was in 1861 is not shown")
    }

    @Test func datedResidenceIsTheStrongestTie() throws {
        let s = person(born: "1880", died: "1950", bornIn: cork, diedIn: boston,
                       residences: [.init(place: "Dublin, Ireland", date: "1916", tag: "CENS")])
        let rising = try #require(line("easter-rising", s))
        #expect(rising.relevance == .lived)
        #expect(rising.placeReason == "lived in Ireland in 1916")
    }

    @Test func presumedDeceasedLinesAreHedged() throws {
        let s = person(born: "1850", died: nil, bornIn: boston)
        let f = try #require(LT.facts(for: s, options: year2026))
        #expect(f.status == .presumedDeceased)
        let ww1 = try #require(line("ww1", s))
        #expect(ww1.certainty == .possible)
        #expect(ww1.spoken == "would have been 64 when the First World War began (1914–1918), if still living")
        let civil = try #require(line("us-civil-war", s))
        #expect(civil.certainty == .likely)
    }

    @Test func deathTextWithoutAYearIsDeceased() throws {
        let f = try #require(LT.facts(for: person(born: "1960", died: "Deceased", bornIn: boston), options: year2026))
        #expect(f.status == .deceased)
        #expect(f.death == nil)
    }

    @Test func rankingKeepsAHandfulInDateOrderAndAtMostTwoPerKind() throws {
        let s = person(born: "1838", died: "1925", bornIn: cork, diedIn: boston)
        let f = try #require(LT.facts(for: s, options: year2026))
        #expect(f.livedThrough.count == 5)
        let starts = f.livedThrough.compactMap { LT.event(id: $0.eventID)?.startYear }
        #expect(starts == starts.sorted())
        let kinds = Dictionary(grouping: f.livedThrough, by: \.kind)
        #expect(kinds.values.allSatisfy { $0.count <= 2 })
        let ids = Set(f.livedThrough.map(\.eventID))
        #expect(ids.contains("great-famine"), "the Famine is this life's headline: \(ids)")
        #expect(ids.contains("us-civil-war"), "a man of fighting age in the Civil War: \(ids)")
    }

    @Test func rankingPrefersTheFightingAgeWarForMen() throws {
        let man = person(born: "1890", died: "1970", bornIn: leeds, diedIn: leeds)
        let woman = person("@I2@", "Edwina Placeholder", sex: "F", born: "1890", died: "1970", bornIn: leeds, diedIn: leeds)
        let m = try #require(line("ww1", man))
        let w = try #require(line("ww1", woman))
        #expect(m.score > w.score)
    }

    @Test func nestedEventInsideAChosenWorldEventOnlyOnRegionalMerit() {
        let byID = HistoricalTimeline.byID
        func mk(_ id: String, score: Int, rel: LT.PlaceRelevance) -> LT.LivedThroughLine {
            let e = byID[id]!
            return LT.LivedThroughLine(eventID: id, eventName: e.name, eventPhrase: e.phrase, years: e.yearsLabel,
                                       kind: e.kind, moment: .aliveDuring, certainty: .certain, relevance: rel,
                                       ageAtStart: nil, ageAtEnd: nil, placeReason: nil, score: score)
        }
        // A synthetic nested world event: "ww2-sub" inside ww2, same kind, worldwide.
        let worldInner = LT.HistoricalEvent(id: "inner", name: "Inner", phrase: "the inner thing", startYear: 1940,
                                            endYear: 1941, regions: [.world], kind: .war, weight: 3, source: "test")
        var table = byID
        table["inner"] = worldInner
        let inner = LT.LivedThroughLine(eventID: "inner", eventName: "Inner", eventPhrase: "the inner thing",
                                        years: "1940–1941", kind: .war, moment: .aliveDuring, certainty: .certain,
                                        relevance: .world, ageAtStart: nil, ageAtEnd: nil, placeReason: nil, score: 50)
        let picked = LT.ranked([mk("ww2", score: 90, rel: .world), inner, mk("the-blitz", score: 60, rel: .lived)],
                               maxLines: 5, timeline: table)
        #expect(picked.map(\.eventID) == ["ww2", "the-blitz"], "the world-inside-world line is dropped; the Blitz stands")
    }
}

// MARK: - Service age

@Suite("LifeAndTimesService")
struct LifeAndTimesServiceTests {

    private func ww1(_ s: LT.Subject, options: LT.Options = year2026) -> LT.ServiceScan {
        LT.serviceScan(subjects: [s], warID: "ww1", options: options)
    }

    @Test func bandEdgesAreInclusive() {
        // 45 in 1914 → in; 46 in 1914 → out.
        #expect(ww1(person(born: "1869", died: "1940", bornIn: leeds, diedIn: leeds)).candidates.first?.strength == .strong)
        let tooOld = ww1(person(born: "1868", died: "1940", bornIn: leeds, diedIn: leeds))
        #expect(tooOld.candidates.isEmpty)
        #expect(tooOld.counts.outOfAgeOrLife == 1)
        // 18 in 1918 → in; 17 in 1918 → out.
        #expect(ww1(person(born: "1900", died: "1980", bornIn: leeds, diedIn: leeds)).candidates.first?.strength == .strong)
        #expect(ww1(person(born: "1901", died: "1980", bornIn: leeds, diedIn: leeds)).candidates.isEmpty)
    }

    @Test func qualifiedBirthAtTheEdgeIsOnlyPossible() throws {
        let scan = ww1(person(born: "ABT 1868", died: "1940", bornIn: leeds, diedIn: leeds))
        let c = try #require(scan.candidates.first)
        #expect(c.strength == .possible)
        #expect(c.ageAtStart?.spoken == "about 46")
        #expect(c.reasons.contains { $0.hasPrefix("possible only") })
    }

    @Test func bandIsConfigurable() {
        var wars = LT.defaultWars
        let i = wars.firstIndex { $0.id == "ww1" }!
        wars[i].band = LT.ServiceBand(minAge: 18, maxAge: 51)
        let opts = LT.Options(currentYear: 2026, wars: wars)
        #expect(ww1(person(born: "1865", died: "1940", bornIn: leeds, diedIn: leeds), options: opts).candidates.count == 1)
        #expect(ww1(person(born: "1865", died: "1940", bornIn: leeds, diedIn: leeds)).candidates.isEmpty)
    }

    @Test func sexAsRecorded() {
        let woman = ww1(person(sex: "F", born: "1890", died: "1960", bornIn: leeds, diedIn: leeds))
        #expect(woman.candidates.isEmpty)
        #expect(woman.counts.excludedBySex == 1)
        let unknown = ww1(person(sex: "", born: "1890", died: "1960", bornIn: leeds, diedIn: leeds))
        #expect(unknown.candidates.isEmpty)
        #expect(unknown.counts.excludedUnknownSex == 1)
        var wars = LT.defaultWars
        let i = wars.firstIndex { $0.id == "ww1" }!
        wars[i].band = LT.ServiceBand(minAge: 18, maxAge: 45, sexes: ["M", "F"])
        #expect(ww1(person(sex: "F", born: "1890", died: "1960", bornIn: leeds, diedIn: leeds),
                    options: LT.Options(currentYear: 2026, wars: wars)).candidates.count == 1)
    }

    @Test func placeMustBeInATheatre() throws {
        let yankee = ww1(person(born: "1890", died: "1960", bornIn: boston, diedIn: boston))
        let c = try #require(yankee.candidates.first)
        #expect(c.strength == .strong)
        #expect(c.regions == [.unitedStates])
        #expect(c.targets.contains(.usWWIDraftRegistration))
        #expect(!c.targets.contains(.tnaWO363))
        let nowhere = ww1(person(born: "1890", died: "1960"))
        #expect(nowhere.candidates.isEmpty)
        #expect(nowhere.counts.noMatchingPlace == 1)
    }

    @Test func emigrantIsPossibleOnBothSidesOfTheAtlantic() throws {
        let c = try #require(ww1(person(born: "1890", died: "1960", bornIn: cork, diedIn: boston)).candidates.first)
        #expect(c.strength == .possible)
        #expect(Set(c.regions).isSuperset(of: [.ireland, .unitedStates]))
        #expect(c.targets.contains(.tnaWO363) && c.targets.contains(.tnaWO372) && c.targets.contains(.usWWIDraftRegistration))
        #expect(c.reasons.contains { $0.contains("born in Ireland; died elsewhere") })
    }

    @Test func recordedMilitaryFactMakesItStrong() throws {
        let fact = GedcomFamilyGraph.MilitaryFact(tag: "_MILT", value: "Private, Royal Fictional Rifles", date: "1916")
        let c = try #require(ww1(person(born: "1890", died: "1960", bornIn: cork, diedIn: boston, military: [fact])).candidates.first)
        #expect(c.strength == .strong)
        #expect(c.recordedMilitary == ["Private, Royal Fictional Rifles 1916"])
    }

    @Test func deadBeforeTheTheatreOpensIsNotACandidate() {
        let s = person(born: "1880", died: "1915", bornIn: boston, diedIn: boston)
        #expect(ww1(s).candidates.isEmpty, "the US theatre opens in 1917")
    }

    @Test func researchQueueInputIsProposedAndStable() throws {
        let s = person("@I77@", "Ambrose Placeholder", born: "1890", died: "1960", bornIn: cork, diedIn: cork)
        let q = LT.researchQueue(subjects: [s], warID: "ww1", options: year2026)
        let r = try #require(q.first)
        #expect(q.count == 1)
        #expect(r.id == "@I77@|ww1")
        #expect(r.status == .proposed)
        #expect(r.surname == "Placeholder")
        #expect(r.birth.anchor == 1890)
        #expect(r.targets.contains(.tnaWO363))
        let data = try JSONEncoder().encode(q)
        #expect(try JSONDecoder().decode([LT.ResearchRequest].self, from: data) == q)
    }

    @Test func allWarsScan() {
        let s = person(born: "1840", died: "1920", bornIn: boston, diedIn: boston)
        let scan = LT.serviceScan(subjects: [s], options: year2026)
        #expect(scan.candidates.map(\.warID) == ["us-civil-war"], "\(scan.candidates.map(\.warID))")
    }
}

// MARK: - Occupations

@Suite("LifeAndTimesOccupation")
struct LifeAndTimesOccupationTests {

    private func cat(_ s: String) -> LT.OccupationCategory { LT.OccupationClassifier.classify(s).category }

    @Test func periodSpellings() {
        #expect(cat("Ag Lab") == .labourer)
        #expect(LT.OccupationClassifier.classify("Ag. Lab.").term == "agricultural labourer")
        #expect(LT.OccupationClassifier.classify("ag lab").detail == "agricultural")
        #expect(cat("Labourer") == .labourer)
        #expect(cat("Laborer") == .labourer)
        #expect(cat("Labr") == .labourer)
        #expect(cat("Yeoman") == .farming)
        #expect(cat("Husbandman") == .farming)
        #expect(cat("Cordwainer") == .trades)
        #expect(cat("Licensed Victualler") == .business)
        #expect(cat("Gen Serv") == .domesticService)
        #expect(cat("Serv") == .domesticService)
        #expect(cat("Ostler") == .labourer)
    }

    @Test func statusIsNotAnOccupation() {
        #expect(cat("Spinster") == .status)
        #expect(cat("Widow") == .status)
        #expect(cat("Scholar") == .status)
        #expect(cat("Gentleman") == .status)
        #expect(cat("Living on own means") == .status)
        #expect(cat("Cotton Spinner") == .trades, "spinner is not spinster")
        #expect(cat("Widow, Farmer") == .farming, "a real occupation beats a status word")
        #expect(!LT.OccupationClassifier.classify("Spinster").isOccupation)
    }

    @Test func artsWritingAndTheProfessions() {
        #expect(cat("Printer") == .writing)
        #expect(cat("Compositor") == .writing)
        #expect(cat("Journalist") == .writing)
        #expect(cat("Author") == .writing)
        #expect(cat("Portrait Painter") == .arts)
        #expect(cat("Musician") == .arts)
        #expect(cat("Actress") == .arts)
        #expect(cat("Solicitor") == .professions)
        #expect(LT.OccupationClassifier.classify("Physician").detail == "medicine")
        #expect(LT.OccupationClassifier.classify("Schoolmistress").detail == "teaching")
        #expect(cat("Clerk in Holy Orders") == .clergy, "the longest phrase wins over 'clerk'")
        #expect(cat("Clerk") == .business)
    }

    @Test func ambiguityAndRetirementAreRecorded() {
        let painter = LT.OccupationClassifier.classify("Painter")
        #expect(painter.category == .trades)
        #expect(painter.ambiguity != nil)
        let retired = LT.OccupationClassifier.classify("Retired Farmer")
        #expect(retired.category == .farming && retired.retired)
        #expect(cat("Master Mariner") == .maritime)
        #expect(cat("Private, 2nd Battalion") == .military)
        #expect(cat("Postman") == .government)
        #expect(cat("Farmer and Labourer") == .farming, "first named wins a tie")
        #expect(cat("Xyzzy") == .unknown)
    }

    @Test func notesOnlyByExplicitCue() {
        let hits = LT.OccupationClassifier.fromNote("He worked as a compositor for the local paper. His father was a farmer.")
        #expect(hits.map(\.category) == [.writing])
        #expect(hits.first?.evidence == .note)
        #expect(LT.OccupationClassifier.fromNote("His father was a farmer.").isEmpty)
        #expect(LT.OccupationClassifier.fromNote("Occupation: teacher; later retired").first?.category == .professions)
    }

    @Test func lineAggregateSaysWhatAndHowMuch() {
        var people: [LT.Subject] = []
        for i in 0..<9 { people.append(person("@L\(i)@", "Labourer \(i) Testwright", born: "1850", died: "1910", occupations: ["Labourer"])) }
        people.append(person("@S1@", "Soldier One Testwright", born: "1850", died: "1910", occupations: ["Soldier"]))
        people.append(person("@S2@", "Soldier Two Testwright", born: "1850", died: "1910", occupations: ["Private"]))
        people.append(person("@P1@", "Printer Testwright", born: "1850", died: "1910", occupations: ["Printer"]))
        people.append(person("@N1@", "Nobody Testwright", born: "1850", died: "1910"))
        people.append(person("@Q1@", "Spinster Testwright", sex: "F", born: "1850", died: "1910", occupations: ["Spinster"]))
        people.append(person("@LIVE@", "Living Testwright", born: "1960", died: nil, occupations: ["Artist"]))
        let agg = LT.aggregate(label: "Test line", subjects: people, options: year2026)
        #expect(agg.spoken == "Test line: 9 labourers, 2 soldiers, 1 printer — occupations recorded for 12 of 14 people (1 living skipped).")
        #expect(agg.counts[.arts] == nil, "the living artist is not counted")
        #expect(agg.statusOnly == 1)
        #expect(!agg.allManualOrLand)
        let data = try? JSONEncoder().encode(agg)
        #expect(data != nil)
    }
}

// MARK: - GEDCOM side reader

@Suite("LifeAndTimesDetails")
struct LifeAndTimesDetailsTests {

    static let gedcom = """
    0 HEAD
    1 GEDC
    2 VERS 5.5.1
    0 @I1@ INDI
    1 NAME Cornelius /Testwright/
    1 SEX M
    1 BIRT
    2 DATE ABT 1833
    2 PLAC Ballyfake, Cork, Ireland
    1 DEAT
    2 DATE 1901
    2 PLAC Boston, Suffolk, Massachusetts, United States
    1 OCCU Ag Lab
    2 DATE 1851
    2 PLAC Ballyfake, Cork, Ireland
    1 RESI
    2 DATE 1880
    2 PLAC Boston, Massachusetts, USA
    1 CENS
    2 DATE 1900
    2 PLAC Lowellish, Middlesex, Massachusetts, USA
    1 EVEN Printer
    2 TYPE Occupation
    2 DATE 1890
    1 EVEN Something else
    2 TYPE Baptism of a ship
    1 NOTE He worked as a compos
    2 CONC itor for a fictional paper.
    2 CONT Second line.
    1 NOTE @N1@
    1 _MILT Private in a fictional regiment
    2 DATE 1862
    0 @I2@ INDI
    1 NAME Edwina /Placeholder/
    1 SEX F
    0 @N1@ NOTE Shared note: a mus
    1 CONC ician by
    1 CONT night.
    0 TRLR
    """

    @Test func readsOccupationsResidencesAndNotes() throws {
        let d = GedcomLifeDetails(gedcomText: Self.gedcom)
        let c = try #require(d["@I1@"])
        #expect(c.occupations.map(\.value) == ["Ag Lab", "Printer"])
        #expect(c.occupations.first?.date == "1851")
        #expect(c.residences.map(\.tag) == ["RESI", "CENS"])
        #expect(c.residences.map(\.year) == [1880, 1900])
        #expect(c.notes == ["He worked as a compositor for a fictional paper.\nSecond line.", "Shared note: a musician by\nnight."])
        #expect(d["@I2@"] == nil, "no details → no entry")
    }

    @Test func subjectFromGraphPlusDetails() throws {
        let graph = GedcomFamilyGraph(gedcomText: Self.gedcom)
        let ctx = LT.Context(graph: graph, details: GedcomLifeDetails(gedcomText: Self.gedcom), options: year2026)
        let p = try #require(graph.people["@I1@"])
        let f = try #require(LT.facts(for: p, in: ctx))
        #expect(f.occupations.map(\.category).contains(.labourer))
        #expect(f.occupations.map(\.category).contains(.writing))
        #expect(f.recordedMilitary == ["Private in a fictional regiment 1862"])
        #expect(f.regions == [.unitedStates, .ireland])
        #expect(f.service.contains { $0.warID == "us-civil-war" && $0.strength == .strong })
        let data = try JSONEncoder().encode(f)
        #expect(try JSONDecoder().decode(LT.PersonFacts.self, from: data) == f)
        #expect(LT.facts(for: try #require(graph.people["@I2@"]), in: ctx) == nil, "undated → living → skipped")
    }
}

// MARK: - Privacy sensor

@Suite("LifeAndTimesPrivacy")
struct LifeAndTimesPrivacyTests {

    @Test func conservativeLivingRule() {
        func living(_ born: String?, _ died: String? = nil) -> Bool {
            LT.isTreatedAsLiving(person(born: born, died: died), currentYear: 2026)
        }
        #expect(living("1950"))
        #expect(living("1927"), "99 years ago")
        #expect(!living("1926"), "exactly 100 years ago")
        #expect(living("ABT 1925"), "could be 1927")
        #expect(living("AFT 1900"), "no upper bound")
        #expect(!living("BEF 1926"))
        #expect(living(nil), "undated = living")
        #expect(!living("1990", "2010"), "a recorded death is deceased, however young")
        #expect(!living(nil, "Deceased"))
    }

    @Test func thresholdCannotBeLoosened() {
        #expect(LT.Options(currentYear: 2026, livingThresholdYears: 50).livingThresholdYears == 100)
    }

    @Test func livingPeopleProduceNothingAnywhere() {
        let livingMan = person("@LIVE@", "Living Testwright", born: "1930", died: nil, bornIn: boston,
                               occupations: ["Author"])
        let dead = person("@DEAD@", "Late Testwright", born: "1920", died: "1990", bornIn: boston, diedIn: boston,
                          occupations: ["Farmer"])
        #expect(LT.facts(for: livingMan, options: year2026) == nil)
        let scan = LT.serviceScan(subjects: [livingMan, dead], options: year2026)
        #expect(!scan.candidates.contains { $0.personID == "@LIVE@" })
        #expect(scan.counts.skippedLiving == 1)
        #expect(scan.candidates.contains { $0.personID == "@DEAD@" && $0.warID == "ww2" })
        #expect(!LT.researchQueue(subjects: [livingMan, dead], options: year2026).contains { $0.personID == "@LIVE@" })
        let agg = LT.aggregate(label: "x", subjects: [livingMan, dead], options: year2026)
        #expect(agg.counts[.writing] == nil)
        #expect(agg.skippedLiving == 1)
    }

    /// SENSOR at production scale: 100k synthetic people, a third of them
    /// living by the conservative rule — not one living ID may surface.
    @Test func noLivingIDSurfacesAtScale() {
        let people = LifeAndTimesSynthetic.people(count: 100_000)
        let living = Set(people.filter { LT.isTreatedAsLiving($0, currentYear: 2026) }.map(\.id))
        #expect(living.count > 20_000, "the fixture must exercise the rule: \(living.count)")
        var leaked = 0
        for p in people where living.contains(p.id) {
            if LT.facts(for: p, options: year2026) != nil { leaked += 1 }
        }
        let scan = LT.serviceScan(subjects: people, options: year2026)
        leaked += scan.candidates.filter { living.contains($0.personID) }.count
        #expect(leaked == 0)
        #expect(scan.counts.skippedLiving == living.count)
    }
}

// MARK: - Isolation

@Suite("LifeAndTimesIsolation")
struct LifeAndTimesIsolationTests {

    @Test func theYearComesOnlyFromOptions() {
        let s = person(born: "1950", died: nil, bornIn: boston)
        #expect(LT.facts(for: s, options: LT.Options(currentYear: 2026)) == nil)
        #expect(LT.facts(for: s, options: LT.Options(currentYear: 2060)) != nil)
    }

    @Test func injectedTimelineIsTheOnlyTimeline() throws {
        let only = LT.HistoricalEvent(id: "test-only", name: "Test event", phrase: "the test event",
                                      startYear: 1900, endYear: 1900, regions: [.world], kind: .disaster,
                                      weight: 3, source: "test")
        let f = try #require(LT.facts(for: person(born: "1880", died: "1950"),
                                      options: LT.Options(currentYear: 2026, timeline: [only], wars: [])))
        #expect(f.livedThrough.map(\.eventID) == ["test-only"])
        #expect(f.service.isEmpty)
    }

    @Test func concurrentCallsMatchSequential() async {
        let people = Array(LifeAndTimesSynthetic.people(count: 2_000))
        let sequential = people.map { LT.facts(for: $0, options: year2026) }
        let parallel = await withTaskGroup(of: (Int, LT.PersonFacts?).self) { group in
            for (i, p) in people.enumerated() {
                group.addTask { (i, LT.facts(for: p, options: year2026)) }
            }
            var out = [LT.PersonFacts?](repeating: nil, count: people.count)
            for await (i, f) in group { out[i] = f }
            return out
        }
        #expect(parallel == sequential)
    }
}

// MARK: - Scale

@Suite("LifeAndTimesScale")
struct LifeAndTimesScaleTests {

    /// Measured 2026-10-01, Debug, on a busy fleet machine (load 7.5–11 on
    /// 16 cores, other agents building): 11.2–12.5 s for facts + all-war
    /// service scan + aggregate over 100k (facts alone 7.3–7.8 s). Budget
    /// ≈ 2.5× that; TimingBudget widens it further under load / on CI.
    static let budget: Duration = .seconds(30)

    @Test func hundredThousandPeople() {
        let people = LifeAndTimesSynthetic.people(count: 100_000)
        let clock = ContinuousClock()
        let start = clock.now
        var withFacts = 0, lines = 0
        for p in people {
            if let f = LT.facts(for: p, options: year2026) {
                withFacts += 1
                lines += f.livedThrough.count
            }
        }
        let factsDone = clock.now
        let scan = LT.serviceScan(subjects: people, options: year2026)
        let agg = LT.aggregate(label: "all", subjects: people, options: year2026)
        let elapsed = clock.now - start
        let ceiling = TimingBudget.loadAwareDebugCeiling(Self.budget)
        print("[life-and-times-scale] 100k: \(elapsed) total; facts \(factsDone - start); \(withFacts) with facts, \(lines) lines, \(scan.candidates.count) candidates; \(agg.spoken.prefix(120)) (\(TimingBudget.loadDescription()))")
        #expect(elapsed < ceiling, "100k took \(elapsed), ceiling \(ceiling)")
        #expect(withFacts > 50_000)
        #expect(scan.candidates.count > 1_000)
    }
}

// MARK: - Examples (what Hallie could say)

@Suite("LifeAndTimesExamples")
struct LifeAndTimesExamplesTests {

    fileprivate static let examples: [LT.Subject] = [
        person("@E1@", "Cornelius Testwright", born: "ABT 1833", died: "1901", bornIn: cork, diedIn: boston,
               occupations: ["Ag Lab", "Labourer"]),
        person("@E2@", "Ambrose Placeholder", born: "12 JUN 1891", died: "1958", bornIn: leeds, diedIn: leeds,
               occupations: ["Compositor"],
               military: [.init(tag: "_MILT", value: "Private, Fictional Light Infantry", date: "1916")]),
        person("@E3@", "Edwina Placeholder", sex: "F", born: "1898", died: "1987", bornIn: boston, diedIn: boston,
               notes: ["She worked as a music teacher for forty years."]),
        person("@E4@", "Thaddeus Fictional", born: "BET 1838 AND 1840", died: "1912", bornIn: "Hamletville, Massachusetts",
               diedIn: "Hamletville, Massachusetts", occupations: ["Yeoman"]),
        person("@E5@", "Bartholomew Notreal", born: "1889", died: "1964", bornIn: "Ballyimaginary, Mayo, Ireland",
               diedIn: "Dorchester, Suffolk, Massachusetts, USA",
               residences: [.init(place: "Dublin, Ireland", date: "1911", tag: "CENS")],
               occupations: ["Painter"]),
    ]

    @Test func fiveExamplesProduceGroundedLines() throws {
        for s in Self.examples {
            let f = try #require(LT.facts(for: s, options: year2026))
            #expect(!f.storyLines.isEmpty)
            print("[life-and-times-example] \(s.name) (\(s.birthDate ?? "?")–\(s.deathDate ?? "?")):")
            for line in f.storyLines { print("    \(line)") }
        }
        let e2 = try #require(LT.facts(for: Self.examples[1], options: year2026))
        #expect(e2.service.first { $0.warID == "ww1" }?.strength == .strong)
    }
}

// MARK: - Synthetic fixture

enum LifeAndTimesSynthetic {
    /// Deterministic synthetic people: varied qualifiers, places, sexes,
    /// occupations; about a quarter living by the conservative rule.
    static func people(count: Int) -> [LifeAndTimes.Subject] {
        let places = [cork, boston, leeds, "Glasgow, Lanark, Scotland", "Cardiff, Wales",
                      "Halifax, Nova Scotia, Canada", "Lyon, France", "Bremen, Germany", "Somewhere Unrecorded", ""]
        let jobs = ["Ag Lab", "Labourer", "Farmer", "Printer", "Spinster", "Soldier", "Cordwainer",
                    "Musician", "Servant", "Master Mariner", "Teacher", "Xyzzy"]
        let quals = ["", "ABT ", "BEF ", "AFT ", "EST "]
        var out: [LifeAndTimes.Subject] = []
        out.reserveCapacity(count)
        var state: UInt64 = 0x2545F4914F6CDD1D
        func next(_ n: Int) -> Int {
            state ^= state << 13; state ^= state >> 7; state ^= state << 17
            return Int(state % UInt64(n))
        }
        for i in 0..<count {
            let born = 1700 + next(320)
            let q = quals[next(quals.count)]
            // Born in the last century: mostly no death recorded (living).
            let died: String? = born > 1926 && next(6) != 0 ? nil : "\(min(2025, born + 20 + next(70)))"
            let bp = places[next(places.count)], dp = places[next(places.count)]
            out.append(LifeAndTimes.Subject(
                id: "@S\(i)@", name: "Synthetic Person \(i)", surname: "Synthetic", sex: next(2) == 0 ? "M" : "F",
                birthDate: "\(q)\(born)", deathDate: died,
                birthPlace: bp.isEmpty ? nil : bp, deathPlace: dp.isEmpty ? nil : dp,
                residences: next(4) == 0 ? [.init(place: places[next(places.count - 1)], date: "\(born + 30)", tag: "CENS")] : [],
                occupations: next(2) == 0 ? [.init(value: jobs[next(jobs.count)])] : []))
        }
        return out
    }
}
