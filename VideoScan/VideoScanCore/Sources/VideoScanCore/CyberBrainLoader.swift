import Darwin
import Foundation

public enum CyberBrainError: Error, Sendable, Equatable, LocalizedError {
    case missingArchive
    case unsafePath(String)
    case oversizedFile(Int)
    case unreadableFile
    case invalidJSON(String)
    case unsupportedSchema(Int)
    case invalidField(String)
    case duplicateID(String)
    case danglingReference(String)

    public var errorDescription: String? {
        switch self {
        case .missingArchive: return "No CyberBrain archive is installed."
        case .unsafePath(let path): return "CyberBrain refused an unsafe path: \(path)"
        case .oversizedFile(let bytes): return "CyberBrain archive is too large (\(bytes) bytes)."
        case .unreadableFile: return "CyberBrain archive could not be read safely."
        case .invalidJSON(let detail): return "CyberBrain JSON is invalid: \(detail)"
        case .unsupportedSchema(let version): return "Unsupported CyberBrain schema version \(version)."
        case .invalidField(let field): return "CyberBrain field is invalid: \(field)"
        case .duplicateID(let id): return "CyberBrain ID is duplicated: \(id)"
        case .danglingReference(let id): return "CyberBrain reference does not exist: \(id)"
        }
    }
}

public enum CyberBrainValidator {
    public static func validate(_ archive: CyberBrainArchive) throws {
        guard archive.schemaVersion == CyberBrainArchive.currentSchemaVersion else {
            throw CyberBrainError.unsupportedSchema(archive.schemaVersion)
        }
        try requireText(archive.archiveID, "archiveID")
        try requireText(archive.displayName, "displayName")

        let peopleByID = try unique(archive.people, id: \CyberBrainPerson.id)
        let sourcesByID = try unique(archive.sources, id: \CyberBrainSource.id)
        var itemsByID: [String: CyberBrainItem] = [:]

        for source in archive.sources {
            try requireText(source.id, "source.id")
            try requireText(source.title, "source.title")
            if let locator = source.locator {
                try validateRelativePath(locator, field: "source.locator")
            }
            if let date = source.sourceDate { try validate(date) }
        }

        for person in archive.people {
            try requireText(person.id, "person.id")
            try requireText(person.canonicalName, "person.canonicalName")
            for alias in person.aliases { try requireText(alias, "person.alias") }
            for term in person.terminology {
                try requireText(term, "person.terminology")
            }
            guard Set(person.aliases.map(normalized)).count == person.aliases.count else {
                throw CyberBrainError.invalidField("duplicate alias for \(person.id)")
            }

            let sections: [([CyberBrainItem], CyberBrainItem.Kind, String)] = [
                (person.biographyPassages, .biography, "biographyPassages"),
                (person.anecdotes, .anecdote, "anecdotes"),
                (person.lifeEvents, .event, "lifeEvents"),
                (person.notes, .note, "notes"),
            ]
            for (section, expectedKind, sectionName) in sections {
                for item in section {
                    guard item.kind == expectedKind else {
                        throw CyberBrainError.invalidField(
                            "\(sectionName) item \(item.id) has kind \(item.kind.rawValue)")
                    }
                    guard item.subjectPersonIDs.contains(person.id) else {
                        throw CyberBrainError.invalidField(
                            "item \(item.id) does not name owning person \(person.id)")
                    }
                    try requireText(item.id, "item.id")
                    guard itemsByID.updateValue(item, forKey: item.id) == nil else {
                        throw CyberBrainError.duplicateID(item.id)
                    }
                    try requireText(item.text, "item.text")
                    guard !item.subjectPersonIDs.isEmpty else {
                        throw CyberBrainError.invalidField("item.subjectPersonIDs")
                    }
                    guard !item.sourceIDs.isEmpty else {
                        throw CyberBrainError.invalidField("item.sourceIDs")
                    }
                    guard item.updatedAt >= item.createdAt else {
                        throw CyberBrainError.invalidField("item.updatedAt before createdAt")
                    }
                    if let date = item.eventDate { try validate(date) }
                }
            }
        }

        for item in itemsByID.values {
            for personID in item.subjectPersonIDs where peopleByID[personID] == nil {
                throw CyberBrainError.danglingReference(personID)
            }
            for sourceID in item.sourceIDs where sourcesByID[sourceID] == nil {
                throw CyberBrainError.danglingReference(sourceID)
            }
            if let prior = item.supersedesItemID {
                guard prior != item.id, itemsByID[prior] != nil else {
                    throw CyberBrainError.danglingReference(prior)
                }
            }
        }
    }

    private static func unique<T>(
        _ values: [T], id: KeyPath<T, String>
    ) throws -> [String: T] {
        var result: [String: T] = [:]
        for value in values {
            let key = value[keyPath: id]
            guard result.updateValue(value, forKey: key) == nil else {
                throw CyberBrainError.duplicateID(key)
            }
        }
        return result
    }

    private static func validate(_ date: CyberBrainQualifiedDate) throws {
        try requireText(date.value, "qualifiedDate.value")
        try requireText(date.displayText, "qualifiedDate.displayText")
    }

    private static func requireText(_ value: String, _ field: String) throws {
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CyberBrainError.invalidField(field)
        }
    }

    private static func validateRelativePath(_ value: String, field: String) throws {
        try requireText(value, field)
        guard !value.hasPrefix("/"), !value.hasPrefix("~") else {
            throw CyberBrainError.unsafePath(value)
        }
        let components = value.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CyberBrainError.unsafePath(value)
        }
    }

    private static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive],
                      locale: Locale(identifier: "en_US_POSIX"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }
}

