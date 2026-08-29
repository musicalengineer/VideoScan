// HalliePronunciationLexicon.swift
// Family-name pronunciations for Hallie's neural voice. Kokoro says
// "McGill" as "Mic Gill" and "Edith" as "Ed-ith"; the audited spellings here
// are substituted into the PRIVATE string sent to speech synthesis only —
// Hallie's visible answer and the catalog are never rewritten.
//
// Three layers, first match wins per word (2026-08-26, Rick: "a
// pronunciation key somewhere next to aliases"):
//   1. per-person entries on CyberBrain person records
//      (`CyberBrainPerson.pronunciations`, edited from the Family Tree
//      inspector or by telling Hallie "Nathaniel is pronounced …"),
//   2. the user-editable JSON object of written → spoken at
//      ~/Library/Application Support/VideoScan/Hallie/pronunciations.json
//      (written from the shipped default on first use so the format is
//      visible),
//   3. the shipped default below.
// Because the lexicon is word-based, a person-level entry applies to that
// WORD wherever it appears in spoken text — "Nathaniel" on Nathaniel
// McGill's record also respells any other Nathaniel. That is the intended
// scope: a name is said the same way whoever carries it.
//
// Matches are whole-word and case-insensitive; possessives survive
// ("McGill's" → "muh-GILL's"). Every entry that fires is logged with the
// layer it came from so a bad respelling can be traced to its line.

import Foundation
import VideoScanCore

