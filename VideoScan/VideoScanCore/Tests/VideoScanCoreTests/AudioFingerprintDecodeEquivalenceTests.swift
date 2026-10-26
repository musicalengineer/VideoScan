// AudioFingerprintDecodeEquivalenceTests.swift — the bulk-read
// `AudioFingerprint.decode` (2026-10-26, Find Master) against the decoder it
// replaced, copied here VERBATIM as the reference (`ReferenceDecoder`).
// On random valid prints, every truncation, size-mismatched (padded or cut)
// blobs, bad magic/version, invalid headers and random garbage: the two
// return the identical print, or throw the identical DecodingError.
// Seeded; no I/O.

import Foundation
import Testing
@testable import VideoScanCore

/// The pre-2026-10-26 `AudioFingerprint.decode`, unchanged but for its name
/// and the reader it is given (the original's private `LittleEndianReader`,
/// also copied).
enum ReferenceDecoder {
    struct LittleEndianReader {
        let data: Data
        var offset: Int

        mutating func read<T: FixedWidthInteger>() -> T? {
            let size = MemoryLayout<T>.size
            guard offset + size <= data.count else { return nil }
            var raw: T = 0
            _ = withUnsafeMutableBytes(of: &raw) { data.copyBytes(to: $0, from: offset..<(offset + size)) }
            offset += size
            return T(littleEndian: raw)
        }
    }

    typealias DecodingError = AudioFingerprint.DecodingError

    static func decode(_ data: Data) throws -> AudioFingerprint {
        guard data.count >= AudioFingerprint.headerBytes else { throw DecodingError.tooShort(bytes: data.count) }
        guard Array(data.prefix(4)) == AudioFingerprint.magic else { throw DecodingError.badMagic }
        var reader = LittleEndianReader(data: data, offset: 4)
        guard let version: UInt16 = reader.read(), let recipeID: UInt32 = reader.read(),
              let flags: UInt8 = reader.read(),
              let sampleRate: UInt32 = reader.read(), let hop: UInt32 = reader.read(),
              let frameSize: UInt32 = reader.read(), let durationBits: UInt64 = reader.read(),
              let count: UInt32 = reader.read(), let secondCount: UInt32 = reader.read()
        else { throw DecodingError.tooShort(bytes: data.count) }
        guard version == AudioFingerprint.currentVersion else { throw DecodingError.unsupportedVersion(version) }
        let expected = AudioFingerprint.headerBytes + 8 * Int(count) + (Int(secondCount) + 7) / 8
        guard data.count == expected else { throw DecodingError.sizeMismatch(expected: expected, actual: data.count) }
        do {
            try AudioFingerprintParameters.validateFrame(sampleRate: Int(sampleRate), frameSize: Int(frameSize),
                                                         hopSamples: Int(hop))
        } catch let error as AudioFingerprintParameters.ValidationError {
            throw DecodingError.invalidHeader(error)
        }
        var hashes = [UInt32](), times = [UInt32]()
        hashes.reserveCapacity(Int(count)); times.reserveCapacity(Int(count))
        for _ in 0..<count {
            guard let h: UInt32 = reader.read() else { throw DecodingError.tooShort(bytes: data.count) }
            hashes.append(h)
        }
        for _ in 0..<count {
            guard let t: UInt32 = reader.read() else { throw DecodingError.tooShort(bytes: data.count) }
            times.append(t)
        }
        var active = [Bool](); active.reserveCapacity(Int(secondCount))
        var byte: UInt8 = 0
        for i in 0..<Int(secondCount) {
            if i % 8 == 0 {
                guard let next: UInt8 = reader.read() else { throw DecodingError.tooShort(bytes: data.count) }
                byte = next
            }
            active.append(byte & (1 << UInt8(i % 8)) != 0)
        }
        return AudioFingerprint(version: version, recipeID: recipeID, sampleRate: Int(sampleRate),
                                hopSamples: Int(hop), frameSize: Int(frameSize),
                                durationSeconds: Double(bitPattern: durationBits),
                                complete: flags & AudioFingerprint.completeFlag != 0, activeSeconds: active,
                                hashes: hashes, times: times)
    }
}

@Suite("AudioFingerprint decode equivalence (bulk read vs the reference)")
struct AudioFingerprintDecodeEquivalenceTests {

