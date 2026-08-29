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
        let temp = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        do {
            try data.write(to: temp, options: [.atomic])
            _ = try fm.replaceItemAt(url, withItemAt: temp)
        } catch {
            try? fm.removeItem(at: temp)
            throw StoreError.ioFailure(error.localizedDescription)
        }
    }
}
