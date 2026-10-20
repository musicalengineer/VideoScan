// ValidateCatalogTests.swift
// "Validate Catalog…" — ONE verb (Rick 2026-10-20): the disk audit, then,
// only when it completed, Verify Catalog, as ONE Media File Operation.
//   LOGIC     — how a run ended → the row's words, the state and the
//               OUTCOME line (pure); the audit-record gate (pure); the job:
//               a complete file check → Verify runs and its report lands;
//               a stopped or failed file check → Verify never made, the
//               OUTCOME says why; Stop is forwarded to the step in flight.
//   ISOLATION — poisoned state beside the catalog (a stale
//               integrity-latest.json, a stale "completed" catalog-audit.json
//               from 2020): a failed file check does not let Verify run on
//               the stale record, and the stale report is left as it was; a
//               good run's tier 0 reads THIS run's record, never the stale one.
//   SENSOR    — the Catalog menu has exactly one checking verb, "Validate
//               Catalog…", and no "Audit Catalog…" / "Verify Catalog…" item;
//               --audit-catalog and --validate-catalog both run this job.
// SCALE: no new O(records) work — the audit's and Verify's own 100k tests
// cover the engines. MEDIA MATRIX: N/A — nothing on media is opened.
//
// Suites (filter by SUITE): ValidateCatalogOutcomeTests ·
// ValidateCatalogJobTests · ValidateCatalogMenuSensorTests

import Foundation
import Testing
@testable import VideoScan

// MARK: - Logic (pure)

@Suite("Validate Catalog — outcome words and the audit-record gate")
struct ValidateCatalogOutcomeTests {

    @Test("both steps completed → finished, 'Validated — files: … · catalog: …', OUTCOME validated")
    func validated() {
        let o = ValidateCatalogEnding.validated(files: "3 present", catalog: "7 tiers ok").outcome(refused: false)
        #expect(o.state == .finished(summary: "Validated — files: 3 present · catalog: 7 tiers ok"))
        #expect(o.logLine == "OUTCOME validated — files: 3 present · catalog: 7 tiers ok")
        #expect(ValidateCatalogEnding.validated(files: "", catalog: "").verifyRan)
    }

    @Test("the file check stopped → Stopped, the catalog NOT checked, and the words say why")
    func filesStopped() {
        let end = ValidateCatalogEnding.filesNotChecked(.stopped)
        let o = end.outcome(refused: false)
        #expect(o.state == .cancelled)
        #expect(!end.verifyRan)
        #expect(o.rowWords.hasPrefix("Stopped while checking files on disk; the marks it saved are kept."), Comment(rawValue: o.rowWords))
        #expect(o.rowWords.hasSuffix(ValidateCatalogEnding.catalogSkipped))
        #expect(o.logLine.hasPrefix("OUTCOME stopped — while checking files on disk"))
    }

    @Test("the file check failed → Failed with the audit's own words (one full stop), the catalog NOT checked; refused → Refused")
    func filesFailed() {
        let end = ValidateCatalogEnding.filesNotChecked(.couldNotComplete("the file check could not complete: Failed — marks undone."))
        let o = end.outcome(refused: false)
        #expect(o.state == .failed(message: o.rowWords))
        #expect(o.rowWords == "Failed — the file check could not complete: Failed — marks undone. " + ValidateCatalogEnding.catalogSkipped)
        #expect(o.logLine.hasPrefix("OUTCOME failed — the file check could not complete"))
        let refused = end.outcome(refused: true)
        #expect(refused.rowWords.hasPrefix("Refused — "))
        #expect(refused.logLine.hasPrefix("OUTCOME refused — "))
    }

