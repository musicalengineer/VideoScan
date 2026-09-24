// ArchiveAngelRowFacts+Record.swift
// The ONE place a live catalog record + the Angel's stored evidence become
// the value snapshot the list row and the Archive Readiness sheet read
// (ArchiveAngelListRowModel.swift). Main actor (it reads the record), O(1)
// per call: one ArchiveReadiness.assess, one date resolve, a cached
// reachability lookup. Called for the ~10 visible rows when the list is
// rebuilt and once when "Archive Readiness" is pressed — never in a body.

import Foundation
import VideoScanCore

extension ArchiveAngelRowFacts {

    /// `kind` is the EFFECTIVE class (ArchiveAngel.recommendationClass).
    @MainActor
    static func make(record r: VideoRecord, evidence ev: ArchiveAngelEvidenceRecord?,
                     kind: ArchiveAngelRecommendationClass) -> ArchiveAngelRowFacts {
        let readiness = ArchiveReadiness.assess(record: r)
        var f = ArchiveAngelRowFacts(id: r.id, filename: r.filename, fullPath: r.fullPath, kind: kind)
        f.ext = r.ext
        f.videoCodec = r.videoCodec
        f.audioCodec = r.audioCodec
        f.durationSeconds = r.durationSeconds
        f.audio = readiness.audio
        f.audioVerifyStatus = r.audioVerifyStatus
        f.audioVerifyNote = r.audioVerifyNote
        f.date = readiness.date
        f.dateLabel = dateLabel(r)
        f.videoVerifyStatus = r.videoVerifyStatus
        f.videoVerifyNote = r.videoVerifyNote
        if let ev {
            f.evidenceLines = ev.lines.map(\.line)
            f.reasons = ev.reasons ?? []
            f.score = ev.score
            f.copies = ev.copies ?? 1
        }
        f.duplicateCount = r.duplicateGroupCount
        let confirmed = r.confirmedByUserPeople.map(\.name)
        f.confirmedPeople = confirmed
        var seen = Set(confirmed)
        f.otherPeople = (r.detectedPeople + r.suspectedPeople).filter { seen.insert($0).inserted }
        f.volumeName = VolumeReachability.volumeName(forPath: r.fullPath)
        f.isReachable = VolumeReachability.isReachable(path: r.fullPath)
        return f
    }

    /// "12 Jul 1994" / "July 1994" / "1994" from the SAME resolver Promote
    /// places by (RecordDateResolver); nil when nothing dates it.
    static func dateLabel(_ r: VideoRecord) -> String? {
        let res = RecordDateResolver.resolve(userDate: r.userDate,
                                             userDateConfidence: r.userDateConfidence,
                                             embeddedCreationDate: r.embeddedCreationDate,
                                             originMake: r.originMake,
                                             originModel: r.originModel,
                                             originEncoder: r.originEncoder,
                                             inferredRecordDate: r.inferredRecordDate,
                                             inferredDateConfidence: r.inferredDateConfidence,
                                             filename: r.filename)
        guard res.precision != .unknown else { return nil }
        return UserDateEntry.friendlyDisplay(res.isoString)
    }
}
