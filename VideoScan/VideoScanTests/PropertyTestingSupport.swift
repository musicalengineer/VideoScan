// PropertyTestingSupport.swift (VideoScanTests)
// A copy of VideoScanCoreTests/PropertyTestingSupport.swift — the two test
// targets cannot share a source file (the app target is an Xcode synchronized
// folder, Core is a SwiftPM target). Keep the two in step.
// A small seeded property-testing harness (Rick approved generated-input
// tests 2026-10-01). No third-party dependency: a SplitMix64 generator, a
// `check` loop and a greedy shrinker.
//
// HOW A PROPERTY RUNS. Each property is a parameterized `@Test(arguments:
// Property.batches)`: Swift Testing runs one test case per batch (in
// parallel), and each batch generates `cases` inputs from seeds derived
// from (property name, batch, index). Every seed is deterministic, so a run
// is reproducible bit-for-bit on any machine.
//
// WHEN A PROPERTY FAILS the issue names the property, the seed of the first
// failing case, the input as generated, the MINIMAL input the shrinker
// reached (each shrink step keeps the property failing), the reason, and
// how many of the batch's cases failed. To replay one case:
//     var g = SeededGenerator(seed: 0x…); let input = generate(&g)
//
// C++ readers: this is the hand-rolled equivalent of RapidCheck /
// Hypothesis. `#expect` is EXPECT_* (records and continues); `Issue.record`
// is ADD_FAILURE() with a message; `inout` is a non-const reference.

import Foundation
import Testing

/// SplitMix64 — tiny, fast, and the same sequence on every platform.
struct SeededGenerator: RandomNumberGenerator {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// One element, uniformly. The array must not be empty.
    mutating func pick<T>(_ items: [T]) -> T {
        items[Int(next() % UInt64(items.count))]
    }

    mutating func int(_ range: ClosedRange<Int>) -> Int {
        Int.random(in: range, using: &self)
    }

    /// True with probability `p`.
    mutating func chance(_ p: Double) -> Bool {
        Double(next() >> 11) / Double(1 << 53) < p
    }
}

enum Property {

    /// The batches a property is split into; one Swift Testing case each.
    static let batches = Array(0..<8)

    /// Default cases per batch: 8 × 500 = 4,000 per property.
    static let casesPerBatch = 500

    /// PROPERTY_TRACE=1 prints every seed before its case runs.
    static let trace = ProcessInfo.processInfo.environment["PROPERTY_TRACE"] == "1"

    /// A stable 64-bit seed for one case: FNV-1a of the property name,
    /// mixed with the batch and index. (`String.hashValue` is randomised
    /// per process, so it is never used here.)
    static func seed(property: String, batch: Int, index: Int) -> UInt64 {
        var h: UInt64 = 0xCBF2_9CE4_8422_2325
        for b in property.utf8 { h = (h ^ UInt64(b)) &* 0x0000_0100_0000_01B3 }
        var g = SeededGenerator(seed: h ^ (UInt64(batch) << 32) ^ UInt64(index))
        return g.next()
    }

    /// Run `property` over `cases` generated inputs. `property` returns nil
    /// when it holds, or the reason it does not. Returns the failure count.
    @discardableResult
    static func check<Input>(
        _ name: String,
        batch: Int,
        cases: Int = casesPerBatch,
        generate: (inout SeededGenerator) -> Input,
        shrink: (Input) -> [Input] = { _ in [] },
        describe: (Input) -> String = { String(reflecting: $0) },
        sourceLocation: SourceLocation = #_sourceLocation,
        _ property: (Input) -> String?
    ) -> Int {
        var failures = 0
        var first: (seed: UInt64, input: Input, reason: String)?
        for index in 0..<cases {
            let seed = Self.seed(property: name, batch: batch, index: index)
            var g = SeededGenerator(seed: seed)
            let input = generate(&g)
            // A crash or a hang kills the run before an issue is recorded:
            // rerun with PROPERTY_TRACE=1 and the last line names the seed.
            if trace { print("[property] \(name) batch \(batch) case \(index) seed 0x\(String(seed, radix: 16))") }
            if let reason = property(input) {
                failures += 1
                if first == nil { first = (seed, input, reason) }
            }
        }
        if let first {
            let (minimal, minimalReason) = Self.shrunk(first.input, reason: first.reason,
                                                       shrink: shrink, property: property)
            Issue.record(Comment(rawValue: """
                Property "\(name)" failed in \(failures) of \(cases) cases (batch \(batch)).
                  seed:    0x\(String(first.seed, radix: 16))   (replay: SeededGenerator(seed: 0x\(String(first.seed, radix: 16))))
                  input:   \(describe(first.input))
                  minimal: \(describe(minimal))
                  reason:  \(minimalReason)
                """), sourceLocation: sourceLocation)
        }
        return failures
    }

    /// Greedy shrink: take the first smaller candidate that still fails,
    /// repeat until none does (bounded, so a bad shrinker cannot hang).
    static func shrunk<Input>(_ input: Input, reason: String,
                              shrink: (Input) -> [Input],
                              property: (Input) -> String?) -> (Input, String) {
        var current = input
        var currentReason = reason
        var steps = 0
        outer: while steps < 500 {
            steps += 1
            for candidate in shrink(current) {
                if let r = property(candidate) {
                    current = candidate
                    currentReason = r
                    continue outer
                }
            }
            break
        }
        return (current, currentReason)
    }
}

/// Shrinkers for unstructured inputs. A STRUCTURED input (a place with
/// roles, a GEDCOM tree) shrinks through its own type, so a shrink step can
/// never turn it into a different kind of input — see GeneratedPlace.shrinks.
enum Shrink {

    /// Text: halve, drop the first / last character, drop one word.
    static func text(_ s: String) -> [String] {
        guard !s.isEmpty else { return [] }
        var out: [String] = []
        if s.count > 1 {
            out.append(String(s.prefix(s.count / 2)))
            out.append(String(s.suffix(s.count - s.count / 2)))
        }
        out.append(String(s.dropFirst()))
        out.append(String(s.dropLast()))
        let words = s.split(separator: " ", omittingEmptySubsequences: false)
        if words.count > 1 {
            for i in words.indices {
                var w = words
                w.remove(at: i)
                out.append(w.joined(separator: " "))
            }
        }
        return out.filter { $0 != s }
    }

    /// Lines of a document: drop one line at a time, then halves.
    static func lines(_ lines: [String]) -> [[String]] {
        guard lines.count > 1 else { return [] }
        var out: [[String]] = [Array(lines.prefix(lines.count / 2)), Array(lines.suffix(lines.count - lines.count / 2))]
        for i in lines.indices {
            var l = lines
            l.remove(at: i)
            out.append(l)
        }
        return out
    }
}