    @Test("Stop between the steps, a stale audit record, a stopped or failed catalog check — each in its own words")
    func theOtherEndings() {
        let between = ValidateCatalogEnding.stoppedBetween(files: "3 present").outcome(refused: false)
        #expect(between.state == .cancelled)
        #expect(between.rowWords.contains(ValidateCatalogEnding.catalogSkipped))
        let stale = ValidateCatalogEnding.auditRecordNotThisRun("the record is an older run's", files: "3 present")
        #expect(!stale.verifyRan)
        #expect(stale.outcome(refused: false).rowWords == "Failed — the record is an older run's. Files: 3 present. " + ValidateCatalogEnding.catalogSkipped)
        let catalogStopped = ValidateCatalogEnding.catalogNotChecked(.stopped, files: "3 present")
        #expect(catalogStopped.verifyRan)
        #expect(catalogStopped.outcome(refused: false).state == .cancelled)
        #expect(catalogStopped.outcome(refused: false).rowWords.contains("its report says stopped (partial)"))
        let catalogFailed = ValidateCatalogEnding.catalogNotChecked(.couldNotComplete("the catalog check could not complete: report could not be written"),
                                                                    files: "3 present").outcome(refused: false)
        #expect(catalogFailed.rowWords == "Failed — the catalog check could not complete: report could not be written. Files: 3 present.")
        let busy = ValidateCatalogEnding.couldNotStart("Validate Catalog is already running — wait for it to finish (or stop it)").outcome(refused: true)
        #expect(busy.rowWords == "Refused — Validate Catalog is already running — wait for it to finish (or stop it). Nothing was checked.")
    }

    @Test("ISOLATION (pure): the audit-record gate — none, an older run's, a stopped one → a reason; this run's completed record → nil")
    func theAuditRecordGate() {
        let started = Date(timeIntervalSince1970: 2_000_000_000.7)
        #expect(ValidateCatalogJob.auditRecordProblem(nil, auditStartedAt: started)?.contains("could not be read back") == true)
        var stale = CatalogAuditRunRecord(startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        stale.outcome = .completed
        stale.finishedAt = Date(timeIntervalSince1970: 1_600_000_010)
        #expect(ValidateCatalogJob.auditRecordProblem(stale, auditStartedAt: started)?.contains("an older run's") == true,
                "a completed record from 2020 is not this run's")
        // ISO-8601 whole seconds: the marker's start is truncated to the second the job was made in.
        var mine = CatalogAuditRunRecord(startedAt: Date(timeIntervalSince1970: 2_000_000_000))
        mine.outcome = .stopped
        mine.finishedAt = Date(timeIntervalSince1970: 2_000_000_003)
        #expect(ValidateCatalogJob.auditRecordProblem(mine, auditStartedAt: started)?.contains("says stopped") == true)
        mine.outcome = .completed
        #expect(ValidateCatalogJob.auditRecordProblem(mine, auditStartedAt: started) == nil)
        mine.finishedAt = nil
        #expect(ValidateCatalogJob.auditRecordProblem(mine, auditStartedAt: started) != nil, "no finish time = not completed")
    }
}

// MARK: - The job (sandboxed catalog folder, real small files)

@MainActor
struct ValidateScene {
    let sandbox: ShowAgainSandbox

    var folder: URL { URL(fileURLWithPath: sandbox.model.catalogStore.fileLocation).deletingLastPathComponent() }
    var reportURL: URL { folder.appendingPathComponent(IntegrityReportStore.latestFileName) }
    var auditRecordURL: URL { folder.appendingPathComponent(CatalogAuditRunMarker.fileName) }

    static func make(_ label: String, rows: Int = 3) throws -> ValidateScene {
        let sb = try ShowAgainSandbox.make("validate_\(label)")
        try FileManager.default.createDirectory(at: sb.catalogDir, withIntermediateDirectories: true)
        for i in 0..<rows { try sb.live("clip\(i).mov", bytes: 2_000 + i) }
        guard sb.model.saveCatalogNow() else { throw CocoaError(.fileWriteUnknown) }
        return ValidateScene(sandbox: sb)
    }

    func cleanup() { sandbox.cleanup() }

    /// POISON: a stale integrity-latest.json and a stale COMPLETED audit
    /// record from 2020, beside the catalog.
    func poison() throws -> Data {
        let staleReport = Data("{\"poison\": \"a report from another day\"}".utf8)
        try staleReport.write(to: reportURL)
        var stale = CatalogAuditRunRecord(startedAt: Date(timeIntervalSince1970: 1_600_000_000))
        stale.outcome = .completed
        stale.finishedAt = Date(timeIntervalSince1970: 1_600_000_010)
        stale.counts = ["present": 3, "planned": 3]
        try CatalogAuditRunMarker.encoder.encode(stale).write(to: auditRecordURL)
        return staleReport
    }

