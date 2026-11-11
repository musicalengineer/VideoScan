// ProvenanceEstimateTests.swift — machine-ESTIMATED provenance in the app
// (ProvenanceEstimateStore, ProvenanceEstimateJob, ProvenanceEstimateMark;
// DECISIONS 2026-11-10; the rule itself is Core's ProvenanceResolverTests).
//
// Dimensions (CLAUDE.md rule 8, a catalog writer):
//   LOGIC      the facts projection (archived videos with a digest and an
//              original path), the glyph's seam (VHS master only; Rick's own
//              role wins), the menu's offer, the Inspector's line, the words,
//              the File Journey event; an alternate capture names its master
//              by the archive's file name, and drops the pointer once the
//              master's estimate no longer stands.
//   TRUTH      a display string never claims confirmation while only inferred
//              rows exist; never shows a confidence; nothing without an
//              estimate; nothing after a reject; the Inspector line is for
//              the content it was read for.
//   STORE      Estimate lands inferred rows through the one door; a second
//              run writes NOTHING; a reject, then Estimate again, is VETOED
//              and reported; Confirm writes Rick's confirmed rows AND the
//              provenance_roles row in ONE transaction through
//              ProvenanceRoleStore; Confirm with no estimate is a counted
//              skip; the table decides when the projection is stale.
//   WRITER     an estimate + confirm inside the 2 s debounce window of a
//              record edit; during a job's write hold (REFUSED, nothing
//              written, lands after release); across a role flip master →
//              viewer → master; every case relaunched (a NEW model).
//   ISOLATION  an unattached store shows nothing and refuses with words; a
//              content catalog.sqlite does not hold is counted, the others
//              land; an older load snapshot never replaces newer state.
//   SCALE      100k records → the facts projection and the menu's count
//              inside a budget (the rule over 100k facts is Core's).
//   SENSOR     no SQL and no commit in the views or the job; no `extension
//              VideoScanModel` in the new files; the glyph's logic is not in
//              Archive/; nothing starts an estimate at launch; no name or
//              date field is written.
//   MEDIA      the rule's matrix is Core's; here the projection's stream
//              filter over the same five shapes.
//
//   REVIEW     the independent review of 2026-11-10 (its red tests, kept)
//              and the fixes' own rules: a withdrawn estimate is taken back
//              with a row; Confirm is a compare-and-swap on what was shown;
//              a refusal corrects what is shown; Rick's Set Role wins on the
//              dossier too, and Unknown after a Confirm makes it provisional
//              again; an open dossier hears every change; the run's counts
//              add up; the commit line names the confirmed rows.
//
// Suites (filter by SUITE): ProvenanceEstimateLogicTests ·
// ProvenanceEstimateStoreTests · ProvenanceEstimateScaleTests ·
// ProvenanceEstimateSensorTests · ProvenanceEstimateReviewTests ·
// ProvenanceEstimateReviewFixTests
// Synthetic names only.

import AppKit
import Combine
import Foundation
import Testing
@testable import VideoScan
import VideoScanCore

private let estimateNow = Date(timeIntervalSince1970: 1_794_300_000)     // 2026-11-10
private let captured = Date(timeIntervalSince1970: 1_783_944_000)        // 2026-07-13T12:00:00Z
private let utc = TimeZone(identifier: "UTC") ?? .current
private let vhsFolder = "/Volumes/Fixture/_staging/Converted_VHS_Tapes_2026"
/// What the archive calls the master (never its original name, test_tape.mkv).
private let archivedMasterName = "1984_test-tape.mkv"

private func hex(_ n: Int) -> String { String(format: "%064x", n) }

@MainActor
private func record(digest: String?, original: String? = "\(vhsFolder)/1984/test_tape.mkv", stream: String = "Video+Audio") -> VideoRecord {
    let r = VideoRecord()
    r.filename = "test_synthetic_\(UUID().uuidString.prefix(6)).mkv"
    r.sizeBytes = 4_096
    r.streamTypeRaw = stream
    r.container = "matroska,webm"
    r.videoCodec = "ffv1"
    r.resolution = "1280x720"
    r.bitDepth = "8"
    r.durationSeconds = 3_660
    r.embeddedCreationDate = captured
    r.originalFullPath = original
    if let digest {
        r.contentFixity = ContentFixity(digest: digest, byteCount: 4_096,
                                        stamp: FileIdentityStamp(device: 1, inode: 1, size: 4_096, mtimeNs: 1), computedAt: estimateNow)
    }
    return r
}

private func fact(_ digest: String, _ name: String, folder: String = "1984", seconds: Double = 3_660,
                  resolution: String = "1280x720", codec: String = "ffv1", created: Date? = captured) -> ProvenanceFact {
    ProvenanceFact(digest: digest, originalPath: "\(vhsFolder)/\(folder)/\(name)", filename: name, container: "matroska,webm",
                   videoCodec: codec, durationSeconds: seconds, embeddedCreatedAt: created,
                   resolution: resolution, bitDepth: "8", frameRate: "30", originEncoder: "Lavf61.7.100")
}

private func roleRow(_ digest: String, _ role: String, id: Int64 = 1) -> CatalogRow.ProvenanceRoleReading {
    CatalogRow.ProvenanceRoleReading(roleID: id, digest: digest, storedRole: role, decidedAt: 1, storedSourceMissing: false, note: nil)
}

private func estimate(_ role: ProvenanceRole = .master, confirmed: Bool = false, carrier: String? = "VHS") -> ProvenanceEstimate {
    ProvenanceEstimate(role: role, carrier: carrier, captureSetupID: CaptureSetup.july2026.id, isConfirmed: confirmed,
                       masterDigest: role == .alternateCapture ? hex(9) : nil, masterFilename: role == .alternateCapture ? "test_a.mkv" : nil)
}

// MARK: - LOGIC + TRUTH (pure)

@Suite("Estimated provenance — logic and truth")
@MainActor
struct ProvenanceEstimateLogicTests {

    @Test("facts: only an archived video with a full SHA-256 and an original path is read")
    func factsProjection() {
        let archived = record(digest: hex(1)), loose = record(digest: hex(2)), bare = record(digest: nil)
        let neverMoved = record(digest: hex(3), original: nil), sound = record(digest: hex(4), stream: "Audio only")
        let unprobed = record(digest: hex(5), stream: "")
        let facts = ProvenanceEstimateStore.facts(records: [archived, loose, bare, neverMoved, sound, unprobed]) { $0 !== loose }
        #expect(facts.map(\.digest) == [hex(1)])
        #expect(facts.first?.originalPath == "\(vhsFolder)/1984/test_tape.mkv")
        #expect(facts.first?.resolution == "1280x720")
        #expect(facts.first?.embeddedCreatedAt == captured)
        #expect(ProvenanceResolver.resolve(facts).proposals.first?.role == .master)
    }

    @Test("MEDIA: the projection keeps video streams of every container; the rule (Core) then takes only mkv/ffv1")
    func mediaMatrixThroughTheProjection() {
        let shapes: [(String, String)] = [("mov,mp4,m4a,3gp,3g2,mj2", "h264"), ("mov,mp4,m4a,3gp,3g2,mj2", "prores"),
                                          ("matroska,webm", "ffv1"), ("mxf", "dnxhd"), ("avi", "dvvideo")]
        let records = shapes.enumerated().map { i, shape -> VideoRecord in
            let r = record(digest: hex(i + 1), original: "\(vhsFolder)/1984/test_\(i).bin")
            r.container = shape.0
            r.videoCodec = shape.1
            return r
        }
        let facts = ProvenanceEstimateStore.facts(records: records) { _ in true }
        #expect(facts.count == 5)
        #expect(ProvenanceResolver.resolve(facts).proposals.map(\.digest) == [hex(3)])
    }

    @Test("the glyph: a VHS capture master only — estimated says so, confirmed says who; an alternate capture draws nothing")
    func glyphSeam() throws {
        let provisional = try #require(ProvenanceEstimateMark.judged(estimate(), rickRole: .unknown, captured: captured, timeZone: utc))
        #expect(provisional.help == "Estimated: original capture of a VHS tape, captured July 2026 — not confirmed")
        #expect(!provisional.isConfirmed)
        #expect(provisional.label == ProvenanceEstimateWords.glyphLabelEstimated)
        let confirmed = try #require(ProvenanceEstimateMark.judged(estimate(confirmed: true), rickRole: .master, captured: captured, timeZone: utc))
        #expect(confirmed.help == "Original capture of a VHS tape, captured July 2026. Provenance confirmed by Rick.")
        #expect(confirmed.isConfirmed)
        #expect(confirmed.symbol == provisional.symbol, "the same glyph; only the green check differs")
        #expect(ProvenanceEstimateMark.judged(estimate(.alternateCapture), rickRole: .unknown, captured: captured) == nil)
        #expect(ProvenanceEstimateMark.judged(estimate(carrier: "Hi8"), rickRole: .unknown, captured: captured) == nil)
        #expect(ProvenanceEstimateMark.judged(estimate(carrier: nil), rickRole: .unknown, captured: captured) == nil)
        #expect(ProvenanceEstimateMark.judged(nil, rickRole: .master, captured: captured) == nil, "Rick's role alone is not a carrier")
    }

