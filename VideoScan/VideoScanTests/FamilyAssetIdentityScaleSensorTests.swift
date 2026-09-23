// FamilyAssetIdentityScaleSensorTests.swift
// Regression sensor for the 2026-09-23 HallieQueryBench finding: the
// paternal-line question took 1.27 s p50 (Release, M5). A lineage card asks
// `FamilyAssetStore.photoURLs(for:)` once per person shown; each call
// listed, stat'ed, sorted and parsed People/ about six times, and for every
// folder `groupFolderMatches` asked the identity directory for
// `member(_:)`, which rebuilt a dictionary of EVERY tree person per call:
// 7 people × 82 folders × 16,383 entries per answer. It hid behind the
// identity directory being published — e7d71578 (2026-09-10) made "tell
// me about <name>" a deterministic biography, which publishes it.
//
// Isolated on purpose: the bench reads whatever People/ folder the host
// machine has (82 on the M5, 20 on the M4) through the process-global
// FamilyAssetConfigurationCenter, so it can only see this when the
// machine happens to carry enough folders and an earlier turn happened to
// publish a directory. These tests build their own People/ tree in a
// temporary directory and their own directory at Rick's scale.
//
// Budgets follow PerformanceLane: a loose always-on ceiling (the old code
// misses it by an order of magnitude or more) and a tight Release budget
// that only counts under VIDEOSCAN_HALLIE_PERF=1.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Group-photo identity directory at scale", .serialized)
struct FamilyAssetIdentityScaleSensorTests {

    static let performanceOptIn = "VIDEOSCAN_HALLIE_PERF"
    static let peopleCount = 16_383
    /// Rick's M5 People/ folder carried 82 entries on 2026-09-23.
    static let folderCount = 82

    static let graph = GedcomFamilyGraph(
        gedcomText: GedcomSyntheticPedigree.gedcom(people: peopleCount))

    static let directory: FamilyAssetIdentityDirectory = FamilyAssetIdentityDirectory(
        graph: graph, aliases: [:], ownerGedcomID: graph.rootPerson?.id, ownerName: nil)

    /// The people a 6-generation paternal-line card shows: the subject and
    /// six fathers.
    static func paternalLine() -> [GedcomFamilyGraph.Person] {
        guard var person = graph.rootPerson else { return [] }
        var line = [person]
        for _ in 0..<6 {
            guard let father = graph.relatives(.father, of: person).first else { break }
            line.append(father)
            person = father
        }
        return line
    }

    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")

    /// One surname per person on the line (the synthetic pedigree does
    /// not inherit surnames), deduplicated: a surname-only group folder
    /// ("Breen_Family") attributes its photo to every carrier, so each
    /// person on the line matches at least one group folder.
    static func lineSurnames(_ line: [GedcomFamilyGraph.Person]) -> [String] {
        var out: [String] = []
        for person in line {
            if let token = directory.member(person.id)?.surnameTokens.min(), !out.contains(token) {
                out.append(token)
            }
        }
        return out
    }

    static func title(_ token: String) -> String { token.prefix(1).uppercased() + token.dropFirst() }

    /// A People/ tree shaped like a real one — 82 folders, as on Rick's M5
    /// on 2026-09-23: single-person folders plus a named group folder and
    /// a surname-only group folder per line surname, so the identity-aware
    /// attribution path runs and matches.
    private func peopleStore(surnames: [String]) throws -> (base: URL, store: FamilyAssetStore) {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("FamilyAssetIdentityScale-\(UUID().uuidString)", isDirectory: true)
        var store = FamilyAssetStore(
            root: base.appendingPathComponent("archive/40_Family_Tree", isDirectory: true),
            cacheRoot: base.appendingPathComponent("support/thumbs", isDirectory: true))
        let png = try #require(Self.png)
        var groups = surnames.map { "\(Self.title($0))_Family" }
        if let first = surnames.first { groups.append("John\(Self.title(first))Family") }
        let singles = max(0, Self.folderCount - groups.count)
        let folders = (0..<singles).map { "Person\($0) Example_ABCD-\(1000 + $0)" } + groups
        for name in folders {
            let folder = store.peopleDirectory.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            try png.write(to: folder.appendingPathComponent("photo.png"))
        }
        store.identity = Self.directory
        return (base, store)
    }

    // MARK: Logic — the index answers exactly what the rebuilt dictionary did

