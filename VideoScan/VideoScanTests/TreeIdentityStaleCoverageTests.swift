// TreeIdentityStaleCoverageTests.swift
// Deterministic sensors for graph/profile replacement while derivation is
// held, plus fail-closed pin action tokens. Pure in-memory GEDCOM fixtures;
// no defaults, disk, app launch, sleeps, or timing races.

import Foundation
import Dispatch
import Testing
import VideoScanCore
@testable import VideoScan

/// A semaphore wait runs on a detached worker so the MainActor stays free for
/// `TreeIdentityCenter.refresh`. Unlike a bare continuation, both rendezvous
/// have a hard failure bound and cannot strand the test process.
private final class TreeIdentityCoverageGate: @unchecked Sendable {
    private static let timeout = DispatchTimeInterval.seconds(5)
    private let stateLock = NSLock()
    private var firstPass = true
    private let started = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)

    private func claimFirstPass() -> Bool {
        stateLock.lock()
        let shouldHold = firstPass
        firstPass = false
        stateLock.unlock()
        return shouldHold
    }

    private static func waitForSignal(_ semaphore: DispatchSemaphore) -> Bool {
        semaphore.wait(timeout: .now() + timeout) == .success
    }

    func holdFirstPass() async -> Bool {
        let shouldHold = claimFirstPass()
        guard shouldHold else { return true }

        started.signal()
        return await Task.detached { [released] in
            Self.waitForSignal(released)
        }.value
    }

    func waitUntilStarted() async -> Bool {
        await Task.detached { [started] in
            Self.waitForSignal(started)
        }.value
    }

    func release() {
        released.signal()
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
            let released = await gate.holdFirstPass()
            #expect(released, "held derivation did not receive its release signal")
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
        let started = await gate.waitUntilStarted()
        #expect(started, "held derivation did not start")
        guard started else {
            gate.release()
            await heldA.value
            return
        }

        kinship.install(graph: F.graph)
        gate.release()
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
        let started = await gate.waitUntilStarted()
        #expect(started, "held derivation did not start")
        guard started else {
            gate.release()
            await heldA.value
            return
        }

        var revised = F.rick
        revised.notInFamilyTree = true
        await center.refresh(profiles: [revised])
        #expect(center.derivations.isEmpty)
        #expect(center.derivationRunCount == 1)

        gate.release()
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
        2 DATE 1900
        2 PLAC Boston, Massachusetts
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

    /// Every stored field participates in the synthesized equality used by
    /// the pin action token. Each variant changes exactly one field, so this
    /// fails if equality ever degrades to (for example) IDs + name.
    @Test func everyStoredFieldParticipatesInCandidateEquality() throws {
        func candidate(
            personID: String = "@I1@",
            name: String = "Alex /River/",
            familySearchID: String? = "SAME-001",
            birthDate: String? = "1900",
            birthPlace: String? = "Boston, Massachusetts",
            sex: String = "M"
        ) throws -> TreeIdentityCandidate {
            let familySearchLine = familySearchID.map { "1 _FSFTID \($0)" } ?? ""
            let birthLines: String = {
                guard birthDate != nil || birthPlace != nil else { return "" }
                let dateLine = birthDate.map { "2 DATE \($0)" } ?? ""
                let placeLine = birthPlace.map { "2 PLAC \($0)" } ?? ""
                return ["1 BIRT", dateLine, placeLine]
                    .filter { !$0.isEmpty }
                    .joined(separator: "\n")
            }()
            let graph = GedcomFamilyGraph(gedcomText: """
            0 HEAD
            0 \(personID) INDI
            1 NAME \(name)
            1 SEX \(sex)
            \(familySearchLine)
            \(birthLines)
            0 TRLR
            """)
            return TreeIdentityCandidate(try #require(graph.people[personID]))
        }

        let reviewed = try candidate()
        let unchanged = try candidate()
        let oneFieldVariants: [(String, TreeIdentityCandidate)] = [
            ("personID", try candidate(personID: "@I2@")),
            ("name", try candidate(name: "Blake /River/")),
            ("familySearchID", try candidate(familySearchID: "OTHER-002")),
            ("birthDate", try candidate(birthDate: "1901")),
            ("birthPlace", try candidate(birthPlace: "Albany, New York")),
            ("sex", try candidate(sex: "F"))
        ]

        func storedFields(_ value: TreeIdentityCandidate) -> [String?] {
            [
                value.personID,
                value.name,
                value.familySearchID,
                value.birthDate,
                value.birthPlace,
                value.sex
            ]
        }

        #expect(reviewed == unchanged)
        for (field, changed) in oneFieldVariants {
            let differences = zip(storedFields(reviewed), storedFields(changed))
                .filter { pair in pair.0 != pair.1 }
            #expect(differences.count == 1, "fixture must change only \(field)")
            #expect(reviewed != changed, "candidate equality omitted \(field)")
        }
    }
}
