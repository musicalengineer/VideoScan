import Foundation
@testable import VideoScan

// Shared fixtures for the codex review of GH #201 (docs/reviews/codex/codex-review-dates-2026-09-26.md,
// F1–F4). Scratch catalog stores only; the real catalog and People store are never read.

enum DateReviewFixtures {

    static func utc(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 12) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        var dc = DateComponents()
        dc.year = y; dc.month = mo; dc.day = d; dc.hour = h
        return cal.date(from: dc) ?? .distantPast
    }

    static let now = utc(2026, 9, 26)

    @MainActor
    static func model(_ label: String) -> VideoScanModel {
        let model = VideoScanModel()
        model.catalogStore = CatalogStore(directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("DateReview-\(label)-\(UUID().uuidString)", isDirectory: true))
        model.dateInferencePeople = []
        return model
    }

    /// Two members of one footage group; names carry no year.
    @MainActor
    static func pair(confidence: FootageConfidence = .likely) -> (a: VideoRecord, b: VideoRecord) {
        let group = UUID()
        func make(_ dir: String, rank: Int, original: UUID?) -> VideoRecord {
            let r = VideoRecord()
            r.fullPath = "/Volumes/\(dir)/clip.mov"; r.filename = "clip.mov"; r.directory = "/Volumes/\(dir)"
            r.streamTypeRaw = StreamType.videoAndAudio.rawValue
            r.footage = FootageMembership(groupID: group, groupSize: 2, confidence: confidence,
                                          role: rank == 0 ? .original : .copy, rank: rank,
                                          likelyOriginalID: original ?? r.id, originalInCatalog: true,
                                          evidence: ["same name + length"], scannedAt: now, algorithmVersion: 1)
            return r
        }
        let a = make("A", rank: 0, original: nil)
        let b = make("B", rank: 1, original: a.id)
        return (a, b)
    }

    static func resolve(_ r: VideoRecord) -> RecordDateResolution {
        RecordDateResolver.resolve(userDate: r.userDate, userDateConfidence: r.userDateConfidence,
                                   embeddedCreationDate: r.embeddedCreationDate,
                                   originMake: r.originMake, originModel: r.originModel, originEncoder: r.originEncoder,
                                   inferredRecordDate: r.inferredRecordDate, inferredDateConfidence: r.inferredDateConfidence,
                                   inferredDateRange: r.inferredDateRange,
                                   filename: r.filename.isEmpty ? nil : r.filename, now: now)
    }

    /// Every inferred field, for write-free assertions.
    struct InferredSnapshot: Equatable {
        var date: Date?, confidence: Float?, range: InferredDateRange?, source: String?, reason: String?
        init(_ r: VideoRecord) {
            date = r.inferredRecordDate; confidence = r.inferredDateConfidence
            range = r.inferredDateRange; source = r.inferredDateSource; reason = r.inferredDateReason
        }
    }
}