    @Test("member(_:) finds every person by GEDCOM id, and nobody else")
    func memberLookupIsExact() {
        let d = Self.directory
        #expect(d.members.count == Self.graph.people.count)
        for member in d.members.prefix(2_000) {
            #expect(d.member(member.gedcomID)?.gedcomID == member.gedcomID)
        }
        #expect(d.member(nil) == nil)
        #expect(d.member("@NOBODY@") == nil)
    }

    @Test("a duplicated GEDCOM id keeps the FIRST member, as the old dictionary did")
    func duplicateIDFirstWins() {
        let first = FamilyAssetIdentityDirectory.Member(
            gedcomID: "@I1@", givenTokens: ["richard"], surnameTokens: ["breen"],
            suffix: "jr", aliasTokens: [])
        let second = FamilyAssetIdentityDirectory.Member(
            gedcomID: "@I1@", givenTokens: ["richard"], surnameTokens: ["breen"],
            suffix: "sr", aliasTokens: [])
        let d = FamilyAssetIdentityDirectory(members: [first, second], ownerGedcomID: nil)
        #expect(d.member("@I1@") == first)
    }

    /// Byte-for-byte the attribution as it was before the surname index
    /// (2026-09-23): union every member's surnames, filter every member.
    static func frozenAttributedMembers(_ d: FamilyAssetIdentityDirectory,
                                        folderTokens: [String]) -> Set<String> {
        let suffixes = GedcomFamilyGraph.nameSuffixes
        let suffixTokens = Set(folderTokens.filter { suffixes.contains($0) })
        let nameTokens = folderTokens.filter { !suffixes.contains($0) }
        let folderSurnames = Set(nameTokens).intersection(
            d.members.reduce(into: Set<String>()) { $0.formUnion($1.surnameTokens) })
        guard !folderSurnames.isEmpty else { return [] }
        let family = d.members.filter { !$0.surnameTokens.isDisjoint(with: folderSurnames) }
        let givenTokens = nameTokens.filter { !folderSurnames.contains($0) }
        if givenTokens.isEmpty { return Set(family.map(\.gedcomID)) }
        func formal(_ t: String) -> String { GedcomFamilyGraph.diminutives[t] ?? t }
        var out: Set<String> = []
        for token in givenTokens {
            let levels: [[FamilyAssetIdentityDirectory.Member]] = [
                d.ownerTokens.contains(token) ? family.filter { $0.gedcomID == d.ownerGedcomID } : [],
                family.filter { $0.aliasTokens.contains(token) },
                family.filter { member in
                    member.givenTokens.contains(token)
                        || member.givenTokens.contains(where: { formal($0) == formal(token) })
                },
            ]
            guard var candidates = levels.first(where: { !$0.isEmpty }) else { continue }
            if !suffixTokens.isEmpty {
                let narrowed = candidates.filter { $0.suffix.map(suffixTokens.contains) ?? false }
                if !narrowed.isEmpty { candidates = narrowed }
            }
            if candidates.count == 1 { out.insert(candidates[0].gedcomID) }
        }
        return out
    }

    @Test("group-folder attribution through the surname index equals the frozen full scan")
    func attributionMatchesFrozenScan() {
        // An owner with a nickname and a few alias tokens, so levels 1 and 2
        // of the ladder are reachable, not just the tree's given names.
        let base = Self.directory.members
        var members = base
        for i in stride(from: 0, to: members.count, by: 997) {
            let m = members[i]
            members[i] = .init(gedcomID: m.gedcomID, givenTokens: m.givenTokens,
                               surnameTokens: m.surnameTokens, suffix: i % 2 == 0 ? "sr" : m.suffix,
                               aliasTokens: ["dicky\(i % 3)"])
        }
        let d = FamilyAssetIdentityDirectory(
            members: members, ownerGedcomID: members[0].gedcomID, ownerTokens: ["rick"])
        var probes: [[String]] = [["nobody", "family"], [], ["rick"]]
        for (i, m) in members.enumerated() where i % 211 == 0 {
            let given = m.givenTokens.sorted()
            guard let surname = m.surnameTokens.min() else { continue }
            probes.append([surname])                                   // surname-only
            probes.append((given.first.map { [$0] } ?? []) + [surname]) // named
            if let other = members[(i + 5_000) % members.count].surnameTokens.min() {
                probes.append((given.first.map { [$0] } ?? []) + [surname, other]) // two surnames
            }
        }
        // Levels 1 and 2 of the ladder, reachable by construction: the
        // owner's nickname with the owner's surname, and each alias with
        // its carrier's surname (plus a suffix, to exercise narrowing).
        var ladderProbes: [[String]] = []
        if let ownerSurname = members[0].surnameTokens.min() {
            ladderProbes.append(["rick", ownerSurname])
        }
        for i in stride(from: 0, to: members.count, by: 997) {
            guard let surname = members[i].surnameTokens.min() else { continue }
            ladderProbes.append(["dicky\(i % 3)", surname])
            ladderProbes.append(["dicky\(i % 3)", surname, "sr"])
        }
        var productive = 0
        for tokens in probes + ladderProbes {
            let new = d.attributedMembers(folderTokens: tokens)
            #expect(new == Self.frozenAttributedMembers(d, folderTokens: tokens), "\(tokens)")
            if !new.isEmpty { productive += 1 }
        }
        let ladderProductive = ladderProbes.filter { !d.attributedMembers(folderTokens: $0).isEmpty }.count
        print("[identity-scale] attribution parity: \(probes.count + ladderProbes.count) probes, \(productive) attribute someone, \(ladderProductive) of \(ladderProbes.count) via owner/alias")
        #expect(probes.count + ladderProbes.count > 250)
        #expect(productive > 100, "only \(productive) probes attributed anyone — the agreement would be vacuous")
        #expect(ladderProductive > ladderProbes.count / 2, "the owner/alias levels are barely exercised (\(ladderProductive))")
    }

