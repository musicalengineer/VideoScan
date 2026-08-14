// DriveTempsMenuBar.swift
//
// A single-file macOS menu-bar indicator for drive temperatures.
// Green / yellow / red at a glance so heat gets caught early.
//
// Build:  swiftc -O scripts/DriveTempsMenuBar.swift -o ~/bin/drivetemps
// Run:    ~/bin/drivetemps &
//
// No bundle needed -- it sets .accessory activation policy so it lives in
// the menu bar with no Dock icon and no window.
//
// Two design notes worth keeping:
//
// 1. Devices are found by PRODUCT NAME, never by /dev/diskN. External
//    identifiers get renumbered on every reconnect -- the LaCie moved
//    disk6 -> disk24 in a single evening -- so hardcoding them silently
//    reads the wrong disk or nothing at all.
//
// 2. Thresholds differ by medium on purpose. Drive-reliability studies
//    put HDD failure rates up sharply past ~45-50 C, while an SN850X does
//    not throttle until ~80 C. A single shared ceiling would either nag
//    about the NVMe constantly or stay silent while a spinning disk cooks.

import AppKit
import Foundation

// MARK: - Model

enum Status: Int, Comparable {
    case green = 0, yellow = 1, red = 2
    var dot: String {
        switch self {
        case .green:  return "🟢"
        case .yellow: return "🟡"
        case .red:    return "🔴"
        }
    }
    static func < (a: Status, b: Status) -> Bool { a.rawValue < b.rawValue }
}

/// (yellow at, red at) in Celsius, by storage medium.
func limits(for medium: String) -> (Int, Int) {
    medium == "hdd" ? (42, 48) : (55, 70)
}

struct Reading: Decodable {
    let label: String
    let celsius: Int?
    let medium: String
    let note: String

    var status: Status? {
        guard let t = celsius else { return nil }
        let (warn, crit) = limits(for: medium)
        if t >= crit { return .red }
        if t >= warn { return .yellow }
        return .green
    }
}

private struct Payload: Decodable { let drives: [Reading] }

// MARK: - Sensing

enum Sensor {
    static let smartctl = "/opt/homebrew/bin/smartctl"
    static let diskutil = "/usr/sbin/diskutil"

    /// Candidate install locations, first match wins. /usr/local/sbin does
    /// not exist on a stock Apple Silicon Mac, so bin is the usual home.
    static let helperPaths = [
        "/usr/local/bin/vs-drive-temps",
        "/usr/local/sbin/vs-drive-temps",
    ]

