import Testing
import Foundation
@testable import VideoScan

/// VolumeRole enum-level contract after the 2026-08-16 taxonomy cleanup
/// (docs/volume_taxonomy_proposal.md, final names by Rick): `.retired`
/// gone, `.original` merged into `.workspace`, `.lta` → `.cloud`,
/// `.archive` displays as "Master Archive", `pickerCases` excludes
/// Archive/System, and every legacy raw string still decodes. Model-level
/// migration lives in VolumeRoleTaxonomyMigrationTests.
@Suite("VolumeRole")
struct VolumeRoleTests {

    @Test func allCasesPresent() {
        let all = VolumeRole.allCases
        #expect(all.count == 6)
        #expect(all == [.unassigned, .system, .workspace, .backup, .cloud, .archive])
        #expect(VolumeRole.archive.rawValue == "Master Archive")
        #expect(VolumeRole.cloud.rawValue == "Cloud")
        #expect(VolumeRole.workspace.rawValue == "Workspace")
    }

    /// The old case names must be gone — any of them sneaking back in
    /// would re-open the two-owners bug or split Workspace again.
    @Test func retiredLTAOriginalWorkingOffsiteAreNotCurrentCases() {
        for old in ["Retired", "Long-Term Archive", "Original", "Working", "Offsite", "Archive"] {
            #expect(VolumeRole(rawValue: old) == nil, "'\(old)' must be legacy-only")
        }
    }

    @Test func pickerCasesExcludeDisplayOnlyRoles() {
        let p = VolumeRole.pickerCases
        #expect(p == [.unassigned, .workspace, .backup, .cloud])
        #expect(!p.contains(.archive), "Master Archive is set only by Initialize")
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
        #expect(VolumeRole.cloud.icon == "icloud.fill", "Cloud's icon is the cloud")
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

    /// Every string any earlier build could have persisted (original set,
    /// the interim Working/Offsite/Archive build, hand-edits), plus the
    /// current set, plus junk. ONE table, so adding a legacy string means
    /// adding a row here.
    static let legacyMatrix: [(raw: String, role: VolumeRole, wasRetired: Bool, unknown: Bool)] = [
        // current
        ("Unassigned",        .unassigned, false, false),
        ("System",            .system,     false, false),
        ("Workspace",         .workspace,  false, false),
        ("Backup",            .backup,     false, false),
        ("Cloud",             .cloud,      false, false),
        ("Master Archive",    .archive,    false, false),
        // original 2026 set
        ("Original",          .workspace,  false, false),   // merged into Workspace
        ("Archive",           .archive,    false, false),   // display name changed
        ("Long-Term Archive", .cloud,      false, false),   // rename
        ("Retired",           .unassigned, true,  false),   // role → lifecycle stamp
        // interim build names
        ("Working",           .workspace,  false, false),
        ("Offsite",           .cloud,      false, false),
        // hand-edits
        ("LTA",               .cloud,      false, false),
        (" backup ",          .backup,     false, false),   // whitespace + case
        ("retired",           .unassigned, true,  false),   // case-insensitive legacy
        ("original",          .workspace,  false, false),
        // junk
        ("Bogus",             .unassigned, false, true),
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
        #expect(String(data: try encoder.encode(VolumeRole.cloud), encoding: .utf8) == "\"Cloud\"")
        #expect(String(data: try encoder.encode(VolumeRole.workspace), encoding: .utf8) == "\"Workspace\"")
        #expect(String(data: try encoder.encode(VolumeRole.archive), encoding: .utf8) == "\"Master Archive\"")
        #expect(String(data: try encoder.encode(VolumeRole.system), encoding: .utf8) == "\"System\"")
    }
}
