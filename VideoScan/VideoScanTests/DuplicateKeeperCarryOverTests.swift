import Foundation
import Testing
@testable import VideoScan

// MARK: - Human-metadata carry-over on duplicate deletion (2026-08-18)
//
// The 8/17 worry, second half: even with a better keeper election, an
// extra copy can still hold Rick's work (stars, confirmed people, notes,
// tags, provenance stamp). When its bytes are verified identical and
// removed, that work must fold into the keeper — with the SAME rules as
// repair adoption (applyHumanMetadataInheritance): union, never clobber
// a judgment already on the keeper, never touch machine metadata.
//
// Dimensions: Logic (rules), Sensor (the delete path really calls the
// merge — a gate that exists but is never called protects nothing).

@MainActor
private func makeModel(_ dir: URL) -> VideoScanModel {
    let model = VideoScanModel()
    model.catalogStore = CatalogStore(directory: dir)
    return model
}

private func write(_ url: URL, _ bytes: [UInt8]) {
    FileManager.default.createFile(atPath: url.path, contents: Data(bytes))
}

@MainActor
private func dupRecord(path: String, size: Int64, group: UUID,
                       disposition: DuplicateDisposition) -> VideoRecord {
    let r = VideoRecord()
    r.fullPath = path
    r.filename = (path as NSString).lastPathComponent
    r.sizeBytes = size
    r.partialMD5 = "m"
    r.durationSeconds = 61.0
    r.duplicateGroupID = group
    r.duplicateDisposition = disposition
    r.duplicateConfidence = .high
    return r
}

@Suite(.serialized)
@MainActor
struct DuplicateKeeperCarryOverTests {

    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("DupCarry-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The whole contract on the real delete path: identical bytes,
    /// extra carries metadata, keeper has its own judgments — after the
    /// delete the keeper holds the union and none of its own values were
    /// overwritten.
    @Test func verifiedDeleteCarriesHumanMetadataOntoKeeperWithoutClobbering() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let bytes = (0..<150_000).map { UInt8($0 % 241) }
        let keeperURL = dir.appendingPathComponent("Reel12.mov")
        let extraURL = dir.appendingPathComponent("Reel12 copy.mov")
        write(keeperURL, bytes)
        write(extraURL, bytes)

        let model = makeModel(dir)
        let group = UUID()
        let keeper = dupRecord(path: keeperURL.path, size: 150_000, group: group, disposition: .keep)
        let extra = dupRecord(path: extraURL.path, size: 150_000, group: group, disposition: .extraCopy)

        // Keeper's own judgments — must survive untouched.
        keeper.starRating = 1
        keeper.tags = ["Follow Up"]
        keeper.confirmedByUserPeople = [ConfirmedTag(name: "Rick", confirmedAt: Date())]
        keeper.rejectedPeople = ["donna"]           // lower-case on purpose
        keeper.userNotes = "keeper note"
        keeper.mediaDisposition = .important
        keeper.userDate = "1994-11"
        keeper.userDateConfidence = "known"

        // Extra's metadata — the part a delete would otherwise lose.
        extra.starRating = 3
        extra.tags = ["Gold", "follow up"]           // case-insensitive union
        extra.confirmedByUserPeople = [
            ConfirmedTag(name: "Donna", confirmedAt: Date()),   // keeper REJECTED Donna → must NOT transfer
            ConfirmedTag(name: "Timmy", confirmedAt: Date()),   // no keeper judgment → transfers
        ]
        extra.rejectedPeople = ["Rick", "Anna"]      // Rick confirmed on keeper → no; Anna → yes
        extra.userNotes = "extra note"
        extra.mediaDisposition = .confirmedJunk      // keeper reviewed → ignored
        extra.lifecycleStage = .archived             // keeper cataloged → adopts
        extra.archiveStage = .backedUp               // keeper .none → adopts
        extra.userDate = "1990-01"                   // keeper has one → ignored
        extra.userDateConfidence = "estimated"
        // Machine metadata on the extra — must NOT move.
        extra.videoCodec = "dvvideo"
        extra.audioVerifyStatus = "damaged"

        model.records = [keeper, extra]

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 1)
        #expect(!FileManager.default.fileExists(atPath: extraURL.path))
        #expect(FileManager.default.fileExists(atPath: keeperURL.path))
        #expect(model.records.count == 1 && model.records.first === keeper)

