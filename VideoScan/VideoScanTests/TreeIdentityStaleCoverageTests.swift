// TreeIdentityStaleCoverageTests.swift
// Deterministic sensors for graph/profile replacement while derivation is
// held, plus fail-closed pin action tokens. Pure in-memory GEDCOM fixtures;
// no defaults, disk, app launch, sleeps, or timing races.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private actor TreeIdentityCoverageGate {
    private var firstPass = true
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    func holdFirstPass() async {
        guard firstPass else { return }
        firstPass = false
        started = true
        let waiters = startedWaiters
        startedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiter = $0 }
    }

    func waitUntilStarted() async {
        guard !started else { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

@MainActor
@Suite("TreeIdentityCenter — replacement coverage")
struct TreeIdentityStaleCoverageTests {
    typealias F = TreeIdentityFixture

    private func makeCenter() -> (TreeIdentityCenter, KinshipDisplayCenter) {
        let kinship = KinshipDisplayCenter()
        let center = TreeIdentityCenter(kinshipCenter: kinship)
        center.defaults = nil
        center.speakers = {
            HallieTurnExecutor.Speakers(
                ownerName: "Rick Breen",
                archivistName: "Hallie Mae",
                ownerFamilySearchID: "GVQV-NW3"
            )
        }
        return (center, kinship)
    }

    private func installHeldPass(
        on center: TreeIdentityCenter,
        gate: TreeIdentityCoverageGate
    ) {
        center.derivationPass = { graph, subjects, speakers in
            await gate.holdFirstPass()
            return TreeIdentityDeriver(
                graph: graph,
                subjects: subjects,
                ownerName: speakers.ownerName,
                ownerFamilySearchID: speakers.ownerFamilySearchID
            ).deriveAll()
        }
    }

    /// Replacing graph A with a non-nil graph B invalidates held A even
    /// before a B refresh starts. Generation owns acceptance; nil-ness and
    /// parent-task cancellation are irrelevant.
    @Test func nonnilGraphReplacementRejectsHeldPriorGeneration() async {
        let (center, kinship) = makeCenter()
        let gate = TreeIdentityCoverageGate()
        var saved: [POIProfile] = []
        center.store = { saved.append($0) }
        installHeldPass(on: center, gate: gate)
        let profiles = [F.rick, F.donna]

        kinship.install(graph: F.graph)
        let heldA = Task { await center.refresh(profiles: profiles) }
        await gate.waitUntilStarted()

        kinship.install(graph: F.graph)
        await gate.release()
        await heldA.value

        #expect(center.derivations.isEmpty)
        #expect(center.derivationRunCount == 0)
        #expect(center.pinsRevision == 0)
        #expect(saved.isEmpty, "graph A must not auto-pin in generation B")
    }

    /// A profile revision starts a newer refresh without cancelling held A.
    /// A must not overwrite the revised memo or auto-pin from its obsolete
    /// subject snapshot when it eventually returns.
    @Test func uncancelledProfileRevisionRejectsHeldPriorSignature() async {
        let (center, kinship) = makeCenter()
        let gate = TreeIdentityCoverageGate()
        var saved: [POIProfile] = []
        center.store = { saved.append($0) }
        installHeldPass(on: center, gate: gate)
        kinship.install(graph: F.graph)

        let heldA = Task { await center.refresh(profiles: [F.rick]) }
        await gate.waitUntilStarted()

        var revised = F.rick
        revised.notInFamilyTree = true
        await center.refresh(profiles: [revised])
        #expect(center.derivations.isEmpty)
        #expect(center.derivationRunCount == 1)

        await gate.release()
        await heldA.value

        #expect(center.derivations.isEmpty)
        #expect(center.derivationRunCount == 1)
        #expect(center.showInTreeState(for: revised, among: [revised]) == .notInTree)
        #expect(center.pinsRevision == 0)
        #expect(saved.isEmpty, "obsolete owner verdict must not auto-pin")
    }

    @Test func pinFailsClosedWithoutAnInstalledGraph() {
        let (center, _) = makeCenter()
        var saved: [POIProfile] = []
        center.store = { saved.append($0) }

        let outcome = center.pin(
            F.candidate("@I1@"),
            on: F.rick,
            among: [F.rick],
            attestation: "picked: stale sheet"
        )

        #expect(outcome.refusal?.contains("family tree changed") == true)
        #expect(saved.isEmpty)
        #expect(center.pinsRevision == 0)
    }

    @Test func pointerOnlyCandidateCannotRebindToReplacementRecord() throws {
        let (center, kinship) = makeCenter()
        var saved: [POIProfile] = []
        center.store = { saved.append($0) }
        let graphA = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @P1@ INDI
        1 NAME Alex /River/
        1 SEX M
        1 BIRT
        2 DATE 1900
        2 PLAC Boston, Massachusetts
        0 TRLR
        """)
        let graphB = GedcomFamilyGraph(gedcomText: """
        0 HEAD
        0 @P1@ INDI
        1 NAME Blake /River/
        1 SEX M
        1 BIRT
        2 DATE 1901
        2 PLAC Albany, New York
        0 TRLR
        """)
        let reviewed = TreeIdentityCandidate(try #require(graphA.people["@P1@"]))
        #expect(reviewed.familySearchID == nil)

        kinship.install(graph: graphA)
        kinship.install(graph: graphB)
        let outcome = center.pin(
            reviewed,
            on: F.rick,
            among: [F.rick],
            attestation: "picked: prior graph"
        )

        #expect(outcome.refusal?.contains("family tree changed") == true)
        #expect(saved.isEmpty)
        #expect(center.pinsRevision == 0)
    }

    /// Candidate equality is the pin action token's content guard. A reused
    /// GEDCOM pointer or FamilySearch ID with changed visible facts is not
    /// the candidate the person reviewed.
    @Test func sameIDsWithChangedDetailsAreDifferentCandidates() throws {
        func candidate(
            name: String,
            birthDate: String,
            birthPlace: String
        ) throws -> TreeIdentityCandidate {
            let graph = GedcomFamilyGraph(gedcomText: """
            0 HEAD
            0 @I1@ INDI
            1 NAME \(name)
            1 SEX M
            1 _FSFTID SAME-001
            1 BIRT
            2 DATE \(birthDate)
            2 PLAC \(birthPlace)
            0 TRLR
            """)
            return TreeIdentityCandidate(try #require(graph.people["@I1@"]))
        }

        let reviewed = try candidate(
            name: "Alex /River/",
            birthDate: "1900",
            birthPlace: "Boston, Massachusetts"
        )
        let unchanged = try candidate(
            name: "Alex /River/",
            birthDate: "1900",
            birthPlace: "Boston, Massachusetts"
        )
        let changed = try candidate(
            name: "Blake /River/",
            birthDate: "1901",
            birthPlace: "Albany, New York"
        )

        #expect(reviewed == unchanged)
        #expect(reviewed.personID == changed.personID)
        #expect(reviewed.familySearchID == changed.familySearchID)
        #expect(reviewed != changed)
    }
}
