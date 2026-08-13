import CryptoKit
import Darwin
import Foundation

// MARK: - FileHasher
//
// Two hashes, deliberately kept separate, for two jobs with very
// different consequences.
//
//   partialMD5     — head+tail MD5, 64 KB chunks. The catalog's long-
//                    standing identity key. Six subsystems key off it
//                    (relocate reconcile, dossier propagation, catalog
//                    import/export dedup, review sessions, duplicate
//                    detection, training candidates). UNCHANGED.
//
//   segmentedHash  — head‖middle‖tail‖size SHA-256. A fast CANDIDATE
//                    filter. It can prove two files DIFFERENT; it can
//                    never prove them the same.
//   fullHash       — every byte. The only thing that may authorise a
//                    deletion.
//
// WHY A SECOND HASH RATHER THAN A BETTER FIRST ONE. partialMD5 reads the
// first 64 KB and the last 64 KB and, critically, SKIPS THE TAIL
// ENTIRELY for any file under 128 KB — but the real problem is what it
// never looks at: the middle. Two distinct Avid MXF essence files from
// one session share a wrapper header, and operational padding can leave
// them the same length. Head + tail + size then say "identical" for two
// files whose PICTURE CONTENT differs. That is a perfectly acceptable
// risk for "suggest these might be duplicates" and an unacceptable one
// for "delete five of these eight copies" — the failure is silent and
// the footage is unrecoverable.
//
// WHAT SEGMENTED HASHING CAN AND CANNOT DO — read this before using it
// for anything destructive.
//
// It samples three 1 MiB windows out of a file that may be 12 GB. Two
// files sharing a size and all three windows can still differ across
// the ~11.997 GB nobody looked at. Rare for real media; NOT impossible,
// and "rare" is not a basis for deleting irreplaceable footage.
//
// So the contract is deliberately one-directional:
//
//     different segmented hash  ⇒  DEFINITELY different files
//     same segmented hash       ⇒  CANDIDATES, nothing more
//
// An earlier version of this header called it "identity strong enough
// to delete on". That was wrong, and codex was right to stop-ship it
// (#320). The speed argument still holds — three seeks beat streaming
// 12 GB, and that is what makes a whole-catalog pass take minutes — but
// speed buys CANDIDATE GENERATION, not proof.
//
// Anything destructive must call `fullHash` (or a byte compare) on the
// actual pair first. `SignatureVerification` exists to make that
// unmissable rather than a convention someone forgets.
//
// NO mmap ANYWHERE. mmap on a network file SIGBUSes (KERN_MEMORY_ERROR)
// if the remote volume drops mid-read, and this code runs across SMB
// against drives that sleep. Plain read()/lseek() only.

enum FileHasher {

    /// Compute a partial MD5 of the file at `path` by hashing the first and
    /// last `chunkSize` bytes. Returns an empty string on any I/O error.
    /// Uses read() instead of mmap() — mmap on network files can SIGBUS
    /// (KERN_MEMORY_ERROR) if the remote volume becomes unreachable mid-read.
    static func partialMD5(path: String, chunkSize: Int = 65536) -> String {
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return "" }
        let fileSize = Int(sb.st_size)
        guard fileSize > 0 else { return "" }

        var md5 = Insecure.MD5()
        let buf = UnsafeMutableRawPointer.allocate(byteCount: chunkSize, alignment: 16)
        defer { buf.deallocate() }

