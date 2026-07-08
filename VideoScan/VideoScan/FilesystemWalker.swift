import Darwin
import Foundation

// MARK: - FilesystemWalker

/// Directory-tree walking utilities for discovering video files.
/// All methods are static and nonisolated — safe to call from any context.
///
/// Discovery-completeness (2026-07-02): both walkers now
///   * optionally admit files with UNRECOGNIZED extensions ("Scan
///     Unrecognized File Types" — the magic-byte sniff in the probe engine
///     then gates them before ffprobe),
///   * report every skip decision and — critically — every DIRECTORY THE
///     ENUMERATOR COULD NOT READ to an optional `DiscoveryAuditCollector`.
///     The old code swallowed `contentsOfDirectory` errors with a bare
///     `continue`, which is exactly how a scan silently walks 181 of 5,694
///     files and looks healthy (the LaCieWorkspace incident class).
enum FilesystemWalker {

    /// Admission decision for one regular file. `reject` carries the reason
    /// so the audit can count each rule separately.
    enum FileAdmission: Equatable {
        case admit
        case reject(RejectionReason)
    }

    enum RejectionReason: Equatable {
        /// Known-non-media extension (.txt, .jpg, …), or an unrecognized
        /// extension while "Scan Unrecognized File Types" is off.
        case nonMediaExtension
        /// Audio extension while "Scan For Audio Files" is off.
        case audioScanningOff
        /// No extension while "Scan Files With No Extension" is off.
        case extensionlessScanningOff
    }

    /// Classify a regular file by extension. Normal scans admit only known
    /// media extensions. Admission is ADDITIVE: the video allowlist is always
    /// honored and each opt-in toggle adds a category on top —
    ///   * `scanAudioFiles` admits audio extensions,
    ///   * `probeExtensionless` admits files with NO extension (Rick's
    ///     "Scan files with no extension" — recovers Avid/QuickTime
    ///     video-only exports the allowlist silently dropped),
    ///   * `scanUnknownExtensions` admits extensions in NO list (not video,
    ///     not audio, not known-junk) — the probe engine's magic-byte sniff
    ///     then decides whether ffprobe is worth running.
    /// So enabling several toggles in one scan does what the user expects
    /// rather than one overriding another. ffprobe remains the arbiter for
    /// everything the allowlist can't vouch for.
    static func classifyFile(extension ext: String,
                             videoExtensions: Set<String>,
                             audioExtensions: Set<String> = [],
                             probeExtensionless: Bool = false,
                             scanAudioFiles: Bool = false,
                             scanUnknownExtensions: Bool = false,
                             knownNonMediaExtensions: Set<String> = SkipCategories.knownNonMediaExtensions
    ) -> FileAdmission {
        if videoExtensions.contains(ext) { return .admit }
        if audioExtensions.contains(ext) {
            return scanAudioFiles ? .admit : .reject(.audioScanningOff)
        }
        if ext.isEmpty {
            return probeExtensionless ? .admit : .reject(.extensionlessScanningOff)
        }
        if scanUnknownExtensions, !knownNonMediaExtensions.contains(ext) {
            return .admit
        }
        return .reject(.nonMediaExtension)
    }

    /// Boolean shim over `classifyFile` — kept for the walker-admission
    /// regression tests and any caller that only needs yes/no.
    static func shouldAdmitFile(extension ext: String,
                                videoExtensions: Set<String>,
                                audioExtensions: Set<String> = [],
                                probeExtensionless: Bool = false,
                                scanAudioFiles: Bool = false,
                                scanUnknownExtensions: Bool = false) -> Bool {
        classifyFile(extension: ext, videoExtensions: videoExtensions,
                     audioExtensions: audioExtensions,
                     probeExtensionless: probeExtensionless,
                     scanAudioFiles: scanAudioFiles,
                     scanUnknownExtensions: scanUnknownExtensions) == .admit
    }

    // MARK: - Shared walk core

    /// Everything one walk needs to decide skip/admit. Value type so the
    /// detached walker task captures an immutable snapshot of the policy.
    private struct WalkPolicy: Sendable {
        let videoExtensions: Set<String>
        let audioExtensions: Set<String>
        let skipDirs: Set<String>
        let skipBundleExtensions: Set<String>
        let minFileBytes: Int
        let probeExtensionless: Bool
        let scanAudioFiles: Bool
        let scanUnknownExtensions: Bool
    }

