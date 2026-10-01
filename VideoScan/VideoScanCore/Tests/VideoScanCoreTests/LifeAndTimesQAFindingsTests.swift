
import Foundation
import Testing
@testable import VideoScanCore

private typealias LT = LifeAndTimes
private let year2026 = LT.Options(currentYear: 2026)
private let bostonQA = "Boston, Suffolk, Massachusetts, United States"
private let corkQA = "Ballyfake, Cork, Ireland"

private func qaPerson(_ id: String = "@I1@", _ name: String = "Cornelius Testwright", sex: String = "M",
                      born: String?, died: String?, bornIn: String? = nil, diedIn: String? = nil,
                      occupations: [String] = []) -> LT.Subject {
    LT.Subject(id: id, name: name, sex: sex, birthDate: born, deathDate: died,
               birthPlace: bornIn, deathPlace: diedIn, occupations: occupations.map { .init(value: $0) })
}

private func qaLine(_ id: String, _ s: LT.Subject) -> LT.LivedThroughLine? {
    guard let birth = LT.DatedYear.parse(s.birthDate), let event = LT.event(id: id) else { return nil }
    let span = LT.Lifespan(birth: birth, death: LT.DatedYear.parse(s.deathDate), deathRecorded: s.deathRecorded)
    return LT.line(for: event, lifespan: span, presences: LT.presences(of: s), sex: s.sex)
}

// QA review of 2026-10-01 (2 P1, 4 P2, P3s). The first seven tests are
// QA's red tests, copied in unchanged and seen failing before the fix; the
// rest pin the spoken words and the P3 items.
@Suite("LifeAndTimesQAFindings")
struct LifeAndTimesQAFindingsTests {

    // P1-A: OccupationClassifier.swift:302/356/392 + LifeAndTimes.swift:172 — the group term is spoken as the job.
    @Test func storyLineSpeaksTheRecordedJobNotTheGroupTerm() throws {
        let cases: [(String, String)] = [("Butcher", "baker"), ("Midwife", "physician"),
                                         ("Typist", "merchant"), ("Bailiff", "farmer")]
        for (job, wrong) in cases {
            let f = try #require(LT.facts(for: qaPerson(born: "1850", died: "1910", occupations: [job]), options: year2026))
            #expect(!f.storyLines.contains { $0.contains("recorded as a \(wrong)") }, "\(job): \(f.storyLines)")
        }
        let butchers = (0..<2).map { qaPerson("@B\($0)@", born: "1850", died: "1910", occupations: ["Butcher"]) }
        let agg = LT.aggregate(label: "Line", subjects: butchers, options: year2026)
        #expect(!agg.spoken.contains("bakers"), "\(agg.spoken)")
    }

    // P2: OccupationClassifier.swift:334 — "private" (soldier) ties and wins by position.
    @Test func privateAsAnAdjectiveIsNotASoldier() {
        #expect(LT.OccupationClassifier.classify("Private Nurse").category != .military)
        #expect(LT.OccupationClassifier.classify("Private Tutor").category != .military)
    }

