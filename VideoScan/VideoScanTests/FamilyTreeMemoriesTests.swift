// FamilyTreeMemoriesTests.swift
// "Show me some memories…" (Rick 2026-10-01; GH #236 Story of the Day is
// where it grows): the provider list behind the "Recently discovered" card.
//
// Dimensions (docs/testing_retrospective_2026_07_05.md):
//   Logic     — documents filed in the last 30 days, research dossiers with
//               Confirmed findings, today's Person of the Day; newest first,
//               capped at five, deduped; a new provider plugs in
//   Scale     — the read caps (sidecars / dossiers opened) hold
//   Media     — N/A (tiny in-process PDFs only)
//   Isolation — a temp archive root; nothing under the real People/
//   Sensor    — privacy: no living person outside the inner circle; the
//               modification-date filter runs BEFORE a list is opened
// Synthetic people only (public repo).

import Foundation
import PDFKit
import Testing
import VideoScanCore
@testable import VideoScan

/// Home @I1@ (living) + spouse @I2@ (living) = inner circle; father @I4@
/// and grandmother @I7@ deceased; cousin @I5@ living, OUTSIDE the circle.
private let memoriesGedcom = """
0 HEAD
1 _VS_ROOT @I1@
0 @I1@ INDI
1 NAME Home /Testowner/
1 BIRT
2 DATE 1960
1 _FSFTID HOME-001
1 FAMC @F1@
1 FAMS @F2@
0 @I2@ INDI
1 NAME Partner /Testowner/
1 BIRT
2 DATE 1962
1 _FSFTID PART-002
1 FAMS @F2@
0 @I4@ INDI
1 NAME Father /Testowner/
1 BIRT
2 DATE 1930
1 DEAT
2 DATE 2008
1 _FSFTID FATH-004
1 FAMC @F4@
1 FAMS @F1@
0 @I5@ INDI
1 NAME Cousin /Testowner/
1 BIRT
2 DATE 1985
1 _FSFTID COUS-005
0 @I7@ INDI
1 NAME Grandma /Testowner/
1 BIRT
2 DATE 1900
1 DEAT
2 DATE 1980
1 _FSFTID GRAN-007
1 FAMS @F4@
0 @F1@ FAM
1 HUSB @I4@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I1@
1 WIFE @I2@
0 @F4@ FAM
1 WIFE @I7@
1 CHIL @I4@
0 TRLR
"""

@Suite("Family tree — memories", .serialized)
struct FamilyTreeMemoriesTests {
    private let fileManager = FileManager.default
    /// 2026-10-01 12:00 UTC. Files written by a test carry the REAL clock's
    /// modification date (later than this), which passes the 30-day filter;
    /// tests that need an old list set its date explicitly.
    private let now = Date(timeIntervalSince1970: 1_790_683_200)
    private let day: TimeInterval = 24 * 3600

    private struct Sandbox {
        let base: URL
        var store: FamilyAssetStore
        let research: ResearchStore
        let graph: GedcomFamilyGraph
    }

