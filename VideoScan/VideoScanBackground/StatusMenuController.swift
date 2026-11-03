// StatusMenuController.swift — VideoScan Background
//
// The menu bar item (Rick 2026-11-03): Apple's place for a background agent.
// Shows the helper is alive and what it is doing, and offers Pause / Resume
// and Open VideoScan. Words come from BackgroundMenuPresentation (Core, pure,
// tested); this file only draws them and forwards clicks to the supervisor
// in this process. It never contacts the app: "Open VideoScan" asks
// Launch Services to open the app bundle this helper lives in.
//
// The glyph refreshes every 5 s (one in-process status call — a handful of
// small structs); the menu is rebuilt each time it opens.

import AppKit
import VideoScanCore

@MainActor
final class StatusMenuController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let supervisor: JobSupervisor
    private let startedAt: Date
    private let log: BackgroundFileLog
    private var presentation: BackgroundMenuPresentation?
    private var timer: Timer?

    init(supervisor: JobSupervisor, startedAt: Date, log: BackgroundFileLog) {
        self.supervisor = supervisor
        self.startedAt = startedAt
        self.log = log
        super.init()
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        item.button?.image = StatusMenuIcon.image(.idle)
        item.button?.toolTip = "VideoScan Background"
        item.button?.setAccessibilityIdentifier("background.menuBar")
    }

    func start() {
        refresh()
        let t = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        t.tolerance = 1
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func refresh(then: (@MainActor () -> Void)? = nil) {
        let pid = ProcessInfo.processInfo.processIdentifier
        Task { [supervisor, startedAt] in
            let status = await supervisor.status(processIdentifier: pid, startedAt: startedAt)
            let p = BackgroundMenuPresentation.from(status)
            await MainActor.run {
                if p.icon != self.presentation?.icon { self.item.button?.image = StatusMenuIcon.image(p.icon) }
                self.item.button?.toolTip = p.tooltip
                self.presentation = p
                then?()
            }
        }
    }

    // MARK: NSMenuDelegate

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild() }
    }

    private func rebuild() {
        menu.removeAllItems()
        guard let p = presentation else {
            menu.addItem(disabled("VideoScan Background — starting…"))
            return
        }
        menu.addItem(disabled(p.headline))
        for job in p.jobs {
            menu.addItem(disabled(job.words))
            if job.canPause { menu.addItem(action("Pause", #selector(pauseJob(_:)), job.id)) }
            if job.canResume { menu.addItem(action("Resume", #selector(resumeJob(_:)), job.id)) }
        }
        menu.addItem(.separator())
        let open = NSMenuItem(title: "Open VideoScan", action: #selector(openApp), keyEquivalent: "")
        open.target = self
        open.isEnabled = Self.appURL != nil
        menu.addItem(open)
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func action(_ title: String, _ selector: Selector, _ id: JobID) -> NSMenuItem {
        let i = NSMenuItem(title: "    " + title, action: selector, keyEquivalent: "")
        i.target = self
        i.representedObject = id.rawValue
        return i
    }

    // MARK: Actions (one log line each, like the XPC verbs)

    @objc private func pauseJob(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let id = JobID(rawValue: raw)
        Task { [supervisor, log] in
            let ok = await supervisor.pause(id)
            log.write("menu bar: pause \(raw) — \(ok ? "accepted" : "refused (not running)")")
            await MainActor.run { self.refresh() }
        }
    }

    @objc private func resumeJob(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        let id = JobID(rawValue: raw)
        Task { [supervisor, log] in
            let ok = await supervisor.resume(id)
            log.write("menu bar: resume \(raw) — \(ok ? "accepted" : "refused (not paused)")")
            await MainActor.run { self.refresh() }
        }
    }

    /// The app bundle this helper is embedded in:
    /// VideoScan.app/Contents/Library/LoginItems/VideoScan Background.app
    static var appURL: URL? {
        let app = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return app.pathExtension == "app" ? app : nil
    }

    @objc private func openApp() {
        guard let url = Self.appURL else { return }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration()) { [log] _, error in
            log.write("menu bar: Open VideoScan — \(error.map { "failed: \($0.localizedDescription)" } ?? "opened \(url.path)")")
        }
    }
}
