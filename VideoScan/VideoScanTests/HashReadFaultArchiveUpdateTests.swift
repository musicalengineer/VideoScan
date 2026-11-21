// HashReadFaultArchiveUpdateTests.swift
// NEGATIVE MATRIX — Update… on an archived file (the Refile engine) under a
// faulted full read (hash read seam, 2026-11-20). The engine reads the file
// twice through `ArchivePromoteEngine.sha256(root:relativePath:)`: at its old
// path before the move (preflight) and at its new path after it (read-back).
// Each of {EIO mid-file, a read that ends early, one flipped bit} × those
// two reads:
//
//   before the move → REFUSED: nothing renamed, every index file
//                     byte-identical, the record and its fixity untouched;
//   after the move  → ROLLED BACK: the file is back at its old path, every
//                     index file holds its old bytes, the record unchanged.
//
// Never `updated`; the message names the path and what the read found; the
// file's bytes are the same before and after; a clean retry updates it.
//
// Fixture: UpdateFixture (an archived file placed by hand with its manifest
// row and journal line). Parallel-safe: sandbox per test, task-local hook.

import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

struct UpdateFaultCase: Sendable, CustomStringConvertible {
    let kind: HashReadFault.Kind
    /// false = the preflight read at the old path; true = the read-back at
    /// the new path, after the rename.
    let afterTheMove: Bool
    var description: String { "\(kind) in the read \(afterTheMove ? "AFTER the move (new path)" : "BEFORE the move (old path)")" }
    static let all: [UpdateFaultCase] = HashReadFault.Kind.allCases.flatMap {
        [UpdateFaultCase(kind: $0, afterTheMove: false), UpdateFaultCase(kind: $0, afterTheMove: true)]
    }
}

@Suite("Hash read fault × Archive Update — refused before the move, rolled back after it")
@MainActor
struct HashReadFaultArchiveUpdateTests {

    private func indexBytes(_ a: UpdateFixture.Archived) -> [Data] {
        [UpdateFixture.data(a.sb.manifestURL), UpdateFixture.data(a.journalURL)]
    }

    @Test("MATRIX: each fault in each of Update's two reads → never 'updated'; the file is at its old path with its old bytes, the index and the record are unchanged; a clean retry updates it",
          .timeLimit(.minutes(2)), arguments: UpdateFaultCase.all)
    func aFaultedReadNeverUpdates(_ c: UpdateFaultCase) async throws {
        let a = try UpdateFixture.make("hrf_\(c.kind)_\(c.afterTheMove ? "after" : "before")")
        defer { a.sb.cleanup() }
        let p = try await UpdateFixture.preview(a)
        let h = try UpdateFixture.hint(1984)
        let to = p.plan(name: p.currentName, hint: h, known: true).toRelPath
        try #require(to != a.relPath, "fixture: the update moves the file")
        let bytesBefore = UpdateFixture.data(URL(fileURLWithPath: a.absPath))
        let indexBefore = indexBytes(a)
        let fixityBefore = a.copy.archiveFixity
        let userDateBefore = a.copy.userDate

        // Both names end in "DadThanksgiving1984-1.mov"; the 1st full read is
        // the preflight at the old path, the 2nd the read-back at the new one.
        let fault = HashReadFault(c.kind, where: { $0.contains("/Archive/") && $0.hasSuffix("DadThanksgiving1984-1.mov") },
                                  atByte: 11_000, onPass: c.afterTheMove ? 2 : 1)
        let r = await fault.run { await a.model.updateArchivedFile(p, name: p.currentName, hint: h, known: true) }
        #expect(fault.firedCount == 1, "\(c): the fault never reached its read (passes \(fault.passCount))")
        print("[hash-matrix] archive-update | \(c) | \(r.kind) | \(r.message)")

        // --- Named, never a success.
        #expect(r.kind == (c.afterTheMove ? .rolledBack : .refused), "\(c): \(r.kind) — \(r.message)")
        let m = r.message
        // GH #504 D1: EIO AND a read that ends early are read failures (the
        // latter used to be a digest of the prefix, reported as a mismatch);
        // only a flipped bit is a fingerprint mismatch.
        switch (c.kind, c.afterTheMove) {
        case (.bitFlip, false): #expect(m.contains("does not match its manifest fingerprint") && m.contains(a.relPath), "\(m)")
        case (.bitFlip, true): #expect(m.contains("does not match its manifest fingerprint after the move") && m.contains(to), "\(m)")
        case (_, false): #expect(m.contains("could not be read") && m.contains(a.relPath), "\(m)")
        case (_, true): #expect(m.contains("could not be read back") && m.contains(to), "\(m)")
        }
        switch c.kind {
        case .eio:
            // Was P3: the reason inside is the engine's read failure, not "write failed".
            #expect(!m.lowercased().contains("write failed"), "\(m)")
            #expect(m.contains("could not be read in full (read errno \(EIO))"), "\(m)")
        case .shortRead:
            #expect(m.contains("could not be read in full (11000 of \(bytesBefore.count) bytes)"), "\(m)")
        case .bitFlip: break
        }

        // --- Where the media is: the old path, the old bytes; nothing at the new one.
        #expect(UpdateFixture.data(URL(fileURLWithPath: a.absPath)) == bytesBefore, "\(c): the file is not intact at its old path")
        #expect(!FileManager.default.fileExists(atPath: a.url(to).path), "\(c): something is at the new path")
        #expect(indexBytes(a) == indexBefore, "\(c): an index file changed")
        #expect(a.copy.fullPath == a.absPath && a.copy.archiveFixity == fixityBefore && a.copy.userDate == userDateBefore,
                "\(c): the record changed")

        // --- A clean retry updates it (nothing left behind blocks it).
        let p2 = try await UpdateFixture.preview(a)
        let again = await a.model.updateArchivedFile(p2, name: p2.currentName, hint: h, known: true)
        #expect(again.kind == .updated || again.kind == .updatedWithWarnings, "\(c): retry \(again.kind) — \(again.message)")
        #expect(UpdateFixture.data(a.url(to)) == bytesBefore)
    }
}
