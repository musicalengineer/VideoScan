// HallieKindWords.swift
// Rick's "kind words" (2026-09-21): a flattering line or two he wrote for
// each family member, which Hallie says in her own answer.
//
//   • When anyone asks about a person who has kind words — a biography /
//     "tell me about X" / "who is X" answer, tree or People-tab route —
//     ONE of that person's lines is added as its own sentence at the end
//     of the answer (before a trailing "want to see them all?" offer).
//     Rick's amended rule: "it is OK for everyone to hear any of these kind
//     words, say beth asks about ellen, she should hear the good."
//   • When the current user greets Hallie, the greeting may carry one of
//     THEIR OWN lines.
//   • At most once per subject (and once for the greeting) per Hallie
//     conversation; a reset clears it. A person with several lines gets
//     them in rotation across conversations.
//
// What it is NOT: a fact. The line is Rick's voice, never a claim — it is
// appended by Swift AFTER composition and verification (the verifier never
// judges it), carries no [cN] citation, never enters an answer plan, and is
// never written anywhere (no CyberBrain, no biography store, no Publish).
// Catalog / count / search / age / date / kinship answers never get one:
// only a biography AST qualifies.
//
// DATA: ~/Library/Application Support/VideoScan/hallie/kind-words.json,
// private, NOT in the repo, keyed by POIProfile.uuid so a rename of the
// profile's name or aliases never breaks it:
//   {"schemaVersion":1, "note":…, "people": {"<uuid>": {"display":"Beth",
//     "lines":[{"text":…, "addedAt":…, "by":"Rick", "updatedAt"?:…}]}}}
// Read only. Missing / malformed → no kind words and ONE log line, never
// an error to the user. The log never carries a line's text.
//
// Memory: the whole file is decoded into one small value (a handful of
// people, a few short lines each). Worst case is bounded by the file size;
// files larger than `maximumFileBytes` (256 KB) are refused as malformed.

import Foundation
import VideoScanCore

// MARK: - The decoded file

/// Everything the file says, keyed by People-profile UUID. A value type:
/// the store hands out copies, so no caller can see a half-reloaded book.
struct HallieKindWordsBook: Sendable, Equatable {
    struct Person: Sendable, Equatable {
        /// The short name the log line uses ("Beth"). Never matched on.
        let display: String
        /// The lines, in file order, each already a finished sentence.
        let lines: [String]
    }

    let people: [UUID: Person]

    static let empty = HallieKindWordsBook(people: [:])

    var isEmpty: Bool { people.isEmpty }

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case unsupportedSchema(Int)
        case tooLarge(Int)

        var description: String {
            switch self {
            case .unsupportedSchema(let v): return "unsupported schemaVersion \(v)"
            case .tooLarge(let n): return "file too large (\(n) bytes)"
            }
        }
    }

    static let supportedSchemaVersion = 1
    static let maximumFileBytes = 256 * 1024

    // The on-disk shape. Unknown keys ("note", "addedAt", "by",
    // "updatedAt") are ignored by Codable, so Rick can add bookkeeping
    // fields without breaking the reader.
    private struct RawFile: Decodable {
        let schemaVersion: Int
        let people: [String: RawPerson]
    }
    private struct RawPerson: Decodable {
        let display: String?
        let lines: [RawLine]
    }
    private struct RawLine: Decodable {
        let text: String
    }

    /// Strict about the envelope, lenient about entries: a key that is not
    /// a UUID or a person with no usable line is skipped, not fatal.
    static func decode(_ data: Data) throws -> HallieKindWordsBook {
        guard data.count <= maximumFileBytes else { throw DecodeError.tooLarge(data.count) }
        let raw = try JSONDecoder().decode(RawFile.self, from: data)
        guard raw.schemaVersion == supportedSchemaVersion else {
            throw DecodeError.unsupportedSchema(raw.schemaVersion)
        }
        var people: [UUID: Person] = [:]
        for (key, person) in raw.people {
            guard let uuid = UUID(uuidString: key.trimmingCharacters(in: .whitespaces)) else { continue }
            let lines = person.lines.compactMap { sentence($0.text) }
            guard !lines.isEmpty else { continue }
            let display = person.display?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            people[uuid] = Person(display: display.isEmpty ? "someone" : display, lines: lines)
        }
        return HallieKindWordsBook(people: people)
    }

    /// One line as a finished sentence: whitespace collapsed, a period
    /// added only when it has no closing punctuation. Nil when empty.
    static func sentence(_ text: String) -> String? {
        let collapsed = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard let last = collapsed.last else { return nil }
        if ".!?…\"”'’)".contains(last) { return collapsed }
        return collapsed + "."
    }
}

