// ArchiveAngelCandidate+Record.swift
// VideoRecord → ArchiveAngelCandidate projection (main actor; the record
// lives there) plus the pure name/date helpers the plan entries use.
// Play history is NOT read here — the job fills it off-main for the
// eligible records only (design §3.3).

import Foundation
import VideoScanCore

extension ArchiveAngelCandidate {

    /// Snapshot one record. `facts` = the scan-target facts for its
    /// volume (nil when the path is under no scan target); `readiness`
    /// = ArchiveReadiness.assess(record:); `archivedCopyExists` = the
    /// model already holds an archive copy of this content (or the
    /// record IS an archive copy).
    @MainActor
    init(record r: VideoRecord,
         facts: DuplicateKeeperPolicy.VolumeFacts?,
         readiness: ArchiveReadiness,
         archivedCopyExists: Bool,
         isOnMasterArchive: Bool,
         volumeName: String,
         volumeOnline: Bool) {
        var formatAtRisk = false
        if case .atRisk = readiness.format { formatAtRisk = true }
        var audioProblem: String?
        if case .verifiedProblem(let s) = readiness.audio { audioProblem = s }

        self.init(
            id: r.id,
            filename: r.filename,
            fullPath: r.fullPath,
            sizeBytes: r.sizeBytes,
            durationSeconds: r.durationSeconds,
            streamTypeRaw: r.streamTypeRaw,
            isPlayable: r.isPlayable,
            starRating: r.starRating,
            mediaDisposition: r.mediaDisposition,
            archiveStage: r.archiveStage,
            junkScore: r.junkScore,
            confirmedPeople: r.confirmedByUserPeople.map(\.name),
            detectedPeople: r.detectedPeople,
            suspectedPeople: r.suspectedPeople,
            hasUserNotes: Self.hasHumanNote(r.userNotes),
            tagCount: r.tags.count,
            hasCaptions: !r.sceneCaptions.isEmpty,
            hasOCRText: !r.ocrText.isEmpty,
            hasEmbeddedDate: r.embeddedCreationDate != nil,
            hasTapeOrClipName: !r.tapeName.isEmpty || !r.avidClipName.isEmpty,
            userDate: r.userDate,
            inferredRecordDate: r.inferredRecordDate,
            inferredDateConfidence: r.inferredDateConfidence,
            formatAtRisk: formatAtRisk,
            audioProblem: audioProblem,
            isPairedHalf: r.pairedWith != nil || r.pairGroupID != nil,
            hasArchivedDuplicate: archivedCopyExists,
            isOnlyCopy: r.duplicateGroupID == nil,
            volumeRole: facts?.role ?? .unassigned,
            volumeName: volumeName,
            volumeOnline: volumeOnline,
            isOnMasterArchive: isOnMasterArchive,
            useCount: 0,
            lastUsed: nil,
            videoCodec: r.videoCodec,
            duplicateGroupID: r.duplicateGroupID)
    }

    /// The projection the job uses: keeper policy built ONCE by the
    /// caller (it snapshots every scan target), readiness computed here.
    @MainActor
    static func project(_ r: VideoRecord,
                        model: VideoScanModel,
                        policy: DuplicateKeeperPolicy) -> ArchiveAngelCandidate {
        let facts = policy.facts(forPath: r.fullPath)
        let readiness = ArchiveReadiness.assess(record: r)
        let archived = model.isArchiveCopy(r) || model.archivedCopy(of: r) != nil
        let onMaster = facts?.isMasterArchive == true || model.isInsideMasterArchive(path: r.fullPath)
        let name = r.volumeName.isEmpty ? VolumeReachability.displayLabel(forPath: r.fullPath) : r.volumeName
        // A scan-target fact answers reachability without touching the
        // disk; only pathless strays pay for a stat.
        let online = facts?.isReachable ?? VolumeReachability.isReachable(path: r.fullPath)
        return ArchiveAngelCandidate(record: r, facts: facts, readiness: readiness,
                                     archivedCopyExists: archived, isOnMasterArchive: onMaster,
                                     volumeName: name, volumeOnline: online)
    }
}

// MARK: - Human vs machine notes (pure)

extension ArchiveAngelCandidate {
    /// T10 H1 (night of 2026-09-10): 9,977 of 13,842 records carry text in
    /// `userNotes` that no person typed — ffprobe/ffmpeg stderr ("Unsupported
    /// codec with id…", "[aac @ 0x…] …", "Last message repeated…"), the
    /// Find-and-Tag recipe ("FindPerson(Donna) recipe-v1-native …: score …"),
    /// Promote's "copy at /Volumes/…" line. About ten records hold a real
    /// note ("Mark's first birthday, …"). Only those are a HUMAN mark: they
    /// earn the richness point and exempt a file from the machine floors.
    /// Exact writer signatures seen in the live catalog census (2026-09-10),
    /// nothing broader: "[1984] Dad and Donna at Thanksgiving" is a human
    /// note and must stay one (codex #1303). ffmpeg/ffprobe log lines are
    /// matched by their `[<component> @ 0x<address>]` header, not by a
    /// leading bracket.
    nonisolated static let machineNotePrefixes: [String] = [
        "unsupported codec with", "could not open codec", "file could not be analy",
        "consider increasing the", "last message repeated", "file is corrupt or inc",
        "file contains invalid", "invalid data found when", "moov atom not found",
        "findperson(", "copy at /", "promote 20",
    ]
    nonisolated static let ffmpegLogHeader = #"^\[[a-z0-9_,]+ @ 0x[0-9a-f]+\]"#

    nonisolated static func isMachineNoteLine(_ line: String) -> Bool {
        let key = line.lowercased()
        if machineNotePrefixes.contains(where: { key.hasPrefix($0) }) { return true }
        return key.range(of: ffmpegLogHeader, options: .regularExpression) != nil
    }

    /// Lines of `notes` a person could have written. Pure; table-tested.
    nonisolated static func humanNoteLines(_ notes: String) -> [String] {
        notes.split(whereSeparator: { $0.isNewline }).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !isMachineNoteLine($0) }
    }

    nonisolated static func hasHumanNote(_ notes: String) -> Bool { !humanNoteLines(notes).isEmpty }
}

// MARK: - Plan-entry helpers (pure)

enum ArchiveAngelNaming {

    /// "1992-07-xx" → "1992-07"; "1992-xx-xx" → "1992"; "xxxx-xx-xx" → nil;
    /// "1992-07-15" → "1992-07-15".
    nonisolated static func proposedDate(fromFilenamePrefix prefix: String) -> String? {
        var parts = prefix.split(separator: "-").map(String.init)
        while let last = parts.last, last.allSatisfy({ $0 == "x" }) { parts.removeLast() }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: "-")
    }

    /// The archive filename the existing Promote naming rule would give
    /// this record today, with the advisor's title when the stem is a
    /// camera counter. Pure over the facts.
    nonisolated static func proposedName(facts: ArchivePathResolver.RecordFacts,
                                         people: [String], tags: [String]) -> String {
        let stem = (facts.filename as NSString).deletingPathExtension
        let title = ArchiveNameAdvisor.isGenericStem(stem)
            ? ArchiveNameAdvisor.suggestedTitle(people: people, tags: tags)
            : nil
        return (ArchivePathResolver.baseRelativePath(facts: facts, title: title) as NSString).lastPathComponent
    }
}
