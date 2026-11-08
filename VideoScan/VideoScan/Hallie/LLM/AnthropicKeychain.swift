// AnthropicKeychain.swift
// Where the cloud brain's API key comes from: the macOS Keychain, and only
// the Keychain (DECISIONS 2026-10-10 — never UserDefaults, plists, logs or
// git). The key lives in memory for one request and is never printed: the
// wrapper's description is redacted, so an accidental "\(key)" in a log line
// or crash text says "<redacted>".

import Foundation
import Security

/// Read-only Keychain access, injected so tests use a fake and never touch
/// the real login keychain (and never raise its access prompt).
protocol HallieKeychainReading: Sendable {
    /// The password of the first generic-password item matching
    /// service (and account, when given). Nil when there is none.
    func password(service: String, account: String?) -> String?
    /// Whether such an item exists, WITHOUT reading its secret — attributes
    /// only, so the Settings pane can say "key found" with no access prompt.
    func hasItem(service: String, account: String?) -> Bool
}

/// The secret, wrapped so it cannot be logged by accident.
struct AnthropicAPIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let value: String
    /// Which Keychain item it came from — safe to show and log.
    let source: String
    var description: String { "<redacted>" }
    var debugDescription: String { "<redacted>" }
}

/// Lookup order (Rick 2026-11-06 / the E1 harness's item):
///   1. service `anthropic-api-key` (any account) — Rick's Console key;
///   2. service `hallie-e1`, account `anthropic` — scripts/hallie_e1/keys.py.
enum AnthropicKeyLocator {
    static let primaryService = "anthropic-api-key"
    static let harnessService = "hallie-e1"
    static let harnessAccount = "anthropic"

    static let order: [(service: String, account: String?)] = [
        (primaryService, nil),
        (harnessService, harnessAccount),
    ]

    static func locate(in keychain: any HallieKeychainReading) -> AnthropicAPIKey? {
        for item in order {
            if let raw = keychain.password(service: item.service, account: item.account) {
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return AnthropicAPIKey(value: trimmed, source: label(item))
                }
            }
        }
        return nil
    }

    /// Which item WOULD supply the key, without reading any secret.
    static func presentSource(in keychain: any HallieKeychainReading) -> String? {
        order.first { keychain.hasItem(service: $0.service, account: $0.account) }
            .map(label)
    }

    private static func label(_ item: (service: String, account: String?)) -> String {
        item.account.map { "\(item.service) / \($0)" } ?? item.service
    }
}

/// The real login keychain via Security.framework (the app is not sandboxed,
/// so items made with `security add-generic-password` are visible; the first
/// read raises macOS's own "allow access" prompt, which is Rick's to answer).
struct SystemKeychain: HallieKeychainReading {
    func password(service: String, account: String?) -> String? {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func hasItem(service: String, account: String?) -> Bool {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnAttributes as String] = true
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    private func baseQuery(service: String, account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        if let account { query[kSecAttrAccount as String] = account }
        return query
    }
}
