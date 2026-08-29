// TreeLinkBadgeTests.swift
// The People-tab tree-link badge (Rick, 2026-08-29: "a little GEDCOM ID
// flag in the People tab"). Five dimensions:
//   1. Logic     — `TreeLinkBadge.state(for:profile:)` matrix over every
//                  ShowInTreeState + the persisted pin fields (attestation
//                  wording); GEDCOM-ID / missing-GEDCOM membership per state
//   2. Scale     — n/a (one dictionary lookup per card; the memo test below
//                  pins "one build per revision")
//   3. Media     — n/a
//   4. Isolation — isolated TreeIdentityCenter + KinshipDisplayCenter, the
//                  synthetic TreeIdentityFixture tree, capturing store, no
//                  UserDefaults
//   5. Sensors   — memo invalidates on pinsRevision / tree generation and
//                  NOT on a re-read with the same inputs

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

private func treeLinkFixtureCandidate(_ id: String) -> TreeIdentityCandidate {
    guard let person = TreeIdentityFixture.graph.people[id] else {
        preconditionFailure("TreeIdentityFixture is missing \(id)")
    }
    return TreeIdentityCandidate(person)
}

@Suite("TreeLinkBadge — state mapping")
struct TreeLinkBadgeStateTests {
    typealias F = TreeIdentityFixture
    let jr = treeLinkFixtureCandidate("@I1@")
    let sr = treeLinkFixtureCandidate("@I2@")

    @Test func noTreeAndNoneHideTheBadge() {
        #expect(TreeLinkBadge.state(for: .noTree, profile: F.rick) == nil)
        #expect(TreeLinkBadge.state(for: .none, profile: F.rick) == nil)
    }

    @Test func pinnedShowsTheFullFamilySearchIDAndPickedAttestation() {
        var rick = F.profile("Rick", pin: "GVQV-NW3")
        rick.treeIdentityAttestation = "picked: Rick Breen, 2026-08-29"
        let b = TreeLinkBadge.state(for: .pinned(jr), profile: rick)
        #expect(b?.kind == .pinned)
        #expect(b?.label == "GVQV-NW3", "the FSID is the label, never truncated")
        #expect(b?.tooltip == "Richard Harding Breen Jr · GVQV-NW3 · confirmed 2026-08-29")
    }

    @Test func pinnedDerivedAttestationDropsTheProvenanceSuffix() {
        var rick = F.profile("Rick", pin: "GVQV-NW3")
        rick.treeIdentityAttestation = "derived: owner setting (Show in Family Tree)"
        let b = TreeLinkBadge.state(for: .pinned(jr), profile: rick)
        #expect(b?.tooltip == "Richard Harding Breen Jr · GVQV-NW3 · derived: owner setting")

        rick.treeIdentityAttestation = "derived: tree root"
        #expect(TreeLinkBadge.state(for: .pinned(jr), profile: rick)?.tooltip.hasSuffix("· derived: tree root") == true)
    }

    @Test func pinnedWithoutAttestationSaysSo() {
        let rick = F.profile("Rick", pin: "GVQV-NW3")
        let b = TreeLinkBadge.state(for: .pinned(jr), profile: rick)
        #expect(b?.tooltip.hasSuffix("pinned before attestations were recorded") == true)
    }

    @Test func pinnedWithBirthYearLabelsTheYear() {
        let b = TreeLinkBadge.state(for: .pinned(sr), profile: F.profile("Dad", pin: "G2S4-JF4"))
        #expect(b?.label == "G2S4-JF4")
        #expect(b?.tooltip.hasPrefix("Richard Harding Breen Sr (b. 1931) · G2S4-JF4") == true)
    }

    @Test func derivedIsAmberConfirm() {
        let b = TreeLinkBadge.state(for: .derived(jr, reason: .nameAndBirth), profile: F.rick)
        #expect(b?.kind == .derived)
        #expect(b?.label == "confirm")
        #expect(b?.tooltip == "Looks like Richard Harding Breen Jr · GVQV-NW3 (name + birth year) — click to confirm")
    }

