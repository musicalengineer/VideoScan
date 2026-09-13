import Foundation

/// Names locate folders; UUIDs own them. Copies assets without decoding media.
enum POIProfileFileStore {
    private static let lock = NSRecursiveLock()

    enum Failure: LocalizedError {
        case invalidName, differentPerson, unreadableIdentity, missingSource, occupiedDestination
        var errorDescription: String? {
            switch self {
            case .invalidName: return "The person name must be a single folder name."
            case .differentPerson: return "Another person already uses this name. Choose a distinct short name, such as Richard Sr or Richard Jr."
            case .unreadableIdentity: return "The existing profile could not be identified safely. It has not been overwritten."
            case .missingSource: return "The original profile folder is missing. The rename was not saved."
            case .occupiedDestination: return "The new name already has a folder. It has not been overwritten or merged."
            }
        }
    }

    static func folder(component: String, in root: URL) throws -> URL {
        guard !component.isEmpty, component != ".", component != "..",
              !component.contains("/") else { throw Failure.invalidName }
        return root.appendingPathComponent(component, isDirectory: true)
    }

    /// A warning means the new profile committed but the old folder could not
    /// be retired. Failed writes leave the original intact. The writer receives
    /// the staging JSON URL and FINAL reference folder. Serialize in-process saves.
    static func save(
        id: UUID, destination: URL, previous: URL? = nil,
        retire: (URL) throws -> Void,
        write: (URL, URL) throws -> Void
    ) throws -> String? {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let destination = destination.standardizedFileURL
        let previous = previous?.standardizedFileURL
        let isRename = previous != nil && previous != destination

        func checkIdentity(_ folder: URL, required: Bool) throws {
            if let values = try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true { throw Failure.unreadableIdentity }
            let json = folder.appendingPathComponent("profile.json")
            if !fm.fileExists(atPath: json.path) {
                if required { throw Failure.missingSource }
                return
            }
            guard let data = try? Data(contentsOf: json),
                  let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let rawID = object["uuid"] as? String,
                  let existingID = UUID(uuidString: rawID) else {
                throw Failure.unreadableIdentity
            }
            guard existingID == id else { throw Failure.differentPerson }
        }

        try checkIdentity(destination, required: false)
        guard isRename, let previous else {
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            try write(destination.appendingPathComponent("profile.json"), destination)
            return nil
        }
        try checkIdentity(previous, required: true)
        // A same-UUID destination may hold newer photos: never merge implicitly.
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.occupiedDestination }
        let staging = destination.deletingLastPathComponent()
            .appendingPathComponent(".poi-rename-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        try fm.copyItem(at: previous, to: staging)
        // Absolute links to assets inside the old folder must follow the rename.
        // External links and relative links keep their original meaning because
        // source and destination are siblings. Never modify the source copy.
        if let entries = fm.enumerator(at: staging, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let link as URL in entries {
                guard try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true else { continue }
                let target = try fm.destinationOfSymbolicLink(atPath: link.path)
                let prefix = previous.path + "/"
                guard target.hasPrefix(prefix) else { continue }
                let renamedTarget = destination.path + "/" + target.dropFirst(prefix.count)
                try fm.removeItem(at: link)
                try fm.createSymbolicLink(atPath: link.path, withDestinationPath: renamedTarget)
            }
        }
        try write(staging.appendingPathComponent("profile.json"), destination)
        try fm.moveItem(at: staging, to: destination)
        do { try retire(previous) }
        catch { return error.localizedDescription }
        return nil
    }
}
