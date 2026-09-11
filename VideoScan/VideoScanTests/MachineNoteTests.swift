// MachineNoteTests.swift
// GH #176 — authored machine notes. Pure tables: author recognition for
// every legacy unsigned shape + the signed shape, the nine human lines
// from the live catalog census (2026-09-11), the writer helper, and the
// per-record repair rule. No model, no disk, no defaults.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("MachineNote — author recognition")
struct MachineNoteAuthorTests {

    /// Every line a machine has written into a note field, with the
    /// author a reader must attribute it to. Legacy (unsigned) shapes
    /// come from the census; the signed shapes are what the writers
    /// produce now.
    static let machineLines: [(String, String)] = [
        // ffprobe stderr — census 2026-09-11 (leading spaces included)
        ("Unsupported codec with id 98314 for input stream 0", "ffprobe"),
        ("    Last message repeated 2 times", "ffprobe"),
        ("Last message repeated 113 times", "ffprobe"),
        ("Could not open codec for input stream 1", "ffprobe"),
        ("Consider increasing the value of the 'analyzeduration' (0) and 'probesize' (5000000) options", "ffprobe"),
        ("Invalid data found when processing input", "ffprobe"),
        ("[aac @ 0x7ac800a80] This stream seems to use a channel layout", "ffprobe"),
        ("[mov,mp4,m4a,3gp,3g2,mj2 @ 0x7e3018000] moov atom not found", "ffprobe"),
        ("[NULL @ 0x600002a0c000] Unable to find a suitable output format", "ffprobe"),
        ("[in#0/mov,mp4,m4a,3gp,3g2,mj2 @ 0x13be05a70] Error opening input", "ffprobe"),
        // ScanEngine.humanReadableDiagnosis / probe engine / ingest
        ("File could not be analyzed — no additional details available", "scan"),
        ("File could not be analyzed: moov atom not found", "scan"),
        ("File is corrupt or incomplete — missing media index (moov atom not found)", "scan"),
        ("File contains invalid or unreadable data (invalid data found when processing input)", "scan"),
        ("File appears to be cut short or incomplete (unexpected end of file)", "scan"),
        ("Cannot read file — permission denied", "scan"),
        ("File read timed out — network volume may be slow or unreachable", "scan"),
        ("File was discovered during scan but is no longer accessible", "scan"),
        ("Probe cancelled before acquiring a concurrency permit", "scan"),
        ("File probe exceeded 60s — network I/O may be stalled", "scan"),
        ("Content sniff found no media container signature in the file header — ffprobe skipped", "scan"),
        ("Neither ffprobe nor MXF header parser could read this file", "scan"),
        ("Damaged MXF — both ffprobe and header parser failed (Invalid data found)", "scan"),
        ("MXF header parsed (ffprobe failed: Invalid data found when processing input)", "scan"),
        ("Added as a document", "scan"),
        // Combine / recipe / cleanup
        ("Combined: video V1993-06-14.mxf + audio A1993-06-14.mxf", "combine"),
        ("FindPerson(Donna) recipe-v1-native 2026-08-27T22:30:19Z: score 0.612 → Donna?", "recipe"),
        ("copy at /Volumes/CrucialX9/reel.mov (from /Volumes/OldBook/reel.mov) removed 2026-08-18; identical bytes", "cleanup"),
        // File Journey stamps (verb + ISO8601) — text unchanged by #176
        ("Transcode 2026-07-01T18:00:12Z: Created archival derivative Clip 05_hevc.mov", "ffmpeg"),
        ("Balance Audio 2026-07-18T14:22:05Z: Created balanced copy Clip 07_balanced.mov", "ffmpeg"),
        ("Cleanup 2026-07-08T09:15:44Z: Created cleaned copy Tape12_clean.mov", "ffmpeg"),
        ("Reformat 2026-06-14T20:03:31Z: Reformatted to HEVC as Thanksgiving-Raw_hevc.mov", "ffmpeg"),
        ("Trim 2026-07-16T11:40:00Z: Trimmed from Tape03.mov (kept 0:12–1:03:45)", "ffmpeg"),
        ("Verify Audio 2026-08-01T10:00:00Z: repaired copy linked: x.mov", "ffmpeg"),
        ("Reconcile 2026-06-20T15:00:00Z: source file not found", "scan"),
        ("Migrate 2026-06-20T15:01:10Z: salvage recovered — re-copied and verified", "scan"),
        ("Confirm 2026-08-20T12:00:00Z: repair confirmed by Rick — replaces a.mov", "scan"),
        ("Promote 2026-09-09T17:20:11Z: promoted to Master Archive as BreenFamilyArchive/1990s/x.mov", "promote"),
        ("Promote 2026-09-09T17:20:11Z → BreenFamilyArchive/1990s/…", "promote"),
        // Signed shapes (what every writer produces after #176)
        ("ffprobe: Unsupported codec with id 98314 for input stream 0", "ffprobe"),
        ("ffmpeg: concat demuxer joined 3 parts", "ffmpeg"),
        ("scan: File probe exceeded 60s — network I/O may be stalled", "scan"),
        ("combine: video V1993-06-14.mxf + audio A1993-06-14.mxf", "combine"),
        ("recipe: FindPerson(Donna) recipe-v1-native 2026-08-27T22:30:19Z: score 0.612 → Donna?", "recipe"),
        ("promote: verified copy", "promote"),
        ("cleanup: copy at /Volumes/X/a.mov removed 2026-08-18; identical bytes", "cleanup"),
        ("angel: proposed for the 1990s batch", "angel"),
    ]

