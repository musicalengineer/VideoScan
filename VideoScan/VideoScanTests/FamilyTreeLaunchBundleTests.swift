// FamilyTreeLaunchBundleTests.swift
// Launch-to-tree work (2026-08-29): the sidebar rows, the identity
// directory and the anchors are built off the main actor from the
// compiled index's launch tables, in parallel, and memoized per shared-
// cache load token. Dimensions: logic (equivalence with the frozen
// per-person builders), scale (39,250 synthetic people), isolation (no
// production path is read), sensor (memo hit count, log line).

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Family tree launch bundle")
struct FamilyTreeLaunchBundleTests {

    // MARK: Frozen reference builders (pre-2026-08-29; do not "fix")

    static func frozenRows(_ graph: GedcomFamilyGraph) -> [FamilyTreePersonSummary] {
        let index = graph.index
        return index.sidebarOrder.map { frozenSummary(graph.people[index.ids[Int($0)]]!) }
    }

    static func frozenSummary(_ person: GedcomFamilyGraph.Person) -> FamilyTreePersonSummary {
        FamilyTreePersonSummary(
            id: person.id,
            name: person.name.isEmpty ? "(unnamed)" : person.name,
            surname: person.surname,
            years: FamilyTreeLiveModel.years(birth: person.birthDate, death: person.deathDate),
            sex: FamilyTreeSex(gedcom: person.sex),
            reference: person.id.trimmingCharacters(in: CharacterSet(charactersIn: "@")))
    }

    /// The 2026-08-26 builder: one `familyUnits` walk + tokenizing per person.
    static func frozenDirectory(graph: GedcomFamilyGraph,
                                aliases: FamilyAssetIdentityDirectory.AliasTable,
                                ownerGedcomID: String?,
                                ownerName: String?) -> FamilyAssetIdentityDirectory {
        let suffixes = GedcomFamilyGraph.nameSuffixes
        struct Draft {
            let person: GedcomFamilyGraph.Person
            let given: Set<String>
            let surnames: Set<String>
            let suffix: String?
        }
        var drafts: [Draft] = []
        var allGiven: Set<String> = []
        var allSurnames: Set<String> = []
        for person in graph.people.values {
            let surname = FamilyIdentityText.tokens(person.surname ?? "")
            var surnames = Set(surname)
            for unit in graph.familyUnits(of: person) {
                if let spouse = unit.spouse { surnames.formUnion(FamilyIdentityText.tokens(spouse.surname ?? "")) }
            }
            let nameTokens = FamilyIdentityText.tokens(person.name)
            let suffix = nameTokens.last(where: { suffixes.contains($0) })
            let given = Set(nameTokens.filter { !suffixes.contains($0) && !surnames.contains($0) })
            drafts.append(Draft(person: person, given: given, surnames: surnames, suffix: suffix))
            allGiven.formUnion(given)
            allSurnames.formUnion(surnames)
        }
        func nicknameTokens(_ spellings: [String]) -> Set<String> {
            Set(spellings.flatMap(FamilyIdentityText.tokens))
                .subtracting(allGiven).subtracting(allSurnames).subtracting(suffixes)
        }
        let ownerNick = nicknameTokens(ownerName.map { [$0] } ?? [])
        let members = drafts.map { draft in
            var nick = nicknameTokens(aliases[draft.person.id] ?? [])
            if draft.person.id == ownerGedcomID { nick.formUnion(ownerNick) }
            return FamilyAssetIdentityDirectory.Member(gedcomID: draft.person.id,
                                                       givenTokens: draft.given,
                                                       surnameTokens: draft.surnames,
                                                       suffix: draft.suffix,
                                                       aliasTokens: nick)
        }.sorted { $0.gedcomID < $1.gedcomID }
        return FamilyAssetIdentityDirectory(members: members, ownerGedcomID: ownerGedcomID,
                                            ownerTokens: ownerGedcomID == nil ? [] : ownerNick)
    }

