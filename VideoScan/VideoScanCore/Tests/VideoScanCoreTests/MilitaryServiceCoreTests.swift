import Foundation
import Testing
@testable import VideoScanCore

/// The data side of Hallie's military-service stories (Rick 2026-09-23):
/// the ADDITIVE CyberBrain service record, the biography planner's rule for
/// it, and military facts carried through the family-tree pipeline
/// (parse → merge → write → compiled codec) with exact loss accounting.
/// Synthetic people only; every file lives in a fresh temporary directory.
@Suite("Military service — CyberBrain record and tree facts")
struct MilitaryServiceCoreTests {

    private static let instant = Date(timeIntervalSince1970: 1_790_000_000)

    // MARK: - CyberBrain fixtures

    private func source(_ id: String, type: CyberBrainSource.Kind = .familyWitness,
                        attribution: String = "Alex River") -> CyberBrainSource {
        CyberBrainSource(id: id, type: type, title: "Synthetic account \(id)", attribution: attribution)
    }

    private func passage(_ id: String, person: String, text: String) -> CyberBrainItem {
        CyberBrainItem(id: id, kind: .biography, text: text, subjectPersonIDs: [person],
                       sourceIDs: ["source.alex"], confidence: .confirmed, privacy: .family,
                       createdAt: Self.instant, updatedAt: Self.instant)
    }

    private func serviceEvent(_ id: String, person: String, text: String,
                              record: CyberBrainServiceRecord,
                              kind: CyberBrainItem.Kind = .event) -> CyberBrainItem {
        CyberBrainItem(id: id, kind: kind, text: text, subjectPersonIDs: [person],
                       sourceIDs: ["source.alex"], confidence: .confirmed, privacy: .family,
                       createdAt: Self.instant, updatedAt: Self.instant, service: record)
    }

    private let marines = CyberBrainServiceRecord(
        conflict: .worldWarII, force: "United States Marine Corps",
        serviceDates: CyberBrainQualifiedDate(value: "1946-12-31", precision: .day,
                                              qualifier: .before, displayText: "before the end of 1946"),
        combat: .no, basis: .confirmedByFamily)

    private let tradition = CyberBrainServiceRecord(
        conflict: .civilWar, force: "Confederate States Army",
        engagements: [
            .init(name: "First Battle of Fort Wagner",
                  date: CyberBrainQualifiedDate(value: "1863-07-11", precision: .day, qualifier: .exact,
                                                displayText: "July 11, 1863"),
                  place: "Morris Island, South Carolina"),
        ],
        combat: .yes, basis: .familyTradition)

    private func archive(people: [CyberBrainPerson]) -> CyberBrainArchive {
        CyberBrainArchive(archiveID: "synthetic", displayName: "Synthetic",
                          people: people, sources: [source("source.alex")])
    }

    private func temporaryRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("military-core-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, to root: URL) throws {
        try data.write(to: root.appendingPathComponent(CyberBrainLoader.defaultFilename))
    }

    // MARK: - Additive decode

    @Test("an archive with no service record encodes with no service key and loads unchanged")
    func oldFileUnchanged() throws {
        let old = archive(people: [
            CyberBrainPerson(id: "person.jordan", canonicalName: "Jordan River",
                             biographyPassages: [passage("bio.jordan", person: "person.jordan",
                                                         text: "Jordan restored radios.")]),
        ])
        let bytes = try CyberBrainWriter.encode(old)
        #expect(!String(decoding: bytes, as: UTF8.self).contains("\"service\""))
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try write(bytes, to: root)
        let loaded = try CyberBrainLoader(rootURL: root).load()
        #expect(loaded == old)
        #expect(try CyberBrainWriter.encode(loaded) == bytes, "re-encoding an old file is byte-identical")
    }

