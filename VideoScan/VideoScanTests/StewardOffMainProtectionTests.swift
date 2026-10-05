// StewardOffMainProtectionTests.swift
// 2026-10-04 perf: the content steward's rule 2 — the Delete planner's
// bulk-verb gate (`bulkDeleteRefusal`) and hold rule, asked per record —
// moved OFF the main thread. Rick's Release Time Profiler trace had it at
// 1.1 s of main thread per refresh (`isInsideMasterArchive` and the
// read-only marks' `hasNoReadOnlyVolumeMarks`, asked per record).
//
// DATA-RISK BOUNDARY: these refusals decide what may be deleted. The move
// changes WHERE and WHEN they run, never WHAT they decide. Pinned here:
//
//   Logic/Equivalence — on a synthetic catalog, in five model states (no
//               archive / read-only marks / both, provisional and BUILT
//               snapshots, a different drive mounted at a marked name), for
//               every record and every BulkVerbEffect:
//                 bulkDeleteRefusal(r, effect:, volume:)  ==  bulkDeleteGate(…).refusal(for: subject)
//               and the steward's main-actor reference rule ==
//               the off-main resolution, row for row, and the built queues
//               are equal. The matrix must produce every refusal kind.
//   Scale     — 100k records with an archive and two marks: the main-actor
//               half and the off-main resolution under explicit budgets,
//               old main-thread cost printed beside the new.
//   Sensor    — the refresh no longer asks the per-record gate on the main
//               actor; the gate keeps the instance rule's order.
// Isolation: every model has its own temp catalog directory; snapshots are
// injected (no disk probe). Media matrix: N/A — no media is opened.
//
// Suites: BulkDeleteGateEquivalenceTests · StewardOffMainScaleTests ·
//         StewardOffMainSensorTests

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
private func isolatedModel() -> VideoScanModel {
    let model = VideoScanModel()
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("test_steward_offmain_\(UUID().uuidString.prefix(8))", isDirectory: true)
    model.catalogStore = CatalogStore(directory: dir)
    return model
}

@MainActor
private func record(_ path: String, group: UUID? = nil, disposition: DuplicateDisposition = .none,
                    promoted: Bool = false) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.directory = (path as NSString).deletingLastPathComponent
    r.sizeBytes = 100
    r.partialMD5 = "m"
    r.durationSeconds = 61
    if let group {
        r.duplicateGroupID = group
        r.duplicateDisposition = disposition
        r.duplicateConfidence = .high
    }
    if promoted { r.derivationKind = ArchivePromotion.derivationKind }
    return r
}

@MainActor
private func target(_ path: String, readOnly: Bool = false, uuid: String? = nil) -> CatalogScanTarget {
    let t = CatalogScanTarget(searchPath: path)
    t.role = .workspace
    t.isReachable = true
    if readOnly { t.readOnlyMark = VolumeReadOnlyMark(markedAt: Date(timeIntervalSince1970: 1_790_000_000), volumeUUID: uuid) }
    return t
}

private let designation = MasterArchiveDesignation(
    targetPath: "/Volumes/FamilyArchive", rootPath: "/Volumes/FamilyArchive/Test_Family_Archive", volumeUUID: "ARCH")

/// Paths chosen to hit every branch of both halves: the tree, its root,
/// "." and ".." spellings, a name that merely starts like the root, the
/// archive drive, a look-alike drive, the marked drives (case, a subfolder
/// mark, the drive under another name), the boot disk, and "".
private let matrixPaths = [
    "/Volumes/FamilyArchive/Test_Family_Archive/1990s/a.mov",
    "/Volumes/FamilyArchive/Test_Family_Archive",
    "/Volumes/FamilyArchive/other/../Test_Family_Archive/b.mov",
    "/Volumes/FamilyArchive/./Test_Family_Archive/c.mov",
    "/Volumes/FamilyArchive/Test_Family_ArchiveX/d.mov",
    "/Volumes/FamilyArchive/loose/e.mov",
    "/Volumes/FamilyArchiveOld/f.mov",
    "/Volumes/SanDisk/g.mov",
    "/Volumes/SanDisk/sub/h.mov",
    "/Volumes/sandisk/i.mov",
    "/Volumes/SanDiskPro/j.mov",
    "/Volumes/SanDisk 1/k.mov",
    "/Volumes/LaCie/marked/l.mov",
    "/Volumes/LaCie/other/m.mov",
    "/Volumes/X9/n.mov",
    "/Users/someone/Movies/o.mov",
    "/private/var/p.mov",
    "",
]