    static let synthetic39k = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 39_250))

    // MARK: Logic + scale: equivalence

    @Test func sidebarRowsMatchTheFrozenBuilderOn39k() {
        let graph = Self.synthetic39k
        let rows = FamilyTreeLiveModel.sidebarRows(of: graph)
        #expect(rows == Self.frozenRows(graph))
        #expect(rows.count == 39_250)
        // Parallel build is deterministic: byte-identical twice.
        #expect(FamilyTreeLiveModel.sidebarRows(of: graph) == rows)
    }

    @Test func referenceMatchesCharacterSetTrimming() {
        for id in ["@I1@", "I1", "@@I77@@", "@", "", "@I@x@", "I@", "@I"] {
            #expect(FamilyTreeLiveModel.reference(for: id) == id.trimmingCharacters(in: CharacterSet(charactersIn: "@")), Comment(rawValue: id))
        }
    }

    @Test func identityDirectoryMatchesTheFrozenBuilderOn39k() {
        let graph = Self.synthetic39k
        let root = graph.rootPersonID
        let aliases: FamilyAssetIdentityDirectory.AliasTable = [
            root ?? "": ["Rick", "Ricky Breen"],
            graph.index.ids[7]: ["Dick"],
        ]
        for (owner, name) in [(root, "Rick Breen"), (nil, "Nobody"), (root, nil)] as [(String?, String?)] {
            let fresh = FamilyAssetIdentityDirectory(graph: graph, aliases: aliases, ownerGedcomID: owner, ownerName: name)
            let frozen = Self.frozenDirectory(graph: graph, aliases: aliases, ownerGedcomID: owner, ownerName: name)
            #expect(fresh == frozen)
            #expect(fresh.members.count == 39_250)
        }
        // The speakers-based convenience init goes through the same path.
        let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie",
                                                   archivistPersonName: nil, ownerFamilySearchID: nil)
        _ = FamilyAssetIdentityDirectory(graph: graph, speakers: speakers)
    }

    @Test func identityDirectoryEdgeCases() {
        // A dangling FAMS, a self-spouse FAM, a two-token surname, an
        // empty name, a suffix, diacritics.
        let gedcom = """
        0 HEAD
        0 @I1@ INDI
        1 NAME Richard Harding /Breen/ Jr
        1 SEX M
        1 FAMS @F1@
        1 FAMS @F9@
        0 @I2@ INDI
        1 NAME Donna /Hudson/
        1 SEX F
        1 FAMS @F1@
        1 FAMS @F2@
        0 @I3@ INDI
        1 NAME Édith /Van Buren/
        1 SEX F
        1 FAMS @F2@
        0 @I4@ INDI
        1 NAME
        1 SEX U
        1 FAMS @F3@
        0 @F1@ FAM
        1 HUSB @I1@
        1 WIFE @I2@
        0 @F2@ FAM
        1 HUSB @I3@
        1 WIFE @I2@
        0 @F3@ FAM
        1 HUSB @I4@
        1 WIFE @I4@
        0 TRLR
        """
        let graph = GedcomFamilyGraph(gedcomText: gedcom)
        let aliases: FamilyAssetIdentityDirectory.AliasTable = ["@I1@": ["Rick", "Junior"], "@I3@": ["Edie", "van"]]
        let fresh = FamilyAssetIdentityDirectory(graph: graph, aliases: aliases, ownerGedcomID: "@I1@", ownerName: "Rick Breen")
        let frozen = Self.frozenDirectory(graph: graph, aliases: aliases, ownerGedcomID: "@I1@", ownerName: "Rick Breen")
        #expect(fresh == frozen)
        #expect(fresh.member("@I2@")?.surnameTokens == ["hudson", "van", "buren"])
        #expect(fresh.member("@I1@")?.suffix == "jr")
        #expect(fresh.member("@I1@")?.aliasTokens == ["rick"])
        #expect(fresh.member("@I3@")?.aliasTokens == ["edie"])   // "van" is a tree surname token
        #expect(fresh.member("@I4@")?.givenTokens.isEmpty == true)
    }

    // MARK: Bundle

    @Test func bundleBuildsEveryPartAndIsDeterministic() {
        let graph = Self.synthetic39k
        let settings = FamilyTreeLaunchBundle.Settings(
            speakers: HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie",
                                                  archivistPersonName: nil, ownerFamilySearchID: nil),
            ownerFamilySearchID: nil)
        let a = FamilyTreeLaunchBundle.build(graph: graph, settings: settings)
        let b = FamilyTreeLaunchBundle.build(graph: graph, settings: settings)
        #expect(a.rows == b.rows)
        #expect(a.identity == b.identity)
        #expect(a.anchors == b.anchors)
        #expect(a.anchors == FamilyTreeLiveModel.anchors(in: graph, ownerFamilySearchID: nil))
        #expect(a.anchorsCaption == nil)
        #expect(Set(a.anchorIndexes.keys) == Set(a.anchors.map(\.id)))
        for anchor in a.anchors {
            #expect(a.anchorIndexes[anchor.id]?.depths == GedcomFamilyGraph.AncestorIndex(graph: graph, descendantID: anchor.id).depths)
        }
        // A stale owner pin: caption, no anchors, no indexes.
        let stale = FamilyTreeLaunchBundle.build(
            graph: graph, settings: FamilyTreeLaunchBundle.Settings(speakers: settings.speakers, ownerFamilySearchID: "ZZZZ-999"))
        #expect(stale.anchors.isEmpty)
        #expect(stale.anchorIndexes.isEmpty)
        #expect(stale.anchorsCaption?.contains("ZZZZ-999") == true)
    }

    @Test func cacheBuildsOncePerTokenAndSettings() {
        let cache = FamilyTreeLaunchBundle.Cache()
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 200, generations: 6))
        let token = UUID()
        let loaded = FamilyGraphSharedCache.Loaded(graph: graph, compiled: true, token: token, reused: false)
        let settings = FamilyTreeLaunchBundle.Settings(
            speakers: HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie",
                                                  archivistPersonName: nil, ownerFamilySearchID: nil),
            ownerFamilySearchID: nil)
        #expect(cache.cached(token: token, settings: settings) == nil)
        let first = cache.bundle(for: loaded, settings: settings)
        #expect(cache.builds == 1)
        let again = cache.bundle(for: FamilyGraphSharedCache.Loaded(graph: graph, compiled: true, token: token, reused: true),
                                 settings: settings)
        #expect(cache.builds == 1)
        #expect(again.rows == first.rows)
        #expect(cache.cached(token: token, settings: settings) != nil)
        // Changed settings → rebuild; new token → rebuild; invalidate → rebuild.
        let other = FamilyTreeLaunchBundle.Settings(speakers: settings.speakers, ownerFamilySearchID: "GVQV-NW3")
        _ = cache.bundle(for: loaded, settings: other)
        #expect(cache.builds == 2)
        _ = cache.bundle(for: FamilyGraphSharedCache.Loaded(graph: graph, compiled: true, token: UUID(), reused: false),
                         settings: other)
        #expect(cache.builds == 3)
        cache.invalidate()
        #expect(cache.cached(token: token, settings: other) == nil)
    }

    /// Concurrent callers (prewarm + tab) build once.
    @Test func concurrentCallersShareOneBuild() async {
        let cache = FamilyTreeLaunchBundle.Cache()
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 2_000, generations: 10))
        let loaded = FamilyGraphSharedCache.Loaded(graph: graph, compiled: true, token: UUID(), reused: false)
        let settings = FamilyTreeLaunchBundle.Settings(
            speakers: HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie",
                                                  archivistPersonName: nil, ownerFamilySearchID: nil),
            ownerFamilySearchID: nil)
        await withTaskGroup(of: Int.self) { group in
            for _ in 0..<8 {
                group.addTask { cache.bundle(for: loaded, settings: settings).rows.count }
            }
            for await count in group { #expect(count == 2_000) }
        }
        #expect(cache.builds == 1)
    }

    // MARK: Install through the bundle

    @MainActor
    @Test func installWithABundleDoesNoInlineBuildAndKeepsTheRows() {
        let graph = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 300, generations: 6))
        let bundle = FamilyTreeLaunchBundle.build(
            graph: graph,
            settings: FamilyTreeLaunchBundle.Settings(
                speakers: HallieTurnExecutor.Speakers(ownerName: "Rick", archivistName: "Hallie",
                                                      archivistPersonName: nil, ownerFamilySearchID: nil),
                ownerFamilySearchID: nil))
        let sink = InMemoryLogSink()
        let model = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        withAppLog(sink) { model.install(graph: graph, bundle: bundle) }
        #expect(model.peopleCount == 300)
        #expect(model.filteredPeople == bundle.rows)
        #expect(model.anchors == bundle.anchors)
        #expect(sink.lines.contains { $0.contains("[family-tree] install total took ") })
        // Without a bundle the same install builds inline and lands on the same state.
        let plain = FamilyTreeLiveModel(originalsDirectory: URL(fileURLWithPath: "/nonexistent/never-read"))
        plain.install(graph: graph)
        #expect(plain.filteredPeople == model.filteredPeople)
        #expect(plain.anchors == model.anchors)
        #expect(plain.selectedPerson == model.selectedPerson)
    }

    // MARK: Prewarm sensor

    @Test func prewarmLogsOneLine() async throws {
        // Isolation: the production prewarm reads the shared configuration
        // center; here only the log shape is pinned, via a capture that
        // accepts whatever the machine has (a tree or "no tree to load").
        let lines = LogCapture()
        FamilyTreeLaunchBundle.prewarm(log: { lines.append($0) })
        for _ in 0..<600 where lines.all.isEmpty {
            try await Task.sleep(for: .milliseconds(50))
        }
        let line = try #require(lines.all.first)
        #expect(line.hasPrefix("[family-tree] prewarm: "))
        #expect(line.contains("bundle in") || line.contains("no tree to load"))
    }

    final class LogCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var lines: [String] = []
        func append(_ line: String) { lock.withLock { lines.append(line) } }
        var all: [String] { lock.withLock { lines } }
    }
}
