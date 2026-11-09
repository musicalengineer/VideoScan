// main.swift — VideoScan Background
//
// The launchd agent inside VideoScan.app (Contents/Library/LoginItems/,
// registered by the app through SMAppService; docs/design/background_service.md).
// Two modes in ONE binary:
//
//   • no arguments → the SERVICE. The same headless-Aqua arrangement as the
//     app's `--find-tag` (App/main.swift): NSApplication with the
//     `.accessory` activation policy, because the jobs this process will
//     host (Vision, CoreML, MLX) need an application context; LSUIElement
//     keeps it out of the Dock and the menu bar item shows it is running.
//     launchd starts it at registration and login (RunAtLoad + KeepAlive)
//     and restarts it after a crash; it owns its schedule (JobSchedule) and
//     never exits on idle. Unregistering sends SIGTERM → exit 0, and
//     `KeepAlive {SuccessfulExit false}` leaves it down (off = not running).
//     The menu bar's Quit (Rick 2026-11-08) exits 0 the same way and writes
//     a marker so an on-demand launch (an XPC client) exits again at once.
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
} else if BackgroundService.quitHoldsUsDown() {
    // Quit from the menu bar in this boot (BackgroundQuitMarker): exit 0,
    // launchd leaves it down until VideoScan clears the marker or a reboot.
    exit(0)
} else {
    let serviceApp = NSApplication.shared
    // `.accessory` (was `.prohibited`, Rick 2026-11-03): still no Dock icon
    // (LSUIElement), but allowed the menu bar item that says the helper is
    // alive and what it is doing (StatusMenuController).
    serviceApp.setActivationPolicy(.accessory)
    let service = BackgroundService(arguments: arguments)
    service.start()
    service.installMenuBar()
    RunLoop.main.run()
}