    /// The job, its steps pointed at the sandbox (the audit's lane is the
    /// sandbox folder, mounted; Verify reads no shared events store).
    func job() -> ValidateCatalogJob {
        let job = ValidateCatalogJob(model: sandbox.model, marker: CatalogAuditRunMarker())
        let laneRoot = sandbox.laneRoot
        job.configureAuditForTesting = { audit in
            audit.volumeOnline = { _ in true }
            audit.laneRoot = laneRoot
            audit.tickMilliseconds = 20
        }
        job.configureVerifyForTesting = { $0.eventsForTesting = [] }
        return job
    }

    func run(_ configure: (ValidateCatalogJob) -> Void = { _ in }) async -> ValidateCatalogJob {
        let job = job()
        configure(job)
        await TestHostDrive.identified {
            job.start()
            await job.task?.value
        }
        return job
    }

    func log() -> String { sandbox.catalogLogText() }
}

@Suite("Validate Catalog — the job", .serialized)
@MainActor
struct ValidateCatalogJobTests {

    @Test("LOGIC: a complete file check → Verify runs, its report lands beside the catalog; ONE START and ONE OUTCOME of the job, in order around the steps' own lines")
    func aCompleteFileCheckThenVerify() async throws {
        let scene = try ValidateScene.make("ok"); defer { scene.cleanup() }
        let job = await scene.run()
        guard case .finished(let summary) = job.state else { Issue.record("expected finished, got \(job.state) — \(job.subtitle)"); return }
        #expect(summary.hasPrefix("Validated — files: "), Comment(rawValue: summary))
        #expect(job.kind == .validateCatalog)
        #expect(job.title == "Validate Catalog")
        #expect(job.phase == .done)
        #expect(job.fraction == 1)
        #expect(job.auditJob?.stampedCount == 3)
        let report = try #require(job.verifyJob?.report)
        #expect(report.outcome == .completed)
        #expect(FileManager.default.fileExists(atPath: scene.reportURL.path))
        let log = scene.log()
        #expect(log.components(separatedBy: "Validate Catalog: START — ").count == 2, Comment(rawValue: log))
        #expect(log.components(separatedBy: "Validate Catalog: OUTCOME ").count == 2, Comment(rawValue: log))
        let order = ["Validate Catalog: START — step 1 of 2 checks every file on disk", "Audit catalog: START", "Audit catalog: OUTCOME",
                     "Verify catalog: START", "Verify catalog: OUTCOME", "Validate Catalog: OUTCOME validated — files: "]
        let positions = order.map { log.range(of: $0)?.lowerBound }
        #expect(!positions.contains(nil), Comment(rawValue: log))
        let found = positions.compactMap { $0 }
        #expect(found == found.sorted(), Comment(rawValue: log))
    }