    /// Same print, or same error — anything else is a difference.
    static func outcome(_ decode: (Data) throws -> AudioFingerprint, _ data: Data) -> Result<AudioFingerprint, AudioFingerprint.DecodingError> {
        do { return .success(try decode(data)) } catch let error as AudioFingerprint.DecodingError {
            return .failure(error)
        } catch {
            Issue.record("unexpected error type: \(error)")
            return .failure(.badMagic)
        }
    }

    static func expectSame(_ data: Data, _ label: String) {
        let new = outcome(AudioFingerprint.decode, data), old = outcome(ReferenceDecoder.decode, data)
        switch (new, old) {
        case (.success(let a), .success(let b)):
            #expect(a == b, "\(label): different prints")
            #expect(a.activeSeconds == b.activeSeconds, "\(label)")
        case (.failure(let a), .failure(let b)):
            #expect(a == b, "\(label): \(a) vs \(b)")
        default:
            Issue.record("\(label): new \(new) vs reference \(old)")
        }
    }

    static func randomPrint(_ rng: inout SplitMix64) -> AudioFingerprint {
        let count = Int(rng.next() % 3_000)
        let seconds = Int(rng.next() % 300)
        let hashes = (0..<count).map { _ in UInt32(truncatingIfNeeded: rng.next()) }
        let times = (0..<count).map { _ in UInt32(truncatingIfNeeded: rng.next()) }
        let active = (0..<seconds).map { _ in rng.next() % 2 == 0 }
        return AudioFingerprint(recipeID: UInt32(truncatingIfNeeded: rng.next()), sampleRate: 8_000, hopSamples: 512,
                                frameSize: 1_024, durationSeconds: Double(seconds) + rng.unit(), complete: rng.next() % 2 == 0,
                                activeSeconds: active, hashes: hashes, times: times)
    }

    @Test("random valid prints decode identically")
    func validPrints() {
        var rng = SplitMix64(seed: 0xDEC0_DE01)
        for i in 0..<200 {
            let blob = Self.randomPrint(&rng).encoded()
            Self.expectSame(blob, "valid #\(i)")
        }
        Self.expectSame(AudioFingerprint(sampleRate: 8_000, hopSamples: 512, frameSize: 1_024, durationSeconds: 0,
                                         hashes: [], times: []).encoded(), "empty print")
    }

    @Test("every truncation, padded and cut blobs throw the identical error")
    func truncatedAndSizeMismatched() {
        var rng = SplitMix64(seed: 0xDEC0_DE02)
        for i in 0..<20 {
            let blob = Self.randomPrint(&rng).encoded()
            for length in stride(from: 0, to: blob.count, by: max(1, blob.count / 97)) {
                Self.expectSame(blob.prefix(length), "#\(i) cut to \(length)")
            }
            Self.expectSame(blob + Data([0]), "#\(i) +1 byte")
            Self.expectSame(blob + Data(repeating: 7, count: 9), "#\(i) +9 bytes")
            Self.expectSame(blob.dropLast(), "#\(i) −1 byte")
        }
    }

    @Test("bad magic, other versions, invalid headers and garbage throw the identical error")
    func badHeadersAndGarbage() {
        var rng = SplitMix64(seed: 0xDEC0_DE03)
        let base = Self.randomPrint(&rng).encoded()
        var badMagic = base; badMagic[0] = 0x58
        Self.expectSame(badMagic, "bad magic")
        var version = base; version[4] = 3
        Self.expectSame(version, "version 3")
        for (offset, label) in [(AudioFingerprint.hopFieldOffset, "hop 0"), (AudioFingerprint.sampleRateFieldOffset, "rate 0"),
                                (AudioFingerprint.frameSizeFieldOffset, "frame 0")] {
            var patched = base
            for k in 0..<4 { patched[offset + k] = 0 }
            Self.expectSame(patched, label)
        }
        var oddFrame = base
        oddFrame[AudioFingerprint.frameSizeFieldOffset] = 0x03
        Self.expectSame(oddFrame, "frame not a power of two")
        for i in 0..<200 {
            let length = Int(rng.next() % 200)
            var garbage = Data((0..<length).map { _ in UInt8(truncatingIfNeeded: rng.next()) })
            if i % 2 == 0, garbage.count >= 4 { garbage.replaceSubrange(0..<4, with: AudioFingerprint.magic) }
            Self.expectSame(garbage, "garbage #\(i)")
        }
    }
}
