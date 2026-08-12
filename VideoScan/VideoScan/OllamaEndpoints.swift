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
// MIGRATION RULE. A first cut promoted any legacy `archivist.ollamaHost`
// to the FRONT, reasoning that its presence implied a deliberate choice.
// codex caught two holes in that (#313) and was right on both:
//
//   * No UI has ever written that key, so presence implies nothing — it
//     could be the old default persisted by any code path that touched
//     the binding.
//   * Even a genuinely deliberate old value has been SUPERSEDED: Rick
//     designated the M4 as master on 2026-08-12. A stale preference must
//     not outrank the instruction that replaced it.
//
// So the defaults lead, always. A legacy host that merely names a
// default is folded in (deduped, M4 still first). A legacy host naming
// something ELSE is a machine we would otherwise forget about, so it is
// preserved — APPENDED after the defaults, available as a fallback
// without displacing the designated primary.
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

    /// Normalize one user-entered endpoint.
    ///
    /// An earlier version STRIPPED any scheme and port, on the assumption
    /// that every endpoint was a bare `.local` box on plain http at
    /// 11434. Rick then asked for cloud endpoints too (2026-08-12), and
    /// a cloud endpoint is exactly the case that assumption destroys:
    /// `https://ollama.example.com` would have been mangled to
    /// `ollama.example.com` and then dialled over http on port 11434.
    ///
    /// So scheme and port are PRESERVED when the user supplies them, and
    /// defaulted only when they do not. All this function does is trim,
    /// drop a trailing slash, and reject empties — `chatURLString` owns
    /// the defaulting.
    static func normalize(_ raw: String) -> String? {
        var h = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while h.hasSuffix("/") { h.removeLast() }
        h = h.trimmingCharacters(in: .whitespaces)
        return h.isEmpty ? nil : h
    }

    /// True when the endpoint names its own scheme, and is therefore a
    /// full URL we must not second-guess.
    static func hasScheme(_ endpoint: String) -> Bool {
        let lower = endpoint.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://")
    }

    /// Full chat URL for one endpoint.
    ///
    ///   `RicksM4.local`               → http://RicksM4.local:11434/api/chat
    ///   `RicksM4.local:1234`          → http://RicksM4.local:1234/api/chat
    ///   `https://ollama.example.com`  → https://ollama.example.com/api/chat
    ///
    /// A schemed endpoint keeps whatever port it was given, or none —
    /// appending :11434 to an https cloud host would break it, since TLS
    /// endpoints answer on 443 through their own front door.
    static func chatURLString(for endpoint: String, defaultPort: Int) -> String {
        guard let e = normalize(endpoint) else { return "" }
        if hasScheme(e) { return e + "/api/chat" }
        // Bare host: add http and the default port unless a port is
        // already spelled out. IPv6 literals in brackets keep their
        // colons, so only a colon AFTER a closing bracket counts.
        let portSeparator = e.hasPrefix("[")
            ? e.range(of: "]:").map { e.index(after: $0.lowerBound) }
            : e.lastIndex(of: ":")
        let hasPort = portSeparator != nil
        return hasPort
            ? "http://\(e)/api/chat"
            : "http://\(e):\(defaultPort)/api/chat"
    }

    /// Short label for the UI — the bit a human recognises.
    static func displayLabel(for endpoint: String) -> String {
        guard let e = normalize(endpoint) else { return endpoint }
        guard hasScheme(e), let url = URL(string: e), let host = url.host else { return e }
        return host
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
    /// 1. An explicit list wins outright — that IS the user's order.
    /// 2. Otherwise the defaults lead (M4 primary), with a legacy host
    ///    APPENDED only if it names a machine the defaults do not.
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
        var out = defaultHosts
        if let legacy = defaults.string(forKey: legacyHostKey),
           let host = normalize(legacy),
           !out.contains(where: { $0.lowercased() == host.lowercased() }) {
            // A machine we would otherwise forget — kept as a fallback,
            // never ahead of the designated primary.
            out.append(host)
        }
        return out
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
