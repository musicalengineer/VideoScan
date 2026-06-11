import Foundation
import Testing
@testable import VideoScan

// MARK: - MediaDisposition raw-value contract (Rick 2026-06-10)
//
// Pinned after a real corruption incident: scripts/tag_imovie_stock_as_junk.py
// wrote the Swift case NAME ("confirmedJunk") into JSON instead of the
// case's RAW VALUE ("Confirmed Junk"). The Swift JSONDecoder silently
// falls back to .unreviewed on raw-value mismatch, so 132 records were
// effectively un-tagged with no error surface. The Python script side is
// pinned by tests/test_tag_imovie_stock_as_junk.py::
// test_writes_swift_enum_raw_value — these two tests must move together.

@Suite("MediaDisposition raw-value contract")
struct MediaDispositionRawValueContractTests {

    @Test func confirmedJunkRawValueIsConfirmedJunkWithSpace() {
        // Anything other than this exact string corrupts every record any
        // out-of-process script writes for confirmedJunk. Keep in lock-step
        // with the Python sibling test.
        #expect(MediaDisposition.confirmedJunk.rawValue == "Confirmed Junk")
    }

    @Test func allRawValuesAreStableContract() {
        // Pin every case's raw value — any rename here ripples to the
        // catalog file format and to every out-of-process writer (the
        // dossier merger, the junk tagger, the bundle import). Bumping
        // these is a migration, not a rename.
        let pairs: [(MediaDisposition, String)] = [
            (.unreviewed,    "Unreviewed"),
            (.important,     "Important"),
            (.recoverable,   "Recoverable"),
            (.suspectedJunk, "Suspected Junk"),
            (.confirmedJunk, "Confirmed Junk"),
        ]
        for (case_, expected) in pairs {
            #expect(case_.rawValue == expected,
                    "MediaDisposition.\(case_) raw value drifted to \(case_.rawValue)")
        }
    }

    @Test func swiftDecoderRejectsCaseNameInsteadOfRawValue() {
        // Negative control: prove the decoder really does reject the bad
        // value the 2026-06-10 incident produced. If this test ever
        // starts passing the WRONG way, MediaDisposition gained a
        // lenient codable and the regression sensor is disarmed.
        struct Wrap: Decodable { let mediaDisposition: MediaDisposition }
        let bad = #"{"mediaDisposition":"confirmedJunk"}"#.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(Wrap.self, from: bad)
        }
    }

    @Test func swiftDecoderAcceptsCorrectRawValue() {
        // Positive control: the value the fixed script writes round-trips.
        struct Wrap: Decodable { let mediaDisposition: MediaDisposition }
        let good = #"{"mediaDisposition":"Confirmed Junk"}"#.data(using: .utf8)!
        let decoded = try! JSONDecoder().decode(Wrap.self, from: good)
        #expect(decoded.mediaDisposition == .confirmedJunk)
    }
}