struct HalliePronunciationLexicon: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let written: String
        let spoken: String
    }

    /// Where an entry came from — provenance for the log line, not part of
    /// an entry's identity (two layers can carry the same word).
    enum Source: Equatable, Sendable, CustomStringConvertible {
        case person(id: String, name: String)
        case file
        case shipped

        var description: String {
            switch self {
            case .person(_, let name): return "person \(name)"
            case .file: return "pronunciations.json"
            case .shipped: return "shipped"
            }
        }
    }

    let entries: [Entry]
    /// Normalised written word → layer. Parallel to `entries`; provenance
    /// only, so two tables with the same words are equal whichever layer
    /// they came from (the `==` below is entries-only on purpose).
    private let sourcesByWord: [String: Source]

    static func == (lhs: HalliePronunciationLexicon, rhs: HalliePronunciationLexicon) -> Bool {
        lhs.entries == rhs.entries
    }

    /// Shipped default — the Scots-Irish/Irish set Rick audited 2026-08-26
    /// plus the 8/25 Edith fix and the 8/26 Nathaniel/Bethiah additions.
    /// Keys are what the family tree spells.
    static let shipped = HalliePronunciationLexicon(entries: [
        Entry(written: "Edith", spoken: "EE-dith"),
        Entry(written: "McGill", spoken: "muh-GILL"),
        Entry(written: "McDonald", spoken: "muh-DON-uld"),
        Entry(written: "McCarthy", spoken: "muh-CAR-thee"),
        Entry(written: "McLaughlin", spoken: "muh-GLOCK-lin"),
        Entry(written: "Latta", spoken: "LAT-uh"),
        Entry(written: "Nathaniel", spoken: "nuh-THAN-yul"),
        Entry(written: "Bethiah", spoken: "beh-THY-uh"),
        // Audited as already correct (2026-08-26; "BREEN" and "LAM" measured
        // no better on the installed Kokoro). Identity entries are listed so
        // the JSON shows the family set, and never fire.
        Entry(written: "Breen", spoken: "Breen"),
        Entry(written: "Ronan", spoken: "ROW-nin"),
        Entry(written: "Lamb", spoken: "Lamb"),
        Entry(written: "Hendour", spoken: "HEN-door"),
    ], source: .shipped)

    static let fileName = "pronunciations.json"

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("VideoScan/Hallie", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Where the CyberBrain lives — the same directory Hallie answers from
    /// and the telling mode writes.
    static var defaultCyberBrainRootURL: URL? { FamilyTreeNotesStorage.productionRootURL }

    /// A single-layer table; every entry gets `source`.
    init(entries: [Entry], source: Source = .file) {
        self.init(entries: entries, sources: Dictionary(
            entries.map { (Self.key($0.written), source) }, uniquingKeysWith: { first, _ in first }))
    }

    private init(entries: [Entry], sources: [String: Source]) {
        // Longest written form first so "McLaughlin" is never shadowed by a
        // shorter key; deterministic order for the log line.
        self.entries = entries.sorted {
            $0.written.count != $1.written.count ? $0.written.count > $1.written.count : $0.written < $1.written
        }
        self.sourcesByWord = sources
    }

    /// JSON object {"McGill": "muh-GILL", …}. Empty or non-string values are
    /// dropped; a malformed file throws so the caller can log it.
    init(jsonData: Data) throws {
        let object = try JSONSerialization.jsonObject(with: jsonData)
        guard let table = object as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }
        self.init(entries: table.compactMap { key, value in
            guard let spoken = value as? String else { return nil }
            let written = key.trimmingCharacters(in: .whitespaces)
            let said = spoken.trimmingCharacters(in: .whitespaces)
            guard !written.isEmpty, !said.isEmpty else { return nil }
            return Entry(written: written, spoken: said)
        }, source: .file)
    }

    var jsonData: Data {
        let table = Dictionary(uniqueKeysWithValues: entries.map { ($0.written, $0.spoken) })
        return (try? JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    }

    // MARK: - Layers

    /// The per-person layer: every `pronunciations` entry on every CyberBrain
    /// person. A word that two records both claim (two Nathaniels with
    /// different respellings) is resolved deterministically and the choice
    /// is logged (codex #700, 2026-08-26):
    ///   1. the record for `subject` — the person the current answer is
    ///      about, given as a CyberBrain id or a canonical name/alias — when
    ///      it carries the word;
    ///   2. else the most recently updated record (newest item timestamp —
    ///      the schema has no per-entry timestamps, so a record with no
    ///      items sorts last);
    ///   3. else the lowest id.
    static func personLayer(
        people: [CyberBrainPerson],
        subject: String? = nil,
        log: LogSink? = nil
    ) -> HalliePronunciationLexicon {
        typealias Claim = (person: CyberBrainPerson, written: String, spoken: String)
        let subjectKey = subject.map { FamilyIdentityText.normalized($0) } ?? ""
        func isSubject(_ person: CyberBrainPerson) -> Bool {
            guard !subjectKey.isEmpty else { return false }
            if person.id == subject { return true }
            return ([person.canonicalName] + person.aliases).contains {
                FamilyIdentityText.normalized($0) == subjectKey
            }
        }
        func updated(_ person: CyberBrainPerson) -> Date {
            person.items.map(\.updatedAt).max() ?? .distantPast
        }

        var claims: [String: [Claim]] = [:]
        var order: [String] = []
        for person in people.sorted(by: { $0.id < $1.id }) {
            for (word, spoken) in (person.pronunciations ?? [:]).sorted(by: { $0.key < $1.key }) {
                let written = word.trimmingCharacters(in: .whitespaces)
                let said = spoken.trimmingCharacters(in: .whitespaces)
                guard !written.isEmpty, !said.isEmpty else { continue }
                let wordKey = key(written)
                if claims[wordKey] == nil { order.append(wordKey) }
                claims[wordKey, default: []].append((person, written, said))
            }
        }

        var entries: [Entry] = []
        var sources: [String: Source] = [:]
        for wordKey in order {
            guard let list = claims[wordKey], let first = list.first else { continue }
            var chosen = first
            var reason = ""
            if list.count > 1 {
                if let own = list.first(where: { isSubject($0.person) }) {
                    chosen = own
                    reason = "subject of this answer"
                } else {
                    // Newest first; ties (including "no items at all") by id.
                    chosen = list.sorted {
                        let (a, b) = (updated($0.person), updated($1.person))
                        return a != b ? a > b : $0.person.id < $1.person.id
                    }[0]
                    reason = updated(chosen.person) == .distantPast ? "lowest id" : "most recently updated"
                }
                let names = list.map { "\($0.person.canonicalName) → \($0.spoken)" }.joined(separator: ", ")
                log?.write("[hallie-voice] '\(chosen.written)' carried by \(list.count) records (\(names)); using \(chosen.person.canonicalName) → \(chosen.spoken) (\(reason))")
            }
            entries.append(Entry(written: chosen.written, spoken: chosen.spoken))
            sources[wordKey] = .person(id: chosen.person.id, name: chosen.person.canonicalName)
        }
        return HalliePronunciationLexicon(entries: entries, sources: sources)
    }

    /// Merge layers, highest priority first; the first layer that carries a
    /// word (case-insensitively) owns it.
    static func merged(_ layers: [HalliePronunciationLexicon]) -> HalliePronunciationLexicon {
        var entries: [Entry] = []
        var sources: [String: Source] = [:]
        for layer in layers {
            for entry in layer.entries where sources[key(entry.written)] == nil {
                entries.append(entry)
                sources[key(entry.written)] = layer.sourcesByWord[key(entry.written)] ?? .file
            }
        }
        return HalliePronunciationLexicon(entries: entries, sources: sources)
    }

    /// The layer an entry came from (after `merged`); `.file` for a table
    /// built directly from JSON.
    func source(of entry: Entry) -> Source {
        sourcesByWord[Self.key(entry.written)] ?? .file
    }

    /// What Bella reads from on the next utterance: people → file → shipped.
    /// Cheap enough to call per utterance: the file is tiny and the
    /// CyberBrain records are cached by (path, mtime, size). `subject` is
    /// the person the utterance is about (id or name), used only to break
    /// ties between records that claim the same word.
    static func resolved(
        fileURL: URL = defaultFileURL,
        cyberBrainRootURL: URL? = defaultCyberBrainRootURL,
        subject: String? = nil,
        log: LogSink? = appLog
    ) -> HalliePronunciationLexicon {
        var layers: [HalliePronunciationLexicon] = []
        if let root = cyberBrainRootURL {
            layers.append(PersonPronunciationCache.shared.layer(rootURL: root, subject: subject, log: log))
        }
        layers.append(load(from: fileURL, log: log))
        layers.append(shipped)
        return merged(layers)
    }

    /// The user's table, or the shipped default when the file does not exist
    /// (in which case the default is written there so it can be edited) or
    /// cannot be parsed (logged; the file is left alone for the user to fix).
    static func load(from url: URL = defaultFileURL, log: LogSink? = appLog) -> HalliePronunciationLexicon {
        guard FileManager.default.fileExists(atPath: url.path) else {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try shipped.jsonData.write(to: url, options: .atomic)
                log?.write("[hallie-voice] wrote default pronunciations to \(url.path)")
            } catch {
                log?.write("[hallie-voice] could not write default pronunciations to \(url.path): \(error.localizedDescription)")
            }
            return shipped
        }
        do {
            return try HalliePronunciationLexicon(jsonData: Data(contentsOf: url))
        } catch {
            log?.write("[hallie-voice] pronunciations.json unreadable (\(error.localizedDescription)); using shipped defaults")
            return shipped
        }
    }

    /// Why a file-level write was refused.
    enum FileError: LocalizedError, Equatable {
        /// The user's pronunciations.json did not parse. It was moved to
        /// `keptAt` (same directory, ".bad-<timestamp>" suffix) so nothing
        /// they typed is lost; the next read falls back to shipped.
        case malformed(keptAt: URL)

        var errorDescription: String? {
            switch self {
            case .malformed(let keptAt):
                return "pronunciations.json is not valid JSON, so I did not write over it; the file is kept as \(keptAt.lastPathComponent)"
            }
        }
    }

    /// Set (or, with an empty `spoken`, remove) one word in the JSON file —
    /// the fallback when a name told to Hallie is nobody's in particular.
    /// Read-modify-write of the whole (tiny) table, atomic replace; an
    /// existing key with different case is replaced, not duplicated.
    /// A malformed file is never overwritten (codex #700): it is set aside
    /// as `.bad-<timestamp>`, logged, and the write is refused so the
    /// caller can say so; reads then fall back to shipped.
    @discardableResult
    static func setFileEntry(
        written: String, spoken: String?, url: URL = defaultFileURL, log: LogSink? = appLog
    ) throws -> HalliePronunciationLexicon {
        let word = written.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, word.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let said = spoken?.trimmingCharacters(in: .whitespaces) ?? ""
        try setAsideIfMalformed(url, log: log)
        let current = load(from: url, log: log)
        var kept = current.entries.filter { key($0.written) != key(word) }
        if !said.isEmpty { kept.append(Entry(written: word, spoken: said)) }
        let updated = HalliePronunciationLexicon(entries: kept, source: .file)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try updated.jsonData.write(to: url, options: .atomic)
        log?.write("[hallie-voice] pronunciations.json: \(word) → \(said.isEmpty ? "(removed)" : said)")
        return updated
    }

    /// Refuse to clobber a file the user broke: move it to
    /// `pronunciations.json.bad-<yyyyMMdd-HHmmss>` and throw. A missing
    /// file is fine (load writes the default); a readable one is untouched.
    private static func setAsideIfMalformed(_ url: URL, log: LogSink?) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let data = try Data(contentsOf: url)
        do {
            _ = try HalliePronunciationLexicon(jsonData: data)
        } catch {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let keptAt = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).bad-\(formatter.string(from: Date()))")
            try FileManager.default.moveItem(at: url, to: keptAt)
            log?.write("[hallie-voice] pronunciations.json is malformed (\(error.localizedDescription)); kept as \(keptAt.lastPathComponent), write refused, shipped defaults in force")
            throw FileError.malformed(keptAt: keptAt)
        }
    }

    // MARK: - Applying

    /// Alternatives separator: "MahGill | MicGill" keeps both of Rick's
    /// respellings (2026-08-29 drill); only the FIRST is ever spoken.
    static let alternativesSeparator = " | "

    /// Split a stored respelling into its alternatives (first = spoken).
    /// A plain respelling is a one-element list.
    static func alternatives(_ spoken: String) -> [String] {
        spoken.split(separator: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Join Rick's alternatives into the stored form.
    static func joinedAlternatives(_ alternatives: [String]) -> String {
        alternatives.map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: alternativesSeparator)
    }

    /// Substitute every entry on whole-word boundaries, case-insensitively.
    /// Returns the spoken text and the entries that fired, in table order.
    /// An entry with alternatives speaks the first one.
    func apply(to text: String) -> (spoken: String, fired: [Entry]) {
        var spoken = text
        var fired: [Entry] = []
        for entry in entries where entry.spoken != entry.written {
            let said = Self.alternatives(entry.spoken).first ?? entry.spoken
            guard said != entry.written else { continue }
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: entry.written) + #"\b"#
            guard spoken.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            spoken = spoken.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: said),
                options: [.regularExpression, .caseInsensitive])
            fired.append(entry)
        }
        return (spoken, fired)
    }

    /// One log fragment per fired entry: "Nathaniel→nuh-THAN-yul (person Nathaniel McGill)".
    func logLine(for fired: [Entry]) -> String {
        fired.map { "\($0.written)→\($0.spoken) (\(source(of: $0)))" }.joined(separator: ", ")
    }

    private static func key(_ written: String) -> String {
        FamilyIdentityText.normalized(written)
    }
}

