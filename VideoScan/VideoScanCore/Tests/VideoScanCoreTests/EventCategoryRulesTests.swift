// EventCategoryRulesTests.swift
// Events v1 — LOGIC for the pure category rule table
// (docs/design/events_v1_plan_2026_10_14.md §7): strength is a word from
// what the recording's own words say; a mention is not an occasion; a
// television's "Happy Birthday" is not a party; a folder name alone is
// "name only". Media matrix: not applicable — no media is opened here.

import Testing
@testable import VideoScanCore

struct EventCategoryRulesTests {

    private func caption(_ text: String, at t: Double = 95) -> SceneCaption { SceneCaption(timestamp: t, text: text) }

    private func evidence(captions: [SceneCaption] = [], transcript: String? = nil, labels: [EventLabel] = [])
    -> [String: EventCategoryEvidence] {
        Dictionary(uniqueKeysWithValues: EventCategoryRules.evidence(captions: captions, transcript: transcript, labels: labels)
            .map { ($0.category, $0) })
    }

    @Test("a cake with candles in a caption AND 'happy birthday' in the transcript is 'seen and said', with both lines")
    func seenAndSaidBirthdayIsStrong() {
        let e = evidence(captions: [caption("A young boy leans over a cake with lit candles while the family watches.")],
                         transcript: "okay everybody, happy birthday dear Timmy, happy birthday to you, blow them out")
        let birthday = e["Birthday"]
        #expect(birthday?.strength == .seenAndSaid)
        #expect(birthday?.strength.words == "seen and said")
        #expect(birthday?.lines.map(\.source) == [.caption, .transcript])
        #expect(birthday?.lines.first?.timestamp == 95)
        #expect(birthday?.lines.first?.words.contains("cake with lit candles") == true)
        #expect(birthday?.lines.last?.words.contains("happy birthday dear Timmy") == true)
        #expect(e.count == 1, "nothing else is suggested: \(e.keys.sorted())")
    }

    @Test("'happy birthday' sung on the television is a cancelled hit — the transcript alone proves nothing")
    func tvSaysHappyBirthdayIsWeak() {
        let tv = evidence(transcript: "they're singing happy birthday on the tv again, turn it down")
        #expect(tv["Birthday"] == nil, "a broadcast greeting is not evidence")
        // The same words, with a caption that saw the cake, still count as
        // seen (the caption is its own source); only the said half is cancelled.
        let withCake = evidence(captions: [caption("Children around a birthday cake with candles.")],
                                transcript: "they're singing happy birthday on the tv again")
        #expect(withCake["Birthday"]?.strength == .seen)
        #expect(withCake["Birthday"]?.lines.map(\.source) == [.caption])
    }

    @Test("'we'll see you at Christmas' and 'last Christmas' are mentions, not Christmas")
    func mentionsChristmasIsNotChristmas() {
        #expect(evidence(transcript: "we'll see you at christmas then, drive safe")["Christmas"] == nil)
        #expect(evidence(transcript: "remember last christmas when the tree fell over? merry christmas she said")["Christmas"] == nil,
                "'last christmas' sits within the cue window of the greeting")
        let real = evidence(transcript: "merry christmas everyone! go on, open your presents")
        #expect(real["Christmas"]?.strength == .said)
        #expect(real["Christmas"]?.lines.first?.source == .transcript)
        #expect(real["Christmas"]?.lines.first?.timestamp == nil, "transcripts are untimed in v1")
    }

    @Test("a caption of someone playing the piano on stage is 'seen' for Music / performance, nothing else")
    func musicPerformanceFromCaptionOnly() {
        let e = evidence(captions: [caption("A woman in a long dress is playing the piano on stage before an audience.", at: 12)])
        #expect(e.keys.sorted() == ["Music / performance"])
        #expect(e["Music / performance"]?.strength == .seen)
        #expect(e["Music / performance"]?.lines.first?.timestamp == 12)
        // A photograph of a concert is not a concert.
        let poster = evidence(captions: [caption("A framed photo of a band playing on stage hangs on the wall.")])
        #expect(poster["Music / performance"] == nil)
    }

    @Test("a folder called 'Xmas 1998' with no captions or speech is 'name only' — one line, one source")
    func folderNameAloneIsNameOnly() {
        let labels = EventLabeler.labels(day: nil, year: 1998, filename: "tape07.mov", fullPath: "/Volumes/Tapes/Xmas 1998/tape07.mov")
        let e = evidence(labels: labels)
        #expect(e.keys.sorted() == ["Christmas"])
        #expect(e["Christmas"]?.strength == .nameOnly)
        #expect(e["Christmas"]?.strength.words == "name only")
        // EventLabeler spells the word as it folds it (lowercase) — its own, pinned behaviour.
        #expect(e["Christmas"]?.lines == [EventEvidenceLine(source: .folderName, words: "folder name says 'xmas'")])
        // A trusted Dec 25 with no words at all is "date only".
        let day = EventLabeler.labels(day: EventDay(year: 1998, month: 12, day: 25), year: 1998,
                                      filename: "clip.mov", fullPath: "/Volumes/Tapes/1998/clip.mov")
        #expect(evidence(labels: day)["Christmas"]?.strength == .dateOnly)
        // Word boundaries: "beaches" is beach, "capes" is not a Cape trip word in a caption.
        #expect(evidence(captions: [caption("Waves roll onto two beaches.")])["Beach / vacation"] == nil,
                "a caption phrase matches whole words only")
        #expect(evidence(captions: [caption("Children build a sandcastle at the beach.")])["Beach / vacation"]?.strength == .seen)
    }

    @Test("the table has the nine categories, in the page's order, and compatibility is the documented rule")
    func tableShapeAndCompatibility() {
        #expect(EventCategory.all.map(\.name) == ["Birthday", "Christmas", "Thanksgiving", "Easter", "Halloween", "Wedding",
                                                  "Beach / vacation", "Music / performance", "Graduation"])
        #expect(EventCategory.compatible("Birthday", "Birthday"))
        #expect(EventCategory.compatible("Birthday", "Beach / vacation"), "a vacation may contain a birthday")
        #expect(EventCategory.compatible("Music / performance", "Christmas"), "carols at Christmas")
        #expect(!EventCategory.compatible("Christmas", "Thanksgiving"))
        #expect(!EventCategory.compatible("Birthday", "Christmas"), "conservative in v1")
        #expect(!EventCategory.compatible("Music / performance", "Halloween"))
        for c in EventCategory.all {
            #expect(!c.seen.isEmpty && !c.said.isEmpty, "\(c.name) has seen and said phrases")
            #expect(c.seen.allSatisfy { $0 == $0.lowercased() } && c.said.allSatisfy { $0 == $0.lowercased() },
                    "\(c.name) phrases are lowercase")
        }
    }
}