    @Test("a service record round-trips through the writer and the strict loader")
    func serviceRoundTrip() throws {
        let archive = archive(people: [
            CyberBrainPerson(id: "person.harold", canonicalName: "Harold River",
                             lifeEvents: [serviceEvent("event.harold.service", person: "person.harold",
                                                       text: "Harold River served in the United States Marine Corps.",
                                                       record: marines)]),
            CyberBrainPerson(id: "person.josiah", canonicalName: "Josiah River",
                             lifeEvents: [serviceEvent("event.josiah.service", person: "person.josiah",
                                                       text: "Josiah River is said to have fought at Fort Wagner.",
                                                       record: tradition)]),
        ])
        let bytes = try CyberBrainWriter.encode(archive)
        let text = String(decoding: bytes, as: UTF8.self)
        #expect(text.contains("\"service\""))
        #expect(text.contains("\"familyTradition\""))
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try write(bytes, to: root)
        let loaded = try CyberBrainLoader(rootURL: root).load()
        #expect(loaded == archive)
        let josiah = try #require(loaded.people.first { $0.id == "person.josiah" })
        #expect(josiah.lifeEvents.first?.service?.engagements.first?.place == "Morris Island, South Carolina")
    }

    @Test("the loader fails closed on an unknown field inside a service record")
    func unknownServiceFieldRejected() throws {
        let archive = archive(people: [
            CyberBrainPerson(id: "person.harold", canonicalName: "Harold River",
                             lifeEvents: [serviceEvent("event.harold.service", person: "person.harold",
                                                       text: "Harold River served.", record: marines)]),
        ])
        var json = try #require(try JSONSerialization.jsonObject(with: CyberBrainWriter.encode(archive)) as? [String: Any])
        var people = try #require(json["people"] as? [[String: Any]])
        var events = try #require(people[0]["lifeEvents"] as? [[String: Any]])
        var service = try #require(events[0]["service"] as? [String: Any])
        service["rank"] = "General"          // a fact nobody gave — must not load
        events[0]["service"] = service
        people[0]["lifeEvents"] = events
        json["people"] = people
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try write(try JSONSerialization.data(withJSONObject: json), to: root)
        #expect(throws: CyberBrainError.invalidJSON("unknown field lifeEvents[0].service.rank")) {
            _ = try CyberBrainLoader(rootURL: root).load()
        }
    }

    /// QA P3 (2026-09-24): a hand-written record with no battles and no
    /// combat key must not fail the whole CyberBrain load.
    @Test("a service record without engagements or combat loads with [] and .unknown")
    func missingOptionalServiceFieldsDefault() throws {
        let archive = archive(people: [
            CyberBrainPerson(id: "person.harold", canonicalName: "Harold River",
                             lifeEvents: [serviceEvent("event.harold.service", person: "person.harold",
                                                       text: "Harold River served.", record: marines)]),
        ])
        var json = try #require(try JSONSerialization.jsonObject(with: CyberBrainWriter.encode(archive)) as? [String: Any])
        var people = try #require(json["people"] as? [[String: Any]])
        var events = try #require(people[0]["lifeEvents"] as? [[String: Any]])
        var service = try #require(events[0]["service"] as? [String: Any])
        service.removeValue(forKey: "engagements")
        service.removeValue(forKey: "combat")
        events[0]["service"] = service
        people[0]["lifeEvents"] = events
        json["people"] = people
        let root = try temporaryRoot(); defer { try? FileManager.default.removeItem(at: root) }
        try write(try JSONSerialization.data(withJSONObject: json), to: root)
        let loaded = try CyberBrainLoader(rootURL: root).load()
        let record = try #require(loaded.people.first?.lifeEvents.first?.service)
        #expect(record.engagements.isEmpty)
        #expect(record.combat == .unknown)
        #expect(record.force == "United States Marine Corps")
        #expect(record.basis == .confirmedByFamily)
    }

    @Test("a service record rides only on a life event, names its force, and names its battles")
    func validatorRules() throws {
        let onBiography = archive(people: [
            CyberBrainPerson(id: "person.harold", canonicalName: "Harold River",
                             biographyPassages: [serviceEvent("bio.harold", person: "person.harold",
                                                              text: "Harold River served.", record: marines,
                                                              kind: .biography)]),
        ])
        #expect(throws: CyberBrainError.self) { try CyberBrainValidator.validate(onBiography) }

        let noForce = CyberBrainServiceRecord(conflict: .worldWarII, force: "  ", basis: .confirmedByFamily)
        #expect(throws: CyberBrainError.invalidField("service.force")) {
            try CyberBrainValidator.validate(self.archive(people: [
                CyberBrainPerson(id: "person.harold", canonicalName: "Harold River",
                                 lifeEvents: [self.serviceEvent("event.h", person: "person.harold",
                                                                text: "Harold River served.", record: noForce)]),
            ]))
        }
        let unnamedBattle = CyberBrainServiceRecord(conflict: .civilWar, force: "Union Army",
                                                    engagements: [.init(name: "")], basis: .documented)
        #expect(throws: CyberBrainError.invalidField("service.engagements.name")) {
            try CyberBrainValidator.validate(self.archive(people: [
                CyberBrainPerson(id: "person.harold", canonicalName: "Harold River",
                                 lifeEvents: [self.serviceEvent("event.h", person: "person.harold",
                                                                text: "Harold River served.", record: unnamedBattle)]),
            ]))
        }
    }

    // MARK: - Biography planner

    @Test("a biography leaves the service story out when it has anything else to say, and IS the story otherwise")
    func plannerServiceRule() throws {
        let story = "Harold River served in the United States Marine Corps."
        let index = try CyberBrainIndex(archive: archive(people: [
            CyberBrainPerson(id: "person.harold", canonicalName: "Harold River",
                             biographyPassages: [passage("bio.harold", person: "person.harold",
                                                         text: "Harold River repaired typewriters.")],
                             lifeEvents: [serviceEvent("event.harold.service", person: "person.harold",
                                                       text: story, record: marines)]),
            CyberBrainPerson(id: "person.seamus", canonicalName: "Seamus River",
                             lifeEvents: [serviceEvent("event.seamus.service", person: "person.seamus",
                                                       text: "Seamus River served in the British Army.",
                                                       record: CyberBrainServiceRecord(
                                                        conflict: nil, force: "British Army",
                                                        basis: .confirmedByFamily))]),
        ]))
        let harold = CyberBrainBiographyPlanner.plan(personName: "Harold River", index: index)
        #expect(harold.answerState == .answered)
        #expect(harold.claims.map(\.text) == ["Harold River repaired typewriters."])
        let seamus = CyberBrainBiographyPlanner.plan(personName: "Seamus River", index: index)
        #expect(seamus.answerState == .answered)
        #expect(seamus.claims.map(\.text) == ["Seamus River served in the British Army."])
        #expect(index.serviceItems(for: "person.harold", privacyCeiling: .family).map(\.id) == ["event.harold.service"])
    }

    @Test("the four wars are world facts with their standard spans")
    func warSpans() {
        #expect(WorldKnowledge.war(.americanRevolution)?.years == 1775...1783)
        #expect(WorldKnowledge.war(.civilWar)?.years == 1861...1865)
        #expect(WorldKnowledge.war(.worldWarI)?.years == 1914...1918)
        #expect(WorldKnowledge.war(.worldWarII)?.years == 1939...1946)
        #expect(WorldKnowledge.war(.other) == nil)
    }

    // MARK: - Family tree military facts

    /// Lines marked KEPT are military; everything else under a record is
    /// dropped exactly as before this change.
    static let tree = """
    0 HEAD
    1 GEDC
    2 VERS 5.5.1
    0 @I1@ INDI
    1 NAME Eli /Sample/
    1 SEX M
    1 BIRT
    2 DATE 1741
    1 _MILT Private in Revolutionary War
    2 NOTE @N1@
    1 _MILT
    2 DATE 6 July 1780
    2 PLAC Shrewsbury, Massachusetts
    3 MAP
    4 LATI 42.2958
    4 LONG -71.7133
    2 SOUR @S1@
    1 EVEN
    2 TYPE Residence
    2 DATE 1790
    1 OCCU Farmer
    1 _FSFTID LZ7K-QRS
    0 @I2@ INDI
    1 NAME Walter /Sample/
    1 SEX M
    1 EVEN
    2 TYPE Military Draft Registration
    2 DATE 1917-1918
    2 PLAC Ohio, United States
    2 NOTE Registered at the county seat
    3 CONT on a Tuesday
    1 MILI
    2 TYPE Army
    0 @I3@ INDI
    1 NAME Ann /Sample/
    1 SEX F
    1 BIRT
    2 DATE 1750
    0 TRLR
    """

    @Test("military facts are parsed verbatim, and only non-military lines are counted as dropped")
    func parse() {
        let graph = GedcomFamilyGraph(gedcomText: Self.tree)
        let eli = graph.people["@I1@"]
        #expect(eli?.militaryFacts == [
            .init(tag: "_MILT", value: "Private in Revolutionary War"),
            .init(tag: "_MILT", date: "6 July 1780", place: "Shrewsbury, Massachusetts"),
        ])
        #expect(eli?.birthDate == "1741", "BIRT is untouched by the military block")
        #expect(eli?.familySearchID == "LZ7K-QRS")
        let walter = graph.people["@I2@"]
        #expect(walter?.militaryFacts == [
            .init(tag: "EVEN", type: "Military Draft Registration", date: "1917-1918",
                  place: "Ohio, United States", note: "Registered at the county seat\non a Tuesday"),
            .init(tag: "MILI", type: "Army"),
        ])
        #expect(walter?.militaryFacts.first?.isDraftRegistration == true)
        #expect(graph.people["@I3@"]?.militaryFacts.isEmpty == true, "a birth year is never a military fact")
        // Dropped: NOTE @N1@, MAP, LATI, LONG, SOUR (5); the Residence EVEN
        // block (3); OCCU (1). The HEAD envelope is never counted.
        #expect(graph.droppedLineCount == 9)
    }

    @Test("the writer carries military facts, and they read back identically with nothing dropped")
    func writerRoundTrip() {
        let graph = GedcomFamilyGraph(gedcomText: Self.tree)
        let reread = GedcomFamilyGraph(gedcomText: graph.gedcomText())
        for id in ["@I1@", "@I2@", "@I3@"] {
            #expect(reread.people[id]?.militaryFacts == graph.people[id]?.militaryFacts, "\(id)")
        }
        #expect(reread.droppedLineCount == 0)
    }

    @Test("a merge unions military facts — nothing a pull recorded is lost, nothing is doubled")
    func mergeUnion() {
        let first = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I1@ INDI
        1 NAME Eli /Sample/
        1 _MILT Private in Revolutionary War
        1 _FSFTID LZ7K-QRS
        0 TRLR
        """)
        let second = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @I9@ INDI
        1 NAME Eli /Sample/
        1 _MILT Private in Revolutionary War
        1 EVEN
        2 TYPE Military Service
        2 DATE 1778
        1 _FSFTID LZ7K-QRS
        0 TRLR
        """)
        let merged = first.merged(with: second)
        let eli = merged.people.values.first { $0.familySearchID == "LZ7K-QRS" }
        #expect(merged.people.count == 1)
        #expect(eli?.militaryFacts == [
            .init(tag: "_MILT", value: "Private in Revolutionary War"),
            .init(tag: "EVEN", type: "Military Service", date: "1778"),
        ])
    }

    @Test("codec 7 carries military facts through the compiled tree, and verify notices a lost one")
    func codecRoundTrip() throws {
        #expect(GedcomCompiledTree.codecVersion == 7)
        let graph = GedcomFamilyGraph(gedcomText: Self.tree)
        let decoded = try GedcomCompiledTree.decode(GedcomCompiledTree.encode(graph))
        for id in ["@I1@", "@I2@", "@I3@"] {
            #expect(decoded.people[id]?.militaryFacts == graph.people[id]?.militaryFacts, "\(id)")
        }
        #expect(GedcomCompiledTree.verify(decoded: decoded, against: graph).isEmpty)
        var eli = try #require(graph.people["@I1@"])
        eli.militaryFacts = []
        #expect(GedcomCompiledTree.firstDifference(eli, try #require(graph.people["@I1@"])) == "militaryFacts")
    }
}