// MARK: - The store (read-only, cached by mtime)

/// Reads kind-words.json from an injectable directory and caches the
/// decoded book until the file's modification date or size changes.
///
/// C++ analogy: a class with a mutex around its cache; `@unchecked
/// Sendable` is our promise to the compiler that the lock makes sharing
/// across threads safe. Called off the main actor (the coordinator's
/// detached worker, the shell) — it does one stat per call, and a read +
/// decode only when the file changed.
final class HallieKindWordsStore: @unchecked Sendable {
    static let fileName = "kind-words.json"

    /// App Support/VideoScan/hallie/ in production. Under a test host a
    /// per-process scratch folder, never the real file (same idiom as
    /// POIProfileAudit.defaultDirectory).
    nonisolated static var defaultDirectory: URL {
        if TestEnvironment.isTestHost {
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("VideoScan-tests/hallie-kind-\(ProcessInfo.processInfo.processIdentifier)",
                                        isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("VideoScan/hallie", isDirectory: true)
    }

    static let shared = HallieKindWordsStore(directory: defaultDirectory)

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent(Self.fileName) }

    private struct Stamp: Equatable {
        let modified: Date?
        let size: Int
    }

    /// What the log last said about the file, so a missing or broken file
    /// costs ONE line, not one per question.
    private enum State: Equatable {
        case unread, missing, malformed, loaded
    }

    private let lock = NSLock()
    private var stamp: Stamp?
    private var cached: HallieKindWordsBook = .empty
    private var state: State = .unread
    private let log: @Sendable (String) -> Void

    init(directory: URL, log: @escaping @Sendable (String) -> Void = { appLog.write($0) }) {
        self.directory = directory
        self.log = log
    }

    /// The current book. Never throws; a missing or malformed file is the
    /// empty book.
    func book() -> HallieKindWordsBook {
        lock.lock()
        defer { lock.unlock() }
        let url = fileURL
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            stamp = nil
            cached = .empty
            transition(to: .missing, "[hallie-kind] no kind words file; none will be said")
            return cached
        }
        let current = Stamp(modified: attributes[.modificationDate] as? Date,
                            size: (attributes[.size] as? NSNumber)?.intValue ?? -1)
        if current == stamp, state != .unread { return cached }
        stamp = current
        do {
            let data = try Data(contentsOf: url)
            cached = try HallieKindWordsBook.decode(data)
            let count = cached.people.count
            transition(to: .loaded, "[hallie-kind] loaded kind words for \(count) \(count == 1 ? "person" : "people")", force: true)
        } catch {
            cached = .empty
            // The error's TYPE only — a DecodingError description could
            // quote a fragment of the file, and the file is private.
            let reason = (error as? HallieKindWordsBook.DecodeError)?.description
                ?? (error is DecodingError ? "not the expected JSON shape" : "unreadable")
            transition(to: .malformed, "[hallie-kind] kind words file ignored (\(reason)); none will be said")
        }
        return cached
    }

    private func transition(to next: State, _ line: String, force: Bool = false) {
        guard force || next != state else { return }
        state = next
        log(line)
    }
}

// MARK: - Rotation

/// Which of a person's lines comes next. Process memory only — never
/// written — so a person with three lines hears them in turn across
/// conversations, and a fresh shell replay always starts at the first.
final class HallieKindWordsRotation: @unchecked Sendable {
    static let shared = HallieKindWordsRotation()

    private let lock = NSLock()
    private var cursor: [UUID: Int] = [:]