    // P1-B: ServiceAge.swift:254 + LifeAndTimes.swift:184 — age at the THEATRE start spoken as "when the war began".
    @Test func serviceLeadNeverRedatesTheStartOfTheWar() throws {
        let f = try #require(LT.facts(for: qaPerson(born: "1920", died: "1990", bornIn: bostonQA, diedIn: bostonQA),
                                      options: year2026))
        let began = f.storyLines.filter { $0.contains("when the Second World War began") }
        #expect(!began.contains { $0.contains("was 21 when the Second World War began") }, "\(began)")
        let c = try #require(f.service.first { $0.warID == "ww2" })
        #expect(!c.reasons.contains { $0.contains("when the Second World War began (1941)") }, "\(c.reasons)")
    }

    // P2-A: LivedThrough.swift:359-361 + 296-301 — edge years read as "during" / "under way".
    @Test func edgeYearBirthOrDeathIsNotSaidToBeDuring() throws {
        let born = try #require(qaLine("ww2", qaPerson(born: "4 MAR 1939", died: "2001", bornIn: bostonQA, diedIn: bostonQA)))
        #expect(!born.spoken.contains("born during"), "war began 1 Sep 1939: \(born.spoken)")
        let died = try #require(qaLine("ww2", qaPerson(born: "1900", died: "1 DEC 1945", bornIn: bostonQA, diedIn: bostonQA)))
        #expect(!died.spoken.contains("under way"), "war ended 2 Sep 1945: \(died.spoken)")
    }

    // P2-B: LivedThrough.swift:372 + 140-167 — an age is spoken for someone possibly not yet born.
    @Test func noAgeIsSpokenWhenTheBirthMayFollowTheStart() throws {
        let abt = try #require(qaLine("great-famine", qaPerson(born: "ABT 1846", died: "1901", bornIn: corkQA, diedIn: corkQA)))
        #expect(!abt.spoken.contains("about 0"), "\(abt.spoken)")
        let bet = try #require(qaLine("great-famine", qaPerson(born: "BET 1840 AND 1850", died: "1901", bornIn: corkQA, diedIn: corkQA)))
        #expect(!bet.spoken.contains("between 0 and"), "\(bet.spoken)")
    }

    // P2-C: HistoricalTimeline.swift:304 — "the Vietnam War began (1964–1973)".
    @Test func vietnamLineDoesNotSayTheWarBeganIn1964() throws {
        let l = try #require(qaLine("vietnam-war", qaPerson(born: "1934", died: "2001", bornIn: bostonQA, diedIn: bostonQA)))
        #expect(!l.spoken.contains("when the Vietnam War began (1964"), "\(l.spoken)")
    }

    // P3: LifeAndTimesRegion.swift:73/113 + HistoricalTimeline.swift:98 — "United Kingdom" places miss UK-scoped rows.
    @Test func unitedKingdomPlaceIsTouchedByTheBlitz() {
        #expect(qaLine("the-blitz", qaPerson(born: "1900", died: "1980", bornIn: "United Kingdom", diedIn: "United Kingdom")) != nil)
    }
}


// MARK: - Pins added with the fixes

private let belfast = "Belfast, Antrim, Northern Ireland"

@Suite("LifeAndTimesQAPins")
struct LifeAndTimesQAPinsTests {

    // P1-A: each job speaks its own words; only abbreviations expand.
    @Test func spokenWordsForARangeOfJobs() {
        let cases: [(String, String)] = [
            ("Butcher", "butcher"), ("Baker", "baker"), ("Midwife", "midwife"), ("Typist", "typist"),
            ("Bailiff", "bailiff"), ("Cordwainer", "cordwainer"), ("Ag Lab", "agricultural labourer"),
            ("Labr", "labourer"), ("Gen Serv", "general servant"), ("Pte", "private"),
            ("Farmer's Son", "farmer's son"), ("Master Mariner", "master mariner"),
            ("Clk in Holy Orders", "clerk in holy orders"), ("Licensed Victualler", "licensed victualler"),
            ("Compositor", "compositor"), ("Schoolmistress", "schoolmistress"), ("Lady's Maid", "lady's maid"),
        ]
        for (raw, spoken) in cases {
            #expect(LT.OccupationClassifier.classify(raw).term == spoken, "\(raw)")
        }
        #expect(LT.OccupationClassifier.classify("Butcher").group == "baker", "the group is a key, never spoken")
        let f = LT.facts(for: qaPerson(born: "1850", died: "1910", occupations: ["Midwife"]), options: year2026)
        #expect(f?.storyLines.contains("Cornelius Testwright is recorded as a midwife.") == true)
        let agg = LT.aggregate(label: "Line", subjects: (0..<2).map {
            qaPerson("@B\($0)@", born: "1850", died: "1910", occupations: ["Butcher"]) }, options: year2026)
        #expect(agg.spoken.hasPrefix("Line: 2 butchers"), "\(agg.spoken)")
    }