enum StewardOffMainState: CaseIterable, Sendable {
    case bare, marksOnly, archiveOnly, archiveAndMarksProvisional, archiveAndMarksBuilt
}

@Suite("Bulk-delete gate as a value — same refusal as the instance rule", .serialized)
@MainActor
struct BulkDeleteGateEquivalenceTests {

    typealias State = StewardOffMainState

    /// A model in `state`, with records over the path matrix (each path
    /// plain, as a promoted archive copy, and in Angel use).
    private func model(_ state: State) -> (VideoScanModel, [VideoRecord]) {
        let m = isolatedModel()
        let marks = state == .marksOnly || state == .archiveAndMarksProvisional || state == .archiveAndMarksBuilt
        m.scanTargets = [target("/Volumes/SanDisk", readOnly: marks, uuid: "AAA"),
                         target("/Volumes/LaCie/marked", readOnly: marks),
                         target("/Volumes/X9"), target("/Volumes/FamilyArchive")]
        if state != .bare && state != .marksOnly { m.masterArchive = designation }
        let g = UUID()
        var recs: [VideoRecord] = []
        for (i, p) in matrixPaths.enumerated() {
            recs.append(record(p, group: g, disposition: i == 0 ? .keep : .extraCopy))
            recs.append(record(p, group: g, disposition: .extraCopy, promoted: true))
            recs.append(record(p, group: g, disposition: .extraCopy))
        }
        m.records = recs
        // The third copy of every path is in a batch the Angel prepared.
        var summary = m.archiveAngel.recommendations
        summary.preparedIDs = Set(recs.enumerated().filter { $0.offset % 3 == 2 }.map(\.element.id))
        summary.revision += 1
        m.archiveAngel.publishRecommendations(summary)
        if state == .archiveAndMarksBuilt {
            // BUILT snapshots, injected — no disk: the archive drive away
            // (so the rest is unprovable, and a catalog removal is allowed),
            // and a different drive mounted at the marked "SanDisk" while the
            // marked one is mounted as "SanDisk 1".
            let built = ArchiveVolumeProtection.make(designation: designation, aliasCandidates: m.archiveAliasCandidates,
                                                     mountedRoots: { ["/Volumes/SanDisk", "/Volumes/SanDisk 1", "/Volumes/X9"] },
                                                     probe: { ["/Volumes/X9": "X9X9", "/Volumes/SanDisk": "BBB",
                                                               "/Volumes/SanDisk 1": "AAA"][$0] },
                                                     identity: { _ in nil }, networkRoots: { [] })
            m.archiveVolumeSnapshotCache.builtFor = designation
            m.archiveVolumeSnapshotCache.builtForCandidates = m.archiveAliasCandidates
            m.archiveVolumeSnapshotCache.snapshot = built
            m.archiveVolumeSnapshotCache.isFresh = true
            let ro = ReadOnlyVolumeProtection.make(marks: m.readOnlyVolumeMarks,
                                                   mountedRoots: { ["/Volumes/SanDisk 1", "/Volumes/X9"] },
                                                   probe: { p in p == "/Volumes/SanDisk" ? "BBB" : p == "/Volumes/SanDisk 1" ? "AAA" : nil },
                                                   identity: { _ in nil }, networkRoots: { [] })
            m.readOnlyVolumeSnapshotCache.snapshot = ro
            m.readOnlyVolumeSnapshotCache.isFresh = true
        }
        return (m, recs)
    }