    /// The index to say now, advancing the cursor for next time.
    func next(for uuid: UUID, count: Int) -> Int {
        guard count > 0 else { return 0 }
        lock.lock()
        defer { lock.unlock() }
        let index = (cursor[uuid] ?? 0) % count
        cursor[uuid] = index + 1
        return index
    }
}

// MARK: - Decisions

enum HallieKindWords {
    /// A kind word that MAY be said with this answer — resolved off the
    /// main actor where the identity context lives, then applied (or not)
    /// by the client that owns the conversation memory.
    struct Offer: Sendable, Equatable {
        enum Occasion: Sendable, Equatable {
            /// A biography about the person.
            case subject
            /// The current user's own line in a greeting.
            case greeting
        }

        let uuid: UUID
        let display: String
        let lines: [String]
        let occasion: Occasion
        /// The prose the line goes right after. For a biography it is the
        /// whole answer as composed, so an offer sentence appended later
        /// ("want to see them all?") stays last; for a greeting it is the
        /// hello before "How can I help?".
        let anchor: String
    }

    /// The greeting reply the line is woven into, split at its question.
    static let greetingQuestion = "How can I help?"

    // MARK: Gates

    /// A biography answer: the graph route, answered, no which-one pending,
    /// and the executed question was a biography. Nothing else qualifies —
    /// catalog, count, search, age, date and kinship answers have other
    /// shapes and never reach the book.
    static func isBiographyAnswer(_ result: HallieTurnExecutor.Result,
                                  ast: ArchivistQueryAST?) -> Bool {
        guard result.route == .graph, result.outcome == .answered,
              result.clarification == nil,
              case .graph(let payload)? = ast, payload.operation == .biography else { return false }
        return true
    }

    /// The fixed deterministic greeting ("hi hallie", "good morning").
    static func isGreeting(_ result: HallieTurnExecutor.Result) -> Bool {
        result.route == .smalltalk
            && result.prose == ArchivistConversationCommand.smalltalkReply(.greeting)
    }

    // MARK: Offers

    /// The kind word for a biography answer's subject, or nil. `selected`
    /// is the identity a which-one chip picked, when the answer continued
    /// one. `loadBook` is only called once the answer qualifies.
    static func biographyOffer(
        result: HallieTurnExecutor.Result,
        ast: ArchivistQueryAST?,
        selected: HallieTurnExecutor.CandidateID? = nil,
        profiles: [HallieTurnExecutor.ProfileSnapshot]?,
        graph: GedcomFamilyGraph?,
        loadBook: () -> HallieKindWordsBook
    ) -> Offer? {
        guard isBiographyAnswer(result, ast: ast),
              case .graph(let payload)? = ast else { return nil }
        let book = loadBook()
        guard !book.isEmpty else { return nil }
        let typed = payload.people.count == 1 ? payload.people[0] : nil
        guard let profile = subjectProfile(
                  answeredName: result.catalogPersonName, typed: typed, selected: selected,
                  profiles: profiles, graph: graph),
              let uuid = profileUUID(profile),
              let person = book.people[uuid] else { return nil }
        return Offer(uuid: uuid, display: person.display, lines: person.lines,
                     occasion: .subject, anchor: result.prose)
    }

    /// The current user's own kind word for a greeting, or nil.
    static func greetingOffer(
        result: HallieTurnExecutor.Result,
        speakers: HallieTurnExecutor.Speakers,
        profiles: [HallieTurnExecutor.ProfileSnapshot]?,
        loadBook: () -> HallieKindWordsBook
    ) -> Offer? {
        guard isGreeting(result) else { return nil }
        let book = loadBook()
        guard !book.isEmpty,
              let profile = ownerProfile(speakers: speakers, profiles: profiles),
              let uuid = profileUUID(profile),
              let person = book.people[uuid] else { return nil }
        let anchor: String
        if result.prose.hasSuffix(greetingQuestion) {
            anchor = String(result.prose.dropLast(greetingQuestion.count))
                .trimmingCharacters(in: .whitespaces)
        } else {
            anchor = result.prose
        }
        return Offer(uuid: uuid, display: person.display, lines: person.lines,
                     occasion: .greeting, anchor: anchor)
    }

