// MasterArchiveReadoption.swift
// GH #167 recovery: the catalog carries no Master Archive designation, but
// a mounted volume holds an archive tree with its self-describing marker —
// `Breen_Family_Archive/00_Index/Archive_Inventory_Manifest.csv`. Offer to
// re-adopt it. NEVER re-designate on our own: the offer opens the ordinary
// Initialize sheet (create-if-missing throughout, so it is adopt-safe — it
// never truncates the manifest or README) and Rick confirms there.
//
// Read-only: lstat calls on the candidate folders, nothing else. Runs off
// the main thread (a sleeping disk can block a stat).

import Foundation
import os

private let readoptionLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "masterArchive")

/// An archive tree found on disk while nothing is designated.
struct MasterArchiveReadoptionCandidate: Identifiable, Equatable, Sendable {
    var id: String { targetPath }
    /// The folder Initialize would designate (the volume root, or the
    /// folder that holds `Breen_Family_Archive`).
    let targetPath: String
    let rootPath: String
    /// Rows in the manifest (data lines below the header) — evidence the
    /// archive is in use, shown in the offer.
    let manifestRows: Int
}

extension VideoScanModel {

    /// Every `<base>` in `searchPaths` whose `<base>/Breen_Family_Archive`
    /// is a real directory (not a symlink) holding `00_Index/<manifest>` as
    /// a regular file. Pure function of the filesystem; no writes.
    /// `nonisolated` ≈ a free function — call it off the main actor.
    nonisolated static func findReadoptionCandidates(searchPaths: [String]) -> [MasterArchiveReadoptionCandidate] {
        var seen = Set<String>()
        var out: [MasterArchiveReadoptionCandidate] = []
        for raw in searchPaths where !raw.isEmpty {
            let base = PathScope.normalize(URL(fileURLWithPath: raw).standardizedFileURL.path)
            guard seen.insert(base).inserted else { continue }
            let root = MasterArchiveLayout.rootURL(forTargetPath: base).path
            let index = (root as NSString).appendingPathComponent(MasterArchiveLayout.indexFolder)
            let manifest = MasterArchiveLayout.manifestURL(rootPath: root).path
            guard isRealDirectory(root), isRealDirectory(index), isRegularFile(manifest) else { continue }
            out.append(MasterArchiveReadoptionCandidate(targetPath: base, rootPath: root,
                                                        manifestRows: manifestDataRows(manifest)))
        }
        return out.sorted { $0.targetPath < $1.targetPath }
    }

    /// The mounted volumes under `volumesRoot` plus every scan target's
    /// folder (a designation may be a folder inside a volume). Then the
    /// off-main search. Returns [] when a designation exists. Logs ONE
    /// line per candidate per session — evidence for the log, nothing
    /// changed.
    func findMasterArchivesAwaitingReadoption(volumesRoot: String = "/Volumes") async -> [MasterArchiveReadoptionCandidate] {
        guard masterArchive == nil else { return [] }
        let targetPaths = scanTargets.map(\.searchPath)
        let found = await Task.detached(priority: .utility) { () -> [MasterArchiveReadoptionCandidate] in
            let mounts = ((try? FileManager.default.contentsOfDirectory(atPath: volumesRoot)) ?? [])
                .map { (volumesRoot as NSString).appendingPathComponent($0) }
            return Self.findReadoptionCandidates(searchPaths: mounts + targetPaths)
        }.value
        // The world may have moved during the await.
        guard masterArchive == nil else { return [] }
        for c in found where Self.readoptionReported.insert(c.targetPath).inserted {
            let line = "Master Archive: none designated, but \(c.rootPath) carries an archive manifest (\(c.manifestRows) line(s)). Nothing was changed — Archive tab ▸ Re-adopt… makes it the Master Archive again after you confirm (GH #167)."
            log(line)
            appLog.write(line)
            readoptionLog.notice("\(line, privacy: .public)")
        }
        return found
    }

    /// Re-adopt = the ordinary Initialize sheet for that folder (Rick
    /// confirms; Initialize is create-if-missing, so the tree, manifest and
    /// README are kept as they are).
    func offerReadoptMasterArchive(_ candidate: MasterArchiveReadoptionCandidate) {
        let line = "Master Archive: Re-adopt offered for \(candidate.targetPath) — waiting for confirmation."
        log(line)
        appLog.write(line)
        offerInitializeMasterArchive(atPath: candidate.targetPath)
    }

    /// Candidates already logged this session (one line each, not one per
    /// Archive-tab visit). Static stored property ≈ a C++ class static.
    private static var readoptionReported = Set<String>()

    nonisolated private static func lstatMode(_ path: String) -> mode_t? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return st.st_mode & S_IFMT
    }

    nonisolated private static func isRealDirectory(_ path: String) -> Bool {
        lstatMode(path) == S_IFDIR
    }

    nonisolated private static func isRegularFile(_ path: String) -> Bool {
        lstatMode(path) == S_IFREG
    }

    /// Data lines in the manifest (non-empty lines after the header) —
    /// evidence only (a quoted field with a newline counts twice).
    /// Opened O_NOFOLLOW|O_NONBLOCK and fstat'ed before any read, so a
    /// FIFO or device swapped in after the lstat can never block us
    /// (ARCH-8). Bounded: the manifest is a small CSV; cap at 64 MB.
    nonisolated private static func manifestDataRows(_ path: String) -> Int {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { return 0 }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { close(fd); return 0 }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let data = try? h.read(upToCount: 64 << 20) else { return 0 }
        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return max(0, lines.count - 1)
    }
}
