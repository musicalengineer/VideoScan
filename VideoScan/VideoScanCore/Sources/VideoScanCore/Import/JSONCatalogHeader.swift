// JSONCatalogHeader.swift (VideoScanCore/Import)
// The catalog.json header probe the importer reads its source generation
// with. Moved unchanged out of Store/JSONCatalogRepository.swift when that
// read-only stub was retired (2026-10-20, JSON gone); it lives with its one
// remaining caller, CatalogImporter.

import Foundation

/// `version` + `generation` from catalog.json WITHOUT decoding the records:
/// the first 4 KB, then the last 4 KB (JSONEncoder's key order is
/// per-process random, so an old file may carry the header after 36 MB
/// of records — GH #165). Same rule as the app's
/// `CatalogSnapshot.headerProbe`; kept here because this package cannot
/// see the app target. When the JSON store moves behind this seam for
/// good, the app's copy goes and this is the one.
enum JSONCatalogHeader {

    static let probeWindowBytes = 4096

    static func probe(at url: URL) -> (version: Int, generation: Int)? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: probeWindowBytes) else { return nil }
        // Lossy decode on purpose: a 4 KB cut can split a multibyte sequence
        // and the failable initializer would nil the WHOLE window; the keys
        // searched for are ASCII and survive the replacement character.
        // swiftlint:disable:next optional_data_string_conversion
        let headText = String(decoding: head, as: UTF8.self)
        var version = intValue(forKey: "version", in: headText, last: false)
        var generation = intValue(forKey: "generation", in: headText, last: false)
        if version == nil || generation == nil, let tailText = tail(of: handle, after: head.count) {
            if version == nil { version = intValue(forKey: "version", in: tailText, last: true) }
            if generation == nil { generation = intValue(forKey: "generation", in: tailText, last: true) }
        }
        guard version != nil || generation != nil else { return nil }
        return (version ?? 0, generation ?? 0)
    }

    private static func tail(of handle: FileHandle, after headCount: Int) -> String? {
        guard let size = try? handle.seekToEnd(), size > UInt64(headCount) else { return nil }
        let start = size > UInt64(probeWindowBytes) ? size - UInt64(probeWindowBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let tail = try? handle.readToEnd() else { return nil }
        // Lossy on purpose, same reason as the head window.
        // swiftlint:disable:next optional_data_string_conversion
        return String(decoding: tail, as: UTF8.self)
    }

    /// `"key" : 123`, whitespace optional. `last` picks the final
    /// occurrence (the tail's top-level keys come after the records).
    private static func intValue(forKey key: String, in text: String, last: Bool) -> Int? {
        let needle = "\"\(key)\""
        guard let found = last ? text.range(of: needle, options: .backwards) : text.range(of: needle) else {
            return nil
        }
        let blank: (Character) -> Bool = { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "\r" }
        var rest = text[found.upperBound...].drop(while: blank)
        guard rest.first == ":" else { return nil }
        rest = rest.dropFirst().drop(while: blank)
        return Int(rest.prefix(while: { $0.isNumber }))
    }
}
