// MasterArchiveDesignationGuardTests.swift
// GH #167 defence in depth: a LIVE catalog save may change the Master
// Archive designation from set to unset only right after the user cleared
// it (Clear Master Archive). Any other null in the store's slot — whatever
// produced it — is refused before a byte is written, logged once
// (START / OUTCOME / REFUSED through the audit sink + the write journal),
// and catalog.json keeps the designation.
//
// Plus the recovery: an archive tree that carries its manifest while the
// catalog has no designation is OFFERED for re-adoption, never adopted.
//
// Five dimensions: logic (below), scale (100k-record refusal budget),
// isolation (scratch CatalogStore(directory:), scratch "volumes" root —
// never App Support or /Volumes; a poisoned slot), sensor (source scan
// pinning the one session load()).

import Foundation
import Testing
@testable import VideoScan

@MainActor
private func scratch(_ tag: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("test_167_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
}

private func designation(under dir: URL, uuid: String = "TEST-UUID-167") -> MasterArchiveDesignation {
    let target = dir.appendingPathComponent("TestArchiveVol", isDirectory: true).path
    return MasterArchiveDesignation(targetPath: target,
                                    rootPath: target + "/Breen_Family_Archive",
                                    volumeUUID: uuid,
                                    designatedAt: Date(timeIntervalSince1970: 1_786_000_000))
}

@MainActor
private func reread(_ dir: URL) -> MasterArchiveDesignation? {
    let s = CatalogStore(directory: dir)
    _ = s.load()
    return s.masterArchive
}

@MainActor
private func journalLines(_ store: CatalogStore) -> [String] {
    let url = CatalogWriteJournal.journalURL(besideCatalogAt: URL(fileURLWithPath: store.fileLocation))
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(separator: "\n").map(String.init)
}

// MARK: - Store guard

@Suite("GH #167 — a save never drops a designation nobody cleared", .serialized)
@MainActor
struct MasterArchiveDesignationGuardTests {

    @Test("set → unset without Clear is REFUSED by saveNow; catalog.json is byte-identical")
    func refusedWithoutClear() throws {
        let dir = scratch("guard")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let d = designation(under: dir)
        store.masterArchive = d
        #expect(store.saveNow(records: []))
        let before = try Data(contentsOf: URL(fileURLWithPath: store.fileLocation))

        store.masterArchive = nil                      // the poisoned slot
        #expect(store.saveNow(records: []) == false)
        #expect(store.lastWriteError == .designationLossRefused(targetPath: d.targetPath))
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.fileLocation)) == before,
                "a refusal writes zero bytes")
        #expect(reread(dir) == d)
    }

    @Test("the async and acknowledged save paths refuse the same way")
    func refusedOnEveryLivePath() async throws {
        let dir = scratch("paths")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let d = designation(under: dir)
        store.masterArchive = d
        #expect(store.saveNow(records: []))
        store.masterArchive = nil
        store.saveAsync(records: [])
        #expect(await store.saveAcknowledged(records: []) == false)
        try await Task.sleep(nanoseconds: 300_000_000)  // any async completion has run
        #expect(reread(dir) == d)
    }

    @Test("an authorized Clear lands, and the authorization is consumed")
    func authorizedClearLands() throws {
        let dir = scratch("clear")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let d = designation(under: dir)
        store.masterArchive = d
        #expect(store.saveNow(records: []))

        store.authorizeDesignationClear(reason: "test")
        store.masterArchive = nil
        #expect(store.saveNow(records: []))
        #expect(reread(dir) == nil)
        #expect(store.persistedMasterArchive == nil)
        #expect(store.designationClearAuthorized == false, "consumed by the save that removed it")

        // Designate again, then lose it without a Clear → refused again.
        store.masterArchive = d
        #expect(store.saveNow(records: []))
        store.masterArchive = nil
        #expect(store.saveNow(records: []) == false)
    }

    @Test("setting a designation again cancels a pending Clear")
    func reDesignateCancelsClear() throws {
        let dir = scratch("cancel")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let d = designation(under: dir)
        store.masterArchive = d
        #expect(store.saveNow(records: []))
        store.authorizeDesignationClear(reason: "test")
        store.masterArchive = designation(under: dir, uuid: "OTHER")
        store.masterArchive = nil
        #expect(store.saveNow(records: []) == false)
    }

    @Test("START + OUTCOME on a change, REFUSED once (journal + audit), not once per debounce")
    func auditLines() throws {
        let dir = scratch("audit")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        var lines: [String] = []
        store.designationAudit = { lines.append($0) }
        let d = designation(under: dir)
        store.masterArchive = d
        #expect(store.saveNow(records: []))
        // Identified by volume UUID — never the archive's path (codex
        // 2026-10-02 #7: these lines reach catalog.log / videoscan.log).
        let uuid = try #require(d.volumeUUID)
        #expect(lines.contains { $0.contains("START") && $0.contains(uuid) })
        #expect(lines.contains { $0.contains("OUTCOME durable") && $0.contains(uuid) })
        #expect(!lines.contains { $0.contains(d.targetPath) || $0.contains(d.rootPath) }, "\(lines)")

        lines.removeAll()
        store.masterArchive = nil
        for _ in 0..<3 { #expect(store.saveNow(records: []) == false) }
        #expect(lines.filter { $0.contains("REFUSED") }.count == 1)
        #expect(!lines.contains { $0.contains(d.targetPath) }, "\(lines)")
        #expect(journalLines(store).filter { $0.contains("designationLoss") }.count == 1)
    }

    @Test("an older async completion landing after a newer save cannot resurrect the designation")
    func outOfOrderCompletion() async throws {
        let dir = scratch("order")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let d = designation(under: dir)
        store.masterArchive = d
        #expect(store.saveNow(records: []))

        store.testWriteDelay = 0.2
        store.saveAsync(records: [])                   // carries d, lands late
        store.authorizeDesignationClear(reason: "test")
        store.masterArchive = nil
        #expect(store.saveNow(records: []))            // newer: carries nil
        try await Task.sleep(nanoseconds: 600_000_000) // the async completion runs now
        #expect(store.persistedMasterArchive == nil)
        store.testWriteDelay = 0
        #expect(store.saveNow(records: []), "no false refusal after the cleared write")
        #expect(reread(dir) == nil)
    }

    // Codex 2026-10-02 #2 (P1): the FIRST designation rides an async write
    // whose completion has not run, so `persistedMasterArchive` is still
    // nil; a nil saveNow without Clear passed the guard, queued behind the
    // designated write and overwrote it. The baseline must include
    // accepted-but-pending writes.
    @Test("a first designation still in flight cannot be lost to a nil save without Clear")
    func pendingFirstDesignationCannotBeLost() async throws {
        let dir = scratch("pending")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let d = designation(under: dir)

        store.testWriteDelay = 0.2
        store.masterArchive = d
        store.saveAsync(records: [])
        store.masterArchive = nil // no Clear

        #expect(!store.saveNow(records: []))
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(reread(dir) == d)
    }

    @Test("a first designation in flight, THEN an explicit Clear: the clear still lands (no false refusal)")
    func pendingFirstDesignationThenClearLands() async throws {
        let dir = scratch("pendingclear")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let d = designation(under: dir)

        store.testWriteDelay = 0.2
        store.masterArchive = d
        store.saveAsync(records: [])
        store.authorizeDesignationClear(reason: "test")
        store.masterArchive = nil
        #expect(store.saveNow(records: []), "Clear is the one authorized removal")
        try await Task.sleep(nanoseconds: 600_000_000)
        store.testWriteDelay = 0
        #expect(reread(dir) == nil)
        #expect(store.saveNow(records: []), "nothing pending, nothing designated: saves proceed")
    }

    // MARK: Model path (the Clear button and a poisoned model value)

    @Test("model: Clear Master Archive persists the removal; a bare nil does not")
    func modelClearVersusPoison() throws {
        let dir = scratch("model")
        defer { try? FileManager.default.removeItem(at: dir) }
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: dir)
        var lines: [String] = []
        m.catalogStore.designationAudit = { lines.append($0) }
        let d = designation(under: dir)

        m.masterArchive = d
        #expect(m.catalogStore.saveNow(records: []))
        m.masterArchive = nil                          // poisoned: nobody pressed Clear
        #expect(m.catalogStore.saveNow(records: []) == false)
        #expect(reread(dir) == d)

        m.masterArchive = d
        m.clearMasterArchive()
        #expect(m.catalogStore.saveNow(records: []))
        #expect(reread(dir) == nil)
        #expect(lines.contains { $0.contains("clear authorized") })
    }

    // MARK: Scale

    @Test("100k records: the refusal costs no encode (< 0.5 s) and the 100k-record file survives")
    func scaleRefusal() throws {
        let dir = scratch("scale")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = CatalogStore(directory: dir)
        let records: [VideoRecord] = (0..<100_000).map { i in
            let r = VideoRecord()
            r.filename = "clip_\(i).mov"
            r.fullPath = "/Volumes/TestScaleVol/clips/clip_\(i).mov"
            return r
        }
        let d = designation(under: dir)
        store.masterArchive = d
        #expect(store.saveNow(records: records))
        let size = try FileManager.default.attributesOfItem(atPath: store.fileLocation)[.size] as? Int

        store.masterArchive = nil
        let t0 = Date()
        #expect(store.saveNow(records: records) == false)
        let elapsed = Date().timeIntervalSince(t0)
        #expect(elapsed < 0.5, "refusal took \(elapsed) s — it must run before the payload is built")
        #expect(try FileManager.default.attributesOfItem(atPath: store.fileLocation)[.size] as? Int == size)
        let back = CatalogStore(directory: dir)
        #expect(back.load().count == 100_000)
        #expect(back.masterArchive == d)
    }
}

