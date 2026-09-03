// HallieProfileWhichOne.swift
// The which-one question for People-tab / CyberBrain identities, phrased
// so the person being asked can actually answer it.
//
// WHY (2026-09-03). "Which tim do you mean?" is a bug even when asking IS
// the right move: it names one spelling and offers nothing to choose
// between. Chips carry the choice in the UI, but voice, the shell CLI and
// the eval transcripts see only the sentence — and the sentence was empty
// of information. A which-one must always end in the candidates:
//
//     "Which Tim do you mean — Tim (born 1960) or Timmy (born 1996)?"
//
// The birth year is added only when it DISCRIMINATES: two candidates whose
// display names already differ read better without it, and a year nobody
// recorded cannot help anyone. Nothing here is specific to any family;
// the discriminator is chosen from the candidates that are actually in
// front of it.

import Foundation
import VideoScanCore

enum HallieProfileWhichOne {

    /// One candidate as the sentence should say it.
    struct Choice: Equatable, Sendable {
        let name: String
        /// Birth year, when the profile records one.
        var birthYear: Int?
        /// Last-resort discriminator when name AND year still collide
        /// (a duplicated gallery entry) — usually the stable id.
        var fallbackDetail: String?

        init(name: String, birthYear: Int? = nil, fallbackDetail: String? = nil) {
            self.name = name
            self.birthYear = birthYear
            self.fallbackDetail = fallbackDetail
        }

        init(name: String, birthdate: Date?, fallbackDetail: String? = nil) {
            self.init(name: name,
                      birthYear: HallieProfileWhichOne.year(of: birthdate),
                      fallbackDetail: fallbackDetail)
        }
    }

    static func year(of date: Date?) -> Int? {
        date.map { Calendar(identifier: .gregorian).component(.year, from: $0) }
    }

    /// Labels that tell the candidates apart, cheapest discriminator first:
    /// the name alone; then "name (born YYYY)"; then the fallback detail.
    ///
    /// The decision is made per label, not globally, so one undated profile
    /// among three dated ones does not strip the years off the other two.
    static func labels(_ choices: [Choice]) -> [String] {
        let nameCounts = Dictionary(grouping: choices) {
            PersonResolver.normalize($0.name)
        }.mapValues(\.count)

        return choices.map { choice in
            let key = PersonResolver.normalize(choice.name)
            guard nameCounts[key, default: 0] > 1 else { return choice.name }
            // The name is shared: a recorded birth year is the natural
            // discriminator (Rick's two Tims are 36 years apart).
            if let year = choice.birthYear {
                let sameYear = choices.filter {
                    PersonResolver.normalize($0.name) == key
                        && $0.birthYear == year
                }.count
                if sameYear == 1 { return "\(choice.name) (born \(year))" }
            }
            if let detail = choice.fallbackDetail, !detail.isEmpty {
                return "\(choice.name) (\(detail))"
            }
            return choice.birthYear.map { "\(choice.name) (born \($0))" }
                ?? choice.name
        }
    }

    /// The sentence for candidates that ALREADY carry distinguishing
    /// labels (the CyberBrain route's `bridgedLabel`, which reads
    /// "Richard Harding Breen (b. 4 JUL 1962)"). Wrapping those in a
    /// second name would say the name twice.
    static func prose(typed: String, labels: [String]) -> String {
        let shown = Array(Set(labels)).count == labels.count
            ? labels : PersonNameClaim.dedupe(labels)
        let name = HallieWhichOne.display(typed)
        guard shown.count > 1 else { return "Which \(name) do you mean?" }
        return "Which \(name) do you mean — "
            + HallieNameQualifier.joined(shown, conjunction: "or") + "?"
    }

    /// "Which Tim do you mean — Tim (born 1960) or Timmy (born 1996)?"
    ///
    /// The typed spelling is echoed through `HallieWhichOne.display`, so a
    /// lowercase "tim" is asked back as "Tim" — Hallie never says a name in
    /// a casing the family would not write.
    static func prose(typed: String, choices: [Choice]) -> String {
        let shown = labels(choices)
        let name = HallieWhichOne.display(typed)
        guard !shown.isEmpty else { return "Which \(name) do you mean?" }
        // A candidate label identical to the echoed name adds nothing;
        // "Which John do you mean — John or John?" is worse than the bare
        // question. Only reachable when the labeller had no discriminator.
        guard Set(shown).count > 1 else { return "Which \(name) do you mean?" }
        return "Which \(name) do you mean — "
            + HallieNameQualifier.joined(shown, conjunction: "or") + "?"
    }
}
