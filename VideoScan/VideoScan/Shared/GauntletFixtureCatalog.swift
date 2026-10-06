// GauntletFixtureCatalog.swift
// Test-host-only seams for the Catalog keyboard harness
// (docs/design/catalog_window_architecture_2026_10_06.md §6,
// VideoScanUITests/Gauntlet/CatalogKeyboardUITests.swift).
//
// 1. `-gauntletFixtureCatalog <json>` — a synthetic catalog: N volumes
//    (scan targets) and their `test_*` files, loaded straight into the
//    model with no ffprobe and no scan, so the harness starts in seconds.
//    JSON shape: {"volumes":[{"path":"/abs/dir","files":["test_a.mov",…]}]}
//    Refused (with a log line) unless the JSON and every volume path sit
//    inside the Gauntlet's per-run sandbox (the parent of the fake HOME,
//    named gauntlet_*) and every file name starts with `test_`. Never
//    real family data, never a real catalog.
//
// 2. The `[keys]` trace — a local NSEvent monitor that records the first
//    responder on mouseDown and on ↑ ↓ Tab Space, before AND after AppKit
//    dispatches the event. It writes `keys.log` beside the fixture JSON
//    (inside the sandbox) so the UI test can attach it. It observes only:
//    it always returns the event untouched and never moves focus.
//
// Both are dead code in production: GauntletSeams' getters return nil
// unless TestEnvironment.isTestHost (VS_UI_TEST=1 under the Gauntlet).

import AppKit
import Foundation
import VideoScanCore

/// Decoded fixture file. `Decodable` ≈ a C++ struct with a generated
/// from-JSON constructor.
struct GauntletFixtureCatalogSpec: Decodable {
    struct Volume: Decodable {
        let path: String
        let files: [String]
    }
    let volumes: [Volume]

    /// The per-run sandbox the Gauntlet created: the parent of the fake
    /// HOME, and only if it is a `gauntlet_*` directory. nil = refuse.
    static func sandboxRoot(home: String?) -> String? {
        guard let home, !home.isEmpty else { return nil }
        let parent = (home as NSString).deletingLastPathComponent
        guard (parent as NSString).lastPathComponent.hasPrefix("gauntlet_") else { return nil }
        return (parent as NSString).standardizingPath
    }

    /// Pure guard: every path inside the sandbox, every file `test_*`.
    /// Returns the refusal reason, or nil when the spec is acceptable.
    func refusal(jsonPath: String, sandbox: String) -> String? {
        let root = sandbox.hasSuffix("/") ? sandbox : sandbox + "/"
        func inside(_ p: String) -> Bool {
            (p as NSString).standardizingPath.hasPrefix(root)
        }
        if !inside(jsonPath) { return "fixture JSON is outside the Gauntlet sandbox" }
        for vol in volumes {
            if !inside(vol.path) { return "volume \(vol.path) is outside the Gauntlet sandbox" }
            if let bad = vol.files.first(where: { !$0.hasPrefix("test_") || $0.contains("/") }) {
                return "file \(bad) is not a test_* fixture name"
            }
        }
        return nil
    }
}

extension GauntletSeams {
    /// `-gauntletFixtureCatalog <json>` — see the file header.
    static var fixtureCatalogPath: String? {
        guard TestEnvironment.isTestHost else { return nil }
        guard let value = UserDefaults.standard.string(forKey: "gauntletFixtureCatalog"),
              !value.isEmpty else { return nil }
        return value
    }
}

extension VideoScanModel {

