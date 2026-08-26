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
        }

        public init(
            subjectName: String,
            subjectAliases: [String] = [],
            speakerName: String,
            text: String,
            kind: CyberBrainItem.Kind = .biography,
            date: Date,
            origin: Origin = .conversation,
            gedcomPersonID: String? = nil
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

        let dayStamp = dayString(testimony.date)
        let speaker = testimony.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerLabel = speaker.isEmpty ? "a family member" : speaker
        var sources = archive.sources
        let sourceID: String
        let itemPrefix: String
        let confidence: CyberBrainItem.Confidence
        switch testimony.origin {
        case .conversation:
            sourceID = "source.told-by-" + slug(speakerLabel) + "." + dayStamp
            itemPrefix = "told"
            // Recorded, attributed, NOT verified. Verification is a later,
            // human step; nothing told in conversation starts as confirmed.
            confidence = .probable
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
        case .familyTreeNote:
            sourceID = "source.family-tree-notes-" + slug(speakerLabel) + "." + dayStamp
            itemPrefix = "note"
            confidence = .confirmed
            if !sources.contains(where: { $0.id == sourceID }) {
                sources.append(CyberBrainSource(
                    id: sourceID,
                    type: .profileNote,
                    title: "Family Tree notes (\(speakerLabel))",
                    attribution: speakerLabel,
                    sourceDate: CyberBrainQualifiedDate(
                        value: dayStamp, precision: .day, qualifier: .exact,
                        displayText: dayStamp),
                    notes: "Written in the Family Tree inspector about a specific GEDCOM record."))
            }
        }

        let takenItemIDs = Set(people.flatMap(\.items).map(\.id))
        let itemID = uniqueID(
            base: "\(itemPrefix).\(slug(personID.replacingOccurrences(of: "person.", with: ""))).\(dayStamp)",
            taken: takenItemIDs)
        let item = CyberBrainItem(
            id: itemID,
            kind: testimony.kind,
            text: text,
            subjectPersonIDs: [personID],
            sourceIDs: [sourceID],
            confidence: confidence,
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
            gedcomPersonID: person.gedcomPersonID ?? linkPointer,
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

        let dayStamp = dayString(caption.date)
        let speaker = caption.speakerName.trimmingCharacters(in: .whitespacesAndNewlines)
        let speakerLabel = speaker.isEmpty ? "a family member" : speaker
        var sources = archive.sources
        let photoURL = URL(fileURLWithPath: caption.photoPath)
        let photoSourceID = "source.photo." + slug(
            photoURL.deletingLastPathComponent().lastPathComponent + "-" + photoURL.lastPathComponent)
        if !sources.contains(where: { $0.id == photoSourceID }) {
            sources.append(CyberBrainSource(
                id: photoSourceID,
                type: .mediaEvidence,
                title: "Photo: \(photoURL.lastPathComponent)",
                attribution: speakerLabel,
                sourceDate: nil,
                locator: photoLocator(caption.photoPath),
                notes: "A photo in the family archive, captioned in conversation. Full path when captioned: \(caption.photoPath)"))
        }
        let toldSourceID = "source.told-by-" + slug(speakerLabel) + "." + dayStamp
        if !sources.contains(where: { $0.id == toldSourceID }) {
            sources.append(CyberBrainSource(
                id: toldSourceID,
                type: .familyWitness,
                title: "Told to Hallie by \(speakerLabel), \(dayStamp)",
                attribution: speakerLabel,
                sourceDate: CyberBrainQualifiedDate(
                    value: dayStamp, precision: .day, qualifier: .exact,
                    displayText: dayStamp),
                notes: "Recorded in conversation; not yet verified against documents."))
        }

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
            notes: person.notes + [item])
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

    /// Durable form of `appending(caption:to:)`; same atomic save as `record`.
    public static func record(
        caption: PhotoCaption,
        rootURL: URL
    ) throws -> Receipt {
        let (root, existing) = try prepareRoot(rootURL)
        let receipt = try appending(caption: caption, to: existing)
        try save(receipt.archive, root: root, hadExisting: existing != nil)
        return receipt
    }

    /// Subject → CyberBrain person id, minting one when nobody matches. The
    /// resolution ladder shared by testimony and captions: a known GEDCOM
    /// pointer wins; a name match that carries a DIFFERENT pointer is
    /// somebody else (Jr/Sr); an unlinked name match acquires the pointer.
    private static func resolveSubject(
        _ subject: String,
        gedcomPersonID: String?,
        aliases: [String],
        index: CyberBrainIndex,
        people: inout [CyberBrainPerson]
    ) throws -> (id: String, created: Bool) {
        func createPerson() -> String {
            let id = uniqueID(
                base: "person." + slug(subject)
                    + (gedcomPersonID.map { "." + slug($0) } ?? ""),
                taken: Set(people.map(\.id)))
            people.append(CyberBrainPerson(
                id: id,
                gedcomPersonID: gedcomPersonID,
                canonicalName: subject,
                aliases: normalizedAliases(aliases, excluding: subject)))
            return id
        }
        if let pointer = gedcomPersonID,
           let linked = index.people(gedcomPersonID: pointer).first {
            return (linked.id, false)
        }
        switch index.resolve(subject) {
        case .resolved(let person):
            if let pointer = gedcomPersonID,
               let existing = person.gedcomPersonID, existing != pointer {
                return (createPerson(), true)
            }
            if person.gedcomPersonID == nil, let pointer = gedcomPersonID,
               let at = people.firstIndex(where: { $0.id == person.id }) {
                let p = people[at]
                people[at] = CyberBrainPerson(
                    id: p.id, gedcomPersonID: pointer, profileStableID: p.profileStableID,
                    canonicalName: p.canonicalName, aliases: p.aliases, terminology: p.terminology,
                    biographyPassages: p.biographyPassages, anecdotes: p.anecdotes,
                    lifeEvents: p.lifeEvents, notes: p.notes)
            }
            return (person.id, false)
        case .ambiguous(let candidates):
            guard gedcomPersonID != nil else {
                throw WriteError.ambiguousSubject(candidates.map(\.canonicalName))
            }
            return (createPerson(), true)
        case .notFound:
            return (createPerson(), true)
        }
    }

    /// Validate the root directory and load what is there (nil when the
    /// archive does not exist yet). Shared by both durable writers.
    private static func prepareRoot(_ rootURL: URL) throws -> (URL, CyberBrainArchive?) {
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
        do {
            return (root, try loader.load())
        } catch CyberBrainError.missingArchive {
            return (root, nil)
        }
        // Any other loader error propagates: a corrupt or unsafe archive must
        // never be silently replaced by a fresh one.
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
