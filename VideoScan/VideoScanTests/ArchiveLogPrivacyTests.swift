// ArchiveLogPrivacyTests.swift
// Codex review 2026-10-02, finding 7 (P2): persistent logs carried raw media
// paths and identifying filenames from overlap refusals, designation
// audits, re-adoption, duplicate refusals and digest-mismatch errors.
//
// Persistent = catalog.log (model.log), videoscan.log (appLog), the catalog
// write-error journal, and the unified log (os.Logger, public
// interpolation). Those carry operation ids, counts, digest prefixes and
// refusal codes only; the identifying detail stays in the UI (the outcome
// row, the sheet, the returned refusal message).
//
// SENTINEL: every folder / filename the triggers touch contains
// PRIVATE_SUBJECT_SENTINEL. No captured persistent line may contain it,
// and each test also proves the line it guards WAS written (an absent line
// would pass a privacy test vacuously) and that the UI still has the
// detail. Synthetic names only; sandbox only.
//
// Serialized: the global appLog is swapped for an in-memory sink.

import Foundation
import OSLog
import Testing
import VideoScanCore
@testable import VideoScan

let privateSentinel = "PRIVATE_SUBJECT_SENTINEL"

/// Everything a trigger writes to persistent logs between `init` and `finish()`.
@MainActor
final class PersistentLogCapture {
    let model: VideoScanModel
    let sink = InMemoryLogSink()
    private let previous: LogSink
    private let catalogLogOffset: Int
    private let since: Date
    private let extraFiles: [URL]
    private let beginMarker = "privacy-capture-begin-\(UUID().uuidString)"

    init(model: VideoScanModel, extraFiles: [URL] = []) {
        self.model = model
        self.extraFiles = extraFiles
        previous = appLog
        since = Date()
        let begin = beginMarker
        Self.markerLog.notice("\(begin, privacy: .public)")
        catalogLogOffset = (try? Data(contentsOf: model.dashboard.catalogLog.url))?.count ?? 0
        appLog = sink
    }

    /// Restores appLog and returns every captured persistent line.
    func finish() throws -> [String] {
        appLog = previous
        var out: [String] = []
        let catalogLog = (try? Data(contentsOf: model.dashboard.catalogLog.url)) ?? Data()
        out += (String(bytes: catalogLog.dropFirst(catalogLogOffset), encoding: .utf8) ?? "")
            .split(separator: "\n").map { "catalog.log: " + $0 }
        out += sink.lines.map { "appLog: " + $0 }
        for url in extraFiles {
            let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            out += text.split(separator: "\n").map { "\(url.lastPathComponent): " + $0 }
        }
        out += try Self.unifiedLog(begin: beginMarker, since: since)
        return out
    }

    /// This process's own unified-log messages (app subsystem, or NSLog
    /// from the app image) logged between the BEGIN marker (`init`) and an
    /// END marker logged now — read from logd with `/usr/bin/log show`,
    /// re-read until both markers are visible (delivery lags a little).
    /// The in-process OSLogStore view proved unreliable for this (it
    /// skipped entries of the same instant and sometimes never showed the
    /// marker), so it is not used. Throws rather than pass on a partial read.
    static func unifiedLog(begin: String, since: Date) throws -> [String] {
        let end = "privacy-capture-end-\(UUID().uuidString)"
        markerLog.notice("\(end, privacy: .public)")
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let startArg = fmt.string(from: since.addingTimeInterval(-5))
        let pid = ProcessInfo.processInfo.processIdentifier
        let deadline = Date().addingTimeInterval(60)
        while true {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
            p.arguments = ["show", "--start", startArg, "--style", "ndjson", "--info", "--debug",
                           "--predicate", "processID == \(pid)"]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            var out: [String] = []
            var inside = false, sawBegin = false, sawEnd = false
            for raw in data.split(separator: 0x0A) {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(raw)) as? [String: Any],
                      let message = obj["eventMessage"] as? String else { continue }
                if message == begin { inside = true; sawBegin = true; continue }
                if message == end { sawEnd = true; break }
                guard inside else { continue }
                let subsystem = obj["subsystem"] as? String ?? ""
                let image = obj["senderImagePath"] as? String ?? ""
                if subsystem.hasPrefix("Rick-Breen") || (subsystem.isEmpty && image.contains("VideoScan")) {
                    out.append("oslog[\(subsystem)/\(obj["category"] as? String ?? "")]: " + message)
                }
            }
            if sawBegin && sawEnd { return out }
            guard Date() < deadline else { throw CaptureError.unifiedLogIncomplete }
            Thread.sleep(forTimeInterval: 0.5)
        }
    }

    static let markerLog = Logger(subsystem: "Rick-Breen.VideoScan", category: "test-marker")

    enum CaptureError: Error { case unifiedLogIncomplete }

    static func leaks(_ lines: [String]) -> [String] { lines.filter { $0.contains(privateSentinel) } }
}

