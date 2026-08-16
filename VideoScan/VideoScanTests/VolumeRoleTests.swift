import Testing
import Foundation
@testable import VideoScan

/// VolumeRole enum-level contract after the 2026-08-16 taxonomy cleanup
/// (docs/volume_taxonomy_proposal.md): `.retired` gone, `.lta` → `.offsite`,
/// `.working` added, `pickerCases` excludes Archive/System, and every
/// legacy raw string still decodes. Model-level migration lives in
/// VolumeRoleTaxonomyMigrationTests.
@Suite("VolumeRole")
struct VolumeRoleTests {

    @Test func allCasesPresent() {
        let all = VolumeRole.allCases
        #expect(all.count == 7)
        #expect(all.contains(.unassigned))
        #expect(all.contains(.system))
        #expect(all.contains(.working))
        #expect(all.contains(.original))
        #expect(all.contains(.backup))
        #expect(all.contains(.archive))
        #expect(all.contains(.offsite))
    }

    /// The old case names must be gone — a `.retired` or `.lta` sneaking
    /// back in would re-open the two-owners bug.
    @Test func retiredAndLTARawValuesAreNotCurrentCases() {
        #expect(VolumeRole(rawValue: "Retired") == nil)
        #expect(VolumeRole(rawValue: "Long-Term Archive") == nil)
    }

    @Test func pickerCasesExcludeDisplayOnlyRoles() {
        let p = VolumeRole.pickerCases
        #expect(p == [.unassigned, .working, .original, .backup, .offsite])
        #expect(!p.contains(.archive), "Archive is set only by Initialize")
        #expect(!p.contains(.system), "System is auto-assigned to the boot volume")
        for r in VolumeRole.allCases {
            #expect(r.isUserSelectable == p.contains(r))
        }
    }

    @Test func pickerChoicesKeepCurrentDisplayOnlySelectionValid() {
        #expect(VolumeRole.pickerChoices(including: .backup) == VolumeRole.pickerCases)
        #expect(VolumeRole.pickerChoices(including: .archive) == VolumeRole.pickerCases + [.archive])
        #expect(VolumeRole.pickerChoices(including: .system) == VolumeRole.pickerCases + [.system])
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

    @Test func codableRoundTripPreservesEveryCase() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        for c in VolumeRole.allCases {
            let data = try encoder.encode(c)
            let decoded = try decoder.decode(VolumeRole.self, from: data)
            #expect(decoded == c)
        }
    }

    // MARK: - Legacy raw-string decode matrix

    /// Every string a pre-taxonomy build could have persisted, plus the
    /// three current display-only/renamed ones, plus junk. ONE table, so
    /// adding a legacy string means adding a row here.
    static let legacyMatrix: [(raw: String, role: VolumeRole, wasRetired: Bool, unknown: Bool)] = [
        ("Unassigned",        .unassigned, false, false),
        ("System",            .system,     false, false),
        ("Original",          .original,   false, false),
        ("Backup",            .backup,     false, false),
        ("Archive",           .archive,    false, false),
        ("Long-Term Archive", .offsite,    false, false),   // rename
        ("Retired",           .unassigned, true,  false),   // role → lifecycle stamp
        ("Working",           .working,    false, false),
        ("Offsite",           .offsite,    false, false),
        ("LTA",               .offsite,    false, false),   // hand-edited short label
        (" backup ",          .backup,     false, false),   // whitespace + case
        ("retired",           .unassigned, true,  false),   // case-insensitive legacy
        ("Bogus",             .unassigned, false, true),    // junk → unassigned, flagged
        ("",                  .unassigned, false, true),
    ]

    @Test func decodeLegacyMatrix() {
        for row in Self.legacyMatrix {
            let d = VolumeRole.decodeLegacy(row.raw)
            #expect(d.role == row.role, "'\(row.raw)' → \(d.role), expected \(row.role)")
            #expect(d.wasRetired == row.wasRetired, "'\(row.raw)' wasRetired mismatch")
            #expect((d.unknownRaw != nil) == row.unknown, "'\(row.raw)' unknown flag mismatch")
        }
    }

    @Test func legacyRawValueInitIsNilOnlyForJunk() {
        for row in Self.legacyMatrix {
            let r = VolumeRole(legacyRawValue: row.raw)
            if row.unknown {
                #expect(r == nil, "'\(row.raw)' should be unrecognised")
            } else {
                #expect(r == row.role, "'\(row.raw)' → \(String(describing: r))")
            }
        }
    }

    /// JSON `Codable` path (any struct holding a VolumeRole directly)
    /// accepts legacy strings and never throws on junk.
    @Test func codableDecodeAcceptsLegacyAndJunk() throws {
        let decoder = JSONDecoder()
        for row in Self.legacyMatrix {
            let json = try JSONEncoder().encode([row.raw])   // ["<raw>"]
            let decoded = try decoder.decode([VolumeRole].self, from: json)
            #expect(decoded == [row.role], "JSON '\(row.raw)' → \(decoded)")
        }
    }

    @Test func encodingUsesCurrentRawValues() throws {
        let encoder = JSONEncoder()
        #expect(String(data: try encoder.encode(VolumeRole.offsite), encoding: .utf8) == "\"Offsite\"")
        #expect(String(data: try encoder.encode(VolumeRole.working), encoding: .utf8) == "\"Working\"")
        #expect(String(data: try encoder.encode(VolumeRole.system), encoding: .utf8) == "\"System\"")
    }
}
