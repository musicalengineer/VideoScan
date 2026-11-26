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

    /// True when the endpoint is THIS Mac — the only place the Local brain
    /// may send family media (GH #450; rule 13; DECISIONS 2026-10-10 R6:
    /// the data-class policy is enforced in the adapter). Decided by the
    /// HOST the URL actually dials, never by how it is spelled: loopback or
    /// one of this Mac's own names (`OllamaLocalServerBootstrap
    /// .currentLocalHostNames()`). A cloud row (`https://ollama.example.com`),
    /// a userinfo trick (`http://localhost@evil.example`), a look-alike
    /// (`localhost.example.com`) and another Mac on the LAN are all not this
    /// Mac. (The fleet Macs are not listed as local in ARCHITECTURE or
    /// DECISIONS, so they are treated as off this Mac — fail closed.)
    ///
    /// An IP literal is compared as an ADDRESS, never as text (Codex round 1:
    /// `[0:0:0:0:0:0:0:1]` is `::1`): any 127/8, `::1`, or IPv4-mapped
    /// `::ffff:127/8` is loopback; any other literal is local only if it is
    /// the same address as one of `thisMacNames`. Only inet_pton's strict
    /// forms are addresses — shorthand like `127.1` stays refused (fail closed).
    static func isOnThisMac(_ endpoint: String, thisMacNames: Set<String>) -> Bool {
        let chat = chatURLString(for: endpoint, defaultPort: 11434)
        guard let url = URL(string: chat), let host = url.host, !host.isEmpty else { return false }
        let target = normalizedHost(host)
        if let address = IPAddress(target) {
            if address.isLoopback { return true }
            return thisMacNames.contains { IPAddress(normalizedHost($0)) == address }
        }
        let names = Set(thisMacNames.map(normalizedHost))
        return names.contains(target)
    }

    /// Lower-cased, without a trailing root dot or IPv6 brackets.
    private static func normalizedHost(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: ".[]")).lowercased()
    }

    /// A strictly parsed IPv4 / IPv6 literal, as its canonical bytes.
    /// IPv4-mapped IPv6 (`::ffff:a.b.c.d`) is folded to its IPv4 address.
    struct IPAddress: Equatable {
        let bytes: [UInt8]   // 4 (IPv4) or 16 (IPv6)

        init?(_ text: String) {
            var v4 = in_addr()
            if inet_pton(AF_INET, text, &v4) == 1 {
                bytes = withUnsafeBytes(of: &v4) { Array($0) }
                return
            }
            var v6 = in6_addr()
            guard inet_pton(AF_INET6, text, &v6) == 1 else { return nil }
            let raw = withUnsafeBytes(of: &v6) { Array($0) }
            let mappedPrefix: [UInt8] = Array(repeating: 0, count: 10) + [0xff, 0xff]
            bytes = Array(raw.prefix(12)) == mappedPrefix ? Array(raw.suffix(4)) : raw
        }

        var isLoopback: Bool {
            bytes.count == 4 ? bytes[0] == 127 : bytes == Array(repeating: 0, count: 15) + [1]
        }
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

    /// Liveness URL for one endpoint. `/api/tags` is ollama's cheapest
    /// honest endpoint: it answers only if the server is actually up and
    /// serving, and it returns immediately rather than generating.
    static func tagsURLString(for endpoint: String, defaultPort: Int) -> String {
        let chat = chatURLString(for: endpoint, defaultPort: defaultPort)
        guard chat.hasSuffix("/api/chat") else { return chat }
        return String(chat.dropLast("chat".count)) + "tags"
    }

    /// `/api/ps` — what this server currently holds in memory, which is a
    /// different question from `/api/tags` ("what could it load"). The gap
    /// between them is the cold-load a first question pays.
    static func psURLString(for endpoint: String, defaultPort: Int) -> String {
        let chat = chatURLString(for: endpoint, defaultPort: defaultPort)
        guard chat.hasSuffix("/api/chat") else { return chat }
        return String(chat.dropLast("chat".count)) + "ps"
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

/// The URLSession every Ollama HTTP call goes through (GH #450, Codex round 1).
///
/// The family-media gate checks the URL it is about to dial; a server that
/// answers 307 would move the POST — method and body kept (RFC 9110) — to a
/// host the gate never saw. Ollama has no reason to redirect, so this session
/// refuses EVERY redirect, for every class: the 3xx becomes the final reply,
/// which `classify` turns into an error, so the call fails closed. (Refusing
/// all rather than "all off this Mac" keeps one rule with nothing to spoof.)
/// The `.curl` transport never follows redirects either: it runs without -L.
enum OllamaHTTP {
    static let session = makeSession(configuration: .default)

    /// Tests pass a configuration carrying a URLProtocol stub; the redirect
    /// policy is the production one either way.
    static func makeSession(configuration: URLSessionConfiguration) -> URLSession {
        URLSession(configuration: configuration, delegate: OllamaRedirectRefusal(), delegateQueue: nil)
    }
}

/// Answers every "may I follow this redirect?" with no. Stateless, so
/// Sendable. (C++: a callback object whose one hook always returns nullptr.)
/// Completion-handler form on purpose: the async form of this delegate
/// method crashes swift-frontend's @objc thunk emission (Swift 6.4).
final class OllamaRedirectRefusal: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
