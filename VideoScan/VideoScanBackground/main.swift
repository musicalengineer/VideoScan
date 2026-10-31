// main.swift — VideoScan Background
//
// The launchd agent inside VideoScan.app (Contents/Library/LoginItems/,
// registered by the app through SMAppService; docs/design/background_service_2026_10_30.md).
// Two modes in ONE binary:
//
//   • no arguments → the SERVICE. The same headless-Aqua arrangement as the
//     app's `--find-tag` (App/main.swift): NSApplication with the
//     `.prohibited` activation policy, because the jobs this process will
//     host (Vision, CoreML, MLX) need an application context, and
//     `.prohibited` keeps it out of the Dock. launchd starts it on the first
//     XPC message and relaunches it after a crash; it exits itself after 10
//     idle minutes (IdleExitPolicy) so `KeepAlive: SuccessfulExit false`
//     leaves it down until the next message.
//
//   • `--status | --pause <id> | --resume <id> | --stop <id> | --enqueue noop`
//     → the CLIENT: this is the design's `videoscan-bg` CLI folded into the
//     helper binary (one bundle to sign, one code path for the wire). It
//     connects to the running service over XPC (launchd starts the service
//     if it is down), prints ONE line and exits. Used by Rick with the app
//     closed and by the nightly.
//
// Nothing here touches catalog.sqlite except through BackgroundCatalogAccess
// (read-only by construction); BackgroundServiceSensorTests proves the
// built binary carries no committer symbol.

import AppKit
import Foundation
import VideoScanCore

let arguments = Array(CommandLine.arguments.dropFirst())

if let verb = BackgroundCLI.verb(in: arguments) {
    // videoscan-bg: a client, one line, exit.
    Task {
        let code = await BackgroundCLI.run(verb)
        fflush(stdout)
        fflush(stderr)
        exit(code)
    }
    RunLoop.main.run()
} else {
    let serviceApp = NSApplication.shared
    serviceApp.setActivationPolicy(.prohibited)
    let service = BackgroundService(arguments: arguments)
    service.start()
    RunLoop.main.run()
}