    /// Synchronous iterative depth-first walk. Both public walkers run this
    /// on their detached task; only the `emit` sink differs (collect vs
    /// stream). One implementation ⇒ the admission/audit rules can never
    /// drift between the two.
    private static func walkTree(
        root: String,
        policy: WalkPolicy,
        audit: DiscoveryAuditCollector?,
        onDirectoryEntered: ((URL) -> Void)?,
        emit: (URL) -> Void
    ) {
        let fm = FileManager.default
        var dirStack: [URL] = [URL(fileURLWithPath: root)]

        while !dirStack.isEmpty {
            if Task.isCancelled { break }
            let currentDir = dirStack.removeLast()
            onDirectoryEntered?(currentDir)

            let contents: [URL]
            do {
                // Bounded retry (walker-subtree-loss incident, 2026-07-02):
                // under process-wide fd pressure, contentsOfDirectory fails
                // with Cocoa error 256 on directories that read fine moments
                // later — and ONE transient failure on a top-level directory
                // used to cost the entire subtree for the scan. Two short
                // retries ride out the transient fd-pressure class ONLY
                // (Cocoa 256 / EMFILE); deterministic failures such as
                // permission-denied land in the audit below immediately.
                contents = try listDirectoryWithRetry(at: currentDir) { dir in
                    try fm.contentsOfDirectory(
                        at: dir,
                        includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey],
                        options: [.skipsHiddenFiles]
                    )
                }
            } catch {
                // Discovery-completeness: an unreadable directory means the
                // scan CANNOT claim it saw everything. Record it (the audit
                // forces scanWasComplete=false downstream) instead of the
                // old silent `continue`.
                audit?.directoryEnumerationFailed(path: currentDir.path, error: error)
                continue
            }

            for url in contents {
                if Task.isCancelled { break }
                guard let rv = try? url.resourceValues(
                    forKeys: [.isDirectoryKey, .isRegularFileKey, .isReadableKey, .fileSizeKey]
                ) else {
                    // QA 2026-07-02: an entry whose resource values cannot be
                    // fetched used to vanish with a bare `continue`. Record
                    // it — visibility only, the scan stays "complete" (the
                    // merge's existence check retains on-disk files, so
                    // nothing can be pruned by skipping it).
                    audit?.unreadableFile(path: url.path)
                    continue
                }

                if rv.isDirectory == true {
                    let dirName = url.lastPathComponent.lowercased()
                    let dirExt = url.pathExtension.lowercased()
                    if policy.skipDirs.contains(dirName) {
                        audit?.skippedSystemTreeDir()
                    } else if policy.skipBundleExtensions.contains(dirExt) {
                        audit?.skippedBundleDir()
                    } else {
                        dirStack.append(url)
                    }
                } else if rv.isRegularFile == true {
                    if rv.isReadable == true {
                        processRegularFile(url, fileSize: rv.fileSize, policy: policy,
                                           audit: audit, emit: emit)
                    } else {
                        // Regular file the walker can see but not read
                        // (permissions) — previously a silent skip. Same
                        // visibility-only treatment as above.
                        audit?.unreadableFile(path: url.path)
                    }
                } else {
                    // Neither a directory nor a regular file: symlink, fifo,
                    // socket, device node. The walker deliberately does not
                    // follow symlinks (cycle risk), but until 2026-07-02 this
                    // branch didn't exist and such entries vanished with NO
                    // audit trace — a silent hole in the completeness
                    // contract ("visit every reachable entry or say why
                    // not"). Visibility only; never forces scan-incomplete.
                    audit?.nonRegularEntry(path: url.path)
                }
            }
        }
    }

    /// List a directory with a bounded retry budget. ONLY transient failures
    /// — the fd-exhaustion / Cocoa-256 class from the 2026-07-02 incident
    /// (see `isRetryableListingError`) — are retried; they recover on a
    /// later attempt instead of costing the whole subtree. Deterministic
    /// failures (permission-denied 257 etc.) throw straight to the audit on
    /// the first attempt: retrying them can never succeed, and 3 attempts +
    /// 0.5 s of sleep per directory adds up to minutes on foreign-ownership
    /// volumes (QA 2026-07-02). Persistent retryable failures rethrow the
    /// LAST error for the audit. The delays are synchronous (`usleep`) by
    /// design: the walker runs on a detached task doing blocking FileManager
    /// I/O already, and worst case adds ~0.5 s per fd-starved directory.
    ///
    /// `list` is injectable so tests can pin the retry contract without
    /// filesystem games; production passes `fm.contentsOfDirectory`.
    static func listDirectoryWithRetry(
        at dir: URL,
        retryDelaysMicroseconds: [UInt32] = [100_000, 400_000],
        list: (URL) throws -> [URL]
    ) throws -> [URL] {
        var lastError: Error
        do {
            return try list(dir)
        } catch {
            guard isRetryableListingError(error) else { throw error }
            lastError = error
        }
        for delay in retryDelaysMicroseconds {
            usleep(delay)
            do {
                return try list(dir)
            } catch {
                guard isRetryableListingError(error) else { throw error }
                lastError = error
            }
        }
        throw lastError
    }

    /// The transient fd-pressure error class — the ONLY class worth
    /// retrying in `listDirectoryWithRetry`:
    ///   * `NSCocoaErrorDomain` code 256 (`NSFileReadUnknownError`) — the
    ///     2026-07-02 incident signature: what `contentsOfDirectory` throws
    ///     when the process fd table is full. Retryable even without an
    ///     underlying error (Foundation doesn't always attach one).
    ///   * Any Cocoa error whose underlying POSIX error is EMFILE/ENFILE —
    ///     the same fd-pressure class when Foundation DOES surface errno.
    /// Everything else (notably 257 / EACCES permission-denied) is
    /// deterministic and must fail immediately.
    static func isRetryableListingError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain,
           underlying.code == Int(EMFILE) || underlying.code == Int(ENFILE) {
            return true
        }
        return nsError.domain == NSCocoaErrorDomain
            && nsError.code == NSFileReadUnknownError
    }

    /// Classify one regular file, apply the .ts and small-file guards, and
    /// either emit it or record the skip reason. Split from `walkTree` so
    /// each function stays a readable size.
    private static func processRegularFile(
        _ url: URL,
        fileSize: Int?,
        policy: WalkPolicy,
        audit: DiscoveryAuditCollector?,
        emit: (URL) -> Void
    ) {
        audit?.fileEnumerated()
        // In-flight Media File Operation partials (m1, 2026-07-07):
        // Reformat/Transcode/Cleanup write to a `<stem>.vs-partial.<ext>`
        // sibling and atomically rename on completion. A concurrent scan
        // must never catalog the half-written transient — skip on the
        // marker substring. (Counted as a non-media skip in the audit:
        // it is not a media file to catalog.)
        if url.lastPathComponent.contains(".vs-partial.") {
            audit?.skippedNonMediaExtension()
            return
        }
        let ext = url.pathExtension.lowercased()
        switch classifyFile(extension: ext,
                            videoExtensions: policy.videoExtensions,
                            audioExtensions: policy.audioExtensions,
                            probeExtensionless: policy.probeExtensionless,
                            scanAudioFiles: policy.scanAudioFiles,
                            scanUnknownExtensions: policy.scanUnknownExtensions) {
        case .admit:
            if ext == "ts" && !isMpegTS(url) {
                audit?.skippedNonMediaExtension()   // TypeScript, not MPEG-TS
                return
            }
            if policy.minFileBytes > 0, let sz = fileSize, sz < policy.minFileBytes {
                audit?.skippedSmallFile()
                return
            }
            audit?.fileAdmitted()
            emit(url)
        case .reject(.nonMediaExtension):
            audit?.skippedNonMediaExtension()
        case .reject(.audioScanningOff):
            audit?.skippedAudioExtensionOff()
        case .reject(.extensionlessScanningOff):
            audit?.skippedExtensionlessOff()
        }
    }

    // MARK: - Public walkers

    /// Walk a single directory tree and return all video file URLs.
    /// Runs on a detached task to avoid blocking the cooperative thread pool
    /// (FileManager calls are synchronous and can stall on network volumes).
    static func walkDirectory(
        root: String,
        videoExtensions: Set<String>,
        skipDirs: Set<String>,
        skipBundleExtensions: Set<String>,
        skipSmallFiles: Bool,
        probeExtensionless: Bool = false,
        audioExtensions: Set<String> = [],
        scanAudioFiles: Bool = false,
        scanUnknownExtensions: Bool = false,
        audit: DiscoveryAuditCollector? = nil,
        onProgress: (@Sendable (_ currentDir: URL, _ filesFoundSoFar: Int, _ lastFile: URL?) -> Void)? = nil
    ) async -> [URL] {
        let policy = WalkPolicy(
            videoExtensions: videoExtensions,
            audioExtensions: audioExtensions,
            skipDirs: skipDirs,
            skipBundleExtensions: skipBundleExtensions,
            minFileBytes: skipSmallFiles ? 1_048_576 : 0,
            probeExtensionless: probeExtensionless,
            scanAudioFiles: scanAudioFiles,
            scanUnknownExtensions: scanUnknownExtensions
        )
        let result = await Task.detached(priority: .userInitiated) {
            var videoFiles: [URL] = []
            var lastDir = URL(fileURLWithPath: root)
            walkTree(root: root, policy: policy, audit: audit,
                     onDirectoryEntered: { dir in
                         lastDir = dir
                         onProgress?(dir, videoFiles.count, nil)
                     },
                     emit: { url in
                         videoFiles.append(url)
                         onProgress?(lastDir, videoFiles.count, url)
                     })
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
        probeExtensionless: Bool = false,
        audioExtensions: Set<String> = [],
        scanAudioFiles: Bool = false,
        scanUnknownExtensions: Bool = false,
        audit: DiscoveryAuditCollector? = nil,
        onDirectoryEntered: (@Sendable (_ currentDir: URL) -> Void)? = nil
    ) -> AsyncStream<URL> {
        let policy = WalkPolicy(
            videoExtensions: videoExtensions,
            audioExtensions: audioExtensions,
            skipDirs: skipDirs,
            skipBundleExtensions: skipBundleExtensions,
            minFileBytes: skipSmallFiles ? 1_048_576 : 0,
            probeExtensionless: probeExtensionless,
            scanAudioFiles: scanAudioFiles,
            scanUnknownExtensions: scanUnknownExtensions
        )
        return AsyncStream(URL.self, bufferingPolicy: .unbounded) { continuation in
            let walker = Task.detached(priority: .userInitiated) {
                walkTree(root: root, policy: policy, audit: audit,
                         onDirectoryEntered: { onDirectoryEntered?($0) },
                         emit: { continuation.yield($0) })
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
