import Testing
import Foundation
@testable import VideoScan

// One test (or a few) per section formatter of InspectorMetadataText — the
// pieces "Copy All Metadata" is built from. The whole text is pinned by
// InspectorMetadataTextCharacterizationTests; these pin each piece's own
// rules (visibility, empty values, spacing) so a change shows up in the
// section it belongs to.

@MainActor
struct InspectorMetadataTextTests {

    static func rec(_ name: String = "a.mov") -> VideoRecord {
        let r = VideoRecord()
        r.filename = name
        r.fullPath = "/Volumes/CharzNeverMounted/\(name)"
        return r
    }

    private func lines(_ build: (inout InspectorMetadataText) -> Void) -> [String] {
        var t = InspectorMetadataText()
        build(&t)
        return t.lines
    }

    // MARK: primitives

    @Test func addSkipsEmptyValues() {
        #expect(lines { $0.add("Size", ""); $0.add("Codec", "h264") } == ["  Codec: h264"])
    }

    @Test func firstSectionHasNoLeadingBlankLaterOnesDo() {
        #expect(lines { $0.section("A"); $0.section("B") } == ["[A]", "", "[B]"])
    }

    // MARK: header

    @Test func headerShowsRatingTagsAndAvidOnlyWhenPresent() {
        let plain = Self.rec()
        #expect(lines { $0.header(plain) }.count == 3, "filename, stream type, volume only")
        let r = Self.rec()
        r.starRating = 2
        r.tags = ["x", "y"]
        r.avidClipName = "Clip"
        let out = lines { $0.header(r) }
        #expect(out.contains("  Rating: ★★"))
        #expect(out.contains("  Tags: x, y"))
        #expect(out.last == "  Clip: Clip", "Avid tape is empty so only the clip shows")
    }

    // MARK: technical sections

    @Test func technicalSectionsAlwaysShowTheirTitle() {
        let r = Self.rec()
        #expect(lines { $0.general(r) } == ["[General]"])
        #expect(lines { $0.video(r) } == ["[Video]"])
        #expect(lines { $0.audio(r) } == ["[Audio]"])
        #expect(lines { $0.timestamps(r) } == ["[Timestamps]"])
    }

    @Test func videoListsFieldsInInspectorOrder() {
        let r = Self.rec()
        r.scanType = "Interlaced"; r.resolution = "720x480"; r.videoCodec = "dvvideo"
        #expect(lines { $0.video(r) } == ["[Video]", "  Resolution: 720x480", "  Codec: dvvideo", "  Scan Type: Interlaced"])
    }

    @Test func yourDateSaysKnownOrBestGuess() {
        let r = Self.rec()
        #expect(InspectorMetadataText.yourDate(r) == nil)
        r.userDate = "1992"
        #expect(InspectorMetadataText.yourDate(r) == "1992 (best guess)")
        r.userDateConfidence = "known"
        #expect(InspectorMetadataText.yourDate(r) == "1992 (known)")
    }

    @Test func embeddedDateIsUTCWithOptionalSource() {
        let r = Self.rec()
        #expect(InspectorMetadataText.embeddedDate(r) == nil)
        r.embeddedCreationDate = Date(timeIntervalSince1970: 0)
        #expect(InspectorMetadataText.embeddedDate(r) == "1970-01-01 00:00 UTC")
        r.embeddedCreationSource = "mvhd"
        #expect(InspectorMetadataText.embeddedDate(r) == "1970-01-01 00:00 UTC (mvhd)")
    }

    // MARK: correlation / duplicates / avid / notes

    @Test func correlationOnlyWhenPairedOrScored() {
        let r = Self.rec()
        #expect(lines { $0.correlation(r) }.isEmpty)
        r.pairConfidence = .low
        #expect(lines { $0.correlation(r) } == ["[Correlation]", "  Confidence: Low"])
    }

    @Test func duplicatesHiddenWithoutFlagOrFootage() {
        #expect(lines { $0.duplicates(Self.rec(), .init()) }.isEmpty)
    }