    /// Called from restoreScanTargets()'s test-host branch. Adds one
    /// scanned-looking target per fixture volume and one Video+Audio
    /// record per fixture file, then starts the `[keys]` trace.
    func installGauntletFixtureCatalogIfRequested() {
        guard let jsonPath = GauntletSeams.fixtureCatalogPath else { return }
        guard let sandbox = GauntletFixtureCatalogSpec.sandboxRoot(
                home: ProcessInfo.processInfo.environment["HOME"]) else {
            log("Gauntlet fixture catalog refused: no gauntlet_* sandbox HOME.")
            return
        }
        guard let data = FileManager.default.contents(atPath: jsonPath),
              let spec = try? JSONDecoder().decode(GauntletFixtureCatalogSpec.self, from: data) else {
            log("Gauntlet fixture catalog refused: cannot read \(jsonPath).")
            return
        }
        if let reason = spec.refusal(jsonPath: jsonPath, sandbox: sandbox) {
            log("Gauntlet fixture catalog refused: \(reason).")
            return
        }
        var fixtureRecords: [VideoRecord] = []
        for vol in spec.volumes {
            let target = CatalogScanTarget(searchPath: vol.path)
            target.lastScannedDate = Date()
            scanTargets.append(target)
            fixtureRecords += vol.files.map { Self.gauntletFixtureRecord(name: $0, directory: vol.path) }
        }
        records = fixtureRecords
        log("Gauntlet seam: fixture catalog \(spec.volumes.count) volumes, \(fixtureRecords.count) files.")
        GauntletKeyTrace.start(logURL: URL(fileURLWithPath: jsonPath)
            .deletingLastPathComponent().appendingPathComponent("keys.log"))
    }

    private static func gauntletFixtureRecord(name: String, directory: String) -> VideoRecord {
        let rec = VideoRecord()
        rec.filename = name
        rec.ext = (name as NSString).pathExtension
        rec.directory = directory
        rec.fullPath = (directory as NSString).appendingPathComponent(name)
        rec.streamTypeRaw = StreamType.videoAndAudio.rawValue
        rec.sizeBytes = 1024
        rec.size = "1 KB"
        rec.duration = "00:00:01"
        rec.durationSeconds = 1
        return rec
    }
}

/// The `[keys]` first-responder trace. `@MainActor` ≈ "this must run on
/// the UI thread" — NSEvent monitors and firstResponder are main-thread
/// only. An `enum` with only statics ≈ a C++ namespace with file-static
/// state.
@MainActor
enum GauntletKeyTrace {
    private static var monitor: Any?
    private static var handle: FileHandle?

    /// Worst-case memory: one open FileHandle and one short line per
    /// traced event; nothing is buffered in memory.
    static func start(logURL: URL) {
        guard monitor == nil else { return }
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        handle = try? FileHandle(forWritingTo: logURL)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown]) { event in
            if let label = label(for: event) {
                write("\(label) before: \(describeFirstResponder())")
                // After AppKit has dispatched the event (next main-queue turn).
                DispatchQueue.main.async { write("\(label) after: \(describeFirstResponder())") }
            }
            return event   // observe only — never consume
        }
    }

    /// A free-form note from app code (e.g. the Space live-preview toggle).
    static func note(_ text: String) {
        guard monitor != nil else { return }
        write("note: \(text)")
    }

    private static func label(for event: NSEvent) -> String? {
        if event.type == .leftMouseDown { return "mouseDown" }
        switch event.keyCode {
        case 125: return "key ↓"
        case 126: return "key ↑"
        case 48:  return event.modifierFlags.contains(.shift) ? "key ⇧Tab" : "key Tab"
        case 49:  return "key Space"
        default:  return nil
        }
    }

    /// "NSTableView rows=3 y=… < NSClipView < …" — the class chain from the
    /// first responder up to the nearest table, plus that table's row count
    /// (the volumes table has one row per volume, the files table one per
    /// file, which is how the harness tells them apart).
    private static func describeFirstResponder() -> String {
        guard let window = NSApp.keyWindow else { return "no key window" }
        guard let responder = window.firstResponder else { return "nil" }
        guard let view = responder as? NSView else { return String(describing: type(of: responder)) }
        var chain: [String] = []
        var node: NSView? = view
        while let current = node, chain.count < 12 {
            if let table = current as? NSTableView {
                let y = Int(table.convert(table.bounds, to: nil).maxY)
                chain.append("NSTableView(rows=\(table.numberOfRows) top=\(y))")
                break
            }
            // Generic SwiftUI host names run to kilobytes; the outer name is enough.
            chain.append(String(String(describing: type(of: current)).prefix(60)))
            node = current.superview
        }
        return chain.joined(separator: " < ")
    }

    private static func write(_ line: String) {
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        handle.write(data)
    }
}
