// BackupAttestationTests.swift
// LOGIC for the backup-attestation model (Rick 2026-09-12, promote-and-
// prune stage 1): Codable shape, latest-per-kind, the inheritance merge
// rule, the manifest JSON codec, the summary tokens, the ProtectionSummary
// display line (including the design's exact example), the batch combine
// rules, the VideoRecord DTO round trip, and a SCALE pin for summarizing
// 100k copies in 5k families.

import XCTest
@testable import VideoScanCore

final class BackupAttestationTests: XCTestCase {

    private func t(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }
    private func a(_ kind: BackupAttestation.Kind, _ answer: BackupAttestation.Answer,
                   _ label: String? = nil, at: TimeInterval = 1_757_700_000, by: String = "rick") -> BackupAttestation {
        BackupAttestation(kind: kind, answer: answer, label: label, attestedAt: t(at), by: by)
    }

    // MARK: Model + Codable

    func testInitTrimsLabelAndEmptyLabelBecomesNil() {
        XCTAssertEqual(a(.cloud, .yes, "  iCloud ").label, "iCloud")
        XCTAssertNil(a(.cloud, .yes, "   ").label)
        XCTAssertNil(a(.cloud, .yes, nil).label)
    }

    func testTokensAndJournalLine() {
        XCTAssertEqual(a(.cloud, .yes, "iCloud").token, "cloud=yes 'iCloud'")
        XCTAssertEqual(a(.offsite, .no).token, "offsite=no")
        XCTAssertEqual(a(.offsite, .notApplicable).token, "offsite=n/a")
        XCTAssertEqual(a(.cloud, .yes, "iCloud").journalLine, "attestation cloud=yes 'iCloud' by rick")
        XCTAssertEqual(BackupAttestation.Kind.offsite.displayName, "off-site")
    }

