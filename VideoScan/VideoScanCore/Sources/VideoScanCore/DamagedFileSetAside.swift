// DamagedFileSetAside.swift
// One shared way to keep a hand-curated file that can no longer be read:
// MOVE it (never copy, never delete) to `<name>.damaged-<ISO8601>` beside
// itself before anything is written in its place. Used by the photo "not
// of" sidecar (N1012-F2) and meant for the identity-rulings file
// (N1009-D F1, branch fix/p1-relocate-witness-and-rulings, which carries
// a private copy of this routine today) — one helper, not two copies.
//
// C++ readers: an `enum` with no cases is Swift's namespace-only type
// (like a `struct` with only `static` members and a deleted constructor).

import Foundation

public enum DamagedFileSetAside {
    /// The damaged file could not be moved aside; nothing was moved, and the
    /// caller must refuse its write so the bytes stay where they are.
    public struct NotPreserved: LocalizedError, Equatable {
        public let path: String
        public let errnoValue: Int32
        public var errorDescription: String? {
            "The file at \(path) could not be read, and it could not be set aside safely "
                + "(\(String(cString: strerror(errnoValue)))), so nothing was saved."
        }
    }

    /// `<name>.damaged-<yyyyMMdd'T'HHmmss'Z'>`, then `-2` … `-99` if that
    /// second is taken. `renamex_np(RENAME_EXCL)` never replaces an existing
    /// file. Throws `NotPreserved` (and moves nothing) on any other failure.
    /// Returns where the bytes now live.
    public static func move(_ url: URL, now: Date = Date()) throws -> URL {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let base = url.path + ".damaged-" + fmt.string(from: now)
        var lastErr: Int32 = EEXIST
        for n in 1...99 {
            let candidate = n == 1 ? base : "\(base)-\(n)"
            if renamex_np(url.path, candidate, UInt32(RENAME_EXCL)) == 0 {
                return URL(fileURLWithPath: candidate)
            }
            lastErr = errno
            if lastErr != EEXIST { break }
        }
        throw NotPreserved(path: url.path, errnoValue: lastErr)
    }
}
