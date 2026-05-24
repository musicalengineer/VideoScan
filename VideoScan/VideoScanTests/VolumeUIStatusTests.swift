// VolumeUIStatusTests.swift
// Pins the state-derivation logic for `VolumeUIStatus.compute(...)`.
//
// VolumeUIStatus is the single source of truth for what the catalog row's
// status pill should say. Bugs here would show up as the pill saying
// "Connected" while a Verify pass is running — exactly the kind of
// "the UI doesn't match reality" that motivated the original flicker
// refactor. Keep this suite cheap and exhaustive.

import Testing
import Foundation
@testable import VideoScan

@Suite("VolumeUIStatus Derivation")
struct VolumeUIStatusTests {

    // MARK: - Mount precedence

    @Test func unmountedAlwaysOfflineEvenIfModelClaimsActivity() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: false,
            targetStatus: .scanning,
            isCombining: true,
            isBackfilling: true,
            isVerifyingThisVolume: true,
            scanProgress: 0.5
        )
        #expect(VolumeUIStatus.compute(inputs) == .offline)
    }

    @Test func mountedIdleIsConnected() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .idle,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: nil
        )
        #expect(VolumeUIStatus.compute(inputs) == .connected)
    }

    @Test func completedScanIsConnected() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .complete,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: nil
        )
        #expect(VolumeUIStatus.compute(inputs) == .connected)
    }

    // MARK: - Activity precedence: combine > backfill > verify > scan

    @Test func combiningBeatsScanning() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .scanning,
            isCombining: true,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: 0.3
        )
        #expect(VolumeUIStatus.compute(inputs) == .combining)
    }

    @Test func backfillingBeatsVerifying() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .scanning,
            isCombining: false,
            isBackfilling: true,
            isVerifyingThisVolume: true,
            scanProgress: nil
        )
        #expect(VolumeUIStatus.compute(inputs) == .backfilling)
    }

    @Test func verifyingBeatsScanningStatus() {
        // verify reuses CatalogTargetStatus.scanning; the per-target flag is
        // what distinguishes them.
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .scanning,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: true,
            scanProgress: 0.5
        )
        #expect(VolumeUIStatus.compute(inputs) == .verifying)
    }

    // MARK: - Scanning states

    @Test func scanningPropagatesProgress() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .scanning,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: 0.42
        )
        if case let .scanning(progress) = VolumeUIStatus.compute(inputs) {
            #expect(progress == 0.42)
        } else {
            Issue.record("Expected .scanning, got something else")
        }
    }

    @Test func discoveringPhaseIsScanningWithoutProgress() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .discovering,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: nil
        )
        if case let .scanning(progress) = VolumeUIStatus.compute(inputs) {
            #expect(progress == nil)
        } else {
            Issue.record("Expected .scanning, got something else")
        }
    }

    @Test func pausedScanStillReadsAsScanning() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .paused,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: 0.1
        )
        if case .scanning = VolumeUIStatus.compute(inputs) {
            // pass
        } else {
            Issue.record("Paused should still read as .scanning in the UI")
        }
    }

    @Test func waitingForVolumeReadsAsScanning() {
        // waitingForVolume is the "queued, will start when mount returns"
        // state — surfacing it as scanning keeps the user-visible activity
        // pill consistent across that transition.
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .waitingForVolume,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: nil
        )
        if case .scanning = VolumeUIStatus.compute(inputs) {
            // pass
        } else {
            Issue.record("Expected .scanning, got something else")
        }
    }

    // MARK: - Terminal target states

    @Test func stoppedIsConnected() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .stopped,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: nil
        )
        #expect(VolumeUIStatus.compute(inputs) == .connected)
    }

    @Test func errorIsConnected() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .error,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: nil
        )
        #expect(VolumeUIStatus.compute(inputs) == .connected)
    }

    @Test func resumableIsConnected() {
        let inputs = VolumeUIStatusInputs(
            mountReachable: true,
            targetStatus: .resumable,
            isCombining: false,
            isBackfilling: false,
            isVerifyingThisVolume: false,
            scanProgress: nil
        )
        #expect(VolumeUIStatus.compute(inputs) == .connected)
    }

    // MARK: - Derived properties

    @Test func isActiveTrueForRemediationStates() {
        #expect(VolumeUIStatus.scanning(progress: nil).isActive)
        #expect(VolumeUIStatus.scanning(progress: 0.5).isActive)
        #expect(VolumeUIStatus.verifying.isActive)
        #expect(VolumeUIStatus.backfilling.isActive)
        #expect(VolumeUIStatus.combining.isActive)
    }

    @Test func isActiveFalseForIdleStates() {
        #expect(VolumeUIStatus.offline.isActive == false)
        #expect(VolumeUIStatus.connected.isActive == false)
    }

    @Test func tooltipsPresentForActiveStates() {
        #expect(VolumeUIStatus.scanning(progress: nil).activityTooltip != nil)
        #expect(VolumeUIStatus.verifying.activityTooltip != nil)
        #expect(VolumeUIStatus.backfilling.activityTooltip != nil)
        #expect(VolumeUIStatus.combining.activityTooltip != nil)
    }

    @Test func tooltipsAbsentForIdleStates() {
        #expect(VolumeUIStatus.offline.activityTooltip == nil)
        #expect(VolumeUIStatus.connected.activityTooltip == nil)
    }

    @Test func labelsAreNonEmpty() {
        let all: [VolumeUIStatus] = [
            .offline, .connected,
            .scanning(progress: nil), .scanning(progress: 0.5),
            .verifying, .backfilling, .combining
        ]
        for status in all {
            #expect(status.label.isEmpty == false, "label missing for \(status)")
        }
    }

    // MARK: - Transitions exercised end-to-end

    @Test func transitionScanStartsThenFinishes() {
        // Start: mounted, idle, no flags.
        let before = VolumeUIStatus.compute(VolumeUIStatusInputs(
            mountReachable: true, targetStatus: .idle,
            isCombining: false, isBackfilling: false,
            isVerifyingThisVolume: false, scanProgress: nil
        ))
        #expect(before == .connected)

        // Scan in progress.
        let during = VolumeUIStatus.compute(VolumeUIStatusInputs(
            mountReachable: true, targetStatus: .scanning,
            isCombining: false, isBackfilling: false,
            isVerifyingThisVolume: false, scanProgress: 0.5
        ))
        if case .scanning = during {} else {
            Issue.record("Expected .scanning during a scan, got \(during)")
        }

        // Scan complete.
        let after = VolumeUIStatus.compute(VolumeUIStatusInputs(
            mountReachable: true, targetStatus: .complete,
            isCombining: false, isBackfilling: false,
            isVerifyingThisVolume: false, scanProgress: 1.0
        ))
        #expect(after == .connected)
    }

    @Test func transitionVerifyStartsThenFinishes() {
        // Verify in progress (target.status is .scanning, flag is set).
        let during = VolumeUIStatus.compute(VolumeUIStatusInputs(
            mountReachable: true, targetStatus: .scanning,
            isCombining: false, isBackfilling: false,
            isVerifyingThisVolume: true, scanProgress: 0.5
        ))
        #expect(during == .verifying)

        // Verify completes (flag cleared, status flipped to .complete).
        let after = VolumeUIStatus.compute(VolumeUIStatusInputs(
            mountReachable: true, targetStatus: .complete,
            isCombining: false, isBackfilling: false,
            isVerifyingThisVolume: false, scanProgress: 1.0
        ))
        #expect(after == .connected)
    }

    @Test func transitionMountLostMidScanFlipsToOffline() {
        // Mid-scan flip: status is still .scanning but mount disappeared.
        let result = VolumeUIStatus.compute(VolumeUIStatusInputs(
            mountReachable: false, targetStatus: .scanning,
            isCombining: false, isBackfilling: false,
            isVerifyingThisVolume: false, scanProgress: 0.5
        ))
        #expect(result == .offline)
    }
}
