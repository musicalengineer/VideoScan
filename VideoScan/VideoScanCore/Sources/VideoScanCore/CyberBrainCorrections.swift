// CyberBrainCorrections.swift
// "Correct a family note" (Rick, approved 2026-09-29):
//
//   Take back, reword, or move one note about one person — nothing is ever
//   erased; the old text stays in the file, hidden unless Rick asks to see
//   corrections.
//
// Why it exists: a Find a Grave passage about John Robert Latta (b. 1835)
// was saved on John C. Latta (b. 1805, his father) and there was no way to
// take it off. Genealogy practice here is "forensic — something in between":
// never hard-delete; a wrong note stays in the file, struck through, visible
// only when you ask for the details.
//
// Three operations, each a pure `correcting(_:in:)` over an archive plus the
// durable `correct(_:rootURL:)` that reuses the writer's one save path
// (temp → probe-load → backup → atomic rename):
//
//   REMOVE  item → retracted + correction{removed}
//   EDIT    new active item (same subjects/kind/sources/confidence/privacy)
//           supersedes it; item → superseded + correction{edited}
//   MOVE    new active item on the right person (same text, kind, sources,
//           confidence, privacy, ORIGINAL createdAt); item → retracted +
//           correction{moved, movedTo…}
//
// Every refusal is decided before anything is written; a refused request
// leaves cyberbrain.json byte-identical. Hallie reads only active,
// non-superseded items (CyberBrainIndex), so a corrected item leaves her
// answers the moment the file is saved.

import Foundation

extension CyberBrainWriter {

    /// One correction a person asked for.
    public struct NoteCorrection: Sendable, Equatable {
        public enum Operation: Sendable, Equatable {
            case remove(reason: CyberBrainCorrection.Reason, detail: String?)
            case edit(newText: String)
            case move(to: MoveTarget)
        }

        /// The tree person a note belongs on. Resolved to a CyberBrain
        /// person by the SAME ladder a new note uses: the GEDCOM pointer
        /// wins; a same-name record with a different pointer (Jr/Sr) is
        /// never merged; nobody found → a linked person is created.
        public struct MoveTarget: Sendable, Equatable {
            public let name: String
            public let gedcomPersonID: String
            public let aliases: [String]

            public init(name: String, gedcomPersonID: String, aliases: [String] = []) {
                self.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
                self.gedcomPersonID = gedcomPersonID.trimmingCharacters(in: .whitespacesAndNewlines)
                self.aliases = aliases
            }
        }

        public let itemID: String
        /// The CyberBrain person the caller was LOOKING AT when they asked.
        /// The item must be about them — a menu opened on one card can
        /// never correct a note that belongs to somebody else.
        public let viewedPersonID: String
        public let operation: Operation
        /// Who is correcting (the owner name from the archivist settings).
        public let by: String
        /// When. Injected so tests are deterministic.
        public let date: Date

        public init(itemID: String, viewedPersonID: String, operation: Operation,
                    by: String, date: Date) {
            self.itemID = itemID
            self.viewedPersonID = viewedPersonID
            self.operation = operation
            self.by = by
            self.date = date
        }
    }

    /// Every way a correction can be turned down. All are decided before
    /// any write; the file is untouched.
    public enum CorrectionRefusal: Error, Sendable, Equatable, LocalizedError {
        /// No knowledge file exists yet — there is nothing to correct.
        case noArchive
        case unknownItem(String)
        /// Already taken back, moved, or replaced by a newer wording.
        case itemNotCurrent(String)
        /// The note is not about the person being viewed. (itemID, person)
        case notAboutViewedPerson(String, String)
        case emptyText
        case unchangedText
        /// "Other" needs a word of why.
        case detailRequired
        case detailTooLong(Int)
        /// No person to move it to (empty name or pointer, or not in the tree).
        case targetMissing
        /// The note is already on that person.
        case sameTarget(String)
        /// A note shared by several people (a photo caption) is edited or
        /// removed as a whole, never moved off one of them.
        case sharedNoteCannotMove(Int)
        case noAuthor