    @Test(arguments: StewardOffMainState.allCases)
    func theGateValueRefusesExactlyWhatTheInstanceRuleRefuses(_ state: StewardOffMainState) {
        let (m, recs) = model(state)
        if state == .archiveAndMarksBuilt {
            #expect(m.isArchiveVolumeSnapshotFresh && m.archiveVolumeProtection()?.isProvisional == false, "the built archive snapshot is read")
            #expect(m.readOnlyVolumeProtection().isBuilt, "the built read-only snapshot is read")
        }
        let snapshot = m.archiveVolumeProtection()
        var compared = 0
        for effect in [VideoScanModel.BulkVerbEffect.removesFiles, .catalogRemoval, .catalogOnly] {
            // With the verb's snapshot, and with none (single-record callers).
            let withSnapshot = m.bulkDeleteGate(effect: effect, volume: snapshot)
            let without = m.bulkDeleteGate(effect: effect)
            for r in recs {
                let subject = m.bulkDeleteSubject(r)
                #expect(m.bulkDeleteRefusal(r, effect: effect, volume: snapshot) == withSnapshot.refusal(for: subject),
                        "\(state) \(effect) \(r.fullPath) copy=\(subject.isArchiveCopy)")
                #expect(m.bulkDeleteRefusal(r, effect: effect) == without.refusal(for: subject),
                        "\(state) \(effect) (no snapshot) \(r.fullPath)")
                compared += 2
            }
        }
        #expect(compared == recs.count * 6)
    }

    /// The steward: main-actor reference vs the live off-main path, row for
    /// row, and the queues they build.
    @Test(arguments: StewardOffMainState.allCases)
    func theStewardsOffMainProtectionEqualsTheMainActorReference(_ state: StewardOffMainState) async {
        let (m, _) = model(state)
        let reference = StewardCaseBuilder.project(m.records, protection: m.stewardProtectionRule())
        let rule = m.stewardRuleCapture()
        let projected = StewardCaseBuilder.project(m.records, facts: rule.facts)
        let gate = rule.gate
        let facts = projected.facts
        let rows = projected.inputs
        let resolved = await Task.detached(priority: .utility) {
            var inputs = rows
            VideoScanModel.resolveStewardProtection(&inputs, facts: facts, gate: gate)
            return inputs
        }.value
        #expect(resolved.count == reference.count && !resolved.isEmpty)
        #expect(resolved == reference, "\(state): a row's protection differs between the main-actor rule and the off-main one")
        for (a, b) in zip(resolved, reference) where a.protection != b.protection {
            Issue.record("\(state) \(a.fullPath): off-main \(a.protection) vs reference \(b.protection)")
        }
        for crossMode in [false, true] {
            let q1 = StewardCaseBuilder.build(inputs: reference, volumes: [], mountedRoots: ["/"], alsoCleanUpWorkingCopies: crossMode)
            let q2 = StewardCaseBuilder.build(inputs: resolved, volumes: [], mountedRoots: ["/"], alsoCleanUpWorkingCopies: crossMode)
            #expect(q1 == q2, "\(state): the queues differ")
        }
    }

    /// The matrix is not vacuous: across the states it produces every
    /// refusal kind and every protection.
    @Test func theMatrixCoversEveryRefusalAndEveryProtection() {
        var refusals = Set<String>()
        var protections = Set<StewardProtection>()
        for state in State.allCases {
            let (m, recs) = model(state)
            for effect in [VideoScanModel.BulkVerbEffect.removesFiles, .catalogRemoval] {
                let gate = m.bulkDeleteGate(effect: effect, volume: m.archiveVolumeProtection())
                for r in recs {
                    switch gate.refusal(for: m.bulkDeleteSubject(r)) {
                    case nil: refusals.insert("nil")
                    case .archiveTree?: refusals.insert("tree")
                    case .archiveVolume?: refusals.insert("volume")
                    case .archiveVolumeUnprovable?: refusals.insert("unprovable")
                    case .readOnlyVolume?: refusals.insert("readOnly")
                    case .readOnlyVolumeDifferentDrive?: refusals.insert("readOnlyDifferent")
                    }
                }
            }
            let rule = m.stewardProtectionRule()
            for r in recs { protections.insert(rule(r)) }
        }
        #expect(refusals == ["nil", "tree", "volume", "unprovable", "readOnly", "readOnlyDifferent"], "covered: \(refusals.sorted())")
        #expect(protections == [.none, .archived, .archiveDrive, .archiveCopy, .angel, .readOnlyDrive], "covered: \(protections)")
    }
}

@Suite("Steward off-main rule 2 — scale", .serialized)
@MainActor
struct StewardOffMainScaleTests {

