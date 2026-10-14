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
}
