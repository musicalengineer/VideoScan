// ArchiveAngel+Occasions.swift
// The façade's front door for ONE question another feature may ask the
// Angel: "what occasion is this clip, and on which trusted day?"
// (2026-10-03 — the Triage steward's Events lane asked it by naming the
// Angel's inside: ArchiveAngelEvent, ArchiveAngelCandidate,
// ArchiveAngelEventContext, AngelCoverageRules. ArchiveAngelBoundarySensorTests
// went red; this is the door it should have used.)
//
// The answer is the Angel's ONE derivation — `ArchiveAngelEvent.derive`
// over RecordDateResolver and VideoScanCore.EventLabeler, the same call
// behind the Angel's event key and its Occasion line. Nothing here labels
// or dates anything itself; it only carries the question in and the answer
// out as plain values:
//
//   OccasionFacts   exactly the date and name facts the derivation reads.
//   Occasions       the labels (VideoScanCore's EventLabel), the trusted
//                   day as a TYPED EventDay (nobody outside parses the
//                   Angel's event key), the year that may name an occasion,
//                   whether a person typed the date, and whether the file
//                   is a Live Photo's motion half.
//   OccasionReader  the policy's birthday window and the People tab's
//                   birthdays, captured BY VALUE on the main actor
//                   (`archiveAngel.occasionReader`), then usable from any
//                   thread. The labels are always ON for a reader: a policy
//                   that turns the Angel's event labels off changes what
//                   the Angel spreads a batch over, not what an occasion
//                   is. The Angel's own policy is never touched.
//
// COST. One `ArchiveAngelCandidate` on the stack and one `derive` per call
// (O(characters) of the name; each folder's words once per `folders` memo).
// The reader allocates nothing of its own per call.
//
// (For Rick: the three structs are nested in the façade's namespace, like
// `ArchiveAngel::OccasionReader` in C++ — outsiders name only the façade.
// Nested types do NOT inherit the class's @MainActor; these are plain
// Sendable values, ≈ const PODs passed across threads.)

import Foundation
import VideoScanCore

extension ArchiveAngel {

    /// What the Angel's occasion derivation reads about one clip.
    struct OccasionFacts: Sendable, Equatable {
        var id: UUID
        var filename: String
        var fullPath: String
        /// A person's date ("1994", "1994-12", "1994-12-25") and how sure they were.
        var userDate: String?
        var userDateConfidence: String?
        /// The container's creation stamp, and the camera / software behind it.
        var embeddedDate: Date?
        var originMake: String?
        var originModel: String?
        var originEncoder: String?
        /// The dossier's inferred date, its confidence and its year range.
        var inferredDate: Date?
        var inferredConfidence: Float?
        var inferredRange: InferredDateRange?
    }

    /// The Angel's answer for one clip.
    struct Occasions: Sendable, Equatable {
        /// The labeller's labels, in its own order. A name word on a clip
        /// whose year is unknown (or only a copy-era stamp's) has no year:
        /// it explains, it keys nothing.
        var labels: [EventLabel] = []
        /// The day the clip is trusted to record — the day in the Angel's
        /// event key; nil when the key carries none.
        var day: EventDay?
        /// The year the clip is trusted to record, at any precision; nil
        /// when nothing dates it, or only a stamp with no camera behind it
        /// does (that dates the COPY — the Angel lends its year to nothing).
        var year: Int?
        /// A person typed the date (the strongest claim there is).
        var isPersonDated = false
        /// A Live Photo's motion half — part of a photo, not a clip. The
        /// rest is left empty for one.
        var isLivePhotoMotion = false
    }

    /// The Angel's occasion derivation with its inputs captured by value.
    struct OccasionReader: Sendable, Equatable {
        private let context: ArchiveAngelEventContext

        /// The Angel's inside (and its tests): a policy's coverage rules
        /// and the birthdays, with the labels switched on in a COPY.
        init(coverage: AngelCoverageRules, birthdays: [FamilyBirthday]) {
            var rules = coverage
            rules.eventLabels = true
            context = ArchiveAngelEventContext(coverage: rules, birthdays: birthdays)
        }

        /// The built-in rules with these birthdays — what a caller with no
        /// Angel in hand gets (a pure build's default, a test).
        init(birthdays: [FamilyBirthday] = []) {
            self.init(coverage: .standard, birthdays: birthdays)
        }

        /// One clip. `now` only bounds the date resolver's search for a
        /// year in a file name; `folders` is the caller's per-pass memo
        /// (each folder's words scanned once). Pure; any thread.
        nonisolated func occasions(for facts: OccasionFacts, now: Date,
                                   folders: inout EventLabeler.FolderWordCache) -> Occasions {
            let candidate = ArchiveAngelCandidate(
                id: facts.id, filename: facts.filename, fullPath: facts.fullPath,
                userDate: facts.userDate, inferredRecordDate: facts.inferredDate,
                inferredDateConfidence: facts.inferredConfidence,
                deviceModel: facts.originModel ?? "", captureDate: facts.embeddedDate,
                userDateConfidence: facts.userDateConfidence, originMake: facts.originMake,
                originEncoder: facts.originEncoder, inferredDateRange: facts.inferredRange)
            guard !candidate.isLivePhotoMotion else { return Occasions(isLivePhotoMotion: true) }
            let derived = ArchiveAngelEvent.derive(candidate, now: now, context: context, keysOnly: false, folders: &folders)
            var out = Occasions(labels: derived.labels, day: derived.day)
            if let claim = derived.claim {
                // A stamp with no camera behind it dates the copy: its year
                // names nothing (the same threshold `derive` keys a day by).
                let copyStamp = claim.sourceRank == 1
                    && claim.confidenceMilli < Int((ArchiveAngelEvent.dayKeyMinimumConfidence * 1000).rounded())
                out.year = copyStamp ? nil : derived.year
                out.isPersonDated = claim.sourceRank == 0
            }
            return out
        }
    }

    /// The reader under the rules and birthdays the Angel holds right now
    /// (O(1): two value copies). Take it on the main actor, use it anywhere.
    var occasionReader: OccasionReader {
        OccasionReader(coverage: policy.coverage, birthdays: familyBirthdays)
    }
}
