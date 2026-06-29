// CatalogStoreAsyncSaveTests.swift
// Locks down the off-main save path added 2026-06-10 (perf fix: a tag/
// rating/note edit was triggering a multi-second main-thread stall while
// JSONEncoder serialized a ~73 MB catalog.json on the main actor).
//
// The contract under test:
//   1. Round trip — a save through saveAsync (snapshot on main, encode+
//      write on the background queue) reads back identically.
//   2. Compact output — no .prettyPrinted/.sortedKeys (30-40% smaller file).
//   3. Snapshot independence — mutating a live record AFTER saveAsync
//      returns must NOT leak into the in-flight write. This is the
//      race-freedom property: the background encoder only ever sees the
//      deep copies made on the main actor.
//   4. Coalescing — a dirty mark while a save is in flight triggers a
//      follow-up save; the final file contains the latest edit. The
//      user's catalog never loses an edit to an unlucky overlap.
//   5. Clone parity — snapshotClone() + deepCopySnapshot() produce records
//      that encode byte-identically to the originals (for every field the
//      fully-populated fixture exercises) and that rewire pairedWith to
//      the partner's CLONE, never into the live graph.
//
// All tests use CatalogStore(directory:) against per-test scratch dirs.

import Testing
import Foundation
@testable import VideoScan

// MARK: - Write waiter

/// Test observer: counts catalogStoreDidWrite callbacks and lets a test
/// suspend until N writes have landed. Everything runs on the main actor
/// (the observer protocol is @MainActor), so no locking is needed.
@MainActor
private final class WriteWaiter: CatalogStoreObserver {
    private(set) var writeCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    private var target = Int.max

    func catalogStoreDidWrite(_ store: CatalogStore) {
        writeCount += 1
        if writeCount >= target, let c = continuation {
            continuation = nil
            target = Int.max
            c.resume()
        }
    }

    func waitForWrites(_ n: Int) async {
        if writeCount >= n { return }
        target = n
        await withCheckedContinuation { continuation = $0 }
    }
}

@MainActor
struct CatalogStoreAsyncSaveTests {

