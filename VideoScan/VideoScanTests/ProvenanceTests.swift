import Testing
import Foundation
@testable import VideoScan

// MARK: - ProvenanceTests
//
// Covers the Provenance & Audit Trail builders (docs/relocate_volume_plan.md
// §2). Three views: Volume Provenance, File Journey, Migration Overview.
//
// Pure builders — no filesystem, no MainActor needed for the actual
// asserts (we use a small @MainActor model fixture only where the
// resolver-from-scan-targets path is being exercised).
//
// Pattern matches RelocateSafelyRedundantTests / VolumesWindowRetireTests.

@Suite(.serialized) @MainActor
struct ProvenanceTests {

    // MARK: - Fixtures

    private func makeRecord(fullPath: String,
                            stage: ArchiveStage = .none,
                            size: Int64 = 1024,
                            md5: String = "abcd0001",
                            notes: String = "",
                            originalFullPath: String? = nil,
                            originVolume: String? = nil,
                            combinedFromPairID: UUID? = nil) -> VideoRecord {
        let r = VideoRecord()
        r.filename = (fullPath as NSString).lastPathComponent
        r.fullPath = fullPath
        r.directory = (fullPath as NSString).deletingLastPathComponent
        r.sizeBytes = size
        r.partialMD5 = md5
        r.archiveStage = stage
        r.notes = notes
        r.originalFullPath = originalFullPath
        r.originVolume = originVolume
        r.combinedFromPairID = combinedFromPairID
        return r
    }

    /// Build a quick safety resolver from an inline map. Returns
    /// `(.unassigned, .unknown)` for unmatched paths — same neutral
    /// fallback the real resolver uses.
    private func resolver(_ table: [String: (VolumeRole, VolumeTrust)]) -> VolumeSafetyResolver {
        let sorted = table
            .map { (path: $0.key, safety: VolumeSafety(role: $0.value.0, trust: $0.value.1)) }
            .sorted { $0.path.count > $1.path.count }
        return { path in
            for entry in sorted where path.hasPrefix(entry.path + "/") || path == entry.path {
                return entry.safety
            }
            return VolumeSafety.unknown
        }
    }

    // MARK: - Volume Provenance (View 1)

