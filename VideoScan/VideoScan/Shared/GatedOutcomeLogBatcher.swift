import Foundation

// MARK: - GatedOutcomeLogBatcher (GH #163, secondary)
//
// The scan drain loops (VideoScanModel+ProbeEngine) write one appLog
// "NOT CATALOGED — …" line per gated-out file. Through `PersistentLog.write`
// that is a DateFormatter alloc + FileHandle.write + fsync PER LINE, on the
// main actor, in the middle of a scan — 359k lines on the Projects volume
// (2026-08-18 sample: 22/2181 main-thread samples inside recordGatedOutcome
// → PersistentLog.write while the app was beachballing).
//
// This class keeps the CONTENT and ORDER of those lines byte-identical and
// changes only the write cadence: lines accumulate on the main actor and
// are handed, `flushEvery` at a time, to ONE detached consumer task that
// calls `LogSink.writeBatch` (one fsync per batch on PersistentLog). A
// single consumer over an AsyncStream is what guarantees order — N
// independent `Task.detached { writeBatch(...) }` would race each other.
//
// Lifecycle (one instance per probe group run):
//   append(line)   — main actor, sync, cheap (array append)
//   finish()       — awaits until EVERY appended line has reached the sink.
//                    Called on the normal path AND on cancel/abort so the
//                    trailing "Discovery audit …" / "Cancelled catalog
//                    scan …" lines that finalize writes directly still land
//                    AFTER the last gated line, exactly as before.
//
// C++ analogy: a producer/consumer queue with a std::thread consumer and a
// join() at scope exit — here the "thread" is a detached Task and the queue
// is an AsyncStream<[String]>.
@MainActor
final class GatedOutcomeLogBatcher {

    /// Lines per batch (≈ one fsync per 512 gated files instead of 512).
    static let defaultFlushEvery = 512

    private let flushEvery: Int
    private let sink: LogSink
    private var buffer: [String] = []
    private var finished = false

    private let continuation: AsyncStream<[String]>.Continuation
    private let consumer: Task<Void, Never>

    /// Number of batches handed to the sink so far. Test seam — the sensor
    /// pins that 100k gated lines cost O(100k / flushEvery) writeBatch
    /// calls (≈ fsyncs on PersistentLog), not 100k.
    private(set) var batchesWritten = 0

    /// - Parameter sink: captured ONCE at construction (the scan's `appLog`
    ///   at the moment the probe group starts) so a test that swaps
    ///   `appLog` around the run sees every line in ITS sink.
    init(sink: LogSink, flushEvery: Int = GatedOutcomeLogBatcher.defaultFlushEvery) {
        self.flushEvery = max(1, flushEvery)
        self.sink = sink
        // Unbounded: the producer is the main-actor drain loop; batches are
        // small arrays and the consumer keeps up (one fsync per batch).
        let (stream, cont) = AsyncStream<[String]>.makeStream(bufferingPolicy: .unbounded)
        self.continuation = cont
        // Detached (off the main actor); the ONLY writer to the sink for
        // this batcher, so batches land strictly in yield order.
        self.consumer = Task.detached(priority: .utility) {
            for await batch in stream {
                sink.writeBatch(batch)
            }
        }
    }

    /// Queue one gated-outcome line. Sync, main actor. When the buffer
    /// reaches `flushEvery` the batch is handed to the consumer.
    func append(_ line: String) {
        guard !finished else {
            // Late line after finish() (shouldn't happen — the drain loops
            // finish() only after their last outcome). Never lose it.
            sink.write(line)
            return
        }
        buffer.append(line)
        if buffer.count >= flushEvery { flushBuffer() }
    }

    private func flushBuffer() {
        guard !buffer.isEmpty else { return }
        let batch = buffer
        buffer.removeAll(keepingCapacity: true)
        batchesWritten += 1
        continuation.yield(batch)
    }

    /// Final flush. Hands off whatever is buffered, closes the stream, and
    /// waits for the consumer to have written every batch. Idempotent.
    /// Called from the drain loops on completion, cancel, and abort.
    func finish() async {
        guard !finished else { return }
        finished = true
        flushBuffer()
        continuation.finish()
        await consumer.value
    }
}
