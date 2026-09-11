// ArchiveAngelScorerTests.swift
// Archive Angel Stage 1 — LOGIC (floor reasons, evidence lines, ordering,
// caps, batch cut) + SCALE (100k candidates under a time budget). Pure
// core: no model, no disk, no defaults — ISOLATION is by construction.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

@Suite("Archive Angel scorer — hard floor")
struct ArchiveAngelFloorTests {

    @Test("a plain unarchived video is eligible")
    func plainEligible() {
        guard case .eligible = ArchiveAngelScorer.verdict(.init()) else {
            Issue.record("default candidate must be eligible"); return
        }
    }

    @Test("floor reasons", arguments: [
        (ArchiveAngelCandidate(streamTypeRaw: StreamType.audioOnly.rawValue), ArchiveAngelRejection.notVideo),
        (ArchiveAngelCandidate(archiveStage: .masterAssigned), .alreadyArchived),
        (ArchiveAngelCandidate(isOnMasterArchive: true), .alreadyArchived),
        (ArchiveAngelCandidate(hasArchivedDuplicate: true), .duplicateArchived),
        (ArchiveAngelCandidate(isPlayable: "No"), .notPlayable),
        (ArchiveAngelCandidate(isPlayable: "Codec unsupported"), .notPlayable),
        (ArchiveAngelCandidate(isPairedHalf: true), .pairedHalf),
        (ArchiveAngelCandidate(durationSeconds: 3), .tooShort),
        (ArchiveAngelCandidate(mediaDisposition: .confirmedJunk), .junk),
        (ArchiveAngelCandidate(mediaDisposition: .suspectedJunk), .suspectedJunk),
        (ArchiveAngelCandidate(junkScore: 5), .suspectedJunk),
        (ArchiveAngelCandidate(volumeOnline: false), .volumeOffline),
    ])
    func floor(candidate: ArchiveAngelCandidate, reason: ArchiveAngelRejection) {
        #expect(ArchiveAngelScorer.verdict(candidate) == .rejected(reason))
    }

    @Test("a star overrides machine junk evidence, never a human junk decision")
    func starsVersusJunk() {
        guard case .eligible = ArchiveAngelScorer.verdict(.init(starRating: 2, junkScore: 9)) else {
            Issue.record("rated file with high junkScore must stay eligible"); return
        }
        guard case .eligible = ArchiveAngelScorer.verdict(.init(starRating: 1, mediaDisposition: .suspectedJunk)) else {
            Issue.record("rated file suspected junk by machine must stay eligible"); return
        }
        #expect(ArchiveAngelScorer.verdict(.init(starRating: 3, mediaDisposition: .confirmedJunk)) == .rejected(.junk))
    }

    @Test("under one minute is out for everyone — a star, a person, a note or a date no longer lowers the floor")
    func minuteFloorForAll() {
        // Rick 2026-09-10: "usually there's a longer video of the whole
        // scene … a 60 s or less clip is just a small edit I made to send
        // to someone" — the long original is the archive candidate.
        #expect(ArchiveAngelScorer.verdict(.init(durationSeconds: 40)) == .rejected(.tooShort))
        #expect(ArchiveAngelScorer.verdict(.init(durationSeconds: 35, starRating: 3, confirmedPeople: ["Donna"])) == .rejected(.tooShort),
                "a starred 35 s Cape edit — the whole-tape original is what we want")
        for marked in [ArchiveAngelCandidate(durationSeconds: 59.9, starRating: 1),
                       ArchiveAngelCandidate(durationSeconds: 59.9, confirmedPeople: ["Donna"]),
                       ArchiveAngelCandidate(durationSeconds: 59.9, hasUserNotes: true),
                       ArchiveAngelCandidate(durationSeconds: 59.9, userDate: "1994")] {
            #expect(ArchiveAngelScorer.verdict(marked) == .rejected(.tooShort), "\(marked)")
        }
        guard case .eligible = ArchiveAngelScorer.verdict(.init(durationSeconds: 60)) else {
            Issue.record("60 s is the floor, inclusive"); return
        }
        guard case .eligible = ArchiveAngelScorer.verdict(.init(durationSeconds: 60, starRating: 3)) else {
            Issue.record("60 s starred is the floor, inclusive"); return
        }
    }

    @Test("iMovie caches and thumbnail streams never qualify — Rick 2026-09-10 (Cache.mov scored 120)")
    func appCachesAndProxyStreams() {
        let cache = ArchiveAngelCandidate(filename: "Cache.mov",
            fullPath: "/Volumes/LaCie/Family Movies/Christmas1990/iMovie Thumbnails/iMovie Cache/Cache.mov",
            sizeBytes: 4_800_000, durationSeconds: 9553, hasUserNotes: true, hasEmbeddedDate: true)
        #expect(ArchiveAngelScorer.verdict(cache) == .rejected(.appCache))
        let cache30 = ArchiveAngelCandidate(filename: "Cache-30.mov",
            fullPath: "/Volumes/LaCie/iMovie Events.localized/Snowy Westford - Day 7/iMovie Movie Cache/Cache-30.mov",
            sizeBytes: 900_000, durationSeconds: 330)
        #expect(ArchiveAngelScorer.verdict(cache30) == .rejected(.appCache))
        // Name alone, in an ordinary folder.
        #expect(ArchiveAngelScorer.verdict(.init(filename: "render_12.mov", fullPath: "/v/Movies/render_12.mov",
                                                  sizeBytes: 500_000_000, durationSeconds: 300)) == .rejected(.appCache))
        // Folder alone, ordinary name.
        #expect(ArchiveAngelScorer.verdict(.init(filename: "clip-004.mov", fullPath: "/v/Movies/Render Files/clip-004.mov",
                                                  sizeBytes: 500_000_000, durationSeconds: 300)) == .rejected(.appCache))
        // A person's name that CONTAINS the noun is not a cache.
        for ok in [ArchiveAngelCandidate(filename: "Cache Cod 1998.mov", fullPath: "/v/Movies/Cache Cod 1998.mov",
                                         sizeBytes: 9_000_000_000, durationSeconds: 3600),
                   ArchiveAngelCandidate(filename: "Thumbnails of Grandma.mov", fullPath: "/v/Movies/Thumbnails of Grandma/tape1.mov",
                                         sizeBytes: 9_000_000_000, durationSeconds: 3600)] {
            guard case .eligible = ArchiveAngelScorer.verdict(ok) else { Issue.record("\(ok.filename) must be eligible"); return }
        }
        // Bitrate floor: 2 h 39 min in 4.8 MB is ~4 kbit/s — a thumbnail stream, whatever it is called.
        let thin = ArchiveAngelCandidate(filename: "Christmas1990.mov", fullPath: "/v/Movies/Christmas1990.mov",
                                         sizeBytes: 4_800_000, durationSeconds: 9553)
        #expect(ArchiveAngelScorer.verdict(thin) == .rejected(.proxyStream))
        // A poor web clip at 300 kbit/s and a DV tape at 25 Mbit/s both pass.
        for ok in [ArchiveAngelCandidate(filename: "web.mp4", sizeBytes: 11_250_000, durationSeconds: 300),
                   ArchiveAngelCandidate(filename: "tape.dv", sizeBytes: 11_000_000_000, durationSeconds: 3600)] {
            guard case .eligible = ArchiveAngelScorer.verdict(ok) else { Issue.record("\(ok.filename) must be eligible"); return }
        }
        // A star is the human's word — machine floors yield to it, as with junk.
        guard case .eligible = ArchiveAngelScorer.verdict(.init(filename: "Cache.mov", fullPath: "/v/iMovie Cache/Cache.mov",
                                                                sizeBytes: 4_800_000, durationSeconds: 9553, starRating: 2)) else {
            Issue.record("a starred file stays eligible"); return
        }
        #expect(ArchiveAngelScorer.rulesVersion >= 3, "floors changed → the sidecar must re-derive")
    }

    @Test("the rejection line tells the user why short clips are skipped")
    func floorReasonText() {
        #expect(ArchiveAngelRejection.tooShort.rawValue.contains("under 1 min"))
        #expect(ArchiveAngelRejection.tooShort.rawValue.contains("longer original"))
    }
}

