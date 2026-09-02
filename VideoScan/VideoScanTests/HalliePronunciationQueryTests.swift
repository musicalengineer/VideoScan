// HalliePronunciationQueryTests.swift
// "say <name> again" is a read-back, not a search refinement (live 9/02).
import Testing
@testable import VideoScan

@Suite("Pronunciation read-back requests")
struct HalliePronunciationQueryTests {
    @Test(arguments: [
        ("say stoughton again", "stoughton"),
        ("say Stoughton", "Stoughton"),
        ("Say Beth one more time", "Beth"),
        ("please pronounce Latta", "Latta"),
        ("hallie, say McGill again please", "McGill"),
        ("how do you say McGill", "McGill"),
    ])
    func readBackNamesAreDetected(question: String, name: String) {
        #expect(HalliePronunciationQuery.detect(question) == .name(name), Comment(rawValue: question))
    }

    @Test(arguments: [
        "say Edith as EE-dith",          // the drill's correction form
        "say it like MahGill",           // the drill's correction form
        "say it again",                  // no name
        "show videos of matt being born",
        "read me the pronunciations",    // the list, not a name
    ])
    func correctionsAndSearchesAreNotReadBacks(question: String) {
        let detected = HalliePronunciationQuery.detect(question)
        #expect(detected == nil || detected == .list, Comment(rawValue: question))
    }
}
