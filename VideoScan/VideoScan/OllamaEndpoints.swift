// OllamaEndpoints.swift
// The ordered list of hosts the Family Archivist will try, in order.
//
// WHY THIS EXISTS. The Archivist pointed at a single hard-coded host,
// `ricksm5.local` — the MacBook Pro. A laptop sleeps, leaves the house,
// and runs on battery, and Rick hit exactly that: the Archivist hanging
// because its brain had gone to sleep in a bag. Rick and codex moved the
// model to the M4 Studio (2026-08-12), which is mains-powered and stays
// put, with the laptop demoted to fallback.
//
// So the host is no longer one string but an ORDERED LIST, tried in
// sequence. The M4 answers when it is up; the M5 covers the window when
// it is not; further hosts (the M1, a future Studio) can be appended
// without touching code.
//
// MIGRATION RULE, and why it is not the obvious one. The old default was
// `ricksm5.local`, and `@AppStorage` does not persist a default until
// the user changes it — so the mere PRESENCE of `archivist.ollamaHost`
// means someone deliberately set that host. A deliberate choice must not
// be silently demoted by a new default, so a legacy host is migrated to
// the FRONT of the list rather than dropped or appended. Absence of the
// key means "never configured", which the new default order can claim
// freely.
//
// Pure and injectable: every function takes its `UserDefaults`, so tests
// never touch the real preferences plist (the settings-pollution class).

import Foundation

enum OllamaEndpoints {

    /// Default order as of 2026-08-12: the mains-powered Studio first,
    /// the laptop as backup. Hostnames carry `.local` — this fleet is
    /// resolved over Bonjour and a bare name does not resolve.
    static let defaultHosts = ["RicksM4.local", "ricksm5.local"]

    /// Newline/comma-tolerant persisted list.
    static let hostsKey = "archivist.ollamaHosts"
    /// Pre-2026-08-12 single-host key. Read for migration, never written.
    static let legacyHostKey = "archivist.ollamaHost"

    /// Normalize one user-entered host: trim, drop any scheme or port a
    /// user pasted in, and discard empties. Returns nil if nothing
    /// usable survives.
    static func normalize(_ raw: String) -> String? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty else { return nil }
        for scheme in ["http://", "https://"] where h.lowercased().hasPrefix(scheme) {
            h = String(h.dropFirst(scheme.count))
        }
        // A pasted "host:11434" would otherwise become part of the
        // hostname and fail to resolve; the port is configured
        // separately on the translator.
        if let colon = h.firstIndex(of: ":") { h = String(h[h.startIndex..<colon]) }
        if h.hasSuffix("/") { h.removeLast() }
        h = h.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? nil : h
    }

    /// Parse a stored list. Accepts commas or newlines so the value can
    /// be edited by hand with `defaults write` without ceremony.
    /// De-duplicates case-insensitively, preserving first-seen order.
    static func parse(_ raw: String) -> [String] {
        let pieces = raw.split(whereSeparator: { $0 == "," || $0 == "\n" })
        var seen = Set<String>()
        var out: [String] = []
        for piece in pieces {
            guard let h = normalize(String(piece)) else { continue }
            let key = h.lowercased()
            if seen.insert(key).inserted { out.append(h) }
        }
        return out
    }

    static func serialize(_ hosts: [String]) -> String {
        hosts.joined(separator: ",")
    }

    /// The list to try, in order.
    ///
    /// 1. An explicit list wins outright.
    /// 2. Otherwise, a legacy single host goes FIRST (it was a
    ///    deliberate choice — see the header), followed by any default
    ///    hosts it does not already name.
    /// 3. Otherwise the defaults.
    ///
    /// Never returns an empty array: an empty list would leave the
    /// Archivist with nowhere to ask and no way for the user to tell
    /// why, so a wiped preference falls back to the defaults.
    static func resolved(from defaults: UserDefaults) -> [String] {
        if let raw = defaults.string(forKey: hostsKey) {
            let hosts = parse(raw)
            if !hosts.isEmpty { return hosts }
        }
        if let legacy = defaults.string(forKey: legacyHostKey),
           let host = normalize(legacy) {
            var out = [host]
            for d in defaultHosts where d.lowercased() != host.lowercased() {
                out.append(d)
            }
            return out
        }
        return defaultHosts
    }

    /// Persist an explicit order. Writing an empty list clears the
    /// preference rather than storing "", so `resolved` falls back to
    /// the defaults instead of returning nothing.
    static func save(_ hosts: [String], to defaults: UserDefaults) {
        let cleaned = parse(serialize(hosts))
        if cleaned.isEmpty {
            defaults.removeObject(forKey: hostsKey)
        } else {
            defaults.set(serialize(cleaned), forKey: hostsKey)
        }
    }
}
