// HalliePronunciationGuardTests.swift
// GH #187 (2026-09-21): learned pronunciations may be for NAMES only. Two
// live defects came from poisoned entries in pronunciations.json —
// Edward → "III" ("III the Third") and see → "KY | OK" ("good to KYE
// you", ten days). These suites pin the write-time refusal, the
// apply-time ignore (never a delete), the names that must keep working,
// fixture-only isolation, and a sensor for both live defects.
//
// Every file here is a temp fixture; Rick's real pronunciations.json is
// never named.

import Foundation
import Testing
import VideoScanCore
@testable import VideoScan

// MARK: - Fixtures shared by the suites

private enum GuardFixture {
    /// The two live poisoned entries, byte-for-byte the shapes found in
    /// Rick's file (see: attested by owner 2026-09-11; Edward: told).
    static let liveDefectsJSON = #"""
    {
      "Edward": {"respelling": "III", "source": "told"},
      "see": {"attested": {"at": "2026-09-11T22:11:42Z", "by": "owner"},
              "phonemes": "kˈI", "respelling": "KY | OK", "source": "told"}
    }
    """#

    /// Live defects plus the legitimate names that must keep working, a
    /// common word Rick taught ("record"), and surnames that are English
    /// words ("Young" is on the closed list; "Lamb" is not).
    static let mixedJSON = #"""
    {
      "Edward": {"respelling": "III", "source": "told"},
      "see": {"attested": {"at": "2026-09-11T22:11:42Z", "by": "owner"},
              "phonemes": "kˈI", "respelling": "KY | OK", "source": "told"},
      "record": {"phonemes": "ɹˈɛkɔɹd", "respelling": "reh-cord", "source": "told"},
      "Caleb": "KAY-leb",
      "Stoughton": "STOE-tun",
      "beth": {"phonemes": "bˈɛθ", "respelling": "BETH", "source": "told"},
      "Young": "YUNG",
      "Lamb": "LAM",
      "Blank": {"respelling": " | ", "source": "told"}
    }
    """#

    static let graph = GedcomFamilyGraph(gedcomText: """
    0 HEAD
    0 @I1@ INDI
    1 NAME Mary /Young/
    1 SEX F
    0 @I2@ INDI
    1 NAME Edward /Plantagenet/
    1 SEX M
    0 @I3@ INDI
    1 NAME Will /Breen/
    1 SEX M
    0 @I4@ INDI
    1 NAME Adam /FitzHerbert/
    1 NAME Llanlowell Llan Hywel and see note
    1 SEX M
    0 @I5@ INDI
    1 NAME Caleb /Stoughton/
    1 SEX M
    0 TRLR
    """)

    /// A scratch directory holding a pronunciations.json with `json`.
    static func file(_ json: String) throws -> (url: URL, root: URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HalliePronunciationGuardTests-\(UUID().uuidString)", isDirectory: true)
        let url = root.appendingPathComponent("Hallie", isDirectory: true)
            .appendingPathComponent(HalliePronunciationLexicon.fileName)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json.utf8).write(to: url)
        return (url, root)
    }
}

// MARK: - Logic: the list, the verdict, the names

@Suite("Pronunciation guard — the rule")
struct HalliePronunciationGuardRuleTests {

    @Test func theClosedListCarriesTheEverydayWordsAndNotTheFamilyNames() {
        for word in ["see", "you", "to", "the", "and", "good", "it", "is", "are", "was", "record", "read",
                     "live", "I", "Your", "SEE"] {
            #expect(HalliePronunciationGuard.isCommonWord(word), Comment(rawValue: word))
        }
        for name in ["McGill", "Edith", "Caleb", "Stoughton", "Latta", "Beth", "Lamb", "Breen", "Edward",
                     "Nathaniel", "Ronan", "Donna"] {
            #expect(!HalliePronunciationGuard.isCommonWord(name), Comment(rawValue: name))
        }
        #expect(HalliePronunciationGuard.commonWords.count >= 300)
        // Every shipped entry is a name, never a common word.
        for entry in HalliePronunciationLexicon.shipped.entries {
            #expect(!HalliePronunciationGuard.isCommonWord(entry.written), Comment(rawValue: entry.written))
        }
    }

    @Test func aCommonWordIsRefusedUnlessSomebodyCarriesItAsAName() {
        let nobody: (String) -> Bool = { _ in false }
        #expect(HalliePronunciationGuard.refusal(written: "see", spoken: "KY | OK", phonemes: "kˈI",
                                                 isKnownName: nobody) == .commonWord("see"))
        #expect(HalliePronunciationGuard.refusal(written: "Young", spoken: "YUNG", phonemes: nil,
                                                 isKnownName: nobody) == .commonWord("Young"))
        #expect(HalliePronunciationGuard.refusal(written: "Young", spoken: "YUNG", phonemes: nil,
                                                 isKnownName: { $0 == "Young" }) == nil)
        // A name that is not on the list never consults the name source.
        #expect(HalliePronunciationGuard.refusal(written: "Latta", spoken: "LAT-uh", phonemes: nil,
                                                 isKnownName: { _ in
                                                     Issue.record("names consulted for a non-common word")
                                                     return false
                                                 }) == nil)
    }

    @Test func aRomanNumeralOrNothingIsNeverAPronunciation() {
        let anyone: (String) -> Bool = { _ in true }
        for bad in ["III", "III | ED-werd", "Ⅲ", "VIII", "III."] {
            #expect(HalliePronunciationGuard.refusal(written: "Edward", spoken: bad, phonemes: nil, isKnownName: anyone)
                    == .numeral(word: "Edward", spoken: HalliePronunciationLexicon.alternatives(bad)[0]),
                    Comment(rawValue: bad))
        }
        // Phonemes beside a numeral do not rescue it (they were derived from it).
        #expect(HalliePronunciationGuard.refusal(written: "Edward", spoken: "III", phonemes: "ˈɛdwɚd",
                                                 isKnownName: anyone) != nil)
        #expect(HalliePronunciationGuard.refusal(written: "Edward", spoken: " | ", phonemes: nil, isKnownName: anyone)
                == .empty("Edward"))
        // Single-letter sounds and ordinary syllables stay valid respellings.
        for good in ["I", "V", "X", "Vi", "LIV", "ED-werd"] {
            #expect(HalliePronunciationGuard.refusal(written: "Edward", spoken: good, phonemes: nil, isKnownName: anyone) == nil,
                    Comment(rawValue: good))
        }
    }

    @Test func knownNamesComeFromPeopleNotFromNotesOrTheLexicon() {
        let names = HallieKnownNames.from(graph: GuardFixture.graph)
        #expect(names.contains("Young"))
        #expect(names.contains("will"), "a capitalised forename in a primary name is a name")
        #expect(names.contains("FitzHerbert"))
        #expect(!names.contains("see"), "\"see\" inside a notes-style alias is not a name (GH #184 item 6)")
        #expect(!names.contains("and"))
        // Shipped family words are always known.
        #expect(HallieKnownNames.shipped.contains("Lamb"))
        #expect(HallieKnownNames.shipped.contains("Breen"))
        // Profiles and CyberBrain people count too.
        let more = HallieKnownNames.from(
            profiles: [(primary: "Hope Latta", aliases: ["Hopie"])],
            cyberBrainPeople: [CyberBrainPerson(id: "p.long", canonicalName: "Sarah Long", aliases: [])])
        #expect(more.contains("Hope") && more.contains("Hopie") && more.contains("Long"))
    }

    @Test func theRefusalSentencesAreHonest() {
        #expect(HalliePronunciationGuard.Refusal.commonWord("see").reply
                == "I keep pronunciations for names; \u{201C}see\u{201D} is an everyday word, so I left it alone.")
        #expect(HalliePronunciationGuard.Refusal.commonWord("see").ignoredLogLine
                == "[hallie-voice] ignored learned pronunciation for common word \u{201C}see\u{201D}")
        #expect(HalliePronunciationGuard.Refusal.numeral(word: "Edward", spoken: "III").reply.contains("Roman numeral"))
    }
}

// MARK: - Write time

@MainActor
@Suite("Pronunciation guard — write time", .serialized)
struct HalliePronunciationGuardWriteTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [HallieAppTurnCoordinator.PronunciationWrite] = []
        func append(_ value: HallieAppTurnCoordinator.PronunciationWrite) { lock.withLock { storage.append(value) } }
        var writes: [HallieAppTurnCoordinator.PronunciationWrite] { lock.withLock { storage } }
    }

    private func dependencies(_ recorder: Recorder) -> HallieAppTurnCoordinator.Dependencies {
        HallieAppTurnCoordinator.Dependencies(
            startLocalBrain: { $0 },
            translateAST: { _, _, _ in
                Issue.record("translation must not run for a pronunciation")
                throw NLTranslatorError.unreachable("fixture")
            },
            loadProfiles: { nil },
            loadGraph: { GuardFixture.graph },
            loadCyberBrain: { nil },
            recordPronunciation: { recorder.append($0) },
            saveDrillStore: { _, _ in },
            executeRequest: { _, _ in
                Issue.record("no catalog query for a pronunciation")
                throw NLTranslatorError.unreachable("fixture")
            },
            continueTurn: { _, _, _ in throw NLTranslatorError.unreachable("fixture") },
            resolveBiographyPhoto: { _ in nil })
    }

    private func run(_ question: String, _ recorder: Recorder) async throws -> HallieAppTurnCoordinator.Response {
        try await HallieAppTurnCoordinator.execute(
            question: question, records: [],
            referent: .init(recordID: nil, temporalDate: nil),
            hosts: ["fixture.invalid"], modelName: "fixture-model",
            telling: nil, dependencies: dependencies(recorder))
    }

    @Test func teachingAnEverydayWordIsRefusedWithTheHonestSentence() async throws {
        let recorder = Recorder()
        let response = try await run("see is pronounced KY", recorder)
        #expect(recorder.writes.isEmpty)
        #expect(response.result.prose
                == "I keep pronunciations for names; \u{201C}see\u{201D} is an everyday word, so I left it alone.")
        #expect(response.result.outcome == .declined)
        #expect(response.result.route == .telling)
    }

    @Test func theSharedTeachRefusesEverydayWordsAndNumeralsForEveryCaller() {
        let recorder = Recorder()
        let deps = dependencies(recorder)
        func refusal(_ result: Result<HallieAppTurnCoordinator.PronunciationTarget, Error>) -> HalliePronunciationGuard.Refusal? {
            if case .failure(let error) = result { return error as? HalliePronunciationGuard.Refusal }
            return nil
        }
        #expect(refusal(HallieAppTurnCoordinator.teach(word: "see", alternatives: ["KY", "OK"], dependencies: deps))
                == .commonWord("see"))
        #expect(refusal(HallieAppTurnCoordinator.teach(word: "record", alternatives: ["reh-cord"], dependencies: deps))
                == .commonWord("record"))
        #expect(refusal(HallieAppTurnCoordinator.teach(word: "Edward", alternatives: ["III"], phonemes: "ˈɪ",
                                                       dependencies: deps))
                == .numeral(word: "Edward", spoken: "III"))
        #expect(recorder.writes.isEmpty)
    }

    @Test func aSurnameThatIsAnEnglishWordIsTaughtWhenTheTreeCarriesIt() async throws {
        let recorder = Recorder()
        let response = try await run("say Young as YUNG", recorder)
        #expect(recorder.writes.map(\.word) == ["Young"])
        #expect(recorder.writes.first?.target == .treePerson(name: "Mary Young", gedcomID: "@I1@", aliases: []))
        #expect(response.result.prose.hasPrefix("OK, noted — Young."))
        // And an ordinary name is untouched by the guard.
        _ = try await run("say Caleb as KAY-leb", recorder)
        #expect(recorder.writes.map(\.word) == ["Young", "Caleb"])
    }

    /// The sentence that poisoned "see" on 2026-09-11 still writes nothing.
    @Test func theLiveKentuckySentenceWritesNothing() async throws {
        let recorder = Recorder()
        _ = try await run(#"when you see KY as a location in caps, it is OK, and recommended to pornounce it "Kentucky""#, recorder)
        #expect(recorder.writes.isEmpty)
    }
}

// MARK: - Load / apply time (fixture files only)

@Suite("Pronunciation guard — apply time", .serialized)
struct HalliePronunciationGuardApplyTests {

    private func resolve(_ url: URL, names: HallieKnownNames, once: HalliePronunciationGuard.OnceLog,
                         log: LogSink) -> HalliePronunciationLexicon {
        HalliePronunciationLexicon.resolved(
            fileURL: url, cyberBrainRootURL: nil, allowDefaultWrite: false,
            knownNames: names, ignoredLog: once, log: log)
    }

    @Test func poisonedEntriesAreIgnoredLoggedOnceAndNeverDeleted() throws {
        let (url, root) = try GuardFixture.file(GuardFixture.mixedJSON)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Data(contentsOf: url)
        let log = InMemoryLogSink(name: "test")
        let once = HalliePronunciationGuard.OnceLog()
        let names = HallieKnownNames.from(graph: GuardFixture.graph)

        let lexicon = resolve(url, names: names, once: once, log: log)
        _ = resolve(url, names: names, once: once, log: log)   // a second utterance

        let written = Set(lexicon.entries.map(\.written))
        #expect(!written.contains("see"))
        #expect(!written.contains("record"))
        #expect(!written.contains("Blank"))
        #expect(!written.contains("Edward"))
        #expect(written.isSuperset(of: ["Caleb", "Stoughton", "beth", "Young", "Lamb", "McGill", "Edith", "Latta"]))

        let seeLine = "[hallie-voice] ignored learned pronunciation for common word \u{201C}see\u{201D}"
        #expect(log.lines.filter { $0.contains(seeLine) }.count == 1, "one line per entry per launch")
        #expect(log.lines.filter { $0.contains("common word \u{201C}record\u{201D}") }.count == 1)
        #expect(log.lines.filter { $0.contains("\u{201C}Edward\u{201D}") && $0.contains("Roman numeral") }.count == 1)
        #expect(log.lines.filter { $0.contains("\u{201C}Blank\u{201D}") && $0.contains("empty") }.count == 1)
        // The file is Rick's: byte-identical after being read and guarded.
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func everydaySpeechIsUnchangedAndNamesStillApply() throws {
        let (url, root) = try GuardFixture.file(GuardFixture.mixedJSON)
        defer { try? FileManager.default.removeItem(at: root) }
        let lexicon = resolve(url, names: HallieKnownNames.from(graph: GuardFixture.graph),
                              once: .init(), log: InMemoryLogSink(name: "test"))
        for kokoro in [false, true] {
            #expect(HallieSpeaker.spokenText("It's good to see you.", lexicon: lexicon, phonemeLinks: kokoro)
                    == "It's good to see you.")
            #expect(HallieSpeaker.spokenText("Edward III was king.", lexicon: lexicon, phonemeLinks: kokoro)
                    == "Edward the Third was king.")
            #expect(HallieSpeaker.spokenText("Did you record the tape?", lexicon: lexicon, phonemeLinks: kokoro)
                    == "Did you record the tape?")
        }
        #expect(HallieSpeaker.spokenText("Caleb Stoughton met Beth McGill, Edith Latta and Mary Young and Lamb.",
                                         lexicon: lexicon)
                == "KAY-leb STOE-tun met BETH muh-GILL, EE-dith LAT-uh and Mary YUNG and LAM.")
    }

    @Test func aSurnameOnTheListIsIgnoredOnlyWhileNobodyCarriesIt() throws {
        let (url, root) = try GuardFixture.file(GuardFixture.mixedJSON)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = InMemoryLogSink(name: "test")
        let unknown = resolve(url, names: .shipped, once: .init(), log: log)
        #expect(HallieSpeaker.spokenText("Mary Young", lexicon: unknown) == "Mary Young")
        #expect(log.lines.contains { $0.contains("common word \u{201C}Young\u{201D}") })
        // Lamb is a shipped family word and not on the list: always applied.
        #expect(HallieSpeaker.spokenText("Muriel Lamb", lexicon: unknown) == "Muriel LAM")
    }

    /// A poisoned PERSON-layer entry (the GH #184 minting path) is ignored
    /// the same way, and a lower layer's entry for the word takes over.
    @Test func personLayerEntriesAreGuardedToo() {
        let people = [CyberBrainPerson(id: "p.adam", canonicalName: "Adam FitzHerbert",
                                       aliases: ["Llanlowell Llan Hywel and see note"],
                                       pronunciations: ["see": "KY | OK", "FitzHerbert": "FITZ-her-bert"])]
        let layer = HalliePronunciationLexicon.personLayer(people: people, log: nil)
        let log = InMemoryLogSink(name: "test")
        let names = HallieKnownNames.from(cyberBrainPeople: people)
        let guarded = layer.speakable(isKnownName: names.contains, ignoredLog: .init(), log: log)
        let merged = HalliePronunciationLexicon.merged([guarded, .shipped])
        #expect(HallieSpeaker.spokenText("It's good to see Adam FitzHerbert.", lexicon: merged)
                == "It's good to see Adam FITZ-her-bert.")
        #expect(log.lines.contains { $0.contains("common word \u{201C}see\u{201D}") })
    }
}

// MARK: - Isolation

@Suite("Pronunciation guard — isolation")
struct HalliePronunciationGuardIsolationTests {

    /// The voice's resolution seam, pointed at fixture roots, reads only
    /// the fixture: a word only the fixture carries fires, the poisoned
    /// entry is ignored, and a missing fixture file is not created in
    /// viewer mode (nothing global is written).
    @Test func theSpeakerSeamReadsOnlyTheInjectedFixture() throws {
        let (url, root) = try GuardFixture.file(#"{"Zanzibarr": "ZAN-zi-bar", "see": "KY | OK"}"#)
        let brainRoot = root.appendingPathComponent("cyberbrain", isDirectory: true)
        try FileManager.default.createDirectory(at: brainRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = InMemoryLogSink(name: "test")
        let lexicon = HallieSpeaker.resolvedLexicon(
            fileURL: url, cyberBrainRootURL: brainRoot, viewerMode: true,
            knownNames: .shipped, ignoredLog: .init(), log: log)
        #expect(HallieSpeaker.spokenText("Zanzibarr, good to see you.", lexicon: lexicon)
                == "ZAN-zi-bar, good to see you.")
        #expect(url.path != HalliePronunciationLexicon.defaultFileURL.path)

        let missing = root.appendingPathComponent("absent/Hallie/pronunciations.json")
        _ = HallieSpeaker.resolvedLexicon(
            fileURL: missing, cyberBrainRootURL: brainRoot, viewerMode: true,
            knownNames: .shipped, ignoredLog: .init(), log: log)
        #expect(!FileManager.default.fileExists(atPath: missing.deletingLastPathComponent().path))
    }

    /// A fresh OnceLog logs again; the shared one is never touched by tests.
    @Test func onceLogIsPerInstance() {
        let entry = HalliePronunciationLexicon.Entry(written: "see", spoken: "KY")
        let a = InMemoryLogSink(name: "a"), b = InMemoryLogSink(name: "b")
        let first = HalliePronunciationGuard.OnceLog()
        first.note(.commonWord("see"), entry: entry, log: a)
        first.note(.commonWord("see"), entry: entry, log: a)
        HalliePronunciationGuard.OnceLog().note(.commonWord("see"), entry: entry, log: b)
        #expect(a.lines.count == 1)
        #expect(b.lines.count == 1)
    }
}

// MARK: - Sensor: the two live defects

@Suite("Pronunciation guard — live defect sensor", .serialized)
struct HalliePronunciationGuardSensorTests {

    /// Rick's file as it stood before the hand fixes of 2026-09-21 (both
    /// poisoned entries), through the PRODUCTION resolution path — default
    /// known-name source, the sentence splitter, both voices. Hallie must
    /// say "see you" and "Edward the Third".
    @Test func aFileHoldingBothLiveDefectsSpeaksCorrectly() throws {
        let (url, root) = try GuardFixture.file(GuardFixture.liveDefectsJSON)
        let brainRoot = root.appendingPathComponent("cyberbrain", isDirectory: true)
        try FileManager.default.createDirectory(at: brainRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let log = InMemoryLogSink(name: "test")
        let lexicon = HallieSpeaker.resolvedLexicon(
            fileURL: url, cyberBrainRootURL: brainRoot, viewerMode: true,
            ignoredLog: .init(), log: log)
        let displayed = "It's good to see you. Edward III was king of England."
        for kokoro in [false, true] {
            #expect(HallieSpeaker.sentences(displayed, lexicon: lexicon, phonemeLinks: kokoro)
                    == ["It's good to see you.", "Edward the Third was king of England."])
        }
        #expect(displayed == "It's good to see you. Edward III was king of England.")
        #expect(!lexicon.entries.contains { $0.written == "see" || $0.written == "Edward" })
        #expect(log.lines.contains("[hallie-voice] ignored learned pronunciation for common word \u{201C}see\u{201D}"))
    }
}

// MARK: - Arrows in spoken text (Rick 2026-09-21)

@Suite("Hallie speaks arrows as words")
struct HallieSpokenArrowsTests {
    private let empty = HalliePronunciationLexicon(entries: [])

    @Test func thePlainLineOfDescentIsChildOf() {
        let displayed = "Line: Richard Harding Breen Jr → Richard Harding Breen Sr → Muriel Lamb → Edith Lucy Parker → …"
        #expect(HallieSpeaker.spokenText(displayed, lexicon: empty)
                == "Line: Richard Harding Breen Junior, child of Richard Harding Breen Senior, child of Muriel Lamb, child of Edith Lucy Parker …")
        #expect(displayed.contains("→"), "the displayed answer keeps its arrows")
    }

    @Test func theRelationLedChainIsWhoseRelationIs() {
        let displayed = "(Richard Harding Breen Jr → mother Eileen Latta → her father David McGill Latta Sr)"
        #expect(HallieSpeaker.spokenText(displayed, lexicon: empty)
                == "(Richard Harding Breen Junior, whose mother is Eileen Latta, whose father is David McGill Latta Senior)")
        #expect(HallieSpokenArrows.spoken("Rick's mother (Eileen Latta) → father (David Latta), but not his mother")
                == "Rick's mother (Eileen Latta), whose father is David Latta, but not his mother")
        #expect(HallieSpokenArrows.spoken("Rick → half-brother Tim → his great-grandmother Edith Parker")
                == "Rick, whose half-brother is Tim, whose great-grandmother is Edith Parker")
    }

    @Test func asciiAndDoubleArrowsAreTheSame() {
        #expect(HallieSpokenArrows.spoken("Line: Rick Breen -> Muriel Lamb -> Edith Lucy Parker")
                == "Line: Rick Breen, child of Muriel Lamb, child of Edith Lucy Parker")
        #expect(HallieSpokenArrows.spoken("Line: Rick Breen ⇒ Muriel Lamb ⇒ Edith Lucy Parker")
                == "Line: Rick Breen, child of Muriel Lamb, child of Edith Lucy Parker")
        #expect(HallieSpokenArrows.spoken("The recorded line: Rick Breen => Edward Plantagenet.")
                == "The recorded line: Rick Breen, child of Edward Plantagenet.")
    }

    @Test func anArrowOutsideALineageIsTo() {
        #expect(HallieSpokenArrows.spoken("1990 → 1995") == "1990 to 1995")
        #expect(HallieSpokenArrows.spoken("They moved Boston → Chicago.") == "They moved Boston to Chicago.")
        #expect(HallieSpokenArrows.spoken("→ Promote") == "Promote")
        let displayed = "Tapes from 1990 → 1995."
        let said = HallieSpeaker.spokenText(displayed, lexicon: empty)
        #expect(!said.contains("→"))
        #expect(said.contains(" to "))
        #expect(displayed == "Tapes from 1990 → 1995.")
        #expect(HallieSpokenArrows.spoken("No arrows at all.") == "No arrows at all.")
    }

    /// Through the whole speech path with the shipped table: no arrow
    /// symbol of any spelling survives into what the voice is handed.
    @Test func noArrowReachesTheVoice() {
        let displayed = "Line: Rick Breen → Muriel Lamb -> Edith Parker ⇒ Mary McGill ⟶ Ann Latta => Ronan"
        for kokoro in [false, true] {
            let sentences = HallieSpeaker.sentences(displayed, lexicon: .shipped, phonemeLinks: kokoro)
            for arrow in ["→", "->", "⇒", "⟶", "=>"] {
                #expect(!sentences.joined().contains(arrow), Comment(rawValue: arrow))
            }
            #expect(sentences.joined().components(separatedBy: "child of").count == 6)
        }
    }
}
