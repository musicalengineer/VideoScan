// CatalogAuditCLI.swift — the headless "Audit Catalog" run (--audit-catalog).
//
// The nightly's door to the SAME job the Catalog menu starts
// (CatalogAuditJob): it loads the catalog the way the app does
// (VideoScanModel on CatalogStore.shared), runs one audit, prints the
// OUTCOME line and quits. Same headless-Aqua arrangement as --find-tag
// (App/main.swift). Nothing else of the app starts: no scenes, no
// catalog sync, no daemons.
//
// Single writer: the catalog is one file with one writer at a time. This
// process REFUSES when the VideoScan app is open on this Mac — its in-
// memory catalog would go stale the moment the audit saved, and the app
// would refuse its own next save as "stale generation". The audit then
// belongs inside the app (Catalog ▸ Audit Catalog…). A viewer-role Mac
// (CatalogSync says so by hostname) refuses the same way the app does:
// the model is read-only there and the job refuses before any stat.
//
// Exit codes: 0 completed · 1 failed · 2 usage · 3 refused (app open,
// read-only, test host) · 4 stopped by SIGTERM/SIGINT (partial, saved).
//
// Invocation:
//   VideoScan.app/Contents/MacOS/VideoScan --audit-catalog [--quiet]

import AppKit
import Foundation
import VideoScanCore

enum CatalogAuditCLI {

    static let usage = "usage: VideoScan --audit-catalog [--quiet]"

    struct Options {
        var quiet = false
    }

    static func parse(_ arguments: [String]) throws -> Options {
        var options = Options()
        for arg in arguments where arg != "--audit-catalog" {
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
        let options: Options
        do { options = try parse(arguments) } catch {
            fputs("audit-catalog: \(error.localizedDescription)\n", stderr)
            return 2
        }
        let others = otherVideoScanInstances()
        guard others.isEmpty else {
            let pids = others.map { String($0.processIdentifier) }.joined(separator: ", ")
            fputs("audit-catalog: refused — VideoScan is open on this Mac (pid \(pids)); the catalog has one writer. "
                  + "Run Catalog ▸ Audit Catalog… there instead.\n", stderr)
            return 3
        }

        // The role the app would run under (master / viewer by hostname),
        // installed before the model reads it. CatalogSync.production() only
        // reads defaults and the hostname; it starts no sync.
        let sync = CatalogSync.production()
        ViewerModeCenter.shared.install(sync.viewerRole)
        let model = VideoScanModel()
        model.applyReadOnlyMode(sync.isReadOnly)
        let marker = CatalogAuditRunMarker()
        let job = CatalogAuditJob(model: model, marker: marker)
        installStopSignals(job)

        if !options.quiet { print("audit-catalog: \(model.records.count) records · \(model.catalogStore.fileLocation)") }
        job.start()
        await job.task?.value
        // The job's own OUTCOME went to the console sink, catalog.log and
        // videoscan.log; stdout gets the row's summary for the nightly's log.
        if !options.quiet { print("audit-catalog: \(job.subtitle)") }
        model.catalogStore.relinquishLock()
        return exitCode(for: job)
    }

    @MainActor
    static func exitCode(for job: CatalogAuditJob) -> Int32 {
        switch job.state {
        case .finished: return 0
        case .cancelled: return 4
        case .failed: return job.wasRefused ? 3 : 1
        case .running, .cancelling: return 1
        }
    }

    /// SIGTERM / SIGINT (the nightly's timeout, a Ctrl-C) → Stop: the chunk
    /// in flight finishes, the marks so far are saved, OUTCOME says partial.
    @MainActor
    private static func installStopSignals(_ job: CatalogAuditJob) {
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
