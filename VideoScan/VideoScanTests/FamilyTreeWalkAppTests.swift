// FamilyTreeWalkAppTests.swift
// The Family Tree Walk, app half (2026-09-27). Dimensions:
//   Logic     — default start people (pinned owner first, Rick + Donna),
//               display names, the fan layout (Rick left, Donna right),
//               the MFO kind.
//   Scale     — the animation's per-tick frame is O(batch), never
//               O(people): a 100k-person replay ticks as fast as a small one.
//   Isolation — every center here writes to a scratch decorations.json;
//               absent / poisoned / stale files → an honest status and a
//               rebuild; no tree → no start people, said so.
//   Sensor    — one START and one OUTCOME line per run through the sink;
//               the background job ends Done with a summary.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private let twoRoots = """
0 HEAD
1 _VS_MERGED Y
1 _VS_ROOT @I1@
1 _VS_ROOT @I2@
0 @I1@ INDI
1 NAME Richard Harding /Breen/ Jr
1 SEX M
1 _FSFTID GVQV-NW3
1 BIRT
2 DATE 4 MAR 1959
1 FAMC @F1@
1 FAMS @F0@
0 @I2@ INDI
1 NAME Donna /Hudson/
1 SEX F
1 _FSFTID G2CL-86B
1 FAMC @F2@
1 FAMS @F0@
0 @I3@ INDI
1 NAME Richard Harding /Breen/ Sr
1 SEX M
1 BIRT
2 DATE 21 FEB 1929
2 PLAC Boston, Massachusetts
1 FAMS @F1@
0 @I4@ INDI
1 NAME Eileen /Latta/
1 SEX F
1 FAMS @F1@
0 @I7@ INDI
1 NAME Richard C /Hudson/
1 SEX M
1 FAMS @F2@
0 @F0@ FAM
1 HUSB @I1@
1 WIFE @I2@
0 @F1@ FAM
1 HUSB @I3@
1 WIFE @I4@
1 CHIL @I1@
0 @F2@ FAM
1 HUSB @I7@
1 CHIL @I2@
0 TRLR
"""

@MainActor
private func scratchCenter() -> (FamilyTreeWalkCenter, URL) {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ftwalk-\(UUID().uuidString)")
    let center = FamilyTreeWalkCenter()
    center.storeURL = dir.appendingPathComponent(TreeWalkStore.fileName)
    return (center, dir)
}

@Suite("FamilyTreeWalkApp")
@MainActor
struct FamilyTreeWalkAppTests {

    // MARK: Logic

    @Test func defaultStartsAreTheHomePeoplePinnedOwnerFirst() {
        let g = GedcomFamilyGraph(gedcomText: twoRoots)
        #expect(FamilyTreeWalkCenter.defaultStarts(in: g, ownerFamilySearchID: nil) == ["@I1@", "@I2@"])
        #expect(FamilyTreeWalkCenter.defaultStarts(in: g, ownerFamilySearchID: "G2CL-86B") == ["@I2@", "@I1@"])
        #expect(FamilyTreeWalkCenter.defaultStarts(in: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR"),
                                                   ownerFamilySearchID: nil).isEmpty)
        let speakers = HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie",
                                                   archivistPersonName: nil, ownerFamilySearchID: "GVQV-NW3")
        #expect(FamilyTreeWalkCenter.displayNames(for: ["@I1@", "@I2@"], in: g, speakers: speakers) == ["Rick", "Donna"])
    }

    @Test func theFanPutsRickLeftAndDonnaRight() throws {
        let g = GedcomFamilyGraph(gedcomText: twoRoots)
        let r = try TreeWalk.walk(g, options: .init(starts: ["@I1@", "@I2@"]))
        let size = CGSize(width: 400, height: 400)
        let layout = TreeWalkFanLayout(result: r, size: size)
        #expect(layout.placed.count == r.visitedCount)
        let byLine = Dictionary(grouping: layout.placed.filter { $0.generation > 0 }, by: \.line)
        #expect(byLine[.first]?.allSatisfy { $0.point.x < size.width / 2 } == true, "Rick's ancestors fan left")
        #expect(byLine[.second]?.allSatisfy { $0.point.x > size.width / 2 } == true, "Donna's fan right")
        #expect(layout.placed.first { $0.generation == 0 }.map { $0.point.x < size.width / 2 } == true)
        #expect(layout.placed.filter { $0.generation > 0 }.allSatisfy { $0.from != nil })
    }

    @Test func walkTreeIsAnMFOKindWithADetailView() {
        #expect(MediaFileOperationKind.walkTree.badgeText == "Walk")
        #expect(MediaFileOperationKind.walkTree.logVerb == "walk tree")
        #expect(MediaFileOperationKind.walkTree.hasDetailView)
    }

    // MARK: Sensor — one START, one OUTCOME; saved; loaded back O(1)

    @Test func aRunLogsOneStartOneOutcomeSavesAndServesDecorations() async throws {
        let (center, dir) = scratchCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        var console: [String] = []
        center.consoleLog = { console.append($0) }
        let g = GedcomFamilyGraph(gedcomText: twoRoots)
        let result = await center.run(graph: g, options: .init(starts: ["@I1@", "@I2@"]), mode: .foreground,
                                      displayNames: ["Rick", "Donna"])
        let r = try #require(result)
        #expect(console.filter { $0.hasPrefix("Walk Tree: starting from") }.count == 1)
        #expect(console.filter { $0.hasPrefix("Walk Tree: analysis complete") }.count == 1)
        #expect(console.first?.contains("foreground") == true)
        #expect(console.last?.hasSuffix("decorations saved") == true)
        #expect(console == center.recentLines)
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(TreeWalkStore.fileName).path))
        #expect(center.decoration(for: "@I3@")?.line == .first)
        #expect(center.decoration(for: "@I3@")?.birthRegion == .newEngland)
        #expect(center.decoration(for: "@I7@")?.line == .second)
        // A fresh center reads the saved file back as current.
        let (other, _) = scratchCenter()
        other.storeURL = center.storeURL
        await other.ensureLoaded(for: g, speakers: .none)
        #expect(other.stored?.sourceKey == r.sourceKey)
        #expect(other.decoration(for: "@I3@") == center.decoration(for: "@I3@"))
        #expect(other.displayNames == ["Richard", "Donna"], "no owner configured → first given names")
    }

    // MARK: Isolation

    @Test func absentPoisonedAndStaleFilesSayWhyAndRebuild() async throws {
        let (center, dir) = scratchCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let g = GedcomFamilyGraph(gedcomText: twoRoots)
        await center.ensureLoaded(for: g, speakers: .none)
        #expect(center.stored == nil)
        #expect(center.status?.contains("not been walked") == true)

        let url = try #require(center.storeURL)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("not json at all".utf8).write(to: url)
        let (poisoned, _) = scratchCenter()
        poisoned.storeURL = url
        await poisoned.ensureLoaded(for: g, speakers: .none)
        #expect(poisoned.stored == nil)
        #expect(poisoned.status?.contains("could not be read") == true)

        // A walk over a DIFFERENT tree leaves a stale file for this one.
        let other = GedcomFamilyGraph(gedcomText: twoRoots.replacingOccurrences(of: "21 FEB 1929", with: "22 FEB 1929"))
        _ = await poisoned.run(graph: other, options: .init(starts: ["@I1@"]), mode: .background, displayNames: [])
        let (stale, _) = scratchCenter()
        stale.storeURL = url
        await stale.ensureLoaded(for: g, speakers: .none)
        #expect(stale.stored == nil)
        #expect(stale.status?.contains("out of date") == true)
        // …and walking this tree rebuilds it.
        _ = await stale.run(graph: g, options: .init(starts: ["@I1@"]), mode: .background, displayNames: [])
        let (fresh, _) = scratchCenter()
        fresh.storeURL = url
        await fresh.ensureLoaded(for: g, speakers: .none)
        #expect(fresh.stored != nil)
    }

    @Test func aTreeWithNoHomePeopleFailsHonestly() async {
        let (center, dir) = scratchCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        var lines: [String] = []
        center.consoleLog = { lines.append($0) }
        let result = await center.run(graph: GedcomFamilyGraph(gedcomText: "0 HEAD\n0 TRLR"),
                                      options: .init(starts: []), mode: .foreground, displayNames: [])
        #expect(result == nil)
        #expect(lines.count == 1)
        #expect(lines.first?.hasPrefix("Walk Tree: FAILED — No start person") == true)
    }

    // MARK: Background job

    @Test func theBackgroundJobEndsDoneWithASummary() async throws {
        let (center, dir) = scratchCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let g = GedcomFamilyGraph(gedcomText: twoRoots)
        let job = WalkTreeJob(graph: g, options: .init(starts: ["@I1@", "@I2@"]), displayNames: ["Rick", "Donna"],
                              center: center)
        job.start()
        await job.task?.value
        guard case .finished(let line) = job.state else { Issue.record("state \(job.state)"); return }
        #expect(line.contains("decorations saved"))
        #expect(job.fraction == 1)
        #expect(job.summary?.peopleWalked == 5)
        #expect(job.title == "Walk Tree — from Rick + Donna")
    }

    // MARK: Scale — the frame is O(batch), not O(people)

    @Test func animationTicksAreBoundedByTheBatchNotThePeople() async throws {
        let big = GedcomFamilyGraph(gedcomText: GedcomSyntheticPedigree.gedcom(people: 100_000))
        _ = big.index
        let root = try #require(big.rootPersonID)
        let r = try TreeWalk.walk(big, options: .init(starts: [root]))
        let layout = await TreeWalkAnimator.prepare(r, size: CGSize(width: 600, height: 600))
        let animator = TreeWalkAnimator(layout: layout, summary: r.summary, displayNames: ["Rick"])
        animator.nodesPerSecond = 600
        let clock = ContinuousClock()
        let t0 = clock.now
        for _ in 0..<30 { animator.tick() }
        let thirtyTicks = clock.now - t0
        #expect(animator.frame.visited == 600, "600 people/s × 1 s of ticks")
        #expect(animator.frame.recent.count == 20, "one tick = 600/30 people")
        #expect(thirtyTicks < .seconds(2), "30 frames took \(thirtyTicks)")
        // Instant: every tick is capped at maxBatch, however many people.
        animator.instant = true
        animator.tick()
        #expect(animator.frame.recent.count == min(TreeWalkAnimator.maxBatch, layout.placed.count - 600))
        while !animator.frame.finished { animator.tick() }
        #expect(animator.frame.visited == r.visitedCount)
        #expect(animator.frame.recent.isEmpty || animator.frame.recent.count <= TreeWalkAnimator.maxBatch)
        #expect(animator.frame.trail != nil)
    }
}