    /// The nine human lines in the live catalog (census 2026-09-11) plus
    /// the bracketed one codex #1303 ruled on and a few that merely use a
    /// machine's words. All must read as HUMAN (author == nil).
    static let humanLines: [String] = [
        "Donna and Libby on Porch",
        "Mark’s first birthday, Nov 1984, nice videos of Donna. Thanksgiving in Brockton larger Breen family.",
        "Sue, Barry, Ellen, Paul, Beth, Tim, and lots of kids.",
        "Dan’s Kindergarten, Franklin Backyard, Rick Dancing to songs with kids, etc.",
        "Video of Rick and kids at Dad Breen’s house circa 1985",
        "m2v DVD-authoring intermediate format from Dec 2009 me or Avid DVD export encoded JustPatsHouse.mov for a DVD",
        "The better news: the true master is intact one folder up — /…/Avid Users/JustPatsHouse.mov,",
        "this is a test abcdefgh",
        "[1984] Dad and Donna at Thanksgiving",
        "[cape] the whole tape, promote this one",
        "Transcoded this myself in 2019",
        "Trim this one later",
        "Migrate 1999 photos into this folder?",
        "Combined the two tapes by hand",
        "Scan: the porch, then the yard",          // capitalized — not the signed prefix
        "ffprobe says it is fine, I disagree",     // no colon+space after the author word
        "copy at Dad's house is the better one",   // no path
        "Archive Angel picked this — I agree",
    ]

    @Test("every machine shape is attributed to its author",
          arguments: machineLines)
    func machine(line: String, author: String) {
        #expect(MachineNote.author(of: line) == author, "\(line)")
        #expect(MachineNote.isMachineLine(line))
    }

    @Test("every human line stays human", arguments: humanLines)
    func human(line: String) {
        #expect(MachineNote.author(of: line) == nil, "\(line)")
        #expect(!MachineNote.isMachineLine(line))
    }

    @Test func emptyAndWhitespaceAreNotMachine() {
        #expect(MachineNote.author(of: "") == nil)
        #expect(MachineNote.author(of: "   ") == nil)
    }

    @Test func vocabularyIsFixed() {
        #expect(MachineNote.Author.allCases.map(\.rawValue) ==
                ["ffprobe", "ffmpeg", "scan", "combine", "recipe", "promote", "cleanup", "angel"])
    }

    // MARK: The legacy split no longer pumps machine text into userNotes

    @Test("UserNotesMigration keeps every legacy machine line in notes (the #176 pump is closed)",
          arguments: machineLines.map(\.0))
    func legacySplitKeepsMachineLines(line: String) {
        #expect(UserNotesMigration.migrate(notes: line, userNotes: "") == nil, "\(line)")
    }

    @Test func angelReaderAgreesWithTheClassifier() {
        for (line, _) in Self.machineLines {
            #expect(!ArchiveAngelCandidate.hasHumanNote(line), "\(line)")
        }
        for line in Self.humanLines {
            #expect(ArchiveAngelCandidate.hasHumanNote(line), "\(line)")
        }
    }
}

@Suite("MachineNote — writing")
struct MachineNoteWriterTests {

    @Test func singleLineIsSigned() {
        #expect(MachineNote.line(author: .scan, text: "Added as a document") == "scan: Added as a document")
    }

