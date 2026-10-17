// RowPreflightTests.swift
// Codex D′ #6: the DDL's row-local CHECKs applied before any insert. Each
// check named once; a clean row and every fixture shape are clean; a
// quarantine landing ignores the main-scope checks; the sidecar checks
// (event state, member range, ignored size, audit judged path) each refuse.
// One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("RowPreflightTests")
struct RowPreflightTests {

    /// The fixture's healthy row with `edit` applied, mapped like the importer maps it.
    private static func dto(_ shape: PoisonedCatalogFixture.Shape = .healthy,
                            _ edit: (inout [String: CatalogJSONValue]) -> Void = { _ in }) throws -> CatalogRecordDTO {
        var row = try #require(PoisonedCatalogFixture.row(for: shape).objectValue)
        edit(&row)
        let file: CatalogJSONValue = .object(["version": .int(6), "records": .array([.object(row)])])
        let catalog = try CatalogFileJSON.decode(try CatalogJSONValue.makeEncoder().encode(file))
        return CatalogRecordDTO(record: try #require(catalog.records.first), migrationLoadedAt: 0)
    }

    @Test func aHealthyRowIsClean() throws {
        #expect(RowPreflight.report(try Self.dto()).isClean)
    }

    @Test("every fixture shape is representable", arguments: PoisonedCatalogFixture.Shape.allCases)
    func everyFixtureShapeIsRepresentable(shape: PoisonedCatalogFixture.Shape) throws {
        #expect(RowPreflight.report(try Self.dto(shape)).isClean, "\(shape.rawValue)")
    }

    @Test func aVolumeIdThatIsNotAUUIDIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto { $0["scanContext"] = .object(["volumeUUID": .string("VU-1")]) })
        #expect(report.main == ["volume id \"VU-1\" is not a 36-character UUID"])
        #expect(report.any.isEmpty)
    }

    @Test func aLowercaseVolumeUUIDIsAMainViolationAsTheDDLSpellsIt() throws {
        let report = RowPreflight.report(try Self.dto { $0["scanContext"] = .object(["volumeUUID": .string("0a1b2c3d-0000-4000-8000-00000000f1f0")]) })
        #expect(report.main.count == 1)
    }

    @Test func anEmptyVolumeIdIsAllowed() throws {
        let report = RowPreflight.report(try Self.dto { $0["scanContext"] = .object(["volumeUUID": .string("")]) })
        #expect(report.isClean)
    }

    @Test func aNegativeSizeOnAHashedRowViolatesFilesAndContent() throws {
        let report = RowPreflight.report(try Self.dto { row in
            row["sizeBytes"] = .int(-1)
            var fixity = row["contentFixity"]?.objectValue ?? [:]
            fixity["byteCount"] = .int(-1)
            row["contentFixity"] = .object(fixity)
        })
        #expect(report.main == ["size_bytes is negative (-1)"])
        #expect(report.any == ["content byte_count is negative (-1)"])
    }

    @Test func aRelativePathIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto { $0["fullPath"] = .string("Clips/a.mov") })
        #expect(report.main == ["path \"Clips/a.mov\" is not an absolute path"])
    }

    @Test func anUnknownLifecycleIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto { $0["lifecycleStage"] = .string("Weird") })
        #expect(report.main == ["lifecycle \"Weird\" is not a known stage"])
    }

    @Test func anUnknownStreamTypeIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto { $0["streamTypeRaw"] = .string("Hologram") })
        #expect(report.main == ["stream_type \"Hologram\" is not a known stream type"])
    }

    @Test func aNegativeDurationIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto { $0["durationSeconds"] = .double(-0.5) })
        #expect(report.main == ["duration_s is negative (-0.5)"])
    }

    @Test func anUnknownBackupKindIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto {
            $0["backupDestinations"] = .array([.object(["name": .string("LTO"), "kind": .string("Tape"), "date": .string("2026-01-01T00:00:00Z")])])
        })
        #expect(report.main == ["backup kind \"Tape\" is not Local, Cloud or Offsite"])
    }

    @Test func anInTrashMarkerOnACatalogedRowIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto {
            $0["removal"] = .object(["state": .string("inTrash"), "since": .string("2026-01-01T00:00:00Z"), "reason": .string("catalogTrash")])
        })
        #expect(report.main == ["an inTrash marker on a row whose lifecycle is \"Cataloged\", not Trashed"])
    }

    @Test func aTrashPathOnAMissingMarkerIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto {
            $0["removal"] = .object(["state": .string("missing"), "since": .string("2026-01-01T00:00:00Z"), "reason": .string("audit"),
                                     "trashPath": .string("/T/a.mov")])
        })
        #expect(report.main == ["a trash path on a marker that is not inTrash"])
    }

    @Test func aNegativeRemovalRevisionIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto { $0["removalRevision"] = .int(-3) })
        #expect(report.main == ["removal_revision is negative (-3)"])
    }

    @Test func aBlankAuditVolumeIsAMainViolation() throws {
        let report = RowPreflight.report(try Self.dto {
            $0["auditSeenOn"] = .object(["volumeUUID": .string("  "), "seenAt": .string("2026-01-01T00:00:00Z")])
        })
        #expect(report.main == ["the audit stamp names no volume"])
    }

    @Test func anUnknownFootageVerdictIsAnAnyViolation() throws {
        let report = RowPreflight.report(try Self.dto {
            $0["footageDecisions"] = .array([.object(["otherID": .string("13131313-1313-1313-1313-131313131313"),
                                                      "verdict": .string("maybe"), "decidedAt": .string("2026-01-01T00:00:00Z")])])
        })
        #expect(report.any == ["footage verdict \"maybe\" is not same or notSame"])
        #expect(report.main.isEmpty)
    }

    @Test func aFootageDecisionNamingItsOwnRowIsAnAnyViolation() throws {
        let report = RowPreflight.report(try Self.dto {
            $0["footageDecisions"] = .array([.object(["otherID": .string(PoisonedCatalogFixture.id(.healthy)),
                                                      "verdict": .string("same"), "decidedAt": .string("2026-01-01T00:00:00Z")])])
        })
        #expect(report.any == ["a footage decision names its own row"])
    }

    @Test func aNoAudioSoundPrintWithLandmarksIsAnAnyViolation() throws {
        let report = RowPreflight.report(try Self.dto {
            $0["audioFingerprint"] = .object([
                "computedAt": .string("2026-01-01T00:00:00Z"), "engineVersion": .int(3),
                "contentDigest": .string("sha256:" + PoisonedCatalogFixture.digest("healthy")), "sizeBytes": .int(4_096),
                "outcome": .string("noAudio"), "analyzedSeconds": .double(1), "complete": .bool(true), "landmarks": .int(9), "bytes": .int(0),
            ])
        })
        #expect(report.any == ["a noAudio sound print carries landmarks or bytes"])
    }

    @Test func aSoundPrintBelowEngineVersionOneIsAnAnyViolation() throws {
        let report = RowPreflight.report(try Self.dto {
            $0["audioFingerprint"] = .object([
                "computedAt": .string("2026-01-01T00:00:00Z"), "engineVersion": .int(0),
                "contentDigest": .string("sha256:" + PoisonedCatalogFixture.digest("healthy")), "sizeBytes": .int(4_096),
                "outcome": .string("fingerprinted"), "analyzedSeconds": .double(1), "complete": .bool(true), "landmarks": .int(9), "bytes": .int(9),
            ])
        })
        #expect(report.any == ["sound print engine_version 0 is below 1"])
    }

    @Test func aQuarantineLandingAnswersOnlyToTheAnyChecks() {
        let report = RowPreflight.Report(main: ["m"], any: ["a"])
        #expect(report.violations(for: .quarantine(reason: .auditGone, words: "", findings: [])) == ["a"])
        #expect(report.violations(for: .main(tombstoned: false)) == ["a", "m"])
    }

    @Test func theWordsNameTheGatesVerdictAndEveryCheck() {
        let words = RowPreflight.words(gate: .main(tombstoned: true), violations: ["one", "two"])
        #expect(words == "cannot be stored as-is (the gate said main, tombstoned): one; two")
    }

    @Test func theQuarantineFloorIsAThirtySixCharacterId() throws {
        #expect(RowPreflight.quarantineFloor(try Self.dto()) == nil)
        let short = try Self.dto { $0["id"] = .string("abc") }
        #expect(RowPreflight.quarantineFloor(short) == "its id \"abc\" is not 36 characters — not even quarantine can key it")
    }

    // MARK: - Sidecar entries

    @Test func anUnknownEventStateIsAFault() {
        let event = EventsDecisionsJSON.Event(id: PoisonedCatalogFixture.eventOneID, name: "x", categories: nil, state: "pending",
                                              createdAt: nil, updatedAt: nil, note: nil)
        #expect(RowPreflight.violations(event: event) == ["event state \"pending\" is not confirmed or dismissed"])
    }

    @Test func aShortEventIdIsAFault() {
        let event = EventsDecisionsJSON.Event(id: "E1", name: "x", categories: nil, state: nil, createdAt: nil, updatedAt: nil, note: nil)
        #expect(RowPreflight.violations(event: event) == ["event id \"E1\" is not 36 characters"])
    }

    @Test func aMemberRangeThatRunsBackwardsIsAFault() {
        let member = EventsDecisionsJSON.Member(eventID: "e", contentKey: "k", start: 5, end: 2)
        #expect(RowPreflight.violations(member: member) == ["member k: range start 5.0 is after its end 2.0"])
    }

    @Test func aMemberRangeWithOneEndIsAFault() {
        let member = EventsDecisionsJSON.Member(eventID: "e", contentKey: "k", start: 5, end: nil)
        #expect(RowPreflight.violations(member: member) == ["member k: a range needs both its start and its end"])
    }

    @Test func aNegativeIgnoredSizeIsAFault() {
        let entry = IgnoredContentJSON.Entry(id: "0A1B2C3D-0000-4000-8000-00000000CC01", partialMD5: nil, sizeBytes: -1,
                                             filename: nil, reason: nil, addedAt: nil, samplePath: nil)
        #expect(RowPreflight.violations(ignored: entry) == ["ignored entry size_bytes is negative (-1)"])
    }

    @Test func aNonPresentAuditResultWithoutAJudgedPathIsAFault() {
        let row = AuditMarkerJSON.Row(id: "r", result: "gone")
        #expect(RowPreflight.violations(auditRow: row) == ["audit result \"gone\" for r names no judged path — "
                                                            + "an audit marker from before 2026-10-17; run Audit Catalog with this build"])
    }

    @Test func aPresentAuditResultNeedsNoJudgedPath() {
        #expect(RowPreflight.violations(auditRow: AuditMarkerJSON.Row(id: "r", result: "present")).isEmpty)
    }

    @Test func theFixturesSidecarsHaveNoFault() throws {
        let fixture = PoisonedCatalogFixture()
        let events = try EventsDecisionsJSON.decode(try #require(fixture.sidecarData[PoisonedCatalogFixture.eventsFileName]))
        #expect(events.faults.isEmpty)
        let ignored = try IgnoredContentJSON.decode(try #require(fixture.sidecarData[PoisonedCatalogFixture.ignoredFileName]))
        #expect(ignored.faults.isEmpty)
        #expect(try AuditMarkerJSON.decode(fixture.auditData).faults.isEmpty)
    }
}
