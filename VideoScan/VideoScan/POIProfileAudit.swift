// POIProfileAudit.swift
// Audit trail for the People tab (Rick 2026-09-19: "an edit of a person or
// add/subtract a person deserves a log entry for audit level tracking").
//
// Until tonight a plain Save in the person edit sheet wrote nothing: only
// kinship saves, photo adds and folder renames logged. Now EVERY profile
// write, add, delete and undo produces:
//   • one human line in the app log ("[people] edited Libby (4670A796):
//     name 'Libby' → 'Elizabeth'; surname — → 'Breen'; aliases [Libby,
//     Elizabeth] → [Libby]"), and
//   • one JSON line in an append-only journal beside the profiles
//     (App Support/VideoScan/people-audit/people-audit.jsonl; a test host
//     gets a per-process scratch folder — the MediaLedger discipline), so
//     "who was Dan called before, and when did that change?" has an
//     answer with dates.
// The diff is PURE and table-tested; the writers are two small hops.
//
// Codex 2026-09-20 #12: kinships, notes and identity notes are REDACTED
// in the line ("3 kinships", "12 chars") but compared by their ORIGINAL
// values — a changed relationship at equal count, or notes AB → CD, is a
// change and prints "3 → 3 (changed)". And the journal appends go through
// ONE ordered worker chain (MediaLedger's tail-Task pattern), so two rapid
// edits land in submission order; second-resolution JSON dates could not
// recover the order once two detached tasks had raced.
//
// (For Rick: `Change` is a POD; `changes(before:after:)` is a field-by-
// field compare over the identity fields only — thresholds, crop offsets
// and sort order are settings, not identity, and stay out of the audit.
// The journal chain ≈ a single-thread work queue: each job awaits the one
// before it, so order is submission order, whatever the scheduler does.)

import Foundation

enum POIProfileAudit {

    enum Action: String, Codable, Sendable { case added, edited, deleted, restored }

    struct Change: Equatable, Codable, Sendable {
        let field: String
        let from: String
        let to: String
    }

    struct Entry: Codable, Sendable {
        let at: Date
        let action: Action
        let uuid: UUID
        /// The display name AFTER the change (before it, for a delete).
        let display: String
        let name: String
        let changes: [Change]
    }

    static let journalFilename = "people-audit.jsonl"
    /// Appended to a redacted display when the values differ but the
    /// redaction does not ("3 → 3 (changed)").
    static let changedSuffix = " (changed)"