        public var errorDescription: String? {
            switch self {
            case .noArchive: return "there is no family knowledge file to correct yet"
            case .unknownItem: return "that note is no longer in the family knowledge file"
            case .itemNotCurrent: return "that note was already corrected — refresh to see the current version"
            case .notAboutViewedPerson(_, let person):
                return "that note is not about \(person); nothing was changed"
            case .emptyText: return "the new wording is empty"
            case .unchangedText: return "the new wording is the same as the old"
            case .detailRequired: return "say briefly why (Other needs a reason)"
            case .detailTooLong(let count):
                return "the reason is \(count) characters; keep it under \(CyberBrainCorrection.maximumDetailLength)"
            case .targetMissing: return "choose the person this note belongs to"
            case .sameTarget(let name): return "the note is already on \(name)"
            case .sharedNoteCannotMove(let count):
                return "this note is about \(count) people; edit or remove it instead of moving it"
            case .noAuthor: return "no archivist name is set"
            }
        }
    }

    /// What was changed, so the caller can say it back and log it.
    public struct CorrectionReceipt: Sendable, Equatable {
        public let archive: CyberBrainArchive
        public let action: CyberBrainCorrection.Action
        /// The item that was corrected (now retracted or superseded).
        public let itemID: String
        /// The new edited or moved item; nil for a removal.
        public let newItemID: String?
        public let fromPersonID: String
        /// Where a moved note went; nil otherwise.
        public let toPersonID: String?
        public let toPersonName: String?
        /// True when a move created the target person.
        public let createdTargetPerson: Bool
        public let oldText: String
        public let newText: String?
        /// Where the previous file was copied (durable form only).
        public let backupURL: URL?

        func with(backupURL: URL?) -> CorrectionReceipt {
            CorrectionReceipt(
                archive: archive, action: action, itemID: itemID, newItemID: newItemID,
                fromPersonID: fromPersonID, toPersonID: toPersonID, toPersonName: toPersonName,
                createdTargetPerson: createdTargetPerson, oldText: oldText, newText: newText,
                backupURL: backupURL)
        }
    }

    // MARK: - Pure

    /// Apply one correction to an in-memory archive. Pure: no I/O. Every
    /// check that can say no runs before the new archive is assembled, and
    /// the result has passed the validator.
    ///
    /// Cost: O(items) to find the item and the supersession set, plus one
    /// validation pass — a 10k-item archive is milliseconds.
    public static func correcting(
        _ request: NoteCorrection,
        in archive: CyberBrainArchive
    ) throws -> CorrectionReceipt {
        let author = request.by.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !author.isEmpty else { throw CorrectionRefusal.noAuthor }
        guard let location = locate(request.itemID, in: archive.people) else {
            throw CorrectionRefusal.unknownItem(request.itemID)
        }
        let old = location.item
        // "Current" = what Hallie would say: active AND not replaced by an
        // active newer wording. Anything else was already corrected.
        let replaced = archive.people.lazy.flatMap(\.items).contains {
            $0.status == .active && $0.supersedesItemID == old.id
        }
        guard old.status == .active, !replaced else {
            throw CorrectionRefusal.itemNotCurrent(old.id)
        }
        guard old.subjectPersonIDs.contains(request.viewedPersonID) else {
            let name = archive.people.first { $0.id == request.viewedPersonID }?.canonicalName
                ?? request.viewedPersonID
            throw CorrectionRefusal.notAboutViewedPerson(old.id, name)
        }
        let now = max(request.date, old.createdAt)
        var people = archive.people

        let receipt: CorrectionReceipt
        switch request.operation {
        case .remove(let reason, let rawDetail):
            let detail = try checkedDetail(rawDetail, reason: reason)
            let retracted = old.withCorrection(
                status: .retracted, updatedAt: now,
                correction: CyberBrainCorrection(
                    action: .removed, reason: reason, detail: detail, at: request.date, by: author))
            replace(at: location, with: retracted, in: &people)
            receipt = CorrectionReceipt(
                archive: rebuilt(archive, people: people), action: .removed,
                itemID: old.id, newItemID: nil, fromPersonID: request.viewedPersonID,
                toPersonID: nil, toPersonName: nil, createdTargetPerson: false,
                oldText: old.text, newText: nil, backupURL: nil)

        case .edit(let rawText):
            let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw CorrectionRefusal.emptyText }
            guard text != old.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw CorrectionRefusal.unchangedText
            }
            let owner = people[location.personIndex]
            let newID = uniqueID(
                base: "\(idPrefix(old.id)).\(slug(owner.id.replacingOccurrences(of: "person.", with: ""))).\(dayString(request.date))",
                taken: Set(people.flatMap(\.items).map(\.id)))
            // Same subjects/kind/sources/confidence/privacy — only the words
            // change. The structured fields ride along so a reworded service
            // story keeps its service record.
            let edited = CyberBrainItem(
                id: newID, kind: old.kind, text: text, subjectPersonIDs: old.subjectPersonIDs,
                eventDate: old.eventDate, place: old.place, sourceIDs: old.sourceIDs,
                confidence: old.confidence, privacy: old.privacy, status: .active,
                supersedesItemID: old.id, disputesItemIDs: old.disputesItemIDs,
                createdAt: now, updatedAt: now, service: old.service)
            let superseded = old.withCorrection(
                status: .superseded, updatedAt: now,
                correction: CyberBrainCorrection(
                    action: .edited, reason: .wrongInformation, at: request.date, by: author))
            replace(at: location, with: superseded, in: &people)
            append(edited, toPersonAt: location.personIndex, in: &people)
            receipt = CorrectionReceipt(
                archive: rebuilt(archive, people: people), action: .edited,
                itemID: old.id, newItemID: newID, fromPersonID: request.viewedPersonID,
                toPersonID: nil, toPersonName: nil, createdTargetPerson: false,
                oldText: old.text, newText: text, backupURL: nil)

