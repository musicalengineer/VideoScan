// EventCategoryRulesReviewRedTests.swift
// QA review of feat/events-v1 (2026-10-14): RED tests for the rule table.

import Testing
@testable import VideoScanCore

struct EventCategoryRulesReviewRedTests {

    private func evidence(_ transcript: String) -> [String: EventCategoryEvidence] {
        Dictionary(uniqueKeysWithValues: EventCategoryRules.evidence(captions: [], transcript: transcript, labels: [])
            .map { ($0.category, $0) })
    }

    /// Pins EventCategoryRules.swift:206, :215, :225, :232 against the
    /// file's own rule (:14-17, :118-120): the SAID list is "occasion
    /// phrases, never the bare name". "wedding", "vacation", "concert",
    /// "recital", "graduation", "diploma" are bare names.
    @Test("a bare mention of 'wedding' / 'vacation' / 'graduation' in speech is not the occasion")
    func bareNameInSpeechIsAMention() {
        #expect(evidence("remember our wedding, that was the summer of seventy nine")["Wedding"] == nil)
        #expect(evidence("we need a vacation after this")["Beach / vacation"] == nil)
        #expect(evidence("she has her graduation in june, we should go")["Graduation"] == nil)
        #expect(evidence("there's a concert downtown next week")["Music / performance"] == nil)
    }

    /// Round 2 — pins EventCategoryRules.swift `broadcastCues` after the
    /// P2-d rework: "remember" joined the SHARED cue list, so a greeting
    /// with "remember" within 48 characters is cancelled. "Remember to
    /// make a wish" is party speech, not a mention of another year.
    @Test("'happy birthday … remember to make a wish' is still a birthday")
    func rememberInPartySpeechDoesNotCancelTheGreeting() {
        #expect(evidence("happy birthday dear Timmy, remember to make a wish before you blow")["Birthday"]?.strength == .said)
        #expect(evidence("merry christmas everyone, remember to open the big one last")["Christmas"]?.strength == .said)
    }
}
