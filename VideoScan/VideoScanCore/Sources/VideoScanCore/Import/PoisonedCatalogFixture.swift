// PoisonedCatalogFixture.swift
// A small catalog.json + catalog-audit.json + integrity-latest.json with one
// row per NAMED poisoned shape (brief deliverable 4), each shape built to land
// in one §f row. Used by the gate and comparator tests here and by the
// Mac-side importer tests later.
//
// Pure: `files` returns the bytes by file name; the caller writes them (the
// test helper `PoisonedCatalogFixture.write(to:)` lives in the test target),
// so this source file does no file I/O.
//
// Every row is a JSON object built by hand (never encoded from VideoRecord),
// so a key's absence or a poisoned value is exactly what the file says.
//
// (For Rick: a test-data factory — each `Shape` is one row the gate must
// put in a known place.)

import CryptoKit
import Foundation

public struct PoisonedCatalogFixture: Sendable {

    public enum Shape: String, CaseIterable, Sendable {
        case healthy
        case deadLink
        case neverSeen
        case sampledOnly
        case changedSize
        case duplicateIDFirst
        case duplicateIDSecond
        case disagreeingFixities
        case caseAliasUpper
        case caseAliasLower
        case supersessionCycleA
        case supersessionCycleB
        case referenceMovie
        case tombstonedWithDigest
        case curatedConflictA
        case curatedConflictB
        case stalePrint
    }

    /// Where a shape must land (§f): a reason code, or main (tombstoned or not).
    public struct Expected: Sendable, Equatable {
        public var reason: CatalogDDL.ReasonCode?
        public var tombstoned: Bool

        public static func quarantine(_ r: CatalogDDL.ReasonCode) -> Expected { Expected(reason: r, tombstoned: false) }
        public static let main = Expected(reason: nil, tombstoned: false)
        public static let tombstone = Expected(reason: nil, tombstoned: true)
    }

    public static func expected(_ shape: Shape) -> Expected {
        switch shape {
        case .healthy, .curatedConflictA, .curatedConflictB, .stalePrint: return .main
        case .deadLink: return .quarantine(.auditCouldNotCheck)
        case .neverSeen: return .quarantine(.auditNeverSeen)
        case .sampledOnly: return .quarantine(.noWholeFileDigest)
        case .changedSize: return .quarantine(.auditChanged)
        case .duplicateIDFirst, .duplicateIDSecond: return .quarantine(.duplicateId)
        case .disagreeingFixities: return .quarantine(.fixityDisagree)
        case .caseAliasUpper, .caseAliasLower: return .quarantine(.tier5Finding)
        case .supersessionCycleA, .supersessionCycleB: return .quarantine(.tier5Finding)
        case .referenceMovie: return .quarantine(.referenceMovie)
        case .tombstonedWithDigest: return .tombstone
        }
    }

    // MARK: - Clock and identity (fixed, so the bytes are deterministic)

    public static let generation = 41
    public static let auditStartedAt: Int64 = 1_790_000_000          // 2026-09-21T14:13:20Z
    public static let auditFinishedAt: Int64 = auditStartedAt + 3_600
    public static let integrityStartedAt: Int64 = auditFinishedAt + 600
    public static let seenAt: Int64 = auditStartedAt + 60
    public static let volumeUUID = "0A1B2C3D-0000-4000-8000-00000000F1F0"
    public static let auditFileName = "catalog-audit.json"
    public static let catalogFileName = "catalog.json"
    public static let integrityFileName = "integrity-latest.json"

    /// The row id of each shape (the duplicate pair shares one).
    public static func id(_ shape: Shape) -> String {
        let n: Int
        switch shape {
        case .duplicateIDSecond: n = Shape.allCases.firstIndex(of: .duplicateIDFirst) ?? 0
        default: n = Shape.allCases.firstIndex(of: shape) ?? 0
        }
        return String(format: "00000000-0000-4000-8000-%012ld", n + 1)
    }

    public static func path(_ shape: Shape) -> String {
        switch shape {
        case .caseAliasUpper: return "/Volumes/Fixture/Clips/Clip.mov"
        case .caseAliasLower: return "/Volumes/Fixture/Clips/clip.mov"
        default: return "/Volumes/Fixture/Clips/\(shape.rawValue).mov"
        }
    }

