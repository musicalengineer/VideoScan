import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

/// Catalog volume list Show menu (Rick 2026-08-28): default = connected +
/// every role, retired hidden; chip words; persistence round-trip.
struct VolumeShowFilterTests {

    // MARK: Predicate

    @Test func defaultShowsOnlineAvailableMedia() {
        let f = VolumeShowFilter.default
        #expect(f.admits(role: .archive,   isReachable: true,  isRetired: false))
        #expect(f.admits(role: .workspace, isReachable: true,  isRetired: false))
        #expect(f.admits(role: .backup,    isReachable: true,  isRetired: false))
        #expect(f.admits(role: .unassigned, isReachable: true, isRetired: false))
        // Disconnected and retired are hidden by default.
        #expect(!f.admits(role: .workspace, isReachable: false, isRetired: false))
        #expect(!f.admits(role: .backup,    isReachable: true,  isRetired: true))
    }

    @Test func allVolumesAdmitsEverything() {
        let f = VolumeShowFilter.all
        #expect(f.isAll)
        for role in VolumeRole.allCases {
            #expect(f.admits(role: role, isReachable: false, isRetired: true))
        }
    }

    @Test func roleGroupToggleNarrowsAndSnapsBackWhenEmpty() {
        var f = VolumeShowFilter.default
        f.toggle(.backup)
        #expect(!f.includes(.backup))
        #expect(!f.admits(role: .backup, isReachable: true, isRetired: false))
        #expect(f.admits(role: .workspace, isReachable: true, isRetired: false))
        // "Other" covers unassigned + system together.
        f.toggle(.other)
        #expect(!f.admits(role: .system, isReachable: true, isRetired: false))
        #expect(!f.admits(role: .unassigned, isReachable: true, isRetired: false))
        // Untick the rest → nothing would be listed → snaps to every role.
        f.toggle(.archive); f.toggle(.workspace); f.toggle(.cloud)
        #expect(f.roles == Set(VolumeRole.allCases))
    }

    // MARK: Chip words

    @Test func summaryWordsForDefaultAllAndNarrowed() {
        #expect(VolumeShowFilter.default.summary(shown: 9, total: 9)
                == "Connected · Archive · Workspace · Backup · Cloud · Other")
        #expect(VolumeShowFilter.all.summary(shown: 9, total: 9) == "All volumes")

        var f = VolumeShowFilter.default
        f.toggle(.backup); f.toggle(.cloud); f.toggle(.other)
        f.includeRetired = true
        #expect(f.summary(shown: 9, total: 9) == "Connected · Archive · Workspace · Retired")
    }

    @Test func summaryAppendsCountOnlyWhenSomethingIsHidden() {
        let f = VolumeShowFilter.default
        #expect(f.summary(shown: 5, total: 9).hasSuffix(" — 5 of 9"))
        #expect(!f.summary(shown: 9, total: 9).contains(" of "))
        #expect(!f.summary(shown: 0, total: 0).contains(" of "))
    }

    // MARK: Persistence

    @Test func encodeDecodeRoundTrip() {
        var f = VolumeShowFilter.default
        f.connectedOnly = false
        f.toggle(.cloud)
        f.includeRetired = true
        let raw = VolumeShowFilter.encode(f)
        #expect(!raw.isEmpty)
        #expect(VolumeShowFilter.decode(raw) == f)
    }

    @Test func decodeFallsBackToDefaultOnGarbageOrEmpty() {
        #expect(VolumeShowFilter.decode("") == .default)
        #expect(VolumeShowFilter.decode("not json") == .default)
        #expect(VolumeShowFilter.decode(#"{"connectedOnly":true,"roles":["Nope"],"includeRetired":false}"#) == .default)
        #expect(VolumeShowFilter.decode(#"{"connectedOnly":true,"roles":[],"includeRetired":false}"#) == .default)
    }
}