    func testCodableRoundTripAndLabelKeyOmittedWhenNil() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let with = a(.cloud, .yes, "iCloud")
        let without = a(.offsite, .no)
        let withText = String(decoding: try enc.encode(with), as: UTF8.self)
        let withoutText = String(decoding: try enc.encode(without), as: UTF8.self)
        XCTAssertTrue(withText.contains("\"label\":\"iCloud\""))
        XCTAssertFalse(withoutText.contains("label"), withoutText)
        XCTAssertEqual(try dec.decode(BackupAttestation.self, from: Data(withText.utf8)), with)
        XCTAssertEqual(try dec.decode(BackupAttestation.self, from: Data(withoutText.utf8)), without)
        // A line without `by` (a future writer, or a hand edit) decodes as rick's.
        let noBy = "{\"answer\":\"no\",\"attestedAt\":\"2026-09-12T20:00:00Z\",\"kind\":\"drive\"}"
        XCTAssertEqual(try dec.decode(BackupAttestation.self, from: Data(noBy.utf8)).by, "rick")
    }

    // MARK: latest per kind / merge / replace

    func testLatestPerKindLaterAttestedAtWinsAndTieIsConservativeNotPositional() {
        let older = a(.cloud, .no, at: 100)
        let newer = a(.cloud, .yes, "iCloud", at: 200)
        XCTAssertEqual(BackupAttestation.latestPerKind([newer, older])[.cloud], newer)
        XCTAssertEqual(BackupAttestation.latestPerKind([older, newer])[.cloud], newer)
        // Exact tie: the conservative answer wins in EITHER order (codex #1430).
        let tieNo = a(.offsite, .no, at: 300), tieYes = a(.offsite, .yes, "Tim's", at: 300)
        XCTAssertEqual(BackupAttestation.latestPerKind([tieNo, tieYes])[.offsite], tieNo)
        XCTAssertEqual(BackupAttestation.latestPerKind([tieYes, tieNo])[.offsite], tieNo)
        XCTAssertTrue(BackupAttestation.latestPerKind([]).isEmpty)
    }

    func testMergeUnionByKindLatestWinsBaseWinsTiesAndNoIsNeverDropped() {
        let baseCloudOld = a(.cloud, .no, at: 100)
        let incomingCloudNew = a(.cloud, .yes, "iCloud", at: 200)
        let incomingOffsiteNA = a(.offsite, .notApplicable, at: 150)
        let merged = BackupAttestation.merged([baseCloudOld], with: [incomingCloudNew, incomingOffsiteNA])
        XCTAssertEqual(merged, [incomingCloudNew, incomingOffsiteNA], "union by kind, latest wins, kind order")

        // Base keeps a newer answer.
        let baseNewer = a(.cloud, .no, at: 300)
        XCTAssertEqual(BackupAttestation.merged([baseNewer], with: [incomingCloudNew]), [baseNewer])
        // Exact tie: the conservative answer (the base's "no") wins — and
        // would from the other side too (see testEqualTimePolicy…).
        let tieIn = a(.cloud, .yes, at: 300)
        XCTAssertEqual(BackupAttestation.merged([baseNewer], with: [tieIn]), [baseNewer])
        XCTAssertEqual(BackupAttestation.merged([tieIn], with: [baseNewer]), [baseNewer])
        // A "no" on one side vs nothing on the other is KEPT, both directions.
        XCTAssertEqual(BackupAttestation.merged([], with: [baseNewer]), [baseNewer])
        XCTAssertEqual(BackupAttestation.merged([baseNewer], with: []), [baseNewer])
        // Idempotent.
        XCTAssertEqual(BackupAttestation.merged(merged, with: merged), merged)
        // Kind order regardless of input order.
        let drive = a(.drive, .yes, "MyBook", at: 50)
        XCTAssertEqual(BackupAttestation.merged([drive], with: [incomingOffsiteNA, incomingCloudNew]).map(\.kind),
                       [.cloud, .offsite, .drive])
    }

    func testReplacingSwapsSameKindKeepsOthers() {
        let list = [a(.cloud, .no, at: 100), a(.offsite, .no, at: 100)]
        let out = BackupAttestation.replacing(list, with: a(.cloud, .yes, "iCloud", at: 50))
        XCTAssertEqual(out.map(\.token), ["cloud=yes 'iCloud'", "offsite=no"], "a NEW answer replaces even an older date")
    }

    // MARK: Manifest JSON codec

    func testJSONStringRoundTripEmptyAndMalformed() {
        let list = [a(.cloud, .yes, "O'Neil, \"Cloud\""), a(.offsite, .no, at: 1_757_700_100)]
        let text = BackupAttestation.jsonString(list)
        XCTAssertTrue(text.hasPrefix("[{"), text)
        XCTAssertTrue(text.contains("\"attestedAt\":\"2025-09-12T18:00:00.000Z\""),
                      "millisecond ISO-8601 dates, the Timestamp rule (epoch 1_757_700_000): \(text)")
        XCTAssertEqual(BackupAttestation.fromJSONString(text), list)
        XCTAssertEqual(BackupAttestation.jsonString(text == "" ? [] : []), "", "empty list → empty cell, never []")
        XCTAssertEqual(BackupAttestation.fromJSONString(""), [])
        XCTAssertEqual(BackupAttestation.fromJSONString("   "), [])
        XCTAssertEqual(BackupAttestation.fromJSONString("not json"), [])
        XCTAssertEqual(BackupAttestation.fromJSONString("[{\"kind\":\"moon\"}]"), [], "unknown kind → nothing, never a throw")
        // Byte-stable for the same list (sorted keys) — the manifest is diffable.
        XCTAssertEqual(BackupAttestation.jsonString(list), text)
        // Duplicates collapse to the latest per kind on the way out.
        let dup = [a(.cloud, .no, at: 1), a(.cloud, .yes, at: 2)]
        XCTAssertEqual(BackupAttestation.fromJSONString(BackupAttestation.jsonString(dup)), [a(.cloud, .yes, at: 2)])
    }

    func testSummaryString() {
        XCTAssertEqual(BackupAttestation.summary([]), "")
        XCTAssertEqual(BackupAttestation.summary([a(.offsite, .no), a(.cloud, .yes, "iCloud")]),
                       "cloud=yes 'iCloud'; offsite=no")
    }

    // MARK: VideoRecord

    func testRecordInheritanceReportsChange() {
        let source = VideoRecord(); source.backupAttestations = [a(.cloud, .yes, "iCloud")]
        let target = VideoRecord()
        XCTAssertTrue(target.inheritBackupAttestations(from: source))
        XCTAssertEqual(target.backupAttestations, source.backupAttestations)
        XCTAssertFalse(target.inheritBackupAttestations(from: source), "second pass changes nothing")
        XCTAssertFalse(VideoRecord().inheritBackupAttestations(from: VideoRecord()))
        XCTAssertEqual(target.backupAttestation(for: .cloud)?.label, "iCloud")
        XCTAssertNil(target.backupAttestation(for: .offsite))
    }

    func testDTORoundTripAndKeyOmittedWhenEmpty() throws {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.sortedKeys]
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let bare = VideoRecord(); bare.filename = "bare.mov"
        XCTAssertFalse(String(decoding: try enc.encode(VideoRecordDTO(bare)), as: UTF8.self).contains("backupAttestations"))
        let attested = VideoRecord(); attested.filename = "att.mov"
        attested.backupAttestations = [a(.cloud, .yes, "iCloud"), a(.offsite, .notApplicable)]
        let data = try enc.encode(VideoRecordDTO(attested))
        let back = try dec.decode(VideoRecord.self, from: data)
        XCTAssertEqual(back.backupAttestations, attested.backupAttestations)
        XCTAssertEqual(attested.snapshotClone().backupAttestations, attested.backupAttestations, "clone carries them")
    }

    // MARK: ProtectionSummary — the line

    private func copy(_ volume: String, online: Bool = true, archive: Bool = false, verified: Bool = false,
                      _ atts: [BackupAttestation] = []) -> ProtectionSummary.CopyFacts {
        ProtectionSummary.CopyFacts(volumeName: volume, isOnline: online, isArchiveCopy: archive,
                                    fixityVerified: verified, attestations: atts)
    }

    func testDisplayLineMatchesTheDesignExampleExactly() {
        let family = [copy("FamilyArchive", archive: true, verified: true), copy("Projects"), copy("LaCie")]
        let s = ProtectionSummary.summarize(family: family)
        XCTAssertEqual(s.displayLine, "Archive ✓verified · 2 working copies (LaCie, Projects) · cloud: none · off-site: none")
        XCTAssertEqual(s.archive, .verified)
        XCTAssertEqual(s.workingCopyCount, 2)
        XCTAssertEqual(s.familyCount, 1)
    }

    func testDisplayLineVariants() {
        XCTAssertEqual(ProtectionSummary.summarize(family: [copy("X", archive: true, verified: false), copy("LaCie")]).displayLine,
                       "Archive unverified · 1 working copy (LaCie) · cloud: none · off-site: none")
        XCTAssertEqual(ProtectionSummary.summarize(family: [copy("LaCie")]).displayLine,
                       "Archive none · 1 working copy (LaCie) · cloud: none · off-site: none")
        XCTAssertEqual(ProtectionSummary.summarize(family: [copy("X", archive: true, verified: true)]).displayLine,
                       "Archive ✓verified · no working copies · cloud: none · off-site: none")
        // Offline volumes are named as such; a volume with any online copy is online.
        let s = ProtectionSummary.summarize(family: [copy("X", archive: true, verified: true),
                                                     copy("MyBook", online: false), copy("LaCie"),
                                                     copy("LaCie", online: false)])
        XCTAssertEqual(s.displayLine, "Archive ✓verified · 3 working copies (LaCie, MyBook offline) · cloud: none · off-site: none")
        // Attestations: yes with a label shows the label; yes/no/n-a otherwise; drive only when attested.
        let atts = [a(.cloud, .yes, "iCloud"), a(.offsite, .notApplicable), a(.drive, .yes, "MyBook")]
        let t = ProtectionSummary.summarize(family: [copy("X", archive: true, verified: true), copy("LaCie", atts)])
        XCTAssertEqual(t.displayLine, "Archive ✓verified · 1 working copy (LaCie) · cloud: iCloud · off-site: n/a · drive: MyBook")
        let u = ProtectionSummary.summarize(family: [copy("LaCie", [a(.cloud, .yes), a(.offsite, .no)])])
        XCTAssertEqual(u.displayLine, "Archive none · 1 working copy (LaCie) · cloud: yes · off-site: no")
        XCTAssertEqual(ProtectionSummary.summarize(family: [copy("", archive: false)]).displayLine,
                       "Archive none · 1 working copy (unnamed) · cloud: none · off-site: none")
        XCTAssertEqual(ProtectionSummary.summarize(family: []), .empty)
        XCTAssertEqual(ProtectionSummary.empty.displayLine, "Archive none · no working copies · cloud: none · off-site: none")
    }

    func testBatchCombineRules() {
        let verifiedA = [copy("X", archive: true, verified: true), copy("LaCie", [a(.cloud, .yes, "iCloud")])]
        let verifiedB = [copy("X", archive: true, verified: true), copy("Projects", [a(.cloud, .yes, "iCloud")])]
        let s = ProtectionSummary.summarize(families: [verifiedA, verifiedB])
        XCTAssertEqual(s.displayLine, "Archive ✓verified · 2 working copies (LaCie, Projects) · cloud: iCloud · off-site: none")
        XCTAssertEqual(s.familyCount, 2)
        // One family without an archive copy → the batch is not archived.
        XCTAssertEqual(ProtectionSummary.summarize(families: [verifiedA, [copy("LaCie")]]).archive, .none)
        // One unverified → unverified.
        XCTAssertEqual(ProtectionSummary.summarize(families: [verifiedA, [copy("X", archive: true)]]).archive, .unverified)
        // Same answer, different labels → the answer without a label.
        let otherLabel = [copy("X", archive: true, verified: true), copy("LaCie", [a(.cloud, .yes, "Dropbox")])]
        XCTAssertEqual(ProtectionSummary.summarize(families: [verifiedA, otherLabel]).cloud, .answer(.yes, label: nil))
        XCTAssertEqual(ProtectionSummary.summarize(families: [verifiedA, otherLabel]).displayLine,
                       "Archive ✓verified · 2 working copies (LaCie) · cloud: yes · off-site: none")
        // Different answers → mixed; an attested family beside an unattested one → mixed too.
        let no = [copy("X", archive: true, verified: true), copy("LaCie", [a(.cloud, .no)])]
        XCTAssertEqual(ProtectionSummary.summarize(families: [verifiedA, no]).cloud, .mixed)
        XCTAssertEqual(ProtectionSummary.summarize(families: [verifiedA, [copy("LaCie")]]).cloud, .mixed)
        XCTAssertTrue(ProtectionSummary.summarize(families: [verifiedA, no]).displayLine.contains("cloud: mixed"))
        // Empty families are ignored; all-empty → .empty.
        XCTAssertEqual(ProtectionSummary.summarize(families: [[], []]), .empty)
        XCTAssertEqual(ProtectionSummary.summarize(families: [[], verifiedA]).familyCount, 1)
    }

    // MARK: SCALE — 100k copies in 5k families, summarized per batch

    func testScaleSummarize100kCopiesIn5kFamiliesUnderBudget() {
        // 5,000 families × 20 copies (1 verified archive copy + 19 working
        // copies spread over 6 volumes, every 7th offline, every 3rd family
        // attested). ~100k CopyFacts ≈ 15 MB transient — see the type's
        // memory note.
        let volumes = ["LaCie", "Projects", "MyBook", "X9", "X10", "Movies"]
        var families: [[ProtectionSummary.CopyFacts]] = []
        families.reserveCapacity(5_000)
        for f in 0..<5_000 {
            var fam: [ProtectionSummary.CopyFacts] = [copy("FamilyArchive", archive: true, verified: true)]
            for c in 0..<19 {
                let atts = (f % 3 == 0 && c == 0) ? [a(.cloud, .yes, "iCloud"), a(.offsite, .no)] : []
                fam.append(copy(volumes[(f + c) % volumes.count], online: (f + c) % 7 != 0, atts))
            }
            families.append(fam)
        }
        let start = Date()
        let s = ProtectionSummary.summarize(families: families)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(s.familyCount, 5_000)
        XCTAssertEqual(s.workingCopyCount, 95_000)
        XCTAssertEqual(s.archive, .verified)
        XCTAssertEqual(s.cloud, .mixed, "two thirds of the families were never asked")
        XCTAssertLessThan(elapsed, 1.0, "summarize(families:) took \(elapsed)s for 100k copies")
    }
}