    /// A distinct 64-hex digest per label.
    public static func digest(_ label: String) -> String {
        SHA256.hash(data: Data(label.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public static let sizeBytes: Int64 = 4_096

    // MARK: - Built content

    /// Shapes in file order; ordinal = position. The bulk rows (scale) follow
    /// the 17 shapes as `.healthy`.
    public let order: [Shape]
    /// How many bulk healthy rows follow the shapes.
    public let bulkRows: Int
    public let catalogData: Data
    public let auditData: Data
    public let integrityData: Data
    /// The §f sidecars (events-decisions.json, ignored-content.json,
    /// media-ledger.jsonl, fullhash-backfill.json), by file name.
    public let sidecarData: [String: Data]

    public static let eventsFileName = CatalogDDL.ImportSourceFile.eventsDecisions.rawValue
    public static let ignoredFileName = CatalogDDL.ImportSourceFile.ignoredContent.rawValue
    public static let ledgerFileName = CatalogDDL.ImportSourceFile.mediaLedger.rawValue
    public static let backfillFileName = CatalogDDL.ImportSourceFile.fullHashBackfill.rawValue

    public var files: [String: Data] {
        var all = [Self.catalogFileName: catalogData, Self.auditFileName: auditData, Self.integrityFileName: integrityData]
        for (name, data) in sidecarData { all[name] = data }
        return all
    }

    public var catalogSHA256: String {
        SHA256.hash(data: catalogData).map { String(format: "%02x", $0) }.joined()
    }

    public func ordinals(of shape: Shape) -> [Int] {
        order.enumerated().filter { $0.element == shape }.map(\.offset)
    }

    /// The 17 shapes, then `healthyRows` distinct healthy rows (ids, paths
    /// and digests of their own; all `present` with a stamp in the window).
    public init(healthyRows: Int = 0) {
        let shapes = Shape.allCases
        order = shapes + Array(repeating: Shape.healthy, count: healthyRows)
        bulkRows = healthyRows
        var rows = shapes.map { Self.row(for: $0) }
        rows.reserveCapacity(shapes.count + healthyRows)
        for n in 0..<healthyRows { rows.append(Self.bulkRow(n)) }
        let catalog: CatalogJSONValue = .object([
            "version": .int(6),
            "generation": .int(Int64(Self.generation)),
            "savedAt": .string(Self.iso(Self.auditFinishedAt + 1)),
            "savedFromHost": .string("FixtureHost"),
            "records": .array(rows),
        ])
        let catalogBytes = (try? CatalogJSONValue.makeEncoder().encode(catalog)) ?? Data()
        catalogData = catalogBytes
        let sha = SHA256.hash(data: catalogBytes).map { String(format: "%02x", $0) }.joined()

        let encoder = CatalogJSONValue.makeEncoder()
        auditData = (try? encoder.encode(Self.auditMarker(bulkRows: healthyRows))) ?? Data()
        integrityData = (try? encoder.encode(Self.integrityReport(catalogSHA256: sha, byteCount: Int64(catalogBytes.count),
                                                                  rowCount: rows.count))) ?? Data()
        sidecarData = [
            Self.eventsFileName: (try? encoder.encode(Self.eventsDecisions())) ?? Data(),
            Self.ignoredFileName: (try? encoder.encode(Self.ignoredContent())) ?? Data(),
            Self.ledgerFileName: Data(Self.ledgerText().utf8),
            Self.backfillFileName: (try? encoder.encode(Self.backfillMarker())) ?? Data(),
        ]
    }

    // MARK: - Bulk rows (scale)

    public static func bulkID(_ n: Int) -> String { String(format: "00000000-0000-4000-8000-1%011ld", n) }
    public static func bulkPath(_ n: Int) -> String { "/Volumes/Fixture/Bulk/\(n / 1_000)/row-\(n).mov" }

    static func bulkRow(_ n: Int) -> CatalogJSONValue {
        let p = bulkPath(n)
        var o: [String: CatalogJSONValue] = [
            "id": .string(bulkID(n)),
            "filename": .string((p as NSString).lastPathComponent),
            "ext": .string("mov"),
            "fullPath": .string(p),
            "directory": .string((p as NSString).deletingLastPathComponent),
            "sizeBytes": .int(sizeBytes),
            "streamTypeRaw": .string("Video+Audio"),
            "lifecycleStage": .string("Cataloged"),
            "archiveStage": .string("None"),
            "scanContext": .object(["volumeUUID": .string(volumeUUID), "volumeName": .string("Fixture"),
                                    "scanHost": .string("FixtureHost")]),
            "contentFixity": contentFixity(digest("bulk-\(n)"), byteCount: sizeBytes),
            "auditSeenOn": auditSeenOn,
        ]
        if n % 10 == 0 { o["starRating"] = .int(Int64(n % 3 + 1)) }      // some curated values, for the counts
        if n % 25 == 0 { o["sceneCaptions"] = .array([.object(["timestamp": .int(1), "text": .string("bulk caption \(n)")])]) }
        return .object(o)
    }

    // MARK: - Rows

    static func iso(_ t: Int64) -> String { CatalogJSONDate(unixSeconds: t).text }

    private static func contentFixity(_ digest: String, byteCount: Int64) -> CatalogJSONValue {
        .object([
            "algorithm": .string("sha256"),
            "digest": .string(digest),
            "byteCount": .int(byteCount),
            "stamp": .object([
                "device": .int(16_777_220), "inode": .int(Int64(digest.utf8.count) * 1_000 + 7),
                "size": .int(byteCount), "mtimeNs": .int(1_700_000_000_000_000_000),
                "ctimeNs": .int(1_700_000_000_000_000_000), "volumeUUID": .string(volumeUUID),
            ]),
            "computedAt": .string(iso(auditStartedAt - 86_400)),
        ])
    }

    private static func archiveFixity(_ digest: String) -> CatalogJSONValue {
        .object([
            "algorithm": .string("sha256"), "digest": .string(digest),
            "verifiedAt": .string(iso(auditStartedAt - 7_200)), "sizeBytes": .int(sizeBytes),
        ])
    }

    private static var auditSeenOn: CatalogJSONValue {
        .object(["volumeUUID": .string(volumeUUID), "mountFrom": .string("/dev/disk9s1"),
                 "seenAt": .string(iso(seenAt))])
    }

    /// The two conflicting curated values on one shared digest (brief:
    /// "stars + user date on two copies with conflicting values").
    struct CuratedConflict: Sendable {
        let stars: Int64
        let userDate: String
        let confidence: String
        static let a = CuratedConflict(stars: 2, userDate: "1991", confidence: "estimated")
        static let b = CuratedConflict(stars: 3, userDate: "1992-06", confidence: "known")
    }

    static func row(for shape: Shape) -> CatalogJSONValue {
        var o = baseRow(shape)
        if poison(shape, into: &o) {
            o["contentFixity"] = contentFixity(digest(shape.rawValue), byteCount: sizeBytes)
        }
        if seesStamp(shape) { o["auditSeenOn"] = auditSeenOn }
        return .object(o)
    }

    /// The healthy row every shape starts from: identity, disk facts, scan context.
    private static func baseRow(_ shape: Shape) -> [String: CatalogJSONValue] {
        let p = path(shape)
        return [
            "id": .string(id(shape)),
            "filename": .string((p as NSString).lastPathComponent),
            "ext": .string("mov"),
            "fullPath": .string(p),
            "directory": .string((p as NSString).deletingLastPathComponent),
            "sizeBytes": .int(sizeBytes),
            "streamTypeRaw": .string("Video+Audio"),
            "lifecycleStage": .string("Cataloged"),
            "archiveStage": .string("None"),
            "scanContext": .object(["volumeUUID": .string(volumeUUID), "volumeName": .string("Fixture"),
                                    "scanHost": .string("FixtureHost")]),
        ]
    }

    /// What is poisoned about the shape — the keys whose value or absence
    /// send it to its §f row. Returns true when the row still gets its own
    /// agreeing whole-file fixity (a shape that sets its own, or none, says no).
    private static func poison(_ shape: Shape, into o: inout [String: CatalogJSONValue]) -> Bool {
        switch shape {
        case .deadLink:
            // A curated value on a row that cannot enter `files` (§10b: it
            // goes to quarantine WITH its curated fields — the TRUTH test).
            o["starRating"] = .int(3)
            return true
        case .sampledOnly:
            o["contentHash"] = .string("v1:" + String(digest("sampled").prefix(32)))
            o["partialMD5"] = .string("d41d8cd98f00b204e9800998ecf8427e")
            return false
        case .changedSize:
            o["sizeBytes"] = .int(sizeBytes * 2)   // the fixity covers the old size: no identity
            o["contentFixity"] = contentFixity(digest(shape.rawValue), byteCount: sizeBytes)
            return false
        case .disagreeingFixities:
            o["contentFixity"] = contentFixity(digest("disagree-content"), byteCount: sizeBytes)
            o["archiveFixity"] = archiveFixity(digest("disagree-archive"))
            return false
        case .curatedConflictA:
            curate(&o, .a)
            return false
        case .curatedConflictB:
            curate(&o, .b)
            return false
        case .duplicateIDSecond:
            o["contentFixity"] = contentFixity(digest(Shape.duplicateIDFirst.rawValue), byteCount: sizeBytes)
            return false
        case .supersessionCycleA:
            o["supersededByID"] = .string(id(.supersessionCycleB))
            o["repairConfirmedDate"] = .string(iso(auditStartedAt - 3_600))
            return true
        case .supersessionCycleB:
            o["supersededByID"] = .string(id(.supersessionCycleA))
            return true
        case .stalePrint:
            // The one row that names an A/V pair, so an event member keyed
            // `pair:<pairGroupID>` has a half to resolve to (F9).
            o["pairGroupID"] = .string(pairGroupID)
            o["pairedWithID"] = .string(id(.healthy))
            o["pairConfidence"] = .string("High")
            return true
        case .tombstonedWithDigest:
            o["lifecycleStage"] = .string("Trashed")
            o["removal"] = .object(["state": .string("inTrash"), "since": .string(iso(auditStartedAt - 600)),
                                    "reason": .string("catalogTrash"),
                                    "trashPath": .string("/Volumes/Fixture/.Trashes/501/tombstonedWithDigest.mov")])
            o["removalRevision"] = .int(1)
            return true
        default:
            return true
        }
    }

    /// One of the two conflicting copies: the shared digest plus its curated values.
    private static func curate(_ o: inout [String: CatalogJSONValue], _ c: CuratedConflict) {
        o["contentFixity"] = contentFixity(digest("curated-shared"), byteCount: sizeBytes)
        o["starRating"] = .int(c.stars)
        o["userDate"] = .string(c.userDate)
        o["userDateConfidence"] = .string(c.confidence)
    }

    /// The row carries an `auditSeenOn` inside the audit window.
    private static func seesStamp(_ shape: Shape) -> Bool {
        switch shape {
        case .neverSeen, .deadLink, .changedSize, .tombstonedWithDigest: return false
        default: return true
        }
    }

    // MARK: - Audit marker (contract §c / §f shape)

    /// The app's own detail for a row made not provable by a link in its
    /// path (VideoScanModel+CatalogAudit.swift + CatalogAuditPlan.swift).
    public static let deadLinkDetail = "not at its path, but that is not proof here: a link in the path — not provable — not marked"

    /// The marker in the app's words (`CatalogAuditResult.rawValue`).
    static func auditMarker(bulkRows: Int = 0) -> AuditMarkerJSON {
        var rows: [AuditMarkerJSON.Row] = []
        rows.reserveCapacity(Shape.allCases.count + bulkRows)
        var seen = Set<String>()
        for n in 0..<bulkRows { rows.append(.init(id: bulkID(n), result: "present")) }
        for shape in Shape.allCases {
            let rowID = id(shape)
            guard seen.insert(rowID).inserted else { continue }   // one answer per id
            switch shape {
            case .neverSeen:
                continue
            case .deadLink:
                rows.append(.init(id: rowID, result: "couldNotCheck", detail: deadLinkDetail, judgedPath: path(shape)))
            case .changedSize:
                rows.append(.init(id: rowID, result: "changed", detail: "size differs", judgedPath: path(shape)))
            case .tombstonedWithDigest:
                rows.append(.init(id: rowID, result: "gone", detail: "in the Trash", judgedPath: path(shape)))
            default:
                rows.append(.init(id: rowID, result: "present"))
            }
        }
        var counts: [String: Int] = [:]
        for r in rows { counts[r.result, default: 0] += 1 }
        return AuditMarkerJSON(startedAt: CatalogJSONDate(unixSeconds: auditStartedAt),
                               finishedAt: CatalogJSONDate(unixSeconds: auditFinishedAt),
                               outcome: "completed", partial: false, counts: counts, marked: 0,
                               rows: rows, savedGeneration: generation)
    }

    // MARK: - Sidecars (contract §c), small and deterministic

    public static let pairGroupID = "0A1B2C3D-0000-4000-8000-00000000AA11"
    public static let eventOneID = "0A1B2C3D-0000-4000-8000-00000000EE01"
    public static let eventTwoID = "0A1B2C3D-0000-4000-8000-00000000EE02"
    public static let unknownEventID = "0A1B2C3D-0000-4000-8000-00000000EE03"

    /// Two events; nine decisions in the stream, every kind the app writes
    /// plus one from a newer build. The fold yields THREE members (the
    /// deadLink one is accepted then rejected) and ONE key that cannot
    /// resolve (`id:` of the row with no digest).
    public static func eventsDecisions() -> CatalogJSONValue {
        func member(_ event: String, _ key: String, _ verdict: String) -> CatalogJSONValue {
            .object(["kind": .string("member"), "eventID": .string(event), "range": .object(["contentKey": .string(key)]),
                     "verdict": .string(verdict)])
        }
        let events: [CatalogJSONValue] = [
            .object(["id": .string(eventOneID), "name": .string("Matt's birthday"), "categories": .array([.string("birthday")]),
                     "state": .string("confirmed"), "createdAt": .string(iso(auditStartedAt - 9_000)),
                     "updatedAt": .string(iso(auditStartedAt - 8_000)), "note": .string("the cake")]),
            .object(["id": .string(eventTwoID), "name": .string("Lake day"), "categories": .array([]),
                     "state": .string("dismissed"), "createdAt": .string(iso(auditStartedAt - 7_000)),
                     "updatedAt": .string(iso(auditStartedAt - 7_000))]),
        ]
        let decisions: [CatalogJSONValue] = [
            member(eventOneID, digest(Shape.healthy.rawValue), "accepted"),
            member(eventOneID, "id:" + id(.sampledOnly), "accepted"),
            member(eventOneID, "pair:" + pairGroupID, "accepted"),
            member(eventOneID, digest(Shape.deadLink.rawValue), "accepted"),
            member(eventOneID, digest(Shape.deadLink.rawValue), "rejected"),
            .object(["kind": .string("differentOccasions"), "a": .object(["contentKey": .string(digest(Shape.healthy.rawValue))]),
                     "b": .object(["contentKey": .string(digest(Shape.deadLink.rawValue))])]),
            .object(["kind": .string("merged"), "from": .string(unknownEventID), "into": .string(eventOneID)]),
            .object(["kind": .string("futureKind"), "note": .string("written by a newer build")]),
            member(eventTwoID, digest("curated-shared"), "accepted"),
        ]
        return .object(["storeVersion": .int(1), "savedAt": .string(iso(auditStartedAt - 6_000)),
                        "events": .array(events), "decisions": .array(decisions)])
    }

    public static func ignoredContent() -> CatalogJSONValue {
        .object(["storeVersion": .int(1), "savedAt": .string(iso(auditStartedAt - 5_000)), "entries": .array([
            .object(["id": .string("0A1B2C3D-0000-4000-8000-00000000CC01"), "partialMD5": .string("d41d8cd98f00b204e9800998ecf8427e"),
                     "sizeBytes": .int(4_096), "filename": .string("junk.mov"), "reason": .string("junk"),
                     "addedAt": .string(iso(auditStartedAt - 4_000)), "samplePath": .string("/Volumes/Fixture/Junk/junk.mov")]),
            .object(["id": .string("0A1B2C3D-0000-4000-8000-00000000CC02"), "partialMD5": .string(""),
                     "sizeBytes": .int(99), "filename": .string("slate.mov"), "reason": .string("removed-by-user"),
                     "addedAt": .string(iso(auditStartedAt - 3_000)), "samplePath": .string("/Volumes/Fixture/Junk/slate.mov")]),
        ])])
    }

    /// Three JSON lines (one names a row with a digest, one a row without,
    /// one a high-water line with no record) and one torn line.
    public static func ledgerText() -> String {
        func line(_ event: String, _ rowID: String, _ path: String) -> String {
            let o: CatalogJSONValue = .object(["at": .string(iso(auditStartedAt - 2_000) ), "event": .string(event),
                                               "recordID": .string(rowID), "contentKey": .string(""), "filename": .string(""),
                                               "fullPath": .string(path), "by": .string("rick"), "detail": .object([:])])
            return o.canonicalText()
        }
        return [
            line("dateSet", id(.healthy), path(.healthy)),
            line("setAside", id(.sampledOnly), path(.sampledOnly)),
            CatalogJSONValue.object(["kind": .string("generationHighWater"), "intended": .int(42)]).canonicalText(),
            "{\"at\":\"2026-",
        ].joined(separator: "\n")                       // no newline after the torn line: a torn append (codex D′ #5)
    }

    public static func backfillMarker() -> CatalogJSONValue {
        .object(["startedAt": .string(iso(auditStartedAt - 90_000)), "finishedAt": .string(iso(auditStartedAt - 80_000)),
                 "hashedSoFar": .int(12)])
    }

    // MARK: - Integrity report (schema 2)

    /// The tier-5 / tier-4 findings the shapes carry.
    public static func findings() -> [ImportGate.Finding] {
        [
            .init(tier: 5, rule: "pathAliasByCase", recordID: id(.caseAliasUpper),
                  words: "two rows name one file by case on a case-insensitive volume", needsDecision: true),
            .init(tier: 5, rule: "pathAliasByCase", recordID: id(.caseAliasLower),
                  words: "two rows name one file by case on a case-insensitive volume", needsDecision: true),
            .init(tier: 5, rule: "supersessionCycle", recordID: id(.supersessionCycleA),
                  words: "repairs supersede each other in a circle", needsDecision: true),
            .init(tier: 5, rule: "supersessionCycle", recordID: id(.supersessionCycleB),
                  words: "repairs supersede each other in a circle", needsDecision: true),
            .init(tier: 5, rule: ImportGate.referenceMovieRule, recordID: id(.referenceMovie),
                  words: "a reference movie: its media live in other files", needsDecision: true),
            .init(tier: 4, rule: "derivedStampsMatchContent", recordID: id(.stalePrint),
                  words: "the sound print was made for other bytes", needsDecision: true),
        ]
    }

    static func integrityReport(catalogSHA256: String, byteCount: Int64, rowCount: Int) -> IntegrityReportJSON {
        let f = findings()
        let tiers: [IntegrityReportJSON.Tier] = (0...6).map { (t) -> IntegrityReportJSON.Tier in
            let n = f.filter { $0.tier == t }.count
            return IntegrityReportJSON.Tier(
                tier: t, name: "tier\(t)", verifiedAt: CatalogJSONDate(unixSeconds: integrityStartedAt + 60),
                runID: "11111111-0000-4000-8000-000000000001",
                result: n == 0 ? .init(kind: "ok") : .init(kind: "needsDecision", count: n),
                checked: rowCount, passed: rowCount - n, needsDecision: n, couldNotCheck: 0,
                elapsedSeconds: 1, summary: n == 0 ? "ok" : "\(n) need a decision")
        }
        return IntegrityReportJSON(
            runID: "11111111-0000-4000-8000-000000000001",
            startedAt: CatalogJSONDate(unixSeconds: integrityStartedAt),
            verifiedAt: CatalogJSONDate(unixSeconds: integrityStartedAt + 120),
            outcome: "completed", catalogFile: catalogFileName,
            snapshotGeneration: generation, catalogGeneration: generation,
            catalogSHA256: catalogSHA256, catalogByteCount: byteCount, catalogHashCertified: true,
            rowsTotal: rowCount, rowsLive: rowCount, tiers: tiers, findings: f, findingsTotal: f.count)
    }
}
