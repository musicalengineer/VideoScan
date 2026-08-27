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
    /// person. People are visited in id order so a word two records both
    /// claim resolves the same way every time (first id wins).
    static func personLayer(people: [CyberBrainPerson]) -> HalliePronunciationLexicon {
        var entries: [Entry] = []
        var sources: [String: Source] = [:]
        for person in people.sorted(by: { $0.id < $1.id }) {
            for (word, spoken) in (person.pronunciations ?? [:]).sorted(by: { $0.key < $1.key }) {
                let written = word.trimmingCharacters(in: .whitespaces)
                let said = spoken.trimmingCharacters(in: .whitespaces)
                guard !written.isEmpty, !said.isEmpty, sources[key(written)] == nil else { continue }
                entries.append(Entry(written: written, spoken: said))
                sources[key(written)] = .person(id: person.id, name: person.canonicalName)
            }
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
    /// CyberBrain layer is cached by (path, mtime, size).
    static func resolved(
        fileURL: URL = defaultFileURL,
        cyberBrainRootURL: URL? = defaultCyberBrainRootURL,
        log: LogSink? = appLog
    ) -> HalliePronunciationLexicon {
        var layers: [HalliePronunciationLexicon] = []
        if let root = cyberBrainRootURL {
            layers.append(PersonPronunciationCache.shared.layer(rootURL: root, log: log))
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

    /// Set (or, with an empty `spoken`, remove) one word in the JSON file —
    /// the fallback when a name told to Hallie is nobody's in particular.
    /// Read-modify-write of the whole (tiny) table, atomic replace; an
    /// existing key with different case is replaced, not duplicated.
    @discardableResult
    static func setFileEntry(
        written: String, spoken: String?, url: URL = defaultFileURL, log: LogSink? = appLog
    ) throws -> HalliePronunciationLexicon {
        let word = written.trimmingCharacters(in: .whitespaces)
        guard !word.isEmpty, word.rangeOfCharacter(from: .whitespacesAndNewlines) == nil else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let said = spoken?.trimmingCharacters(in: .whitespaces) ?? ""
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

    // MARK: - Applying

    /// Substitute every entry on whole-word boundaries, case-insensitively.
    /// Returns the spoken text and the entries that fired, in table order.
    func apply(to text: String) -> (spoken: String, fired: [Entry]) {
        var spoken = text
        var fired: [Entry] = []
        for entry in entries where entry.spoken != entry.written {
            let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: entry.written) + #"\b"#
            guard spoken.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { continue }
            spoken = spoken.replacingOccurrences(
                of: pattern,
                with: NSRegularExpression.escapedTemplate(for: entry.spoken),
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

/// The CyberBrain per-person layer, re-read only when cyberbrain.json
/// changes. Memory: one lexicon (a few hundred short strings at most —
/// the loader caps the file at 16 MB but only the pronunciation tables
/// are kept). `NSLock` ≈ std::mutex; `@unchecked Sendable` = "I promise
/// the lock makes this thread-safe" since the compiler cannot prove it.
final class PersonPronunciationCache: @unchecked Sendable {
    static let shared = PersonPronunciationCache()

    private struct Stamp: Equatable {
        let path: String
        let modified: Date?
        let size: Int?
    }

    private let lock = NSLock()
    private var stamp: Stamp?
    private var cached = HalliePronunciationLexicon(entries: [])

    func layer(rootURL: URL, log: LogSink?) -> HalliePronunciationLexicon {
        let file = rootURL.appendingPathComponent(CyberBrainLoader.defaultFilename, isDirectory: false)
        let values = try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let now = Stamp(path: file.path, modified: values?.contentModificationDate, size: values?.fileSize)
        return lock.withLock {
            if now == stamp { return cached }
            var layer = HalliePronunciationLexicon(entries: [])
            do {
                let archive = try CyberBrainLoader(rootURL: rootURL).load()
                layer = .personLayer(people: archive.people)
            } catch CyberBrainError.missingArchive {
                // No brain yet: nothing person-level to say.
            } catch {
                log?.write("[hallie-voice] CyberBrain pronunciations unavailable (\(error.localizedDescription)); using file + shipped")
            }
            stamp = now
            cached = layer
            return layer
        }
    }

    /// Tests and the inspector call this after a write so the next
    /// utterance sees it even if the mtime granularity hides the change.
    func invalidate() {
        lock.withLock { stamp = nil }
    }
}
