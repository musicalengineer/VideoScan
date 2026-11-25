// PersonRefreshLaunchScratch.swift
// The per-launch scratch folder of "Refresh from FamilySearch…" — made, and
// freed, by identity (codex closing pass on 84e7a599f, P1).
//
//   <answerScratchRoot>/<UUID>/<FSID>-<stamp>/person.ged
//                       ^ made here   ^ made here  ^ the tool's answer
//
// MAKE: mkdirat the UUID folder and its leaf relative to descriptors, open
// each O_NOFOLLOW and record its (st_dev, st_ino). mkdirat fails on anything
// already there, so what is recorded is exactly what this launch created.
//
// FREE: open the root, then the UUID folder and the leaf relative to it,
// O_NOFOLLOW, and require each recorded identity — a folder renamed aside and
// replaced, or a path redirected through a swapped ancestor, reaches another
// inode and is left alone. Then the whole tree must be what the launch made
// (the leaf; in it, at most person.ged) — anything else and NOTHING is
// removed; the caller logs the one-line reason. Removal is unlinkat relative
// to the verified descriptors (a symlink is unlinked, never followed), then
// rmdir of the leaf and of the UUID folder by name relative to their verified
// parents. Residual: between the identity check and that final rmdir a racer
// could swap in a different EMPTY folder under the same name; rmdir removes
// only empty folders, so that is the most it can cost.
//
// Scratch only — never media, never family data (those go to Trash). Memory:
// two short strings and four integers per live launch.
//
// (For Rick: openat/unlinkat are the *at() family — paths resolved relative to
// an already-open directory descriptor, like holding a handle instead of
// re-walking a path string that someone may have changed.)

import Darwin
import Foundation

struct PersonRefreshLaunchScratch: Equatable, Sendable {
    struct Identity: Equatable, Sendable {
        let device: UInt64
        let inode: UInt64
    }

    let root: URL
    let name: String
    let identity: Identity
    let leafName: String
    let leafIdentity: Identity

    /// `<root>/<name>/`.
    var folder: URL { root.appendingPathComponent(name, isDirectory: true) }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Make `<root>/<name>/<leafName>/` (root must exist). Throws when either
    /// level exists already or cannot be made/opened; a half-made UUID folder
    /// (still empty) is removed before the throw.
    static func make(in root: URL, name: String, leafName: String) throws -> PersonRefreshLaunchScratch {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw posixError("open \(root.lastPathComponent)") }
        defer { close(rootFD) }
        guard mkdirat(rootFD, name, 0o700) == 0 else { throw posixError("mkdir \(name)") }
        let folderFD = openat(rootFD, name, directoryFlags)
        guard folderFD >= 0, let folderID = Self.identity(of: folderFD) else {
            let error = posixError("open \(name)")
            if folderFD >= 0 { close(folderFD) }
            unlinkat(rootFD, name, AT_REMOVEDIR)
            throw error
        }
        defer { close(folderFD) }
        guard mkdirat(folderFD, leafName, 0o700) == 0 else {
            let error = posixError("mkdir \(leafName)")
            unlinkat(rootFD, name, AT_REMOVEDIR)
            throw error
        }
        let leafFD = openat(folderFD, leafName, directoryFlags)
        guard leafFD >= 0, let leafID = Self.identity(of: leafFD) else {
            let error = posixError("open \(leafName)")
            if leafFD >= 0 { close(leafFD) }
            unlinkat(folderFD, leafName, AT_REMOVEDIR)
            unlinkat(rootFD, name, AT_REMOVEDIR)
            throw error
        }
        close(leafFD)
        return PersonRefreshLaunchScratch(root: root, name: name, identity: folderID,
                                          leafName: leafName, leafIdentity: leafID)
    }

    /// Free what `make` made. nil = freed (or already gone); otherwise the
    /// reason it stopped — every identity and content check runs before the
    /// first unlink, so only an unlink that itself fails stops part-way.
    func free() -> String? {
        let rootFD = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { return errno == ENOENT ? nil : Self.reason("open the scratch root") }
        defer { close(rootFD) }
        let folderFD = openat(rootFD, name, Self.directoryFlags)
        guard folderFD >= 0 else { return errno == ENOENT ? nil : Self.reason("open \(name)") }
        defer { close(folderFD) }
        guard Self.identity(of: folderFD) == identity else { return "\(name) is no longer the folder this launch made" }
        guard let top = Self.entries(of: folderFD) else { return Self.reason("list \(name)") }
        guard top.isSubset(of: [leafName]) else { return "\(name) holds what this launch did not make: \(top.sorted())" }
        if top.contains(leafName), let kept = freeLeaf(in: folderFD) { return kept }
        guard unlinkat(rootFD, name, AT_REMOVEDIR) == 0 else { return Self.reason("remove \(name)") }
        return nil
    }

    /// The leaf level of `free`, under the already-verified UUID folder: the
    /// leaf's identity, its content (at most person.ged), then the unlinks.
    private func freeLeaf(in folderFD: Int32) -> String? {
        let leafFD = openat(folderFD, leafName, Self.directoryFlags)
        guard leafFD >= 0 else { return Self.reason("open \(leafName)") }
        defer { close(leafFD) }
        guard Self.identity(of: leafFD) == leafIdentity else { return "\(leafName) is no longer the folder this launch made" }
        guard let inLeaf = Self.entries(of: leafFD) else { return Self.reason("list \(leafName)") }
        guard inLeaf.isSubset(of: [PersonRefreshPaths.outputFileName]) else {
            return "\(leafName) holds what this launch did not make: \(inLeaf.sorted())"
        }
        for entry in inLeaf where unlinkat(leafFD, entry, 0) != 0 { return Self.reason("remove \(entry)") }
        guard unlinkat(folderFD, leafName, AT_REMOVEDIR) == 0 else { return Self.reason("remove \(leafName)") }
        return nil
    }

    private static func identity(of fd: Int32) -> Identity? {
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else { return nil }
        return Identity(device: UInt64(UInt32(bitPattern: info.st_dev)), inode: UInt64(info.st_ino))
    }

    /// The names in an open directory (not "." / ".."); nil when unreadable.
    private static func entries(of fd: Int32) -> Set<String>? {
        let copy = dup(fd)
        guard copy >= 0 else { return nil }
        guard let dir = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(dir) }   // closes `copy`
        rewinddir(dir)
        var names = Set<String>()
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self))
            }
            if name != "." && name != ".." { names.insert(name) }
        }
        return names
    }

    private static func reason(_ what: String) -> String {
        "could not \(what): \(String(cString: strerror(errno)))"
    }

    private static func posixError(_ what: String) -> NSError {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code),
                       userInfo: [NSLocalizedDescriptionKey: "could not \(what): \(String(cString: strerror(code)))"])
    }
}