        case .move(let target):
            guard !target.name.isEmpty, !target.gedcomPersonID.isEmpty else {
                throw CorrectionRefusal.targetMissing
            }
            guard old.subjectPersonIDs.count == 1 else {
                throw CorrectionRefusal.sharedNoteCannotMove(old.subjectPersonIDs.count)
            }
            // Resolve against the archive as it stands; `resolveSubject`
            // may append a new linked person to `people` (never removes).
            let index = try CyberBrainIndex(archive: archive)
            let resolved = try resolveSubject(
                target.name, gedcomPersonID: target.gedcomPersonID,
                aliases: target.aliases, index: index, people: &people)
            guard !old.subjectPersonIDs.contains(resolved.id) else {
                let name = people.first { $0.id == resolved.id }?.canonicalName ?? target.name
                throw CorrectionRefusal.sameTarget(name)
            }
            guard let targetIndex = people.firstIndex(where: { $0.id == resolved.id }) else {
                throw CorrectionRefusal.targetMissing
            }
            let newID = uniqueID(
                base: "\(idPrefix(old.id)).\(slug(resolved.id.replacingOccurrences(of: "person.", with: ""))).\(dayString(old.createdAt))",
                taken: Set(people.flatMap(\.items).map(\.id)))
            // The same words, sources, confidence and privacy on the right
            // person, keeping the day it was first written.
            let moved = CyberBrainItem(
                id: newID, kind: old.kind, text: old.text, subjectPersonIDs: [resolved.id],
                eventDate: old.eventDate, place: old.place, sourceIDs: old.sourceIDs,
                confidence: old.confidence, privacy: old.privacy, status: .active,
                disputesItemIDs: [], createdAt: old.createdAt, updatedAt: now,
                service: old.service)
            let retracted = old.withCorrection(
                status: .retracted, updatedAt: now,
                correction: CyberBrainCorrection(
                    action: .moved, reason: .wrongPerson, at: request.date, by: author,
                    movedToPersonID: resolved.id, movedToItemID: newID))
            replace(at: location, with: retracted, in: &people)
            append(moved, toPersonAt: targetIndex, in: &people)
            receipt = CorrectionReceipt(
                archive: rebuilt(archive, people: people), action: .moved,
                itemID: old.id, newItemID: newID, fromPersonID: request.viewedPersonID,
                toPersonID: resolved.id, toPersonName: people[targetIndex].canonicalName,
                createdTargetPerson: resolved.created,
                oldText: old.text, newText: old.text, backupURL: nil)
        }
        try CyberBrainValidator.validate(receipt.archive)
        return receipt
    }

    // MARK: - Durable

    /// Load the archive at `rootURL`, apply the correction, save through
    /// the writer's one atomic path (backup first). On a refusal or any
    /// failure the file on disk is exactly what it was before the call —
    /// and a missing archive is refused WITHOUT creating the directory.
    public static func correct(
        _ request: NoteCorrection,
        rootURL: URL
    ) throws -> CorrectionReceipt {
        let file = rootURL.standardizedFileURL
            .appendingPathComponent(CyberBrainLoader.defaultFilename, isDirectory: false)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw CorrectionRefusal.noArchive
        }
        let (root, existing) = try prepareRoot(rootURL)
        guard let archive = existing else { throw CorrectionRefusal.noArchive }
        let receipt = try correcting(request, in: archive)
        let backup = try save(receipt.archive, root: root, hadExisting: true)
        return receipt.with(backupURL: backup)
    }

    // MARK: - Helpers

    private enum Section { case biography, anecdote, event, note }

    private struct Location {
        let personIndex: Int
        let section: Section
        let itemIndex: Int
        let item: CyberBrainItem
    }

    /// Where an item lives (the person whose section holds it). O(items).
    private static func locate(_ itemID: String, in people: [CyberBrainPerson]) -> Location? {
        for (p, person) in people.enumerated() {
            let sections: [(Section, [CyberBrainItem])] = [
                (.biography, person.biographyPassages), (.anecdote, person.anecdotes),
                (.event, person.lifeEvents), (.note, person.notes),
            ]
            for (section, items) in sections {
                if let i = items.firstIndex(where: { $0.id == itemID }) {
                    return Location(personIndex: p, section: section, itemIndex: i, item: items[i])
                }
            }
        }
        return nil
    }

    private static func replace(at location: Location, with item: CyberBrainItem,
                                in people: inout [CyberBrainPerson]) {
        let p = people[location.personIndex]
        var bio = p.biographyPassages, anec = p.anecdotes, events = p.lifeEvents, notes = p.notes
        switch location.section {
        case .biography: bio[location.itemIndex] = item
        case .anecdote: anec[location.itemIndex] = item
        case .event: events[location.itemIndex] = item
        case .note: notes[location.itemIndex] = item
        }
        people[location.personIndex] = rebuiltPerson(p, bio: bio, anec: anec, events: events, notes: notes)
    }

    /// Appended to the section its kind belongs in (the validator's rule).
    private static func append(_ item: CyberBrainItem, toPersonAt index: Int,
                               in people: inout [CyberBrainPerson]) {
        let p = people[index]
        people[index] = rebuiltPerson(
            p,
            bio: p.biographyPassages + (item.kind == .biography ? [item] : []),
            anec: p.anecdotes + (item.kind == .anecdote ? [item] : []),
            events: p.lifeEvents + (item.kind == .event ? [item] : []),
            notes: p.notes + (item.kind == .note ? [item] : []))
    }

    private static func rebuiltPerson(
        _ p: CyberBrainPerson, bio: [CyberBrainItem], anec: [CyberBrainItem],
        events: [CyberBrainItem], notes: [CyberBrainItem]
    ) -> CyberBrainPerson {
        CyberBrainPerson(
            id: p.id, gedcomPersonID: p.gedcomPersonID, profileStableID: p.profileStableID,
            canonicalName: p.canonicalName, aliases: p.aliases, terminology: p.terminology,
            biographyPassages: bio, anecdotes: anec, lifeEvents: events, notes: notes,
            pronunciations: p.pronunciations)
    }

    private static func rebuilt(_ archive: CyberBrainArchive,
                                people: [CyberBrainPerson]) -> CyberBrainArchive {
        CyberBrainArchive(
            schemaVersion: archive.schemaVersion, archiveID: archive.archiveID,
            displayName: archive.displayName, people: people, sources: archive.sources)
    }

    /// "note" from "note.john-latta.2026-09-29" — the new item keeps the
    /// kind of id the old one had (note / told / research / caption).
    private static func idPrefix(_ id: String) -> String {
        let head = id.split(separator: ".", maxSplits: 1).first.map(String.init) ?? ""
        return head.isEmpty ? "item" : head
    }

    private static func checkedDetail(_ raw: String?,
                                      reason: CyberBrainCorrection.Reason) throws -> String? {
        let detail = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if reason == .other, detail.isEmpty { throw CorrectionRefusal.detailRequired }
        guard detail.count <= CyberBrainCorrection.maximumDetailLength else {
            throw CorrectionRefusal.detailTooLong(detail.count)
        }
        return detail.isEmpty ? nil : detail
    }
}