    @Test("TRUTH: an estimate never reads as confirmed — in the glyph, the Inspector line or the journey")
    func anEstimateNeverClaimsConfirmation() throws {
        let shown = try #require(ProvenanceEstimateMark.judged(estimate(), rickRole: .unknown, captured: captured, timeZone: utc))
        #expect(!shown.help.contains("confirmed by"))
        #expect(shown.help.hasPrefix("Estimated: "))
        #expect(shown.help.hasSuffix("not confirmed"))
        let line = try #require(ProvenanceEstimateMark.inspectorLine(
            digest: hex(1), reading: .estimate(digest: hex(1), estimate()), rickRole: .unknown, year: 1984, captured: captured,
            technical: .init(videoCodec: "ffv1", resolution: "1280x720", bitDepth: "8"), timeZone: utc))
        #expect(line.text == "Provenance (estimated): Original capture of a VHS tape from 1984, captured July 2026 using ClearClick into OBS — FFV1, 1280×720, 8-bit")
        #expect(!line.isConfirmed)
        for text in [shown.help, line.text] {
            #expect(!text.contains("0.9") && !text.contains("%") && !text.lowercased().contains("confidence"), "\(text)")
        }
    }

    @Test("TRUTH: Rick's own role wins — a different Set Role hides the estimate everywhere; the same role keeps it")
    func ricksOwnRoleWins() {
        #expect(ProvenanceEstimateMark.visible(estimate(), rickRole: .unknown) != nil)
        #expect(ProvenanceEstimateMark.visible(estimate(), rickRole: .master) != nil)
        #expect(ProvenanceEstimateMark.visible(estimate(), rickRole: .editCopy) == nil)
        #expect(ProvenanceEstimateMark.judged(estimate(), rickRole: .editCopy, captured: captured) == nil)
        #expect(ProvenanceEstimateMark.judged(estimate(confirmed: true), rickRole: .viewCopy, captured: captured) == nil)
        #expect(ProvenanceEstimateMark.inspectorLine(digest: hex(1), reading: .estimate(digest: hex(1), estimate()), rickRole: .editCopy,
                                                     year: 1984, captured: captured, technical: nil) == nil)
    }

    @Test("the Inspector line: confirmed says so; nothing for no estimate, an unread content, another content's reading or a failed read")
    func inspectorLine() throws {
        let confirmed = try #require(ProvenanceEstimateMark.inspectorLine(
            digest: hex(1).uppercased(), reading: .estimate(digest: hex(1), estimate(confirmed: true)), rickRole: .master, year: nil,
            captured: nil, technical: nil, timeZone: utc))
        #expect(confirmed.text == "Provenance (confirmed by Rick): Original capture of a VHS tape, captured using ClearClick into OBS")
        #expect(confirmed.isConfirmed)
        let alternate = try #require(ProvenanceEstimateMark.inspectorLine(
            digest: hex(1), reading: .estimate(digest: hex(1), estimate(.alternateCapture)), rickRole: .unknown, year: 1984,
            captured: captured, technical: nil, timeZone: utc))
        #expect(alternate.text == "Provenance (estimated): Alternate capture of a VHS tape", "no archive name given: no pointer, never the original name")
        let named = try #require(ProvenanceEstimateMark.inspectorLine(
            digest: hex(1), reading: .estimate(digest: hex(1), estimate(.alternateCapture)), rickRole: .unknown, year: 1984,
            captured: captured, technical: nil, masterName: { $0.masterDigest == hex(9) ? "1984_test-a.mkv" : nil }, timeZone: utc))
        #expect(named.text == "Provenance (estimated): Alternate capture of the same tape as 1984_test-a.mkv")
        #expect(ProvenanceEstimateMark.inspectorLine(digest: hex(1), reading: .none(digest: hex(1)), rickRole: .unknown, year: 1984,
                                                     captured: captured, technical: nil) == nil)
        #expect(ProvenanceEstimateMark.inspectorLine(digest: hex(1), reading: nil, rickRole: .unknown, year: 1984, captured: captured,
                                                     technical: nil) == nil, "never a guess while reading")
        #expect(ProvenanceEstimateMark.inspectorLine(digest: hex(2), reading: .estimate(digest: hex(1), estimate()), rickRole: .unknown,
                                                     year: 1984, captured: captured, technical: nil) == nil, "a reading for A is never shown for B")
        #expect(ProvenanceEstimateMark.inspectorLine(digest: hex(1), reading: .unavailable(digest: hex(1), why: "closed"), rickRole: .unknown,
                                                     year: 1984, captured: captured, technical: nil) == nil)
        #expect(ProvenanceEstimateMark.inspectorLine(digest: nil, reading: nil, rickRole: .unknown, year: nil, captured: nil, technical: nil) == nil)
    }

    @Test("the SF Symbol resolves on this macOS as recordingtape; there is NO fallback — without it no glyph is drawn (film means film)")
    func theSymbolResolves() throws {
        let name = try #require(ProvenanceEstimateMark.symbolName, "recordingtape is not a system symbol on this macOS")
        print("[provenance-estimate] glyph symbol in use: \(name)")
        #expect(name == "recordingtape")
        #expect(NSImage(systemSymbolName: name, accessibilityDescription: nil) != nil)
        #expect(ProvenanceEstimateMark.resolveSymbol { _ in true } == "recordingtape")
        #expect(ProvenanceEstimateMark.resolveSymbol { _ in false } == nil, "never film, never any stand-in")
        #expect(ProvenanceEstimateMark.judged(estimate(), rickRole: .unknown, captured: captured, symbol: nil) == nil, "no symbol: no glyph")
        #expect(ProvenanceEstimateMark.judged(estimate(), rickRole: .unknown, captured: captured, symbol: "recordingtape")?.symbol == "recordingtape")
        let mark = try SourceTree.appCode(named: "Provenance/ProvenanceEstimateMark.swift")
        #expect(!mark.contains("\"film\""), "the tape glyph has no film fallback")
    }

    @Test("the offer: Confirm needs ≥ 1 estimate waiting; Not Right needs exactly one; the session's refusal disables both, with words")
    func offer() {
        let none = ProvenanceEstimateMark.Offer(provisional: 0, writeRefusal: nil)
        #expect(none.confirmRefusal == ProvenanceEstimateWords.nothingToConfirmHelp)
        #expect(none.notRightRefusal == ProvenanceEstimateWords.notRightNeedsOneHelp)
        let one = ProvenanceEstimateMark.Offer(provisional: 1, writeRefusal: nil)
        #expect(one.confirmRefusal == nil)
        #expect(one.notRightRefusal == nil)
        let many = ProvenanceEstimateMark.Offer(provisional: 4, writeRefusal: nil)
        #expect(many.confirmRefusal == nil)
        #expect(many.notRightRefusal == ProvenanceEstimateWords.notRightNeedsOneHelp)
        let held = ProvenanceEstimateMark.Offer(provisional: 1, writeRefusal: "held — a test job")
        #expect(held.confirmRefusal == "Provenance cannot be changed now: held — a test job.")
        #expect(held.notRightRefusal == "Provenance cannot be changed now: held — a test job.")
        #expect(ProvenanceEstimateWords.confirmTitle(1) == "Confirm Provenance")
        #expect(ProvenanceEstimateWords.confirmTitle(4) == "Confirm Provenance for 4")
        #expect(ProvenanceEstimateWords.notRightTitle == "Provenance Not Right")
        #expect(ProvenanceEstimateWords.estimateTitle == "Estimate Provenance…")
    }

    @Test("the run's words: examined, estimated, already estimated, vetoed — and what was left out, only when there is some")
    func summaryWords() {
        let plain = ProvenanceEstimateStore.Tally(examined: 12, estimated: 3, already: 2, vetoed: 1)
        #expect(ProvenanceEstimateStore.summary(plain) == "12 archived videos examined, 3 estimated, 2 already estimated, 1 vetoed")
        let more = ProvenanceEstimateStore.Tally(examined: 1, estimated: 0, already: 0, vetoed: 0, shorter: 2, notStored: 1)
        #expect(ProvenanceEstimateStore.summary(more) == "1 archived video examined, 0 estimated, 0 already estimated, 0 vetoed, "
                + "2 left unclassified (shorter than a capture of the same name in its folder), 1 not in catalog.sqlite yet (run again)")
        #expect(ProvenanceEstimateStore.startLine(examined: 2).hasPrefix("START estimate provenance — 2 archived videos to examine"))
        #expect(ProvenanceEstimateWords.summary(estimate()) == "Master · VHS · ClearClick into OBS")
    }

    @Test("ISOLATION: an unattached store (a viewer launch, a JSON session) shows nothing, refuses every verb with words, writes nothing")
    func unattachedShowsNothingAndRefuses() async {
        let store = ProvenanceEstimateStore()
        var lines: [String] = []
        store.note = { lines.append($0) }
        let words = "the catalog is not open for writing in this session"
        #expect(store.estimate(of: hex(1)) == nil)
        #expect(store.estimate(of: nil) == nil)
        #expect(store.shown(of: hex(1), roles: nil) == nil)
        #expect(store.provisionalCount(in: [hex(1), hex(2)], roles: nil) == 0)
        #expect(store.writeRefusal == words)
        #expect(await store.run(now: estimateNow) == .refused(words))
        #expect(store.confirm(digests: [hex(1)]) == .refused(words))
        #expect(store.confirm(digests: []) == .refused("nothing selected has a full SHA-256"))
        #expect(store.reject(digest: hex(1)) == .refused(words))
        #expect(lines.contains("REFUSED estimate provenance — \(words). Nothing was written."))
        #expect(lines.contains { $0.hasPrefix("REFUSED confirm provenance: 1 content") })
        #expect(lines.contains { $0.hasPrefix("REFUSED provenance not right: content") })
        #expect(await store.load() == "the catalog is not open")
    }

    @Test("ISOLATION: an older load snapshot never replaces newer state; the projection reads any spelling of a digest")
    func olderSnapshotNeverWins() {
        let store = ProvenanceEstimateStore()
        let takenAt = store.commitEpoch
        #expect(store.apply([hex(1): estimate()], takenAt: takenAt))
        #expect(store.estimate(of: hex(1).uppercased())?.role == .master)
        #expect(store.provisionalCount(in: [hex(1), hex(2)], roles: nil) == 1)
        #expect(store.apply([:], takenAt: takenAt - 1) == false)
        #expect(store.estimate(of: hex(1)) != nil, "a stale snapshot changed nothing")
        #expect(store.apply([hex(1): estimate(confirmed: true)], takenAt: store.commitEpoch))
        let roles = ProvenanceRoleStore()
        roles.apply([roleRow(hex(1), "master")], takenAt: roles.commitEpoch)
        #expect(store.provisionalCount(in: [hex(1)], roles: roles) == 0, "confirmed, and Rick's role agrees: not waiting")
        #expect(store.shown(of: hex(1), roles: roles)?.isConfirmed == true)
        // Set Role ▸ Unknown (or no role at all) after a Confirm takes his word back: provisional again.
        #expect(store.provisionalCount(in: [hex(1)], roles: nil) == 1)
        roles.apply([roleRow(hex(1), "unknown", id: 2)], takenAt: roles.commitEpoch)
        #expect(store.shown(of: hex(1), roles: roles)?.isConfirmed == false)
        #expect(store.shownProvisional(in: [hex(1).uppercased(), hex(2)], roles: roles) == [hex(1): estimate()])
    }

    @Test("the File Journey: one provenance event with the sentence, dated at the capture; none when nothing is passed in")
    func journeyEvent() throws {
        let rec = record(digest: hex(1))
        rec.fullPath = "/Volumes/Fixture/Archive/test_tape.mkv"
        let safe: VolumeSafetyResolver = { _ in VolumeSafety.unknown }
        let plain = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: safe, probe: { _ in .regularFile })
        #expect(!plain.events.contains { $0.kind == .provenance })
        let sentence = try #require(ProvenanceResolver.shortLine(estimate(), captured: captured, timeZone: utc))
        let told = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: safe,
                                                   provenance: JourneyProvenance(sentence: sentence, captured: captured),
                                                   probe: { _ in .regularFile })
        let events = told.events.filter { $0.kind == .provenance }
        #expect(events.count == 1)
        #expect(events.first?.sentence == "Estimated: original capture of a VHS tape, captured July 2026 — not confirmed")
        #expect(events.first?.timestamp == captured)
        #expect(events.first?.icon == ProvenanceEstimateMark.journeyIcon)
        #expect(told.events.count == plain.events.count + 1)
        #expect(told.events.last?.kind == .currentState, "the current state is still last")
        let undated = VideoScanModel.buildFileJourney(for: rec, allRecords: [rec], resolveVolumeSafety: safe,
                                                      provenance: JourneyProvenance(sentence: sentence, captured: nil),
                                                      probe: { _ in .regularFile })
        #expect(undated.events.first { $0.kind == .provenance }?.displayStamp.isEmpty == true, "no capture date: no stamp, never an invented one")
    }

    @Test("the master-name seam: an unattached store knows no archive name, so an alternate never points anywhere")
    func masterNameSeamWithoutAnArchive() {
        let store = ProvenanceEstimateStore()
        store.apply([hex(1): estimate(.alternateCapture), hex(9): estimate()], takenAt: store.commitEpoch)
        #expect(store.masterName(of: estimate(.alternateCapture), roles: nil) == nil)
        #expect(store.masterName(of: estimate(), roles: nil) == nil)
        #expect(store.journey(for: record(digest: hex(1)), roles: nil)?.sentence
                == ProvenanceResolver.shortLine(estimate(.alternateCapture), captured: captured))
        #expect(store.journey(for: record(digest: hex(1)), roles: nil)?.sentence.contains("test_a.mkv") == false)
    }

    @Test("the store's journey seam: provisional, confirmed, and nothing when Rick's role says otherwise or there is no estimate")
    func journeySeam() throws {
        let store = ProvenanceEstimateStore()
        let rec = record(digest: hex(1))
        #expect(store.journey(for: rec, roles: nil) == nil)
        store.apply([hex(1): estimate()], takenAt: store.commitEpoch)
        let told = try #require(store.journey(for: rec, roles: nil))
        #expect(told.sentence.hasPrefix("Estimated: original capture of a VHS tape, captured "))
        #expect(told.captured == captured)
        #expect(store.journey(for: record(digest: hex(2)), roles: nil) == nil)
        #expect(store.journey(for: record(digest: nil), roles: nil) == nil)
    }
}