public struct CyberBrainLoader: Sendable {
    public static let defaultFilename = "cyberbrain.json"
    public static let maximumBytes = 16 * 1_024 * 1_024

    public let rootURL: URL
    public let maximumBytes: Int

    public init(rootURL: URL, maximumBytes: Int = maximumBytes) {
        self.rootURL = rootURL
        self.maximumBytes = maximumBytes
    }

    public func load() throws -> CyberBrainArchive {
        let candidate = rootURL.appendingPathComponent(Self.defaultFilename,
                                                        isDirectory: false)
        let root = rootURL.standardizedFileURL
        guard candidate.deletingLastPathComponent().standardizedFileURL == root else {
            throw CyberBrainError.unsafePath(candidate.path)
        }
        guard FileManager.default.fileExists(atPath: candidate.path) else {
            throw CyberBrainError.missingArchive
        }
        try rejectSymlink(root)
        let data = try readNoFollow(candidate)
        try Self.rejectUnknownFields(in: data)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let archive: CyberBrainArchive
        do {
            archive = try decoder.decode(CyberBrainArchive.self, from: data)
        } catch {
            throw CyberBrainError.invalidJSON(String(describing: error))
        }
        try CyberBrainValidator.validate(archive)
        return archive
    }

    private func rejectSymlink(_ url: URL) throws {
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey,
                                                       .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw CyberBrainError.unsafePath(url.path)
        }
    }

    private func readNoFollow(_ url: URL) throws -> Data {
        let descriptor = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            if errno == ELOOP { throw CyberBrainError.unsafePath(url.path) }
            throw CyberBrainError.unreadableFile
        }
        defer { close(descriptor) }

        var status = stat()
        guard fstat(descriptor, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFREG else {
            throw CyberBrainError.unreadableFile
        }
        guard status.st_size <= maximumBytes else {
            throw CyberBrainError.oversizedFile(Int(status.st_size))
        }

        var result = Data()
        result.reserveCapacity(Int(status.st_size))
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { break }
            guard count > 0 else {
                if errno == EINTR { continue }
                throw CyberBrainError.unreadableFile
            }
            result.append(buffer, count: count)
            guard result.count <= maximumBytes else {
                throw CyberBrainError.oversizedFile(result.count)
            }
        }
        return result
    }

    /// Codable normally ignores fields written by a newer producer. Family
    /// knowledge must fail closed instead, so a misspelled privacy/status key
    /// cannot silently acquire a default interpretation.
    private static func rejectUnknownFields(in data: Data) throws {
        let object: Any
        do { object = try JSONSerialization.jsonObject(with: data) }
        catch { throw CyberBrainError.invalidJSON(String(describing: error)) }
        guard let archive = object as? [String: Any] else {
            throw CyberBrainError.invalidJSON("top level is not an object")
        }
        try known(archive, allowed: ["schemaVersion", "archiveID", "displayName",
                                     "people", "sources"], at: "archive")
        for (index, value) in (archive["people"] as? [Any] ?? []).enumerated() {
            guard let person = value as? [String: Any] else {
                throw CyberBrainError.invalidJSON("people[\(index)] is not an object")
            }
            try known(person, allowed: ["id", "gedcomPersonID", "profileStableID",
                                        "canonicalName", "aliases", "terminology",
                                        "biographyPassages", "anecdotes", "lifeEvents",
                                        "notes"], at: "people[\(index)]")
            for key in ["biographyPassages", "anecdotes", "lifeEvents", "notes"] {
                for (itemIndex, itemValue) in (person[key] as? [Any] ?? []).enumerated() {
                    guard let item = itemValue as? [String: Any] else {
                        throw CyberBrainError.invalidJSON("\(key)[\(itemIndex)] is not an object")
                    }
                    try known(item, allowed: ["id", "kind", "text", "subjectPersonIDs",
                                              "eventDate", "place", "sourceIDs",
                                              "confidence", "privacy", "status",
                                              "supersedesItemID", "createdAt", "updatedAt"],
                              at: "\(key)[\(itemIndex)]")
                    if let date = item["eventDate"] as? [String: Any] {
                        try knownDate(date, at: "\(key)[\(itemIndex)].eventDate")
                    }
                }
            }
        }
        for (index, value) in (archive["sources"] as? [Any] ?? []).enumerated() {
            guard let source = value as? [String: Any] else {
                throw CyberBrainError.invalidJSON("sources[\(index)] is not an object")
            }
            try known(source, allowed: ["id", "type", "title", "attribution",
                                        "sourceDate", "locator", "notes"],
                      at: "sources[\(index)]")
            if let date = source["sourceDate"] as? [String: Any] {
                try knownDate(date, at: "sources[\(index)].sourceDate")
            }
        }
    }

    private static func knownDate(_ value: [String: Any], at path: String) throws {
        try known(value, allowed: ["value", "precision", "qualifier", "displayText"],
                  at: path)
    }

    private static func known(_ value: [String: Any], allowed: Set<String>,
                              at path: String) throws {
        if let unknown = Set(value.keys).subtracting(allowed).sorted().first {
            throw CyberBrainError.invalidJSON("unknown field \(path).\(unknown)")
        }
    }
}