    private func sandbox() throws -> Sandbox {
        let base = fileManager.temporaryDirectory
            .appendingPathComponent("FamilyTreeMemoriesTests-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        let store = FamilyAssetStore(
            root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true),
            access: .readWrite)
        return Sandbox(base: base, store: store, research: ResearchStore(peopleRoot: store.peopleDirectory),
                       graph: GedcomFamilyGraph(gedcomText: memoriesGedcom))
    }

    private func context(_ sb: Sandbox, featured: FamilyMemoryContext.Featured? = nil,
                         store: Bool = true) -> FamilyMemoryContext {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        return FamilyMemoryContext(
            graph: sb.graph,
            innerCircle: FamilyTreeFeatureContext.innerCircle(graph: sb.graph, starts: ["@I1@"]),
            now: now, calendar: utc,
            assetStore: store ? sb.store : nil, researchStore: store ? sb.research : nil,
            featured: featured)
    }

    private func pdf(in sb: Sandbox, named name: String) throws -> URL {
        let document = PDFDocument()
        document.insert(PDFPage(), at: 0)
        let url = sb.base.appendingPathComponent(name)
        try #require(document.dataRepresentation()).write(to: url)
        return url
    }

    /// File a document for a tree person as if on `when`.
    @discardableResult
    private func file(_ sb: inout Sandbox, _ personID: String, kind: PersonDocumentKind = .birth,
                      daysAgo: Double, note: String = "") throws -> PersonDocument {
        let person = FamilyAssetPerson(try #require(sb.graph.people[personID]))
        let when = now.addingTimeInterval(-daysAgo * day)
        sb.store.importClock = { when }
        let folder = try sb.store.folderForPhotoRequest(person: person)
        return try sb.store.importPersonDocument(
            from: try pdf(in: sb, named: "\(UUID().uuidString).pdf"), kind: kind, note: note, into: folder, for: person)
    }

    private func setModified(_ url: URL, daysAgo: Double) throws {
        try fileManager.setAttributes([.modificationDate: now.addingTimeInterval(-daysAgo * day)], ofItemAtPath: url.path)
    }

    private func sidecar(_ sb: Sandbox, _ personID: String) throws -> URL {
        let person = FamilyAssetPerson(try #require(sb.graph.people[personID]))
        let folder = try #require(sb.store.personFolders(for: person).first)
        return FamilyAssetStore.documentsFolder(in: folder).appendingPathComponent(FamilyAssetStore.documentsSidecarName)
    }

    private func saveDossier(_ sb: Sandbox, _ personID: String, verdicts: [ResearchVerdict], daysAgo: Double) throws {
        let subject = ResearchSubject(person: try #require(sb.graph.people[personID]))
        var dossier = ResearchDossier(subject: subject)
        for (i, verdict) in verdicts.enumerated() {
            dossier.findings.append(ResearchFinding(
                source: .findAGrave, title: "Finding \(i)", date: nil, excerpt: "", url: "https://example.org/\(personID)/\(i)",
                retrievedAt: now.addingTimeInterval(Double(i)), verdict: verdict))
        }
        try sb.research.saveDossier(dossier)
        try setModified(try sb.research.dossierURL(key: subject.key), daysAgo: daysAgo)
    }

    // MARK: Logic

    @Test func recentDocumentsAppearNewestFirstAndOlderThanThirtyDaysDoNot() throws {
        var sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        try file(&sb, "@I4@", kind: .death, daysAgo: 3)
        try file(&sb, "@I7@", kind: .census, daysAgo: 1)
        try file(&sb, "@I7@", kind: .other, daysAgo: 45)   // same list, too old

        let items = RecentDocumentsMemoryProvider().memories(in: context(sb), limit: 5)
        #expect(items.map(\.personID) == ["@I7@", "@I4@"])
        #expect(items.first?.title == "Census record filed for Grandma Testowner")
        #expect(items.allSatisfy { $0.kind == .document })
    }

    @Test func researchWithConfirmedFindingsAppearsOncePerPerson() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        try saveDossier(sb, "@I7@", verdicts: [.confirmed, .unreviewed, .confirmed], daysAgo: 2)
        try saveDossier(sb, "@I4@", verdicts: [.unreviewed, .wrong], daysAgo: 1)   // nothing confirmed
        let items = RecentResearchMemoryProvider().memories(in: context(sb), limit: 5)
        #expect(items.count == 1)
        let item = try #require(items.first)
        #expect(item.personID == "@I7@")
        #expect(item.detail == "Finding 2 and 1 more", "the newest confirmed finding, then the rest counted")
    }

    @Test func personOfTheDayIsAnItemOnlyForSomeoneInTheTree() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let featured = FamilyMemoryContext.Featured(personID: "@I7@", name: "Grandma Testowner",
                                                    whyToday: "Born 126 years ago today")
        let items = PersonOfTheDayMemoryProvider().memories(in: context(sb, featured: featured), limit: 5)
        #expect(items.map(\.title) == ["Person of the Day: Grandma Testowner"])
        let stranger = FamilyMemoryContext.Featured(personID: "@I99@", name: "Nobody", whyToday: "")
        #expect(PersonOfTheDayMemoryProvider().memories(in: context(sb, featured: stranger), limit: 5).isEmpty)
    }

    @Test func gatherMergesNewestFirstCapsAtFiveAndAcceptsANewProvider() throws {
        var sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        for d in 1...4 { try file(&sb, "@I4@", daysAgo: Double(d)) }
        try saveDossier(sb, "@I7@", verdicts: [.confirmed], daysAgo: 0.5)

        struct Stub: FamilyMemoryProvider {
            let date: Date
            func memories(in context: FamilyMemoryContext, limit: Int) -> [FamilyMemory] {
                let one = FamilyMemory(id: "stub.1", kind: .research, personID: "@I4@", title: "Stub", detail: nil, date: date)
                return [one, one]   // a duplicate id is shown once
            }
        }
        let providers: [any FamilyMemoryProvider] = [RecentDocumentsMemoryProvider(), RecentResearchMemoryProvider(),
                                                     Stub(date: now)]
        let items = FamilyMemories.gather(providers, in: context(sb))
        #expect(items.count == FamilyMemories.maxItems)
        #expect(items.first?.id == "stub.1")
        #expect(items.map(\.date) == items.map(\.date).sorted(by: >))
        #expect(items.filter { $0.id == "stub.1" }.count == 1)
        #expect(items.dropFirst().first?.kind == .research)
    }

    @Test func nothingToShowGivesNoItemsAndTheFriendlyLine() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        #expect(FamilyMemories.gather(FamilyMemories.defaultProviders(), in: context(sb)).isEmpty)
        #expect(FamilyMemories.gather(FamilyMemories.defaultProviders(), in: context(sb, store: false)).isEmpty)
        #expect(FamilyMemories.emptyMessage
                == "Nothing new yet — file a record or run Research and it'll show up here.")
    }

    // MARK: Sensors — privacy and the date filter

    @Test func noLivingPersonOutsideTheInnerCircleIsEverShown() throws {
        var sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        try file(&sb, "@I5@", daysAgo: 1)        // living cousin
        try file(&sb, "@I2@", daysAgo: 2)        // living partner — inner circle
        let cousin = FamilyMemoryContext.Featured(personID: "@I5@", name: "Cousin Testowner", whyToday: "")
        let items = FamilyMemories.gather(FamilyMemories.defaultProviders(), in: context(sb, featured: cousin))
        #expect(!items.contains { $0.personID == "@I5@" })
        #expect(items.map(\.personID) == ["@I2@"])
        // A provider that forgets the rule is still filtered by gather.
        struct Leaky: FamilyMemoryProvider {
            func memories(in context: FamilyMemoryContext, limit: Int) -> [FamilyMemory] {
                [FamilyMemory(id: "leak", kind: .document, personID: "@I5@", title: "x", detail: nil, date: Date())]
            }
        }
        #expect(FamilyMemories.gather([Leaky()], in: context(sb)).isEmpty)
    }

    // Pin (2026-10-01): DNA results are private by default — their
    // screenshots name living matches — so they are never a memory, for a
    // deceased person or the inner circle alike, while a certificate filed
    // beside them still is.
    @Test func dnaDocumentsAreNeverListedAsMemories() throws {
        var sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        try file(&sb, "@I4@", kind: .dna, daysAgo: 1)       // deceased father
        try file(&sb, "@I2@", kind: .dna, daysAgo: 1.5)     // living partner, inner circle
        #expect(RecentDocumentsMemoryProvider().memories(in: context(sb), limit: 5).isEmpty)
        #expect(FamilyMemories.gather(FamilyMemories.defaultProviders(), in: context(sb)).isEmpty)

        try file(&sb, "@I4@", kind: .death, daysAgo: 2)
        let items = FamilyMemories.gather(FamilyMemories.defaultProviders(), in: context(sb))
        #expect(items.map(\.title) == ["Death certificate filed for Father Testowner"])
        #expect(!items.contains { $0.title.contains("DNA") })
    }

    @Test func anOldListIsNeverOpenedEvenIfItHoldsARecentRow() throws {
        var sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        try file(&sb, "@I4@", daysAgo: 1)
        try setModified(try sidecar(sb, "@I4@"), daysAgo: 60)
        #expect(RecentDocumentsMemoryProvider().memories(in: context(sb), limit: 5).isEmpty)
        try saveDossier(sb, "@I7@", verdicts: [.confirmed], daysAgo: 60)
        #expect(RecentResearchMemoryProvider().memories(in: context(sb), limit: 5).isEmpty)
    }

    // MARK: Scale — the read caps hold

    @Test func onlyTheNewestDossiersAndListsAreOpened() throws {
        var sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        try saveDossier(sb, "@I7@", verdicts: [.confirmed], daysAgo: 1)
        try saveDossier(sb, "@I4@", verdicts: [.confirmed], daysAgo: 2)
        var research = RecentResearchMemoryProvider()
        research.maxDossiersRead = 1
        #expect(research.memories(in: context(sb), limit: 5).map(\.personID) == ["@I7@"])

        try file(&sb, "@I7@", daysAgo: 1)
        try file(&sb, "@I4@", daysAgo: 2)
        try setModified(try sidecar(sb, "@I4@"), daysAgo: 2)
        var documents = RecentDocumentsMemoryProvider()
        documents.maxSidecarsRead = 1
        #expect(documents.memories(in: context(sb), limit: 5).map(\.personID) == ["@I7@"])
    }

    // MARK: Isolation

    @Test func theSandboxIsOutsideTheRealArchive() throws {
        let sb = try sandbox()
        defer { try? fileManager.removeItem(at: sb.base) }
        let real = FamilyAssetConfigurationCenter.shared.snapshot().roots.assets.path
        #expect(!sb.store.root.path.hasPrefix(real))
    }
}