    // MARK: Identity (existing resolution, reused — never a new matcher)

    /// The People profile a biography was about.
    ///
    /// Order, each step failing CLOSED (nil, no kind word) rather than
    /// guessing:
    ///   1. a which-one chip's own identity (profile directly; a tree
    ///      record through the profile that uniquely pins it);
    ///   2. the name the answer settled on: a unique tree record → the
    ///      profile that pins it (HallieVitalDates.pinOwnership); otherwise
    ///      an EXACT People-tab claim of that name (PeopleTab.claim). Two
    ///      tree records by that name → nil;
    ///   3. only when the answer named nobody (a People-tab answer for an
    ///      untagged person) — an exact claim of the typed spelling.
    /// A tree biography about a namesake nobody pinned never falls back to
    /// the typed spelling, so "ellen" can't pull Ellen's line into an
    /// answer about a different Ellen.
    static func subjectProfile(
        answeredName: String?,
        typed: String?,
        selected: HallieTurnExecutor.CandidateID?,
        profiles: [HallieTurnExecutor.ProfileSnapshot]?,
        graph: GedcomFamilyGraph?
    ) -> HallieTurnExecutor.ProfileSnapshot? {
        guard let profiles, !profiles.isEmpty else { return nil }
        // Lazily computed: one pass over the profiles, only when needed.
        var ownershipCache: HallieVitalDates.PinOwnership?
        func owner(ofTreePerson id: String) -> HallieTurnExecutor.ProfileSnapshot? {
            let ownership = ownershipCache ?? HallieVitalDates.pinOwnership(
                profiles: profiles.map(HallieVitalProfile.init), graph: graph)
            ownershipCache = ownership
            guard let stableID = ownership.profileStableID(owning: id) else { return nil }
            return profiles.first { $0.stableID == stableID }
        }
        func exactClaim(_ spelling: String) -> HallieTurnExecutor.ProfileSnapshot? {
            let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            if case .one(let profile) = HallieTurnExecutor.PeopleTab.claim(
                trimmed, in: profiles, matching: .exact) {
                return profile
            }
            return nil
        }

        switch selected {
        case .profileStableID(let id)?:
            return profiles.first { $0.stableID == id }
        case .gedcomPersonID(let id)?:
            return owner(ofTreePerson: id)
        case .cyberBrainPersonID?, nil:
            break
        }

        if let name = answeredName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            // The same by-name tree match the coordinator's photo and
            // gallery offers use for a biography subject.
            let matches = graph?.people.values.filter {
                $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
            } ?? []
            if matches.count > 1 { return nil }
            if matches.count == 1, let pinned = owner(ofTreePerson: matches[0].id) {
                return pinned
            }
            return exactClaim(name)
        }
        return typed.flatMap(exactClaim)
    }

    /// The current user's People profile: the configured FamilySearch ID
    /// when a profile pins exactly that ID, else an exact People-tab claim
    /// of the owner's name ("Rick Breen", or the web reader's "Beth").
    /// No tree lookup, so the app and the shell decide identically without
    /// loading the family tree for a hello.
    static func ownerProfile(
        speakers: HallieTurnExecutor.Speakers,
        profiles: [HallieTurnExecutor.ProfileSnapshot]?
    ) -> HallieTurnExecutor.ProfileSnapshot? {
        guard let profiles, !profiles.isEmpty else { return nil }
        if let fsid = speakers.ownerFamilySearchID {
            let pinned = profiles.filter {
                if case .familySearchID(let id)? = $0.treeIdentity {
                    return id.uppercased() == fsid.uppercased()
                }
                return false
            }
            if pinned.count == 1 { return pinned[0] }
        }
        guard let name = speakers.ownerName else { return nil }
        return subjectProfile(answeredName: nil, typed: name, selected: nil,
                              profiles: profiles, graph: nil)
    }

    /// The key into the book: the profile's UUID, or a stableID that IS
    /// one (older snapshots carried only the stable ID).
    static func profileUUID(_ profile: HallieTurnExecutor.ProfileSnapshot) -> UUID? {
        profile.uuid ?? UUID(uuidString: profile.stableID)
    }

    // MARK: Applying

    /// Say the offer's next line with `result` — unless this conversation
    /// already heard this person's line (or the greeting's). Marks the
    /// memory and writes one log line (display name and index, never the
    /// text). Returns `result` unchanged when nothing is said.
    static func apply(
        _ offer: Offer?,
        to result: HallieTurnExecutor.Result,
        memory: inout HallieTurnExecutor.ConversationMemory,
        rotation: HallieKindWordsRotation = .shared,
        log: (String) -> Void = { appLog.write($0) }
    ) -> HallieTurnExecutor.Result {
        guard let offer, !offer.lines.isEmpty else { return result }
        switch offer.occasion {
        case .subject:
            guard !memory.kindWordSubjects.contains(offer.uuid) else { return result }
            memory.noteKindWord(about: offer.uuid)
        case .greeting:
            guard !memory.kindWordGreetingSaid else { return result }
            memory.noteGreetingKindWord()
        }
        let index = rotation.next(for: offer.uuid, count: offer.lines.count)
        log("[hallie-kind] added a kind word for \(offer.display) (\(index + 1) of \(offer.lines.count))")
        return result.insertingKindWord(offer.lines[index], after: offer.anchor)
    }
}

