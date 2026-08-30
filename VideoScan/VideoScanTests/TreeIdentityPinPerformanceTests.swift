// TreeIdentityPinPerformanceTests.swift
// Non-timing sensors for derived-pin validation. These count the expensive
// synchronous boundaries directly: an exact accepted memo does neither a
// derivation nor a graph SHA; a cold/mismatched memo retains the guarded
// fallback; pointer-pin fingerprints fail closed when unavailable.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

@MainActor
@Suite("TreeIdentityCenter — derived pin hot path")
struct TreeIdentityPinPerformanceTests {
    typealias F = TreeIdentityFixture

    private func makeCenter() -> (TreeIdentityCenter, KinshipDisplayCenter) {
        let kinship = KinshipDisplayCenter()
        let center = TreeIdentityCenter(kinshipCenter: kinship)
        center.defaults = nil
        center.autoAcceptsTrustedSources = false
        center.speakers = {
            HallieTurnExecutor.Speakers(
                ownerName: "Rick Breen",
                archivistName: "Hallie Mae",
                ownerFamilySearchID: "GVQV-NW3"
            )
        }
        kinship.install(graph: F.graph)
        return (center, kinship)
    }

    private func pointerPinnedProfile(fingerprint: String = "fixture-fingerprint") -> POIProfile {
        var profile = F.profile("Dad", sex: .male, born: 1931)
        profile.treeIdentity = .pointer(pointer: "@I2@", sourceFingerprint: fingerprint)
        return profile
    }

    @Test func acceptedMemoDerivedPinPerformsNoSynchronousDerivationOrFingerprintRead() async {
        let (center, _) = makeCenter()
        let candidate = F.candidate("@I1@")
        let profiles = [F.rick, pointerPinnedProfile()]
        var saved: [POIProfile] = []
        var synchronousDerivations = 0
        var fingerprintReads = 0

        center.store = { saved.append($0) }
        center.derivationPass = { _, _, _ in
            [F.rick.id: .certain(candidate, reason: .ownerSetting)]
        }
        await center.refresh(profiles: profiles)
        center.synchronousDerivation = { _, _, _, _, _ in
            synchronousDerivations += 1
            return .none
        }
        center.graphFingerprint = {
            fingerprintReads += 1
            return nil
        }

        let outcome = center.pin(
            candidate,
            on: F.rick,
            among: profiles,
            attestation: "derived: owner setting (Show in Family Tree)"
        )

        #expect(outcome.profile?.treeIdentity == .familySearchID("GVQV-NW3"))
        #expect(saved.count == 1)
        #expect(synchronousDerivations == 0, "exact memo verdict must validate without reconstructing the deriver")
        #expect(fingerprintReads == 0, "FSID candidate + accepted memo needs no synchronous tree SHA")
    }

    @Test func coldMemoUsesOneCachedFingerprintInputAndPreservesDerivationFallback() {
        let (center, _) = makeCenter()
        let candidate = F.candidate("@I1@")
        let fingerprint = FamilyKinshipOverlay.fingerprint(of: F.graph)
        let profiles = [F.rick, pointerPinnedProfile(fingerprint: fingerprint)]
        var saved: [POIProfile] = []
        var synchronousDerivations = 0
        var fingerprintReads = 0

        center.store = { saved.append($0) }
        center.graphFingerprint = {
            fingerprintReads += 1
            return fingerprint
        }
        center.synchronousDerivation = { graph, subjects, speakers, currentFingerprint, subject in
            synchronousDerivations += 1
            #expect(currentFingerprint == fingerprint)
            return TreeIdentityDeriver(
                graph: graph,
                subjects: subjects,
                ownerName: speakers.ownerName,
                ownerFamilySearchID: speakers.ownerFamilySearchID,
                currentGraphFingerprint: currentFingerprint
            ).derive(subject)
        }

        let outcome = center.pin(
            candidate,
            on: F.rick,
            among: profiles,
            attestation: "derived: owner setting (Show in Family Tree)"
        )

        #expect(outcome.profile?.treeIdentity == .familySearchID("GVQV-NW3"))
        #expect(saved.count == 1)
        #expect(synchronousDerivations == 1)
        #expect(fingerprintReads == 1, "the cached current SHA is read once and passed into the fallback deriver")
    }

    @Test func mismatchedMemoRevalidatesAndRefusesTheStaleSuggestion() async {
        let (center, _) = makeCenter()
        let candidate = F.candidate("@I1@")
        var currentSpeakers = HallieTurnExecutor.Speakers(
            ownerName: "Rick Breen",
            archivistName: "Hallie Mae",
            ownerFamilySearchID: "GVQV-NW3"
        )
        var saved: [POIProfile] = []
        var synchronousDerivations = 0
        center.speakers = { currentSpeakers }
        center.store = { saved.append($0) }

        await center.refresh(profiles: [F.rick])
        currentSpeakers = HallieTurnExecutor.Speakers(
            ownerName: "Someone Else",
            archivistName: "Hallie Mae",
            ownerFamilySearchID: nil
        )
        center.synchronousDerivation = { graph, subjects, speakers, fingerprint, subject in
            synchronousDerivations += 1
            return TreeIdentityDeriver(
                graph: graph,
                subjects: subjects,
                ownerName: speakers.ownerName,
                ownerFamilySearchID: speakers.ownerFamilySearchID,
                currentGraphFingerprint: fingerprint
            ).derive(subject)
        }

        let outcome = center.pin(
            candidate,
            on: F.rick,
            among: [F.rick],
            attestation: "derived: owner setting (Show in Family Tree)"
        )

        #expect(outcome.refusal?.contains("suggestion changed") == true)
        #expect(synchronousDerivations == 1, "a mismatched exact-input key must not trust the old memo")
        #expect(saved.isEmpty)
    }

    @Test func coldFallbackFailsClosedWhenPointerFingerprintIsUnavailable() {
        let (center, _) = makeCenter()
        let candidate = F.candidate("@I1@")
        let profiles = [F.rick, pointerPinnedProfile()]
        var saved: [POIProfile] = []
        var fingerprintReads = 0
        center.store = { saved.append($0) }
        center.graphFingerprint = {
            fingerprintReads += 1
            return nil
        }

        let outcome = center.pin(
            candidate,
            on: F.rick,
            among: profiles,
            attestation: "derived: owner setting (Show in Family Tree)"
        )

        #expect(outcome.refusal?.contains("suggestion changed") == true)
        #expect(fingerprintReads == 1)
        #expect(saved.isEmpty, "missing pointer SHA must never make an existing claimant disappear")
    }

    @Test func badgesReadFingerprintOnlyWhenSomeProfileHasAPointerPin() {
        let (center, _) = makeCenter()
        var fingerprintReads = 0
        center.graphFingerprint = {
            fingerprintReads += 1
            return nil
        }

        _ = center.treeLinkBadges(for: [F.rick, F.profile("Donna", pin: "DONN-A03")])
        #expect(fingerprintReads == 0)

        _ = center.treeLinkBadges(for: [F.rick, pointerPinnedProfile()])
        #expect(fingerprintReads == 1)
    }
}