        // Union rules.
        #expect(keeper.starRating == 3, "star rating = max")
        #expect(keeper.tags == ["Follow Up", "Gold"], "tags union, case-insensitive: \(keeper.tags)")
        #expect(keeper.userNotes == "keeper note\nextra note", "notes append")
        #expect(keeper.confirmedByUserPeople.map(\.name) == ["Rick", "Timmy"],
                "Donna must not be confirmed — keeper had rejected her")
        #expect(keeper.rejectedPeople == ["donna", "Anna"],
                "Rick must not be rejected — keeper had confirmed him")
        #expect(keeper.mediaDisposition == .important, "keeper's review is not clobbered")
        #expect(keeper.lifecycleStage == .archived)
        #expect(keeper.archiveStage == .backedUp)
        #expect(keeper.userDate == "1994-11" && keeper.userDateConfidence == "known")
        // Machine metadata untouched.
        #expect(keeper.videoCodec.isEmpty)
        #expect(keeper.audioVerifyStatus != "damaged")
    }

    /// A refused (non-identical) extra carries NOTHING — the merge is
    /// gated on the byte-verify passing, exactly like the delete.
    @Test func refusedDeleteCarriesNothing() async throws {
        let dir = tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let keeperURL = dir.appendingPathComponent("a.mov")
        let extraURL = dir.appendingPathComponent("b.mov")
        write(keeperURL, [UInt8](repeating: 1, count: 5_000))
        write(extraURL, [UInt8](repeating: 2, count: 5_000))

        let model = makeModel(dir)
        let group = UUID()
        let keeper = dupRecord(path: keeperURL.path, size: 5_000, group: group, disposition: .keep)
        let extra = dupRecord(path: extraURL.path, size: 5_000, group: group, disposition: .extraCopy)
        extra.starRating = 3
        extra.userNotes = "not a duplicate at all"
        model.records = [keeper, extra]

        let result = await model.deleteDuplicates(onVolume: dir.path)

        #expect(result.deleted == 0)
        #expect(keeper.starRating == 0)
        #expect(keeper.userNotes.isEmpty)
        #expect(FileManager.default.fileExists(atPath: extraURL.path))
    }

    /// The shared merge reports what it carried (that is what the delete
    /// path logs), and reports nothing when the extra was bare.
    @Test func inheritanceReportsCarriedFields() {
        let model = VideoScanModel()
        let keeper = VideoRecord(); let extra = VideoRecord()
        #expect(model.applyHumanMetadataInheritance(from: extra, to: keeper).isEmpty)

        extra.starRating = 2
        extra.tags = ["Gold"]
        extra.confirmedByUserPeople = [ConfirmedTag(name: "Donna", confirmedAt: Date())]
        let carried = model.applyHumanMetadataInheritance(from: extra, to: keeper)
        #expect(Set(carried) == ["star rating", "tags", "confirmed people"], "\(carried)")

        // Idempotent: a second pass has nothing new to carry.
        #expect(model.applyHumanMetadataInheritance(from: extra, to: keeper).isEmpty)
    }

    /// Source-level sensor: the delete loop routes through the ONE shared
    /// merge (no second copy of the rules that could drift).
    @Test func deletePathRoutesThroughSharedInheritance() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VideoScan/VideoScanModel+Duplicates.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        #expect(source.contains("applyHumanMetadataInheritance(from:"),
                "deleteDuplicates no longer carries human metadata onto the keeper")
    }
}
