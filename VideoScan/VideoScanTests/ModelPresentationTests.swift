// ModelPresentationTests.swift
//
// SAFETY NET for the upcoming presentation-layer relocation: all SwiftUI
// presentation members (`icon`, `label`, `shortLabel`, `detail` — and the
// `color`/`textColor` Color properties, which we do NOT pin here) are about
// to be moved OFF the domain enums in Models/ and into separate
// `+Presentation` extensions. These tests freeze the EXACT current String
// outputs of every String-typed presentation property so that move can be
// proven behavior-preserving: re-run after the relocation, they must stay
// green. (Companion to ModelSchemaTests.swift, which pins the persisted
// Codable layer; this file pins the UI-facing string vocabulary instead.)
//
// Why only String properties: SwiftUI `Color` is not usefully Equatable
// (no stable, documented value equality we can assert across the move), so
// the Color members (PairConfidence.color/.textColor, ArchiveStage.color,
// VolumePhase.color, etc.) are deliberately skipped. Pinning the SF Symbol
// names and labels is sufficient to prove the relocation didn't alter the
// mapping — if a switch arm gets shuffled during the move, the icon string
// for that case changes and the assertion fires.
//
// For every CaseIterable enum we also assert `allCases.count`, so a future
// case addition can't slip in without a matching presentation assertion
// (the count check fails, forcing the author to extend this file).
//
// Style: Swift Testing (`@Test` / `#expect`), matching ModelSchemaTests.swift
// and the dominant suite style. For Rick, who reads C++ test code:
// `#expect(x == y)` ≈ GoogleTest `EXPECT_EQ(x, y)` — a soft assertion that
// records a failure but lets the test body continue, so one sweep reports
// EVERY drifted case, not just the first.
//
// Coverage notes (what was found absent, so the gaps are intentional, not
// oversights):
//   - MediaClassification.swift: StreamType exposes NO String presentation
//     member (only `needsCorrelation: Bool`). PairConfidence,
//     DuplicateConfidence, and DuplicateDisposition expose only `color` /
//     `textColor` (Color — skipped). So NONE of the MediaClassification
//     enums contribute String presentation assertions; documented here so
//     their absence is understood, not assumed missing.
//   - These four enums are also not CaseIterable, so no count check applies.

import Testing
import SwiftUI
@testable import VideoScan

struct ModelPresentationTests {

    // MARK: - ArchiveModels.swift

    // MediaDisposition.icon (CaseIterable).
    @Test
    func mediaDispositionIcons() {
        #expect(MediaDisposition.unreviewed.icon    == "circle")
        #expect(MediaDisposition.important.icon     == "star.fill")
        #expect(MediaDisposition.recoverable.icon   == "wrench.and.screwdriver.fill")
        #expect(MediaDisposition.suspectedJunk.icon == "exclamationmark.triangle")
        #expect(MediaDisposition.confirmedJunk.icon == "xmark.circle.fill")
        // No case left unasserted.
        #expect(MediaDisposition.allCases.count == 5)
    }

    // ArchiveStage.icon (CaseIterable).
    @Test
    func archiveStageIcons() {
        #expect(ArchiveStage.none.icon            == "circle")
        #expect(ArchiveStage.healthy.icon         == "heart.fill")
        #expect(ArchiveStage.masterAssigned.icon  == "crown.fill")
        #expect(ArchiveStage.backedUp.icon        == "doc.on.doc.fill")
        #expect(ArchiveStage.readyForArchive.icon == "checkmark.seal.fill")
        #expect(ArchiveStage.archived.icon        == "archivebox.fill")
        #expect(ArchiveStage.manuallyDeleted.icon == "trash.slash.fill")
        #expect(ArchiveStage.salvageFailed.icon   == "exclamationmark.octagon.fill")
        #expect(ArchiveStage.allCases.count == 8)
    }

    // ArchiveHealth.icon + .label + .detail (all String).
    // NOT CaseIterable — no count check possible; assert all four cases
    // explicitly so a new case + drifted mapping is still caught by the
    // exhaustive switch in production failing to compile (which would block
    // this build) plus these per-case strings.
    @Test
    func archiveHealthIcons() {
        #expect(ArchiveHealth.safe.icon           == "checkmark.shield.fill")
        #expect(ArchiveHealth.inProgress.icon     == "clock.badge.checkmark")
        #expect(ArchiveHealth.needsAttention.icon == "exclamationmark.shield.fill")
        #expect(ArchiveHealth.notApplicable.icon  == "")
    }

    @Test
    func archiveHealthLabels() {
        #expect(ArchiveHealth.safe.label           == "Safe")
        #expect(ArchiveHealth.inProgress.label     == "In Progress")
        #expect(ArchiveHealth.needsAttention.label == "Needs Attention")
        #expect(ArchiveHealth.notApplicable.label  == "")
    }

