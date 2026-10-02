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

private final class Words: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private var errors: [String] = []
    func add(_ word: String) { lock.withLock { stored.append(word) } }
    func fail(_ error: Error) { lock.withLock { errors.append(String(describing: error)) } }
    var all: [String] { lock.withLock { stored } }
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

    // MARK: Coverage gaps named by codex review 2026-10-02

    private struct Boom: Error {}

    private func testimony(_ text: String) -> CyberBrainWriter.Testimony {
        .init(subjectName: "Synthetic Ancestor", speakerName: "Tester", text: text, date: told)
    }

    /// Run `work` on another thread and wait at most `seconds`. A lock that
    /// is never released strands that thread, but the TEST still ends —
    /// with a failure — instead of hanging the suite. (C++: std::async +
    /// future.wait_for.)
    private func completes(within seconds: Double, _ work: @escaping @Sendable () -> Void) -> Bool {
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            work()
            done.signal()
        }
        return done.wait(timeout: .now() + seconds) == .success
    }

    /// A writer that throws INSIDE the root lock must release it: the next
    /// writer on that root proceeds. Both the raw lock and a real durable
    /// writer that fails after taking it (no such person) are checked.
    @Test func aWriterThatThrowsReleasesTheRootLock() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(throws: Boom.self) {
            try CyberBrainWriter.withRootLock(root) { throw Boom() }
        }
        #expect(throws: (any Error).self, "no archive yet, so no such person: refused inside the lock") {
            try CyberBrainWriter.setPronunciation(personID: "person.none", token: "Synthetic",
                                                  saidAs: "SIN-thet-ik", rootURL: root)
        }
        let receipts = Receipts()
        let t = testimony("Written after two failed writers.")
        let finished = completes(within: 10) {
            do { receipts.add(t.text, try CyberBrainWriter.record(t, rootURL: root)) } catch { receipts.fail(error) }
        }
        #expect(finished, "the lock was released by the throwing writers")
        #expect(receipts.failures.isEmpty, "\(receipts.failures)")
        #expect(receipts.all.count == 1)
    }

    /// Two roots make progress independently: while one root's lock is
    /// HELD, a writer on the other root completes; a writer on the held
    /// root waits until it is released, then completes too.
    @Test func aHeldRootDoesNotBlockAnotherRoot() throws {
        let held = try temporaryRoot()
        let free = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: held)
            try? FileManager.default.removeItem(at: free)
        }
        let holding = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let holderDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            CyberBrainWriter.withRootLock(held) {
                holding.signal()
                release.wait()
            }
            holderDone.signal()
        }
        try #require(holding.wait(timeout: .now() + 10) == .success)

        let receipts = Receipts()
        let onFree = testimony("Written to the free root.")
        #expect(completes(within: 10) {
            do { receipts.add(onFree.text, try CyberBrainWriter.record(onFree, rootURL: free)) } catch { receipts.fail(error) }
        }, "the free root is not blocked by the held one")

        let onHeld = testimony("Written to the held root.")
        let heldWriter = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do { receipts.add(onHeld.text, try CyberBrainWriter.record(onHeld, rootURL: held)) } catch { receipts.fail(error) }
            heldWriter.signal()
        }
        #expect(heldWriter.wait(timeout: .now() + 0.5) == .timedOut, "the held root's writer waits")
        release.signal()
        #expect(heldWriter.wait(timeout: .now() + 10) == .success, "and proceeds once released")
        #expect(holderDone.wait(timeout: .now() + 10) == .success)
        #expect(receipts.failures.isEmpty, "\(receipts.failures)")
        #expect(receipts.all.count == 2)
    }

    /// Bounded deadlock check: two writers, two roots, opposite orders
    /// (A,B,A,B… and B,A,B,A…), many rounds. Must finish within the bound
    /// and every receipt must resolve to its passage on its root.
    @Test func twoWritersOnTwoRootsInOppositeOrdersNeverDeadlock() throws {
        let a = try temporaryRoot()
        let b = try temporaryRoot()
        defer {
            try? FileManager.default.removeItem(at: a)
            try? FileManager.default.removeItem(at: b)
        }
        let rounds = 12
        let onA = Receipts(), onB = Receipts(), told = self.told
        let finished = completes(within: 60) {
            DispatchQueue.concurrentPerform(iterations: 2) { writer in
                for round in 0..<rounds {
                    let toA = (round + writer) % 2 == 0
                    let text = "Synthetic writer \(writer) round \(round)."
                    let t = CyberBrainWriter.Testimony(subjectName: "Synthetic Ancestor", speakerName: "Tester",
                                                       text: text, date: told)
                    let box = toA ? onA : onB
                    do { box.add(text, try CyberBrainWriter.record(t, rootURL: toA ? a : b)) } catch { box.fail(error) }
                }
            }
        }
        #expect(finished, "two writers on two roots finished within the bound (no deadlock)")
        for (root, box) in [(a, onA), (b, onB)] {
            #expect(box.failures.isEmpty, "\(box.failures)")
            let final = items(try CyberBrainLoader(rootURL: root).load())
            #expect(box.all.allSatisfy { final[$0.receipt.itemID]?.text == $0.text })
            #expect(final.count == box.all.count)
        }
        #expect(onA.all.count + onB.all.count == 2 * rounds)
    }

    /// Concurrent pronunciation writers (interleaved with testimony
    /// writers) on one archive: every word set lands, and every testimony
    /// receipt still resolves.
    @Test func concurrentPronunciationWritersLoseNoEntry() throws {
        let root = try temporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let words = ["Aldwin", "Brannock", "Corvell", "Dunmere", "Elsworth", "Fenmarch", "Galloway", "Harrowby"]
        let seed = try CyberBrainWriter.record(
            .init(subjectName: words.joined(separator: " "), speakerName: "Tester",
                  text: "Seed passage.", date: told), rootURL: root)
        let personID = seed.personID
        let said = Words()
        let testified = Receipts()
        let told = self.told
        DispatchQueue.concurrentPerform(iterations: words.count * 2) { i in
            if i % 2 == 0 {
                let word = words[i / 2]
                do {
                    let receipt = try CyberBrainWriter.setPronunciation(
                        personID: personID, token: word, saidAs: "said-\(word.lowercased())", rootURL: root)
                    said.add(receipt.word)
                } catch {
                    said.fail(error)
                }
            } else {
                let text = "Synthetic passage \(i)."
                let t = CyberBrainWriter.Testimony(subjectName: words.joined(separator: " "), speakerName: "Tester",
                                                   text: text, date: told)
                do { testified.add(text, try CyberBrainWriter.record(t, rootURL: root)) } catch { testified.fail(error) }
            }
        }
        #expect(said.failures.isEmpty, "\(said.failures)")
        #expect(Set(said.all) == Set(words), "every writer got a receipt")
        #expect(testified.failures.isEmpty, "\(testified.failures)")
        let archive = try CyberBrainLoader(rootURL: root).load()
        #expect(archive.people.count == 1)
        let table = archive.people.first?.pronunciations ?? [:]
        for word in words {
            #expect(table[word] == "said-\(word.lowercased())", "lost the pronunciation of \(word)")
        }
        let final = items(archive)
        #expect(testified.all.allSatisfy { final[$0.receipt.itemID]?.text == $0.text })
        #expect(final.count == testified.all.count + 1)
    }
}
