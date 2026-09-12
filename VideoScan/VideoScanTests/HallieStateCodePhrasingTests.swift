import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

/// GH #184 item 6: "David T. McGill was born in KY, 1843." Every route that
/// phrases a PLACE — biography vitals, the birthplace trail, the record's
/// hand-entered place — and the speech pass read a standalone US state
/// code as the state's name. Nothing stored changes.
@MainActor
struct HallieStateCodePhrasingTests {
    private static let tree = """
    0 HEAD
    0 @I19@ INDI
    1 NAME David T. /McGill/
    1 SEX M
    1 BIRT
    2 DATE 1843
    2 PLAC KY
    1 DEAT
    2 DATE 1906
    2 PLAC MS
    0 @I15@ INDI
    1 NAME Hallie Mae /McGill/
    1 SEX F
    1 BIRT
    2 DATE 1876
    2 PLAC Louisville, Jefferson, Kentucky, United States
    0 TRLR
    """
    private let graph = GedcomFamilyGraph(gedcomText: tree)

    @Test func biographyVitalsReadTheStateName() throws {
        let david = try #require(graph.people["@I19@"])
        #expect(HallieBiographyCard.vitalsClause(david) == "was born 1843 in Kentucky and died 1906 in Mississippi")
        #expect(HallieBiographyCard.vitalsAside(david) == ", born 1843 in Kentucky, died 1906 in Mississippi")
        let hallie = try #require(graph.people["@I15@"])
        #expect(HallieBiographyCard.vitalsClause(hallie) == "was born 1876 in Louisville, Jefferson, Kentucky, United States")
        // The tree's own value is untouched.
        #expect(david.birthPlace == "KY")
    }

    @Test func birthplaceTrailLinesReadTheStateName() throws {
        let david = try #require(graph.people["@I19@"])
        let step = LineageTrail.Step(generation: 3, person: david,
                                     birthplace: BirthplaceClassifier.classify("KY"), matchesStop: false)
        let line = HallieLineageAnswer.trailLine(step, number: 4, stop: .outsideCountry(BirthplaceClassifier.unitedStates))
        #expect(line.hasPrefix("4. David T. McGill — 1843, Kentucky"), Comment(rawValue: line))
        #expect(!line.contains(" KY"))
        #expect(HallieLineageAnswer.trailBornDetail(step) == "born 1843 in Kentucky")
        #expect(step.placeText == "KY")
    }

    @Test func theSpeechPassSaysTheStateForAStandaloneCode() {
        // (The shipped lexicon respells McGill, so only the place is pinned.)
        let spoken = HallieSpeaker.spokenText("David T. McGill was born in KY, 1843.")
        #expect(spoken.contains(" was born in Kentucky, "), Comment(rawValue: spoken))
        #expect(!spoken.contains("KY"))
        // Kokoro path too.
        let kokoro = HallieSpeaker.spokenText("She died in MS.", phonemeLinks: true)
        #expect(kokoro.contains("Mississippi"), Comment(rawValue: kokoro))
        // Never a name, a word, or a filename.
        #expect(HallieSpeaker.spokenText("Al Smith was born in Boston.") == "Al Smith was born in Boston.")
        #expect(HallieSpeaker.spokenText("it is OK, and recommended") == "it is OK, and recommended")
        #expect(!HallieSpeaker.spokenText("The file 2006_KY_trip.mov is untouched.").contains("Kentucky"))
        #expect(!HallieSpeaker.spokenText("I'm in it.").contains("Indiana"))
    }

    @Test func theRecordsHandEnteredPlaceIsPhrasedButNeverRewritten() {
        let snapshot = ArchivistRecordDossierSnapshot(
            presence: ArchivistPresenceRecordSnapshot(
                id: UUID(), fullPath: "/Volumes/Fixture/Cape_1993.mov", volumeName: "Fixture",
                streamTypeRaw: StreamType.videoAndAudio.rawValue,
                confirmedPeople: [], transcript: nil, transcriptModel: nil),
            userPlace: "Cape Cod, MA", userPlaceStatus: .known)
        let sentence = ArchivistRecordExecutor.placeSentence(snapshot)
        #expect(sentence.prose == "Cape_1993.mov was taken at Cape Cod, Massachusetts — you marked that as certain.",
                Comment(rawValue: sentence.prose))
        // Display/speech only: the stored place is exactly as Rick typed it.
        #expect(snapshot.userPlace == "Cape Cod, MA")
        #expect(snapshot.userPlaceStatus == .known)

        let guess = ArchivistRecordDossierSnapshot(
            presence: ArchivistPresenceRecordSnapshot(
                id: UUID(), fullPath: "/Volumes/Fixture/2006_KY_trip.mov", volumeName: "Fixture",
                streamTypeRaw: StreamType.videoAndAudio.rawValue,
                confirmedPeople: [], transcript: nil, transcriptModel: nil),
            userPlace: "Louisville KY", userPlaceStatus: .estimated)
        let guessed = ArchivistRecordExecutor.placeSentence(guess)
        #expect(guessed.prose == "2006_KY_trip.mov was taken at Louisville Kentucky, as your best guess.",
                Comment(rawValue: guessed.prose))
        #expect(guess.userPlace == "Louisville KY")
    }
}