@Suite("Archive Angel scorer — evidence")
struct ArchiveAngelEvidenceTests {

    private func lines(_ c: ArchiveAngelCandidate, now: Date = Date()) -> (Int, [String]) {
        guard case .eligible(let score, let ev) = ArchiveAngelScorer.verdict(c, now: now) else { return (-1, []) }
        return (score, ev.map(\.line))
    }

    @Test("every point has a printed reason")
    func everyPointPrints() {
        let c = ArchiveAngelCandidate(starRating: 3, confirmedPeople: ["Donna"], detectedPeople: ["Tim"],
                                      hasUserNotes: true, tagCount: 2, hasCaptions: true,
                                      inferredRecordDate: Date(timeIntervalSince1970: 0), inferredDateConfidence: 0.92,
                                      formatAtRisk: true, audioProblem: "channel imbalance", isOnlyCopy: true, useCount: 14)
        guard case .eligible(let score, let ev) = ArchiveAngelScorer.verdict(c) else { Issue.record("eligible"); return }
        #expect(score == ev.map(\.points).reduce(0, +))
        #expect(ev.allSatisfy { !$0.line.isEmpty })
        let text = ev.map(\.line).joined(separator: "\n")
        #expect(text.contains("★★★"))
        #expect(text.contains("Donna (confirmed)"))
        #expect(text.contains("Looks like Tim (machine)"))
        #expect(text.contains("Played 14 times"))
        #expect(text.contains("Has notes, 2 tags, people, captions, date, rating"))
        #expect(text.contains("Dated 1970-01-01 (consensus 0.92)"))
        #expect(text.contains("At-risk format"))
        #expect(text.contains("only copy"))
        #expect(text.contains("Audio: channel imbalance — will balance"))
    }

    @Test("stars dominate: ★★★ alone outranks a fully tagged, dated, played ★★")
    func starsDominate() {
        let best = lines(.init(starRating: 3)).0
        let rich = lines(.init(starRating: 2, confirmedPeople: ["A", "B", "C"],
                               hasUserNotes: true, tagCount: 3, hasCaptions: true, hasOCRText: true,
                               userDate: "1994", useCount: 100)).0
        #expect(best == 105)   // ★★★ + richness "rating"
        #expect(rich > best, "richness should still add up past ★★★ alone — \(rich)")
        #expect(lines(.init(starRating: 3)).0 > lines(.init(starRating: 2, confirmedPeople: ["A"])).0)
    }

    @Test("people caps: confirmed at 75, machine at 24; confirmed names are not double counted")
    func peopleCaps() {
        let confirmed = lines(.init(confirmedPeople: ["A", "B", "C", "D", "E"]))
        #expect(confirmed.0 == 75 + 5)   // + richness "people"
        let machine = lines(.init(detectedPeople: ["A", "B", "C", "D"], suspectedPeople: ["A", "E"]))
        #expect(machine.0 == 24)
        let both = lines(.init(confirmedPeople: ["Donna"], detectedPeople: ["Donna"]))
        #expect(!both.1.contains { $0.hasPrefix("Looks like") })
    }

    @Test("play history is logarithmic and capped; a recent play adds the bonus")
    func playHistory() {
        #expect(lines(.init(useCount: 1)).0 == 4)
        #expect(lines(.init(useCount: 7)).0 == 12)
        #expect(lines(.init(useCount: 100_000)).0 == 40)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let recent = lines(.init(useCount: 1, lastUsed: now.addingTimeInterval(-86_400)), now: now)
        #expect(recent.0 == 9)
        #expect(recent.1.first?.hasPrefix("Played once, last on ") == true)
        let stale = lines(.init(useCount: 1, lastUsed: now.addingTimeInterval(-400 * 86_400)), now: now)
        #expect(stale.0 == 4)
    }