    private func scratchDir() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("videoscan_async_save_\(UUID().uuidString)",
                                    isDirectory: true)
    }

    private func makeRecord(name: String, notes: String = "") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/Test/\(name)"
        r.notes = notes
        return r
    }

    // MARK: 1. Round trip through the async path

    @Test
    func asyncSaveRoundTripsThroughBackgroundPath() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let waiter = WriteWaiter()
        store.observer = waiter

        let rec = makeRecord(name: "clip.mov", notes: "birthday")
        rec.audioTranscript = "happy birthday matt"
        rec.sceneCaptions = [SceneCaption(timestamp: 1.5, text: "kids around a cake")]
        rec.starRating = 3

        store.saveAsync(records: [rec])
        await waiter.waitForWrites(1)

        let loaded = CatalogStore(directory: dir).load()
        #expect(loaded.count == 1)
        #expect(loaded.first?.filename == "clip.mov")
        #expect(loaded.first?.notes == "birthday")
        #expect(loaded.first?.audioTranscript == "happy birthday matt")
        #expect(loaded.first?.sceneCaptions == [SceneCaption(timestamp: 1.5, text: "kids around a cake")])
        #expect(loaded.first?.starRating == 3)
    }

    // MARK: 2. Compact (non-pretty) output

    @Test
    func savedJsonIsCompact() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let waiter = WriteWaiter()
        store.observer = waiter

        store.saveAsync(records: [makeRecord(name: "a.mov")])
        await waiter.waitForWrites(1)

        let text = try String(contentsOf: URL(fileURLWithPath: store.fileLocation), encoding: .utf8)
        // Compact JSONEncoder output contains no raw newlines (newlines
        // inside string values would be escaped as \n). Pretty-printed
        // output is full of them — this pins the formatting change.
        #expect(!text.contains("\n"),
                "catalog.json must be compact JSON — pretty-printing a 73 MB catalog cost ~30-40% extra bytes and encode time")
    }

    // MARK: 3. Snapshot independence (race-freedom)

    @Test
    func mutationAfterSaveAsyncDoesNotLeakIntoInFlightWrite() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let waiter = WriteWaiter()
        store.observer = waiter
        // Hold the background write open so the mutation below provably
        // happens while the write is still in flight.
        store.testWriteDelay = 0.25

        let rec = makeRecord(name: "clip.mov", notes: "before")
        store.saveAsync(records: [rec])

        // saveAsync has returned ⇒ the main-actor snapshot is complete.
        // This mutation races the background ENCODE only if the encoder
        // were reading the live object — it must not.
        rec.notes = "after"
        rec.detectedPeople = ["Donna"]

        await waiter.waitForWrites(1)

        let loaded = CatalogStore(directory: dir).load()
        #expect(loaded.first?.notes == "before",
                "The write must contain the snapshot taken at saveAsync time, not later mutations")
        #expect(loaded.first?.detectedPeople.isEmpty == true)
    }

    // MARK: 4. Dirty-during-save coalescing

    @Test
    func dirtyMarkDuringInFlightSaveTriggersFollowUpSave() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let waiter = WriteWaiter()
        store.observer = waiter
        store.testWriteDelay = 0.25

        let rec = makeRecord(name: "clip.mov", notes: "v1")
        store.saveAsync(records: [rec])   // write 1 now in flight (held open 250 ms)

        rec.notes = "v2"
        store.saveAsync(records: [rec])   // dirty during in-flight save → must coalesce, not drop

        await waiter.waitForWrites(2)
        #expect(waiter.writeCount == 2, "Exactly one follow-up save — coalesced, not dropped, not duplicated")

        let loaded = CatalogStore(directory: dir).load()
        #expect(loaded.first?.notes == "v2",
                "The follow-up save must persist the edit made during the in-flight save")
    }

    // A third dirty mark while still in flight supersedes the second —
    // latest-wins, still exactly one follow-up write.
    @Test
    func multipleDirtyMarksCoalesceToSingleFollowUp() async throws {
        let dir = scratchDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let waiter = WriteWaiter()
        store.observer = waiter
        store.testWriteDelay = 0.25

        let rec = makeRecord(name: "clip.mov", notes: "v1")
        store.saveAsync(records: [rec])
        rec.notes = "v2"
        store.saveAsync(records: [rec])
        rec.notes = "v3"
        store.saveAsync(records: [rec])

        await waiter.waitForWrites(2)
        // Give a hypothetical (buggy) third write a beat to show up.
        try await Task.sleep(nanoseconds: 100_000_000)
        #expect(waiter.writeCount == 2)

        let loaded = CatalogStore(directory: dir).load()
        #expect(loaded.first?.notes == "v3", "Latest edit wins")
    }

    // MARK: 5a. Clone parity — fully-populated record encodes identically

    @Test
    func cloneEncodesIdenticallyToOriginal() throws {
        // Decode a record with EVERY CodingKey populated, clone it, and
        // compare the encoded bytes. Catches snapshotClone() drift for any
        // field this fixture exercises. When adding a VideoRecord field,
        // add it here too (alongside CodingKeys / init(from:) / encode /
        // snapshotClone — see the maintenance note in Models.swift).
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "filename": "clip.mov", "ext": "mov", "streamTypeRaw": "Video+Audio",
          "size": "1.2 GB", "sizeBytes": 123456789,
          "duration": "00:01:00", "durationSeconds": 60.5,
          "dateCreated": "1991-06-21", "dateModified": "1991-06-22",
          "dateCreatedRaw": "1991-06-21T12:00:00Z", "dateModifiedRaw": "1991-06-22T12:00:00Z",
          "container": "mov", "videoCodec": "h264", "resolution": "720x480",
          "frameRate": "29.97", "videoBitrate": "8 Mb/s", "totalBitrate": "9 Mb/s",
          "colorSpace": "bt601", "bitDepth": "8", "scanType": "interlaced",
          "audioCodec": "pcm_s16le", "audioChannels": "2", "audioSampleRate": "48000",
          "timecode": "01:00:00:00", "tapeName": "Tape1", "isPlayable": "Yes",
          "partialMD5": "ABC123", "fullPath": "/Volumes/T/clip.mov",
          "directory": "/Volumes/T", "notes": "birthday",
          "originalFullPath": "/Volumes/Old/clip.mov", "originVolume": "OldDrive",
          "avidClipName": "Clip 1", "avidMobID": "mob1", "avidMaterialUUID": "amu",
          "avidBinFile": "bin.avb", "avidMobType": "Master", "avidMediaPath": "/avid/media",
          "avidTapeName": "AT", "avidEditRate": 29.97, "avidTracks": "V1, A1-A2",
          "materialPackageUMID": "0x060A2B34",
          "pairedWithID": "99999999-9999-9999-9999-999999999999",
          "pairGroupID": "88888888-8888-8888-8888-888888888888",
          "pairConfidence": "High",
          "duplicateGroupID": "77777777-7777-7777-7777-777777777777",
          "duplicateConfidence": "Medium", "duplicateDisposition": "Keep",
          "duplicateReasons": "same md5", "duplicateBestMatchFilename": "other.mov",
          "duplicateGroupCount": 2,
          "lifecycleStage": "Cataloged", "mediaDisposition": "Important",
          "archiveStage": "Backed Up", "masterLocation": "Mac Studio SSD",
          "backupDestinations": [{"name": "LTA_Crucial", "kind": "Local", "date": "2026-01-01T00:00:00Z"}],
          "junkScore": 3, "junkReasons": ["short"], "starRating": 2,
          "detectedPeople": ["Donna"], "suspectedPeople": ["Tim"],
          "confirmedByUserPeople": [{"name": "Donna", "confirmedAt": "2026-04-12T00:00:00Z"}],
          "rejectedPeople": ["Anna"],
          "sceneCaptions": [{"timestamp": 1.5, "text": "a man playing guitar"}],
          "ocrDateCandidates": [{"timestamp": 2, "text": "JUN.21 1991"}],
          "ocrText": [{"timestamp": 3, "text": "Happy Birthday"}],
          "inferredRecordDate": "1991-06-21T00:00:00Z", "inferredDateConfidence": 0.95,
          "dossierProcessedAt": "2026-06-04T00:00:00Z", "dossierProcessedBy": "qwen+whisper",
          "sceneCaptionModel": "qwen2.5-vl-3b-4bit", "sceneCaptionDate": "2026-05-22T00:00:00Z",
          "audioTranscript": "happy birthday matt",
          "audioTranscriptModel": "whisper-medium-mlx-q4",
          "audioTranscriptDate": "2026-06-04T01:00:00Z",
          "combinedFromPairID": "66666666-6666-6666-6666-666666666666",
          "sourceHost": "MacStudio",
          "scanContext": {
            "scanHost": "MacStudio", "volumeUUID": "VU-1", "volumeMountType": "smbfs",
            "volumeName": "MyBook3Terabytes", "remoteServerName": "macpro.local",
            "scannedAt": "2026-05-01T00:00:00Z", "scanRootLabel": "Movies"
          },
          "purgedAt": "2026-06-01T00:00:00Z"
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let original = try decoder.decode(VideoRecord.self, from: Data(json.utf8))

        let clones = CatalogStore.deepCopySnapshot(records: [original])
        #expect(clones.count == 1)
        let clone = try #require(clones.first)
        #expect(clone !== original, "Clone must be a distinct object")

        // sortedKeys here so byte comparison is key-order independent.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let a = try encoder.encode(original)
        let b = try encoder.encode(clone)
        #expect(a == b, "snapshotClone() drifted from VideoRecord's stored properties — a field is missing from the clone")
    }

    // MARK: 5b. pairedWith rewiring stays inside the cloned graph

    @Test
    func deepCopyRewiresPairedWithToClonedPartner() throws {
        let video = makeRecord(name: "v.mxf")
        let audio = makeRecord(name: "a.mxf")
        video.pairedWith = audio
        audio.pairedWith = video   // cycle, like real Correlate output

        let clones = CatalogStore.deepCopySnapshot(records: [video, audio])
        #expect(clones.count == 2)
        let cv = clones[0], ca = clones[1]

        // Partner references must point at CLONES — never back into the
        // live graph the main actor can mutate.
        #expect(cv.pairedWith === ca)
        #expect(ca.pairedWith === cv)
        #expect(cv.pairedWith !== audio)
        #expect(ca.pairedWith !== video)

        // And the encoded pairedWithID survives the copy.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(cv)
        let obj = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(obj["pairedWithID"] as? String == audio.id.uuidString)
    }

    // Partner outside the records array (defensive path): id-only stub,
    // still encodes the right pairedWithID.
    @Test
    func deepCopyHandlesPartnerOutsideArray() throws {
        let video = makeRecord(name: "v.mxf")
        let orphanPartner = makeRecord(name: "a.mxf")
        video.pairedWith = orphanPartner

        let clones = CatalogStore.deepCopySnapshot(records: [video])
        let cv = try #require(clones.first)
        #expect(cv.pairedWith !== orphanPartner, "Stub must not reference the live partner")
        #expect(cv.pairedWith?.id == orphanPartner.id)
    }

    // MARK: 6. DTO byte-identity (seam E regression guard)
    //
    // The off-main catalog save (2026-06-29 seam E) no longer encodes the
    // non-Sendable VideoRecord off the main actor. Instead it builds a
    // Sendable `VideoRecordDTO` / `CatalogSnapshotDTO` payload ON the main
    // actor and encodes THAT off-thread. catalog.json is irreplaceable
    // family-archive data, so the DTO's JSON MUST be byte-for-byte identical
    // to what VideoRecord / CatalogSnapshot produced before this refactor.
    //
    // These two tests are the safety net. They use the EXACT encoder the
    // catalog uses (compact — NO .sortedKeys — so KEY ORDER is pinned too,
    // not just key presence — plus .iso8601 dates). If the DTO ever drifts
    // from the class (e.g. a future field added to one but not the other, or
    // VideoRecord.encode stops delegating to the DTO), the byte comparison
    // fails loudly.

    /// A fully-populated VideoRecord with a resolved `pairedWith` partner so
    /// the `pairedWith?.id` → `pairedWithID` flattening is exercised.
    private static func fullyPopulatedRecordWithPartner() throws -> VideoRecord {
        let json = """
        {
          "id": "11111111-2222-3333-4444-555555555555",
          "filename": "clip.mov", "ext": "mov", "streamTypeRaw": "Video+Audio",
          "size": "1.2 GB", "sizeBytes": 123456789,
          "duration": "00:01:00", "durationSeconds": 60.5,
          "dateCreated": "1991-06-21", "dateModified": "1991-06-22",
          "dateCreatedRaw": "1991-06-21T12:00:00Z", "dateModifiedRaw": "1991-06-22T12:00:00Z",
          "container": "mov", "videoCodec": "h264", "resolution": "720x480",
          "frameRate": "29.97", "videoBitrate": "8 Mb/s", "totalBitrate": "9 Mb/s",
          "colorSpace": "bt601", "bitDepth": "8", "scanType": "interlaced",
          "audioCodec": "pcm_s16le", "audioChannels": "2", "audioSampleRate": "48000",
          "timecode": "01:00:00:00", "tapeName": "Tape1", "isPlayable": "Yes",
          "partialMD5": "ABC123", "fullPath": "/Volumes/T/clip.mov",
          "directory": "/Volumes/T", "notes": "birthday",
          "originalFullPath": "/Volumes/Old/clip.mov", "originVolume": "OldDrive",
          "avidClipName": "Clip 1", "avidMobID": "mob1", "avidMaterialUUID": "amu",
          "avidBinFile": "bin.avb", "avidMobType": "Master", "avidMediaPath": "/avid/media",
          "avidTapeName": "AT", "avidEditRate": 29.97, "avidTracks": "V1, A1-A2",
          "materialPackageUMID": "0x060A2B34",
          "pairGroupID": "88888888-8888-8888-8888-888888888888",
          "pairConfidence": "High",
          "duplicateGroupID": "77777777-7777-7777-7777-777777777777",
          "duplicateConfidence": "Medium", "duplicateDisposition": "Keep",
          "duplicateReasons": "same md5", "duplicateBestMatchFilename": "other.mov",
          "duplicateGroupCount": 2,
          "lifecycleStage": "Cataloged", "mediaDisposition": "Important",
          "archiveStage": "Backed Up", "masterLocation": "Mac Studio SSD",
          "backupDestinations": [{"name": "LTA_Crucial", "kind": "Local", "date": "2026-01-01T00:00:00Z"}],
          "junkScore": 3, "junkReasons": ["short"], "starRating": 2,
          "detectedPeople": ["Donna"], "suspectedPeople": ["Tim"],
          "confirmedByUserPeople": [{"name": "Donna", "confirmedAt": "2026-04-12T00:00:00Z"}],
          "rejectedPeople": ["Anna"],
          "sceneCaptions": [{"timestamp": 1.5, "text": "a man playing guitar"}],
          "ocrDateCandidates": [{"timestamp": 2, "text": "JUN.21 1991"}],
          "ocrText": [{"timestamp": 3, "text": "Happy Birthday"}],
          "inferredRecordDate": "1991-06-21T00:00:00Z", "inferredDateConfidence": 0.95,
          "dossierProcessedAt": "2026-06-04T00:00:00Z", "dossierProcessedBy": "qwen+whisper",
          "sceneCaptionModel": "qwen2.5-vl-3b-4bit", "sceneCaptionDate": "2026-05-22T00:00:00Z",
          "audioTranscript": "happy birthday matt",
          "audioTranscriptModel": "whisper-medium-mlx-q4",
          "audioTranscriptDate": "2026-06-04T01:00:00Z",
          "combinedFromPairID": "66666666-6666-6666-6666-666666666666",
          "sourceHost": "MacStudio",
          "scanContext": {
            "scanHost": "MacStudio", "volumeUUID": "VU-1", "volumeMountType": "smbfs",
            "volumeName": "MyBook3Terabytes", "remoteServerName": "macpro.local",
            "scannedAt": "2026-05-01T00:00:00Z", "scanRootLabel": "Movies"
          },
          "purgedAt": "2026-06-01T00:00:00Z",
          "drmProtected": true, "needsReformat": true,
          "derivedFrom": "55555555-aaaa-bbbb-cccc-555555555555",
          "workspaceActive": true
        }
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(VideoRecord.self, from: Data(json.utf8))
        // Resolve a real pairedWith so pairedWithID is encoded (not omitted).
        let partner = VideoRecord()
        partner.id = UUID(uuidString: "99999999-9999-9999-9999-999999999999")!
        record.pairedWith = partner
        return record
    }

    /// Exactly the encoder CatalogStore.encodeAndWrite uses — compact (no
    /// .sortedKeys / .prettyPrinted), .iso8601 dates. Compact means the byte
    /// comparison pins KEY ORDER, not just key set.
    private static func catalogEncoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// VideoRecordDTO must encode byte-for-byte identically to VideoRecord.
    @Test
    func dtoEncodesByteIdenticalToVideoRecord() throws {
        let record = try Self.fullyPopulatedRecordWithPartner()
        let enc = Self.catalogEncoder()

        let fromClass = try enc.encode(record)
        let fromDTO = try enc.encode(VideoRecordDTO(record))

        #expect(fromClass == fromDTO,
                "VideoRecordDTO drifted from VideoRecord's on-disk encoding — catalog.json would change shape")
        // Sanity: prove the comparison is non-vacuous (the fixture really did
        // produce a fat record, and pairedWithID really is present).
        #expect(fromDTO.count > 500)
        let obj = try #require(try JSONSerialization.jsonObject(with: fromDTO) as? [String: Any])
        #expect(obj["pairedWithID"] as? String == "99999999-9999-9999-9999-999999999999")
    }

    /// The full on-disk file shape: CatalogSnapshotDTO must encode byte-for-
    /// byte identically to CatalogSnapshot (snapshot wrapper + record array).
    /// Both built with the SAME savedAt so only the encode contract differs.
    @Test
    func snapshotDTOEncodesByteIdenticalToCatalogSnapshot() throws {
        let record = try Self.fullyPopulatedRecordWithPartner()
        let savedAt = Date(timeIntervalSince1970: 1_750_000_000)  // fixed instant
        let host = "MacStudio"

        let classSnapshot = CatalogSnapshot(version: CatalogSnapshot.currentVersion,
                                            savedAt: savedAt,
                                            records: [record],
                                            savedFromHost: host)
        let dtoSnapshot = CatalogSnapshotDTO(version: CatalogSnapshot.currentVersion,
                                             savedAt: savedAt,
                                             records: [VideoRecordDTO(record)],
                                             savedFromHost: host)

        let enc = Self.catalogEncoder()
        let fromClass = try enc.encode(classSnapshot)
        let fromDTO = try enc.encode(dtoSnapshot)

        #expect(fromClass == fromDTO,
                "CatalogSnapshotDTO drifted from CatalogSnapshot — the on-disk catalog.json wrapper would change")
    }
}
