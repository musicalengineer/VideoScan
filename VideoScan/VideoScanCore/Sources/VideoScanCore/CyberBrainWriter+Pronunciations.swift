// CyberBrainWriter+Pronunciations.swift
import Foundation

extension CyberBrainWriter {
    // MARK: - Pronunciations (2026-08-26: "a pronunciation key next to aliases")

    /// What was recorded about how a name is said.
    public struct PronunciationReceipt: Sendable, Equatable {
        public let archive: CyberBrainArchive
        public let personID: String
        public let canonicalName: String
        /// The key as stored (trimmed, caller's spelling).
        public let word: String
        /// Nil when the entry was removed.
        public let saidAs: String?
        public let createdPerson: Bool
    }

    /// Pure: set (or, with an empty `saidAs`, remove) how one word of a
    /// person's name is spoken. `word` must be a single token; keys are
    /// matched case-insensitively so "nathaniel" replaces "Nathaniel"
    /// rather than sitting beside it. Nothing else on the person changes.
    public static func settingPronunciation(
        personID: String,
        word: String,
        saidAs: String?,
        in archive: CyberBrainArchive,
        acceptedNames: [String] = []
    ) throws -> PronunciationReceipt {
        let key = word.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw WriteError.emptySubject }
        guard key.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw WriteError.ioFailure("pronunciation key \"\(key)\" must be one word")
        }
        let spoken = saidAs?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var people = archive.people
        guard let at = people.firstIndex(where: { $0.id == personID }) else {
            throw WriteError.emptySubject
        }
        let person = people[at]
        // The store's own line (GH #184 item 6): a key is SET only when it
        // is a word of this person's name — their canonical name and
        // aliases, or the tree name and alternate names the caller
        // resolved them through (`acceptedNames`, the by-name variant).
        // "see" inside "Llanlowell Llan Hywel and see note" is neither.
        // Removal (empty `saidAs`) is always allowed, so junk can be
        // cleaned out through the same door.
        if !spoken.isEmpty {
            let named = FamilyNameTokens.matches(key, primaryName: person.canonicalName, aliases: person.aliases)
                || (acceptedNames.first.map {
                    FamilyNameTokens.matches(key, primaryName: $0, aliases: Array(acceptedNames.dropFirst()))
                } ?? false)
            guard named else { throw WriteError.unresolvedWord(key, person.canonicalName) }
        }
        var table = (person.pronunciations ?? [:]).filter {
            FamilyIdentityText.normalized($0.key) != FamilyIdentityText.normalized(key)
        }
        if !spoken.isEmpty { table[key] = spoken }
        people[at] = person.withPronunciations(table)
        let updated = CyberBrainArchive(
            schemaVersion: archive.schemaVersion,
            archiveID: archive.archiveID,
            displayName: archive.displayName,
            people: people,
            sources: archive.sources)
        try CyberBrainValidator.validate(updated)
        return PronunciationReceipt(
            archive: updated, personID: person.id, canonicalName: person.canonicalName,
            word: key, saidAs: spoken.isEmpty ? nil : spoken, createdPerson: false)
    }

    /// Pure: same, addressed by NAME (+ optional GEDCOM pointer) through the
    /// resolution ladder testimony uses — so the Family Tree inspector can
    /// set a pronunciation for a tree person Hallie has never been told
    /// about. That mints a person record with no passages, only the
    /// pronunciation; an ambiguous name without a pointer throws.
    public static func settingPronunciation(
        subjectName: String,
        gedcomPersonID: String?,
        aliases: [String] = [],
        word: String,
        saidAs: String?,
        in existing: CyberBrainArchive?
    ) throws -> PronunciationReceipt {
        let subject = subjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { throw WriteError.emptySubject }
        let archive = existing ?? CyberBrainArchive(
            archiveID: defaultArchiveID,
            displayName: defaultDisplayName,
            people: [],
            sources: [])
        let index = try CyberBrainIndex(archive: archive)
        var people = archive.people
        let (id, created) = try resolveSubject(
            subject, gedcomPersonID: gedcomPersonID, aliases: aliases,
            index: index, people: &people)
        let withPerson = CyberBrainArchive(
            schemaVersion: archive.schemaVersion,
            archiveID: archive.archiveID,
            displayName: archive.displayName,
            people: people,
            sources: archive.sources)
        // The guard inside runs BEFORE anything is saved, so a refused
        // word never leaves a freshly minted person behind.
        let receipt = try settingPronunciation(
            personID: id, word: word, saidAs: saidAs, in: withPerson,
            acceptedNames: [subject] + aliases)
        return PronunciationReceipt(
            archive: receipt.archive, personID: receipt.personID,
            canonicalName: receipt.canonicalName, word: receipt.word,
            saidAs: receipt.saidAs, createdPerson: created)
    }
}