    @Test("date evidence: user date > confident inferred > uncertain inferred > camera")
    func dateEvidence() {
        #expect(lines(.init(userDate: "1994-11-24")).1.contains("Dated 1994-11-24 (yours)"))
        let d = Date(timeIntervalSince1970: 786_000_000)
        #expect(lines(.init(inferredRecordDate: d, inferredDateConfidence: 0.8)).0 == 20 + 5)
        #expect(lines(.init(inferredRecordDate: d, inferredDateConfidence: 0.55)).0 == 5 + 5)
        #expect(lines(.init(hasEmbeddedDate: true)).1.contains("Dated by the camera"))
    }

    @Test("duration tiers: nothing under 5 min, then scene 10 / long scene 25 / half tape 45 / whole tape 60")
    func durationTiers() {
        #expect(lines(.init(durationSeconds: 60)).0 == 0)
        #expect(lines(.init(durationSeconds: 299)).0 == 0)
        #expect(lines(.init(durationSeconds: 300)).0 == 10)
        #expect(lines(.init(durationSeconds: 899)).0 == 10)
        #expect(lines(.init(durationSeconds: 900)).0 == 25)
        #expect(lines(.init(durationSeconds: 1799)).0 == 25)
        #expect(lines(.init(durationSeconds: 1800)).0 == 45)
        #expect(lines(.init(durationSeconds: 3599)).0 == 45)
        #expect(lines(.init(durationSeconds: 3600)).0 == 60)
        #expect(lines(.init(durationSeconds: 3 * 3600)).0 == 60, "no ceiling — a two-tape capture is still the whole thing")
        #expect(lines(.init(durationSeconds: 5400)).1 == ["Runs 1 h 30 min — likely a whole tape"])
        #expect(lines(.init(durationSeconds: 1800)).1 == ["Runs 30 min 0 s — likely a whole tape or half"])
        #expect(lines(.init(durationSeconds: 120)).1.isEmpty, "a 2 min clip prints no length line")
    }

    @Test("the whole tape outranks the short edit cut from it, unless the edit carries a human mark")
    func wholeTapeBeatsEdit() {
        // The 1998 Cape tape (55 min, dated by consensus) vs the 3 min
        // "Remember the Cape" edit Rick sent around (same date evidence).
        let d = Date(timeIntervalSince1970: 900_000_000)
        let tape = lines(.init(durationSeconds: 55 * 60, inferredRecordDate: d, inferredDateConfidence: 0.9)).0
        let edit = lines(.init(durationSeconds: 3 * 60, inferredRecordDate: d, inferredDateConfidence: 0.9)).0
        #expect(tape > edit)
        #expect(tape - edit == 45)
        // An unrated whole tape with a date reaches grade B on its own; the edit stays C.
        #expect(ArchiveAngelGrade.from(score: tape) == .b)
        #expect(ArchiveAngelGrade.from(score: edit) == .c)
        // Stars are still the human's word: a ★★★ edit outranks an unrated tape.
        #expect(lines(.init(durationSeconds: 3 * 60, starRating: 3)).0 > tape)
    }
}

@Suite("Archive Angel scorer — T10 H1 download/rip cap (night of 2026-09-10)")
struct ArchiveAngelDownloadCapTests {

    private func result(_ c: ArchiveAngelCandidate) -> (score: Int, lines: [String]) {
        guard case .eligible(let score, let ev) = ArchiveAngelScorer.verdict(c) else { return (-1, []) }
        return (score, ev.map(\.line))
    }

    @Test("Gladiator.mp4 — h264, 2.64 GB over 2 h 51 min, unmarked — is capped at grade C with the rate printed")
    func filmIsCapped() {
        let film = ArchiveAngelCandidate(filename: "Gladiator.mp4",
            fullPath: "/Volumes/SanDisk/From_Breen_NetworkBackups/Movies/Gladiator.mp4",
            sizeBytes: 2_640_000_000, durationSeconds: 10259, hasEmbeddedDate: true, isOnlyCopy: true,
            videoCodec: "h264")
        let r = result(film)
        #expect(r.score == 59)
        #expect(r.lines.last?.hasPrefix("Looks like a download or rip — h264 at 2059 kbit/s for 2 h 50 min") == true)
        #expect(ArchiveAngelGrade.from(score: r.score) == .c)
        // Every point still has a printed reason: the cap is a negative line.
        guard case .eligible(let score, let ev) = ArchiveAngelScorer.verdict(film) else { Issue.record("eligible"); return }
        #expect(score == ev.map(\.points).reduce(0, +))
    }

