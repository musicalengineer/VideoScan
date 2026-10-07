// HallieBornYetQuestion.swift
// "were the boys born yet in 1990?" — a yes / no per person against a year
// the question states, answered by the temporal route with no model.
//
// Replay 2026-10-07: the translator read this sentence as a catalog search
// (shape=event one run, shape=presence the next) naming nobody, and the
// tree-mode gate declined it ("I couldn't tell who it is about"), while
// "how old were the boys in 1994?" — which the translator does read as
// temporal — answered. The born-yet arithmetic and the "the boys" →
// People-tab children resolution already existed (ArchivistTemporalExecutor
// .executeGroup, HallieTurnExecutor+TemporalSubjects); only the ROUTE was
// left to the model. This recogniser takes it away from the model for the
// one shape that is unambiguous: a born-yet verb phrase, a subject in front
// of it, and exactly one stated year.
//
// Deliberately narrow — it abstains (nil → the translator, as before) on:
//   • no born-yet wording (ArchivistTemporalExecutor.detectAsk decides, so
//     "was dan born in 1990" — a birth-year check — is not claimed);
//   • no year, or two years, or a "this / that / here" reference — those are
//     about the selected video ("were the boys born yet when this was shot")
//     and keep the translator's currentSelection road;
//   • a pronoun subject ("were they born yet in 1990") — memory resolves it;
//   • any media word ("were the boys born yet in the 1990 videos").

import Foundation

enum HallieBornYetQuestion {
    /// Most words a subject phrase may have ("my brother's two oldest boys").
    private static let maxSubjectWords = 5

    /// aux + SUBJECT + (already/even/yet)* (been)? born|alive|around … .
    /// The subject is the shortest run before the born-yet verb phrase.
    private static let shape =
        /^(?:(?:and|so|ok|okay|well|hey),?\s+)?(?:were|was|had|has|have)\s+(.+?)\s+(?:(?:already|even|yet)\s+)*(?:been\s+)?(?:born|alive|around|on the scene)\b/

    /// The temporal payload to run, or nil when the sentence is not this shape.
    static func detect(_ question: String) -> ArchivistQueryAST.Temporal? {
        let text = question.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: " ?.!"))
        guard !text.isEmpty,
              ArchivistTemporalExecutor.detectAsk(in: text) == .bornYet,
              let year = ArchivistTemporalExecutor.statedYear(in: text),
              ArchivistQueryAST.yearRange.contains(year),
              !HallieMediaVocabulary.containsMediaWord(text),
              let match = text.firstMatch(of: shape) else { return nil }
        let subject = String(match.1).trimmingCharacters(in: .whitespaces)
        let words = subject.split(separator: " ")
        guard !words.isEmpty, words.count <= maxSubjectWords,
              !HalliePronounContinuity.isThirdPersonPronoun(subject),
              !words.contains(where: { $0.allSatisfy(\.isNumber) }) else { return nil }
        return .init(subject: subject, operation: .age, reference: .explicitYear(year))
    }
}
