import Foundation
import Testing
@testable import VideoScan

/// The model-free one-video recogniser (2026-09-02). Positive rows are the
/// four live New Hampshire questions from the 2026-09-02 transcript plus the
/// selection forms; negative rows are the shapes that must keep their own
/// lanes (selection date, person age, catalog search, media actions).
@Suite("Family Archivist record questions")
struct ArchivistRecordQuestionTests {
    typealias Record = ArchivistQueryAST.Record

    private static let path =
        "/Volumes/SanDiskWorkspace/FromCheesegrater/QuicktimeMovies_AndOtherFormats/New Hampshire.mov"

    @Test(arguments: [
        // The four live questions (2026-09-02).
        ("can you examine this video New Hampshire and see if it has a date and who is in it?",
         Record(reference: .file(name: "New Hampshire"), operations: [.people, .date])),
        ("can you search the text of the file New Hampshire.mov for people's names, like tim, nancy, rick, donna, and a date?",
         Record(reference: .file(name: "New Hampshire.mov"), operations: [.people, .date],
                people: ["tim", "nancy", "rick", "donna"])),
        ("tell me all about this video, including the metadata whether it has rick in it: \(path)",
         Record(reference: .file(name: path), operations: [.about], people: ["rick"])),
        ("Examine the video New Hampshire.mov and see if it has my name in it?",
         Record(reference: .file(name: "New Hampshire.mov"), operations: [.people], people: ["me"])),
        // Selection forms.
        ("who else is in it", Record(reference: .currentSelection, operations: [.people])),
        ("what are the names in this video", Record(reference: .currentSelection, operations: [.people])),
        ("who is in this video", Record(reference: .currentSelection, operations: [.people])),
        ("Who's in this one?", Record(reference: .currentSelection, operations: [.people])),
        ("is Donna in this?", Record(reference: .currentSelection, operations: [.people], people: ["Donna"])),
        ("tell me about this video", Record(reference: .currentSelection, operations: [.about])),
        ("tell me everything about the selected video", Record(reference: .currentSelection, operations: [.about])),
        ("does it have my name in it", Record(reference: .currentSelection, operations: [.people], people: ["me"])),
        ("does this video have Donna and Rick in it?",
         Record(reference: .currentSelection, operations: [.people], people: ["Donna", "Rick"])),
        ("examine this video", Record(reference: .currentSelection, operations: [.about])),
        ("what's in this clip", Record(reference: .currentSelection, operations: [.people])),
        // Named files.
        ("who is in Christmas.mov", Record(reference: .file(name: "Christmas.mov"), operations: [.people])),
        ("who is in New Hampshire.mov", Record(reference: .file(name: "New Hampshire.mov"), operations: [.people])),
        ("when was New Hampshire.mov filmed", Record(reference: .file(name: "New Hampshire.mov"), operations: [.date])),
        ("New Hampshire.mov", Record(reference: .file(name: "New Hampshire.mov"), operations: [.about])),
        ("tell me about /Volumes/Archive/New Hampshire.mov",
         Record(reference: .file(name: "/Volumes/Archive/New Hampshire.mov"), operations: [.about])),
        ("who is in /Volumes/Archive/tape 3.mov",
         Record(reference: .file(name: "/Volumes/Archive/tape 3.mov"), operations: [.people])),
        ("is Donna and Rick in /Volumes/Archive/x.mov",
         Record(reference: .file(name: "/Volumes/Archive/x.mov"), operations: [.people], people: ["Donna", "Rick"])),
        ("who is in Christmas 1994 Part 2.mkv and when was it filmed",
         Record(reference: .file(name: "Christmas 1994 Part 2.mkv"), operations: [.people, .date])),
        ("does New Hampshire.mov have Nancy in it",
         Record(reference: .file(name: "New Hampshire.mov"), operations: [.people], people: ["Nancy"])),
    ] as [(String, Record)])
    func recognisesOneVideoQuestions(question: String, expected: Record) {
        let detected = ArchivistRecordQuestion.detect(question)
        #expect(detected == expected, Comment(rawValue: "\(question) → \(String(describing: detected))"))
    }

    @Test(arguments: [
        "show me New Hampshire videos",
        "matt is my son. timmy is my son. tim os my brother. I know it is confusing. I will fix it in the people tab. do you know the people in the people tab and can you read their names for me?",
        "can you read their names for me",
        "tell me about the people in the catalog",
        "what are their names",
        "who else was at the wedding, it was a big one",
        "how old is Donna here",
        "how old was Timmy in this",
        "when was this filmed",
        "what year is that from",
        "how long ago was that",
        "videos of dad",
        "play the first one",
        "show me Donna at the Cape",
        "tell me about Donna",
        "who is Donna",
        "who did Rick marry",
        "any others from that same trip?",
        "were the boys born yet when this was shot",
        "is there a video of the wedding",
        "how many videos are archived",
        "find videos from 1994",
        "hi Hallie",
        "what can you do",
    ])
    func leavesOtherShapesAlone(question: String) {
        #expect(ArchivistRecordQuestion.detect(question) == nil, Comment(rawValue: question))
    }

    @Test func fileReferenceIsExtractedExactlyIncludingSpacesAndPaths() {
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in New Hampshire.mov?")?.name == "New Hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "the file \"New Hampshire.mov\" please")?.name == "New Hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "look at \(Self.path) for me")?.name == Self.path)
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in Christmas 1994 Part 2.mkv")?.name == "Christmas 1994 Part 2.mkv")
        // A lowercase word before the core is not part of the name.
        #expect(ArchivistRecordQuestion.fileReference(in: "the video hampshire.mov")?.name == "hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "this video New Hampshire and see")?.name == "New Hampshire")
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in the picture") == nil)
    }

    @Test func peopleListDropsDateWordsAndQuestionWords() {
        let question = "can you search the text of the file New Hampshire.mov for people's names, like tim, nancy, rick, donna, and a date?"
        let detected = ArchivistRecordQuestion.detect(question)
        #expect(detected?.people == ["tim", "nancy", "rick", "donna"])
        let noNames = ArchivistRecordQuestion.detect("see if it has a date and who is in it")
        #expect(noNames?.people == nil)
        #expect(noNames?.operations == [.people, .date])
    }

    @Test func atMostSixNamesAreKept() {
        let detected = ArchivistRecordQuestion.detect(
            "is Ann, Bob, Cal, Dee, Eve, Fay, Gus and Hal in this video?")
        #expect(detected?.people?.count == ArchivistQueryAST.maxListItems)
    }
}
