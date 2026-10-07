// GedcomCompiledTree+Binary.swift (VideoScanCore)
import Foundation

extension GedcomCompiledTree {
    // MARK: Byte helpers

    static func le<T: FixedWidthInteger>(_ v: T) -> Data {
        withUnsafeBytes(of: v.littleEndian) { Data($0) }
    }

    struct Writer {
        var body: [UInt8] = []
        var blob: [UInt8] = []
        var offsets: [Int32] = [0]
        private var intern: [String: Int32] = [:]

        mutating func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        mutating func i32(_ v: Int32) { withUnsafeBytes(of: v.littleEndian) { body.append(contentsOf: $0) } }
        mutating func f64(_ v: Double) { withUnsafeBytes(of: v.bitPattern.littleEndian) { body.append(contentsOf: $0) } }
        mutating func ref(_ s: String?) {
            guard let s else { i32(-1); return }
            if let existing = intern[s] { i32(existing); return }
            let id = Int32(offsets.count - 1)
            blob.append(contentsOf: s.utf8)
            offsets.append(Int32(blob.count))
            intern[s] = id
            i32(id)
        }
        mutating func refs(_ list: [String]) { u32(UInt32(list.count)); for s in list { ref(s) } }
        mutating func i32s(_ list: [Int32]) {
            u32(UInt32(list.count))
            list.withUnsafeBufferPointer { body.append(contentsOf: UnsafeRawBufferPointer($0)) }
        }
        mutating func bytes(_ list: [UInt8]) { u32(UInt32(list.count)); body.append(contentsOf: list) }

        /// Codec 5 chunked section:
        ///   u32 count | u32 chunkSize | u32 recordsByteLength |
        ///   records… | u32 byteOffset[chunk] (relative to the first record)
        /// The offsets come AFTER the records (they are known only once the
        /// records are written); the reader jumps over the records by
        /// `recordsByteLength` to find them.
        mutating func chunkedSection(count: Int, _ record: (inout Writer, Int) -> Void) {
            u32(UInt32(count))
            u32(UInt32(GedcomCompiledTree.chunkSize))
            let lengthSlot = body.count
            u32(0)                                   // patched below
            let recordsStart = body.count
            var chunkOffsets: [UInt32] = []
            for i in 0..<count {
                if i % GedcomCompiledTree.chunkSize == 0 { chunkOffsets.append(UInt32(body.count - recordsStart)) }
                record(&self, i)
            }
            let recordsLength = UInt32(body.count - recordsStart)
            withUnsafeBytes(of: recordsLength.littleEndian) { body.replaceSubrange(lengthSlot..<lengthSlot + 4, with: $0) }
            for offset in chunkOffsets { u32(offset) }
        }
    }

    struct Reader {
        let bytes: UnsafeRawBufferPointer
        var cursor = 0
        /// One past the last readable byte (a chunk reader is fenced to
        /// its own chunk so a corrupt offset table cannot read a neighbour).
        var limit: Int
        var strings: [String] = []
        init(bytes: UnsafeRawBufferPointer) { self.bytes = bytes; self.limit = bytes.count }
        var atEnd: Bool { cursor == bytes.count }

        mutating func need(_ n: Int) throws {
            guard n >= 0, cursor + n <= limit else { throw CodecError.truncated }
        }

