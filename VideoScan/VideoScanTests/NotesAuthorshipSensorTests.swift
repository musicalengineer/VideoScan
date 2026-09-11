// NotesAuthorshipSensorTests.swift
// GH #176 sensor — machine text must never land in `userNotes` again.
//
// Pure source scan (no build products, no model): reads the app and Core
// sources relative to #filePath and lists every site that ASSIGNS
// `userNotes` (`userNotes =`, `userNotes +=`, `.userNotes.append(`). Each
// writer file must be on the allow-list of human entry points / field
// copies below. A new writer anywhere else fails this test until a
// person has decided whether it is Rick's text (userNotes) or a
// machine's (notes, via MachineNote.line).
//
// A second, lighter sensor does the same for `.notes` writers: the list
// is long (every MFO job stamps its journey), so it is file-level only —
// a NEW file writing notes must be registered here, which is the moment
// to sign its lines.

import Foundation
import Testing
@testable import VideoScan

@Suite("Notes authorship sensor (GH #176)")
struct NotesAuthorshipSensorTests {

    /// Files allowed to assign `userNotes`, with the reason each is human
    /// (or a verbatim copy of an existing human note).
    static let userNotesWriters: [String: String] = [
        "VideoScanModel+WorkflowTags.swift":      "Notes… sheet (setUserNotes) + the 2026-07 notes→userNotes split",
        "VideoScanModel+NotesRepair.swift":       "GH #176 repair: writes back the HUMAN remainder only",
        "ArchiveAngelReviewSheet.swift":          "Angel review sheet: the note Rick types on a plan entry",
        "VideoScanModel+RepairLifecycle.swift":   "repair confirm carries the original's note; undo restores the snapshot",
        "VideoScanModel+MasterArchive.swift":     "Promote: the archive copy carries the source's note verbatim",
        "VideoScanModel+RescanPreservation.swift": "rescan preservation restores the pre-scan note verbatim",
        "VideoRecord+Clone.swift":                "clone copies the field",
        "VideoRecord.swift":                      "Codable decode",
        "VideoRecordDTO.swift":                   "export DTO init copies the field",
        "ArchivistPresenceExecutor.swift":        "read-only projection struct init",
        "MachineNote.swift":                      "NotesRepair.Change value init — the rule that separates the two fields",
    ]

    /// Files allowed to assign `.notes` (any type — ScanTarget / Person /
    /// CyberBrain `notes` fields are included so the scan stays simple).
    static let notesWriters: Set<String> = [
        "BalanceAudioJob.swift", "BundleImporter.swift", "BundleModels.swift", "CleanupJob.swift",
        "CyberBrainModels.swift", "DocumentIngest.swift", "HoldoutReviewQueue.swift", "MachineNote.swift", "MetadataCache.swift",
        "PersonEditSheet.swift", "PersonFinderTypes.swift", "RebuildAudioJob.swift", "ReformatJob.swift",
        "ScanEngine.swift", "ScanTargetPersistence.swift", "TranscodeJob.swift", "TrimJob.swift",
        "VideoRecord+Clone.swift", "VideoScanModel+Combine.swift", "VideoScanModel+DuplicateEnrichment.swift",
        "VideoScanModel+MasterArchive.swift", "VideoScanModel+NotesRepair.swift", "VideoScanModel+PeopleTags.swift",
        "VideoScanModel+ProbeEngine.swift", "VideoScanModel+Relocate.swift", "VideoScanModel+RepairLifecycle.swift",
        "VideoScanModel+RescanPreservation.swift", "VideoScanModel+ScanMergeMoveIdentity.swift",
        "VideoScanModel+ScanTargetPersistence.swift", "VideoScanModel+WorkflowTags.swift",
    ]

    struct Hit: CustomStringConvertible {
        let file: String; let line: Int; let text: String
        var description: String { "\(file):\(line): \(text)" }
    }

    /// `<repo>/VideoScan` — the directory holding the app target, Core
    /// package and this test target.
    static var projectRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    static func sourceFiles() throws -> [URL] {
        let roots = [projectRoot.appendingPathComponent("VideoScan", isDirectory: true),
                     projectRoot.appendingPathComponent("VideoScanCore/Sources", isDirectory: true)]
        var out: [URL] = []
        for root in roots {
            guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { continue }
            for case let url as URL in e where url.pathExtension == "swift" { out.append(url) }
        }
        try #require(out.count > 100, "source scan found only \(out.count) files under \(projectRoot.path)")
        return out
    }

    static func scan(pattern: String) throws -> [Hit] {
        let rx = try NSRegularExpression(pattern: pattern)
        var hits: [Hit] = []
        for url in try sourceFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (i, raw) in text.components(separatedBy: "\n").enumerated() {
                // Drop line comments (doc comments talk about `userNotes =` freely).
                let code = raw.components(separatedBy: "//").first ?? raw
                if rx.firstMatch(in: code, range: NSRange(code.startIndex..., in: code)) != nil {
                    hits.append(Hit(file: url.lastPathComponent, line: i + 1, text: raw.trimmingCharacters(in: .whitespaces)))
                }
            }
        }
        return hits
    }

    @Test("every `userNotes` writer is a registered human entry point")
    func userNotesWritersAreRegistered() throws {
        let hits = try Self.scan(pattern: #"\buserNotes\s*(=|\+=)(?!=)|\.userNotes\.append\("#)
        #expect(!hits.isEmpty, "the scan must at least find setUserNotes")
        let unregistered = hits.filter { Self.userNotesWriters[$0.file] == nil }
        #expect(unregistered.isEmpty, """
            Unregistered userNotes writer(s). If a MACHINE wrote this text, write it to `notes` via \
            MachineNote.line(author:text:) instead; if a person did, add the file to \
            NotesAuthorshipSensorTests.userNotesWriters with the reason.
            \(unregistered.map(\.description).joined(separator: "\n"))
            """)
        // The allow-list must not rot: every entry still writes.
        let writing = Set(hits.map(\.file))
        for file in Self.userNotesWriters.keys {
            #expect(writing.contains(file), "\(file) no longer assigns userNotes — remove it from the allow-list")
        }
    }

    @Test("every `.notes` writer file is registered (new writers must sign their lines)")
    func notesWriterFilesAreRegistered() throws {
        let hits = try Self.scan(pattern: #"\.notes\s*(=|\+=)(?!=)"#)
        let writing = Set(hits.map(\.file))
        let unregistered = writing.subtracting(Self.notesWriters).sorted()
        #expect(unregistered.isEmpty, """
            New `.notes` writer file(s): \(unregistered). Sign machine lines with \
            MachineNote.line(author:text:) (or a File Journey stamp) and register the file in \
            NotesAuthorshipSensorTests.notesWriters.
            """)
        let stale = Self.notesWriters.subtracting(writing).sorted()
        #expect(stale.isEmpty, "allow-listed files no longer write .notes: \(stale)")
    }

    @Test("the writers this fix signed stay signed")
    func signedWritersStaySigned() throws {
        // The exact unsigned assignments GH #176 removed must not come back.
        let regressions = try Self.scan(pattern: #"o\.notes\s*=\s*stderrTrimmed\b|rec\.notes\s*=\s*"Added as a document"|let line = "FindPerson\("#)
        #expect(regressions.isEmpty, "\(regressions)")
    }
}