    @Test("ISOLATION (poisoned state): a stale 'completed' audit record from 2020 beside the catalog — tier 0 of the run's Verify reads THIS run's record, and the stale report is replaced")
    func aGoodRunNeverReadsTheStaleRecord() async throws {
        let scene = try ValidateScene.make("poison_ok"); defer { scene.cleanup() }
        let staleReport = try scene.poison()
        let job = await scene.run()
        #expect(job.state == .finished(summary: job.subtitle), Comment(rawValue: job.subtitle))
        let audit = try #require(job.auditJob)
        let tier0 = try #require(job.verifyJob?.report?.tier(0))
        let verifiedAt = try #require(tier0.verifiedAt)
        #expect(verifiedAt.timeIntervalSince1970 >= audit.startedAt.timeIntervalSince1970.rounded(.down),
                "tier 0 stood on the stale 2020 record (\(verifiedAt))")
        #expect(try Data(contentsOf: scene.reportURL) != staleReport)
    }

    @Test("LOGIC + ISOLATION: the file check fails (its save is not acknowledged) with a stale 'completed' record and a stale report beside the catalog → Verify is never made, the stale report is left byte-for-byte, the OUTCOME says the catalog was not checked")
    func aFailedFileCheckNeverRunsVerify() async throws {
        let scene = try ValidateScene.make("poison_fail"); defer { scene.cleanup() }
        let staleReport = try scene.poison()
        let job = await scene.run { job in
            let configure = job.configureAuditForTesting
            job.configureAuditForTesting = { audit in
                configure?(audit)
                audit.saveCatalogForTesting = { false }
            }
        }
        guard case .failed(let message) = job.state else { Issue.record("expected failed, got \(job.state)"); return }
        #expect(message.hasPrefix("Failed — the file check could not complete: Failed — marks undone"), Comment(rawValue: message))
        #expect(message.hasSuffix(ValidateCatalogEnding.catalogSkipped), Comment(rawValue: message))
        #expect(job.verifyJob == nil, "Verify must not run on a failed file check")
        #expect(job.ending?.verifyRan == false)
        #expect(try Data(contentsOf: scene.reportURL) == staleReport, "the stale report is left as it was")
        let log = scene.log()
        #expect(!log.contains("Verify catalog: START"), Comment(rawValue: log))
        #expect(log.contains("Validate Catalog: OUTCOME failed — the file check could not complete"), Comment(rawValue: log))
        #expect(log.contains("The catalog was NOT checked against itself"), Comment(rawValue: log))
        #expect(CatalogAuditCLI.exitCode(for: job) == 1)
    }

    @Test("LOGIC: Stop before the file check gets going → the audit ends Stopped, Verify is never made, the row is Stopped and says the catalog was not checked")
    func aStoppedFileCheckNeverRunsVerify() async throws {
        let scene = try ValidateScene.make("stop"); defer { scene.cleanup() }
        let job = await scene.run { $0.cancel() }
        #expect(job.state == .cancelled, Comment(rawValue: "\(job.state) — \(job.subtitle)"))
        #expect(job.auditJob?.state == .cancelled)
        #expect(job.verifyJob == nil)
        #expect(job.subtitle.hasPrefix("Stopped while checking files on disk"), Comment(rawValue: job.subtitle))
        #expect(job.subtitle.hasSuffix(ValidateCatalogEnding.catalogSkipped))
        #expect(scene.log().contains("Validate Catalog: OUTCOME stopped — while checking files on disk"))
        #expect(!scene.log().contains("Verify catalog: START"))
        #expect(CatalogAuditCLI.exitCode(for: job) == 4)
    }

    @Test("a read-only (viewer) catalog: the file check refuses, so Validate refuses and Verify never runs (CLI exit 3)")
    func aReadOnlyCatalogRefuses() async throws {
        let scene = try ValidateScene.make("viewer"); defer { scene.cleanup() }
        scene.sandbox.model.applyReadOnlyMode(true)
        let job = await scene.run()
        #expect(job.wasRefused)
        #expect(job.verifyJob == nil)
        #expect(job.subtitle.hasPrefix("Refused — the file check could not complete"), Comment(rawValue: job.subtitle))
        #expect(CatalogAuditCLI.exitCode(for: job) == 3)
    }

    @Test("the center: one checker at a time — a second Validate, or a bare audit / Verify while Validate runs, is refused with words")
    func oneCheckerAtATime() async throws {
        let sb = try ShowAgainSandbox.make("validate_center"); defer { sb.cleanup() }
        let center = MediaFileOperationsCenter()
        let running = ValidateCatalogJob(model: sb.model, marker: CatalogAuditRunMarker())
        #expect(center.add(running))                                    // active, never started: no work
        let second = center.startValidateCatalog(model: sb.model, marker: CatalogAuditRunMarker())
        let audit = center.startCatalogAudit(model: sb.model, marker: nil)
        let verify = center.startVerifyCatalog(model: sb.model)
        #expect(second.wasRefused)
        #expect(second.subtitle.hasPrefix("Refused — Validate Catalog is already running"), Comment(rawValue: second.subtitle))
        #expect(audit.wasRefused && audit.subtitle.hasPrefix("Validate Catalog is running and runs its own file check"), Comment(rawValue: audit.subtitle))
        #expect(verify.wasRefused && verify.subtitle.hasPrefix("Validate Catalog is running and runs its own catalog check"), Comment(rawValue: verify.subtitle))
        running.refuseToStart(reason: "test over")
        #expect(center.validateRunsItsOwn("file check") == nil)
    }
}

// MARK: - Sensors

@Suite("Validate Catalog — sensors: one verb in the menu, one job behind the launch arguments")
@MainActor
struct ValidateCatalogMenuSensorTests {

    static func code(_ name: String) throws -> String {
        SourceTree.strippingComments(try SourceTree.appSource(named: name))
    }