    @Test("a DivX CD rip (.avi, mpeg4, 0.73 GB, 2 h) and a 1 Mbit/s h264 download are capped")
    func ripsAndDownloads() {
        #expect(result(.init(filename: "Pulp Fiction.avi", sizeBytes: 730_000_000, durationSeconds: 8881, videoCodec: "mpeg4")).score == 59)
        #expect(result(.init(filename: "SpinArt_Download.mp4", sizeBytes: 770_000_000, durationSeconds: 5419,
                             hasEmbeddedDate: true, videoCodec: "h264")).score == 59)
    }

    @Test("family originals are never capped: preservation codecs at any rate, h264 from a camera, short phone clips, or anything a human marked")
    func familyOriginalsUntouched() {
        let cases: [(String, ArchiveAngelCandidate)] = [
            ("Thanksgiving-Raw_Default.mov svq3 455 kbit/s", .init(sizeBytes: 320_000_000, durationSeconds: 5629, videoCodec: "svq3")),
            ("Thanksgiving2009Sequence.mov prores 1.6 Mbit/s", .init(sizeBytes: 1_080_000_000, durationSeconds: 5422, videoCodec: "prores")),
            ("Christmas_1990_partial.dv", .init(sizeBytes: 34_360_000_000, durationSeconds: 9553, videoCodec: "dvvideo")),
            ("Cape-1993-archive.mkv ffv1", .init(sizeBytes: 60_670_000_000, durationSeconds: 7338, videoCodec: "ffv1")),
            ("Kids2004.mpg mpeg2 6.3 Mbit/s", .init(sizeBytes: 2_940_000_000, durationSeconds: 3733, videoCodec: "mpeg2video")),
            ("Christmas-1990-something.mov h264 27 Mbit/s", .init(sizeBytes: 5_840_000_000, durationSeconds: 1715, videoCodec: "h264")),
            ("phone clip h264 3 Mbit/s but 4 min", .init(sizeBytes: 90_000_000, durationSeconds: 240, videoCodec: "h264")),
            ("starred 2 Mbit/s h264 film", .init(sizeBytes: 2_640_000_000, durationSeconds: 10259, starRating: 1, videoCodec: "h264")),
            ("confirmed person on a 2 Mbit/s h264 file", .init(sizeBytes: 2_640_000_000, durationSeconds: 10259, confirmedPeople: ["Donna"], videoCodec: "h264")),
            ("codec unknown (empty)", .init(sizeBytes: 730_000_000, durationSeconds: 8881, videoCodec: "")),
        ]
        for (name, c) in cases {
            let r = result(c)
            #expect(r.score >= 0 && !r.lines.contains { $0.hasPrefix("Looks like a download or rip") }, "\(name): \(r.lines)")
        }
        #expect(ArchiveAngelScorer.rulesVersion >= 4, "H1 changed the rules → the sidecar must re-derive")
    }

    @Test("machine text in userNotes is not a human note — Gladiator's 'FindPerson(Donna) recipe…' does not exempt it")
    func machineNotesAreNotHuman() {
        let machine = [
            "FindPerson(Donna) recipe-v1-native 2026-08-27T22:30:19Z: score 0.61 (3 hits / 40 frames)",
            "Unsupported codec with id 98314 for input stream 0",
            "[aac @ 0x7ac800a80] This stream seems to use a channel layout",
            "Last message repeated 3 times",
            "Could not open codec for stream 1",
            "File could not be analyzed: moov atom not found",
            "Consider increasing the value of the 'analyzeduration'",
            "copy at /Volumes/Projects/MoviesExpansion/x.mov (Promote)",
            "Promote 2026-09-09T17:20:11Z → BreenFamilyArchive/1990s/…",
            "File is corrupt or incomplete",
            "[mov,mp4,m4a,3gp,3g2,mj2 @ 0x7e3018000] moov atom not found",
            "[h264 @ 0x12345abc] no frame!",
        ]
        for m in machine {
            #expect(!ArchiveAngelCandidate.hasHumanNote(m), "\(m)")
            #expect(!ArchiveAngelCandidate.hasHumanNote(m + "\n" + m), "two machine lines")
        }
        let human = ["Mark’s first birthday, Nana's house", "Donna and Libby on Portland Head",
                     "Sue, Barry, Ellen, Paul at the Cape", "Video of Rick and kids", "this is a test abcdefg",
                     "[1984] Dad and Donna at Thanksgiving",            // a bracketed human note (codex #1303)
                     "[cape] the whole tape, promote this one", "Repair this one when you can", "transcode later",
                     "Archive Angel picked this — I agree"]                // words the machine also uses, written by a person
        for h in human { #expect(ArchiveAngelCandidate.hasHumanNote(h), "\(h)") }
        // Mixed: a bracketed human line between machine lines counts.
        #expect(ArchiveAngelCandidate.humanNoteLines("[aac @ 0x7ac800a80] x\n[1984] Dad and Donna at Thanksgiving\nLast message repeated 2 times") == ["[1984] Dad and Donna at Thanksgiving"])
        // Mixed: one human line among machine lines counts.
        #expect(ArchiveAngelCandidate.humanNoteLines(machine[0] + "\nDan’s Kindergarten, Franklin\n" + machine[1]) == ["Dan’s Kindergarten, Franklin"])
        #expect(!ArchiveAngelCandidate.hasHumanNote("   \n\n"))
        // Through the scorer: the film with a machine note is still capped; with a human note it is not.
        let film = ArchiveAngelCandidate(sizeBytes: 2_640_000_000, durationSeconds: 10259, videoCodec: "h264")
        #expect(result(film).score == 59)
        var noted = film; noted.hasUserNotes = true
        #expect(result(noted).score > 59)
    }

    @Test("a low-bitrate h264 export inside an iMovie library or the Family Movies tree is a family export, not a download (live: EP1.m4v)")
    func familyOriginPathExempts() {
        let ep1 = ArchiveAngelCandidate(filename: "EP1.m4v",
            fullPath: "/Volumes/SanDisk/Ellen & Paul.imovielibrary/Ellen & Paul 1997/Original Media/EP1.m4v",
            sizeBytes: 1_100_000_000, durationSeconds: 2932, videoCodec: "h264")
        #expect(!ArchiveAngelScorer.looksLikeDownloadOrRip(ep1))
        #expect(!result(ep1).lines.contains { $0.hasPrefix("Looks like a download") })
        for folder in ["/v/Family Movies/Christmas1990", "/v/x.iMovieProject/Media", "/v/iMovie Events.localized/Day 3", "/v/Home Movies"] {
            #expect(ArchiveAngelScorer.hasFamilyOriginPath(folder + "/clip.mp4"), "\(folder)")
        }
        // The same file in a backup's Movies folder is still a download.
        var moved = ep1; moved.fullPath = "/Volumes/SanDisk/From_Breen_NetworkBackups/Movies/EP1.m4v"
        #expect(ArchiveAngelScorer.looksLikeDownloadOrRip(moved))
        // The marker is a WHOLE folder component, never the filename and never a substring.
        #expect(!ArchiveAngelScorer.hasFamilyOriginPath("/v/Movies/Family Movies.mp4"))
        #expect(!ArchiveAngelScorer.hasFamilyOriginPath("/v/NotFamily Movies Rips/x.mp4"))
        #expect(!ArchiveAngelScorer.hasFamilyOriginPath("/v/imovielibrary_backup_rips/x.mp4"))
        #expect(ArchiveAngelScorer.hasFamilyOriginPath("/v/Ellen.imovielibrary/x.mp4"))
        #expect(ArchiveAngelScorer.hasFamilyOriginPath("/v/iMovie Events.localized/Day 1/x.mp4"))
    }

    @Test("SCALE: the note classifier over 100k projection-sized notes stays under 1 s (Debug ceiling)")
    func classifierScale() {
        let machine = "Unsupported codec with id 98314 for input stream 0\n[aac @ 0x7ac800a80] This stream seems to use a channel layout\nLast message repeated 3 times"
        var notes: [String] = []
        notes.reserveCapacity(100_000)
        for i in 0..<100_000 {
            notes.append(i % 1000 == 0 ? machine + "\n[19\(i % 90 + 10)] Family note \(i)" : (i % 3 == 0 ? "" : machine))
        }
        let started = ContinuousClock.now
        var humans = 0
        for n in notes where ArchiveAngelCandidate.hasHumanNote(n) { humans += 1 }
        let elapsed = ContinuousClock.now - started
        #expect(humans == 100)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(1)), "100k notes took \(elapsed)")
    }

    @Test("threshold edges: 3,999 kbit/s at 20 min is capped; 4,000 is not; 19 min 59 s is not")
    func edges() {
        func c(_ kbps: Double, _ secs: Double) -> ArchiveAngelCandidate {
            .init(sizeBytes: Int64(kbps * 1000 * secs / 8), durationSeconds: secs, videoCodec: "h264")
        }
        #expect(ArchiveAngelScorer.looksLikeDownloadOrRip(c(3999, 1200)))
        #expect(!ArchiveAngelScorer.looksLikeDownloadOrRip(c(4000, 1200)))
        #expect(!ArchiveAngelScorer.looksLikeDownloadOrRip(c(1000, 1199)))
        // The cap only lowers: a rip that scores under 59 anyway prints no line.
        let low = c(1000, 1300)   // 21 min: scene tier only → 10 + only-copy? no → well under 59
        #expect(!result(low).lines.contains { $0.hasPrefix("Looks like a download") })
    }
}