// MARK: - STORE + WRITER on catalog.sqlite

@MainActor
private struct Contents {
    let master: String
    let alternate: String
    let other: String
}

/// Launch on catalog.sqlite and give the store three synthetic VHS facts over
/// the fixture's stored contents: a master and an alternate capture of one
/// tape, and a second tape.
@MainActor
private func launch(_ scene: CutoverScene) async throws -> Contents {
    try await scene.launchOnSQLite()
    try #require(scene.model.catalogCutover.isSQLiteAuthority, "the scene launched on catalog.sqlite")
    let ids = Contents(master: try #require(CatalogCommit.digest(of: try scene.record(.healthy))),
                       alternate: try #require(CatalogCommit.digest(of: try scene.record(.curatedConflictA))),
                       other: try #require(CatalogCommit.digest(of: try scene.record(.stalePrint))))
    attachFacts(scene.model, ids)
    #expect(await scene.model.provenanceEstimates.load() == nil)
    #expect(await scene.model.provenanceRoles.load() == nil)
    return ids
}

@MainActor
private func attachFacts(_ model: VideoScanModel, _ ids: Contents, extra: [ProvenanceFact] = []) {
    // "test_tape" / "test_tape_sd": name-related (one stem is a prefix of the other) and within 1 % → one tape.
    let facts = [fact(ids.master, "test_tape.mkv"), fact(ids.alternate, "test_tape_sd.mkv", seconds: 3_650, resolution: "720x480"),
                 fact(ids.other, "test_other_tape.mkv", folder: "1991")] + extra
    let store = model.provenanceEstimates
    guard let backing = store.backing else { Issue.record("the store has no backing"); return }
    let master = ids.master
    store.attach(backing, roles: model.provenanceRoles, facts: { facts },
                 archiveName: { $0 == master ? archivedMasterName : nil })
}

/// Quit and launch again: a NEW model on the same folder.
@MainActor
private func relaunch(_ scene: CutoverScene, from model: VideoScanModel) async throws -> VideoScanModel {
    if let committer = model.catalogCutover.committer { await committer.repository.close() }
    let sandbox = scene.sandbox
    let fresh = VideoScanModel(logDirectory: sandbox.logs)
    fresh.catalogStore = CatalogStore(directory: sandbox.catalogDir)
    fresh.mediaLedger = MediaLedger(directory: sandbox.root.appendingPathComponent("ledger", isDirectory: true))
    fresh.records = fresh.loadCatalogAtLaunch()
    try #require(fresh.catalogCutover.isSQLiteAuthority, "the relaunch opened catalog.sqlite")
    #expect(await fresh.provenanceEstimates.load() == nil)
    #expect(await fresh.provenanceRoles.load() == nil)
    return fresh
}

@MainActor
private func rows(_ model: VideoScanModel, _ digest: String) async throws -> [CatalogRow.ProvenanceAssertionReading] {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.provenanceAssertions(subjectKind: "content", subjectID: digest) }
}

@MainActor
private func rowCount(_ model: VideoScanModel) async throws -> Int {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.provenanceAssertionCount() }
}

@MainActor
private func roleHistory(_ model: VideoScanModel, _ digest: String) async throws -> [CatalogRow.ProvenanceRoleReading] {
    let repository = try #require(model.catalogCutover.committer?.repository)
    return try await repository.read { try $0.provenanceRoleHistory(digest: digest) }
}

@Suite("Estimated provenance — the store and the writer cases on catalog.sqlite", .serialized)
@MainActor
struct ProvenanceEstimateStoreTests {

    @Test("Estimate lands inferred rows through the door; the glyph's projection shows a provisional master; a SECOND run writes nothing")
    func estimateLandsAndASecondRunWritesNothing() async throws {
        let scene = try CutoverScene.make("prov_estimate"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        #expect(store.byDigest.isEmpty, "nothing is estimated until Rick runs the command")
        let first = await store.run(now: estimateNow)
        #expect(first == .finished(.init(examined: 3, estimated: 3, already: 0, vetoed: 0)))
        let stored = try await rows(scene.model, ids.master)
        #expect(stored.map(\.field) == ["role", "carrier", "captureSetup"])
        #expect(stored.map(\.value) == ["master", "VHS", CaptureSetup.july2026.id])
        #expect(stored.allSatisfy { $0.state == "inferred" && $0.by == ProvenanceEstimateRule.signer })
        #expect(stored.allSatisfy { $0.at == Int64(estimateNow.timeIntervalSince1970) })
        #expect(try await rows(scene.model, ids.alternate).first?.value == "alternateCapture")
        #expect(store.estimate(of: ids.master) == ProvenanceEstimate(role: .master, carrier: "VHS",
                                                                     captureSetupID: CaptureSetup.july2026.id, isConfirmed: false))
        #expect(store.estimate(of: ids.alternate)?.masterFilename == "test_tape.mkv")
        #expect(store.estimate(of: ids.other)?.role == .master)
        #expect(store.provisionalCount(in: [ids.master, ids.alternate, ids.other], roles: scene.model.provenanceRoles) == 3)
        #expect(try await roleHistory(scene.model, ids.master).isEmpty, "an estimate never sets a role")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Provenance: START estimate provenance — 3 archived videos to examine"), "\(log.suffix(900))")
        #expect(log.contains("Provenance: OUTCOME estimate provenance — 3 archived videos examined, 3 estimated, 0 already estimated, 0 vetoed."))
        #expect(log.contains("→ estimated Master · VHS · ClearClick into OBS"))
        #expect(log.contains("via provenance estimates"), "the committer's own OUTCOME line names the table")