/// The CyberBrain records that carry a pronunciation table, re-read only
/// when cyberbrain.json changes; the layer itself is rebuilt per utterance
/// (a handful of records) because the subject can change the tie-break.
/// Memory: only pronunciation-carrying records are kept — the loader caps
/// the file at 16 MB but this holds a few short strings per name.
/// `NSLock` ≈ std::mutex; `@unchecked Sendable` = "I promise the lock
/// makes this thread-safe" since the compiler cannot prove it.
final class PersonPronunciationCache: @unchecked Sendable {
    static let shared = PersonPronunciationCache()

    private struct Stamp: Equatable {
        let path: String
        let modified: Date?
        let size: Int?
    }

    private let lock = NSLock()
    private var stamp: Stamp?
    private var carriers: [CyberBrainPerson] = []

    func layer(rootURL: URL, subject: String? = nil, log: LogSink?) -> HalliePronunciationLexicon {
        let file = rootURL.appendingPathComponent(CyberBrainLoader.defaultFilename, isDirectory: false)
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let now = Stamp(path: file.path, modified: values?.contentModificationDate, size: values?.fileSize)
        let people: [CyberBrainPerson] = lock.withLock {
            if now == stamp { return carriers }
            var loaded: [CyberBrainPerson] = []
            do {
                let archive = try CyberBrainLoader(rootURL: rootURL).load()
                loaded = archive.people.filter { $0.pronunciations != nil }
            } catch CyberBrainError.missingArchive {
                // No brain yet: nothing person-level to say.
            } catch {
                log?.write("[hallie-voice] CyberBrain pronunciations unavailable (\(error.localizedDescription)); using file + shipped")
            }
            stamp = now
            carriers = loaded
            return loaded
        }
        return .personLayer(people: people, subject: subject, log: log)
    }

    /// Tests and the inspector call this after a write so the next
    /// utterance sees it even if the mtime granularity hides the change.
    func invalidate() {
        lock.withLock { stamp = nil }
    }
}