@Suite("Archive Angel scorer — T10 H3 derivative exports (night of 2026-09-10, related-only 2026-09-11)")
struct ArchiveAngelDerivativeTests {

    @Test("base-stem rule", arguments: [
        ("Cape-1993-archive.vs.edit", "Cape-1993-archive"),
        ("CapeCodJune1998-Peekaboo.vs.preserve_balanced", "CapeCodJune1998-Peekaboo"),
        ("GrampaBreen with Dan and Mark.vs.archive", "GrampaBreen with Dan and Mark"),
        ("Clip 08_converted.vs.edit", "Clip 08"),
        ("cape-1992-edit_trimmed", "cape-1992-edit"),
        ("Thanksgiving-Raw_Default_denoise_thm2_nyx3", "Thanksgiving-Raw_Default"),
        ("Franklin_Dan_Kindergarten_NV12_2", "Franklin_Dan_Kindergarten"),
        ("Rick-and-boys-1988-cleaned", "Rick-and-boys-1988"),
        ("CapeCpd_1998_balanced", "CapeCpd_1998"),
        ("Christmas1990 copy 2", "Christmas1990"),
    ])
    func baseStem(stem: String, base: String) {
        #expect(ArchiveAngelNaming.derivativeBaseStem(stem) == base)
    }

    @Test("names that are NOT derivatives", arguments: ["cape-1992-edit", "Christmas_1990_partial", "Thanksgiving-Raw_Default", "Clip 08", "_balanced", "Kill Bill Vol 2", "DVD1992_5Chapters", "New TapeV01.6_4DD754DD88921"])
    func notDerivative(stem: String) {
        #expect(ArchiveAngelNaming.derivativeBaseStem(stem) == nil)
    }

    private func marked(_ cands: [ArchiveAngelCandidate]) -> [String: String?] {
        var c = cands
        ArchiveAngelScorer.markDerivatives(&c)
        return Dictionary(c.map { ($0.fullPath, $0.derivativeOfOriginal) }, uniquingKeysWith: { a, _ in a })
    }