        let count = try await rowCount(scene.model)
        #expect(count == 9)
        let second = await store.run(now: estimateNow.addingTimeInterval(86_400))
        #expect(second == .finished(.init(examined: 3, estimated: 0, already: 3, vetoed: 0)))
        #expect(try await rowCount(scene.model) == count, "a second run wrote nothing")

        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceEstimates.estimate(of: ids.master)?.isConfirmed == false)
        #expect(fresh.provenanceEstimates.byDigest.count == 3)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("Not Right, then Estimate again: the role is VETOED by the table and REPORTED; nothing is shown, before and after a relaunch")
    func rejectThenEstimateAgainIsVetoedAndReported() async throws {
        let scene = try CutoverScene.make("prov_reject"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        _ = await store.run(now: estimateNow)
        #expect(store.reject(digest: ids.master, now: estimateNow) == .rejected(.master))
        #expect(store.estimate(of: ids.master) == nil, "after a reject nothing is shown")
        let after = try await rows(scene.model, ids.master)
        #expect(after.last?.state == "rejected")
        #expect(after.last?.by == "rick")
        #expect(after.last?.field == "role")
        #expect(after.last?.value == "master")
        #expect(after.last?.confidence == nil)
        #expect(store.reject(digest: ids.master, now: estimateNow) == .nothingToReject, "no estimate is waiting any more")
        let count = try await rowCount(scene.model)
        let again = await store.run(now: estimateNow.addingTimeInterval(86_400))
        #expect(again == .finished(.init(examined: 3, estimated: 0, already: 2, vetoed: 1)))
        #expect(try await rowCount(scene.model) == count, "the vetoed role was not written, and nothing else was")
        #expect(store.estimate(of: ids.master) == nil)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("VETOED — you rejected Master for it; not written, not proposed again"), "\(log.suffix(900))")
        #expect(log.contains("estimated Master · VHS · ClearClick into OBS → rejected by Rick"))
        #expect(log.contains("3 archived videos examined, 0 estimated, 2 already estimated, 1 vetoed"))
        #expect(try await roleHistory(scene.model, ids.master).isEmpty)
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceEstimates.estimate(of: ids.master) == nil)
        #expect(fresh.provenanceEstimates.estimate(of: ids.other) != nil, "the other tape's estimate stands")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("Confirm: Rick's confirmed rows AND the provenance_roles row, ONE transaction, through ProvenanceRoleStore; the relaunch shows it confirmed")
    func confirmWritesRowsAndTheRoleInOneTransaction() async throws {
        let scene = try CutoverScene.make("prov_confirm"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        _ = await store.run(now: estimateNow)
        let generation = try #require(scene.model.catalogCutover.committer?.knownGeneration)
        let later = estimateNow.addingTimeInterval(60)
        #expect(store.confirm(digests: [ids.master], files: 1, now: later) == .confirmed(contents: 1, skipped: 0))
        #expect(scene.model.catalogCutover.committer?.knownGeneration == generation + 1, "the rows and the role are one commit")
        let stored = try await rows(scene.model, ids.master)
        let mine = stored.filter { $0.by == "rick" }
        #expect(mine.map(\.field) == ["role", "carrier", "captureSetup"])
        #expect(mine.map(\.value) == ["master", "VHS", CaptureSetup.july2026.id])
        #expect(mine.allSatisfy { $0.state == "confirmed" && $0.confidence == nil && $0.at == Int64(later.timeIntervalSince1970) })
        let history = try await roleHistory(scene.model, ids.master)
        #expect(history.map(\.storedRole) == ["master"])
        #expect(history.first?.decidedAt == Int64(later.timeIntervalSince1970))
        #expect(roles.role(of: ids.master) == .master, "the role menu's checkmark follows")
        #expect(store.estimate(of: ids.master)?.isConfirmed == true)
        #expect(store.estimate(of: ids.other)?.isConfirmed == false, "only what was selected is confirmed")
        #expect(store.provisionalCount(in: [ids.master, ids.other], roles: roles) == 1)
        let shown = try #require(ProvenanceEstimateMark.judged(store.estimate(of: ids.master), rickRole: roles.role(of: ids.master),
                                                              captured: captured, timeZone: utc))
        #expect(shown.help == "Original capture of a VHS tape, captured July 2026. Provenance confirmed by Rick.")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Provenance: START confirm provenance: 1 content (1 file)"), "\(log.suffix(900))")
        #expect(log.contains("… estimated → confirmed by Rick: Master · VHS · ClearClick into OBS"))
        #expect(log.contains("… Unknown → Master"), "the role engine's own old → new line")
        #expect(log.contains("Provenance: OUTCOME confirm provenance: 1 content (1 file) — 1 confirmed, 0 skipped"))
        // Confirming again: nothing waits; nothing more is written.
        let count = try await rowCount(scene.model)
        #expect(store.confirm(digests: [ids.master], now: later) == .confirmed(contents: 0, skipped: 1))
        #expect(try await rowCount(scene.model) == count)
        #expect(try await roleHistory(scene.model, ids.master).count == 1)
        // The rule running again changes nothing about what Rick confirmed.
        #expect(await store.run(now: later.addingTimeInterval(60)) == .finished(.init(examined: 3, estimated: 0, already: 3, vetoed: 0)))
        #expect(store.estimate(of: ids.master)?.isConfirmed == true)

        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceEstimates.estimate(of: ids.master)?.isConfirmed == true)
        #expect(fresh.provenanceRoles.role(of: ids.master) == .master)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("Confirm a reviewed LIST in one action: the master and its alternate capture each get their own role; a content with no estimate is a counted skip")
    func confirmAListWithASkip() async throws {
        let scene = try CutoverScene.make("prov_list"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        _ = await store.run(now: estimateNow)
        let stranger = try #require(CatalogCommit.digest(of: try scene.record(.tombstonedWithDigest)))
        #expect(store.estimate(of: stranger) == nil)
        let outcome = store.confirm(digests: [ids.master, ids.alternate, stranger], files: 3, now: estimateNow)
        #expect(outcome == .confirmed(contents: 2, skipped: 1))
        #expect(try await roleHistory(scene.model, ids.master).map(\.storedRole) == ["master"])
        #expect(try await roleHistory(scene.model, ids.alternate).map(\.storedRole) == ["alternateCapture"])
        #expect(try await roleHistory(scene.model, stranger).isEmpty, "a content with no estimate gets no role")
        #expect(try await rows(scene.model, stranger).isEmpty)
        #expect(store.estimate(of: ids.alternate)?.isConfirmed == true)
        #expect(store.estimate(of: ids.alternate)?.masterDigest == ids.master, "the confirmed alternate still knows its master")
        #expect(scene.sandbox.catalogLogText().contains("OUTCOME confirm provenance: 3 contents (3 files) — 2 confirmed, 1 skipped"))
        // Nothing estimated at all → every one skipped, nothing written, no role set.
        #expect(store.confirm(digests: [stranger], now: estimateNow) == .confirmed(contents: 0, skipped: 1))
        #expect(try await roleHistory(scene.model, stranger).isEmpty)
    }

    @Test("ISOLATION: the TABLE decides — a projection that still shows an estimate Rick rejected elsewhere confirms NOTHING (no rows, no role)")
    func aStaleProjectionConfirmsNothing() async throws {
        let scene = try CutoverScene.make("prov_stale"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        _ = await store.run(now: estimateNow)
        // Behind the store's back: the table now says "rejected"; the projection still shows the estimate.
        try scene.execSQL("""
            INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
            VALUES ('content', '\(ids.master)', 'role', 'master', 'rejected', 'rick', 1794300100, NULL, '{}');
            """)
        #expect(store.estimate(of: ids.master) != nil, "the projection is stale on purpose")
        let count = try await rowCount(scene.model)
        let outcome = store.confirm(digests: [ids.master], now: estimateNow)
        guard case .refused(let words) = outcome else { Issue.record("expected a refusal, got \(outcome)"); return }
        #expect(words.contains("the estimate changed for 1 content — look again"))
        #expect(try await rowCount(scene.model) == count, "no confirmed row")
        #expect(try await roleHistory(scene.model, ids.master).isEmpty, "and no role: the transaction rolled back whole")
        #expect(scene.model.catalogCutover.committer?.blockedReason == nil, "a refused confirm never blocks the catalog")
        #expect(await store.load() == nil)
        #expect(store.estimate(of: ids.master) == nil, "a load shows what the table holds")
    }

    @Test("an alternate capture names its master by the ARCHIVE's file name; once Rick rejects the master's estimate the pointer is dropped; a relaunch agrees")
    func anAlternateNamesItsMasterByTheArchiveNameUntilTheMasterIsRejected() async throws {
        let scene = try CutoverScene.make("prov_alternate"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        _ = await store.run(now: estimateNow)
        let alternate = try #require(store.estimate(of: ids.alternate))
        #expect(alternate.masterFilename == "test_tape.mkv", "the evidence keeps the original name")
        #expect(store.masterName(of: alternate, roles: roles) == archivedMasterName)
        func line() async -> String? {
            ProvenanceEstimateMark.inspectorLine(digest: ids.alternate, reading: await store.readCurrent(digest: ids.alternate),
                                                 rickRole: roles.role(of: ids.alternate), year: nil, captured: captured, technical: nil,
                                                 masterName: { store.masterName(of: $0, roles: roles) }, timeZone: utc)?.text
        }
        #expect(await line() == "Provenance (estimated): Alternate capture of the same tape as \(archivedMasterName)")
        #expect(await line()?.contains("test_tape.mkv") == false, "never the original file name")
        #expect(store.masterName(of: try #require(store.estimate(of: ids.master)), roles: roles) == nil, "a master points at nothing")
        // Rick says the master's estimate is not right: the alternate stays provisional, without the pointer.
        #expect(store.reject(digest: ids.master, now: estimateNow) == .rejected(.master))
        #expect(store.masterName(of: alternate, roles: roles) == nil)
        #expect(await line() == "Provenance (estimated): Alternate capture of a VHS tape")
        #expect(store.estimate(of: ids.alternate)?.isConfirmed == false)
        let fresh = try await relaunch(scene, from: scene.model)
        let again = try #require(fresh.provenanceEstimates.estimate(of: ids.alternate))
        #expect(fresh.provenanceEstimates.masterName(of: again, roles: fresh.provenanceRoles) == nil)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("Rick's Set Role on the MASTER to something else also drops the alternate's pointer")
    func aMasterRickRoledOtherwiseIsNotPointedAt() async throws {
        let scene = try CutoverScene.make("prov_alt_role"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        _ = await store.run(now: estimateNow)
        let alternate = try #require(store.estimate(of: ids.alternate))
        #expect(store.masterName(of: alternate, roles: roles) == archivedMasterName)
        #expect(roles.set(.editCopy, digests: [ids.master], now: estimateNow) == .set(changed: 1, unchanged: 0))
        #expect(store.masterName(of: alternate, roles: roles) == nil)
    }

    @Test("Rick's own Set Role wins: an estimate that disagrees with it is not shown and not confirmed")
    func ricksSetRoleWinsOverAnEstimate() async throws {
        let scene = try CutoverScene.make("prov_setrole"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        #expect(roles.set(.editCopy, digests: [ids.master], now: estimateNow) == .set(changed: 1, unchanged: 0))
        _ = await store.run(now: estimateNow)
        #expect(store.estimate(of: ids.master)?.role == .master, "the rule still records what it saw")
        #expect(store.shown(of: ids.master, roles: roles) == nil, "but Rick's typed role is what is shown")
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 0, skipped: 1))
        #expect(try await roleHistory(scene.model, ids.master).map(\.storedRole) == ["editCopy"], "his role was not overwritten")
        #expect(store.journey(for: try scene.record(.healthy), roles: roles) == nil)
    }

    @Test("ISOLATION: a content catalog.sqlite does not hold is counted, never written — and the others still land")
    func aContentTheCatalogDoesNotHold() async throws {
        let scene = try CutoverScene.make("prov_missing"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        attachFacts(scene.model, ids, extra: [fact(hex(0xdead), "test_unsaved.mkv", folder: "2001")])
        let outcome = await scene.model.provenanceEstimates.run(now: estimateNow)
        #expect(outcome == .finished(.init(examined: 4, estimated: 3, already: 0, vetoed: 0, shorter: 0, notStored: 1)))
        #expect(try await rows(scene.model, hex(0xdead)).isEmpty)
        #expect(scene.model.provenanceEstimates.estimate(of: hex(0xdead)) == nil)
        #expect(scene.sandbox.catalogLogText().contains("1 not in catalog.sqlite yet (run again)"))
    }

    @Test("a shorter capture of the same NAME in the folder is left unclassified and the run says how many")
    func aShorterCaptureIsReportedNotClassified() async throws {
        let scene = try CutoverScene.make("prov_shorter"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let trim = try #require(CatalogCommit.digest(of: try scene.record(.tombstonedWithDigest)))
        attachFacts(scene.model, ids, extra: [fact(trim, "test_tape_trim.mkv", seconds: 1_500)])
        let outcome = await scene.model.provenanceEstimates.run(now: estimateNow)
        #expect(outcome == .finished(.init(examined: 4, estimated: 3, already: 0, vetoed: 0, shorter: 1, notStored: 0)))
        #expect(try await rows(scene.model, trim).isEmpty)
        #expect(scene.sandbox.catalogLogText().contains("1 left unclassified (shorter than a capture of the same name in its folder)"))
    }

    @Test("WRITER: an estimate and a confirm inside the 2 s debounce window of a record edit — all land, all survive the relaunch")
    func insideTheDebounceWindow() async throws {
        let scene = try CutoverScene.make("prov_debounce"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let healthy = try scene.record(.healthy)
        healthy.userNotes = "typed just before the estimate"
        scene.model.saveCatalogDebounced()
        let committer = try #require(scene.model.catalogCutover.committer)
        #expect(committer.isBusy, "the edit is waiting on the debounce timer")
        let store = scene.model.provenanceEstimates
        #expect(await store.run(now: estimateNow) == .finished(.init(examined: 3, estimated: 3, already: 0, vetoed: 0)))
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        #expect(committer.blockedReason == nil, "the side-table commits did not block the record commit")
        #expect(scene.model.saveCatalogNow(), "the edit inside the window still commits")
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceEstimates.estimate(of: ids.master)?.isConfirmed == true)
        #expect(fresh.provenanceEstimates.estimate(of: ids.other)?.isConfirmed == false)
        #expect(fresh.records.first { $0.id == healthy.id }?.userNotes == "typed just before the estimate")
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("WRITER: during a job's write hold every verb is REFUSED with the hold's words and nothing is written; after release they land and survive the relaunch")
    func duringAWriteHold() async throws {
        let scene = try CutoverScene.make("prov_hold"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        #expect(await store.run(now: estimateNow) == .finished(.init(examined: 3, estimated: 3, already: 0, vetoed: 0)))
        let count = try await rowCount(scene.model)
        #expect(await scene.model.catalogStore.holdWrites(reason: "a test job", owner: CatalogWriteHoldOwner()) == .taken)
        let heldRun = await store.run(now: estimateNow)
        guard case .refused(let words) = heldRun else { Issue.record("expected a refusal, got \(heldRun)"); return }
        #expect(words.contains("held — a test job"))
        let heldConfirm = store.confirm(digests: [ids.master], now: estimateNow)
        guard case .refused(let confirmWords) = heldConfirm else { Issue.record("expected a refusal, got \(heldConfirm)"); return }
        #expect(confirmWords.contains("held — a test job"))
        guard case .refused = store.reject(digest: ids.other, now: estimateNow) else { Issue.record("expected a refusal"); return }
        #expect(store.writeRefusal != nil, "the menu is disabled while held")
        #expect(try await rowCount(scene.model) == count, "nothing written")
        #expect(try await roleHistory(scene.model, ids.master).isEmpty)
        #expect(store.estimate(of: ids.master)?.isConfirmed == false, "a refused confirm never shows as confirmed")
        #expect(store.estimate(of: ids.other) != nil, "a refused reject hides nothing")
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("Provenance: REFUSED estimate provenance — "))
        #expect(log.contains("Provenance: REFUSED confirm provenance: 1 content"))
        scene.model.catalogStore.releaseWriteHold()
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        #expect(store.reject(digest: ids.other, now: estimateNow) == .rejected(.master))
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceEstimates.estimate(of: ids.master)?.isConfirmed == true)
        #expect(fresh.provenanceEstimates.estimate(of: ids.other) == nil)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("WRITER: across a role flip — master estimates, the viewer is refused in words (nothing written), master again confirms; the relaunch shows the master's last choice")
    func acrossAViewerMasterFlip() async throws {
        let scene = try CutoverScene.make("prov_flip"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        #expect(await store.run(now: estimateNow) == .finished(.init(examined: 3, estimated: 3, already: 0, vetoed: 0)))
        let count = try await rowCount(scene.model)
        scene.model.updateReadOnlyFacts { $0.viewerRole = true }
        let asViewer = store.confirm(digests: [ids.master], now: estimateNow)
        guard case .refused(let words) = asViewer else { Issue.record("expected a refusal, got \(asViewer)"); return }
        #expect(words.contains("viewer"))
        guard case .refused(let runWords) = await store.run(now: estimateNow) else { Issue.record("expected a refusal"); return }
        #expect(runWords.contains("viewer"), "a read-only session refuses the estimate with words")
        guard case .refused = store.reject(digest: ids.master, now: estimateNow) else { Issue.record("expected a refusal"); return }
        #expect(ProvenanceEstimateMark.Offer(provisional: 1, writeRefusal: store.writeRefusal).confirmRefusal != nil)
        #expect(try await rowCount(scene.model) == count, "the viewer wrote nothing")
        #expect(try await roleHistory(scene.model, ids.master).isEmpty)
        #expect(store.estimate(of: ids.master)?.isConfirmed == false, "and the glyph still shows what the table holds")
        scene.model.updateReadOnlyFacts { $0.viewerRole = false }
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceEstimates.estimate(of: ids.master)?.isConfirmed == true)
        #expect(fresh.provenanceRoles.role(of: ids.master) == .master)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("TRUTH: the Inspector's reading comes from catalog.sqlite — none, estimated, confirmed, then none after a reject")
    func theInspectorReadsTheCatalog() async throws {
        let scene = try CutoverScene.make("prov_inspector"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        #expect(await store.readCurrent(digest: ids.master) == .none(digest: ids.master))
        _ = await store.run(now: estimateNow)
        guard case .estimate(let digest, let provisional) = await store.readCurrent(digest: ids.master.uppercased()) else {
            Issue.record("expected an estimate"); return
        }
        #expect(digest == ids.master)
        #expect(!provisional.isConfirmed)
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        guard case .estimate(_, let confirmed) = await store.readCurrent(digest: ids.master) else { Issue.record("expected an estimate"); return }
        #expect(confirmed.isConfirmed)
        #expect(store.reject(digest: ids.other, now: estimateNow) == .rejected(.master))
        #expect(await store.readCurrent(digest: ids.other) == .none(digest: ids.other))
    }

    @Test("the MFO job: one run to a finished row with the counts; a read-only session is refused in words; pause holds between chunks")
    func theJob() async throws {
        let scene = try CutoverScene.make("prov_job"); defer { scene.cleanup() }
        _ = try await launch(scene)
        let store = scene.model.provenanceEstimates
        let job = ProvenanceEstimateJob(store: store)
        #expect(job.kind == .estimateProvenance)
        #expect(job.title == "Estimate Provenance")
        job.start()
        await job.task?.value
        #expect(job.state == .finished(summary: "3 archived videos examined, 3 estimated, 0 already estimated, 0 vetoed"))
        #expect(job.tally?.estimated == 3)
        #expect(job.finishedAt != nil)
        #expect(!job.wasRefused)
        scene.model.updateReadOnlyFacts { $0.viewerRole = true }
        let refused = ProvenanceEstimateJob(store: store)
        refused.start()
        await refused.task?.value
        #expect(refused.wasRefused)
        guard case .failed(let message) = refused.state else { Issue.record("expected a refusal, got \(refused.state)"); return }
        #expect(message.hasPrefix("Refused — "))
        #expect(message.contains("viewer"))
        #expect(message.hasSuffix("Nothing was written."))
        scene.model.updateReadOnlyFacts { $0.viewerRole = false }
        let stopped = ProvenanceEstimateJob(store: store)
        stopped.cancel()
        stopped.start()
        await stopped.task?.value
        #expect(stopped.state == .cancelled, "a stop before the first chunk writes nothing more")
    }
}

// MARK: - SCALE

@Suite("Estimated provenance — SCALE (100k)")
@MainActor
struct ProvenanceEstimateScaleTests {

    /// What a run does on the main actor before it leaves it, and what the
    /// row menu does at right-click, for 100k archived records: the facts
    /// projection (one digest rule per record) and the provisional count
    /// (two dictionary probes per content) against 100k estimates. Budget
    /// 2 s (Debug, M4 Max) — O(n²) would be hours.
    @Test(.timeLimit(.minutes(2)))
    func hundredThousandRecords() {
        let records = (1...100_000).map { record(digest: hex($0), original: "\(vhsFolder)/tape_\($0)/test_\($0).mkv") }
        let store = ProvenanceEstimateStore()
        store.apply(Dictionary(uniqueKeysWithValues: (1...100_000).map { (hex($0), estimate()) }), takenAt: store.commitEpoch)
        let digests = Set((1...100_000).map(hex))
        let clock = ContinuousClock()
        var facts: [ProvenanceFact] = []
        var waiting = 0
        let elapsed = clock.measure {
            facts = ProvenanceEstimateStore.facts(records: records) { _ in true }
            waiting = store.provisionalCount(in: digests, roles: nil)
        }
        print("[provenance-estimate] 100k records: facts + provisional count \(elapsed)")
        #expect(facts.count == 100_000)
        #expect(waiting == 100_000)
        #expect(elapsed < .seconds(2))
    }
}

// MARK: - SENSOR

@Suite("Estimated provenance — sensors")
@MainActor
struct ProvenanceEstimateSensorTests {

    @Test("the views and the job hold no SQL and no commit; the new files add no model extension; the store's one door names the table")
    func noSQLNoCommitInTheViews() throws {
        for name in ["ProvenanceEstimateMark.swift", "ProvenanceEstimateJob.swift"] {
            let code = try SourceTree.appCode(named: "Provenance/" + name)
            #expect(!code.isEmpty)
            // "import " + "GRDB": spelled apart so this file never reads as a GRDB importer (CatalogStoreSensorTests).
            for token in ["commitSideTables", "writeBlocking", "INSERT", "appendProvenanceAssertion", "appendProvenanceRole",
                          "provenanceAssertions(", "extension VideoScanModel", "import " + "GRDB"] {
                #expect(!code.contains(token), "\(name) contains \(token)")
            }
        }
        let store = try SourceTree.appCode(named: "Provenance/ProvenanceEstimateStore.swift")
        #expect(!store.contains("extension VideoScanModel"))
        #expect(store.contains("commitSideTables(what, via: .provenanceEstimates, body)"), "the one door")
        #expect(!store.contains("INSERT"), "no SQL in the app; the Core door appends")
        #expect(!store.contains("import " + "GRDB"))
        #expect(store.contains("roles.set(estimate.role, digests: [digest]"), "Confirm sets the role through ProvenanceRoleStore — the one writer of provenance_roles")
        #expect(!store.contains("appendProvenanceRole"), "this store never writes provenance_roles itself")
    }

    @Test("rule 3: no name or date field is written — only role, carrier and captureSetup")
    func noNameOrDateFieldIsWritten() throws {
        let store = try SourceTree.appCode(named: "Provenance/ProvenanceEstimateStore.swift")
        for token in ["tapeYear", "digitizedOn", "recordedDate", "userDate", "\"date", "\"name", "\"title", "\"filename"] {
            #expect(!store.contains(token), "ProvenanceEstimateStore.swift mentions \(token)")
        }
        #expect(ProvenanceEstimateRule.fields == ["role", "carrier", "captureSetup"])
        #expect(ProvenanceEstimateRule.fields.allSatisfy { !ProvenanceAssertionFieldPolicy.isNameOrDate($0) })
    }

    @Test("the Archive tab draws the glyph and carries the menu items, and holds none of their logic")
    func theArchiveTabHoldsNoGlyphLogic() throws {
        let table = try SourceTree.appCode(named: "Archive/ArchiveView+Table.swift")
        #expect(table.contains("ProvenanceEstimateBadge(store: model.provenanceEstimates, roles: model.provenanceRoles, record: rec"))
        let start = try #require(table.range(of: "func recordContextMenu("))
        let menu = table[start.lowerBound...]
        #expect(menu.contains("ProvenanceEstimateMenuItems(store: model.provenanceEstimates, roles: model.provenanceRoles"))
        #expect(menu.contains("recs.filter { model.isProvenArchived($0) }"), "only PROVEN archived rows, never the sampled leg")
        let archive = SourceTree.appSources.filter { $0.relative.contains("Archive/") && !$0.relative.contains("ArchiveAngel/") }
        #expect(archive.count > 20, "the sensor must see the Archive folder")
        for source in archive {
            let code = SourceTree.strippingComments((try? String(contentsOf: source.url, encoding: .utf8)) ?? "")
            // (Archive/ has its own, unrelated "not confirmed" words for dates; these tokens are the glyph's alone.)
            for token in ["recordingtape", "isVHSMaster", "ProvenanceResolver", "ProvenanceEstimateMark.judged", "ProvenanceEstimate(",
                          "Provenance confirmed", "\"Estimated: "] {
                #expect(!code.contains(token), "\(source.relative) holds provenance-glyph logic (\(token))")
            }
        }
        let mark = try SourceTree.appCode(named: "Provenance/ProvenanceEstimateMark.swift")
        #expect(mark.contains("accessibilityIdentifier(\"archive.row.provenance\")"))
        #expect(!mark.contains(".yellow") && !mark.contains(".red"), "yellow is 'no sound'; red is never a provenance colour")
    }

    @Test("Estimate Provenance… is an on-demand command: one menu item starts it, nothing at launch does")
    func nothingStartsAnEstimateAtLaunch() throws {
        var starters: [String] = []
        for source in SourceTree.appSources {
            let code = SourceTree.strippingComments((try? String(contentsOf: source.url, encoding: .utf8)) ?? "")
            if code.contains(".startEstimateProvenance(") || code.contains("provenanceEstimates.run(") { starters.append(source.relative) }
        }
        #expect(starters.count == 1, "\(starters)")
        #expect(starters.first?.hasSuffix("Archive/ArchiveView.swift") == true, "\(starters)")
        let flip = try SourceTree.appCode(named: "Catalog/CatalogAuthorityFlip.swift")
        #expect(flip.contains("provenanceEstimates.attach(ProvenanceEstimateCatalogBacking(committer: committer), roles: provenanceRoles"))
        #expect(flip.contains("await self?.provenanceEstimates.load()"), "launch only READS what stands")
        let actions = try SourceTree.appCode(named: "Archive/ArchiveView.swift")
        #expect(actions.contains("Button(ProvenanceEstimateWords.estimateTitle)"))
    }

    @Test("the model holds ONE store, as a let; the job kind is registered and counted as a catalog writer; the Inspector line reads the catalog")
    func wiring() throws {
        let model = try SourceTree.appCode(named: "Model/VideoScanModel.swift")
        #expect(model.contains("let provenanceEstimates = ProvenanceEstimateStore()"))
        #expect(MediaFileOperationKind.all.contains(.estimateProvenance))
        #expect(MediaFileOperationKind.estimateProvenance.writesCatalog)
        #expect(MediaFileOperationKind.estimateProvenance.logVerb == "estimate provenance")
        #expect(CatalogCommitter.SideTable.provenanceEstimates.rawValue == "provenance estimates")
        let mark = try SourceTree.appCode(named: "Provenance/ProvenanceEstimateMark.swift")
        #expect(mark.contains("await store.readCurrent(digest: digest)"))
        let panel = try SourceTree.appCode(named: "Catalog/InspectorPanel.swift")
        #expect(panel.contains("InspectorProvenanceEstimateLine(record: rec, digest: contentDigest,"))
        #expect(panel.contains("archivePath: (masterCopy ?? rec).fullPath"), "the year comes from where the archive filed the copy")
        #expect(mark.contains("ProvenanceResolver.tapeYear(archivePath: archivePath, captured: record.embeddedCreationDate)"))
        #expect(!mark.contains("userDate") && !mark.contains("resolvedArchivedAt"), "never Rick's date field, never the promote stamp")
        let flip = try SourceTree.appCode(named: "Catalog/CatalogAuthorityFlip.swift")
        #expect(flip.contains("archivePromotionIndex.copy(withDigest: digest"), "the master's name is the archive copy's")
        let journey = try SourceTree.appCode(named: "Catalog/VideoScanModel+Provenance.swift")
        #expect(journey.contains("provenance: provenanceEstimates.journey(for: rec, roles: provenanceRoles)"))
        let start = try #require(journey.range(of: "static func buildFileJourney("))
        let end = try #require(journey.range(of: "static func hashStatusLine("))
        let builder = journey[start.lowerBound..<end.lowerBound]
        for token in ["provenanceEstimates", "repository", "catalogCutover"] {
            #expect(!builder.contains(token), "the journey builder reads the catalog (\(token))")
        }
    }
}

// MARK: - Review 2026-11-10 (independent reviewer): written RED on 5cebfd5e6, green since the review fixes

@Suite("Estimated provenance — review 2026-11-10", .serialized)
@MainActor
struct ProvenanceEstimateReviewTests {

    /// Pins ProvenanceEstimateStore.swift:373-408 (`run` lands proposals only):
    /// when the rule STOPS proposing a content (a longer capture of the same
    /// name turned up, so it "may be a trim — cannot tell"), the old inferred
    /// rows keep standing and every surface still says "Estimated: original
    /// capture…" — an estimate the rule no longer makes, one click from confirmed.
    @Test("TRUTH: an estimate the rule no longer makes is not shown after the next run")
    func anEstimateTheRuleWithdrewIsNotShown() async throws {
        let scene = try CutoverScene.make("prov_review_stale"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        _ = await store.run(now: estimateNow)
        #expect(store.estimate(of: ids.other)?.role == .master)
        let longer = try #require(CatalogCommit.digest(of: try scene.record(.tombstonedWithDigest)))
        attachFacts(scene.model, ids, extra: [fact(longer, "test_other_tape_full.mkv", folder: "1991", seconds: 7_200)])
        #expect(await store.load() == nil)
        guard case .finished(let tally) = await store.run(now: estimateNow.addingTimeInterval(60)) else { Issue.record("expected a finished run"); return }
        #expect(tally.shorter == 1, "the rule now leaves test_other_tape.mkv unclassified")
        #expect(store.estimate(of: ids.other) == nil, "what the rule no longer says is no longer shown")
        #expect(await store.readCurrent(digest: ids.other) == .none(digest: ids.other), "nor by the Inspector's own read")
    }

    /// Pins ProvenanceEstimateStore.swift:529-533 (`confirmRows` checks the role
    /// only): Rick was shown carrier VHS; the table's newest carrier is another
    /// value; Confirm writes HIS confirmed row for the value he never saw.
    @Test("CONFIRM: a carrier the table changed after it was shown is never confirmed in Rick's name")
    func confirmNeverWritesAValueThatWasNotShown() async throws {
        let scene = try CutoverScene.make("prov_review_unseen"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        _ = await store.run(now: estimateNow)
        #expect(store.estimate(of: ids.master)?.carrier == "VHS", "what the glyph and the menu show")
        try scene.execSQL("""
            INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
            VALUES ('content', '\(ids.master)', 'carrier', 'Betamax', 'inferred', 'machine:test/other/rule@r1', 1794300100, 0.5, '{}');
            """)
        _ = store.confirm(digests: [ids.master], now: estimateNow.addingTimeInterval(120))
        let mine = try await rows(scene.model, ids.master).filter { $0.by == "rick" }
        #expect(!mine.contains { $0.value == "Betamax" }, "Rick confirmed VHS, or nothing — never a value he was not shown")
    }

    /// Pins ProvenanceEstimateStore.swift:499-505: the refusal says "look
    /// again, then confirm", but the projection (glyph, menu count) is left
    /// exactly as stale as it was — looking again shows the same thing.
    @Test("CONFIRM: after an 'estimate changed' refusal the projection shows what the table holds")
    func aChangedRefusalRefreshesWhatIsShown() async throws {
        let scene = try CutoverScene.make("prov_review_refresh"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        _ = await store.run(now: estimateNow)
        try scene.execSQL("""
            INSERT INTO provenance_assertions (subject_kind, subject_id, field, value, state, by, at, confidence, evidence_json)
            VALUES ('content', '\(ids.master)', 'role', 'master', 'rejected', 'rick', 1794300100, NULL, '{}');
            """)
        guard case .refused = store.confirm(digests: [ids.master], now: estimateNow) else { Issue.record("expected a refusal"); return }
        #expect(store.estimate(of: ids.master) == nil, "the glyph no longer shows the estimate the table rejected")
        #expect(store.provisionalCount(in: [ids.master], roles: scene.model.provenanceRoles) == 0, "and the menu no longer offers it")
    }

    /// Pins FileDossier+Build.swift:290-301 (`provenanceLine` never hears Rick's
    /// role): the glyph, Inspector and journey hide an estimate his Set Role
    /// contradicts; the dossier still states it — and as his own `.fact` once
    /// confirmed, after he has since said the file is something else.
    @Test("TRUTH: the dossier does not state a provenance Rick's own Set Role contradicts")
    func theDossierYieldsToRicksOwnRole() async throws {
        let scene = try CutoverScene.make("prov_review_dossier"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        _ = await store.run(now: estimateNow)
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        #expect(roles.set(.editCopy, digests: [ids.master], now: estimateNow.addingTimeInterval(60)) == .set(changed: 1, unchanged: 0))
        #expect(store.shown(of: ids.master, roles: roles) == nil, "the glyph, Inspector and journey show nothing")
        let fileID = try scene.record(.healthy).id.uuidString
        let repository = try #require(scene.model.catalogCutover.committer?.repository)
        let dossier = try #require(try await repository.read { try FileDossier.read(reader: $0, fileID: fileID, now: estimateNow) })
        #expect(dossier.patterns.line("Provenance") == nil, "got: \(dossier.patterns.line("Provenance")?.value ?? "") [\(dossier.patterns.line("Provenance")?.reading ?? "")]")
    }
}

// MARK: - The review's fixes: their own rules (each seen red by breaking the rule)

@Suite("Estimated provenance — review fixes 2026-11-10", .serialized)
@MainActor
struct ProvenanceEstimateReviewFixTests {

    @Test("WITHDRAWAL: a second identical run writes nothing; the OUTCOME counts it; the rule proposing it again brings it back; Rick's confirmed estimate survives")
    func withdrawalIsIdempotentReversibleAndNeverTouchesRicksWord() async throws {
        let scene = try CutoverScene.make("prov_fix_withdraw"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        _ = await store.run(now: estimateNow)
        #expect(store.confirm(digests: [ids.alternate], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        let longer = try #require(CatalogCommit.digest(of: try scene.record(.tombstonedWithDigest)))
        // Longer captures of the same names turn up: `other` and the confirmed `alternate`... stay as the rule says.
        attachFacts(scene.model, ids, extra: [fact(longer, "test_other_tape_full.mkv", folder: "1991", seconds: 7_200)])
        #expect(await store.load() == nil)
        guard case .finished(let first) = await store.run(now: estimateNow.addingTimeInterval(60)) else { Issue.record("expected a finished run"); return }
        #expect(first.withdrawn == 1)
        #expect(first.accounted == first.examined)
        let withdrawnRow = try #require(try await rows(scene.model, ids.other).last)
        #expect(withdrawnRow.field == "role")
        #expect(withdrawnRow.value == "unknown")
        #expect(withdrawnRow.state == "inferred")
        #expect(withdrawnRow.by == ProvenanceEstimateRule.signer)
        #expect(withdrawnRow.evidenceJSON.contains("\"rule\":\"withdrawn\""))
        #expect(withdrawnRow.evidenceJSON.contains("may be a trim"))
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("estimated Master → WITHDRAWN — it is now clearly shorter than a capture of the same name in its folder"), "\(log.suffix(900))")
        #expect(log.contains("; 1 earlier estimate withdrawn"))
        #expect(store.provisionalCount(in: [ids.other], roles: roles) == 0, "nothing to confirm any more")
        #expect(store.confirm(digests: [ids.other], now: estimateNow) == .confirmed(contents: 0, skipped: 1))
        // The same run again: nothing is written.
        let count = try await rowCount(scene.model)
        guard case .finished(let second) = await store.run(now: estimateNow.addingTimeInterval(120)) else { Issue.record("expected a finished run"); return }
        #expect(second.withdrawn == 0)
        #expect(second.estimated == 0)
        #expect(try await rowCount(scene.model) == count)
        // The longer file goes away again: the rule proposes `other` again, and it is shown again.
        attachFacts(scene.model, ids)
        #expect(await store.load() == nil)
        guard case .finished(let third) = await store.run(now: estimateNow.addingTimeInterval(180)) else { Issue.record("expected a finished run"); return }
        #expect(third.estimated == 1)
        #expect(store.estimate(of: ids.other)?.role == .master)
        #expect(store.estimate(of: longer)?.role == .master, "a content this run did not examine keeps its estimate — not examined is not withdrawn")
        // Rick's confirmed alternate: the rule stops proposing it (its file no longer qualifies) — his word stands.
        let withoutAlternate = [fact(ids.master, "test_tape.mkv"), fact(ids.alternate, "test_tape_sd.mkv", codec: "h264"),
                                fact(ids.other, "test_other_tape.mkv", folder: "1991")]
        let backing = try #require(store.backing)
        store.attach(backing, roles: roles, facts: { withoutAlternate })
        #expect(await store.load() == nil)
        guard case .finished(let fourth) = await store.run(now: estimateNow.addingTimeInterval(240)) else { Issue.record("expected a finished run"); return }
        #expect(fourth.withdrawn == 1)
        #expect(fourth.notQualifying == 1)
        #expect(store.estimate(of: ids.alternate)?.isConfirmed == true, "the machine took back only its own row")
        #expect(store.shown(of: ids.alternate, roles: roles)?.isConfirmed == true)
        let fresh = try await relaunch(scene, from: scene.model)
        #expect(fresh.provenanceEstimates.estimate(of: ids.alternate)?.isConfirmed == true)
        if let c = fresh.catalogCutover.committer { await c.repository.close() }
    }

    @Test("TRUTH: Set Role ▸ Unknown after a Confirm takes Rick's word back — every surface shows it provisional again; confirming again makes it his")
    func setRoleUnknownAfterAConfirmMakesItProvisionalAgain() async throws {
        let scene = try CutoverScene.make("prov_fix_unknown"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        _ = await store.run(now: estimateNow)
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        #expect(store.shown(of: ids.master, roles: roles)?.isConfirmed == true)
        #expect(roles.set(.unknown, digests: [ids.master], now: estimateNow.addingTimeInterval(60)) == .set(changed: 1, unchanged: 0))
        let shown = try #require(store.shown(of: ids.master, roles: roles))
        #expect(!shown.isConfirmed)
        let glyph = try #require(ProvenanceEstimateMark.judged(store.estimate(of: ids.master), rickRole: roles.role(of: ids.master),
                                                              captured: captured, timeZone: utc))
        #expect(glyph.help == "Estimated: original capture of a VHS tape, captured July 2026 — not confirmed")
        let line = ProvenanceEstimateMark.inspectorLine(digest: ids.master, reading: await store.readCurrent(digest: ids.master),
                                                        rickRole: roles.role(of: ids.master), year: nil, captured: captured, technical: nil, timeZone: utc)
        #expect(line?.text.hasPrefix("Provenance (estimated): ") == true)
        #expect(store.journey(for: try scene.record(.healthy), roles: roles)?.sentence.hasPrefix("Estimated: ") == true)
        let fileID = try scene.record(.healthy).id.uuidString
        let repository = try #require(scene.model.catalogCutover.committer?.repository)
        let dossier = try #require(try await repository.read { try FileDossier.read(reader: $0, fileID: fileID, now: estimateNow) })
        #expect(dossier.patterns.line("Provenance")?.standing == .observation)
        #expect(dossier.patterns.line("Provenance")?.reading == "estimated, unconfirmed")
        // It is waiting again, and can be confirmed again.
        #expect(store.provisionalCount(in: [ids.master], roles: roles) == 1)
        #expect(store.confirm(digests: [ids.master], now: estimateNow.addingTimeInterval(120)) == .confirmed(contents: 1, skipped: 0))
        #expect(store.shown(of: ids.master, roles: roles)?.isConfirmed == true)
        #expect(try await roleHistory(scene.model, ids.master).map(\.storedRole) == ["master", "unknown", "master"])
        let again = try #require(try await repository.read { try FileDossier.read(reader: $0, fileID: fileID, now: estimateNow) })
        #expect(again.patterns.line("Provenance")?.standing == .fact)
    }

    @Test("CONFIRM is a compare-and-swap on ALL three fields: a shown estimate that differs from the table in role, carrier or setup is refused, nothing is written, the others still land")
    func confirmComparesEveryField() async throws {
        let scene = try CutoverScene.make("prov_fix_cas"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        _ = await store.run(now: estimateNow)
        let truth = try #require(store.estimate(of: ids.master))
        let count = try await rowCount(scene.model)
        var wrongSetup = truth; wrongSetup.captureSetupID = "another-rig"
        var wrongRole = truth; wrongRole.role = .cameraOriginal
        var wrongCarrier = truth; wrongCarrier.carrier = "Hi8"
        for doctored in [wrongSetup, wrongRole, wrongCarrier] {
            guard case .refused(let words) = store.confirm(shown: [ids.master: doctored], selected: 1, now: estimateNow) else {
                Issue.record("expected a refusal for \(doctored)"); continue
            }
            #expect(words.contains("the estimate changed"))
        }
        #expect(try await rowCount(scene.model) == count)
        #expect(try await roleHistory(scene.model, ids.master).isEmpty, "no role either: each content is one transaction")
        // One changed, one true: the true one is confirmed, the outcome still says look again.
        let other = try #require(store.estimate(of: ids.other))
        guard case .refused(let words) = store.confirm(shown: [ids.master: wrongCarrier, ids.other: other], selected: 2, now: estimateNow) else {
            Issue.record("expected a refusal"); return
        }
        #expect(words == "the estimate changed for 1 content — look again, then confirm (1 confirmed)")
        #expect(store.estimate(of: ids.other)?.isConfirmed == true)
        #expect(try await roleHistory(scene.model, ids.master).isEmpty)
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("… NOT confirmed — "))
        #expect(log.contains("the estimate changed for content \(ids.master.prefix(12))… — look again, then confirm. Nothing of it was written"))
        // What was truly shown confirms.
        #expect(store.confirm(shown: [ids.master: truth], selected: 1, now: estimateNow) == .confirmed(contents: 1, skipped: 0))
    }

    @Test("LOGGING: Confirm's commit line and its own line name the confirmed assertion rows, not only the role")
    func confirmsLogNamesTheRows() async throws {
        let scene = try CutoverScene.make("prov_fix_log"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates
        _ = await store.run(now: estimateNow)
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        let log = scene.sandbox.catalogLogText()
        #expect(log.contains("via provenance roles — set role Master on 1 content(s), with Rick's confirmed role, carrier, captureSetup rows (Confirm Provenance)"),
                "\(log.suffix(900))")
        #expect(log.contains("(confirmed rows: role, carrier, captureSetup; role set through Set Role)"))
    }

    @Test("the capture setup needs the file's own 2026 date: another year (or none) is estimated and confirmed WITHOUT a setup")
    func noSetupWithoutTheFilesOwnDate() async throws {
        let scene = try CutoverScene.make("prov_fix_setup"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        let facts = [fact(ids.master, "test_tape.mkv", created: Date(timeIntervalSince1970: 1_560_000_000)),
                     fact(ids.other, "test_other_tape.mkv", folder: "1991", created: nil)]
        store.attach(try #require(store.backing), roles: roles, facts: { facts })
        #expect(await store.run(now: estimateNow) == .finished(.init(examined: 2, estimated: 2, already: 0, vetoed: 0)))
        #expect(try await rows(scene.model, ids.master).map(\.field) == ["role", "carrier"])
        #expect(try await rows(scene.model, ids.other).map(\.field) == ["role", "carrier"])
        #expect(store.estimate(of: ids.master) == ProvenanceEstimate(role: .master, carrier: "VHS", captureSetupID: nil, isConfirmed: false))
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        #expect(try await rows(scene.model, ids.master).filter { $0.by == "rick" }.map(\.field) == ["role", "carrier"])
        #expect(store.estimate(of: ids.master)?.isConfirmed == true)
        let line = ProvenanceEstimateMark.inspectorLine(digest: ids.master, reading: await store.readCurrent(digest: ids.master),
                                                        rickRole: roles.role(of: ids.master), year: 1984, captured: nil, technical: nil, timeZone: utc)
        #expect(line?.text == "Provenance (confirmed by Rick): Original capture of a VHS tape from 1984", "no rig is named")
    }

    @Test("the run's counts add up to 'examined': files that do not qualify and byte copies are counted as such")
    func theRunsCountsAddUp() async throws {
        let scene = try CutoverScene.make("prov_fix_counts"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let trim = try #require(CatalogCommit.digest(of: try scene.record(.tombstonedWithDigest)))
        attachFacts(scene.model, ids, extra: [fact(trim, "test_tape_trim.mkv", seconds: 1_500),
                                              fact(hex(0xbeef), "test_h264.mkv", folder: "2001", codec: "h264"),
                                              fact(ids.other, "test_other_tape_copy.mkv", folder: "1991"),
                                              fact(hex(0xdead), "test_unsaved.mkv", folder: "2002")])
        guard case .finished(let tally) = await scene.model.provenanceEstimates.run(now: estimateNow) else { Issue.record("expected a finished run"); return }
        #expect(tally.examined == 7)
        #expect(tally == .init(examined: 7, estimated: 3, already: 0, vetoed: 0, shorter: 1, notStored: 1, notQualifying: 1, byteCopies: 1, withdrawn: 0))
        #expect(tally.accounted == tally.examined)
        #expect(ProvenanceEstimateStore.summary(tally) == "7 archived videos examined, 3 estimated, 0 already estimated, 0 vetoed, "
                + "1 left unclassified (shorter than a capture of the same name in its folder), 1 not a capture this rule knows, "
                + "1 byte copy of those, 1 not in catalog.sqlite yet (run again)")
    }

    @Test("an OPEN dossier is told at once about Estimate, Confirm, Not Right and Set Role")
    func anOpenDossierHearsEveryProvenanceChange() async throws {
        let scene = try CutoverScene.make("prov_fix_dossier"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        let loader = FileDossierLoader.production(model: scene.model)
        var heard = 0
        let listening = loader.changes.sink { heard += 1 }
        defer { listening.cancel() }
        _ = await store.run(now: estimateNow)
        #expect(heard >= 1, "the estimate run")
        var before = heard
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        #expect(heard > before, "Confirm")
        before = heard
        #expect(store.reject(digest: ids.other, now: estimateNow) == .rejected(.master))
        #expect(heard > before, "Not Right")
        before = heard
        #expect(roles.set(.editCopy, digests: [ids.master], now: estimateNow) == .set(changed: 1, unchanged: 0))
        #expect(heard > before, "Set Role")
    }

    @Test("SENSOR: the Inspector line's body never asks for the master's name (the archive index may rebuild) — only its read task does")
    func theInspectorBodyDoesNoArchiveLookup() throws {
        let mark = try SourceTree.appCode(named: "Provenance/ProvenanceEstimateMark.swift")
        let start = try #require(mark.range(of: "struct InspectorProvenanceEstimateLine"))
        let view = mark[start.lowerBound...]
        let body = try #require(view.range(of: "var body: some View"))
        let task = try #require(view.range(of: ".task(id: key)"))
        #expect(body.lowerBound < task.lowerBound)
        #expect(!view[body.lowerBound..<task.lowerBound].contains("masterName(of"), "an O(records) rebuild is reachable from a view body")
        #expect(view[task.lowerBound...].contains("store.masterName(of: estimate, roles: roles)"))
        let badge = try #require(mark.range(of: "struct ProvenanceEstimateBadge"))
        #expect(!mark[badge.lowerBound..<start.lowerBound].contains("masterName"), "the glyph and the menu never need it")
    }

    @Test("Not Right uses the same visibility rule in its transaction: Unknown after a Confirm can be rejected; a role Rick set otherwise cannot")
    func notRightSeesWhatIsShown() async throws {
        let scene = try CutoverScene.make("prov_fix_reject"); defer { scene.cleanup() }
        let ids = try await launch(scene)
        let store = scene.model.provenanceEstimates, roles = scene.model.provenanceRoles
        _ = await store.run(now: estimateNow)
        #expect(roles.set(.editCopy, digests: [ids.other], now: estimateNow) == .set(changed: 1, unchanged: 0))
        #expect(store.reject(digest: ids.other, now: estimateNow) == .nothingToReject, "nothing is shown for it, so there is nothing to reject")
        #expect(store.confirm(digests: [ids.master], now: estimateNow) == .confirmed(contents: 1, skipped: 0))
        #expect(store.reject(digest: ids.master, now: estimateNow) == .nothingToReject, "a confirmed provenance is changed with Set Role")
        #expect(roles.set(.unknown, digests: [ids.master], now: estimateNow.addingTimeInterval(60)) == .set(changed: 1, unchanged: 0))
        #expect(store.reject(digest: ids.master, now: estimateNow.addingTimeInterval(120)) == .rejected(.master))
        #expect(store.shown(of: ids.master, roles: roles) == nil)
    }
}
