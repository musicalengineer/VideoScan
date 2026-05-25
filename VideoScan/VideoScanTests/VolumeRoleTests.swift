import Testing
import Foundation
@testable import VideoScan

@Suite("VolumeRole")
struct VolumeRoleTests {

    @Test func allCasesPresent() {
        let all = VolumeRole.allCases
        #expect(all.count == 7)
        #expect(all.contains(.unassigned))
        #expect(all.contains(.system))
        #expect(all.contains(.original))
        #expect(all.contains(.backup))
        #expect(all.contains(.archive))
        #expect(all.contains(.lta))
        #expect(all.contains(.retired))
    }

    @Test func everyCaseHasIconColorShortLabel() {
        for r in VolumeRole.allCases {
            #expect(!r.icon.isEmpty, "icon empty for \(r.rawValue)")
            #expect(!r.shortLabel.isEmpty, "shortLabel empty for \(r.rawValue)")
            _ = r.color
        }
    }

    @Test func shortLabelsAreUnique() {
        let labels = VolumeRole.allCases.map(\.shortLabel)
        #expect(Set(labels).count == labels.count, "shortLabel collision")
    }

    @Test func rawValuesAreUnique() {
        let raw = VolumeRole.allCases.map(\.rawValue)
        #expect(Set(raw).count == raw.count, "rawValue collision")
    }

    @Test func codableRoundTripPreservesNewCases() throws {
        let cases: [VolumeRole] = [.system, .retired, .unassigned, .original]
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for c in cases {
            let data = try encoder.encode(c)
            let decoded = try decoder.decode(VolumeRole.self, from: data)
            #expect(decoded == c)
        }
    }

    @Test func legacyRawValuesStillDecode() throws {
        let legacy: [String: VolumeRole] = [
            "\"Unassigned\"": .unassigned,
            "\"Original\"":   .original,
            "\"Backup\"":     .backup,
            "\"Archive\"":    .archive,
            "\"Long-Term Archive\"": .lta,
        ]
        let decoder = JSONDecoder()
        for (json, expected) in legacy {
            let data = Data(json.utf8)
            let decoded = try decoder.decode(VolumeRole.self, from: data)
            #expect(decoded == expected, "legacy raw value \(json) didn't decode to \(expected)")
        }
    }

    @Test func newCasesUseNewRawValues() throws {
        let encoder = JSONEncoder()
        let sysData = try encoder.encode(VolumeRole.system)
        let rtdData = try encoder.encode(VolumeRole.retired)
        #expect(String(data: sysData, encoding: .utf8) == "\"System\"")
        #expect(String(data: rtdData, encoding: .utf8) == "\"Retired\"")
    }
}