    @Test("an export yields only to a RELATED original: same folder, same group, or same grandparent + year; a same-named file elsewhere never counts (codex #1306)")
    func relatedOnly() {
        let g = UUID()
        let y1993 = Date(timeIntervalSince1970: 740_000_000)   // 1993-06
        let m = marked([
            // Unrelated: another tree, no group, different grandparents → NOT marked.
            .init(filename: "Cape-1993-archive.mkv", fullPath: "/v/Converted_VHS_Tapes_2026/Cape-1993/Cape-1993-archive.mkv", sizeBytes: 60_000_000_000, durationSeconds: 7338, videoCodec: "ffv1"),
            .init(filename: "Cape-1993-archive.vs.edit.mov", fullPath: "/v/editable_versions/Cape-1993-archive.vs.edit.mov", sizeBytes: 46_000_000_000, durationSeconds: 7338, videoCodec: "prores"),
            // Same folder → marked.
            .init(filename: "cape-1992-edit.mov", fullPath: "/v/editable/cape-1992-edit.mov", sizeBytes: 50_000_000_000, durationSeconds: 7400, videoCodec: "prores"),
            .init(filename: "cape-1992-edit_trimmed.mov", fullPath: "/v/editable/cape-1992-edit_trimmed.mov", sizeBytes: 50_000_000_000, durationSeconds: 7384, videoCodec: "prores"),
            // Same duplicate group, different trees → marked.
            .init(filename: "Grampa.mov", fullPath: "/v/tapes/Grampa.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, duplicateGroupID: g),
            .init(filename: "Grampa_NV12.mov", fullPath: "/w/exports/Grampa_NV12.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, duplicateGroupID: g),
            // Same grandparent AND same year → marked; same grandparent, different year → not.
            .init(filename: "Xmas.mov", fullPath: "/v/Family/1993/Xmas.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, inferredRecordDate: y1993, inferredDateConfidence: 0.9),
            .init(filename: "Xmas_balanced.mov", fullPath: "/v/Family/exports/Xmas_balanced.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, userDate: "1993-12-25"),
            .init(filename: "Bday.mov", fullPath: "/v/Family/1990/Bday.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, userDate: "1990"),
            .init(filename: "Bday_fixed.mov", fullPath: "/v/Family/exports/Bday_fixed.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, userDate: "1991"),
            // No original anywhere → the best copy the family has.
            .init(filename: "Lonely_balanced.mov", fullPath: "/v/x/Lonely_balanced.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            // Ungrouped twins in two folders never collapse; the export beside /v/b's twin names it.
            .init(filename: "Twin.mov", fullPath: "/v/a/Twin.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            .init(filename: "Twin.mov", fullPath: "/v/b/Twin.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            .init(filename: "Twin_balanced.mov", fullPath: "/v/b/Twin_balanced.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
        ])
        #expect(m["/v/editable_versions/Cape-1993-archive.vs.edit.mov"] == .some(nil), "unrelated namesake in another tree must NOT mark")
        #expect(m["/v/editable/cape-1992-edit_trimmed.mov"] == "cape-1992-edit.mov")
        #expect(m["/v/editable/cape-1992-edit.mov"] == .some(nil), "'edit' without .vs. is a name, not a token")
        #expect(m["/w/exports/Grampa_NV12.mov"] == "Grampa.mov", "same duplicate group relates across trees")
        #expect(m["/v/Family/exports/Xmas_balanced.mov"] == "Xmas.mov", "same grandparent + same year")
        #expect(m["/v/Family/exports/Bday_fixed.mov"] == .some(nil), "same grandparent, different year")
        #expect(m["/v/x/Lonely_balanced.mov"] == .some(nil))
        #expect(m["/v/b/Twin_balanced.mov"] == "Twin.mov")
        #expect(m["/v/a/Twin.mov"] == .some(nil) && m["/v/b/Twin.mov"] == .some(nil), "originals are never marked")
    }

    @Test("an unusable original does not displace the export: offline, too short, junk, cache, unplayable, or itself a derivative")
    func unusableOriginalKeepsExport() {
        let m = marked([
            .init(filename: "Off.mov", fullPath: "/v/x/Off.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, volumeOnline: false),
            .init(filename: "Off_balanced.mov", fullPath: "/v/x/Off_balanced.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            .init(filename: "Short.mov", fullPath: "/v/x/Short.mov", sizeBytes: 100_000_000, durationSeconds: 30),
            .init(filename: "Short_fixed.mov", fullPath: "/v/x/Short_fixed.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            .init(filename: "Junk.mov", fullPath: "/v/x/Junk.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, mediaDisposition: .confirmedJunk),
            .init(filename: "Junk_fixed.mov", fullPath: "/v/x/Junk_fixed.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            .init(filename: "Sus.mov", fullPath: "/v/x/Sus.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, mediaDisposition: .suspectedJunk),
            .init(filename: "Sus_trimmed.mov", fullPath: "/v/x/Sus_trimmed.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            .init(filename: "Bad.mov", fullPath: "/v/x/Bad.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, isPlayable: "No"),
            .init(filename: "Bad_cleaned.mov", fullPath: "/v/x/Bad_cleaned.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            // The "original" is 40 min, the export 60 min → not its original.
            .init(filename: "Half.mov", fullPath: "/v/x/Half.mov", sizeBytes: 9_000_000_000, durationSeconds: 2400),
            .init(filename: "Half_reencoded.mov", fullPath: "/v/x/Half_reencoded.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            // 0.9 × is enough (an export loses a little at the head/tail).
            .init(filename: "Near.mov", fullPath: "/v/x/Near.mov", sizeBytes: 9_000_000_000, durationSeconds: 3300),
            .init(filename: "Near_converted.mov", fullPath: "/v/x/Near_converted.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            // A derivative is never anyone's original: Chain_fixed_trimmed → base "Chain_fixed" → itself an export → no mark.
            .init(filename: "Chain_fixed.mov", fullPath: "/v/x/Chain_fixed.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            .init(filename: "Chain_fixed_trimmed.mov", fullPath: "/v/x/Chain_fixed_trimmed.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
        ])
        for path in ["/v/x/Off_balanced.mov", "/v/x/Short_fixed.mov", "/v/x/Junk_fixed.mov", "/v/x/Sus_trimmed.mov",
                     "/v/x/Bad_cleaned.mov", "/v/x/Half_reencoded.mov", "/v/x/Chain_fixed_trimmed.mov"] {
            #expect(m[path] == .some(nil), "\(path) must keep its place — its original is unusable")
        }
        #expect(m["/v/x/Near_converted.mov"] == "Near.mov")
    }

    @Test("the floor, a star, and the selection count: a marked export is rejected unless starred")
    func floorAndCount() {
        var cands = [
            ArchiveAngelCandidate(filename: "Tape.mov", fullPath: "/v/x/Tape.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            ArchiveAngelCandidate(filename: "Tape_balanced.mov", fullPath: "/v/x/Tape_balanced.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            ArchiveAngelCandidate(filename: "Tape.vs.edit.mov", fullPath: "/v/x/Tape.vs.edit.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            ArchiveAngelCandidate(filename: "Starred.mov", fullPath: "/v/x/Starred.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600),
            ArchiveAngelCandidate(filename: "Starred.vs.edit.mov", fullPath: "/v/x/Starred.vs.edit.mov", sizeBytes: 9_000_000_000, durationSeconds: 3600, starRating: 2),
        ]
        ArchiveAngelScorer.markDerivatives(&cands)
        func by(_ name: String) -> ArchiveAngelCandidate { cands.first { $0.filename == name } ?? cands[0] }
        #expect(ArchiveAngelScorer.hardFloor(by("Tape_balanced.mov")) == .derivativeOfOriginal)
        #expect(ArchiveAngelScorer.hardFloor(by("Tape.vs.edit.mov")) == .derivativeOfOriginal)
        #expect(ArchiveAngelScorer.hardFloor(by("Tape.mov")) == nil)
        #expect(ArchiveAngelScorer.hardFloor(by("Starred.vs.edit.mov")) == nil, "a star is the human's word")
        let sel = ArchiveAngelScorer.select(cands, count: 20)
        #expect(sel.rejected[.derivativeOfOriginal] == 2)
        #expect(sel.picks.map(\.candidate.filename).sorted() == ["Starred.mov", "Starred.vs.edit.mov", "Tape.mov"])
        #expect(ArchiveAngelScorer.rulesVersion >= 6)
    }

    @Test("SCALE: markDerivatives over 100k candidates with 5k derivative names and 5k same-stem originals under 1 s (Debug ceiling)")
    func scale() {
        var cands: [ArchiveAngelCandidate] = []
        cands.reserveCapacity(100_000)
        let base = Date(timeIntervalSince1970: 700_000_000)
        for i in 0..<100_000 {
            // Every 20th is an export of a tape two rows on (same folder); every
            // 20th+1 is one of 5,000 "Clip 01" originals in 5,000 folders — the
            // quadratic trap codex #1306 named.
            let name: String
            switch i % 20 {
            case 0: name = "tape\(i + 2)_balanced.mov"
            case 1: name = "Clip 01.mov"
            default: name = "tape\(i).mov"
            }
            cands.append(.init(filename: name, fullPath: "/v/f\(i / 20)/\(name)", sizeBytes: 9_000_000_000,
                               durationSeconds: 3600, inferredRecordDate: base.addingTimeInterval(Double(i) * 3600),
                               inferredDateConfidence: 0.9))
        }
        let started = ContinuousClock.now
        ArchiveAngelScorer.markDerivatives(&cands)
        let elapsed = ContinuousClock.now - started
        let markedCount = cands.filter { $0.derivativeOfOriginal != nil }.count
        #expect(markedCount == 5_000, "every export beside its tape is marked: \(markedCount)")
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(1)), "100k markDerivatives took \(elapsed)")
    }
}

@Suite("Archive Angel scorer — selection")
struct ArchiveAngelSelectionTests {

    @Test("takes the top N, reports overflow and rejection counts by reason")
    func batchCut() {
        var cands: [ArchiveAngelCandidate] = []
        for i in 0..<30 { cands.append(.init(filename: "c\(i).mov", starRating: i % 4)) }
        cands.append(.init(filename: "junk.mov", mediaDisposition: .confirmedJunk))
        cands.append(.init(filename: "tiny.mov", durationSeconds: 1))
        cands.append(.init(filename: "tiny2.mov", durationSeconds: 2))
        let sel = ArchiveAngelScorer.select(cands, count: 7)
        #expect(sel.picks.count == 7)
        #expect(sel.overflow == 23)
        #expect(sel.rejected[.junk] == 1)
        #expect(sel.rejected[.tooShort] == 2)
        #expect(sel.rejectedTotal == 3)
        #expect(sel.picks.allSatisfy { $0.candidate.starRating == 3 })
        #expect(sel.picks.map(\.score) == sel.picks.map(\.score).sorted(by: >))
    }

    @Test("ties break oldest date first, then longer, then larger file, then name")
    func tieBreak() {
        // Sizes in GB: the bitrate floor (2026-09-10) reads a 10-byte minute as a thumbnail stream.
        let old = Date(timeIntervalSince1970: 600_000_000)
        let new = Date(timeIntervalSince1970: 900_000_000)
        let cands = [
            ArchiveAngelCandidate(filename: "b.mov", sizeBytes: 10_000_000_000, inferredRecordDate: new, inferredDateConfidence: 0.9),
            ArchiveAngelCandidate(filename: "a.mov", sizeBytes: 10_000_000_000, inferredRecordDate: new, inferredDateConfidence: 0.9),
            ArchiveAngelCandidate(filename: "c.mov", sizeBytes: 99_000_000_000, inferredRecordDate: new, inferredDateConfidence: 0.9),
            ArchiveAngelCandidate(filename: "e.mov", sizeBytes: 1_000_000_000, durationSeconds: 200, inferredRecordDate: new, inferredDateConfidence: 0.9),
            ArchiveAngelCandidate(filename: "d.mov", sizeBytes: 1_000_000_000, inferredRecordDate: old, inferredDateConfidence: 0.9),
        ]
        let names = ArchiveAngelScorer.select(cands, count: 5).picks.map(\.candidate.filename)
        #expect(names == ["d.mov", "e.mov", "c.mov", "a.mov", "b.mov"],
                "e is longer (same score — under 5 min earns nothing) so it beats the bigger file")
    }

    @Test("T10 H2: one member per duplicate group — the best-ranked stays, the rest are counted; unknown-group rows never collapse")
    func onePerDuplicateGroup() {
        let g = UUID(), h = UUID()
        let d = Date(timeIntervalSince1970: 700_000_000)
        let cands = [
            // Same tape under two names on two volumes (live: DVD1992_5Chapters ≡ WholeSequence1991): equal score → the longer/larger wins.
            ArchiveAngelCandidate(filename: "DVD1992_5Chapters.mov", sizeBytes: 13_840_000_000, durationSeconds: 3651, starRating: 3, inferredRecordDate: d, inferredDateConfidence: 0.9, duplicateGroupID: g),
            ArchiveAngelCandidate(filename: "WholeSequence1991.mov", sizeBytes: 13_830_000_000, durationSeconds: 3651, starRating: 3, inferredRecordDate: d, inferredDateConfidence: 0.9, duplicateGroupID: g),
            // A group whose members differ in score: the higher score stays even if it is the smaller file.
            ArchiveAngelCandidate(filename: "Cape-1993-archive.mkv", sizeBytes: 60_670_000_000, durationSeconds: 7338, starRating: 2, duplicateGroupID: h),
            ArchiveAngelCandidate(filename: "Cape-1993-archive-copy.mkv", sizeBytes: 60_670_000_000, durationSeconds: 7338, starRating: 3, duplicateGroupID: h),
            // Two rows with NO group and identical size/duration are NOT collapsed — only a real group counts.
            ArchiveAngelCandidate(filename: "Part1.mov", sizeBytes: 9_000_000_000, durationSeconds: 1800, starRating: 1),
            ArchiveAngelCandidate(filename: "Part2.mov", sizeBytes: 9_000_000_000, durationSeconds: 1800, starRating: 1),
        ]
        let sel = ArchiveAngelScorer.select(cands, count: 10)
        let names = sel.picks.map(\.candidate.filename)
        #expect(names.contains("DVD1992_5Chapters.mov") && !names.contains("WholeSequence1991.mov"), "\(names)")
        #expect(names.contains("Cape-1993-archive-copy.mkv") && !names.contains("Cape-1993-archive.mkv"), "\(names)")
        #expect(names.contains("Part1.mov") && names.contains("Part2.mov"))
        #expect(sel.rejected[.duplicateOfPick] == 2)
        #expect(sel.overflow == 0)
        #expect(ArchiveAngelScorer.rulesVersion >= 6)
    }

    @Test("most original wins a tie: dvvideo beats a larger, longer h264 twin; the table order is dv, mjpeg, mpeg2, hdv, prores, ffv1, mpeg1, svq3, delivery, unknown")
    func originalityTieBreak() {
        let g = UUID()
        let d = Date(timeIntervalSince1970: 700_000_000)
        let cands = [
            ArchiveAngelCandidate(filename: "Cape98.mp4", sizeBytes: 20_000_000_000, durationSeconds: 3700, starRating: 3, inferredRecordDate: d, inferredDateConfidence: 0.9, videoCodec: "h264", duplicateGroupID: g),
            ArchiveAngelCandidate(filename: "Cape98.dv", sizeBytes: 12_000_000_000, durationSeconds: 3600, starRating: 3, inferredRecordDate: d, inferredDateConfidence: 0.9, videoCodec: "dvvideo", duplicateGroupID: g),
        ]
        let sel = ArchiveAngelScorer.select(cands, count: 5)
        #expect(sel.picks.map(\.candidate.filename) == ["Cape98.dv"], "the DV capture is the original; the bigger h264 is a re-encode")
        #expect(sel.rejected[.duplicateOfPick] == 1)
        let order = ["dvvideo", "mjpeg", "mpeg2video", "hdv", "prores", "ffv1", "mpeg1video", "svq3", "h264", ""]
        #expect(order.map(ArchiveAngelScorer.originalityRank) == order.map(ArchiveAngelScorer.originalityRank).sorted())
        #expect(ArchiveAngelScorer.originalityRank("DV") == ArchiveAngelScorer.originalityRank("dvvideo"))
        #expect(ArchiveAngelScorer.originalityRank("hevc") == ArchiveAngelScorer.originalityRank("h264"))
        #expect(ArchiveAngelScorer.originalityRank("wmv3") == ArchiveAngelScorer.originalityUnknown)
        // Score still outranks originality: a starred h264 beats an unrated DV.
        let starred = ArchiveAngelScorer.select([
            .init(filename: "a.mp4", sizeBytes: 9_000_000_000, durationSeconds: 3600, starRating: 1, videoCodec: "h264"),
            .init(filename: "b.dv", sizeBytes: 9_000_000_000, durationSeconds: 3600, videoCodec: "dvvideo"),
        ], count: 2).picks.map(\.candidate.filename)
        #expect(starred == ["a.mp4", "b.dv"])
    }

    @Test("rank is the ONE comparator: strict weak order, score → originality → date → duration → size → name")
    func rankIsStrict() {
        let d = Date(timeIntervalSince1970: 700_000_000)
        func pick(_ name: String, score: Int = 10, codec: String = "", date: Date? = d, dur: Double = 60, size: Int64 = 1) -> ArchiveAngelPick {
            .init(candidate: .init(filename: name, sizeBytes: size, durationSeconds: dur, inferredRecordDate: date, videoCodec: codec), score: score, evidence: [])
        }
        let a = pick("a", score: 20), b = pick("b", codec: "dvvideo"), c = pick("c", date: d.addingTimeInterval(-86_400)),
            e = pick("e", dur: 120), f = pick("f", size: 9), h = pick("h"), i = pick("i")
        let sorted = [i, h, f, e, c, b, a].sorted(by: ArchiveAngelScorer.rank).map(\.candidate.filename)
        #expect(sorted == ["a", "b", "c", "e", "f", "h", "i"])
        #expect(!ArchiveAngelScorer.rank(h, h), "irreflexive")
    }

    @Test("count 0 and empty input are safe")
    func degenerate() {
        #expect(ArchiveAngelScorer.select([], count: 25).picks.isEmpty)
        let sel = ArchiveAngelScorer.select([.init(starRating: 3)], count: 0)
        #expect(sel.picks.isEmpty)
        #expect(sel.overflow == 1)
    }

    @Test("SCALE: 100k candidates select in under 2 s (Debug ceiling, widened on hosted runners)")
    func scale() {
        var cands: [ArchiveAngelCandidate] = []
        cands.reserveCapacity(100_000)
        let base = Date(timeIntervalSince1970: 700_000_000)
        for i in 0..<100_000 {
            cands.append(.init(filename: "v\(i).mov", sizeBytes: Int64(i), durationSeconds: Double(i % 9000),
                               starRating: i % 4, junkScore: i % 7,
                               confirmedPeople: i % 5 == 0 ? ["Donna"] : [],
                               detectedPeople: i % 3 == 0 ? ["Tim", "Matt"] : [],
                               hasUserNotes: i % 11 == 0, tagCount: i % 4,
                               inferredRecordDate: base.addingTimeInterval(Double(i) * 3600),
                               inferredDateConfidence: Float(i % 100) / 100, useCount: i % 50))
        }
        let started = ContinuousClock.now
        let sel = ArchiveAngelScorer.select(cands, count: 50)
        let elapsed = ContinuousClock.now - started
        #expect(sel.picks.count == 50)
        #expect(elapsed < PerformanceLane.debugCeiling(.seconds(2)), "100k select took \(elapsed)")
    }
}
