import Foundation

// MARK: - FilesystemWalker

/// Directory-tree walking utilities for discovering video files.
/// All methods are static and nonisolated — safe to call from any context.
enum FilesystemWalker {

    /// Walk a single directory tree and return all video file URLs.
    /// Runs on a detached task to avoid blocking the cooperative thread pool
    /// (FileManager calls are synchronous and can stall on network volumes).
    static func walkDirectory(
        root: String,
        videoExtensions: Set<String>,
        skipDirs: Set<String>,
        skipBundleExtensions: Set<String>,
        skipSmallFiles: Bool,
        onProgress: (@Sendable (_ currentDir: URL, _ filesFoundSoFar: Int, _ lastFile: URL?) -> Void)? = nil
    ) async -> [URL] {
        let minFileBytes: Int = skipSmallFiles ? 1_048_576 : 0
        let result = await Task.detached(priority: .userInitiated) {
            var videoFiles: [URL] = []
            let fm = FileManager.default
            var dirStack: [URL] = [URL(fileURLWithPath: root)]

            while !dirStack.isEmpty {
                if Task.isCancelled { break }
                let currentDir = dirStack.removeLast()
                onProgress?(currentDir, videoFiles.count, nil)

                let contents: [URL]
                do {
                    contents = try fm.contentsOfDirectory(
                        at: currentDir,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    )
                } catch {
                    continue
                }

                for url in contents {
                    if Task.isCancelled { break }
                    guard let rv = try? url.resourceValues(
                        forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey]
                    ) else { continue }

                    if rv.isDirectory == true {
                        let dirName = url.lastPathComponent.lowercased()
                        let dirExt = url.pathExtension.lowercased()
                        if !skipDirs.contains(dirName)
                            && !skipBundleExtensions.contains(dirExt) {
                            dirStack.append(url)
                        }
                    } else if rv.isRegularFile == true && rv.isReadable == true {
                        let ext = url.pathExtension.lowercased()
                        if videoExtensions.contains(ext) {
                            if ext == "ts" && !isMpegTS(url) {
                                continue
                            }
                            if minFileBytes > 0, let sz = rv.fileSize, sz < minFileBytes {
                                continue
                            }
                            videoFiles.append(url)
                            onProgress?(currentDir, videoFiles.count, url)
                        }
                    }
                }
            }
            return videoFiles
        }.value
        return result
    }

    /// Walk a directory tree and yield video file URLs as they are discovered
    /// via an `AsyncStream<URL>`. The walker runs on a detached task so FileManager
    /// I/O doesn't block the cooperative pool.
    ///
    /// This is the network-friendly variant: interleaving content reads (probe)
    /// with directory enumeration keeps the SMB session warm end-to-end.
    static func walkDirectoryStream(
        root: String,
        videoExtensions: Set<String>,
        skipDirs: Set<String>,
        skipBundleExtensions: Set<String>,
        skipSmallFiles: Bool,
        onDirectoryEntered: (@Sendable (_ currentDir: URL) -> Void)? = nil
    ) -> AsyncStream<URL> {
        let minFileBytes: Int = skipSmallFiles ? 1_048_576 : 0
        return AsyncStream(URL.self, bufferingPolicy: .unbounded) { continuation in
            let walker = Task.detached(priority: .userInitiated) {
                let fm = FileManager.default
                var dirStack: [URL] = [URL(fileURLWithPath: root)]
                while !dirStack.isEmpty {
                    if Task.isCancelled { break }
                    let currentDir = dirStack.removeLast()
                    onDirectoryEntered?(currentDir)

                    let contents: [URL]
                    do {
                        contents = try fm.contentsOfDirectory(
                            at: currentDir,
                            includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey],
                            options: [.skipsHiddenFiles]
                        )
                    } catch {
                        continue
                    }

                    for url in contents {
                        if Task.isCancelled { break }
                        guard let rv = try? url.resourceValues(
                            forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey]
                        ) else { continue }

                        if rv.isDirectory == true {
                            let dirName = url.lastPathComponent.lowercased()
                            let dirExt = url.pathExtension.lowercased()
                            if !skipDirs.contains(dirName)
                                && !skipBundleExtensions.contains(dirExt) {
                                dirStack.append(url)
                            }
                        } else if rv.isRegularFile == true && rv.isReadable == true {
                            let ext = url.pathExtension.lowercased()
                            if videoExtensions.contains(ext) {
                                if ext == "ts" && !isMpegTS(url) {
                                    continue
                                }
                                if minFileBytes > 0, let sz = rv.fileSize, sz < minFileBytes {
                                    continue
                                }
                                continuation.yield(url)
                            }
                        }
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                walker.cancel()
            }
        }
    }

    /// Check if a .ts file is actually an MPEG transport stream (not TypeScript).
    /// Standard MPEG-TS: sync byte 0x47 at offset 0 (188-byte packets).
    /// BDAV/AVCHD:        sync byte 0x47 at offset 4 (192-byte packets with timecode prefix).
    static func isMpegTS(_ url: URL) -> Bool {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var buf = [UInt8](repeating: 0, count: 5)
        let n = read(fd, &buf, 5)
        guard n >= 1 else { return false }
        return buf[0] == 0x47 || (n >= 5 && buf[4] == 0x47)
    }
}