    @Test("SENSOR: the Catalog menu has exactly ONE checking verb, \"Validate Catalog…\" — no \"Audit Catalog…\" and no \"Verify Catalog…\" item anywhere in the app's menus")
    func exactlyOneVerbInTheMenu() throws {
        let app = try Self.code("VideoScanApp.swift")
        #expect(app.components(separatedBy: "ValidateCatalogMenuItem(model: catalogModel, center: fileOpsCenter,").count == 2)
        #expect(app.contains("marker: catalogModel.catalogAuditRunMarker"))
        #expect(!app.contains("CatalogAuditMenuItem(") && !app.contains("VerifyCatalogMenuItem("))
        let item = try Self.code("ValidateCatalogMenuItem.swift")
        #expect(item.components(separatedBy: "Button(").count == 2, "one button")
        #expect(item.contains("Button(\"Validate Catalog…\")"))
        #expect(item.contains("$0.startValidateCatalog(model: model, marker: marker)"))
        for source in SourceTree.appSources {
            let text = SourceTree.strippingComments(try String(contentsOf: source.url, encoding: .utf8))
            // A Button titled with either retired verb, anywhere in the app.
            for retired in ["\"Audit Catalog…\"", "\"Verify Catalog…\"", "Button(\"Audit Catalog", "Button(\"Verify Catalog"]
            where text.contains(retired) {
                Issue.record("\(source.relative) still offers \(retired)")
            }
        }
        #expect(!SourceTree.appSources.contains { $0.relative.hasSuffix("/CatalogAuditMenuItem.swift") || $0.relative.hasSuffix("/VerifyCatalogMenuItem.swift") },
                "the two retired menu items are gone")
    }

    @Test("SENSOR: --audit-catalog (the nightly) and --validate-catalog both run the ONE Validate Catalog job; stdout keeps the argument's prefix")
    func bothLaunchArgumentsRunTheCombinedJob() throws {
        #expect(CatalogAuditCLI.isRequested(by: ["/x/VideoScan", "--audit-catalog"]))
        #expect(CatalogAuditCLI.isRequested(by: ["/x/VideoScan", "--validate-catalog", "--quiet"]))
        #expect(!CatalogAuditCLI.isRequested(by: ["/x/VideoScan", "--find-tag"]))
        #expect(try CatalogAuditCLI.parse(["--audit-catalog", "--quiet"]).quiet)
        #expect(try !CatalogAuditCLI.parse(["--validate-catalog"]).quiet)
        #expect(CatalogAuditCLI.outputTag(for: ["--audit-catalog"]) == "audit-catalog")
        #expect(CatalogAuditCLI.outputTag(for: ["--validate-catalog"]) == "validate-catalog")
        let sb = try ShowAgainSandbox.make("validate_cli"); defer { sb.cleanup() }
        let job = CatalogAuditCLI.makeJob(model: sb.model)
        #expect(job.kind == .validateCatalog)
        let cli = try Self.code("CatalogAuditCLI.swift")
        #expect(cli.contains("let job = makeJob(model: model)"))
        #expect(!cli.contains("CatalogAuditJob("), "the CLI never runs the bare audit")
        let main = try Self.code("main.swift")
        #expect(main.contains("let isCatalogAudit = CatalogAuditCLI.isRequested(by: CommandLine.arguments)"))
    }

    @Test("SENSOR: the Integrity row and its 'Validate again' door start Validate Catalog, never Verify alone; the kind is registered with its own chip")
    func theDoorsPointAtValidate() throws {
        #expect(CatalogStatusDoor.verifyAgain.title == "Validate again")
        #expect(CatalogStatusDoor.verifyAgainHelp.hasPrefix("Run Validate Catalog again"))
        #expect(!AnalyzeCycler.integrity.help.contains("Verify Catalog"))
        let runner = try Self.code("AnalyzeRunner.swift")
        #expect(runner.contains("_ = c.startValidateCatalog(model: model, marker: model.catalogAuditRunMarker)"))
        #expect(!runner.contains("startVerifyCatalog("))
        #expect(MediaFileOperationKind.all.contains(.validateCatalog))
        #expect(MediaFileOperationKind.validateCatalog.badgeText == "Validate Catalog")
        #expect(MediaFileOperationKind.validateCatalog.hasDetailView)
    }
}
