// CyberBrainWriter+Captions.swift
import Foundation

extension CyberBrainWriter {
    // MARK: - Photo captions (2026-08-26: "this photo is me and my family")

    /// What a family member said about a photo Hallie had just shown. One
    /// `.note` item shared by every named person, cited to the photo file
    /// itself and to the told-by source — so "what do we know about this
    /// photo?" and "tell me about Donna" both find it later.
    public struct PhotoCaption: Sendable, Equatable {
        public struct Subject: Sendable, Equatable {
            public let name: String
            /// The tree pointer when the caller resolved one ("me" → the
            /// owner's record). Nil keeps the subject as a name only.
            public let gedcomPersonID: String?
            public init(name: String, gedcomPersonID: String? = nil) {
                self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                let trimmed = gedcomPersonID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                self.gedcomPersonID = trimmed.isEmpty ? nil : trimmed
            }
        }
        /// At least one; at most `CyberBrainWriter.maxCaptionSubjects`.
        public let subjects: [Subject]
        public let speakerName: String
        /// The caption as spoken ("me and my family with Donna and the boys").
        public let text: String
        /// Absolute path of the photo file — the source locator.
        public let photoPath: String
        public let date: Date

        public init(subjects: [Subject], speakerName: String, text: String,
                    photoPath: String, date: Date) {
            self.subjects = subjects
            self.speakerName = speakerName
            self.text = text
            self.photoPath = photoPath
            self.date = date
        }
    }

    /// The validator allows 1…8 subject pointers per item.
    public static let maxCaptionSubjects = 8

    /// Pure: append the caption to an in-memory archive. Each subject is
    /// resolved (or created) exactly as a testimony subject would be, so the
    /// same person is never minted twice. The receipt names the first
    /// subject; `sourceID` is the photo source.
    public static func appending(
        caption: PhotoCaption,
        to existing: CyberBrainArchive?
    ) throws -> Receipt {
        let text = caption.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WriteError.emptyText }
        let subjects = caption.subjects.filter { !$0.name.isEmpty }.prefix(maxCaptionSubjects)
        guard !subjects.isEmpty else { throw WriteError.emptySubject }

        var archive = existing ?? CyberBrainArchive(
            archiveID: defaultArchiveID,
            displayName: defaultDisplayName,
            people: [],
            sources: [])
        var people = archive.people
        let (subjectIDs, createdAny) = try resolveCaptionSubjects(subjects, archive: archive, people: &people)

        let dayStamp = dayString(caption.date)
        let speaker = caption.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerLabel = speaker.isEmpty ? "a family member" : speaker
        var sources = archive.sources
        let (photoSourceID, toldSourceID) = appendCaptionSources(
            caption, speakerLabel: speakerLabel, dayStamp: dayStamp, to: &sources)

        let firstID = subjectIDs[0]
        let takenItemIDs = Set(people.flatMap(\.items).map(\.id))
        let itemID = uniqueID(
            base: "caption.\(slug(firstID.replacingOccurrences(of: "person.", with: ""))).\(dayStamp)",
            taken: takenItemIDs)
        let item = CyberBrainItem(
            id: itemID,
            kind: .note,
            text: text,
            subjectPersonIDs: subjectIDs,
            sourceIDs: [photoSourceID, toldSourceID],
            confidence: .probable,
            privacy: .family,
            createdAt: caption.date,
            updatedAt: caption.date)
        guard let personIndex = people.firstIndex(where: { $0.id == firstID }) else {
            throw WriteError.emptySubject
        }
        let person = people[personIndex]
        people[personIndex] = CyberBrainPerson(
            id: person.id,
            gedcomPersonID: person.gedcomPersonID,
            profileStableID: person.profileStableID,
            canonicalName: person.canonicalName,
            aliases: person.aliases,
            terminology: person.terminology,
            biographyPassages: person.biographyPassages,
            anecdotes: person.anecdotes,
            lifeEvents: person.lifeEvents,
            notes: person.notes + [item],
            pronunciations: person.pronunciations)
        archive = CyberBrainArchive(
            schemaVersion: archive.schemaVersion,
            archiveID: archive.archiveID,
            displayName: archive.displayName,
            people: people,
            sources: sources)
        try CyberBrainValidator.validate(archive)
        return Receipt(
            archive: archive,
            personID: firstID,
            canonicalName: person.canonicalName,
            itemID: itemID,
            sourceID: photoSourceID,
            createdPerson: createdAny)
    }

    /// Source locators are archive-relative by contract (the validator
    /// refuses absolute paths): `People/<folder>/<file>` when the photo is
    /// under a People directory, else the file name alone.
    public static func photoLocator(_ path: String) -> String {
        let parts = path.split(separator: "/").map(String.init)
        if let at = parts.lastIndex(of: "People"), at < parts.count - 1 {
            return parts[at...].joined(separator: "/")
        }
        return parts.last ?? "photo"
    }

    private static func resolveCaptionSubjects(_ subjects: ArraySlice<PhotoCaption.Subject>,
                                               archive: CyberBrainArchive, people: inout [CyberBrainPerson]) throws
        -> (ids: [String], createdAny: Bool) {
        var subjectIDs: [String] = []
        var createdAny = false
        for subject in subjects {
            // Re-index after every creation so a second mention of a newly
            // minted person finds them instead of minting a twin.
            let index = try CyberBrainIndex(archive: CyberBrainArchive(
                schemaVersion: archive.schemaVersion, archiveID: archive.archiveID,
                displayName: archive.displayName, people: people, sources: archive.sources))
            let resolved = try resolveSubject(
                subject.name, gedcomPersonID: subject.gedcomPersonID,
                aliases: [], index: index, people: &people)
            createdAny = createdAny || resolved.created
            if !subjectIDs.contains(resolved.id) { subjectIDs.append(resolved.id) }
        }

        return (subjectIDs, createdAny)
    }
}