        /// Read a codec-5 chunked section (see `Writer.chunkedSection`):
        /// the chunks parse concurrently, each fenced to its byte range,
        /// and every chunk must consume EXACTLY its range. Returns the
        /// records in file order.
        ///
        /// `record` is `@Sendable` because it runs on several threads at
        /// once: the compiler now proves each call site captures nothing
        /// shared and mutable (today both capture nothing at all).
        mutating func chunkedSection<T>(_ record: @Sendable (inout Reader) throws -> T) throws -> [T] {
            let count = Int(try u32())
            let size = Int(try u32())
            guard size > 0, size <= 1 << 20 else { throw CodecError.corrupt("chunk size \(size)") }
            let recordsLength = Int(try u32())
            let recordsStart = cursor
            _ = try slice(recordsLength)
            let chunks = (count + size - 1) / size
            var starts: [Int] = []
            starts.reserveCapacity(chunks + 1)
            for _ in 0..<chunks { starts.append(recordsStart + Int(try u32())) }
            starts.append(recordsStart + recordsLength)
            for c in 0..<chunks where !(starts[c] <= starts[c + 1] && starts[c] >= recordsStart) {
                throw CodecError.corrupt("chunk offsets")
            }
            if chunks > 0, starts[0] != recordsStart { throw CodecError.corrupt("chunk offsets") }
            let chunkStarts = starts          // immutable copy for the workers
            // Race-free (strict-concurrency note): every worker COPIES
            // `template` into its own `var r` (a struct copy — the shared
            // parts, `bytes` and `strings`, are only read); worker c writes
            // only slotBuffer[c] / failureBuffer[c] (disjoint slots); and
            // concurrentPerform returns only after all workers finish, so the
            // reads of `slots`/`failures` below happen after every write.
            nonisolated(unsafe) let template = self
            var slots = [[T]](repeating: [], count: chunks)
            var failures = [CodecError?](repeating: nil, count: chunks)
            slots.withUnsafeMutableBufferPointer { slotBufferBinding in
                failures.withUnsafeMutableBufferPointer { failureBufferBinding in
                    nonisolated(unsafe) let slotBuffer = slotBufferBinding
                    nonisolated(unsafe) let failureBuffer = failureBufferBinding
                    DispatchQueue.concurrentPerform(iterations: chunks) { c in
                        var r = template
                        r.cursor = chunkStarts[c]
                        r.limit = chunkStarts[c + 1]
                        let lo = c * size, hi = min(count, lo + size)
                        var out: [T] = []
                        out.reserveCapacity(hi - lo)
                        do {
                            for _ in lo..<hi { out.append(try record(&r)) }
                            guard r.cursor == r.limit else { throw CodecError.corrupt("chunk length") }
                            slotBuffer[c] = out
                        } catch let error as CodecError {
                            failureBuffer[c] = error
                        } catch {
                            failureBuffer[c] = .corrupt("chunk \(c)")
                        }
                    }
                }
            }
            if let failure = failures.compactMap({ $0 }).first { throw failure }
            var all: [T] = []
            all.reserveCapacity(count)
            for slot in slots { all.append(contentsOf: slot) }
            return all
        }
        mutating func u32() throws -> UInt32 {
            try need(4); defer { cursor += 4 }
            return UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: UInt32.self))
        }
        mutating func i32() throws -> Int32 {
            try need(4); defer { cursor += 4 }
            return Int32(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: Int32.self))
        }
        mutating func f64() throws -> Double {
            try need(8); defer { cursor += 8 }
            return Double(bitPattern: UInt64(littleEndian: bytes.loadUnaligned(fromByteOffset: cursor, as: UInt64.self)))
        }
        mutating func slice(_ n: Int) throws -> UnsafeRawBufferPointer {
            try need(n); defer { cursor += n }
            return UnsafeRawBufferPointer(rebasing: bytes[cursor..<cursor + n])
        }
        mutating func i32s(expected: Int? = nil) throws -> [Int32] {
            let n = Int(try u32())
            if let expected, n != expected { throw CodecError.corrupt("array length \(n) ≠ \(expected)") }
            let raw = try slice(n * 4)
            return [Int32](unsafeUninitializedCapacity: n) { buffer, count in
                raw.copyBytes(to: UnsafeMutableRawBufferPointer(buffer))
                count = n
            }
        }
        mutating func byteArray() throws -> [UInt8] {
            let n = Int(try u32())
            return Array(try slice(n))
        }
        mutating func optionalString() throws -> String? {
            let ref = try i32()
            if ref == -1 { return nil }
            guard ref >= 0, Int(ref) < strings.count else { throw CodecError.corrupt("string ref") }
            return strings[Int(ref)]
        }
        mutating func string() throws -> String {
            guard let s = try optionalString() else { throw CodecError.corrupt("nil string") }
            return s
        }
        mutating func stringArray() throws -> [String] {
            let n = Int(try u32())
            try need(n * 4)
            var out: [String] = []
            out.reserveCapacity(n)
            for _ in 0..<n { out.append(try string()) }
            return out
        }
    }}

extension Data {
    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        let raw: T = self.withUnsafeBytes { buffer in
            buffer.loadUnaligned(fromByteOffset: offset, as: T.self)
        }
        return T(littleEndian: raw)
    }
}
