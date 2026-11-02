// CatalogMasterSetting.swift — Settings ▸ Catalog Master (Rick 2026-11-02,
// after the M4 ran as a second master for a week on a missing defaults key):
// "a user should be able to designate Master; anyone else, by definition,
// is not a master. Only one machine is master and I decide."
//
// One sentence: the pane shows the ONE defaults key the launch reads
// (`CatalogSyncDefaultsKey.masterHostname`, else the built-in default), lets
// Rick set it to any Mac's name or to this Mac with one click, and says what
// this Mac is as a result — master, or a viewer whose catalog is read-only —
// and whether a relaunch is needed, because the role is decided once, at
// launch (CatalogSync.launchMode), before the catalog opens.
//
// No negotiation: the setting is per Mac and names the master; a Mac whose
// own name is not the master's is a viewer. Two Macs can each name
// themselves — Rick decides, and the line on each pane says what that Mac
// is, so a wrong pair is visible, never silent.
//
// A feature store behind a seam (rule 12): the app owns one; defaults, the
// hostname and the launch role are injected; the pure words are tested.

import Combine
import Foundation

/// The pure rules: what the key says, what this Mac is, what to say.
/// Main-actor because `CatalogSync.hostnameMatches` is (CatalogSync is).
@MainActor
enum CatalogMasterSetting {

    static let key = CatalogSyncDefaultsKey.masterHostname

    /// The master the launch would use: the key, else the built-in default.
    static func effective(_ defaults: UserDefaults) -> (hostname: String, explicit: Bool) {
        if let saved = defaults.string(forKey: key)?.trimmingCharacters(in: .whitespacesAndNewlines), !saved.isEmpty {
            return (saved, true)
        }
        return (defaultMasterHostname, false)
    }

    /// Trimmed; empty removes the key (back to the built-in default).
    static func save(_ hostname: String, to defaults: UserDefaults) -> String {
        let trimmed = hostname.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(trimmed, forKey: key)
        }
        return effective(defaults).hostname
    }

    /// "RicksUltra.local" → "RicksUltra".
    static func display(_ hostname: String) -> String {
        hostname.hasSuffix(".local") ? String(hostname.dropLast(".local".count)) : hostname
    }

    /// What this Mac is under `master`.
    static func role(thisMac: String, master: String) -> CatalogSyncMode {
        CatalogSync.hostnameMatches(local: thisMac, master: master) ? .master : .viewer
    }

    /// The line under the field. Every word follows from the three inputs.
    static func words(thisMac: String, master: String, explicit: Bool, launchedAs: CatalogSyncMode, launchedWith: String) -> String {
        let me = display(thisMac)
        let role = role(thisMac: thisMac, master: master)
        var line: String
        switch role {
        case .master:
            line = "This Mac (\(me)) is the catalog master — every other Mac is a viewer."
        case .viewer:
            line = "This Mac (\(me)) is a viewer — the catalog is read-only here, synced from \(display(master))."
        }
        if !explicit { line += " Built-in default; not set on this Mac." }
        if !CatalogSync.hostnameMatches(local: master, master: launchedWith) || role != launchedAs {
            line += " Takes effect when VideoScan relaunches — it launched as \(launchedAs == .master ? "the master" : "a viewer") of \(display(launchedWith))."
        }
        return line
    }
}

@MainActor
final class CatalogMasterStore: ObservableObject {
    /// The master's name as the key says it (or the built-in default).
    @Published private(set) var master: String
    @Published private(set) var explicit: Bool
    let thisMac: String
    /// What the running app decided at launch, and from which name.
    let launchedAs: CatalogSyncMode
    let launchedWith: String

    private let defaults: UserDefaults
    var log: (String) -> Void

    init(defaults: UserDefaults, thisMac: String, launchedAs: CatalogSyncMode, launchedWith: String, log: @escaping (String) -> Void = { _ in }) {
        self.defaults = defaults
        self.thisMac = thisMac
        self.launchedAs = launchedAs
        self.launchedWith = launchedWith
        self.log = log
        let e = CatalogMasterSetting.effective(defaults)
        master = e.hostname
        explicit = e.explicit
    }

    /// The real thing: the standard defaults, this Mac's name, and the role
    /// the launch read from the same key a moment ago.
    static func production(log: @escaping (String) -> Void) -> CatalogMasterStore {
        let launched = CatalogMasterSetting.effective(.standard).hostname
        return CatalogMasterStore(defaults: .standard, thisMac: SystemHostnameSource().currentHostname(),
                                  launchedAs: CatalogSync.launchMode(), launchedWith: launched, log: log)
    }

    var role: CatalogSyncMode { CatalogMasterSetting.role(thisMac: thisMac, master: master) }

    var words: String {
        CatalogMasterSetting.words(thisMac: thisMac, master: master, explicit: explicit, launchedAs: launchedAs, launchedWith: launchedWith)
    }

    /// The one setter: the field's submit and "Use This Mac".
    func setMaster(_ hostname: String) {
        let before = master
        master = CatalogMasterSetting.save(hostname, to: defaults)
        explicit = CatalogMasterSetting.effective(defaults).explicit
        guard master != before else { return }
        log("Catalog master set to \(master) (was \(before)); this Mac (\(thisMac)) is \(role == .master ? "the master" : "a viewer") — takes effect at the next launch")
    }

    func useThisMac() { setMaster(thisMac) }
}