    /// 100k records over six drives (a sixth on the archive drive, a sixth
    /// inside the tree, two drives marked Read only). Budgets (Release):
    /// the main-actor half under 1.5 s, the off-main resolution under 1 s.
    /// The old main-actor path is timed beside them and printed.
    @Test func hundredThousandRecordsUnderBudget() async {
        let m = isolatedModel()
        m.scanTargets = [target("/Volumes/SanDisk", readOnly: true, uuid: "AAA"), target("/Volumes/LaCie/marked", readOnly: true),
                         target("/Volumes/X9"), target("/Volumes/FamilyArchive")]
        m.masterArchive = designation
        let drives = ["/Volumes/SanDisk", "/Volumes/LaCie/marked", "/Volumes/X9", "/Volumes/FamilyArchive/loose",
                      "/Volumes/FamilyArchive/Test_Family_Archive", "/Users/someone/Movies"]
        var recs: [VideoRecord] = []
        recs.reserveCapacity(100_000)
        for i in 0..<100_000 {
            recs.append(record("\(drives[i % 6])/folder\(i % 500)/clip\(i).mov", promoted: i % 50 == 0))
        }
        m.records = recs
        let clock = ContinuousClock()

        let oldStart = clock.now
        let reference = StewardCaseBuilder.project(m.records, protection: m.stewardProtectionRule())
        let oldMain = clock.now - oldStart

        let newStart = clock.now
        let rule = m.stewardRuleCapture()
        let projected = StewardCaseBuilder.project(m.records, facts: rule.facts)
        let newMain = clock.now - newStart

        let gate = rule.gate
        let facts = projected.facts
        let handoff = StewardInputHandoff(projected.inputs)
        let (resolved, offMain) = await Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            var inputs = handoff.take()
            VideoScanModel.resolveStewardProtection(&inputs, facts: facts, gate: gate)
            return (inputs, ContinuousClock.now - start)
        }.value

        print("PERF_SCALE steward: old main-actor projection+rule2 \(oldMain); new main-actor half \(newMain); off-main resolve \(offMain)")
        #expect(resolved == reference, "100k: the off-main path disagrees with the reference")
        #expect(newMain < .milliseconds(1_500), "main-actor half took \(newMain)")
        #expect(offMain < PerformanceLane.debugCeiling(.milliseconds(1_000)), "off-main resolution took \(offMain)")
    }
}

@Suite("Steward off-main rule 2 — sensors")
struct StewardOffMainSensorTests {

    private func code(_ name: String) throws -> String {
        try SourceTree.appSource(named: name).split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    @Test func theRefreshAsksTheGateOffTheMainActor() throws {
        let src = try code("VideoScanModel+Steward.swift")
        let start = try #require(src.range(of: "func scheduleStewardRefresh() {"))
        let end = try #require(src.range(of: "func stewardPaneAppeared() {", range: start.upperBound..<src.endIndex))
        let refresh = String(src[start.upperBound..<end.lowerBound])
        #expect(!refresh.contains("stewardProtectionRule()"), "the refresh asks the per-record gate on the main actor again")
        #expect(refresh.contains("StewardCaseBuilder.project(records, facts: rule.facts)"))
        let detached = try #require(refresh.range(of: "Task.detached(priority: .utility) {"))
        let tail = String(refresh[detached.upperBound...])
        #expect(tail.contains("VideoScanModel.resolveStewardProtection(&inputs, facts: ruleFacts, gate: gate)"),
                "rule 2 is resolved inside the detached task")
        #expect(src.contains("let gate = bulkDeleteGate(volume: archiveDrive)") && src.contains("let hold = duplicateDeletionHoldRule()"),
                "the off-main path captures the planner's own two rules")
    }

    @Test func theGateValueKeepsTheInstanceRulesOrder() throws {
        let src = try code("VideoScanModel+MasterArchive.swift")
        let start = try #require(src.range(of: "func refusal(for s: BulkDeleteSubject) -> BulkDeleteRefusal? {"))
        let body = String(src[start.upperBound...].prefix(1_400))
        let order = ["if s.isArchiveCopy { return .archiveTree }",
                     "VideoScanModel.isInsideMasterArchive(path: s.path, root: archiveRoot)",
                     "snapshot.verdict(forPath: s.path)",
                     "readOnly.verdict(forPath: s.path)"]
        var cursor = body.startIndex
        for step in order {
            let hit = try #require(body.range(of: step, range: cursor..<body.endIndex), "missing or out of order: \(step)")
            cursor = hit.upperBound
        }
        #expect(src.contains("Self.isInsideMasterArchive(path: path, root: masterArchiveRootPath)"),
                "the instance predicate and the gate share one containment test")
    }
}
