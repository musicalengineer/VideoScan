// CyberBrainWriter.swift
// The first writer for the family's knowledge file (Rick, 2026-08-21: "Let
// me tell you about Dad Breen…" → "Oh, tell me all about him, I'll remember
// it"). Until now the CyberBrain was read-only; Hallie could search media but
// could not be told who anyone WAS.
//
// What this is allowed to do is deliberately narrow: append one attributed,
// recorded-but-unverified passage about one person, with a source that says
// who told Hallie and when. It never edits or deletes an existing item, never
// promotes anything to `confirmed` (a person who verifies later does that),
// and never lets a model write the file — every field here is typed by a
// family member or derived deterministically from what they typed.
//
// Durability, per docs/cyberbrain_design.md §7: temp file in the same
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

        public init(
            subjectName: String,
            subjectAliases: [String] = [],
            speakerName: String,
            text: String,
            kind: CyberBrainItem.Kind = .biography,
            date: Date
        ) {
            self.subjectName = subjectName
            self.subjectAliases = subjectAliases
            self.speakerName = speakerName
            self.text = text
            self.kind = kind
            self.date = date
        }
    }

    public enum WriteError: Error, Sendable, Equatable, LocalizedError {
        case emptyText
        case emptySubject
        case ambiguousSubject([String])
        case unsafeRoot(String)
        case ioFailure(String)

        public var errorDescription: String? {
            switch self {
            case .emptyText: return "nothing was said"
            case .emptySubject: return "no person was named"
            case .ambiguousSubject(let names):
                return "more than one person is called that: \(names.joined(separator: ", "))"
            case .unsafeRoot(let path): return "unsafe CyberBrain location: \(path)"
            case .ioFailure(let detail): return "could not save: \(detail)"
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
        let personID: String
        var createdPerson = false
        switch index.resolve(subject) {
        case .resolved(let person):
            personID = person.id
        case .ambiguous(let candidates):
            throw WriteError.ambiguousSubject(candidates.map(\.canonicalName))
        case .notFound:
            personID = uniqueID(
                base: "person." + slug(subject),
                taken: Set(people.map(\.id)))
            people.append(CyberBrainPerson(
                id: personID,
                canonicalName: subject,
                aliases: normalizedAliases(testimony.subjectAliases, excluding: subject)))
            createdPerson = true
        }

        let dayStamp = dayString(testimony.date)
        let speaker = testimony.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerLabel = speaker.isEmpty ? "a family member" : speaker
        var sources = archive.sources
        let sourceID = "source.told-by-" + slug(speakerLabel) + "." + dayStamp
        if !sources.contains(where: { $0.id == sourceID }) {
            sources.append(CyberBrainSource(
                id: sourceID,
                type: .familyWitness,
                title: "Told to Hallie by \(speakerLabel), \(dayStamp)",
                attribution: speakerLabel,
                sourceDate: CyberBrainQualifiedDate(
                    value: dayStamp, precision: .day, qualifier: .exact,
                    displayText: dayStamp),
                notes: "Recorded in conversation; not yet verified against documents."))
        }

        let takenItemIDs = Set(people.flatMap(\.items).map(\.id))
        let itemID = uniqueID(
            base: "told.\(slug(personID.replacingOccurrences(of: "person.", with: ""))).\(dayStamp)",
            taken: takenItemIDs)
        let item = CyberBrainItem(
            id: itemID,
            kind: testimony.kind,
            text: text,
            subjectPersonIDs: [personID],
            sourceIDs: [sourceID],
            // Recorded, attributed, NOT verified. Verification is a later,
            // human step; nothing told in conversation starts as confirmed.
            confidence: .probable,
            privacy: .family,
            createdAt: testimony.date,
            updatedAt: testimony.date)

        guard let personIndex = people.firstIndex(where: { $0.id == personID }) else {
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
            gedcomPersonID: person.gedcomPersonID,
            profileStableID: person.profileStableID,
            canonicalName: person.canonicalName,
            aliases: aliases,
            terminology: person.terminology,
            biographyPassages: person.biographyPassages
                + (testimony.kind == .biography ? [item] : []),
            anecdotes: person.anecdotes + (testimony.kind == .anecdote ? [item] : []),
            lifeEvents: person.lifeEvents + (testimony.kind == .event ? [item] : []),
            notes: person.notes + (testimony.kind == .note ? [item] : []))

        let updated = CyberBrainArchive(
            schemaVersion: archive.schemaVersion,
            archiveID: archive.archiveID,
            displayName: archive.displayName,
            people: people,
            sources: sources)
        try CyberBrainValidator.validate(updated)
        return Receipt(
            archive: updated,
            personID: personID,
            canonicalName: person.canonicalName,
            itemID: itemID,
            sourceID: sourceID,
            createdPerson: createdPerson)
    }

    // MARK: - Durable write

    /// Load (or start) the archive at `rootURL`, append, and save atomically.
    /// Returns the receipt for the saved archive. On any failure the file on
    /// disk is exactly what it was before the call.
    public static func record(
        _ testimony: Testimony,
        rootURL: URL
    ) throws -> Receipt {
        let root = rootURL.standardizedFileURL
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: root.path) {
            do {
                try fileManager.createDirectory(
                    at: root, withIntermediateDirectories: true)
            } catch {
                throw WriteError.ioFailure(error.localizedDescription)
            }
        }
        let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw WriteError.unsafeRoot(root.path)
        }

        let loader = CyberBrainLoader(rootURL: root)
        let existing: CyberBrainArchive?
        do {
            existing = try loader.load()
        } catch CyberBrainError.missingArchive {
            existing = nil
        }
        // Any other loader error propagates: a corrupt or unsafe archive must
        // never be silently replaced by a fresh one with a single passage.

        let receipt = try appending(testimony, to: existing)
        try save(receipt.archive, root: root, hadExisting: existing != nil)
        return receipt
    }

    /// Encoded exactly as the loader reads it back: ISO-8601 dates, stable
    /// key order, human-readable.
    public static func encode(_ archive: CyberBrainArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    private static func save(_ archive: CyberBrainArchive, root: URL,
                             hadExisting: Bool) throws {
        let data = try encode(archive)
        let finalURL = root.appendingPathComponent(
            CyberBrainLoader.defaultFilename, isDirectory: false)
        let tempURL = root.appendingPathComponent(
            ".\(CyberBrainLoader.defaultFilename).tmp-\(UUID().uuidString)",
            isDirectory: false)

        // Write + fsync the temp file.
        let descriptor = open(
            tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw WriteError.ioFailure("cannot create \(tempURL.lastPathComponent)")
        }
        var written = false
        defer {
            if !written { try? FileManager.default.removeItem(at: tempURL) }
        }
        let ok: Bool = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard ok, fsync(descriptor) == 0 else {
            close(descriptor)
            throw WriteError.ioFailure("write failed")
        }
        close(descriptor)

        // Prove the bytes on disk load through the strict reader BEFORE they
        // replace the real file.
        do {
            let probeRoot = root.appendingPathComponent(
                ".probe-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: probeRoot) }
            try FileManager.default.copyItem(
                at: tempURL,
                to: probeRoot.appendingPathComponent(CyberBrainLoader.defaultFilename))
            _ = try CyberBrainLoader(rootURL: probeRoot).load()
        } catch {
            throw WriteError.ioFailure("new archive failed validation: \(error.localizedDescription)")
        }

        if hadExisting {
            try backup(finalURL, root: root)
        }
        // rename(2) is atomic on APFS/HFS+: readers see the old or the new file.
        guard rename(tempURL.path, finalURL.path) == 0 else {
            throw WriteError.ioFailure("rename failed (errno \(errno))")
        }
        written = true
        // Durability of the directory entry itself.
        let dirDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dirDescriptor >= 0 {
            fsync(dirDescriptor)
            close(dirDescriptor)
        }
    }

    /// backups/cyberbrain-<timestamp>.json, bounded to `backupsToKeep`.
    private static func backup(_ fileURL: URL, root: URL) throws {
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let target = backups.appendingPathComponent(
                "cyberbrain-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            try fileManager.copyItem(at: fileURL, to: target)
            let existing = try fileManager.contentsOfDirectory(
                at: backups, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if existing.count > backupsToKeep {
                for stale in existing.prefix(existing.count - backupsToKeep) {
                    try? fileManager.removeItem(at: stale)
                }
            }
        } catch {
            throw WriteError.ioFailure("backup failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Helpers

    public static func slug(_ value: String) -> String {
        let lowered = value.lowercased()
            .folding(options: [.diacriticInsensitive], locale: nil)
        var out = ""
        var lastWasDash = true
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                out.unicodeScalars.append(scalar)
                lastWasDash = false
            } else if !lastWasDash {
                out.append("-")
                lastWasDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "unnamed" : out
    }

    static func uniqueID(base: String, taken: Set<String>) -> String {
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base).\(n)") { n += 1 }
        return "\(base).\(n)"
    }

    static func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func normalizedAliases(_ aliases: [String],
                                          excluding canonical: String) -> [String] {
        var seen: Set<String> = [FamilyIdentityText.normalized(canonical)]
        var out: [String] = []
        for alias in aliases {
            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = FamilyIdentityText.normalized(trimmed)
            guard !trimmed.isEmpty, !key.isEmpty, !seen.contains(key) else { continue }
            seen.insert(key)
            out.append(trimmed)
        }
        return out
    }
}