    @Test func multiLineStderrSignsEveryLineAndDropsBlanks() {
        let stderr = "[aac @ 0x1] channel layout guessed\n    Last message repeated 2 times\n\nUnsupported codec with id 98314 for input stream 0\n"
        let signed = MachineNote.line(author: .ffprobe, text: stderr)
        #expect(signed == "ffprobe: [aac @ 0x1] channel layout guessed\nffprobe: Last message repeated 2 times\nffprobe: Unsupported codec with id 98314 for input stream 0")
        for l in signed.split(separator: "\n") { #expect(MachineNote.author(of: l) == "ffprobe") }
    }

    @Test func appendJoinsWithNewlineAndIgnoresEmpty() {
        #expect(MachineNote.append("scan: a", to: "") == "scan: a")
        #expect(MachineNote.append("scan: b", to: "scan: a") == "scan: a\nscan: b")
        #expect(MachineNote.append("", to: "scan: a") == "scan: a")
    }

    @Test func signedPrefixesLegacyLinesOnceAndLeavesSelfDescribingText() {
        #expect(MachineNote.signed("Unsupported codec with id 1") == "ffprobe: Unsupported codec with id 1")
        #expect(MachineNote.signed("    Last message repeated 2 times") == "ffprobe: Last message repeated 2 times")
        #expect(MachineNote.signed("FindPerson(Donna) recipe-v1-native 2026-08-27T22:30:19Z: score 0.6 → Donna?")
                == "recipe: FindPerson(Donna) recipe-v1-native 2026-08-27T22:30:19Z: score 0.6 → Donna?")
        // Already signed → identity (the migration's idempotence rests on this).
        #expect(MachineNote.signed("ffprobe: Unsupported codec with id 1") == "ffprobe: Unsupported codec with id 1")
        // Journey stamps / Combined / MXF fallback name their author already — text unchanged.
        let stamp = "Promote 2026-09-09T17:20:11Z: promoted to Master Archive as x.mov"
        #expect(MachineNote.signed(stamp) == stamp)
        #expect(MachineNote.signed("Combined: a + b") == "Combined: a + b")
        #expect(MachineNote.signed("MXF header parsed (ffprobe failed: x)") == "MXF header parsed (ffprobe failed: x)")
        // Human → nil
        #expect(MachineNote.signed("Donna and Libby on Porch") == nil)
    }
}

@Suite("NotesRepair — per-record rule")
struct NotesRepairRuleTests {

    @Test func allMachineRecordEmptiesUserNotes() {
        let c = NotesRepair.apply(notes: "[aac @ 0x1] x",
                                  userNotes: "Unsupported codec with id 1\n    Last message repeated 2 times")
        #expect(c == NotesRepair.Change(
            notes: "[aac @ 0x1] x\nffprobe: Unsupported codec with id 1\nffprobe: Last message repeated 2 times",
            userNotes: "", movedLines: 2))
    }

    @Test func mixedRecordKeepsHumanLinesInOrder() {
        let c = NotesRepair.apply(notes: "",
                                  userNotes: "Unsupported codec with id 1\nDonna and Libby on Porch\n\nsecond thought\nFindPerson(Donna) recipe-v1-native 2026-08-27T22:30:19Z: score 0.6 → Donna?")
        #expect(c?.userNotes == "Donna and Libby on Porch\n\nsecond thought")
        #expect(c?.notes == "ffprobe: Unsupported codec with id 1\nrecipe: FindPerson(Donna) recipe-v1-native 2026-08-27T22:30:19Z: score 0.6 → Donna?")
        #expect(c?.movedLines == 2)
    }

    @Test func humanOnlyAndEmptyAreUntouched() {
        #expect(NotesRepair.apply(notes: "[aac @ 0x1] x", userNotes: "Mark’s first birthday, Nov 1984") == nil)
        #expect(NotesRepair.apply(notes: "", userNotes: "") == nil)
        #expect(NotesRepair.apply(notes: "scan: x", userNotes: "") == nil)
    }

    @Test func alreadyPresentLineIsNotDuplicated() {
        let c = NotesRepair.apply(notes: "ffprobe: Unsupported codec with id 1",
                                  userNotes: "Unsupported codec with id 1")
        #expect(c?.notes == "ffprobe: Unsupported codec with id 1")
        #expect(c?.userNotes.isEmpty == true)
    }

    @Test func idempotent() {
        let first = NotesRepair.apply(notes: "", userNotes: "Unsupported codec with id 1\nDonna and Libby on Porch")
        let again = NotesRepair.apply(notes: first!.notes, userNotes: first!.userNotes)  // swiftlint:disable:this force_unwrapping
        #expect(again == nil)
    }
}
