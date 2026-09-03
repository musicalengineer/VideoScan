import Foundation
import Testing
@testable import VideoScan

/// The model-free one-video recogniser (2026-09-02). Positive rows are the
/// four live New Hampshire questions from the 2026-09-02 transcript plus the
/// selection forms; negative rows are the shapes that must keep their own
/// lanes (selection date, person age, catalog search, media actions).
/// codex #987: search openers are judged by their object (item 2), explicit
/// paths are verbatim and bare filenames stop only at hard boundaries
/// (item 3), and "this video" is the deictic hint (item 5).
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
        // Lowercase multiword names and paths (codex #976 item 4): the
        // name is the run of words up to the extension, not just the last
        // capitalised ones.
        ("who is in new hampshire.mov", Record(reference: .file(name: "new hampshire.mov"), operations: [.people])),
        ("tell me about /volumes/archive/new hampshire.mov",
         Record(reference: .file(name: "/volumes/archive/new hampshire.mov"), operations: [.about])),
        ("who is in /Volumes/A/the new hampshire.mov",
         Record(reference: .file(name: "/Volumes/A/the new hampshire.mov"), operations: [.people])),
        ("is Donna in christmas 1994 part 2.mkv",
         Record(reference: .file(name: "christmas 1994 part 2.mkv"), operations: [.people], people: ["Donna"])),
        ("does new hampshire.mov have Nancy in it",
         Record(reference: .file(name: "new hampshire.mov"), operations: [.people], people: ["Nancy"])),
        // Legal filenames with ordinary words are never truncated (codex
        // #987 item 3); paths whose folders read like a sentence are
        // verbatim.
        ("who is in rick and donna.mov", Record(reference: .file(name: "rick and donna.mov"), operations: [.people])),
        ("is donna in rick and donna.mov",
         Record(reference: .file(name: "rick and donna.mov"), operations: [.people], people: ["donna"])),
        ("who is in /Volumes/A/Who is This/tape.mov",
         Record(reference: .file(name: "/Volumes/A/Who is This/tape.mov"), operations: [.people])),
        ("tell me about /Volumes/A/Who is This/tape.mov",
         Record(reference: .file(name: "/Volumes/A/Who is This/tape.mov"), operations: [.about])),
        ("is Donna in /Volumes/A/Who is This/tape one.mov",
         Record(reference: .file(name: "/Volumes/A/Who is This/tape one.mov"), operations: [.people], people: ["Donna"])),
        // A file named beside a knowledge-lane phrase is still a file.
        ("who is in Breen surname origin.mov",
         Record(reference: .file(name: "Breen surname origin.mov"), operations: [.people])),
        // codex #1020 item 3 (verbatim sentences): quotes take precedence
        // and unquoted legal filenames survive in the referent slot.
        ("who is in \"Who Is This.mov\"", Record(reference: .file(name: "Who Is This.mov"), operations: [.people])),
        ("who is in Will and Grace.mov", Record(reference: .file(name: "Will and Grace.mov"), operations: [.people])),
        ("is Donna in Who Is This.mov",
         Record(reference: .file(name: "Who Is This.mov"), operations: [.people], people: ["Donna"])),
        ("who is in 'Will and Grace.mov'?", Record(reference: .file(name: "Will and Grace.mov"), operations: [.people])),
        ("tell me about [x.mov]", Record(reference: .file(name: "x.mov"), operations: [.about])),
        ("who is in “Who Is This.mov”", Record(reference: .file(name: "Who Is This.mov"), operations: [.people])),
        ("does Who Is This.mov have Donna in it",
         Record(reference: .file(name: "Who Is This.mov"), operations: [.people], people: ["Donna"])),
        // codex #1020 item 2 (verbatim): the name is handed over as typed;
        // the resolver, not the recogniser, says whether it exists.
        ("who is in Unknown Tape.mov", Record(reference: .file(name: "Unknown Tape.mov"), operations: [.people])),
        // Pronoun-only date / metadata asks with the noun BESIDE the
        // referent (codex #976 item 5).
        ("what is the date of it", Record(reference: .currentSelection, operations: [.date])),
        ("what's the date on this one", Record(reference: .currentSelection, operations: [.date])),
        ("does it have a date", Record(reference: .currentSelection, operations: [.date])),
        ("is this dated", Record(reference: .currentSelection, operations: [.date])),
        ("show the metadata for this video", Record(reference: .currentSelection, operations: [.about])),
        ("what's in this video and what is its date",
         Record(reference: .currentSelection, operations: [.people, .date])),
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
        // Capability / general asks with a stray pronoun or a date word
        // NOT beside the referent (codex #976 item 5).
        "what can you do with it",
        "can you tell me the date on things",
        "can you tell me the metadata you keep",
        "what metadata do you keep about videos",
        "do you keep dates for videos",
        "is it possible to get the date",
        "what do you know about dates",
        "can you change the date on things",
        "it would be nice to know the dates",
        // A pronoun plus a capitalised word is not a record question
        // without a record verb (eval sm022 hit the record route; on
        // d3725558 it then reached the model as a presence search — the
        // small-talk table now answers it, and its siblings, first).
        "It's pouring rain here in the Berkshires today.",
        "beautiful day out isn't it",
        "Supposed to snow tonight. First one of the year.",
        "Donna and I loved it in the Berkshires",
        "that was the year Tim was born",
        // The surname lane's own shape, with no file in it.
        "where does the Breen surname come from",
    ])
    func leavesOtherShapesAlone(question: String) {
        #expect(ArchivistRecordQuestion.detect(question) == nil, Comment(rawValue: question))
    }

    /// codex #987 item 2: a search opener followed by a GENERAL object —
    /// plural media nouns, "everything", a person, a year, a decade — is a
    /// search, not ours.
    @Test(arguments: [
        "show me videos of Donna",
        "find clips from 1994",
        "list the photos from the 90s",
        "search for footage of the Cape",
        "show me everything from 1994",
        "find Donna at the Cape",
        "show me all the files on LaCie",
        "list videos with Tim in them",
        "show me the movies from the 80s",
        "find recordings of Dad",
        "search for Christmas",
        "hallie, show me pictures of the boys",
        "please find everything with Donna in it",
    ])
    func searchOpenersWithAGeneralObjectStaySearches(question: String) {
        #expect(ArchivistRecordQuestion.detect(question) == nil, Comment(rawValue: question))
    }

    /// … while the same openers followed by a record noun beside a
    /// referent are record questions.
    @Test(arguments: [
        ("show me metadata for this video", Record(reference: .currentSelection, operations: [.about])),
        ("find the date for this video", Record(reference: .currentSelection, operations: [.date])),
        ("show me who is in it", Record(reference: .currentSelection, operations: [.people])),
        ("list the names in this video", Record(reference: .currentSelection, operations: [.people])),
        ("show me the details on this one", Record(reference: .currentSelection, operations: [.about])),
        ("search for the date in it", Record(reference: .currentSelection, operations: [.date])),
        ("show me everything about this video", Record(reference: .currentSelection, operations: [.about])),
        ("find out who is in New Hampshire.mov", Record(reference: .file(name: "New Hampshire.mov"), operations: [.people])),
        ("find the metadata for New Hampshire.mov", Record(reference: .file(name: "New Hampshire.mov"), operations: [.about])),
        ("show me the people in this one", Record(reference: .currentSelection, operations: [.people])),
        ("hallie, show me the metadata for this clip", Record(reference: .currentSelection, operations: [.about])),
    ] as [(String, Record)])
    func searchOpenersWithARecordObjectAreRecordQuestions(question: String, expected: Record) {
        let detected = ArchivistRecordQuestion.detect(question)
        #expect(detected == expected, Comment(rawValue: "\(question) → \(String(describing: detected))"))
    }

    @Test func fileReferenceIsExtractedExactlyIncludingSpacesAndPaths() {
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in New Hampshire.mov?")?.name == "New Hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "the file \"New Hampshire.mov\" please")?.name == "New Hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "look at \(Self.path) for me")?.name == Self.path)
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in Christmas 1994 Part 2.mkv")?.name == "Christmas 1994 Part 2.mkv")
        // A hard boundary before the core is not part of the name; a plain
        // lowercase word is (codex #976 item 4).
        #expect(ArchivistRecordQuestion.fileReference(in: "the video hampshire.mov")?.name == "hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in new hampshire.mov")?.name == "new hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "does new hampshire.mov have Nancy in it")?.name == "new hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "is Donna in christmas 1994 part 2.mkv")?.name == "christmas 1994 part 2.mkv")
        #expect(ArchivistRecordQuestion.fileReference(in: "the file \"new hampshire.mov\" please")?.name == "new hampshire.mov")
        // A path is verbatim from its "/" head, whatever words its folders hold.
        #expect(ArchivistRecordQuestion.fileReference(in: "tell me about /volumes/archive/new hampshire.mov")?.name
                == "/volumes/archive/new hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in /Volumes/A/the new hampshire.mov")?.name
                == "/Volumes/A/the new hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in /Volumes/A/rick and donna/tape.mov")?.name
                == "/Volumes/A/rick and donna/tape.mov")
        // A "/" word separated from the core by a sentence verb or a
        // punctuation break is not its head.
        #expect(ArchivistRecordQuestion.fileReference(in: "check /Volumes/A and tell me who is in new hampshire.mov")?.name
                == "new hampshire.mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "is /Volumes/A mounted? who is in new hampshire.mov")?.name
                == "new hampshire.mov")
        // A bare ".mov" after a space is the tail of a spaced name.
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in Long Sequence - New Hampshire Christmas .mov")?.name
                == "Long Sequence - New Hampshire Christmas .mov")
        #expect(ArchivistRecordQuestion.fileReference(in: "this video New Hampshire and see")?.name == "New Hampshire")
        #expect(ArchivistRecordQuestion.fileReference(in: "who is in the picture") == nil)
    }

    /// codex #987 item 3: ordinary words are legal filename words and are
    /// kept. codex #1020 item 3: the run is placed by SYNTAX POSITION —
    /// everything after the last boundary phrase (a verb / preposition /
    /// naming slot of the recogniser's own patterns, an opener at a clause
    /// start, a punctuation break) that ends before the extension — never
    /// by a word blacklist, so "Will and Grace.mov" and "Who Is This.mov"
    /// survive in the referent slot; "is donna in rick and donna.mov"
    /// starts after the "is … in" slot. A swallowed sentence word ("the
    /// christmas tape.mov") is handed over as typed; the resolver reports
    /// it not found and offers the tail file by its own name.
    @Test(arguments: [
        ("who is in rick and donna.mov", "rick and donna.mov"),
        ("is donna in rick and donna.mov", "rick and donna.mov"),
        ("does rick and donna.mov have Tim in it", "rick and donna.mov"),
        ("who is in trip to maine.mov", "trip to maine.mov"),
        ("who is in christmas at the cape.mov", "christmas at the cape.mov"),
        ("who is in my birthday.mov", "my birthday.mov"),
        ("when was rick and donna.mov filmed", "rick and donna.mov"),
        ("tell me about the christmas tape.mov", "the christmas tape.mov"),
        ("who is in Breen surname origin.mov", "Breen surname origin.mov"),
        // Hard boundaries: question words, auxiliaries, naming words,
        // imperatives, punctuation.
        ("examine rick and donna.mov", "rick and donna.mov"),
        ("hallie, who's in rick and donna.mov", "rick and donna.mov"),
        ("the file called rick and donna.mov", "rick and donna.mov"),
        ("the video rick and donna.mov", "rick and donna.mov"),
        ("what does rick and donna.mov show", "rick and donna.mov"),
        ("who is in it: rick and donna.mov", "rick and donna.mov"),
        ("tell me about this tape.mov", "tape.mov"),
        // codex #1020 item 3 (verbatim): legal filenames made of sentence
        // words survive when they sit in the referent slot.
        ("who is in Will and Grace.mov", "Will and Grace.mov"),
        ("is Donna in Who Is This.mov", "Who Is This.mov"),
        ("does Who Is This.mov have Donna in it", "Who Is This.mov"),
        ("who is in All About Eve.mov", "All About Eve.mov"),
        ("who is in Trip to Maine and Back.mov", "Trip to Maine and Back.mov"),
        ("is Rick and Donna in Who Is This.mov", "Who Is This.mov"),
        ("what's in Will and Grace.mov", "Will and Grace.mov"),
        ("when was Who Is This.mov filmed", "Who Is This.mov"),
        ("hallie, please examine Will and Grace.mov", "Will and Grace.mov"),
        ("the file called Who Is This.mov", "Who Is This.mov"),
        // codex #1020 item 2 (verbatim): the run is as typed, never trimmed.
        ("who is in Unknown Tape.mov", "Unknown Tape.mov"),
        ("Will and Grace.mov", "Will and Grace.mov"),
    ])
    func bareFilenamesArePlacedBySyntaxPosition(question: String, name: String) {
        #expect(ArchivistRecordQuestion.fileReference(in: question)?.name == name, Comment(rawValue: question))
    }

    /// codex #1020 item 3 (verbatim: "`who is in \"Who Is This.mov\"`
    /// extracts This.mov"): a quoted or bracketed name is the text between
    /// the delimiters, verbatim, whatever words it holds and whatever
    /// sentence punctuation follows the closer; the reference's range
    /// spans the delimiters so the masked sentence still reads as a record
    /// question.
    @Test(arguments: [
        ("who is in \"Who Is This.mov\"", "Who Is This.mov"),
        ("who is in \"Who Is This.mov\"?", "Who Is This.mov"),
        ("who is in 'Will and Grace.mov'", "Will and Grace.mov"),
        ("who is in “Who Is This.mov”", "Who Is This.mov"),
        ("who is in ‘tell me about it.mov’!", "tell me about it.mov"),
        ("tell me about [x.mov]", "x.mov"),
        ("tell me about [who is in x.mov]", "who is in x.mov"),
        ("is Donna in (Who Is This.mov)", "Who Is This.mov"),
        ("the file \"New Hampshire.mov\" please", "New Hampshire.mov"),
        ("\"tape.mov\"", "tape.mov"),
        // A stray closer with no opener falls back to the syntax rule.
        ("who is in Who Is This.mov\"", "Who Is This.mov"),
    ])
    func quotedNamesAreVerbatim(question: String, name: String) {
        let reference = ArchivistRecordQuestion.fileReference(in: question)
        #expect(reference?.name == name, Comment(rawValue: question))
    }

    @Test func aQuotedNameMasksItsDelimitersSoTheVerbStillSeesTheReferent() {
        let reference = ArchivistRecordQuestion.fileReference(in: "who is in \"Who Is This.mov\"?")
        #expect(reference.map { String("who is in \"Who Is This.mov\"?"[$0.range]) } == "\"Who Is This.mov\"")
        let detected = ArchivistRecordQuestion.detect("who is in \"Who Is This.mov\"?")
        #expect(detected?.reference == .file(name: "Who Is This.mov"))
        #expect(detected?.operations == [.people])
        #expect(detected?.people == nil)
    }

    /// codex #987 item 3: a path is verbatim from its leading "/" to the
    /// extension — sentence verbs and stop words inside its folders never
    /// truncate it.
    @Test(arguments: [
        ("who is in /Volumes/A/Who is This/tape.mov", "/Volumes/A/Who is This/tape.mov"),
        ("who is in /Volumes/A/Who is This/tape one.mov", "/Volumes/A/Who is This/tape one.mov"),
        ("tell me about /Volumes/A/what does it show/tape.mov", "/Volumes/A/what does it show/tape.mov"),
        ("is Donna in /Volumes/LaCie/tell me who/in the file/x.mov", "/Volumes/LaCie/tell me who/in the file/x.mov"),
        ("/Volumes/A/Who is This/tape.mov", "/Volumes/A/Who is This/tape.mov"),
        ("look at /Users/rick/Movies/is this it/tape.mov please", "/Users/rick/Movies/is this it/tape.mov"),
    ])
    func explicitPathsAreVerbatim(question: String, path: String) {
        #expect(ArchivistRecordQuestion.fileReference(in: question)?.name == path, Comment(rawValue: question))
    }

    /// A lowercase full path survives the trip through the recogniser,
    /// and every chip the ambiguity / missing-path declines generate
    /// (ArchivistRecordExecutor.question(for:path:)) detects as a record
    /// question about exactly that path (codex #976 items 3, 4, 6; codex
    /// #987 item 3 for the sentence-like folders and filenames).
    @Test(arguments: [
        "/volumes/archive/new hampshire.mov",
        "/Volumes/SanDiskWorkspace/FromCheesegrater/QuicktimeMovies_AndOtherFormats/New Hampshire.mov",
        "/Volumes/LaCie/1994-xx-xx_Westford_1994-1995.mkv",
        "/Volumes/A/rick and donna/christmas 1994 part 2.mkv",
        "/Volumes/A/Long Sequence - New Hampshire Christmas .mov",
        "/Users/rick/Movies/tape.mov",
        "/Volumes/A/Who is This/tape.mov",
        "/Volumes/A/Who is This/tape one.mov",
        "/Volumes/A/rick and donna.mov",
        "/Volumes/A/what does it show/who is in it.mov",
        "/Volumes/A/Who Is This.mov",
        "/Volumes/A/Will and Grace.mov",
        "/Volumes/A/Café.mov",
    ])
    func chipQuestionsRoundTripThroughDetect(path: String) {
        let shapes: [(ArchivistQueryAST.Record, [Record.Operation], [String]?)] = [
            (Record(reference: .file(name: "x"), operations: [.people]), [.people], nil),
            (Record(reference: .file(name: "x"), operations: [.people], people: ["Donna", "Rick"]), [.people], ["Donna", "Rick"]),
            (Record(reference: .file(name: "x"), operations: [.date]), [.date], nil),
            (Record(reference: .file(name: "x"), operations: [.people, .date]), [.people, .date], nil),
            (Record(reference: .file(name: "x"), operations: [.about]), [.about], nil),
        ]
        for (query, operations, people) in shapes {
            let chip = ArchivistRecordExecutor.question(for: query, path: path)
            let detected = ArchivistRecordQuestion.detect(chip)
            #expect(detected?.reference == .file(name: path), Comment(rawValue: chip))
            #expect(detected?.operations == operations, Comment(rawValue: chip))
            #expect(detected?.people == people, Comment(rawValue: chip))
        }
    }

    /// codex #987 item 5: the deictic hint is a selection NOUN, never a
    /// bare "it" or "this".
    @Test func mentionsSelectionNeedsASelectionNoun() {
        for question in [
            "can you examine this video New Hampshire and see if it has a date",
            "who is in this one, New Hampshire.mov",
            "tell me about the selected video",
            "is Donna in this clip",
            "who is in that tape",
        ] {
            #expect(ArchivistRecordQuestion.mentionsSelection(question), Comment(rawValue: question))
        }
        for question in [
            "who is in New Hampshire.mov",
            "who is in it",
            "is Donna in this?",
            "who is in /Volumes/A/New Hampshire.mov",
            "does it have a date",
        ] {
            #expect(!ArchivistRecordQuestion.mentionsSelection(question), Comment(rawValue: question))
        }
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