@Suite("Codex 2026-10-02 #7 — no media path or identifying filename in persistent logs", .serialized)
@MainActor
struct ArchiveLogPrivacyTests {

    private func scratch(_ tag: String) throws -> URL {
        let u = FileManager.default.temporaryDirectory
            .appendingPathComponent("test_privacy_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    private func model(_ root: URL) -> VideoScanModel {
        let m = VideoScanModel(logDirectory: root.appendingPathComponent("logs", isDirectory: true))
        m.catalogStore = CatalogStore(directory: root.appendingPathComponent("catalog", isDirectory: true))
        m.installDesignationAuditSink()
        return m
    }

    // MARK: Overlap refusal (Migrate, GH #109)

    @Test("Migrate overlap refusals: the code and the reason are logged, the folders are not")
    func overlapRefusal() throws {
        let root = try scratch("overlap")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = model(root)
        let src = root.appendingPathComponent("\(privateSentinel)_Source", isDirectory: true)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let loop = root.appendingPathComponent("\(privateSentinel)_loop")
        try FileManager.default.createSymbolicLink(atPath: loop.path, withDestinationPath: loop.path)

        let cap = PersistentLogCapture(model: m)
        let identical = m.refuseOverlappingMigrate(source: src.path, destination: src, when: "before queuing")
        let unresolvable = m.refuseOverlappingMigrate(source: src.path, destination: loop, when: "at start")
        let lines = try cap.finish()

        #expect(identical != nil && unresolvable != nil)
        #expect(unresolvable?.contains(privateSentinel) == true, "the UI message still names the folder")
        #expect(lines.filter { $0.contains("Migrate refused") }.count >= 4, "logged to catalog.log + appLog: \(lines)")
        #expect(PersistentLogCapture.leaks(lines).isEmpty, "\(PersistentLogCapture.leaks(lines))")
    }

    // MARK: Designation audits (GH #167)

    @Test("designation START / OUTCOME / REFUSED / clear lines and the write journal carry no archive path")
    func designationAudits() throws {
        let root = try scratch("designation")
        defer { try? FileManager.default.removeItem(at: root) }
        let m = model(root)
        let target = root.appendingPathComponent("\(privateSentinel)_ArchiveVol", isDirectory: true).path
        let d = MasterArchiveDesignation(targetPath: target, rootPath: target + "/Test_Family_Archive",
                                         volumeUUID: "TEST-UUID-PRIV", designatedAt: Date(timeIntervalSince1970: 1_786_000_000))
        let journal = CatalogWriteJournal.journalURL(besideCatalogAt: URL(fileURLWithPath: m.catalogStore.fileLocation))

        let cap = PersistentLogCapture(model: m, extraFiles: [journal])
        m.masterArchive = d
        #expect(m.catalogStore.saveNow(records: []))
        m.masterArchive = nil                                   // poisoned: no Clear
        #expect(!m.catalogStore.saveNow(records: []))
        let uiReason = m.catalogStore.lastWriteError?.userFacingDescription ?? ""
        m.masterArchive = d
        m.clearMasterArchive()
        #expect(m.catalogStore.saveNow(records: []))
        let lines = try cap.finish()

        #expect(uiReason.contains(privateSentinel), "the UI reason still names the archive: \(uiReason)")
        for marker in ["START", "OUTCOME durable", "REFUSED", "clear authorized"] {
            #expect(lines.contains { $0.contains(marker) }, "\(marker) line missing: \(lines)")
        }
        #expect(lines.contains { $0.contains("TEST-UUID-PRIV") }, "the volume UUID identifies the archive in the log")
        #expect(lines.contains { $0.contains("catalog-write-errors.jsonl") && $0.contains("designationLoss") })
        #expect(PersistentLogCapture.leaks(lines).isEmpty, "\(PersistentLogCapture.leaks(lines))")
    }

    // MARK: Re-adoption offer (GH #167 recovery)

    @Test("re-adoption discovery and offer log counts, not the volume path")
    func readoption() async throws {
        let root = try scratch("readopt")
        defer { try? FileManager.default.removeItem(at: root) }
        let vols = root.appendingPathComponent("vols", isDirectory: true)
        let idx = vols.appendingPathComponent("\(privateSentinel)_Vol/\(MasterArchiveLayout.rootFolderName)/\(MasterArchiveLayout.indexFolder)",
                                              isDirectory: true)
        try FileManager.default.createDirectory(at: idx, withIntermediateDirectories: true)
        try Data((MasterArchiveLayout.manifestHeader + "\nrow1\n").utf8)
            .write(to: idx.appendingPathComponent(MasterArchiveLayout.manifestFilename))
        let m = model(root)
        m.masterArchive = nil

        let cap = PersistentLogCapture(model: m)
        let found = await m.findMasterArchivesAwaitingReadoption(volumesRoot: vols.path)
        let candidate = try #require(found.first { $0.targetPath.contains(privateSentinel) })
        m.offerReadoptMasterArchive(candidate)
        let lines = try cap.finish()

        #expect(m.pendingMasterArchiveInitOffer?.targetPath.contains(privateSentinel) == true, "the sheet still names it")
        #expect(lines.contains { $0.contains("carries an archive manifest") }, "\(lines)")
        #expect(lines.contains { $0.contains("Re-adopt offered") }, "\(lines)")
        #expect(PersistentLogCapture.leaks(lines).isEmpty, "\(PersistentLogCapture.leaks(lines))")
    }

    // MARK: Promote refusals (duplicate, stored-digest mismatch, date, changed under the copy)

    @Test("Promote refusals log a code, an operation id and digest prefixes — never the file or folder names")
    func promoteRefusals() async throws {
        let (sb, _) = try PromoteIntegrityHarness.setup("privacy")
        defer { sb.cleanup() }
        let m = VideoScanModel(logDirectory: sb.root.appendingPathComponent("logs", isDirectory: true))
        m.catalogStore = CatalogStore(directory: sb.root.appendingPathComponent("catalog2", isDirectory: true))
        m.mediaLedger = MediaLedger(directory: sb.root.appendingPathComponent("ledger2", isDirectory: true))
        try MasterArchiveTestSupport.initialize(m, in: sb)
        typealias H = PromoteIntegrityHarness

        // A lands first (outside the capture) — its archived name carries the sentinel.
        let a = try H.source(sb, m, name: "test_\(privateSentinel)_a.mov", seed: 71, subfolder: "\(privateSentinel)_cardA")
        _ = try await H.run(m, ids: [a.id])
        let relA = try #require(MasterArchiveTestSupport.archivedFiles(sb).first)

        // B: a twin of A (duplicate). C: a lying stored fixity. E: a date contradiction.
        let b = try H.twin(of: a, sb, m, name: "test_\(privateSentinel)_b.mov", subfolder: "\(privateSentinel)_cardB")
        let c = try H.source(sb, m, name: "test_\(privateSentinel)_c.mov", seed: 72, subfolder: "\(privateSentinel)_cardC")
        let stamp = try #require(FileIdentityStamp.capture(path: c.fullPath))
        c.contentFixity = ContentFixity(digest: String(repeating: "e", count: 64), byteCount: c.sizeBytes, stamp: stamp)
        let e = try H.source(sb, m, name: "test_\(privateSentinel)_e.mov", seed: 73, subfolder: "\(privateSentinel)_cardE")
        e.userDate = "1990"; e.userDateConfidence = UserDateConfidence.known.rawValue
        // D: changes under the copy. Neutral NAME (its ordinary copy-BEGIN line
        // names the file and is not a refusal); the FOLDER carries the sentinel,
        // which the engine's error used to propagate.
        let d = try H.source(sb, m, name: "test_d.mov", seed: 74, bytes: 64_000, subfolder: "\(privateSentinel)_cardD")

        let cap = PersistentLogCapture(model: m)
        let job1 = try await H.run(m, ids: [b.id, c.id, e.id]) {
            $0.archiveDateOverrides[e.id] = .decade(startYear: 1940); $0.archiveDateSources[e.id] = .typed
        }
        let job2 = try H.job(m, ids: [d.id])
        job2.testHookAfterSourceProof = { rec in
            _ = try? MasterArchiveTestSupport.writeBlob(at: URL(fileURLWithPath: rec.fullPath), bytes: 64_000, seed: 98)
        }
        job2.start(); await job2.task?.value; await job2.completionTask?.value
        let lines = try cap.finish()

        // The UI keeps the detail.
        #expect(H.outcome(job1, b.id)?.detail.contains(relA) == true, "\(job1.outcomes)")
        #expect(H.outcome(job1, c.id)?.kind == .failed && H.outcome(job1, e.id)?.kind == .failed, "\(job1.outcomes)")
        #expect(H.outcome(job2, d.id)?.kind == .failed, "\(job2.outcomes)")
        // Each refusal WAS logged, with its code.
        for code in ["duplicate", "stored-digest-mismatch", "date-agreement", "changed-during-copy"] {
            #expect(lines.contains { $0.contains("REFUSED") && $0.contains(code) } || lines.contains { $0.contains("refused") && $0.contains(code) },
                    "\(code) not logged: \(lines)")
        }
        #expect(PersistentLogCapture.leaks(lines).isEmpty, "\(PersistentLogCapture.leaks(lines))")
    }
}