    // P2-D + P3 occupation edges.
    @Test func occupationEdges() {
        func cat(_ s: String) -> LT.OccupationCategory { LT.OccupationClassifier.classify(s).category }
        #expect(cat("Private Detective") == .government)
        #expect(cat("Private Chauffeur") == .labourer)
        #expect(cat("Private") == .military)
        #expect(cat("Private, 2nd Battalion") == .military)
        #expect(cat("Steward") == .unknown)
        #expect(cat("Pilot") == .unknown)
        #expect(cat("Ship's Steward") == .maritime)
        #expect(cat("River Pilot") == .maritime)
        #expect(cat("Calico Printer") == .trades)
        #expect(LT.OccupationClassifier.classify("Calico Printer").detail == "textile")
        #expect(cat("Lab Assistant") != .labourer)
        #expect(cat("Principal Clerk") == .business)
        #expect(cat("Clk in Holy Orders") == .clergy)
        let people = [qaPerson("@W@", born: "1850", died: "1910", occupations: ["Author"]),
                      qaPerson("@P@", born: "1850", died: "1910", occupations: ["Printer"])]
        let agg = LT.aggregate(label: "x", subjects: people, options: year2026)
        #expect(agg.counts[.writing] == 1 && agg.counts[.printTrade] == 1, "writers ≠ printers")
    }

    // P2-A: edge years are spoken as the year.
    @Test func edgeYearsSpeakTheYear() throws {
        let born = try #require(qaLine("ww2", qaPerson(born: "4 MAR 1939", died: "2001", bornIn: bostonQA, diedIn: bostonQA)))
        #expect(born.spoken == "was born in 1939, the year the Second World War began")
        let died = try #require(qaLine("ww2", qaPerson(born: "1900", died: "1 DEC 1945", bornIn: bostonQA, diedIn: bostonQA)))
        #expect(died.spoken == "died in 1945, the year the Second World War ended")
        let titanic = try #require(qaLine("titanic", qaPerson(born: "1912", died: "1990")))
        #expect(titanic.spoken == "was born in 1912, the year of the sinking of the Titanic")
        let inside = try #require(qaLine("ww2", qaPerson(born: "1942", died: "2001", bornIn: bostonQA, diedIn: bostonQA)))
        #expect(inside.spoken == "was born during the Second World War (1939–1945)")
    }

    // P2-B: a birth that may follow the start gets no age.
    @Test func bornAroundTheStartHasNoAge() throws {
        let abt = try #require(qaLine("great-famine", qaPerson(born: "ABT 1846", died: "1901", bornIn: corkQA, diedIn: corkQA)))
        #expect(abt.ageAtStart == nil)
        #expect(abt.spoken == "was born around the time the Great Famine in Ireland began (1845–1852)")
    }

