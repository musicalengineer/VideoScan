// CyberBrainWriter+Testimony.swift
import Foundation

extension CyberBrainWriter {
    // MARK: - Pure transformation

    /// Appends the testimony to an in-memory archive and returns the new
    /// archive. Pure: no I/O, so tests can exercise every branch without a
    /// filesystem. The returned archive has already passed the validator.
    public static func appending(
        _ testimony: Testimony,
        to existing: CyberBrainArchive?
    ) throws -> Receipt {
        let text = testimony.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WriteError.emptyText }
        let subject = testimony.subjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { throw WriteError.emptySubject }

        let archive = existing ?? CyberBrainArchive(
            archiveID: defaultArchiveID,
            displayName: defaultDisplayName,
            people: [],
            sources: [])

        // Resolve the subject through the same index Hallie answers from, so
        // what she stores is what she will later find.
        let index = try CyberBrainIndex(archive: archive)
        var people = archive.people
        let resolved = try resolveTestimonySubject(
            testimony, subject: subject, index: index, people: &people)
        let dayStamp = dayString(testimony.date)
        let speaker = testimony.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerLabel = speaker.isEmpty ? "a family member" : speaker
        var sources = archive.sources
        let source = try appendTestimonySource(
            testimony, dayStamp: dayStamp, speakerLabel: speakerLabel, to: &sources)

        if let receipt = existingResearchReceipt(
            testimony, text: text, resolved: resolved, sourceID: source.id, people: people, archive: archive) {
            return receipt
        }
        let item = makeTestimonyItem(
            testimony, text: text, personID: resolved.id, source: source, dayStamp: dayStamp, people: people)
        let person = try appendTestimonyItem(item, testimony: testimony, resolved: resolved, people: &people)

        let updated = CyberBrainArchive(
            schemaVersion: archive.schemaVersion,
            archiveID: archive.archiveID,
            displayName: archive.displayName,
            people: people,
            sources: sources)
        try CyberBrainValidator.validate(updated)
        return Receipt(
            archive: updated,
            personID: resolved.id,
            canonicalName: person.canonicalName,
            itemID: item.id,
            sourceID: source.id,
            createdPerson: resolved.created)
    }

    private struct TestimonySubject {
        let id: String
        let created: Bool
        /// Deferred until an item is appended: an idempotent research retry must return the original archive.
        let linkPointer: String?
    }

    private static func resolveTestimonySubject(_ testimony: Testimony, subject: String,
                                                index: CyberBrainIndex, people: inout [CyberBrainPerson]) throws
        -> TestimonySubject {
        let personID: String
        var createdPerson = false
        /// Set when a name-resolved person should acquire the caller's
        /// GEDCOM pointer (they had none before).
        var linkPointer: String?

        func createPerson() -> String {
            let id = uniqueID(
                base: "person." + slug(subject)
                    + (testimony.gedcomPersonID.map { "." + slug($0) } ?? ""),
                taken: Set(people.map(\.id)))
            people.append(CyberBrainPerson(
                id: id,
                gedcomPersonID: testimony.gedcomPersonID,
                canonicalName: subject,
                aliases: normalizedAliases(testimony.subjectAliases, excluding: subject)))
            createdPerson = true
            return id
        }

        if let pointer = testimony.gedcomPersonID,
           let linked = index.people(gedcomPersonID: pointer).first {
            // The tree record is already known to the brain: that wins over
            // any name match, however the speaker spelled it.
            personID = linked.id
        } else {
            switch index.resolve(subject) {
            case .resolved(let person):
                if let pointer = testimony.gedcomPersonID,
                   let existing = person.gedcomPersonID, existing != pointer {
                    // Same name, DIFFERENT tree record (Jr/Sr, cousins):
                    // never merge them.
                    personID = createPerson()
                } else {
                    personID = person.id
                    if person.gedcomPersonID == nil { linkPointer = testimony.gedcomPersonID }
                }
            case .ambiguous(let candidates):
                guard testimony.gedcomPersonID != nil else {
                    throw WriteError.ambiguousSubject(candidates.map(\.canonicalName))
                }
                // A pointer disambiguates: a fresh, linked record.
                personID = createPerson()
            case .notFound:
                personID = createPerson()
            }
        }

        return TestimonySubject(id: personID, created: createdPerson, linkPointer: linkPointer)
    }

    private static func existingResearchReceipt(_ testimony: Testimony, text: String, resolved: TestimonySubject,
                                                sourceID: String, people: [CyberBrainPerson], archive: CyberBrainArchive)
        -> Receipt? {
        // Idempotent research attestations (QA 2026-10-01 P3-5): the SAME
        // passage from the SAME research source about the SAME person is
        // already recorded → hand back that item and the archive unchanged.
        // A "told Hallie, but the dossier didn't record it" retry can then
        // never write a duplicate item. ACTIVE items only: a passage taken
        // back or reworded through "correct a family note" is not what
        // Hallie knows, so the same words filed again are a new item
        // (adversarial review 2026-10-01, 06addb5d).
        if testimony.origin == .researchFinding, !resolved.created,
           let person = people.first(where: { $0.id == resolved.id }),
           let existing = person.items.first(where: {
               $0.status == .active && $0.sourceIDs.contains(sourceID) && $0.text == text
           }) {
            return Receipt(archive: archive, personID: resolved.id, canonicalName: person.canonicalName,
                           itemID: existing.id, sourceID: sourceID, createdPerson: false)
        }

        return nil
    }

    private static func makeTestimonyItem(_ testimony: Testimony, text: String, personID: String,
                                          source: (id: String, itemPrefix: String, confidence: CyberBrainItem.Confidence),
                                          dayStamp: String, people: [CyberBrainPerson]) -> CyberBrainItem {
        let takenItemIDs = Set(people.flatMap(\.items).map(\.id))
        let itemID = uniqueID(
            base: "\(source.itemPrefix).\(slug(personID.replacingOccurrences(of: "person.", with: ""))).\(dayStamp)",
            taken: takenItemIDs)
        return CyberBrainItem(
            id: itemID,
            kind: testimony.kind,
            text: text,
            subjectPersonIDs: [personID],
            sourceIDs: [source.id],
            confidence: source.confidence,
            privacy: .family,
            createdAt: testimony.date,
            updatedAt: testimony.date)
    }

    private static func appendTestimonyItem(_ item: CyberBrainItem, testimony: Testimony,
                                            resolved: TestimonySubject, people: inout [CyberBrainPerson]) throws
        -> CyberBrainPerson {
        guard let personIndex = people.firstIndex(where: { $0.id == resolved.id }) else {
            throw WriteError.emptySubject
        }
        let person = people[personIndex]
        var aliases = person.aliases
        for alias in normalizedAliases(testimony.subjectAliases, excluding: person.canonicalName)
            where !aliases.contains(where: { FamilyIdentityText.normalized($0) == FamilyIdentityText.normalized(alias) }) {
            aliases.append(alias)
        }
        people[personIndex] = CyberBrainPerson(
            id: person.id,
            gedcomPersonID: person.gedcomPersonID ?? resolved.linkPointer,
            profileStableID: person.profileStableID,
            canonicalName: person.canonicalName,
            aliases: aliases,
            terminology: person.terminology,
            biographyPassages: person.biographyPassages
                + (testimony.kind == .biography ? [item] : []),
            anecdotes: person.anecdotes + (testimony.kind == .anecdote ? [item] : []),
            lifeEvents: person.lifeEvents + (testimony.kind == .event ? [item] : []),
            notes: person.notes + (testimony.kind == .note ? [item] : []),
            pronunciations: person.pronunciations)

        return person
    }
}
