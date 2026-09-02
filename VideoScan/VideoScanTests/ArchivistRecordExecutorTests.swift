import Foundation
import Testing
@testable import VideoScan

/// The one-record executor (2026-09-02): evidence tiers, per-name verdicts,
/// owner binding, date delegation, the dossier line across the media
/// matrix, and the single citation every answer carries.
@Suite("Family Archivist record executor")
struct ArchivistRecordExecutorTests {
    private let confirmedAt = Date(timeIntervalSince1970: 1_700_000_000)
    private let recordID = UUID()
    private let path = "/Volumes/SanDiskWorkspace/QuicktimeMovies/New Hampshire.mov"

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: year, month: month, day: day, hour: 12))!
    }

    private func snapshot(
        confirmed: [String] = [],
        detected: [String] = [],
        suspected: [String] = [],
        transcript: String? = nil,
        container: String = "mov",
        videoCodec: String = "prores",
        audioCodec: String = "pcm_s16le",
        streamType: StreamType = .videoAndAudio,
        resolution: String = "720x480",
        durationSeconds: Double = 754,
        sizeBytes: Int64 = 1_200_000_000,
        archiveStage: ArchiveStage = .none,
        resolvedDate: ArchivistTemporalSelectionDateSnapshot? = nil
    ) -> ArchivistRecordDossierSnapshot {
        ArchivistRecordDossierSnapshot(
            presence: ArchivistPresenceRecordSnapshot(
                id: recordID, fullPath: path, volumeName: "SanDiskWorkspace",
                streamTypeRaw: streamType.rawValue,
                confirmedPeople: confirmed.map { ConfirmedTag(name: $0, confirmedAt: confirmedAt) },
                transcript: transcript, transcriptModel: transcript == nil ? nil : "fixture-whisper"),
            detectedPeople: detected, suspectedPeople: suspected,
            durationSeconds: durationSeconds, container: container,
            videoCodec: videoCodec, audioCodec: audioCodec, resolution: resolution,
            frameRate: "29.97", sizeBytes: sizeBytes, archiveStage: archiveStage,
            resolvedDate: resolvedDate)
    }

    private func query(
        _ operations: [ArchivistQueryAST.Record.Operation],
        people: [String]? = nil,
        reference: ArchivistQueryAST.Record.Reference = .file(name: "New Hampshire.mov")
    ) -> ArchivistQueryAST.Record {
        .init(reference: reference, operations: operations, people: people)
    }

    private var year1994: ArchivistTemporalSelectionDateSnapshot {
        .resolved(recordID: recordID, fullPath: path, date: date(1994, 1, 1),
                  source: .userDate, precision: .year, confidence: 1.0)
    }

    // MARK: - People tiers

    @Test func peopleAreListedByEvidenceTierWithTheTierNamed() {
        let result = ArchivistRecordExecutor.execute(
            query([.people]),
            snapshot: snapshot(confirmed: ["Donna", "Rick"], detected: ["Tim", "Donna"], suspected: ["Nancy"]),
            ownerName: nil)
        #expect(result.route == .record)
        #expect(result.outcome == .answered)
        #expect(result.prose == "In New Hampshire.mov, Donna and Rick are tagged (confirmed by a person). The face matcher thinks Tim is in it too — not confirmed. Maybe Nancy — a borderline face match.",
                Comment(rawValue: result.prose))
        #expect(result.basisLine.contains("tags confirmed 2, detected 2, suspected 1, no transcript"))
        #expect(result.citations.count == 1)
        #expect(result.citations[0].recordID == recordID)
        #expect(result.citations[0].fullPath == path)
        #expect(result.citations[0].bases.contains {
            if case .humanPersonTag(_, let tag, _) = $0 { return tag == "Donna" }
            return false
        })
    }

    @Test func nobodyKnownIsSaidPlainlyAndTheTranscriptIsOffered() {
        let silent = ArchivistRecordExecutor.execute(query([.people]), snapshot: snapshot(), ownerName: nil)
        #expect(silent.prose == "In New Hampshire.mov, nobody is tagged yet and the face matcher hasn't found anyone.")
        let spoken = ArchivistRecordExecutor.execute(
            query([.people]), snapshot: snapshot(transcript: "okay everybody wave"), ownerName: nil)
        #expect(spoken.prose.hasSuffix("There is a transcript — ask me whether a particular name comes up."))
    }

    @Test func eachAskedNameGetsOneVerdictFromItsHighestTier() {
        let result = ArchivistRecordExecutor.execute(
            query([.people], people: ["Donna", "tim", "Nancy", "Rick", "Bob"]),
            snapshot: snapshot(confirmed: ["Donna"], detected: ["Tim"], suspected: ["Nancy"],
                               transcript: "and here is Rick with the camera"),
            ownerName: nil)
        let prose = result.prose
        #expect(prose.contains("In New Hampshire.mov, Donna is tagged (confirmed by a person)."), Comment(rawValue: prose))
        #expect(prose.contains("The face matcher thinks Tim is in it — not confirmed."), Comment(rawValue: prose))
        #expect(prose.contains("Nancy is a maybe — a borderline face match, not confirmed."), Comment(rawValue: prose))
        #expect(prose.contains("Rick isn't tagged, but someone says the name “Rick” in the transcript."), Comment(rawValue: prose))
        #expect(prose.contains("Nothing for Bob — not tagged, not detected, and the name isn't in the transcript."), Comment(rawValue: prose))
        #expect(result.citations[0].bases.contains {
            if case .transcriptMention(let term, let model) = $0 { return term == "Rick" && model == "fixture-whisper" }
            return false
        })
        #expect(result.catalogPersonName == nil)
    }

    @Test func noTranscriptChangesTheNotFoundWording() {
        let result = ArchivistRecordExecutor.execute(
            query([.people], people: ["Bob"]), snapshot: snapshot(), ownerName: nil)
        #expect(result.prose == "In New Hampshire.mov, nothing for Bob — not tagged, not detected, and there is no transcript to check.")
        #expect(result.catalogPersonName == "Bob")
    }

    @Test func meBindsToTheOwnerOrIsHonestlyUnbound() {
        let tagged = ArchivistRecordExecutor.execute(
            query([.people], people: ["me"]), snapshot: snapshot(confirmed: ["Rick"]), ownerName: "Rick Breen")
        #expect(tagged.prose == "In New Hampshire.mov, Rick is tagged (confirmed by a person).")
        #expect(tagged.catalogPersonName == "Rick")

        let spoken = ArchivistRecordExecutor.execute(
            query([.people], people: ["my name"]),
            snapshot: snapshot(transcript: "rick, get in the picture"), ownerName: "Rick Breen")
        #expect(spoken.prose == "In New Hampshire.mov, Rick isn't tagged, but someone says the name “Rick” in the transcript.")

        let unbound = ArchivistRecordExecutor.execute(
            query([.people], people: ["me"]), snapshot: snapshot(confirmed: ["Rick"]), ownerName: nil)
        #expect(unbound.prose == "In New Hampshire.mov, I don't know your name yet — set it in Hallie's settings and ask again.")
        #expect(unbound.catalogPersonName == nil)
    }

    @Test func nameMatchingIsWholeTokenEitherWayNeverPrefix() {
        #expect(ArchivistRecordExecutor.namesMatch("Rick", "Rick Breen"))
        #expect(ArchivistRecordExecutor.namesMatch("rick breen", "Rick"))
        #expect(ArchivistRecordExecutor.namesMatch("donna", "Donna"))
        #expect(!ArchivistRecordExecutor.namesMatch("Tim", "Timmy"))
        #expect(!ArchivistRecordExecutor.namesMatch("Dan", "Donna"))
        #expect(ArchivistRecordExecutor.transcriptMention(of: "Rick Breen", in: "here is rick") == "Rick")
        #expect(ArchivistRecordExecutor.transcriptMention(of: "Rick Breen", in: "rick breen filming") == "Rick Breen")
        #expect(ArchivistRecordExecutor.transcriptMention(of: "Rick", in: "a trick of the light") == nil)
        #expect(ArchivistRecordExecutor.transcriptMention(of: "Rick", in: nil) == nil)
    }

    // MARK: - Date

    @Test func dateDelegatesToTheSelectionDateWordingWithSourceAndPrecision() {
        let dated = ArchivistRecordExecutor.execute(query([.date]), snapshot: snapshot(resolvedDate: year1994), ownerName: nil)
        #expect(dated.prose == "This was filmed in 1994.")
        #expect(dated.basisLine.contains("from the date Rick entered (year precision"), Comment(rawValue: dated.basisLine))

        let day = ArchivistTemporalSelectionDateSnapshot.resolved(
            recordID: recordID, fullPath: path, date: date(1994, 12, 25),
            source: .embedded, precision: .day, confidence: 0.9)
        let precise = ArchivistRecordExecutor.execute(query([.date]), snapshot: snapshot(resolvedDate: day), ownerName: nil)
        #expect(precise.prose == "This was filmed on 25 December 1994.")

        let undated = ArchivistRecordExecutor.execute(query([.date]), snapshot: snapshot(), ownerName: nil)
        #expect(undated.prose.hasPrefix("I don't have a date for the selected video"))
        #expect(undated.outcome == .answered, "an honest 'no date' is still the answer about this record")

        let stamp = ArchivistTemporalSelectionDateSnapshot.catalogCreation(
            recordID: recordID, fullPath: path, date: date(2026, 7, 1))
        let transcode = ArchivistRecordExecutor.execute(query([.date]), snapshot: snapshot(resolvedDate: stamp), ownerName: nil)
        #expect(transcode.prose.contains("may be when it was copied or transcoded, not when it was filmed"))
    }

    @Test func peopleAndDateComposeInOrder() {
        let result = ArchivistRecordExecutor.execute(
            query([.people, .date], people: ["rick"]),
            snapshot: snapshot(confirmed: ["Rick"], resolvedDate: year1994), ownerName: nil)
        #expect(result.prose == "This was filmed in 1994. In New Hampshire.mov, Rick is tagged (confirmed by a person).")
    }

    // MARK: - About

    @Test func aboutIsOneMetadataLineThenDateThenPeopleThenTheTranscriptOpening() {
        let result = ArchivistRecordExecutor.execute(
            query([.about], people: ["rick"]),
            snapshot: snapshot(confirmed: ["Donna"], transcript: "Okay everybody, wave to the camera. Where is Rick?",
                               resolvedDate: year1994),
            ownerName: nil)
        #expect(result.prose == "New Hampshire.mov is a mov video with sound, prores with pcm_s16le audio, 720x480, 12:34 long, 1.2 GB, on SanDiskWorkspace — not yet archived. This was filmed in 1994. In New Hampshire.mov, Rick isn't tagged, but someone says the name “Rick” in the transcript. The transcript opens: “Okay everybody, wave to the camera.”",
                Comment(rawValue: result.prose))
        #expect(result.basisLine.hasPrefix("Basis: record \(path); media Video+Audio mov/prores/pcm_s16le, 754 s, 1200000000 bytes, archive stage None;"))
        #expect(result.offeredActions.isEmpty, "about already covers people and date")
    }

    /// The media matrix: containers and codecs the catalog actually holds,
    /// plus audio-only and video-only essence (the Avid MXF pairs).
    @Test(arguments: [
        ("mp4", "h264", "aac", StreamType.videoAndAudio, "a mp4 video with sound, h264 with aac audio"),
        ("mov", "prores", "pcm_s16le", .videoAndAudio, "a mov video with sound, prores with pcm_s16le audio"),
        ("mkv", "ffv1", "pcm_s16le", .videoAndAudio, "a mkv video with sound, ffv1 with pcm_s16le audio"),
        ("mxf", "dvvideo", "pcm_s16le", .videoAndAudio, "a mxf video with sound, dvvideo with pcm_s16le audio"),
        ("avi", "dvvideo", "pcm_s16le", .videoAndAudio, "a avi video with sound, dvvideo with pcm_s16le audio"),
        ("mxf", "dvvideo", "", .videoOnly, "a mxf video with no audio track, dvvideo"),
        ("mxf", "", "pcm_s24le", .audioOnly, "an mxf audio-only recording, pcm_s24le audio"),
        ("wav", "", "pcm_s16le", .audioOnly, "an wav audio-only recording, pcm_s16le audio"),
    ] as [(String, String, String, StreamType, String)])
    func aboutLineNamesTheContainerCodecsAndKind(
        container: String, video: String, audio: String, stream: StreamType, expected: String
    ) {
        let line = ArchivistRecordExecutor.metadataSentence(
            snapshot(container: container, videoCodec: video, audioCodec: audio, streamType: stream,
                     resolution: stream == .audioOnly ? "" : "720x480"))
        #expect(line.hasPrefix("New Hampshire.mov is \(expected), "), Comment(rawValue: line))
        #expect(line.hasSuffix("12:34 long, 1.2 GB, on SanDiskWorkspace — not yet archived."), Comment(rawValue: line))
    }

    @Test func archiveStageAndUnreadableMediaAreWorded() {
        #expect(ArchivistRecordExecutor.metadataSentence(snapshot(archiveStage: .archived)).hasSuffix("— safely in the Master Archive."))
        #expect(ArchivistRecordExecutor.metadataSentence(snapshot(archiveStage: .readyForArchive)).hasSuffix("— ready for the archive."))
        let broken = ArchivistRecordExecutor.metadataSentence(
            snapshot(container: "", videoCodec: "", audioCodec: "", streamType: .ffprobeFailed,
                     resolution: "", durationSeconds: 0, sizeBytes: 0))
        #expect(broken == "New Hampshire.mov is a file with no readable streams, on SanDiskWorkspace — not yet archived.")
    }

    @Test func transcriptOpeningIsOneBoundedSentence() {
        #expect(ArchivistRecordExecutor.transcriptOpening("Hello there. More words.") == "Hello there.")
        #expect(ArchivistRecordExecutor.transcriptOpening("   ") == nil)
        #expect(ArchivistRecordExecutor.transcriptOpening(nil) == nil)
        let long = String(repeating: "word ", count: 100)
        let opening = try! #require(ArchivistRecordExecutor.transcriptOpening(long))
        #expect(opening.count <= 161 && opening.hasSuffix("…"))
    }

    // MARK: - Offers and which-one questions

    @Test func offersNameTheFullPathForTheOperationsNotAsked() {
        let people = ArchivistRecordExecutor.execute(query([.people]), snapshot: snapshot(), ownerName: nil)
        #expect(people.offeredActions == [
            .ask(question: "tell me about \(path)", label: "Tell me about it"),
            .ask(question: "when was \(path) filmed", label: "When was it filmed"),
        ])
        let date = ArchivistRecordExecutor.execute(query([.date]), snapshot: snapshot(), ownerName: nil)
        #expect(date.offeredActions == [
            .ask(question: "tell me about \(path)", label: "Tell me about it"),
            .ask(question: "who is in \(path)", label: "Who is in it"),
        ])
        // Every offered question is itself recognised model-free and resolves by path.
        for action in people.offeredActions + date.offeredActions {
            if case .ask(let question, _) = action {
                #expect(ArchivistRecordQuestion.detect(question)?.reference == .file(name: path), Comment(rawValue: question))
            }
        }
    }

    @Test func whichOneQuestionsRepeatTheAskAgainstOnePath() {
        let target = "/Volumes/A/Christmas 1994.mov"
        #expect(ArchivistRecordExecutor.question(for: query([.about]), path: target) == "tell me about \(target)")
        #expect(ArchivistRecordExecutor.question(for: query([.people]), path: target) == "who is in \(target)")
        #expect(ArchivistRecordExecutor.question(for: query([.people], people: ["Donna", "Rick"]), path: target)
                == "is Donna and Rick in \(target)")
        #expect(ArchivistRecordExecutor.question(for: query([.date]), path: target) == "when was \(target) filmed")
        #expect(ArchivistRecordExecutor.question(for: query([.people, .date]), path: target)
                == "who is in \(target) and when was it filmed")
        for question in [
            ArchivistRecordExecutor.question(for: query([.people], people: ["Donna", "Rick"]), path: target),
            ArchivistRecordExecutor.question(for: query([.people, .date]), path: target),
        ] {
            let detected = ArchivistRecordQuestion.detect(question)
            #expect(detected?.reference == .file(name: target), Comment(rawValue: question))
        }
    }

    @Test func queryDescriptionAndSelectionReferenceAreNamed() {
        let result = ArchivistRecordExecutor.execute(
            query([.people], people: ["Donna"], reference: .currentSelection), snapshot: snapshot(), ownerName: nil)
        #expect(result.queryDescription == "shape=record reference=selection operations=people people=Donna")
        #expect(result.citations[0].bases.contains {
            if case .catalogField(let field, let term, let value) = $0 {
                return field == "filename" && term == "selection" && value == "New Hampshire.mov"
            }
            return false
        })
    }
}