// MARK: - Result / Response copies

extension HallieTurnExecutor.Result {
    /// The same answer with one plain sentence placed right after `anchor`
    /// (or at the end when the prose no longer starts with it). Facts,
    /// basis, citations, the answer plan and every other field are
    /// untouched: the sentence is Rick's voice, never a claim.
    func insertingKindWord(_ line: String, after anchor: String) -> HallieTurnExecutor.Result {
        func join(_ head: String, _ tail: String) -> String {
            let h = head.trimmingCharacters(in: .whitespaces)
            let t = tail.trimmingCharacters(in: .whitespaces)
            if h.isEmpty { return t.isEmpty ? line : line + " " + t }
            return t.isEmpty ? h + " " + line : h + " " + line + " " + t
        }
        let newProse: String
        let tail: String
        if !anchor.isEmpty, prose.hasPrefix(anchor) {
            tail = String(prose.dropFirst(anchor.count))
            newProse = join(anchor, tail)
        } else {
            tail = ""
            newProse = join(prose, "")
        }
        // The tagged transcript text: before the same tail when it ends
        // with it (the offer sentence is appended to both), else at the end.
        let newTranscript = transcriptText.map { text -> String in
            let t = tail.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty, text.hasSuffix(t) {
                return join(String(text.dropLast(t.count)), t)
            }
            return join(text, "")
        }
        return HallieTurnExecutor.Result(
            route: route,
            outcome: outcome,
            prose: newProse,
            basisLine: basisLine,
            queryDescription: queryDescription,
            citations: citations,
            knowledgeCitations: knowledgeCitations,
            catalogPersonName: catalogPersonName,
            clarification: clarification,
            matchCount: matchCount,
            mediaAction: mediaAction,
            offeredActions: offeredActions,
            answerPlan: answerPlan,
            composedBy: composedBy,
            transcriptText: newTranscript,
            attachments: attachments,
            performsFirstOfferedAction: performsFirstOfferedAction,
            immediateOfferedAction: immediateOfferedAction,
            subjectLifeStatus: subjectLifeStatus,
            refinableQuery: refinableQuery,
            retryOffer: retryOffer,
            mode: mode,
            modeForce: modeForce)
    }
}

extension HallieAppTurnCoordinator.Response {
    /// The response as the conversation hears it: the pending kind word
    /// said (or dropped) against this conversation's memory. Idempotent —
    /// the offer is consumed.
    func applyingKindWord(
        memory: inout HallieTurnExecutor.ConversationMemory,
        rotation: HallieKindWordsRotation = .shared
    ) -> HallieAppTurnCoordinator.Response {
        guard let offer = kindWord else { return self }
        var copy = self
        copy.result = HallieKindWords.apply(offer, to: result, memory: &memory, rotation: rotation)
        copy.kindWord = nil
        return copy
    }
}