    // P1-B: the US entry year is spoken as the entry, not the start.
    @Test func serviceLeadSaysWhenTheCountryEntered() throws {
        let f = try #require(LT.facts(for: qaPerson(born: "1920", died: "1990", bornIn: bostonQA, diedIn: bostonQA),
                                      options: year2026))
        #expect(f.storyLines.contains { $0.contains("was 21 when the United States entered the Second World War (1941)") },
                "\(f.storyLines)")
        #expect(f.livedThrough.contains { $0.spoken == "was 19 when the Second World War began (1939–1945)" })
        let uk = try #require(LT.facts(for: qaPerson(born: "1900", died: "1980", bornIn: "Leeds, England", diedIn: "Leeds, England"),
                                       options: year2026))
        #expect(uk.service.first { $0.warID == "ww2" }?.startPhrase == "when the Second World War began (1939)")
    }

    // P2-C
    @Test func vietnamRowIsAmericasWar() throws {
        let ev = try #require(LT.event(id: "vietnam-war"))
        #expect(ev.phrase == "America's war in Vietnam" && ev.startYear == 1965 && ev.endYear == 1973)
    }

    // P3: Northern Ireland and "United Kingdom" places.
    @Test func northernIrelandIsIrishBefore1922AndUKAfter() {
        #expect(LT.region(ofPlace: belfast) == .northernIreland)
        #expect(LT.region(ofPlace: "Lisburn, County Antrim, Ireland") == .northernIreland)
        #expect(LT.region(ofPlace: "Antrim, Hillsborough, New Hampshire, USA") == .unitedStates)
        let s = qaPerson(born: "1830", died: "1950", bornIn: belfast, diedIn: belfast)
        #expect(qaLine("great-famine", s) != nil, "Ulster lived the Famine")
        #expect(qaLine("belfast-blitz", s) != nil)
        #expect(qaLine("the-blitz", s) != nil, "a UK event after 1921")
        #expect(qaLine("irish-civil-war", s) == nil, "the Free State's war, not Belfast's")
        #expect(LT.Region.ireland.covers(.northernIreland), "the Irish line includes Ulster")
    }

    // P3: CONC after a trailing space, and CRLF files.
    @Test func gedcomTrailingSpaceAndCRLF() throws {
        let text = ["0 HEAD", "0 @I1@ INDI", "1 NOTE He worked as a ", "2 CONC compositor.",
                    "1 OCCU Master ", "2 CONC Mariner", "0 TRLR"]
        let lf = GedcomLifeDetails(gedcomText: text.joined(separator: "\n"))
        let crlf = GedcomLifeDetails(gedcomText: text.joined(separator: "\r\n"))
        let d = try #require(lf["@I1@"])
        #expect(d.notes == ["He worked as a compositor."])
        #expect(d.occupations.map(\.value) == ["Master Mariner"])
        #expect(crlf["@I1@"] == d)
        #expect(LT.OccupationClassifier.fromNote(d.notes[0]).first?.term == "compositor")
    }

    // P3: ancestors(of:) leaves the living out unless asked.
    @Test func ancestorsLeaveTheLivingOut() throws {
        let gedcom = [
            "0 HEAD",
            "0 @I1@ INDI", "1 NAME Child /Testwright/", "1 SEX M", "1 BIRT", "2 DATE 1980", "1 FAMC @F1@",
            "0 @I2@ INDI", "1 NAME Living /Testwright/", "1 SEX M", "1 BIRT", "2 DATE 1950", "1 FAMS @F1@",
            "1 OCCU Author",
            "0 @I3@ INDI", "1 NAME Late /Placeholder/", "1 SEX F", "1 BIRT", "2 DATE 1952",
            "1 DEAT", "2 DATE 1990", "1 FAMS @F1@", "1 OCCU Teacher",
            "0 @F1@ FAM", "1 HUSB @I2@", "1 WIFE @I3@", "1 CHIL @I1@",
            "0 TRLR",
        ].joined(separator: "\n")
        let graph = GedcomFamilyGraph(gedcomText: gedcom)
        let ctx = LT.Context(graph: graph, details: GedcomLifeDetails(gedcomText: gedcom), options: year2026)
        let child = try #require(graph.people["@I1@"])
        #expect(LT.ancestors(of: child, in: ctx).map(\.id) == ["@I3@"])
        #expect(Set(LT.ancestors(of: child, in: ctx, includeLiving: true).map(\.id)) == ["@I2@", "@I3@"])
        let agg = LT.aggregate(label: "Line", ancestorsOf: child, in: ctx)
        #expect(agg.skippedLiving == 1 && agg.counts[.writing] == nil && agg.counts[.professions] == 1)
    }

    // Timeline corrections.
    @Test func timelineCorrections() throws {
        #expect(LT.event(id: "ulster-scots-migration")?.regions.contains(.scotland) == false)
        #expect(LT.event(id: "slavery-abolition-act")?.regions.contains(.ireland) == true)
        #expect(LT.event(id: "halifax-explosion")?.regions == [.canada])
        #expect(LT.event(id: "mayflower")?.regions == [.unitedStates])
        #expect(LT.event(id: "puritan-great-migration")?.regions == [.unitedStates])
        #expect(LT.event(id: "stockton-darlington")?.name == "First public steam railway")
        #expect(LT.event(id: "first-radio-broadcast")?.phrase.hasPrefix("one of the first") == true)
        #expect(LT.event(id: "uk-suffrage-1918")?.phrase.contains("women over 30") == true)
        #expect(LT.event(id: "bbc-television")?.phrase.contains("high-definition") == true)
        #expect(LT.event(id: "great-migration-us")?.phrase == "the Great Migration of Black Americans from the South")
        let leeds = qaPerson(born: "1600", died: "1660", bornIn: "Leeds, England", diedIn: "Leeds, England")
        #expect(qaLine("mayflower", leeds) == nil, "an Englishman who stayed did not live the Mayflower")
    }
}
