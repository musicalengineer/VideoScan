// CatalogAuditCLI.swift — the headless "Validate Catalog" run
// (--validate-catalog, and the older --audit-catalog the nightly calls).
//
// The nightly's door to the SAME job the Catalog menu starts
// (ValidateCatalogJob, Rick 2026-10-20: ONE verb — every file on disk, then,
// only after a complete file check, the catalog against itself): it loads
// the catalog the way the app does (VideoScanModel on CatalogStore.shared),
// runs one validation, prints the OUTCOME line and quits. Same
// headless-Aqua arrangement as --find-tag (App/main.swift). Nothing else of
// the app starts: no scenes, no catalog sync, no daemons.
//
// Single writer: the catalog is one file with one writer at a time. This
// process REFUSES when the VideoScan app is open on this Mac — its in-
// memory catalog would go stale the moment the audit saved, and the app
// would refuse its own next save as "stale generation". The run then
// belongs inside the app (Catalog ▸ Validate Catalog…). A viewer-role Mac
// (CatalogSync says so by hostname) refuses the same way the app does:
// the model is read-only there and the file check refuses before any stat
// (so the catalog check never runs either).
//
// Exit codes: 0 completed (both steps) · 1 failed · 2 usage · 3 refused
// (app open, read-only, test host) · 4 stopped by SIGTERM/SIGINT (partial,
// saved).
//
// Invocation:
//   VideoScan.app/Contents/MacOS/VideoScan --validate-catalog [--quiet]
//   VideoScan.app/Contents/MacOS/VideoScan --audit-catalog [--quiet]   (the same job)

import AppKit
import Foundation
import VideoScanCore

enum CatalogAuditCLI {

    /// The launch arguments that start this run (either one; the nightly
    /// still passes the older name).
    static let launchArguments: Set<String> = ["--validate-catalog", "--audit-catalog"]

    static let usage = "usage: VideoScan --validate-catalog [--quiet]   (--audit-catalog is the same run)"

    struct Options {
        var quiet = false
    }

    /// True when `arguments` ask for this run.
    static func isRequested(by arguments: [String]) -> Bool {
        arguments.contains { launchArguments.contains($0) }
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        for arg in arguments where !launchArguments.contains(arg) {
            switch arg {
            case "--quiet": options.quiet = true
            default:
                throw NSError(domain: "CatalogAuditCLI", code: 2,
                              userInfo: [NSLocalizedDescriptionKey: "unknown argument \(arg)\n\(usage)"])
            }
        }
        return options
    }

    /// Other VideoScan processes with the app's bundle id (the GUI, or
    /// another headless run). The find-tag daemon has its own pidfile and
    /// is not an app bundle instance by this test; it never writes the
    /// catalog, so it does not matter here.
    static func otherVideoScanInstances() -> [NSRunningApplication] {
        guard let bundleID = Bundle.main.bundleIdentifier else { return [] }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != me }
    }

    @MainActor
    static func run(arguments: [String]) async -> Int32 {
        // stdout / stderr keep the prefix of the argument used, so the
        // nightly's existing "audit-catalog:" greps still match.
        let tag = outputTag(for: arguments)
        let options: Options
        do { options = try parse(arguments) } catch {
            fputs("\(tag): \(error.localizedDescription)\n", stderr)
            return 2
        }
        let others = otherVideoScanInstances()
        guard others.isEmpty else {
            let pids = others.map { String($0.processIdentifier) }.joined(separator: ", ")
            fputs("\(tag): refused — VideoScan is open on this Mac (pid \(pids)); the catalog has one writer. "
                  + "Run Catalog ▸ Validate Catalog… there instead.\n", stderr)
            return 3
        }

        // The role the app would run under (master / viewer by hostname),
        // installed before the model reads it. CatalogSync.production() only
        // reads defaults and the hostname; it starts no sync.
        let sync = CatalogSync.production()
        ViewerModeCenter.shared.install(sync.viewerRole)
        let model = VideoScanModel()
        model.applyReadOnlyMode(sync.isReadOnly)
        let job = makeJob(model: model)
        installStopSignals(job)

        if !options.quiet { print("\(tag): \(model.records.count) records · \(model.catalogStore.fileLocation)") }
        job.start()
        await job.task?.value
        // The job's own OUTCOME went to the console sink, catalog.log and
        // videoscan.log; stdout gets the row's summary for the nightly's log.
        if !options.quiet { print("\(tag): \(job.subtitle)") }
        model.catalogStore.relinquishLock()
        return exitCode(for: job)
    }

    /// "validate-catalog" when that argument was given, else "audit-catalog".
    static func outputTag(for arguments: [String]) -> String {
        arguments.contains("--validate-catalog") ? "validate-catalog" : "audit-catalog"
    }

    /// The one job both launch arguments run — the menu's job, with a
    /// marker of its own (the headless process has no app-owned one).
    @MainActor
    static func makeJob(model: VideoScanModel) -> ValidateCatalogJob {
        ValidateCatalogJob(model: model, marker: CatalogAuditRunMarker())
    }

    @MainActor
    static func exitCode(for job: any MediaFileOperationJob) -> Int32 {
        switch job.state {
        case .finished: return 0
        case .cancelled: return 4
        case .failed: return job.wasRefused ? 3 : 1
        case .running, .cancelling: return 1
        }
    }

    /// SIGTERM / SIGINT (the nightly's timeout, a Ctrl-C) → Stop: the step
    /// in flight ends at its boundary, the marks so far are saved, OUTCOME
    /// says stopped.
    @MainActor
    private static func installStopSignals(_ job: ValidateCatalogJob) {
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)
        for sig in [SIGTERM, SIGINT] {
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { MainActor.assumeIsolated { job.cancel() } }
            source.resume()
            stopSources.append(source)
        }
    }

    /// Kept alive for the process lifetime (a released source stops firing).
    @MainActor private static var stopSources: [DispatchSourceSignal] = []
}
