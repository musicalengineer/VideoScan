// RelocateSourceDestGuardTests.swift
// GH #109 — the Migrate sheet allowed source == destination
// (LaCieWorkspace → itself, an 18,878-record reconcile). The 2026-08-17
// check compared path STRINGS in the sheet only: a symlinked alias, the
// data-volume firmlink spelling or a different letter case slipped past
// it, and the model's `enqueueRelocate` accepted anything.
//
// Isolation: scratch directories under the test temp dir; the catalog is
// a private CatalogStore(directory:); no /Volumes path is created or
// written. Real-filesystem cases (symlink, firmlink, case) resolve the
// scratch directories themselves.

import Foundation
import Testing
@testable import VideoScan

@Suite("GH #109 — Migrate refuses source == destination, however it is spelled", .serialized)
@MainActor
struct RelocateSourceDestGuardTests {

    /// root/real (the source), root/alias → root/real (a symlink).
    private func workspace() throws -> (root: URL, real: URL, alias: URL, other: URL, catalog: URL) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory
            .appendingPathComponent("test_109_guard_\(UUID().uuidString.prefix(8))", isDirectory: true)
        let real = root.appendingPathComponent("SourceVol", isDirectory: true)
        let other = root.appendingPathComponent("OtherDest", isDirectory: true)
        let catalog = root.appendingPathComponent("catalog", isDirectory: true)
        for u in [real, other, catalog] { try fm.createDirectory(at: u, withIntermediateDirectories: true) }
        let alias = root.appendingPathComponent("AliasToSource")
        try fm.createSymbolicLink(at: alias, withDestinationURL: real)
        return (root, real, alias, other, catalog)
    }

    private func resolved(_ url: URL) -> String {
        guard let raw = realpath(url.path, nil) else { return url.path }
        defer { free(raw) }
        return String(cString: raw)
    }

    // MARK: Sheet check (the UI gate)

    @Test("a symlinked alias of the source is the source")
    func symlinkAliasIdentical() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        #expect(RelocateSheet.destinationProblem(source: ws.real.path, destination: ws.alias) != nil)
    }

    @Test("a folder under a symlinked alias of the source is inside the source")
    func symlinkAliasNested() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        #expect(RelocateSheet.destinationProblem(source: ws.real.path,
                                                 destination: ws.alias.appendingPathComponent("from_SourceVol")) != nil)
        #expect(RelocateSheet.destinationProblem(source: ws.alias.appendingPathComponent("sub").path,
                                                 destination: ws.real) != nil,
                "source inside the destination, spelled through the alias")
    }

    @Test("the data-volume firmlink spelling of the source is the source")
    func firmlinkSpelling() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let firm = "/System/Volumes/Data" + resolved(ws.real)
        try #require(FileManager.default.fileExists(atPath: firm), "firmlink spelling not present on this host")
        #expect(RelocateSheet.destinationProblem(source: ws.real.path,
                                                 destination: URL(fileURLWithPath: firm + "/nested")) != nil)
    }

    @Test("a different letter case on a case-insensitive volume is the same folder")
    func caseFolded() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let caseSensitive = try ws.real.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
            .volumeSupportsCaseSensitiveNames ?? true
        try #require(!caseSensitive, "scratch volume is case-sensitive")
        let upper = ws.root.appendingPathComponent("SOURCEVOL", isDirectory: true)
        #expect(RelocateSheet.destinationProblem(source: ws.real.path, destination: upper) != nil)
    }

    @Test("a sibling folder is still a valid destination (no over-refusal)")
    func siblingAllowed() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        #expect(RelocateSheet.destinationProblem(source: ws.real.path, destination: ws.other) == nil)
        #expect(RelocateSheet.destinationProblem(source: ws.real.path,
                                                 destination: ws.other.appendingPathComponent("from_SourceVol/not-yet-created")) == nil)
        // A prefix-sharing name is not containment.
        #expect(RelocateSheet.destinationProblem(source: ws.real.path,
                                                 destination: ws.root.appendingPathComponent("SourceVol 1")) == nil)
    }

    // MARK: Model / job layer (the gate that cannot be bypassed)

    private func model(ws: (root: URL, real: URL, alias: URL, other: URL, catalog: URL)) throws -> VideoScanModel {
        let file = ws.real.appendingPathComponent("clip.bin")
        try Data(repeating: 7, count: 512).write(to: file)
        let rec = VideoRecord()
        rec.filename = "clip.bin"
        rec.fullPath = file.path
        rec.directory = ws.real.path
        rec.sizeBytes = 512
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: ws.catalog)
        m.records = [rec]
        return m
    }

    private func options(_ source: String, _ dest: URL) -> RelocateOptions {
        RelocateOptions(sourceVolumeRootPath: source, destinationRoot: dest,
                        maxConcurrency: 1, dryRun: true, skipAlreadyRelocated: true)
    }

    @Test("enqueueRelocate refuses source == destination before queuing anything")
    func enqueueRefusesIdentical() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let m = try model(ws: ws)
        let id = m.enqueueRelocate(sourceRootPath: ws.real.path, destinationRoot: ws.real,
                                   options: options(ws.real.path, ws.real))
        #expect(id == nil)
        #expect(m.relocateQueue.isEmpty, "a refused Migrate must not queue a job")
    }

    @Test("enqueueRelocate refuses a symlinked alias and a nested destination")
    func enqueueRefusesAliasAndNested() throws {
        let ws = try workspace()
        defer { try? FileManager.default.removeItem(at: ws.root) }
        let m = try model(ws: ws)
        #expect(m.enqueueRelocate(sourceRootPath: ws.real.path, destinationRoot: ws.alias,
                                  options: options(ws.real.path, ws.alias)) == nil)
        let nested = ws.real.appendingPathComponent("from_SourceVol")
        #expect(m.enqueueRelocate(sourceRootPath: ws.real.path, destinationRoot: nested,
                                  options: options(ws.real.path, nested)) == nil)
        #expect(m.relocateQueue.isEmpty)
    }
}
