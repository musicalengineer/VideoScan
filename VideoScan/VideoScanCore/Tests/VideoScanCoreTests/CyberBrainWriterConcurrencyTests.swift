import Foundation
import Testing
@testable import VideoScanCore

// Codex review #18 finding 1 (GH #230, 2026-10-01): `CyberBrainWriter.record`
// did load → append → save with no synchronization. The "I found a record"
// filer (background task) and the Research pane's Tell Hallie (main actor)
// could each load the same archive; the last rename erased the other's
// passage although BOTH callers got a receipt and marked the finding told.
//
// The fix serializes every durable read-modify-write per root URL, in
// process (two app processes are out of scope). This pins it: many writers
// at once, and every successful receipt must resolve to ITS passage in the
// final archive. Synthetic names only.

private final class Receipts: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [(text: String, receipt: CyberBrainWriter.Receipt)] = []
    private var errors: [String] = []
    func add(_ text: String, _ receipt: CyberBrainWriter.Receipt) { lock.withLock { stored.append((text, receipt)) } }
    func fail(_ error: Error) { lock.withLock { errors.append(String(describing: error)) } }
    var all: [(text: String, receipt: CyberBrainWriter.Receipt)] { lock.withLock { stored } }
    var failures: [String] { lock.withLock { errors } }
}

@Suite("CyberBrain writer — concurrent writers")
struct CyberBrainWriterConcurrencyTests {

    private let told = Date(timeIntervalSince1970: 1_790_000_000)

    private func temporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cyberbrain-concurrency-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// Every item in the archive, by id.
    private func items(_ archive: CyberBrainArchive) -> [String: CyberBrainItem] {
        var out: [String: CyberBrainItem] = [:]
        for person in archive.people {
            for item in person.biographyPassages + person.anecdotes + person.lifeEvents + person.notes {
                out[item.id] = item
            }
        }
        return out
    }

    @Test func everyReceiptFromConcurrentWritersResolvesToItsPassage() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        // A non-empty archive first, so every writer loads the same file.
        _ = try CyberBrainWriter.record(
            .init(subjectName: "Synthetic Ancestor", speakerName: "Tester",
                  text: "Seed passage.", date: told), rootURL: root)

        let writers = 24
        let receipts = Receipts()
        // Two writer kinds share the archive, as in the app: testimony (the
        // filer and Tell Hallie) and photo captions (Hallie's conversation).
        // `concurrentPerform` ≈ a parallel for over a thread pool.
        DispatchQueue.concurrentPerform(iterations: writers) { i in
            let text = "Synthetic passage number \(i)."
            do {
                if i % 4 == 3 {
                    let caption = CyberBrainWriter.PhotoCaption(
                        subjects: [.init(name: "Synthetic Ancestor")], speakerName: "Tester",
                        text: text, photoPath: "/synthetic/People/Synthetic_Ancestor/photo-\(i).jpg", date: told)
                    receipts.add(text, try CyberBrainWriter.record(caption: caption, rootURL: root))
                } else {
                    let testimony = CyberBrainWriter.Testimony(
                        subjectName: "Synthetic Ancestor", speakerName: "Tester", text: text, date: told)
                    receipts.add(text, try CyberBrainWriter.record(testimony, rootURL: root))
                }
            } catch {
                receipts.fail(error)
            }
        }

        #expect(receipts.failures.isEmpty, "every writer should succeed: \(receipts.failures)")
        let final = items(try CyberBrainLoader(rootURL: root).load())
        var lost: [String] = []
        for (text, receipt) in receipts.all where final[receipt.itemID]?.text != text {
            lost.append("\(receipt.itemID) → \(final[receipt.itemID]?.text ?? "missing") (wanted \(text))")
        }
        #expect(lost.isEmpty, "a successful receipt must resolve to its own passage: \(lost)")
        #expect(final.count == receipts.all.count + 1, "seed + one item per receipt, no more, no fewer")
        #expect(Set(receipts.all.map(\.receipt.itemID)).count == receipts.all.count, "no two receipts share an item id")
    }

    /// The lock is keyed by the resolved root path, so two spellings of the
    /// same directory (a trailing slash, a `..` hop) are one lock, and two
    /// different roots never wait on each other.
    @Test func spellingsOfOneRootShareALockAndDifferentRootsDoNot() throws {
        let root = try temporaryRoot()
        let other = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let hop = root.appendingPathComponent("sub", isDirectory: true).appendingPathComponent("..", isDirectory: true)
        #expect(CyberBrainWriter.rootLockKey(root) == CyberBrainWriter.rootLockKey(hop))
        #expect(CyberBrainWriter.rootLockKey(root) == CyberBrainWriter.rootLockKey(URL(fileURLWithPath: root.path + "/")))
        #expect(CyberBrainWriter.rootLockKey(root) != CyberBrainWriter.rootLockKey(other))
    }
}
