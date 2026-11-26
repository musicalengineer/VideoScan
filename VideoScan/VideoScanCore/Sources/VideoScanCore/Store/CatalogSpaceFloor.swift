// CatalogSpaceFloor.swift (VideoScanCore/Store)
// GH #357 — the free-space floor every catalog write is checked against
// BEFORE its transaction begins (Rick's fail-fast ruling, 2026-10-21): below
// 2 × (catalog.sqlite + its WAL) free on the catalog's disk, and never under
// 1 GB, a save is refused up front, with words, and nothing is written — no
// body runs, no frame lands, no witness moves. Before this a full disk was
// found only after the whole body ran (a 100k-row commit took ~2 min on the
// main actor before it was refused) and a commit with 2 MB free just went ahead.
//
// One rule, not two: the decision is `PreflightGate.decide(.edit, …)`, the
// launch preflight's own edit floor (PreflightThresholds). This file only
// reads the disk and the catalog's size the way a commit can afford to:
// one statfs(2) and two stat(2) calls, a few microseconds — cheap enough for
// every debounced save. statfs's f_bavail is bytes free RIGHT NOW (purgeable
// space not counted), the same conservative figure the preflight uses (QA r1
// M4: a SQLite write() does not wait for macOS to purge).
//
// A disk that cannot be read does not refuse (PreflightGate: a failed probe is
// not evidence of a full disk); SQLite's own refusal still stands behind it,
// and since GH #338 that refusal comes before the high-water moves.
//
// Memory: none retained; one `statfs` struct on the stack per write.
// (For Rick: an enum with an associated value ≈ a tagged union; `.preflight`
// carries the thresholds the way a std::variant alternative carries its data.)

import Foundation

public enum CatalogSpaceFloor: Sendable, Equatable {
    /// Production: PreflightGate's edit floor with these thresholds.
    case preflight(PreflightThresholds)
    /// Test suites ONLY — the ones that drive SQLite's own disk-full paths on
    /// a small disk image. No production code may pass it
    /// (CatalogStoreSensorTests pins that, as it pins the test-only durability).
    case offForTests

    /// The app's floor: 2 × (catalog + WAL), never under 1 GB.
    public static let production = CatalogSpaceFloor.preflight(PreflightThresholds())

    /// nil = the write may go ahead; else the words of the refusal.
    func refusal(forDatabaseAt url: URL) -> String? {
        guard case .preflight(let thresholds) = self else { return nil }
        return Self.refusal(volume: Self.volume(holding: url), catalogBytes: Self.catalogBytes(url), thresholds: thresholds)
    }

    /// The decision, pure (logic tests drive it with any disk they like).
    static func refusal(volume: PreflightVolume?, catalogBytes: UInt64, thresholds: PreflightThresholds) -> String? {
        let verdict = PreflightGate.decide(.edit, catalogVolume: volume, catalogBytes: catalogBytes, thresholds: thresholds)
        guard case .refused(let words, _, _) = verdict else { return nil }
        return "nothing was saved — not enough free space. \(words). The changes are kept in memory."
    }

    /// The volume holding `url`'s folder, from statfs(2); nil when it can't be read.
    static func volume(holding url: URL) -> PreflightVolume? {
        var info = statfs()
        guard statfs(url.deletingLastPathComponent().path, &info) == 0 else { return nil }
        let block = Int64(info.f_bsize)
        let mount = withUnsafeBytes(of: info.f_mntonname) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
        let name = mount == "/" ? "the startup disk" : (mount as NSString).lastPathComponent
        return PreflightVolume(id: mount, name: name,
                               availableBytes: Int64(info.f_bavail).multipliedClamped(by: block),
                               totalBytes: Int64(info.f_blocks).multipliedClamped(by: block))
    }

    /// catalog.sqlite + catalog.sqlite-wal, in bytes (a missing file counts 0).
    static func catalogBytes(_ url: URL) -> UInt64 {
        [url.path, url.path + "-wal"].reduce(UInt64(0)) { total, path in
            var info = stat()
            guard stat(path, &info) == 0 else { return total }
            return total &+ UInt64(max(0, info.st_size))
        }
    }
}
