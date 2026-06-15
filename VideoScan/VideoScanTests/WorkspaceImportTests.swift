import Testing
import Foundation
@testable import VideoScan

// MARK: - Workspace Import Tests (Pass B)
//
// Pass B of the Triage workflow (Manager dispatch 2026-06-14):
//   - "Import to Workspace" toolbar button on Triage tab.
//   - NSOpenPanel → probeFile → lineage picker sheet → append to catalog.
//   - New record gets workspaceActive=true; optionally derivedFrom=parent.id.
//
// These tests cover the testable pieces of the flow:
//   1. A record carrying BOTH workspaceActive=true AND derivedFrom=<UUID>
//      round-trips through the catalog persistence layer (it's the
//      shape that lands on disk after import).
//   2. The lineage picker's candidate filter (extracted as
//      workspaceImportLineageCandidates) returns only matching,
//      non-archived records.
//
// The NSOpenPanel + ffprobe ingest itself is skipped per spec — UI
// sheets are painful to drive in XCTest and the probe is already
// covered by existing scan tests.

struct WorkspaceImportTests {

    // MARK: - Test helpers

    private func makeRecord(
        name: String,
        workspaceActive: Bool = false,
        derivedFrom: UUID? = nil,
        lifecycleStage: LifecycleStage = .cataloged
    ) -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/TestVol/\(name)"
        r.directory = "/Volumes/TestVol"
        // volumeName is a computed property derived from scanContext —
        // don't try to assign it here. The tests don't need it set.
        r.partialMD5 = String(name.hash, radix: 16)
        r.sizeBytes = 1_000_000
        r.streamTypeRaw = StreamType.videoAndAudio.rawValue
        r.workspaceActive = workspaceActive
        r.derivedFrom = derivedFrom
        r.lifecycleStage = lifecycleStage
        return r
    }

    // MARK: - 1. Import flow output shape

    /// regression: Pass B spec — when the user imports a file derived
    /// from a parent record, the resulting catalog entry has BOTH
    /// `workspaceActive=true` AND `derivedFrom=<parent.id>` set, and
    /// this combination must survive the Codable round-trip (since
    /// that's what `saveCatalogDebounced()` ultimately writes to disk).
    @Test func importFlowSetsWorkspaceActive() throws {
        let parentID = UUID()
        let imported = makeRecord(
            name: "edit_pass_2.mov",
            workspaceActive: true,
            derivedFrom: parentID
        )

        // Sanity — the in-memory record we're about to encode reflects
        // exactly what runImportFlow + commitImportedRecord would set.
        #expect(imported.workspaceActive == true,
                "Imported records must be workspace-active by construction")
        #expect(imported.derivedFrom == parentID,
                "Imported records linked to a parent must carry derivedFrom")

        // Round-trip through JSON to model the catalog-save path. If a
        // future encoder change drops either field, this fails loud.
        let encoder = JSONEncoder()
        let data = try encoder.encode(imported)
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(VideoRecord.self, from: data)

        #expect(decoded.workspaceActive == true,
                "workspaceActive must round-trip when set by the import flow")
        #expect(decoded.derivedFrom == parentID,
                "derivedFrom must round-trip when set by the import flow")
        #expect(decoded.filename == imported.filename,
                "filename round-trip — sanity check that the rest of the record survived")

        // Also confirm snapshotClone() propagates both fields, since
        // anything that clones an imported record (focus sets, undo
        // snapshots, etc.) needs to preserve the lineage + flag.
        let clone = imported.snapshotClone()
        #expect(clone.workspaceActive == true,
                "snapshotClone() must propagate workspaceActive (clone-parity contract)")
        #expect(clone.derivedFrom == parentID,
                "snapshotClone() must propagate derivedFrom (clone-parity contract)")
    }

    // MARK: - 2. Lineage picker candidate filter

    /// regression: Pass B spec — the lineage picker's candidate filter
    /// must (a) include non-archived matching records, (b) exclude
    /// archived records (we don't derive new work from archived
    /// sources), and (c) exclude non-matching records.
    @Test func lineagePickerPredicate() {
        let match = makeRecord(
            name: "Christmas_1985_raw.mov",
            lifecycleStage: .cataloged
        )
        let archived = makeRecord(
            name: "Christmas_1985_master.mov",
            lifecycleStage: .archived
        )
        let nonMatch = makeRecord(
            name: "Birthday_1992_raw.mov",
            lifecycleStage: .cataloged
        )

        let candidates = workspaceImportLineageCandidates(
            in: [match, archived, nonMatch],
            matching: "christmas"
        )

        #expect(candidates.count == 1,
                "Exactly one candidate should pass the lineage filter for 'christmas'")
        #expect(candidates.first?.id == match.id,
                "The non-archived matching record must be the one that passes")
        #expect(!candidates.contains { $0.id == archived.id },
                "Archived records must NEVER appear as lineage candidates")
        #expect(!candidates.contains { $0.id == nonMatch.id },
                "Non-matching records must NEVER appear as lineage candidates")
    }

    /// regression: empty-query case — when the user opens the picker
    /// without typing anything, they should see every eligible
    /// (non-archived) record. Pass B spec lists this as "first 50
    /// records sorted by filename"; the limit is configurable.
    @Test func lineagePickerEmptyQueryReturnsAllEligible() {
        let a = makeRecord(name: "a.mov", lifecycleStage: .cataloged)
        let b = makeRecord(name: "b.mov", lifecycleStage: .archived)
        let c = makeRecord(name: "c.mov", lifecycleStage: .cataloged)

        let candidates = workspaceImportLineageCandidates(
            in: [a, b, c],
            matching: ""
        )

        #expect(candidates.count == 2,
                "Empty query should return all non-archived records")
        #expect(candidates.contains { $0.id == a.id })
        #expect(candidates.contains { $0.id == c.id })
        #expect(!candidates.contains { $0.id == b.id },
                "Archived records excluded even when query is empty")
    }

    /// regression: the limit param caps the result list. Important
    /// because the picker renders all candidates inline and a catalog
    /// with thousands of records would otherwise stall the sheet on
    /// open.
    @Test func lineagePickerHonorsLimit() {
        let records = (0..<100).map { i in
            makeRecord(name: String(format: "clip_%03d.mov", i),
                       lifecycleStage: .cataloged)
        }

        let candidates = workspaceImportLineageCandidates(
            in: records,
            matching: "",
            limit: 10
        )

        #expect(candidates.count == 10,
                "Limit must cap the candidate list — UI responsiveness contract")
    }

    // MARK: - 3. Suggested-parent stem detection

    /// regression: Topaz Video AI chained suffix — denoise + 3 model
    /// codes — should strip to the original stem. This is the real-world
    /// case Rick hit on 2026-06-15.
    @Test func suggestedStem_topazChainedSuffix() {
        let stem = workspaceImportSuggestedParentStem(
            forFilename: "Thanksgiving-Raw_Default_denoise_thm2_nyx3_hyp1.mov"
        )
        #expect(stem == "Thanksgiving-Raw_Default",
                "Chained Topaz suffix should strip to the source stem")
    }

    /// VideoScan Reformat output convention.
    @Test func suggestedStem_vsReformatted() {
        let stem = workspaceImportSuggestedParentStem(
            forFilename: "Thanksgiving-Raw_Default_reformatted.mp4"
        )
        #expect(stem == "Thanksgiving-Raw_Default",
                "_reformatted suffix should strip to the source stem")
    }

    /// VideoScan Transcode (Pass C) output convention — .vs.edit and
    /// .vs.archive markers.
    @Test func suggestedStem_vsTranscode() {
        let editStem = workspaceImportSuggestedParentStem(
            forFilename: "BirthdayParty.vs.edit.mov"
        )
        #expect(editStem == "BirthdayParty",
                ".vs.edit suffix should strip to the source stem")

        let archiveStem = workspaceImportSuggestedParentStem(
            forFilename: "BirthdayParty.vs.archive.mov"
        )
        #expect(archiveStem == "BirthdayParty",
                ".vs.archive suffix should strip to the source stem")
    }

    /// Plain original (no recognized derivative suffix) — must return
    /// nil so the sheet shows no auto-suggestion and the user types
    /// to find a parent or commits as "no parent."
    @Test func suggestedStem_plainOriginalReturnsNil() {
        #expect(workspaceImportSuggestedParentStem(forFilename: "Christmas_1985_raw.mov") == nil)
        #expect(workspaceImportSuggestedParentStem(forFilename: "IMG_4242.mov") == nil)
    }

    /// regression: exact-stem match must return the unique catalog
    /// record. This is the auto-select path the sheet's init uses.
    @Test func exactStemMatch_uniqueParent() {
        let parent = makeRecord(name: "Thanksgiving-Raw_Default.mov",
                                lifecycleStage: .cataloged)
        let sibling = makeRecord(name: "Thanksgiving-Raw_Default_reformatted.mp4",
                                 lifecycleStage: .cataloged)
        let other = makeRecord(name: "Birthday.mov",
                               lifecycleStage: .cataloged)

        let match = workspaceImportFindExactStemMatch(
            stem: "Thanksgiving-Raw_Default",
            in: [parent, sibling, other]
        )

        #expect(match?.id == parent.id,
                "Exact stem match must return only the record whose basename-minus-extension equals the stem")
    }

    /// regression: an archived candidate must be excluded from
    /// auto-selection (same policy as the lineage candidate filter).
    @Test func exactStemMatch_archivedExcluded() {
        let archived = makeRecord(name: "Old.mov",
                                  lifecycleStage: .archived)
        let match = workspaceImportFindExactStemMatch(
            stem: "Old",
            in: [archived]
        )
        #expect(match == nil,
                "Archived records must never be auto-selected as parents")
    }

    /// regression: ambiguity (two records share the same stem) must
    /// return nil so the user picks manually.
    @Test func exactStemMatch_ambiguousReturnsNil() {
        let a = makeRecord(name: "Clip.mov", lifecycleStage: .cataloged)
        let b = makeRecord(name: "Clip.mov", lifecycleStage: .cataloged)
        let match = workspaceImportFindExactStemMatch(
            stem: "Clip",
            in: [a, b]
        )
        #expect(match == nil,
                "Two records sharing a stem is ambiguous — let the user pick")
    }

    // MARK: - 4. Import-context legacy codec banner

    /// regression: the import banner must mention Transcode → For
    /// Editing as the in-app fix, since that's the next action the
    /// user takes after committing the import. Different wording from
    /// `unplayableLegacyReason` (which the Reformat dialog uses).
    @Test func legacyCodecBanner_qdm2AudioMentionsTranscode() {
        let banner = workspaceImportLegacyCodecBanner(
            videoCodec: "prores",
            audioCodec: "qdm2"
        )
        #expect(banner != nil,
                "QDM2 audio must trigger the legacy-codec banner")
        #expect(banner?.contains("Transcode") == true,
                "Banner must point at the Transcode verb so the user knows the in-app fix")
        #expect(banner?.contains("FCP") == true,
                "Banner must mention FCP so the user understands the playback consequence")
        #expect(banner?.contains("import fine") == true,
                "Banner must reassure that the import itself succeeds (it's informational, not blocking)")
    }

    /// Both-codec case (svq3 video + qdm2 audio — the Thanksgiving
    /// source) — banner mentions both codecs in one message.
    @Test func legacyCodecBanner_bothCodecs() {
        let banner = workspaceImportLegacyCodecBanner(
            videoCodec: "svq3",
            audioCodec: "qdm2"
        )
        #expect(banner?.contains("svq3") == true,
                "Both-codec banner must name the video codec")
        #expect(banner?.contains("qdm2") == true,
                "Both-codec banner must name the audio codec")
    }

    /// Modern codecs → no banner.
    @Test func legacyCodecBanner_modernCodecsReturnsNil() {
        #expect(workspaceImportLegacyCodecBanner(videoCodec: "h264", audioCodec: "aac") == nil)
        #expect(workspaceImportLegacyCodecBanner(videoCodec: "hevc", audioCodec: "aac") == nil)
        #expect(workspaceImportLegacyCodecBanner(videoCodec: "prores", audioCodec: "pcm_s24le") == nil)
    }
}