    @Test
    func volumeProvenance_groupsWitnessesByDestinationVolume() {
        // Two records originally on Mini2TB. Each has a witness on a
        // different destination volume; one also has a witness on the
        // same destination as the other. Expect two destination groups,
        // with file counts 2 + 1.
        let witnessNote1 = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:00:00Z",
            witnesses: ["/Volumes/MyBook3Terabytes/clip1.mxf"],
            totalWitnessCount: 1
        )
        let witnessNote2 = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:01:00Z",
            witnesses: ["/Volumes/MyBook3Terabytes/clip2.mxf",
                        "/Volumes/LaCieWorkspace/clip2.mxf"],
            totalWitnessCount: 2
        )
        let r1 = makeRecord(fullPath: "/Volumes/Mini2TB/clip1.mxf",
                            stage: .manuallyDeleted, notes: witnessNote1)
        let r2 = makeRecord(fullPath: "/Volumes/Mini2TB/clip2.mxf",
                            stage: .manuallyDeleted, notes: witnessNote2)

        let res = resolver([
            "/Volumes/Mini2TB":           (.workspace, .unreliable),
            "/Volumes/MyBook3Terabytes":  (.backup,   .reliable),
            "/Volumes/LaCieWorkspace":    (.cloud,    .reliable)
        ])
        let prov = VideoScanModel.buildVolumeProvenance(
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            sourceVolumeName: "Mini2TB",
            sourceIsRetired: false,
            sourceRetiredAt: nil,
            sourceRetiredReason: nil,
            allRecords: [r1, r2],
            resolveVolumeSafety: res
        )
        // Should have grouped into MyBook3Terabytes (2) and
        // LaCieWorkspace (1). Sort is by safety score desc — LTA Reliable
        // beats Backup Reliable, so LaCieWorkspace comes first.
        #expect(prov.allDestinations.count == 2)
        #expect(prov.allDestinations[0].volumeName == "LaCieWorkspace")
        #expect(prov.allDestinations[0].fileCount == 1)
        #expect(prov.allDestinations[1].volumeName == "MyBook3Terabytes")
        #expect(prov.allDestinations[1].fileCount == 2)
    }

    @Test
    func volumeProvenance_safeTabExcludesRetiredAndUnreliable() {
        // One witness on a Reliable backup; one on a Retired drive. Safe
        // tab should show only the Reliable one; All tab shows both.
        let safeNote = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:00:00Z",
            witnesses: ["/Volumes/MyBook3Terabytes/clip1.mxf"],
            totalWitnessCount: 1
        )
        let retiredNote = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:01:00Z",
            witnesses: ["/Volumes/AncientDrive/clip2.mxf"],
            totalWitnessCount: 1
        )
        let r1 = makeRecord(fullPath: "/Volumes/Mini2TB/clip1.mxf",
                            stage: .manuallyDeleted, notes: safeNote)
        let r2 = makeRecord(fullPath: "/Volumes/Mini2TB/clip2.mxf",
                            stage: .manuallyDeleted, notes: retiredNote)
        let res = resolver([
            "/Volumes/Mini2TB":           (.workspace, .unreliable),
            "/Volumes/MyBook3Terabytes":  (.backup,   .reliable),
            "/Volumes/AncientDrive":      (.backup,   .unreliable)
        ])
        let prov = VideoScanModel.buildVolumeProvenance(
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            sourceVolumeName: "Mini2TB",
            sourceIsRetired: false,
            sourceRetiredAt: nil,
            sourceRetiredReason: nil,
            allRecords: [r1, r2],
            resolveVolumeSafety: res
        )
        #expect(prov.allDestinations.count == 2)
        #expect(prov.safeDestinations.count == 1)
        #expect(prov.safeDestinations[0].volumeName == "MyBook3Terabytes")
        // The retired-only record should NOT count as safely backed up.
        #expect(prov.recordsWithSafeBackup == 1)
        #expect(prov.atRiskFilenames == ["clip2.mxf"])
    }

    @Test
    func volumeProvenance_safeTabIncludesAgingButTrustedNonRetired() {
        // Aging + Reliable witness is still safe (only Unreliable and
        // Retired are filtered out). This regression-guards the predicate
        // — earlier drafts conflated "degraded" with "everything < safe".
        let note = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:00:00Z",
            witnesses: ["/Volumes/OldButReliable/clip.mxf"],
            totalWitnessCount: 1
        )
        let r = makeRecord(fullPath: "/Volumes/Mini2TB/clip.mxf",
                           stage: .manuallyDeleted, notes: note)
        let res = resolver([
            "/Volumes/Mini2TB":         (.workspace, .unreliable),
            "/Volumes/OldButReliable":  (.backup,   .aging)
        ])
        let prov = VideoScanModel.buildVolumeProvenance(
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            sourceVolumeName: "Mini2TB",
            sourceIsRetired: false,
            sourceRetiredAt: nil,
            sourceRetiredReason: nil,
            allRecords: [r],
            resolveVolumeSafety: res
        )
        #expect(prov.safeDestinations.count == 1)
        #expect(prov.safeDestinations[0].trust == .aging)
        #expect(prov.allRecordsSafe == true)
    }

    @Test
    func volumeProvenance_emptyVolumeShowsEmptyState() {
        let prov = VideoScanModel.buildVolumeProvenance(
            sourceVolumeRootPath: "/Volumes/NothingHere",
            sourceVolumeName: "NothingHere",
            sourceIsRetired: false,
            sourceRetiredAt: nil,
            sourceRetiredReason: nil,
            allRecords: [],
            resolveVolumeSafety: resolver([:])
        )
        #expect(prov.sourceRecordCount == 0)
        #expect(prov.allDestinations.isEmpty)
        #expect(prov.safeDestinations.isEmpty)
        #expect(prov.allRecordsSafe == false)
        #expect(prov.headlineText.contains("No files"))
    }

    // MARK: - File Journey (View 2)

    @Test
    func fileJourney_parsesReconcileEventsFromNotesInOrder() {
        // Three reconcile lines in the notes field, two with timestamps
        // out of order. The journey should sort them oldest-first and
        // sandwich them between Origin and Current State.
        let note = """
        Reconcile 2026-05-30T11:00:00Z: source-side move detected
        Reconcile 2026-05-30T10:00:00Z: reason=dup-on-other-volume witnesses=["/Volumes/X/c.bin"] totalWitnesses=1
        """
        let rec = makeRecord(fullPath: "/Volumes/Mini2TB/clip.mxf",
                             stage: .manuallyDeleted,
                             notes: note,
                             originVolume: "Mini2TB")
        let journey = VideoScanModel.buildFileJourney(
            for: rec,
            allRecords: [rec],
            resolveVolumeSafety: resolver([:])
        )
        // 1 origin + 2 reconcile + 1 current = 4 events
        #expect(journey.events.count == 4)
        #expect(journey.events.first?.kind == .origin)
        #expect(journey.events.last?.kind == .currentState)
        // Reconcile events should be ascending in time.
        let reconciles = journey.events.filter { $0.kind == .reconcile }
        #expect(reconciles.count == 2)
        if reconciles.count == 2,
           let t1 = reconciles[0].timestamp,
           let t2 = reconciles[1].timestamp {
            #expect(t1 < t2)
        } else {
            #expect(Bool(false), "expected two reconcile events with timestamps")
        }
    }

    @Test
    func fileJourney_handlesRecordWithNoNotes() {
        // The minimum-info record path. Origin + Current — nothing else.
        let rec = makeRecord(fullPath: "/Volumes/SomeDrive/clip.mxf")
        let journey = VideoScanModel.buildFileJourney(
            for: rec,
            allRecords: [rec],
            resolveVolumeSafety: resolver([:])
        )
        #expect(journey.events.count == 2)
        #expect(journey.events[0].kind == .origin)
        #expect(journey.events[1].kind == .currentState)
        #expect(journey.isMarkedDeleted == false)
        #expect(journey.otherKnownCopies.isEmpty)
    }

    @Test
    func fileJourney_currentStateReflectsArchiveStage() {
        // Marked-deleted record should produce a current-state event
        // that uses the retire icon and friendly "marked deleted" copy.
        let note = VideoScanModel.formatSafelyRedundantNote(
            stamp: "2026-05-30T10:00:00Z",
            witnesses: ["/Volumes/MyBook/clip.mxf"],
            totalWitnessCount: 1
        )
        let rec = makeRecord(fullPath: "/Volumes/Mini2TB/clip.mxf",
                             stage: .manuallyDeleted,
                             notes: note)
        let journey = VideoScanModel.buildFileJourney(
            for: rec,
            allRecords: [rec],
            resolveVolumeSafety: resolver([:])
        )
        #expect(journey.isMarkedDeleted == true)
        let last = journey.events.last
        #expect(last?.icon == "archivebox")
        #expect(last?.sentence.contains("Marked deleted") == true)
    }

    // MARK: - Migration Overview (View 3)

    @Test
    func migrationOverview_countsByOriginRoleCorrectly() {
        // Three records: one still on Original, one relocated from
        // Original to Backup, one born on Backup. Flow bars should:
        //   - Original → Original 1, Original → Backup 1
        //   - Backup → Backup 1
        let r1 = makeRecord(fullPath: "/Volumes/Drive1/a.mxf")
        let r2 = makeRecord(fullPath: "/Volumes/Drive2/b.mxf",
                            originalFullPath: "/Volumes/Drive1/b.mxf",
                            originVolume: "Drive1")
        let r3 = makeRecord(fullPath: "/Volumes/Drive2/c.mxf")
        let res = resolver([
            "/Volumes/Drive1": (.workspace, .reliable),
            "/Volumes/Drive2": (.backup,   .reliable)
        ])
        let mo = VideoScanModel.buildMigrationOverview(
            allRecords: [r1, r2, r3],
            resolveVolumeSafety: res,
            now: Date()
        )
        #expect(mo.totalRecords == 3)
        // Find the Original-source bar — it should have 1 → original
        // and 1 → backup.
        let origBar = mo.flowBars.first { $0.sourceRole == .workspace }
        #expect(origBar != nil)
        #expect(origBar?.totalRecords == 2)
        let origToOrig = origBar?.entries.first { $0.destinationRole == .workspace }
        let origToBackup = origBar?.entries.first { $0.destinationRole == .backup }
        #expect(origToOrig?.recordCount == 1)
        #expect(origToBackup?.recordCount == 1)
        // Backup-source bar — just 1.
        let backupBar = mo.flowBars.first { $0.sourceRole == .backup }
        #expect(backupBar?.totalRecords == 1)
    }

    @Test
    func migrationOverview_bestStuffCountsRecordsThatAreCombinedAndArchived() {
        // Four records:
        //   r1: combined + archived → counts
        //   r2: combined + lives on LTA volume → counts
        //   r3: combined but neither archived nor on LTA → does NOT count
        //   r4: archived but not combined → does NOT count
        let pid = UUID()
        let r1 = makeRecord(fullPath: "/Volumes/Backup/r1.mxf",
                            stage: .archived,
                            combinedFromPairID: pid)
        let r2 = makeRecord(fullPath: "/Volumes/LTA/r2.mxf",
                            stage: .none,
                            combinedFromPairID: pid)
        let r3 = makeRecord(fullPath: "/Volumes/Backup/r3.mxf",
                            stage: .none,
                            combinedFromPairID: pid)
        let r4 = makeRecord(fullPath: "/Volumes/Backup/r4.mxf",
                            stage: .archived,
                            combinedFromPairID: nil)
        let res = resolver([
            "/Volumes/Backup": (.backup, .reliable),
            "/Volumes/LTA":    (.cloud,   .reliable)
        ])
        let mo = VideoScanModel.buildMigrationOverview(
            allRecords: [r1, r2, r3, r4],
            resolveVolumeSafety: res,
            now: Date()
        )
        #expect(mo.bestStuffCount == 2)
        // Bytes — two records × default 1024.
        #expect(mo.bestStuffBytes == 2048)
        #expect(mo.bestStuffSentence.contains("2 clips"))
    }

    // MARK: - Friendly-tone guard

    @Test
    func friendlyHeadlineDoesNotContainSecurityJargon() {
        // Anti-drift guard. If a future change accidentally introduces
        // "audit" or "compliance" or "integrity" into a user-facing
        // headline, this test fails. Per feedback_friendly_language.md.
        let forbidden = ["audit", "compliance", "integrity scan",
                         "surveillance", "forensic"]

        // VolumeProvenance headline strings.
        let prov = VideoScanModel.buildVolumeProvenance(
            sourceVolumeRootPath: "/Volumes/Mini2TB",
            sourceVolumeName: "Mini2TB",
            sourceIsRetired: false,
            sourceRetiredAt: nil,
            sourceRetiredReason: nil,
            allRecords: [],
            resolveVolumeSafety: resolver([:])
        )
        for word in forbidden {
            #expect(prov.headlineText.lowercased().contains(word) == false,
                    "VolumeProvenance headline contained forbidden word: \(word)")
        }

        // MigrationOverview best-stuff sentence.
        let mo = VideoScanModel.buildMigrationOverview(
            allRecords: [],
            resolveVolumeSafety: resolver([:]),
            now: Date()
        )
        for word in forbidden {
            #expect(mo.bestStuffSentence.lowercased().contains(word) == false,
                    "Best stuff sentence contained forbidden word: \(word)")
        }

        // FileJourney sentences — exercise a record with notes that
        // would have triggered the old "audit" phrasing.
        let rec = makeRecord(
            fullPath: "/Volumes/Mini2TB/x.bin",
            stage: .manuallyDeleted,
            notes: VideoScanModel.formatSafelyRedundantNote(
                stamp: "2026-05-30T10:00:00Z",
                witnesses: ["/Volumes/MyBook/x.bin"],
                totalWitnessCount: 1
            )
        )
        let journey = VideoScanModel.buildFileJourney(
            for: rec,
            allRecords: [rec],
            resolveVolumeSafety: resolver([:])
        )
        for evt in journey.events {
            for word in forbidden {
                #expect(evt.sentence.lowercased().contains(word) == false,
                        "Journey event '\(evt.sentence)' contained forbidden word: \(word)")
            }
        }
    }
}
