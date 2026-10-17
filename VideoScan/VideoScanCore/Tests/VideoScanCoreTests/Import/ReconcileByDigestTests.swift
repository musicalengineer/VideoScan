// ReconcileByDigestTests.swift
// The §g decision table, one test per row, plus Step B's rules: a row with
// findings is never resolved by a byte match, the two digest-less presence
// reasons are never resolved automatically, and the resolution kind follows
// whether a main row already carried the digest. One condition per #expect.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("ReconcileByDigest — §g as a function")
struct ReconcileByDigestTests {

    private static let digest = String(repeating: "a", count: 64)
    private static let other = String(repeating: "b", count: 64)
    private static let volume = "11111111-1111-1111-1111-111111111111"

    private static func found(stillBeingWritten: Bool = false, linkInPath: Bool = false) -> ReconcileByDigest.Found {
        ReconcileByDigest.Found(digest: digest, volumeUUID: volume, path: "/Volumes/A/new.mov",
                                stillBeingWritten: stillBeingWritten, linkInPath: linkInPath)
    }

    private static func main(_ id: String, digest: String = ReconcileByDigestTests.digest, path: String = "/Volumes/A/old.mov",
                             gone: Bool = false) -> ReconcileByDigest.MainRow {
        ReconcileByDigest.MainRow(fileID: id, digest: digest, volumeUUID: volume, path: path, provenGone: gone)
    }

    private static func quarantined(_ qid: Int64, _ reason: CatalogDDL.ReasonCode, findings: Bool = false,
                                    jsonRowID: String? = nil, usable: Bool = false) -> ReconcileByDigest.QuarantineRow {
        ReconcileByDigest.QuarantineRow(qid: qid, reason: reason, hasFindings: findings, jsonRowID: jsonRowID, jsonRowIDUsable: usable)
    }

    @Test func aFileStillBeingWrittenIsDeferredNeverARow() {
        let action = ReconcileByDigest.decide(found: Self.found(stillBeingWritten: true),
                                              existing: .init(quarantined: [Self.quarantined(1, .auditGone)]))
        #expect(action == .deferred(ReconcileByDigest.StillBeingWritten(path: "/Volumes/A/new.mov")))
    }

    @Test func aLinkInThePathIsRefused() {
        #expect(ReconcileByDigest.decide(found: Self.found(linkInPath: true), existing: .init()) == .refusedLinkInPath)
    }

    @Test func theSameBytesAtTheSamePathRefreshInPlace() {
        let row = Self.main("F1", path: "/Volumes/A/new.mov")
        let action = ReconcileByDigest.decide(found: Self.found(), existing: .init(atPath: row, withDigest: [row]))
        #expect(action == .reconciled(file: .refreshInPlace(fileID: "F1"), resolved: [], findingsStillOpen: []))
    }

    @Test func otherBytesAtTheSamePathReplaceTheRow() {
        let row = Self.main("F1", digest: Self.other, path: "/Volumes/A/new.mov")
        let action = ReconcileByDigest.decide(found: Self.found(), existing: .init(atPath: row))
        #expect(action == .reconciled(file: .replaceAtPath(oldFileID: "F1"), resolved: [], findingsStillOpen: []))
    }

    @Test func aKnownDigestWhoseOneRowIsProvenGoneMovesThatRow() {
        let action = ReconcileByDigest.decide(found: Self.found(), existing: .init(withDigest: [Self.main("F1", gone: true)]))
        #expect(action == .reconciled(file: .updatePath(fileID: "F1"), resolved: [], findingsStillOpen: []))
    }

    @Test func aKnownDigestWhoseRowIsStillPresentIsACopy() {
        let action = ReconcileByDigest.decide(found: Self.found(), existing: .init(withDigest: [Self.main("F1")]))
        #expect(action == .reconciled(file: .newCopyRow, resolved: [], findingsStillOpen: []))
    }

    @Test func aKnownDigestWithSeveralRowsGoneIsACopyLeftToTheAudit() {
        let action = ReconcileByDigest.decide(found: Self.found(),
                                              existing: .init(withDigest: [Self.main("F1", gone: true), Self.main("F2", path: "/Volumes/A/two.mov", gone: true)]))
        #expect(action == .reconciled(file: .newCopyRow, resolved: [], findingsStillOpen: []))
    }

    @Test func aDigestKnownOnlyFromQuarantineBecomesANewRowAndResolvesIt() {
        let id = "00000000-0000-4000-8000-000000000007"
        let action = ReconcileByDigest.decide(found: Self.found(),
                                              existing: .init(quarantined: [Self.quarantined(9, .auditGone, jsonRowID: id, usable: true)]))
        #expect(action == .reconciled(file: .newRow(id: .jsonRowID(id)),
                                      resolved: [.init(qid: 9, kind: .foundByDigest)], findingsStillOpen: []))
    }

    @Test func aQuarantinedRowWhoseIdIsTakenGetsAFreshId() {
        let action = ReconcileByDigest.decide(found: Self.found(),
                                              existing: .init(quarantined: [Self.quarantined(9, .auditNeverSeen, jsonRowID: "X", usable: false)]))
        #expect(action == .reconciled(file: .newRow(id: .fresh), resolved: [.init(qid: 9, kind: .foundByDigest)], findingsStillOpen: []))
    }

    @Test func aNewDigestIsANewRowWithNoKnowledge() {
        #expect(ReconcileByDigest.decide(found: Self.found(), existing: .init())
                == .reconciled(file: .newRow(id: .fresh), resolved: [], findingsStillOpen: []))
    }

    @Test func aMainRowAndAQuarantinedRowSharingTheDigestResolveAsCopy() {
        let action = ReconcileByDigest.decide(found: Self.found(),
                                              existing: .init(withDigest: [Self.main("F1")], quarantined: [Self.quarantined(3, .auditCouldNotCheck)]))
        #expect(action == .reconciled(file: .newCopyRow, resolved: [.init(qid: 3, kind: .resolvedAsCopy)], findingsStillOpen: []))
    }

    @Test func aRowWithFindingsStaysOpenAfterAByteMatch() {
        let action = ReconcileByDigest.decide(found: Self.found(),
                                              existing: .init(quarantined: [Self.quarantined(4, .auditGone, findings: true)]))
        #expect(action == .reconciled(file: .newRow(id: .fresh), resolved: [], findingsStillOpen: [4]))
    }

    @Test("finding reasons never resolve by a byte match",
          arguments: [CatalogDDL.ReasonCode.tier5Finding, .referenceMovie, .fixityDisagree, .duplicateId, .auditChanged])
    func findingReasonsStayOpen(reason: CatalogDDL.ReasonCode) {
        let action = ReconcileByDigest.decide(found: Self.found(), existing: .init(quarantined: [Self.quarantined(5, reason)]))
        #expect(action == .reconciled(file: .newRow(id: .fresh), resolved: [], findingsStillOpen: [5]))
    }

    @Test("digest-less presence reasons are a person's call",
          arguments: [CatalogDDL.ReasonCode.noWholeFileDigest, .removedNoDigest])
    func digestlessPresenceReasonsAreNeverAutomatic(reason: CatalogDDL.ReasonCode) {
        #expect(!ReconcileByDigest.resolvesByByteMatch(reason))
    }
}