// MARK: - Recovery: re-adopt, never silently

@Suite("GH #167 — an archive found on disk is offered, never adopted silently", .serialized)
@MainActor
struct MasterArchiveReadoptionTests {

    /// root/VolA — full marker; VolB — tree without manifest; VolC —
    /// manifest is a symlink; VolD — Breen_Family_Archive is a symlink;
    /// VolE — manifest is a FIFO (must not block, must not count).
    private func volumes() throws -> URL {
        let fm = FileManager.default
        let root = scratch("vols")
        func tree(_ vol: String) throws -> URL {
            let idx = root.appendingPathComponent(vol).appendingPathComponent("Breen_Family_Archive/00_Index", isDirectory: true)
            try fm.createDirectory(at: idx, withIntermediateDirectories: true)
            return idx
        }
        let a = try tree("VolA")
        try Data((MasterArchiveLayout.manifestHeader + "\nrow1\nrow2\n").utf8)
            .write(to: a.appendingPathComponent(MasterArchiveLayout.manifestFilename))
        _ = try tree("VolB")
        let c = try tree("VolC")
        try fm.createSymbolicLink(at: c.appendingPathComponent(MasterArchiveLayout.manifestFilename),
                                  withDestinationURL: a.appendingPathComponent(MasterArchiveLayout.manifestFilename))
        try fm.createDirectory(at: root.appendingPathComponent("VolD"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: root.appendingPathComponent("VolD/Breen_Family_Archive"),
                                  withDestinationURL: root.appendingPathComponent("VolA/Breen_Family_Archive"))
        let e = try tree("VolE")
        #expect(mkfifo(e.appendingPathComponent(MasterArchiveLayout.manifestFilename).path, 0o600) == 0)
        return root
    }

    @Test("only a real tree with a regular-file manifest is a candidate")
    func candidates() throws {
        let root = try volumes()
        defer { try? FileManager.default.removeItem(at: root) }
        let names = ["VolA", "VolB", "VolC", "VolD", "VolE", "Missing"].map { root.appendingPathComponent($0).path }
        let found = VideoScanModel.findReadoptionCandidates(searchPaths: names)
        #expect(found.map(\.targetPath) == [PathScope.normalize(root.appendingPathComponent("VolA").standardizedFileURL.path)])
        #expect(found.first?.manifestRows == 2)
    }

    @Test("model: offers the archive and changes nothing until Rick confirms")
    func modelOffersOnly() async throws {
        let root = try volumes()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogDir = scratch("readopt_catalog")
        defer { try? FileManager.default.removeItem(at: catalogDir) }
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: catalogDir)
        #expect(m.catalogStore.saveNow(records: []))
        m.masterArchive = nil

        let found = await m.findMasterArchivesAwaitingReadoption(volumesRoot: root.path)
        #expect(found.count == 1)
        #expect(m.masterArchive == nil, "discovery never designates")
        let candidate = try #require(found.first)
        m.offerReadoptMasterArchive(candidate)
        #expect(m.masterArchive == nil, "the offer only opens the confirm sheet")
        #expect(m.pendingMasterArchiveInitOffer?.targetPath == candidate.targetPath)
        #expect(reread(catalogDir) == nil)
    }