    // MARK: Scale — lookups are O(1), not O(tree)

    @Test("20,000 member lookups over a 16,383-person directory")
    func memberLookupScale() {
        let d = Self.directory
        let ids = d.members.map(\.gedcomID)
        let start = ContinuousClock.now
        var found = 0
        for i in 0..<20_000 where d.member(ids[(i &* 7919) % ids.count]) != nil { found += 1 }
        let elapsed = ContinuousClock.now - start
        #expect(found == 20_000)
        print("[identity-scale] 20,000 member lookups: \(elapsed) (\(PerformanceLane.configurationName))")
        // The old computed dictionary took ~1.5 ms per lookup in Release at
        // this size: ~30 s here. O(1) lookups are well under 10 ms.
        let ceiling = PerformanceLane.debugCeiling(.milliseconds(500))
        #expect(elapsed < ceiling, "member(_:) is scanning the tree again: \(elapsed) for 20,000 lookups")
        if PerformanceLane.isAuthoritative(optInKey: Self.performanceOptIn) {
            #expect(elapsed < .milliseconds(20), "Release budget: \(elapsed)")
        }
    }

    // MARK: Sensor — the lineage card's photo pass at production scale

    @Test("a 7-person lineage card's photo lookups over 82 People folders")
    func lineageCardPhotoPass() throws {
        let line = Self.paternalLine()
        #expect(line.count == 7, "the synthetic pedigree should reach six fathers up")
        let (base, store) = try peopleStore(surnames: Self.lineSurnames(line))
        defer { try? FileManager.default.removeItem(at: base) }

        // Parity: one People/ listing per card (what ancestorLine does)
        // answers exactly what a fresh listing per lookup answers.
        var card = store
        card.snapshotPeopleFolders()
        for person in line {
            #expect(card.photoURLs(for: person) == store.photoURLs(for: person), "\(person.id)")
        }

        var samples: [Duration] = []
        var photos = 0
        for _ in 0..<5 {
            let start = ContinuousClock.now
            var perCard = store
            perCard.snapshotPeopleFolders()
            photos = line.reduce(0) { $0 + perCard.photoURLs(for: $1).count }
            samples.append(ContinuousClock.now - start)
        }
        #expect(photos >= line.count, "the surname group folder should reach every person on the line (\(photos) photos)")
        let best = samples.min() ?? .zero
        print("[identity-scale] lineage photo pass (7 people, \(Self.folderCount) folders): best \(best) of \(samples) (\(PerformanceLane.configurationName)); \(photos) photos")
        // Before the fix: ~1.2 s in Release on an M5 (the real People/
        // folder); this fixture ~0.17 s with only the member lookup fixed,
        // ~0.02 s after. The ceiling only catches O(folders × tree) coming back.
        let ceiling = PerformanceLane.debugCeiling(.milliseconds(300))
        #expect(best < ceiling, "lineage photo pass \(best) — scan-shaped again")
        if PerformanceLane.isAuthoritative(optInKey: Self.performanceOptIn) {
            #expect(best < .milliseconds(40), "Release budget: lineage photo pass \(best)")
        }
    }
}