    static var helper: String? {
        helperPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Product-name fragment -> (friendly label, medium). Matched against
    /// diskutil's "Device / Media Name".
    static let known: [(match: String, label: String, medium: String)] = [
        ("APPLE SSD",        "Internal SSD", "ssd"),
        ("WD_BLACK SN850XE", "PRO-G40 NVMe", "ssd"),
        ("d2 Professional",  "LaCie d2",     "hdd"),
        ("CT2000X9SSD9",     "Crucial X9",   "ssd"),
        ("CT2000X10SSD9",    "Crucial X10",  "ssd"),
    ]

    static let needsSAT = ["d2 Professional", "CT2000X9SSD9", "CT2000X10SSD9"]

    private static func run(_ path: String, _ args: [String], timeout: Double = 30) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || !data.isEmpty else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func parseTemp(_ text: String) -> Int? {
        for raw in text.split(separator: "\n") {
            let s = String(raw)
            if s.hasPrefix("Temperature:") {
                let n = s.drop(while: { !$0.isNumber }).prefix(while: { $0.isNumber })
                if let v = Int(n) { return v }
            }
            if s.contains("Temperature_Celsius") || s.contains("Current Drive Temperature") {
                if let last = s.split(separator: " ").last(where: { Int($0) != nil }),
                   let v = Int(last) { return v }
            }
        }
        return nil
    }

    /// Find live devices by product name so reconnect renumbering cannot
    /// point us at the wrong disk.
    private static func discover() -> [(dev: String, label: String, medium: String, product: String)] {
        guard let list = run(diskutil, ["list", "-plist", "physical"]) else { return [] }
        var seen = Set<String>()
        var out: [(String, String, String, String)] = []
        for m in list.ranges(of: try! Regex(#"<string>(disk\d+)</string>"#)) {
            let node = String(list[m]).replacingOccurrences(of: "<string>", with: "")
                                      .replacingOccurrences(of: "</string>", with: "")
            guard !seen.contains(node) else { continue }
            seen.insert(node)
            guard let info = run(diskutil, ["info", node]),
                  let line = info.split(separator: "\n")
                                 .first(where: { $0.contains("Device / Media Name:") })
            else { continue }
            let product = line.split(separator: ":", maxSplits: 1)[1]
                              .trimmingCharacters(in: .whitespaces)
            if let k = known.first(where: { product.lowercased().contains($0.match.lowercased()) }) {
                out.append(("/dev/\(node)", k.label, k.medium, product))
            }
        }
        return out
    }

    /// Privileged path first: one call returns every drive including the
    /// USB-bridged disks and the Promise members. Falls back to whatever
    /// is readable unprivileged.
    static func readAll() -> (readings: [Reading], elevated: Bool) {
        if let helper,
           let json = run("/usr/bin/sudo", ["-n", helper], timeout: 45),
           let data = json.data(using: .utf8),
           let payload = try? JSONDecoder().decode(Payload.self, from: data),
           !payload.drives.isEmpty {
            return (payload.drives, true)
        }

        var results: [Reading] = []
        for d in discover() {
            var args = ["-A"]
            if needsSAT.contains(where: { d.product.lowercased().contains($0.lowercased()) }) {
                args += ["-d", "sat"]
            }
            args.append(d.dev)
            let temp = run(smartctl, args).flatMap(parseTemp)
            results.append(Reading(label: d.label, celsius: temp, medium: d.medium,
                                   note: temp == nil ? "needs sudo helper" : ""))
        }
        return (results, false)
    }

    /// CPU speed limit is a free proxy for how hard the room is pushing back.
    static func cpuSpeedLimit() -> Int? {
        guard let out = run("/usr/bin/pmset", ["-g", "therm"]),
              let r = out.range(of: "CPU_Speed_Limit") else { return nil }
        let tail = out[r.upperBound...].drop(while: { !$0.isNumber })
        return Int(tail.prefix(while: { $0.isNumber }))
    }
}

// MARK: - Menu bar

final class Controller: NSObject {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var timer: Timer?
    private var lastAlerted: Status = .green

    override init() {
        super.init()
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        refresh()
        // 60s is plenty -- drive temperatures move slowly.
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func refresh() {
        let (readings, elevated) = Sensor.readAll()
        let overall = readings.compactMap(\.status).max() ?? .green

        // Show a number only when something needs attention; a bare dot
        // the rest of the time keeps the menu bar quiet.
        let hot = readings.filter { ($0.status ?? .green) > .green }
        if let worst = hot.compactMap(\.celsius).max() {
            item.button?.title = "\(overall.dot) \(worst)°"
        } else {
            item.button?.title = overall.dot
        }

        rebuild(readings, overall: overall, elevated: elevated)

        // Alert only on the way UP, so a sustained yellow does not nag.
        if overall > lastAlerted, overall > .green {
            let detail = hot.map { "\($0.label) \($0.celsius ?? 0)°C" }.joined(separator: ", ")
            notify(title: "Drive temperature: \(overall == .red ? "RED" : "YELLOW")", body: detail)
        }
        lastAlerted = overall
    }

    private func rebuild(_ readings: [Reading], overall: Status, elevated: Bool) {
        guard let menu = item.menu else { return }
        menu.removeAllItems()

        for r in readings {
            let text: String
            if let t = r.celsius, let s = r.status {
                text = "\(s.dot)  \(r.label): \(t)°C"
            } else {
                text = "○  \(r.label): — \(r.note.isEmpty ? "" : "(\(r.note))")"
            }
            menu.addItem(NSMenuItem(title: text, action: nil, keyEquivalent: ""))
        }

        if let limit = Sensor.cpuSpeedLimit(), limit < 100 {
            menu.addItem(.separator())
            menu.addItem(NSMenuItem(title: "⚠️  CPU throttled to \(limit)%",
                                    action: nil, keyEquivalent: ""))
        }

        menu.addItem(.separator())
        if !elevated {
            menu.addItem(NSMenuItem(title: "Limited: install sudo helper for all drives",
                                    action: nil, keyEquivalent: ""))
        }
        let r = NSMenuItem(title: "Refresh Now", action: #selector(refreshNow), keyEquivalent: "r")
        r.target = self
        menu.addItem(r)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    @objc private func refreshNow() { refresh() }

    private func notify(title: String, body: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", "display notification \"\(body)\" with title \"\(title)\""]
        try? p.run()
    }
}

extension Controller: NSMenuDelegate {
    // Re-read on open so the numbers are never stale.
    func menuWillOpen(_ menu: NSMenu) { refresh() }
}

// MARK: - Entry

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // menu bar only: no Dock icon, no window
let controller = Controller()
app.run()
