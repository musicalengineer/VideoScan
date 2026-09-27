// FamilyTreeWalkAppTests.swift
// The Family Tree Walk, app half (2026-09-27). Dimensions:
//   Logic     — default start people (pinned owner first, Rick + Donna),
//               display names, the fan layout (Rick left, Donna right),
//               the fan FITS its canvas at depth 3/5/10/all (2026-09-27),
//               the sheet fits its window, every node settles at the end,
//               the pace note, the summary's scope labels.
//   Scale     — the animation's per-tick frame is O(batch), never
//               O(people): a 100k-person replay ticks as fast as a small one.
//   Isolation — every center here writes to a scratch decorations.json;
//               absent / poisoned / stale files → an honest status and a
//               rebuild; no tree → no start people, said so.
//   Sensor    — one START and one OUTCOME line per run through the sink;
//               an automatic refresh writes exactly ONE line (stale → one
//               walk, fresh → none, a burst → one, waits for a foreground
//               walk); the model has no walk center in the test host.

import CoreGraphics
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

/// Two starts (Rick @R0@, Donna @D0@), each with a COMPLETE pedigree
/// `depth` generations deep — the widest possible fan for that depth.
/// `lopsided` gives Donna only a father line, so the two sides differ.
private func twoStartPedigree(depth: Int, lopsided: Bool = false) -> GedcomFamilyGraph {
    var out = ["0 HEAD", "1 _VS_MERGED Y", "1 _VS_ROOT @R0@", "1 _VS_ROOT @D0@"]
    var fams: [String] = []
    for side in ["R", "D"] {
        let full = !(lopsided && side == "D")
        // Heap numbering: person k's parents are 2k+1 (father) and 2k+2 (mother).
        let last = full ? (1 << (depth + 1)) - 2 : depth
        func parents(_ k: Int) -> (Int, Int?) { full ? (2 * k + 1, 2 * k + 2) : (k + 1, nil) }
        for k in 0...last {
            out.append("0 @\(side)\(k)@ INDI")
            out.append("1 NAME P\(k) /\(side)/")
            out.append("1 SEX \(full ? (k == 0 || k % 2 == 1 ? "M" : "F") : "M")")
            let (f, m) = parents(k)
            if f <= last {
                out.append("1 FAMC @F\(side)\(k)@")
                var fam = ["0 @F\(side)\(k)@ FAM", "1 HUSB @\(side)\(f)@"]
                if let m, m <= last { fam.append("1 WIFE @\(side)\(m)@") }
                fam.append("1 CHIL @\(side)\(k)@")
                fams += fam
            }
        }
    }
    return GedcomFamilyGraph(gedcomText: (out + fams + ["0 TRLR"]).joined(separator: "\n"))
}

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

    /// Rick 2026-09-27: "it doesn't fit". Every dot AND its reveal halo lies
    /// inside the canvas with a margin, the fan is centred (left extent =
    /// right extent, top = bottom, for a complete pedigree) and it uses the
    /// canvas (not shrunk to a speck) — at every depth the sheet offers.
    @Test(arguments: [3, 5, 10, 12])   // 12 stands in for "All" on a deep tree
    func theFanFitsItsCanvasAtEveryDepth(depth: Int) throws {
        let g = twoStartPedigree(depth: depth)
        let r = try TreeWalk.walk(g, options: .init(starts: ["@R0@", "@D0@"], maxGenerations: depth == 12 ? nil : depth))
        let size = CGSize(width: 600, height: 600)
        let layout = TreeWalkFanLayout(result: r, size: size)
        #expect(layout.placed.count == r.visitedCount)
        let halo = TreeWalkFanLayout.haloFactor
        var minX = CGFloat.infinity, maxX = -CGFloat.infinity, minY = CGFloat.infinity, maxY = -CGFloat.infinity
        for p in layout.placed {
            let e = p.radius * halo
            minX = min(minX, p.point.x - e); maxX = max(maxX, p.point.x + e)
            minY = min(minY, p.point.y - e); maxY = max(maxY, p.point.y + e)
        }
        #expect(minX >= 0 && minY >= 0 && maxX <= size.width && maxY <= size.height,
                "depth \(depth): x \(minX)…\(maxX), y \(minY)…\(maxY) in 600×600")
        #expect(abs((size.width / 2 - minX) - (maxX - size.width / 2)) < 1, "left and right extents match")
        #expect(abs((size.height / 2 - minY) - (maxY - size.height / 2)) < 1, "top and bottom extents match")
        #expect(max(maxX - minX, maxY - minY) > size.width * 0.8, "the fan fills the canvas")
    }

    @Test func aLopsidedTreeStillFitsAndStaysCentred() throws {
        let r = try TreeWalk.walk(twoStartPedigree(depth: 6, lopsided: true), options: .init(starts: ["@R0@", "@D0@"]))
        let size = CGSize(width: 500, height: 500)
        let layout = TreeWalkFanLayout(result: r, size: size)
        for p in layout.placed {
            let e = p.radius * TreeWalkFanLayout.haloFactor
            #expect(p.point.x - e >= 0 && p.point.x + e <= size.width && p.point.y - e >= 0 && p.point.y + e <= size.height)
        }
        // The starts straddle the centre: the fan's origin is the canvas centre.
        let starts = layout.placed.filter { $0.generation == 0 }
        #expect(starts.count == 2)
        #expect(abs((starts[0].point.x + starts[1].point.x) / 2 - size.width / 2) < 0.5)
    }

    /// Rick 2026-09-27: at "Walk complete" the last generation still showed
    /// as white haloed dots. On completion NOTHING is "just revealed".
    @Test func everyNodeSettlesIntoItsLineColourWhenTheReplayEnds() async throws {
        let r = try TreeWalk.walk(twoStartPedigree(depth: 3), options: .init(starts: ["@R0@", "@D0@"], maxGenerations: 3))
        #expect(r.visitedCount == 30)
        let layout = await TreeWalkAnimator.prepare(r, size: CGSize(width: 600, height: 600))
        let animator = TreeWalkAnimator(layout: layout, summary: r.summary, displayNames: ["Rick", "Donna"])
        animator.nodesPerSecond = 600                       // 20 per tick: 20, then the last 10
        animator.tick()
        #expect(animator.frame.recent.count == 20, "mid-replay the batch glows")
        #expect(!animator.frame.finished)
        animator.tick()
        #expect(animator.frame.finished)
        #expect(animator.frame.visited == 30)
        #expect(animator.frame.recent.isEmpty, "the final batch settles; no white halos at Walk complete")

        // Skip to end (Instant) settles too.
        let again = TreeWalkAnimator(layout: layout, summary: r.summary, displayNames: ["Rick", "Donna"])
        again.skipToEnd()
        again.tick()
        #expect(again.frame.finished)
        #expect(again.frame.recent.isEmpty)
    }

    /// The sheet sizes to the Family Tree window: inside it on a 13"
    /// laptop, capped on a big display, never below the usable minimum.
    @Test func theSheetFitsTheWindowItHangsFrom() {
        let laptop13 = CGSize(width: 1_280, height: 740)          // full-screen window, 1280×800 display
        let s = FamilyTreeWalkSheet.watchingSize(host: laptop13)
        #expect(s.width <= laptop13.width && s.height <= laptop13.height)
        #expect(s == CGSize(width: 1_100, height: 692))
        let small = CGSize(width: 800, height: 600)
        #expect(FamilyTreeWalkSheet.watchingSize(host: small) == CGSize(width: 752, height: 552))
        let studio = CGSize(width: 3_000, height: 1_600)
        #expect(FamilyTreeWalkSheet.watchingSize(host: studio) == FamilyTreeWalkSheet.maximumWatchingSize)
        let tiny = CGSize(width: 500, height: 400)
        #expect(FamilyTreeWalkSheet.watchingSize(host: tiny) == FamilyTreeWalkSheet.minimumWatchingSize)
        #expect(FamilyTreeWalkSheet.watchingSize(host: .zero) == CGSize(width: 900, height: 700), "unknown host")
        // The minimum still holds the side panel and a usable fan.
        let inner = FamilyTreeWalkSheet.minimumWatchingSize.width - 40
        #expect(inner - TreeWalkAnimationView.sidePanelWidth - 16 >= TreeWalkAnimationView.minimumFan)
    }

    /// Manager 2026-09-27: a 45 s replay of a 50 ms analysis must not look
    /// like a slow algorithm.
    @Test func thePaceNoteSeparatesTheAnalysisFromTheReplay() {
        func note(_ ms: Double, visited: Int = 0, total: Int = 27_000, rate: Double = 600,
                  instant: Bool = false, paused: Bool = false, finished: Bool = false) -> String {
            TreeWalkAnimator.paceNote(analysisMilliseconds: ms, visited: visited, total: total, nodesPerSecond: rate,
                                      instant: instant, paused: paused, finished: finished)
        }
        #expect(note(54) == "Analysis done in 54 ms — replaying the walk at 600 people/s (about 45 s left). Skip to end shows it all now.")
        #expect(note(54, total: 90_000).contains("(about 3 min left)"))
        #expect(note(1_340, visited: 29, total: 30).hasPrefix("Analysis done in 1.3 s — "))
        #expect(note(1_340, visited: 29, total: 30).contains("under a second"))
        #expect(note(54, instant: true) == "Analysis done in 54 ms — drawing the rest now.")
        #expect(note(54, paused: true).contains("replay paused"))
        #expect(note(214, finished: true) == "Analysis took 214 ms; the replay is only the animation.")
    }

    /// The summary's check title names the scope; the whole-tree figure is
    /// labelled, and absent when the walk covered every check.
    @Test func theSummaryLabelsItsScope() throws {
        var s = TreeWalk.Summary()
        s.peopleInTree = 39_249; s.peopleWalked = 30
        s.warnCount = 9; s.infoCount = 3
        s.treeWarnCount = 1_119; s.treeInfoCount = 297
        #expect(TreeWalkSummaryView.checksTitle(s) == "Checks on these 30 people (9 warn, 3 info)")
        #expect(TreeWalkSummaryView.wholeTreeLine(s)
                == "Whole tree (39,249 people): 1,416 checks (1,119 warn) — in each person's inspector and decorations.json")
        s.treeWarnCount = 9; s.treeInfoCount = 3
        #expect(TreeWalkSummaryView.wholeTreeLine(s) == nil)
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

    // MARK: Automatic refresh (Rick 2026-09-27: no background walk — the
    // decorations re-walk silently whenever they go stale)

    private func autoCenter(debounce: Duration = .milliseconds(10)) -> (FamilyTreeWalkCenter, URL) {
        let (center, dir) = scratchCenter()
        center.refreshDebounce = debounce
        center.ownerFamilySearchID = { nil }
        center.speakers = { .none }
        return (center, dir)
    }

    @Test func staleDecorationsGetOneSilentWalkWithTheReasonLogged() async throws {
        let (center, dir) = autoCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let g = GedcomFamilyGraph(gedcomText: twoRoots)
        center.treeDidChange(g, reason: "tree refreshed")
        await center.waitForRefresh()
        #expect(center.automaticWalkCount == 1)
        #expect(center.recentLines.count == 1, "ONE line, no START/PROGRESS/OUTCOME: \(center.recentLines)")
        let line = try #require(center.recentLines.first)
        #expect(line.hasPrefix("Walk Tree: decorations refreshed — 5 people, 0 checks, "))
        #expect(line.hasSuffix(" ms (reason: tree refreshed)"))
        #expect(center.decoration(for: "@I3@")?.line == .first, "installed for the inspector")
        #expect(FileManager.default.fileExists(atPath: dir.appendingPathComponent(TreeWalkStore.fileName).path))
    }

    @Test func freshDecorationsMeanNoWalkAndNoLine() async throws {
        let (first, dir) = autoCenter()
        defer { try? FileManager.default.removeItem(at: dir) }
        let g = GedcomFamilyGraph(gedcomText: twoRoots)
        first.treeDidChange(g, reason: "tree loaded")
        await first.waitForRefresh()
        #expect(first.automaticWalkCount == 1)
        // Same tree again (in this center, and in a fresh one reading the file).
        first.treeDidChange(g, reason: "tree loaded")
        await first.waitForRefresh()
        #expect(first.automaticWalkCount == 1)
        let (second, _) = autoCenter()
        second.storeURL = first.storeURL
        second.treeDidChange(g, reason: "tree loaded")
        await second.waitForRefresh()
        #expect(second.automaticWalkCount == 0)
        #expect(second.recentLines.isEmpty)
        #expect(second.decoration(for: "@I3@")?.line == .first, "the current file is installed")
    }

    @Test func aBurstOfThreeChangesIsOneWalk() async throws {
        let (center, dir) = autoCenter(debounce: .milliseconds(150))
        defer { try? FileManager.default.removeItem(at: dir) }
        let g = GedcomFamilyGraph(gedcomText: twoRoots)
        center.treeDidChange(g, reason: "tree loaded")
        center.treeDidChange(g, reason: "identity ruling")
        center.treeDidChange(g, reason: "tree refreshed")
        await center.waitForRefresh()
        #expect(center.automaticWalkCount == 1)
        #expect(center.recentLines.count == 1)
        #expect(center.recentLines.first?.hasSuffix("(reason: tree loaded, identity ruling, tree refreshed)") == true)
    }

    @Test func anAutomaticRefreshWaitsForARunningForegroundWalk() async throws {
        let (center, dir) = autoCenter(debounce: .zero)
        defer { try? FileManager.default.removeItem(at: dir) }
        let a = GedcomFamilyGraph(gedcomText: twoRoots)
        // A different tree, so the refresh really has to walk after the
        // foreground walk saved tree A.
        let b = GedcomFamilyGraph(gedcomText: twoRoots.replacingOccurrences(of: "21 FEB 1929", with: "22 FEB 1929"))
        var sawRunningWhenAsked = false
        _ = await center.run(graph: a, options: .init(starts: ["@I1@", "@I2@"]), mode: .foreground,
                             displayNames: ["Rick", "Donna"]) { event in
            if case .started = event {
                sawRunningWhenAsked = center.isRunning
                center.treeDidChange(b, reason: "tree refreshed")
            }
        }
        await center.waitForRefresh()
        #expect(sawRunningWhenAsked)
        #expect(center.automaticWalkCount == 1)
        let outcome = try #require(center.recentLines.firstIndex { $0.hasPrefix("Walk Tree: analysis complete") })
        let refreshed = try #require(center.recentLines.firstIndex { $0.hasPrefix("Walk Tree: decorations refreshed") })
        #expect(refreshed > outcome, "the refresh walked only after the foreground walk finished")
        #expect(center.stored?.sourceKey == TreeWalkStore.sourceKey(of: b))
    }

    @Test func theModelHasNoWalkCenterInTheTestHost() {
        // Isolation: a synthetic tree installed by any model test must never
        // re-walk into the REAL decorations.json.
        #expect(FamilyTreeLiveModel().walkCenter == nil)
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