    @Test
    func archiveHealthDetails() {
        #expect(ArchiveHealth.safe.detail           == "Reviewed, has audio/video, backed up")
        #expect(ArchiveHealth.inProgress.detail     == "Partially reviewed or archived")
        #expect(ArchiveHealth.needsAttention.detail == "Not yet reviewed or backed up")
        #expect(ArchiveHealth.notApplicable.detail  == "")
    }

    // BackupEntry.BackupKind.icon (CaseIterable). Lives in ArchiveModels.swift
    // alongside the others and is a String presentation member, so pin it too.
    @Test
    func backupKindIcons() {
        #expect(BackupEntry.BackupKind.local.icon   == "externaldrive.fill")
        #expect(BackupEntry.BackupKind.cloud.icon   == "icloud.fill")
        #expect(BackupEntry.BackupKind.offsite.icon == "building.2.fill")
        #expect(BackupEntry.BackupKind.allCases.count == 3)
    }

    // MARK: - VolumeStatusEnums.swift

    // VolumePhase.icon (CaseIterable).
    @Test
    func volumePhaseIcons() {
        #expect(VolumePhase.noCatalog.icon    == "circle")
        #expect(VolumePhase.cataloged.icon    == "list.bullet")
        #expect(VolumePhase.reviewed.icon     == "checkmark.circle")
        #expect(VolumePhase.consolidated.icon == "arrow.triangle.merge")
        #expect(VolumePhase.archived.icon     == "archivebox")
        #expect(VolumePhase.allCases.count == 5)
    }

    // VolumeRole.icon (CaseIterable).
    @Test
    func volumeRoleIcons() {
        #expect(VolumeRole.unassigned.icon == "questionmark.circle")
        #expect(VolumeRole.system.icon     == "internaldrive.fill")
        #expect(VolumeRole.workspace.icon  == "film.stack")
        #expect(VolumeRole.backup.icon     == "doc.on.doc")
        #expect(VolumeRole.cloud.icon      == "icloud.fill")
        #expect(VolumeRole.archive.icon    == "archivebox.fill")
        #expect(VolumeRole.allCases.count == 6)
    }

    // VolumeRole.shortLabel (CaseIterable).
    @Test
    func volumeRoleShortLabels() {
        #expect(VolumeRole.unassigned.shortLabel == "—")
        #expect(VolumeRole.system.shortLabel     == "SYS")
        #expect(VolumeRole.workspace.shortLabel  == "WKSP")
        #expect(VolumeRole.backup.shortLabel     == "BKUP")
        #expect(VolumeRole.cloud.shortLabel      == "CLD")
        #expect(VolumeRole.archive.shortLabel    == "ARCH")
        #expect(VolumeRole.allCases.count == 6)
    }

    // VolumeTrust.icon (CaseIterable).
    @Test
    func volumeTrustIcons() {
        #expect(VolumeTrust.unknown.icon    == "questionmark.circle")
        #expect(VolumeTrust.reliable.icon   == "checkmark.shield.fill")
        #expect(VolumeTrust.aging.icon      == "exclamationmark.triangle")
        #expect(VolumeTrust.unreliable.icon == "xmark.shield.fill")
        #expect(VolumeTrust.allCases.count == 4)
    }

    // VolumeMediaTech.icon (CaseIterable). The four RAID cases share one
    // SF Symbol via a combined switch arm — pin each so a future split is
    // caught.
    @Test
    func volumeMediaTechIcons() {
        #expect(VolumeMediaTech.unknown.icon == "questionmark.circle")
        #expect(VolumeMediaTech.ssd.icon     == "internaldrive")
        #expect(VolumeMediaTech.hdd.icon     == "externaldrive")
        #expect(VolumeMediaTech.raid0.icon   == "externaldrive.connected.to.line.below")
        #expect(VolumeMediaTech.raid1.icon   == "externaldrive.connected.to.line.below")
        #expect(VolumeMediaTech.raid5.icon   == "externaldrive.connected.to.line.below")
        #expect(VolumeMediaTech.raid10.icon  == "externaldrive.connected.to.line.below")
        #expect(VolumeMediaTech.cloud.icon   == "icloud")
        #expect(VolumeMediaTech.network.icon == "network")
        #expect(VolumeMediaTech.allCases.count == 9)
    }

    // DestinationPolicy.icon + .label (both String). NOT CaseIterable — no
    // count check possible; assert all four cases explicitly.
    @Test
    func destinationPolicyIcons() {
        #expect(DestinationPolicy.preferred.icon   == "checkmark.seal.fill")
        #expect(DestinationPolicy.acceptable.icon  == "checkmark.circle")
        #expect(DestinationPolicy.discouraged.icon == "exclamationmark.triangle.fill")
        #expect(DestinationPolicy.forbidden.icon   == "xmark.octagon.fill")
    }

    @Test
    func destinationPolicyLabels() {
        #expect(DestinationPolicy.preferred.label   == "Preferred")
        #expect(DestinationPolicy.acceptable.label  == "Acceptable")
        #expect(DestinationPolicy.discouraged.label == "Discouraged")
        #expect(DestinationPolicy.forbidden.label   == "Forbidden")
    }
}
