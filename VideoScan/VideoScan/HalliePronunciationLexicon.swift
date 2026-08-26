// HalliePronunciationLexicon.swift
// Family-name pronunciations for Hallie's neural voice. Kokoro says
// "McGill" as "Mic Gill" and "Edith" as "Ed-ith"; the audited spellings here
// are substituted into the PRIVATE string sent to speech synthesis only —
// Hallie's visible answer and the catalog are never rewritten.
//
// The table is a user-editable JSON object of written → spoken at
//   ~/Library/Application Support/VideoScan/Hallie/pronunciations.json
// (written from the shipped default on first use so the format is visible).
// Matches are whole-word and case-insensitive; possessives survive
// ("McGill's" → "muh-GILL's"). Every entry that fires is logged so a bad
// respelling can be traced to its line.

import Foundation

struct HalliePronunciationLexicon: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        let written: String
        let spoken: String
    }

    let entries: [Entry]

    /// Shipped default — the Scots-Irish/Irish set Rick audited 2026-08-26
    /// plus the 8/25 Edith fix. Keys are what the family tree spells.
    static let shipped = HalliePronunciationLexicon(entries: [
        Entry(written: "Edith", spoken: "EE-dith"),
        Entry(written: "McGill", spoken: "muh-GILL"),
        Entry(written: "McDonald", spoken: "muh-DON-uld"),
        Entry(written: "McCarthy", spoken: "muh-CAR-thee"),
        Entry(written: "McLaughlin", spoken: "muh-GLOCK-lin"),
        Entry(written: "Latta", spoken: "LAT-uh"),
        // Audited as already correct (2026-08-26; "BREEN" and "LAM" measured
        // no better on the installed Kokoro). Identity entries are listed so
        // the JSON shows the family set, and never fire.
        Entry(written: "Breen", spoken: "Breen"),
        Entry(written: "Ronan", spoken: "ROW-nin"),
        Entry(written: "Lamb", spoken: "Lamb"),
        Entry(written: "Hendour", spoken: "HEN-door"),
    ])

    static let fileName = "pronunciations.json"

    static var defaultFileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory())
        return base.appendingPathComponent("VideoScan/Hallie", isDirectory: true)
            .appendingPathComponent(fileName)
    }

    init(entries: [Entry]) {
        // Longest written form first so "McLaughlin" is never shadowed by a
        // shorter key; deterministic order for the log line.
        self.entries = entries.sorted {
            $0.written.count != $1.written.count ? $0.written.count > $1.written.count : $0.written < $1.written
        }
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
        })
    }

    var jsonData: Data {
        let table = Dictionary(uniqueKeysWithValues: entries.map { ($0.written, $0.spoken) })
        return (try? JSONSerialization.data(withJSONObject: table, options: [.prettyPrinted, .sortedKeys])) ?? Data()
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
}
