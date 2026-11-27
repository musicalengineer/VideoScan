// CatalogRescueBasis.swift
// GH #520 (rest of #356; DECISIONS 2026-11-27 (3)). One sentence: a quit
// rescue copy also records what catalog.sqlite held for each rescued record
// when the copy was written, so Apply… can prove, record by record, that the
// catalog has not changed it since.
//
// What it holds (the rescue copy's header, `rescueBasis`, beside
// `generation`):
//   * `generation` — the generation the rows were read at. Read in ONE
//     snapshot, and only when it equals the copy's base generation (the
//     session's last commit): a store another writer moved since is not the
//     base the changes were made on, so the basis is "unknown".
//   * `rows` — file id → `sha256:<hex>` of the stored row (below), or
//     `absent` (no `files` row: a record the catalog never took, or one
//     still held in `pending_rows`).
//   * `unknown` — why there is no basis (unreadable, another writer, did not
//     finish in time). Apply then lists every record as not applied.
//
// The digest: the stored row (`CatalogLiveReading.storedRow`, the load's own
// per-row read) → `VideoRecord(loaded:)` → `VideoRecordDTO` → JSONEncoder
// with sorted keys and full-precision dates → SHA-256. The same function at
// quit and at Apply, on rows read the same way, so equal digests mean the
// catalog holds what it held. `CatalogChangeDetector`'s fingerprints cannot
// do this: `Hasher` is seeded per process (never compared across launches).
// A digest that differs for any other reason (a newer VideoScan maps a field
// differently) only lists a record as not applied — the safe side.
//
// Memory: one stored row and its record at a time, plus one id → 71-byte
// string per rescued record (the delta only, GH #356). Time: one indexed
// row read + one encode per rescued record (~0.1–1 ms each).
//
// (For Rick: a per-row checksum taken at the moment of the dump, compared
// with the same checksum of the row at merge time — optimistic concurrency
// per record, without a schema change.)

import CryptoKit
import Foundation
import VideoScanCore

/// What catalog.sqlite held for each rescued record when the copy was written.
struct CatalogRescueBasis: Codable, Sendable, Equatable {
    /// The generation the rows were read at (= the copy's base); nil when unknown.
    var generation: Int?
    /// File id (UUID string) → `sha256:<hex>` or `absent`.
    var rows: [String: String] = [:]
    /// Why there is no basis; nil when `rows` holds one per rescued record.
    var unknown: String?

    nonisolated static let absent = "absent"

    /// How long the quit may spend reading the basis before it writes the
    /// copy without one (the copy matters more than the basis).
    nonisolated static let quitBound: TimeInterval = 5

    static func missing(_ why: String) -> CatalogRescueBasis { CatalogRescueBasis(generation: nil, rows: [:], unknown: why) }

    // MARK: - The digest

    /// `sha256:<hex>` of what `row` loads as; nil when the row no longer
    /// becomes a record (a stored value that does not decode).
    nonisolated static func digest(_ row: CatalogLoadedRow) -> String? {
        guard let record = try? VideoRecord(loaded: row) else { return nil }
        // The load leaves the pair link pending; the DTO reads `pairedWith`.
        // An id-only stub, as the commit body does (CatalogCommitBody).
        if let partner = record.pendingPairedWithID { record.pairedWith = VideoRecord(id: partner) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .deferredToDate          // full precision, not ISO seconds
        guard let data = try? encoder.encode(VideoRecordDTO(record)) else { return nil }
        return "sha256:" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// The stored digest of each id, in one read snapshot. A row that no
    /// longer becomes a record maps to nil (never equal to anything).
    nonisolated static func digests(_ ids: [UUID], in reader: any CatalogLiveReading) throws -> [String: String?] {
        var out: [String: String?] = [:]
        for id in ids {
            let key = id.uuidString
            guard let row = try reader.storedRow(id: key) else { out[key] = .some(absent); continue }
            out[key] = .some(digest(row))
        }
        return out
    }

    // MARK: - At quit

    /// The basis for `ids` read from `repository`, only if its committed
    /// generation is still `generation` (the copy's base). Never throws:
    /// every failure is an `unknown` basis with the words.
    nonisolated static func read(_ ids: [UUID], expecting generation: Int,
                                 from repository: any CatalogRepository) async -> CatalogRescueBasis {
        do {
            let read: (Int, [String: String?]) = try await repository.read { reader in
                (reader.generation, try digests(ids, in: reader))
            }
            guard read.0 == generation else {
                return .missing("catalog.sqlite is at generation \(read.0), not the \(generation) the changes were based on")
            }
            var rows: [String: String] = [:]
            for (key, digest) in read.1 {
                guard let digest else { return .missing("the stored record \(key) could not be read back as a record") }
                rows[key] = digest
            }
            return CatalogRescueBasis(generation: generation, rows: rows, unknown: nil)
        } catch {
            return .missing("catalog.sqlite could not be read: \(error)")
        }
    }

    /// `read`, awaited and BOUNDED (the quit before it is approved).
    nonisolated static func read(_ ids: [UUID], expecting generation: Int, from repository: any CatalogRepository,
                                 within seconds: TimeInterval) async -> CatalogRescueBasis {
        let late = CatalogRescueBasis.missing("reading catalog.sqlite did not finish within \(seconds.quitWords) s")
        return await OnceResume<CatalogRescueBasis>.race(within: seconds, timeout: late) { once in
            Task.detached { once.resume(await read(ids, expecting: generation, from: repository)) }
        }
    }

    /// `read`, for applicationWillTerminate (synchronous; the main thread
    /// waits at most `seconds`). The read runs on the cooperative pool and
    /// never touches the main actor, so blocking for it cannot deadlock.
    nonisolated static func readBlocking(_ ids: [UUID], expecting generation: Int, from repository: any CatalogRepository,
                                         within seconds: TimeInterval) -> CatalogRescueBasis {
        let once = BasisBox()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            once.value = await read(ids, expecting: generation, from: repository)
            done.signal()
        }
        guard done.wait(timeout: .now() + max(0, seconds)) == .success, let basis = once.value else {
            return .missing("reading catalog.sqlite did not finish within \(seconds.quitWords) s")
        }
        return basis
    }

    /// One line for the quit's sink.
    var quitWords: String {
        if let unknown { return "no record of what catalog.sqlite held for them (\(unknown)) — Apply will leave every one as it is" }
        return "what catalog.sqlite held for each at generation \(generation.map(String.init) ?? "?") is recorded, so Apply can tell which the catalog changed since"
    }

    private final class BasisBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: CatalogRescueBasis?
        var value: CatalogRescueBasis? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }
}
