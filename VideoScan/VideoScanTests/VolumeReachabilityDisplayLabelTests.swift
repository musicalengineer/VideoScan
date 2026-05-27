import Testing
import Foundation
@testable import VideoScan

@Suite("VolumeReachability.displayLabel(forPath:)")
struct VolumeReachabilityDisplayLabelTests {

    // These tests use fake "/Volumes/<name>" paths that aren't expected to
    // be mounted. URLResourceValues fails on them, exercising the
    // path-string fallback inside `resolvedVolumeName(forPath:)`. That keeps
    // the tests deterministic across machines (M4 Max, MBP, CI runner)
    // without depending on a specific boot-disk name.

    @Test func wholeVolumePathShowsJustTheVolume() {
        let label = VolumeReachability.displayLabel(forPath: "/Volumes/FakeVol-DLB-1")
        #expect(label == "FakeVol-DLB-1")
    }

    @Test func subfolderOfVolumeShowsVolumeBreadcrumbFolder() {
        let label = VolumeReachability.displayLabel(forPath: "/Volumes/FakeVol-DLB-2/Movies")
        #expect(label == "FakeVol-DLB-2 > Movies")
    }

    @Test func deepSubfolderShowsOnlyLastComponent() {
        let label = VolumeReachability.displayLabel(forPath: "/Volumes/FakeVol-DLB-3/Movies/2024/family")
        #expect(label == "FakeVol-DLB-3 > family")
    }

    @Test func trailingSlashOnVolumeRootCollapsesToWholeVolume() {
        let label = VolumeReachability.displayLabel(forPath: "/Volumes/FakeVol-DLB-4/")
        #expect(label == "FakeVol-DLB-4")
    }

    @Test func emptyPathReturnsEmpty() {
        let label = VolumeReachability.displayLabel(forPath: "")
        #expect(label == "")
    }

    @Test func threeFoldersOfSameNameOnDifferentVolumesRemainDistinct() {
        // Regression for the "3 rickb entries with no volume" symptom.
        // Three scan targets named "rickb" on three different volumes should
        // produce three distinct labels — the old volumeName(forPath:)
        // collapsed all /Users/<X>/... paths to "<X>", killing this signal.
        let a = VolumeReachability.displayLabel(forPath: "/Volumes/FakeVol-DLB-A/rickb")
        let b = VolumeReachability.displayLabel(forPath: "/Volumes/FakeVol-DLB-B/rickb")
        let c = VolumeReachability.displayLabel(forPath: "/Volumes/FakeVol-DLB-C/rickb")
        #expect(a == "FakeVol-DLB-A > rickb")
        #expect(b == "FakeVol-DLB-B > rickb")
        #expect(c == "FakeVol-DLB-C > rickb")
        #expect(Set([a, b, c]).count == 3, "Three distinct labels — no collision")
    }

    @Test func folderNameMatchingVolumeNameAvoidsDuplication() {
        // /Volumes/M4drive/M4drive should NOT render as "M4drive > M4drive".
        // Mirrors the same guard that VideoRecord.displayVolumeLabel applies.
        let label = VolumeReachability.displayLabel(forPath: "/Volumes/FakeVol-DLB-Same/FakeVol-DLB-Same")
        #expect(label == "FakeVol-DLB-Same")
    }
}
