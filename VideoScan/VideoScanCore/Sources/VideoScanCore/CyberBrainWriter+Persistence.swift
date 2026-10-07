// CyberBrainWriter+Persistence.swift
import Foundation

extension CyberBrainWriter {
    /// Validate the root directory and load what is there (nil when the
    /// archive does not exist yet). Shared by every durable writer,
    /// including note corrections (CyberBrainCorrections.swift).
    static func prepareRoot(_ rootURL: URL) throws -> (URL, CyberBrainArchive?) {
        let root = rootURL.standardizedFileURL
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: root.path) {
            do {
                try fileManager.createDirectory(
                    at: root, withIntermediateDirectories: true)
            } catch {
                throw WriteError.ioFailure(error.localizedDescription)
            }
        }
        let values = try? root.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard values?.isDirectory == true, values?.isSymbolicLink != true else {
            throw WriteError.unsafeRoot(root.path)
        }
        let loader = CyberBrainLoader(rootURL: root)
        do {
            return (root, try loader.load())
        } catch CyberBrainError.missingArchive {
            return (root, nil)
        }
        // Any other loader error propagates: a corrupt or unsafe archive must
        // never be silently replaced by a fresh one.
    }

    /// Durable form of `appending(caption:to:)`; same atomic save as `record`.
    public static func record(
        caption: PhotoCaption,
        rootURL: URL
    ) throws -> Receipt {
        try withRootLock(rootURL) {
            let (root, existing) = try prepareRoot(rootURL)
            let receipt = try appending(caption: caption, to: existing)
            try save(receipt.archive, root: root, hadExisting: existing != nil)
            return receipt
        }
    }

    /// Durable: load, set, save atomically (temp → fsync → backup → rename,
    /// like every other write here). The person must already exist.
    public static func setPronunciation(
        personID: String,
        token word: String,
        saidAs: String?,
        rootURL: URL
    ) throws -> PronunciationReceipt {
        try withRootLock(rootURL) {
            let (root, existing) = try prepareRoot(rootURL)
            guard let archive = existing else { throw WriteError.emptySubject }
            let receipt = try settingPronunciation(
                personID: personID, word: word, saidAs: saidAs, in: archive)
            try save(receipt.archive, root: root, hadExisting: true)
            return receipt
        }
    }

    /// Durable form of the by-name variant (mints the person if needed).
    public static func setPronunciation(
        subjectName: String,
        gedcomPersonID: String?,
        aliases: [String] = [],
        token word: String,
        saidAs: String?,
        rootURL: URL
    ) throws -> PronunciationReceipt {
        try withRootLock(rootURL) {
            let (root, existing) = try prepareRoot(rootURL)
            let receipt = try settingPronunciation(
                subjectName: subjectName, gedcomPersonID: gedcomPersonID, aliases: aliases,
                word: word, saidAs: saidAs, in: existing)
            try save(receipt.archive, root: root, hadExisting: existing != nil)
            return receipt
        }
    }

    // MARK: - Durable write

    /// Load (or start) the archive at `rootURL`, append, and save atomically.
    /// Returns the receipt for the saved archive. On any failure the file on
    /// disk is exactly what it was before the call. Serialized per root
    /// (`withRootLock`): a receipt always names a passage that is on disk.
    public static func record(
        _ testimony: Testimony,
        rootURL: URL
    ) throws -> Receipt {
        try withRootLock(rootURL) {
            // Same root checks and load as every durable writer; a corrupt or
            // unsafe archive propagates and is never replaced by a fresh one.
            let (root, existing) = try prepareRoot(rootURL)
            let receipt = try appending(testimony, to: existing)
            // An idempotent repeat changes nothing — no rewrite, no backup churn.
            if let existing, receipt.archive == existing { return receipt }
            try save(receipt.archive, root: root, hadExisting: existing != nil)
            return receipt
        }
    }

    /// Encoded exactly as the loader reads it back: ISO-8601 dates, stable
    /// key order, human-readable.
    public static func encode(_ archive: CyberBrainArchive) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(archive)
    }

    /// Temp → probe-load → backup → atomic rename. Returns where the
    /// previous file was copied (nil when there was none), so a caller can
    /// log how to revert. Internal so note corrections share this path.
    @discardableResult
    static func save(_ archive: CyberBrainArchive, root: URL,
                     hadExisting: Bool) throws -> URL? {
        let data = try encode(archive)
        let finalURL = root.appendingPathComponent(
            CyberBrainLoader.defaultFilename, isDirectory: false)
        let tempURL = root.appendingPathComponent(
            ".\(CyberBrainLoader.defaultFilename).tmp-\(UUID().uuidString)",
            isDirectory: false)

        // Write + fsync the temp file.
        let descriptor = open(
            tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw WriteError.ioFailure("cannot create \(tempURL.lastPathComponent)")
        }
        var written = false
        defer {
            if !written { try? FileManager.default.removeItem(at: tempURL) }
        }
        let ok: Bool = data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let count = write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                offset += count
            }
            return true
        }
        guard ok, fsync(descriptor) == 0 else {
            close(descriptor)
            throw WriteError.ioFailure("write failed")
        }
        close(descriptor)

        // Prove the bytes on disk load through the strict reader BEFORE they
        // replace the real file.
        do {
            let probeRoot = root.appendingPathComponent(
                ".probe-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: probeRoot, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: probeRoot) }
            try FileManager.default.copyItem(
                at: tempURL,
                to: probeRoot.appendingPathComponent(CyberBrainLoader.defaultFilename))
            _ = try CyberBrainLoader(rootURL: probeRoot).load()
        } catch {
            throw WriteError.ioFailure("new archive failed validation: \(error.localizedDescription)")
        }

        var backupURL: URL?
        if hadExisting {
            backupURL = try backup(finalURL, root: root)
        }
        // rename(2) is atomic on APFS/HFS+: readers see the old or the new file.
        guard rename(tempURL.path, finalURL.path) == 0 else {
            throw WriteError.ioFailure("rename failed (errno \(errno))")
        }
        written = true
        // Durability of the directory entry itself.
        let dirDescriptor = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        if dirDescriptor >= 0 {
            fsync(dirDescriptor)
            close(dirDescriptor)
        }
        return backupURL
    }

    /// backups/cyberbrain-<timestamp>.json, bounded to `backupsToKeep`.
    private static func backup(_ fileURL: URL, root: URL) throws -> URL {
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let target = backups.appendingPathComponent(
                "cyberbrain-\(stamp)-\(UUID().uuidString.prefix(8)).json")
            try fileManager.copyItem(at: fileURL, to: target)
            let existing = try fileManager.contentsOfDirectory(
                at: backups, includingPropertiesForKeys: [.contentModificationDateKey])
                .filter { $0.pathExtension == "json" }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if existing.count > backupsToKeep {
                for stale in existing.prefix(existing.count - backupsToKeep) {
                    try? fileManager.removeItem(at: stale)
                }
            }
            return target
        } catch {
            throw WriteError.ioFailure("backup failed: \(error.localizedDescription)")
        }
    }
}