    @Test func duplicateGroupListsMembersWithOfflineMark() {
        let r = Self.rec("me.avi")
        r.duplicateDisposition = .keep
        let m = Self.rec("copy.avi")
        m.duplicateDisposition = .extraCopy
        #expect(lines { $0.duplicateGroup(r, []) }.isEmpty)
        #expect(lines { $0.duplicateGroup(r, [m]) } == [
            "",
            "  Duplicate Group (2 total):",
            "    ★ me.avi  [CharzNeverMounted]  Keep",
            "    · copy.avi  [CharzNeverMounted] (offline)  Extra copy",
        ])
    }

    @Test func avidProjectEditRateOnlyWhenPositive() {
        let r = Self.rec()
        #expect(lines { $0.avidProject(r) }.isEmpty)
        r.avidMobID = "mob"
        #expect(lines { $0.avidProject(r) } == ["[Avid Project]", "  Mob ID: mob"])
        r.avidEditRate = 25
        #expect(lines { $0.avidProject(r) }.contains("  Edit Rate: 25.00 fps"))
    }

    @Test func yourNotesComeBeforeMachineNotes() {
        let r = Self.rec()
        r.notes = "probe"; r.userNotes = "mine"
        #expect(lines { $0.notes(r) } == ["[Your Notes]", "  mine", "", "[Notes]", "  probe"])
    }

    // MARK: dossier

    @Test func dossierOmittedWhenNothingToShow() {
        #expect(lines { $0.dossier(Self.rec()) }.isEmpty)
    }

    @Test func degenerateOCRDateAloneIsNotDossierContent() {
        let r = Self.rec()
        r.ocrDateCandidates = [SceneCaption(timestamp: 1, text: "!!!!!!!!!!!!")]
        #expect(!InspectorMetadataText.hasDossierContent(r, usableOCRDates: r.usableOCRDates))
        #expect(lines { $0.dossier(r) }.isEmpty)
    }

    @Test func timedListFormatsClockAndCount() {
        let out = lines { $0.timedList("OCR Text", [SceneCaption(timestamp: 3725, text: "HI")]) }
        #expect(out == ["", "  OCR Text (1):", "    [62:05] HI"])
        #expect(lines { $0.timedList("OCR Text", []) }.isEmpty)
    }

    @Test func transcriptKeepsBlankLines() {
        #expect(lines { $0.transcript("a\n\nb") } == ["", "  Audio Transcript:", "    a", "    ", "    b"])
        #expect(lines { $0.transcript("") }.isEmpty)
    }

    @Test func inferredDateYearOnlyWithConfidence() {
        let r = Self.rec()
        #expect(InspectorMetadataText.inferredDate(r) == nil)
        r.inferredRecordDate = Date(timeIntervalSince1970: 771_681_600)
        r.inferredDateRange = InferredDateRange(year: 1994)
        #expect(InspectorMetadataText.inferredDate(r) == "1994")
        r.inferredDateConfidence = 0.5
        #expect(InspectorMetadataText.inferredDate(r) == "1994 (confidence 0.50)")
    }

    @Test func processedNeedsBothWhoAndWhen() {
        let r = Self.rec()
        r.dossierProcessedBy = "model"
        #expect(InspectorMetadataText.processed(r) == nil)
        r.dossierProcessedAt = Date()
        #expect(InspectorMetadataText.processed(r)?.hasPrefix("model on ") == true)
        r.dossierProcessedBy = ""
        #expect(InspectorMetadataText.processed(r) == nil)
    }

    @Test func clockClampsNegativeAndPadsSeconds() {
        #expect(InspectorMetadataText.clock(-4) == "0:00")
        #expect(InspectorMetadataText.clock(65.9) == "1:05")
    }

    // MARK: location

    @Test func locationAlwaysShowsSignatureState() {
        #expect(lines { $0.location(Self.rec()) } == [
            "[Location]", "  Path: /Volumes/CharzNeverMounted/a.mov", "  File Signature: not computed yet",
        ])
    }

    // MARK: scale

    /// A record with a heavy dossier (2,000 captions + 2,000 OCR hits) copies
    /// in well under a frame's worth of a context-menu click.
    @Test func heavyDossierFormatsQuickly() {
        let r = Self.rec()
        r.sceneCaptions = (0..<2_000).map { SceneCaption(timestamp: Double($0), text: "caption \($0)") }
        r.ocrText = (0..<2_000).map { SceneCaption(timestamp: Double($0), text: "ocr \($0)") }
        let clock = ContinuousClock()
        var text = ""
        let elapsed = clock.measure { text = InspectorMetadataText.format(r) }
        #expect(text.contains("Scene Captions (2000):"))
        #expect(elapsed < .seconds(1), "\(elapsed)")
    }
}
