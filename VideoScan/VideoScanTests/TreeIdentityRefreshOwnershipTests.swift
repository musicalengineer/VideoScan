// TreeIdentityRefreshOwnershipTests.swift
// Adversarial ownership sensor for equal-key refresh continuations.

import Foundation
import Testing
@testable import VideoScan

private actor TreeIdentityMultiPassGate {
    private var nextPass = 0
    private var started: Set<Int> = []
    private var released: Set<Int> = []
    private var startWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var releaseWaiters: [Int: CheckedContinuation<Void, Never>] = [:]

    func holdNextPass() async {
        nextPass += 1
        let pass = nextPass
        started.insert(pass)
        let waiters = startWaiters.removeValue(forKey: pass) ?? []
        waiters.forEach { $0.resume() }
        guard !released.contains(pass) else { return }
        await withCheckedContinuation { releaseWaiters[pass] = $0 }
    }

    func waitUntilStarted(_ pass: Int) async {
        guard !started.contains(pass) else { return }
        await withCheckedContinuation { startWaiters[pass, default: []].append($0) }
    }

    func release(_ pass: Int) {
        released.insert(pass)
        releaseWaiters.removeValue(forKey: pass)?.resume()
    }
}

@Suite("TreeIdentityCenter — refresh ownership")
@MainActor
struct TreeIdentityRefreshOwnershipTests {
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

    /// SENSOR: an old canceled K and a new K have equal keys but different
    /// ownership epochs. Releasing old K must not clear new K's slot.
    @Test func oldKCleanupCannotClearNewKOwnershipAcrossL() async {
        let (center, kinship) = makeCenter()
        let gate = TreeIdentityMultiPassGate()
        var saved: [POIProfile] = []
        center.store = { saved.append($0) }
        center.derivationPass = { graph, subjects, speakers in
            if subjects.first?.stableID == F.rick.id {
                await gate.holdNextPass()
            }
            return TreeIdentityDeriver(
                graph: graph,
                subjects: subjects,
                ownerName: speakers.ownerName,
                ownerFamilySearchID: speakers.ownerFamilySearchID
            ).deriveAll()
        }
        kinship.install(graph: F.graph)
        let profilesK = [F.rick]
        let profilesL = [F.tim]

        let oldK = Task { await center.refresh(profiles: profilesK) }
        await gate.waitUntilStarted(1)
        oldK.cancel()

        await center.refresh(profiles: profilesL)
        #expect(center.derivationRunCount == 1)
        #expect(saved.isEmpty)

        let newK = Task { await center.refresh(profiles: profilesK) }
        await gate.waitUntilStarted(2)
        await gate.release(1)
        await oldK.value

        #expect(center.derivationRunCount == 1)
        #expect(center.pinsRevision == 0)
        #expect(saved.isEmpty, "old K must not publish or auto-pin")

        await gate.release(2)
        await newK.value
        #expect(center.derivationRunCount == 2, "new K must retain ownership and publish")
        #expect(center.pinsRevision == 1)
        #expect(saved.map(\.name) == ["Rick"])
    }
}