    @Test func ambiguousIsQuestionMarkWithCount() {
        let b = TreeLinkBadge.state(for: .ambiguous([jr, sr]), profile: F.profile("Richard"))
        #expect(b?.kind == .ambiguous)
        #expect(b?.label == "?")
        #expect(b?.tooltip == "2 tree records could be Richard — which one? Click to choose")
    }

    @Test func pinProblemCarriesTheReason() {
        let b = TreeLinkBadge.state(for: .pinProblem("Rick's pin is stale"), profile: F.rick)
        #expect(b?.kind == .pinProblem)
        #expect(b?.label == "fix pin")
        #expect(b?.tooltip == "Rick's pin is stale — click to fix")
    }

    @Test func notInTreeIsThePlainOutline() {
        let b = TreeLinkBadge.state(for: .notInTree, profile: F.profile("Tim", notInTree: true))
        #expect(b?.kind == .notInTree)
        #expect(b?.label == "not in tree")
        #expect(b?.isOutline == true)
        #expect(b?.tooltip.hasPrefix("Tim is not in the family tree") == true)
    }

    @Test func describeAttestationEdgeCases() {
        #expect(TreeLinkBadge.describeAttestation(nil) == "pinned before attestations were recorded")
        #expect(TreeLinkBadge.describeAttestation("") == "pinned before attestations were recorded")
        #expect(TreeLinkBadge.describeAttestation("picked: owner") == "confirmed", "no date → bare confirmed")
        #expect(TreeLinkBadge.describeAttestation("something else") == "something else")
    }

    @Test func everyKindHasAnIconAndTint() {
        for kind in TreeLinkBadge.Kind.allCases {
            let b = TreeLinkBadge(kind: kind, label: "x", tooltip: "y")
            #expect(!b.systemImage.isEmpty)
            #expect(b.isOutline == (kind == .notInTree))
        }
    }
}

@Suite("TreeLinkBadge — GEDCOM ID membership")
struct TreeLinkBadgeGEDCOMIDTests {
    private func badge(_ kind: TreeLinkBadge.Kind) -> TreeLinkBadge {
        TreeLinkBadge(kind: kind, label: "", tooltip: "")
    }

    @Test func onlyPinnedHasGEDCOMID() {
        #expect(TreeLinkBadge.hasGEDCOMID(badge(.pinned)))
        #expect(!TreeLinkBadge.hasGEDCOMID(nil))
        #expect(!TreeLinkBadge.hasGEDCOMID(badge(.derived)))
        #expect(!TreeLinkBadge.hasGEDCOMID(badge(.ambiguous)))
        #expect(!TreeLinkBadge.hasGEDCOMID(badge(.pinProblem)))
        #expect(!TreeLinkBadge.hasGEDCOMID(badge(.notInTree)))
    }

    /// Regression sensor for the People-tab checkbox: "Show Missing GEDCOM"
    /// is exactly the complement of hasGEDCOMID, including a nil badge.
    @Test func showMissingGEDCOMIncludesEveryNonPinnedState() {
        let isMissingGEDCOM: (TreeLinkBadge?) -> Bool = { !TreeLinkBadge.hasGEDCOMID($0) }
        let states: [TreeLinkBadge?] = [
            nil,
            badge(.derived),
            badge(.ambiguous),
            badge(.pinProblem),
            badge(.notInTree)
        ]
        #expect(states.allSatisfy(isMissingGEDCOM))
        #expect(!isMissingGEDCOM(badge(.pinned)))
    }
}

@Suite("TreeIdentityCenter — badge memo")
@MainActor
struct TreeLinkBadgeMemoTests {
    typealias F = TreeIdentityFixture

    private func makeCenter() -> (TreeIdentityCenter, KinshipDisplayCenter) {
        let kinship = KinshipDisplayCenter()
        let center = TreeIdentityCenter(kinshipCenter: kinship)
        center.defaults = nil
        center.autoAcceptsTrustedSources = false
        center.speakers = { HallieTurnExecutor.Speakers(ownerName: "Rick Breen", archivistName: "Hallie Mae",
                                                        ownerFamilySearchID: "GVQV-NW3") }
        return (center, kinship)
    }