    @Test("with a designation there is nothing to offer")
    func designatedOffersNothing() async throws {
        let root = try volumes()
        defer { try? FileManager.default.removeItem(at: root) }
        let catalogDir = scratch("readopt_designated")
        defer { try? FileManager.default.removeItem(at: catalogDir) }
        let m = VideoScanModel()
        m.catalogStore = CatalogStore(directory: catalogDir)
        m.masterArchive = designation(under: catalogDir)
        #expect(await m.findMasterArchivesAwaitingReadoption(volumesRoot: root.path).isEmpty)
    }
}

// MARK: - Sensor

@Suite("GH #167 — sensor: the catalog session is loaded exactly once")
struct CatalogSessionLoadSensor {

    /// `CatalogStore.load()` re-baselines the designation slot, the OCC
    /// generation and .prev. The only legitimate caller is
    /// VideoScanModel.init; a read-only query uses
    /// `readRecordsWithoutAdopting()`.
    @Test("no app source other than VideoScanModel.swift calls catalogStore.load() / CatalogStore.shared.load()")
    func singleSessionLoad() throws {
        let pattern = try NSRegularExpression(pattern: #"(CatalogStore\.shared|catalogStore)\.load\(\)"#)
        var hits: [String] = []
        for (relative, url) in SourceTree.appSources {
            let text = try String(contentsOf: url, encoding: .utf8)
            let n = pattern.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
            if n > 0 { hits.append("\(relative)×\(n)") }
        }
        #expect(!SourceTree.appSources.isEmpty, "the sensor must read something")
        #expect(hits == ["Model/VideoScanModel.swift×1"], "session load() callers: \(hits)")
    }

    @Test("the Person Finder skip set reads without adopting")
    func personFinderUsesReadOnlyPath() throws {
        let text = try SourceTree.appSource(named: "PersonFinderCatalogFilter.swift")
        #expect(text.contains("readRecordsWithoutAdopting()"))
        #expect(!text.contains(".load()"))
    }
}