    /// App Support/VideoScan/people-audit/ — the production home. Under a
    /// test host: a per-process scratch folder (never the real journal).
    nonisolated static var defaultDirectory: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/people-audit-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan/people-audit", isDirectory: true)
    }

    // MARK: Pure diff

    /// The identity fields, in the order the line prints them.
    static func changes(before: POIProfile?, after: POIProfile?) -> [Change] {
        var out: [Change] = []
        func field(_ name: String, _ b: String?, _ a: String?) {
            let bs = b ?? "", as_ = a ?? ""
            if bs != as_ { out.append(Change(field: name, from: bs, to: as_)) }
        }
        /// A REDACTED field: equality is decided on the original values;
        /// the display is the redaction, marked when it would hide the
        /// change ("12 chars → 12 chars (changed)").
        func redacted<V: Equatable>(_ name: String, _ b: V?, _ a: V?, show: (V) -> String) {
            guard b != a else { return }
            let bs = b.map(show) ?? "", as_ = a.map(show) ?? ""
            out.append(Change(field: name, from: bs, to: bs == as_ ? as_ + changedSuffix : as_))
        }
        func list(_ xs: [String]?) -> String? { (xs ?? []).isEmpty ? nil : (xs ?? []).joined(separator: ", ") }
        field("name", before?.name, after?.name)
        field("middleName", before?.middleName, after?.middleName)
        field("surname", before?.surname, after?.surname)
        field("maidenName", before?.maidenName, after?.maidenName)
        field("suffix", before?.suffix, after?.suffix)
        field("aliases", list(before?.aliases), list(after?.aliases))
        field("titles", list(before?.titles), list(after?.titles))
        field("birthdate", before?.birthdate.map(day), after?.birthdate.map(day))
        field("deathdate", before?.deathdate.map(day), after?.deathdate.map(day))
        field("sex", before?.sex.map { String(describing: $0) }, after?.sex.map { String(describing: $0) })
        field("hairColor", before?.hairColor.map { String(describing: $0) }, after?.hairColor.map { String(describing: $0) })
        field("eyeColor", before?.eyeColor.map { String(describing: $0) }, after?.eyeColor.map { String(describing: $0) })
        field("notInFamilyTree", before.map { $0.notInFamilyTree ? "yes" : "no" }, after.map { $0.notInFamilyTree ? "yes" : "no" })
        redacted("kinships", before?.kinships, after?.kinships) { "\($0.count)" }
        redacted("notes", before?.notes, after?.notes) { "\($0.count) chars" }
        redacted("identityNotes", before?.identityNotes, after?.identityNotes) { "\($0.count) chars" }
        field("coverImage", before?.coverImageFilename, after?.coverImageFilename)
        return out
    }

    /// The app-log line. `before == nil` = added; `after == nil` = deleted.
    static func line(action: Action, before: POIProfile?, after: POIProfile?) -> String {
        let subject = after ?? before
        let display = subject?.displayName ?? "?"
        let short = subject.map { String($0.uuid.uuidString.prefix(8)) } ?? "?"
        var head = "[people] \(action.rawValue) \(display) (\(short))"
        if let s = subject, s.displayName != s.name { head += " — \(s.name)" }
        switch action {
        case .added:
            let facts = changes(before: nil, after: after).filter { $0.field != "kinships" && $0.field != "notes" }
            return head + (facts.isEmpty ? "" : ": " + facts.map { "\($0.field) \(quote($0.to))" }.joined(separator: "; "))
        case .deleted, .restored:
            return head
        case .edited:
            let diff = changes(before: before, after: after)
            if diff.isEmpty { return head + ": saved, no identity field changed" }
            return head + ": " + diff.map { "\($0.field) \(quote($0.from)) → \(quote($0.to))" }.joined(separator: "; ")
        }
    }

    static func entry(action: Action, before: POIProfile?, after: POIProfile?, at: Date = Date()) -> Entry? {
        guard let subject = after ?? before else { return nil }
        return Entry(at: at, action: action, uuid: subject.uuid, display: subject.displayName, name: subject.name,
                     changes: action == .edited ? changes(before: before, after: after) : changes(before: nil, after: subject))
    }

    // MARK: Writers

    /// The append seam: production writes the line; a test can delay or
    /// refuse (the MediaLedger `Writer` discipline).
    typealias Writer = @Sendable (Entry, URL) throws -> Void
    static let liveWriter: Writer = { e, directory in try append(e, directory: directory) }

    /// ONE ordered worker chain for the journal — every `record()` queues
    /// behind the one before it, so the file order IS the submission
    /// order. Process-wide, like the journal file itself.
    private static let journal = OrderedWorker()

    /// Log + journal. Called by the model after a successful write. The
    /// log line is immediate; the journal append is queued on the ordered
    /// worker and lands off the main actor.
    static func record(action: Action, before: POIProfile?, after: POIProfile?,
                       directory: URL = defaultDirectory, at: Date = Date(),
                       writer: @escaping Writer = liveWriter) {
        appLog.write(line(action: action, before: before, after: after))
        guard let e = entry(action: action, before: before, after: after, at: at) else { return }
        journal.enqueue {
            do { try writer(e, directory) } catch {
                appLog.write("[people] audit journal not written — \(error.localizedDescription)")
            }
        }
    }

    /// Wait for every `record()` issued so far to land (tests, teardown).
    static func waitForPendingWrites() async {
        await journal.waitForPendingWrites()
    }

    nonisolated static func append(_ e: Entry, directory: URL) throws {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        var data = try enc.encode(e)
        data.append(0x0A)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try MediaLedger.appendDurable(data, to: directory.appendingPathComponent(journalFilename))
    }

    /// Every journal line, file order (diagnostics / tests).
    nonisolated static func entries(directory: URL = defaultDirectory) -> [Entry] {
        guard let text = try? String(contentsOf: directory.appendingPathComponent(journalFilename), encoding: .utf8) else { return [] }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return text.split(whereSeparator: \.isNewline).compactMap { try? dec.decode(Entry.self, from: Data($0.utf8)) }
    }

    // MARK: helpers

    private static func quote(_ s: String) -> String { s.isEmpty ? "—" : "'\(s)'" }

    private static func day(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// A tail-chained task queue: each job awaits its predecessor, so
    /// jobs run one at a time in submission order, off the caller's
    /// actor. (MediaLedger keeps the same shape inline; this is the
    /// reusable version for a static façade.)
    final class OrderedWorker: @unchecked Sendable {
        private let lock = NSLock()
        private var tail: Task<Void, Never>?

        func enqueue(_ work: @escaping @Sendable () -> Void) {
            let previous: Task<Void, Never>? = lock.withLock { tail }
            let task = Task.detached(priority: .utility) {
                await previous?.value
                work()
            }
            lock.withLock { tail = task }
        }

        func waitForPendingWrites() async {
            let t: Task<Void, Never>? = lock.withLock { tail }
            await t?.value
        }
    }
}