        // Hash first chunk
        let headLen = min(chunkSize, fileSize)
        let headRead = read(fd, buf, headLen)
        guard headRead > 0 else { return "" }
        md5.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: headRead))

        // Hash last chunk if file is large enough
        if fileSize > chunkSize * 2 {
            let tailOffset = off_t(fileSize - chunkSize)
            guard lseek(fd, tailOffset, SEEK_SET) == tailOffset else { return "" }
            let tailRead = read(fd, buf, chunkSize)
            guard tailRead > 0 else { return "" }
            md5.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: tailRead))
        }

        return md5.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Segmented content hash

    /// Bytes sampled from each of the three windows. 1 MiB is far past
    /// any container header and deep enough into an essence stream to
    /// carry real frame data.
    static let segmentSize = 1 << 20   // 1 MiB

    /// Version tag baked into the digest. If the sampling geometry ever
    /// changes, bump this: stored hashes from the old geometry then
    /// compare unequal to new ones instead of silently pairing files
    /// that were never compared the same way. A silent geometry change
    /// is how a dedup index quietly starts lying.
    static let segmentedHashVersion = "v1"

    /// Content hash for identity decisions, formatted `v1:<64 hex>`.
    ///
    /// Digest input is, in order: the version tag, the file's byte
    /// length, then the head, middle, and tail windows. Length is bound
    /// into the digest so two files of different size can never collide
    /// no matter how their sampled bytes line up.
    ///
    /// Files at or under `3 × segmentSize` are hashed IN FULL — at that
    /// size the three windows would overlap, and hashing everything is
    /// both cheaper to reason about and strictly stronger. That makes
    /// the function exact for anything ≤ 3 MiB and sampled above it.
    ///
    /// Returns "" on any I/O error, matching `partialMD5`'s contract:
    /// callers already treat an empty hash as "no identity evidence",
    /// and an empty string can never compare equal to a real digest.
    static func segmentedHash(path: String, segmentSize: Int = FileHasher.segmentSize) -> String {
        guard segmentSize > 0 else { return "" }

        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return "" }
        // Directories, devices, and FIFOs are not content to hash. A
        // FIFO in particular would BLOCK the scan thread forever.
        guard (sb.st_mode & S_IFMT) == S_IFREG else { return "" }

        let fileSize = Int(sb.st_size)
        guard fileSize > 0 else { return "" }

        var sha = SHA256()

        // Bind version + length into the digest before any file bytes.
        sha.update(data: Data("\(segmentedHashVersion):\(fileSize):".utf8))

        let buf = UnsafeMutableRawPointer.allocate(byteCount: segmentSize, alignment: 16)
        defer { buf.deallocate() }

        /// Read exactly `count` bytes at `offset` into the digest.
        /// read() is allowed to return short (signals, network
        /// filesystems, large requests), so loop until satisfied — a
        /// short read treated as complete would make the digest depend
        /// on transport timing rather than on content.
        func absorb(offset: Int, count: Int) -> Bool {
            guard count > 0 else { return true }
            guard lseek(fd, off_t(offset), SEEK_SET) == off_t(offset) else { return false }
            var got = 0
            while got < count {
                let n = read(fd, buf.advanced(by: got), count - got)
                if n > 0 {
                    got += n
                } else if n == 0 {
                    // EOF before we read what fstat promised: the file
                    // SHRANK mid-hash. Hashing the short read would mix
                    // fewer bytes with the ORIGINAL length already baked
                    // into the digest, producing a signature nobody —
                    // including a later verification pass — could ever
                    // reproduce. Refuse; the next run picks it up.
                    // codex #320.7.
                    return false
                } else if errno == EINTR {
                    continue                    // interrupted, retry
                } else {
                    return false                // real I/O error
                }
            }
            sha.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: got))
            return true
        }

        if fileSize <= segmentSize * 3 {
            // Small enough that sampling would overlap — hash it all.
            var offset = 0
            while offset < fileSize {
                let chunk = min(segmentSize, fileSize - offset)
                guard absorb(offset: offset, count: chunk) else { return "" }
                offset += chunk
            }
        } else {
            let midOffset = (fileSize - segmentSize) / 2
            let tailOffset = fileSize - segmentSize
            guard absorb(offset: 0, count: segmentSize),
                  absorb(offset: midOffset, count: segmentSize),
                  absorb(offset: tailOffset, count: segmentSize)
            else { return "" }
        }

        let hex = sha.finalize().map { String(format: "%02x", $0) }.joined()
        return "\(segmentedHashVersion):\(hex)"
    }

    /// Full-file SHA-256, for the final verification of a copy that is
    /// about to become the SURVIVOR of a duplicate collapse. Streams in
    /// `segmentSize` blocks — bounded memory regardless of file size.
    ///
    /// Deliberately NOT used for bulk indexing: on a 12 GB file over USB
    /// this is minutes, not milliseconds. It exists so an irreversible
    /// delete can be gated on certainty rather than on sampling.
    static func fullHash(path: String, blockSize: Int = FileHasher.segmentSize) -> String {
        guard blockSize > 0 else { return "" }
        let fd = open(path, O_RDONLY)
        guard fd >= 0 else { return "" }
        defer { close(fd) }

        var sb = stat()
        guard fstat(fd, &sb) == 0 else { return "" }
        guard (sb.st_mode & S_IFMT) == S_IFREG else { return "" }
        let fileSize = Int(sb.st_size)
        guard fileSize > 0 else { return "" }

        var sha = SHA256()
        sha.update(data: Data("full:\(fileSize):".utf8))

        let buf = UnsafeMutableRawPointer.allocate(byteCount: blockSize, alignment: 16)
        defer { buf.deallocate() }

        var total = 0
        while true {
            let n = read(fd, buf, blockSize)
            if n > 0 {
                sha.update(bufferPointer: UnsafeRawBufferPointer(start: buf, count: n))
                total += n
            } else if n == 0 {
                break
            } else if errno == EINTR {
                continue
            } else {
                return ""
            }
        }
        // The file changed size mid-read: the digest describes bytes
        // that no longer form the file. Refuse rather than return a
        // hash nobody can reproduce.
        guard total == fileSize else { return "" }

        return "full:" + sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
