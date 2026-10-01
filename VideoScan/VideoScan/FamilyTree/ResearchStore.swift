// ResearchStore.swift
// Disk persistence for Research Person: the dossier (findings + verdicts +
// lore) and a cache of every fetched page with its retrieved date, under
//
//   <People>/<key>/research/dossier.json
//   <People>/<key>/research/cache/<sha256-of-url>.json
//
// keyed by FamilySearch ID so it survives a GEDCOM re-pull. Writes are
// atomic (temp file + rename) so a crash leaves the old file or the new
// one, never a torn one. The store is a value type over one root URL: tests
// inject a temp directory and nothing outside it is ever consulted.
//
// Memory: a dossier is ≤ 500 findings × ≤ 1 KB; a cached page is capped at
// `maxCachedBodyBytes` (2 MB) before it is written. Nothing here holds
// more than one page at a time.
//
// C++ readers: `struct` with `let` members ≈ an immutable object; the
// `throws` functions ≈ functions that return an error via exception.

import CryptoKit
import Foundation
import VideoScanCore

struct ResearchStore: Sendable {
    /// The People directory (FamilyAssetStore.peopleDirectory in
    /// production; a temp directory in tests).
    let peopleRoot: URL

    static let maxCachedBodyBytes = 2 << 20

    enum StoreError: Error, LocalizedError, Equatable {
        case unsafeKey(String)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .unsafeKey(let key): return "unsafe research key \"\(key)\""
            case .ioFailure(let detail): return "could not save research: \(detail)"
            }
        }
    }

    /// One fetched page as cached: what came back and when.
    struct CachedPage: Codable, Equatable, Sendable {
        let url: String
        let retrievedAt: Date
        let statusCode: Int
        let body: Data
    }

    init(peopleRoot: URL) {
        self.peopleRoot = peopleRoot.standardizedFileURL
    }

    // MARK: Paths

    func researchDirectory(key: String) throws -> URL {
        guard ResearchSubject.isSafeKey(key) else { throw StoreError.unsafeKey(key) }
        return peopleRoot
            .appendingPathComponent(key, isDirectory: true)
            .appendingPathComponent("research", isDirectory: true)
    }

    func dossierURL(key: String) throws -> URL {
        try researchDirectory(key: key).appendingPathComponent("dossier.json")
    }

    func cacheDirectory(key: String) throws -> URL {
        try researchDirectory(key: key).appendingPathComponent("cache", isDirectory: true)
    }

    func cacheURL(key: String, pageURL: String) throws -> URL {
        try cacheDirectory(key: key).appendingPathComponent(Self.cacheFileName(pageURL))
    }

    static func cacheFileName(_ pageURL: String) -> String {
        let digest = SHA256.hash(data: Data(pageURL.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".json"
    }

    /// Archive-relative path of a cached page — the CyberBrain source
    /// locator for a confirmed finding (source locators are
    /// archive-relative by contract; the URL itself lives in the notes).
    static func relativeCachePath(key: String, pageURL: String) -> String {
        "People/\(key)/research/cache/\(cacheFileName(pageURL))"
    }

    // MARK: Dossier

    /// Nil when no dossier has been saved for this key yet.
    func loadDossier(key: String) throws -> ResearchDossier? {
        let url = try dossierURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try Self.decoder.decode(ResearchDossier.self, from: data)
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }
    }

    func saveDossier(_ dossier: ResearchDossier) throws {
        try ViewerWriteGuard.check("ResearchStore.saveDossier")
        let url = try dossierURL(key: dossier.subject.key)
        do {
            let data = try Self.encoder.encode(dossier)
            try Self.writeAtomically(data, to: url)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }
    }

    // MARK: Read-modify-write (QA 2026-10-01 P2-1)

    /// Every dossier writer goes through here: the Research pane (verdict,
    /// lore, Tell Hallie, run results) and the "I found a record" filer. It
    /// takes the ONE lock for this key, reads what is on disk NOW, applies
    /// `change`, and writes the result back. Two writers can no longer save
    /// stale copies over each other (a pane opened before a filing used to
    /// erase the filed record on its next save).
    ///
    /// `change` gets nil when no dossier exists. Setting it to nil when one
    /// DID exist retires the file to `research/.trash/` (moved, never
    /// deleted) — used only to undo a dossier this same transaction created.
    /// Unchanged → nothing is written. Returns what is on disk afterwards.
    ///
    /// The lock is held only for one small JSON read + write; `change` must
    /// not block or await. (C++: a std::mutex per key, taken with a
    /// lock_guard around load → mutate → save.)
    @discardableResult
    func update(key: String, _ change: (inout ResearchDossier?) throws -> Void) throws -> ResearchDossier? {
        let lock = Self.keyLocks.lock(for: key)
        lock.lock()
        defer { lock.unlock() }
        let before = try loadDossier(key: key)
        var after = before
        try change(&after)
        if after == before { return after }
        if let after {
            try saveDossier(after)
        } else {
            try retireDossierFile(key: key)
        }
        return after
    }

    /// Move dossier.json to research/.trash/dossier-<stamp>-<uuid>.json.
    private func retireDossierFile(key: String) throws {
        try ViewerWriteGuard.check("ResearchStore.retireDossierFile")
        let url = try dossierURL(key: key)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let trash = try researchDirectory(key: key).appendingPathComponent(".trash", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
            try FileManager.default.moveItem(
                at: url, to: trash.appendingPathComponent("dossier-\(stamp)-\(UUID().uuidString.prefix(8)).json"))
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }
    }

    /// One NSLock per research key, process-wide. `@unchecked Sendable` +
    /// a lock around the table ≈ a C++ class guarding its map with a mutex.
    private final class KeyLocks: @unchecked Sendable {
        private let guardLock = NSLock()
        private var locks: [String: NSLock] = [:]
        func lock(for key: String) -> NSLock {
            guardLock.withLock {
                if let existing = locks[key] { return existing }
                let made = NSLock()
                locks[key] = made
                return made
            }
        }
    }

    private static let keyLocks = KeyLocks()

    // MARK: Page cache

    func cachedPage(key: String, pageURL: String) -> CachedPage? {
        guard let url = try? cacheURL(key: key, pageURL: pageURL),
              let data = try? Data(contentsOf: url)
        else { return nil }
        return try? Self.decoder.decode(CachedPage.self, from: data)
    }

    /// Bodies over the cap are truncated before caching — the parsers only
    /// need the first couple of megabytes of any search page.
    func cache(_ page: CachedPage, key: String) throws {
        try ViewerWriteGuard.check("ResearchStore.cache")
        let capped = page.body.count > Self.maxCachedBodyBytes
            ? CachedPage(url: page.url, retrievedAt: page.retrievedAt,
                         statusCode: page.statusCode,
                         body: page.body.prefix(Self.maxCachedBodyBytes))
            : page
        let url = try cacheURL(key: key, pageURL: page.url)
        do {
            try Self.writeAtomically(try Self.encoder.encode(capped), to: url)
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }
    }

    /// Every dossier key with a saved dossier under this root.
    func keysWithDossiers() -> [String] {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: peopleRoot, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])
        else { return [] }
        return children.compactMap { child in
            let key = child.lastPathComponent
            guard ResearchSubject.isSafeKey(key),
                  let url = try? dossierURL(key: key),
                  FileManager.default.fileExists(atPath: url.path)
            else { return nil }
            return key
        }.sorted()
    }

    // MARK: Helpers

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private static func writeAtomically(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }
        let values = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw StoreError.ioFailure("research directory is not a plain directory: \(directory.path)")
        }
        do {
            try AtomicFilePublish.write(data, to: url, durability: .fullFsync)
        } catch {
            throw StoreError.ioFailure(error.localizedDescription)
        }
    }
}
