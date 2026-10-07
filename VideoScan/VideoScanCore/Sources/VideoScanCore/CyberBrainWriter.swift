// CyberBrainWriter.swift
// The first writer for the family's knowledge file (Rick, 2026-08-21: "Let
// me tell you about Dad Breen…" → "Oh, tell me all about him, I'll remember
// it"). Until now the CyberBrain was read-only; Hallie could search media but
// could not be told who anyone WAS.
//
// What this is allowed to do is deliberately narrow: append one attributed,
// recorded-but-unverified passage about one person, with a source that says
// who told Hallie and when. It never edits or deletes an existing item, never
// promotes anything told in conversation to `confirmed` (a person who
// verifies later does that; only the owner's own Family Tree notes start
// confirmed — see `Testimony.Origin`), and never lets a model write the
// file — every field here is typed by a family member or derived
// deterministically from what they typed.
//
// Durability, per docs/design/cyberbrain_design.md §7: temp file in the same
// directory → full validation of the NEW archive → fsync → atomic rename over
// cyberbrain.json, with the previous file copied to backups/ first. A crash
// at any point leaves either the old file or the new file, never a torn one.

import Foundation

public enum CyberBrainWriter {

    /// One thing a family member told Hallie about one person.
    public struct Testimony: Sendable, Equatable {
        /// The person as the speaker named them ("Dad Breen", "my Uncle Bob").
        public let subjectName: String
        /// Extra ways the speaker referred to the same person, kept as
        /// aliases so "tell me about Dad Breen" and "…Richard Breen Sr."
        /// both find him later.
        public let subjectAliases: [String]
        /// Who is speaking — the owner name from the archivist settings.
        public let speakerName: String
        /// Exactly what they said, one passage.
        public let text: String
        public let kind: CyberBrainItem.Kind
        /// When they said it. Injected so tests are deterministic.
        public let date: Date
        /// Where the words came from — decides the source record, the
        /// item-id prefix and the starting confidence (see `Origin`).
        public let origin: Origin
        /// The family-tree pointer of the subject when the caller KNOWS it
        /// (Family Tree notes pane, 2026-08-26). Resolution then prefers a
        /// CyberBrain person already linked to that pointer, links an
        /// unlinked name match, and otherwise creates a linked person —
        /// so Hallie's "tell me about …" and the tree agree on who this is.
        public let gedcomPersonID: String?

        public enum Origin: String, Sendable, Equatable {
            /// Told to Hallie in conversation ("let me tell you about…").
            /// Recorded as `probable`: attributed, not yet verified.
            case conversation
            /// Typed by the archivist in the Family Tree inspector, about a
            /// specific tree record. Recorded as `confirmed` — the owner's
            /// own statement in their own tree (Rick, 2026-08-26).
            case familyTreeNote
            /// A finding from Research Person (Chronicling America, Find a
            /// Grave, Wikipedia, the web) that the archivist marked
            /// CONFIRMED and told Hallie about (2026-08-29). Recorded as
            /// `confirmed`, with its own source record carrying the URL
            /// and the retrieval date so Hallie can cite "Berkshire County
            /// Eagle, 12 May 1875 — confirmed by Rick". Requires `citation`.
            case researchFinding
        }

        /// Where a research finding came from. Only used with
        /// `Origin.researchFinding`; one CyberBrain source per locator.
        public struct Citation: Sendable, Equatable {
            /// "Berkshire County Eagle, 1875-05-12" / "Find a Grave memorial".
            public let title: String
            /// The web address of the fetched page. Kept in the source's
            /// notes ("URL: …"): a source locator is archive-relative by
            /// contract (the validator refuses anything else), so the URL
            /// cannot BE the locator.
            public let url: String
            /// Archive-relative path of the cached copy of the page
            /// (`People/<key>/research/cache/<sha>.json`), when there is
            /// one. Becomes the source locator.
            public let locator: String?
            /// The document's own date when known ("1875-05-12"), else nil.
            public let sourceDate: String?
            /// Newspaper/grave pages are `.officialRecord`; encyclopedias
            /// and web pages `.curatedBiography`.
            public let sourceKind: CyberBrainSource.Kind
            /// Day the page was fetched (the cache's retrieved date).
            public let retrievedAt: Date

            public init(title: String, url: String, locator: String? = nil,
                        sourceDate: String? = nil,
                        sourceKind: CyberBrainSource.Kind = .officialRecord,
                        retrievedAt: Date) {
                self.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
                self.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmedLocator = locator?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.locator = trimmedLocator.isEmpty ? nil : trimmedLocator
                let trimmedDate = sourceDate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.sourceDate = trimmedDate.isEmpty ? nil : trimmedDate
                self.sourceKind = sourceKind
                self.retrievedAt = retrievedAt
            }
        }

        /// The document behind a `.researchFinding`; nil for every other
        /// origin (a research testimony without one is an `emptySubject`
        /// error — nothing gets stored as "confirmed" without a locator).
        public let citation: Citation?

        public init(
            subjectName: String,
            subjectAliases: [String] = [],
            speakerName: String,
            text: String,
            kind: CyberBrainItem.Kind = .biography,
            date: Date,
            origin: Origin = .conversation,
            gedcomPersonID: String? = nil,
            citation: Citation? = nil
        ) {
            self.subjectName = subjectName
            self.subjectAliases = subjectAliases
            self.speakerName = speakerName
            self.text = text
            self.kind = kind
            self.date = date
            self.origin = origin
            let trimmedPointer = gedcomPersonID?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            self.gedcomPersonID = trimmedPointer.isEmpty ? nil : trimmedPointer
            self.citation = citation
        }
    }

    public enum WriteError: Error, Sendable, Equatable, LocalizedError {
        case emptyText
        case emptySubject
        case ambiguousSubject([String])
        case unsafeRoot(String)
        case ioFailure(String)
        /// A pronunciation key that is not a word of the person's name
        /// (whole alias or name word, FamilyNameTokens). Live 2026-09-11:
        /// "see" was written onto Adam FitzHerbert of Llanllowell through
        /// his notes-style alias (GH #184 item 6). (word, person)
        case unresolvedWord(String, String)

        public var errorDescription: String? {
            switch self {
            case .emptyText: return "nothing was said"
            case .emptySubject: return "no person was named"
            case .ambiguousSubject(let names):
                return "more than one person is called that: \(names.joined(separator: ", "))"
            case .unsafeRoot(let path): return "unsafe CyberBrain location: \(path)"
            case .ioFailure(let detail): return "could not save: \(detail)"
            case .unresolvedWord(let word, let person):
                return "\"\(word)\" is not a word of \(person)'s name"
            }
        }
    }

    /// What was recorded, so the caller can say it back honestly.
    public struct Receipt: Sendable, Equatable {
        public let archive: CyberBrainArchive
        public let personID: String
        public let canonicalName: String
        public let itemID: String
        public let sourceID: String
        /// True when this testimony created the person (first thing ever
        /// recorded about them).
        public let createdPerson: Bool
    }

    public static let defaultArchiveID = "family"
    public static let defaultDisplayName = "Family CyberBrain"
    public static let backupsToKeep = 20

}
