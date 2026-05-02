import Foundation
import CryptoKit

// MARK: - FileHasher

/// Partial MD5 hashing for duplicate detection. Reads the first and last
/// chunks of a file (no mmap — safe for network volumes).
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
}