    @Test func noTreeMeansNoBadgesAndOneBuild() {
        let (center, _) = makeCenter()
        let profiles = [F.rick, F.donna]
        #expect(center.treeLinkBadges(for: profiles).isEmpty)
        #expect(center.treeLinkBadges(for: profiles).isEmpty)
        #expect(center.badgeComputeCount == 1, "same inputs → memo hit")
    }

    @Test func sameInputsHitTheMemoAndPinsRevisionInvalidatesIt() async throws {
        let (center, kinship) = makeCenter()
        center.store = { _ in }
        kinship.install(graph: F.graph)
        let john = F.profile("John Breen", sex: .male, born: 1940)
        let unpinnedRick = F.profile("Rick", aliases: ["Dad"], sex: .male, born: 1962)
        let profiles = [unpinnedRick, F.donna, F.tim, john]

        // Before any derivation pass: pinned/notInTree still resolve, the
        // unpinned rest have no badge yet.
        let before = center.treeLinkBadges(for: profiles)
        #expect(before.isEmpty)
        #expect(center.badgeComputeCount == 1)

        await center.refresh(profiles: profiles)
        let after = center.treeLinkBadges(for: profiles)
        #expect(center.badgeComputeCount == 2, "derivation pass invalidates the memo")
        #expect(after["rick"]?.kind == .derived)
        #expect(after["rick"]?.tooltip.contains("GVQV-NW3") == true)
        #expect(after["donna"]?.kind == .derived)
        #expect(after["john breen"]?.kind == .derived)
        #expect(after["tim"] == nil, "Tim derives to .none → no badge")

        _ = center.treeLinkBadges(for: profiles)
        _ = center.treeLinkBadges(for: profiles)
        #expect(center.badgeComputeCount == 2, "re-reads with the same inputs are memo hits")

        // A pin bumps pinsRevision → the next read rebuilds even with the
        // SAME profile array handed in (production reloads it anyway).
        let jrPerson = try #require(
            F.graph.people["@I1@"]
        )
        let jr = TreeIdentityCandidate(jrPerson)
        let outcome = center.pin(jr, on: unpinnedRick, among: profiles, attestation: "picked: Rick Breen, 2026-08-29")
        let savedProfile = try #require(outcome.profile)
        _ = center.treeLinkBadges(for: profiles)
        #expect(center.badgeComputeCount == 3, "pinsRevision invalidates the memo")

        // With the saved profile in the array the badge is now the pin.
        var reloaded = profiles
        reloaded[0] = savedProfile
        let pinned = center.treeLinkBadges(for: reloaded)
        #expect(pinned["rick"]?.kind == .pinned)
        #expect(pinned["rick"]?.label == "GVQV-NW3")
        #expect(pinned["rick"]?.tooltip.hasSuffix("confirmed 2026-08-29") == true)
    }

    @Test func treeGenerationInvalidatesTheMemo() {
        let (center, kinship) = makeCenter()
        let pinnedRick = F.profile("Rick", pin: "GVQV-NW3")
        kinship.install(graph: F.graph)
        #expect(center.treeLinkBadges(for: [pinnedRick])["rick"]?.kind == .pinned)
        let builds = center.badgeComputeCount
        kinship.install(graph: F.graph)   // new generation, same content
        _ = center.treeLinkBadges(for: [pinnedRick])
        #expect(center.badgeComputeCount == builds + 1)
    }

    @Test func persistedStatesNeedNoDerivationPass() {
        let (center, kinship) = makeCenter()
        kinship.install(graph: F.graph)
        let pinned = F.profile("Rick", pin: "GVQV-NW3")
        let collided = F.profile("Dicky", pin: "GVQV-NW3")
        let stale = F.profile("Ghost", pin: "NOPE-000")
        let out = F.profile("Tim", notInTree: true)
        let map = center.treeLinkBadges(for: [pinned, collided, stale, out])
        #expect(map["rick"]?.kind == .pinProblem, "two profiles on one record collide")
        #expect(map["dicky"]?.kind == .pinProblem)
        #expect(map["ghost"]?.kind == .pinProblem)
        #expect(map["ghost"]?.label == "fix pin")
        #expect(map["tim"]?.kind == .notInTree)
    }
}
