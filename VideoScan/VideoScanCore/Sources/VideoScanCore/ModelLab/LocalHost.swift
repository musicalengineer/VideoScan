// LocalHost.swift (VideoScanCore/ModelLab)
// ONE SENTENCE: the one place a host string is judged "on Rick's machines" —
// a validated value decided at construction, so `ApproachHost.ollama` can
// only ever carry hosts that passed (CLAUDE.md rule 13 carried by TYPE, not
// by a label; reviewer R1 on 4aeb28f5).
//
// For Rick (C++): a strong typedef with a validating constructor —
// `explicit LocalHost(std::string)` that yields nullopt instead of ever
// holding a value it did not check. There is no other way to make one.
//
// Accepted, and nothing else:
//   • an optional plain scheme prefix "http://" — a TLS endpoint ("https://")
//     is the cloud shape OllamaEndpoints admits for Hallie, and is refused
//     here outright;
//   • then a host that is `localhost`, a loopback literal (127.0.0.0/8, ::1),
//     an mDNS name ending in `.local` (the fleet: RicksM4.local, ricksm5.local),
//     an RFC 1918 literal (10/8, 172.16/12, 192.168/16), or a link-local
//     literal (169.254/16, fe80::/10);
//   • an optional :port (1…65535); no path, query, fragment, userinfo or
//     whitespace.
// An empty host list is "not local": `ApproachHost.ollama(hosts: [])` is
// refused by the gate, the registry and preflight alike.
//
// MEMORY: two short strings per host.

import Foundation

public struct LocalHost: Hashable, Sendable, CustomStringConvertible {
    /// As given, trimmed.
    public let rawValue: String
    /// The host part, lowercased, without scheme or port.
    public let hostName: String
    public let port: Int?

    public var description: String { rawValue }

    /// nil unless `raw` names a host on the local machine or the local
    /// network by one of the shapes in the file comment.
    public init?(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed == raw.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var rest = Substring(trimmed)
        let lower = trimmed.lowercased()
        if lower.hasPrefix("https://") { return nil }
        if lower.hasPrefix("http://") { rest = rest.dropFirst("http://".count) }
        guard !rest.isEmpty,
              rest.unicodeScalars.allSatisfy({ !CharacterSet.whitespacesAndNewlines.contains($0) }),
              !rest.contains("/"), !rest.contains("?"), !rest.contains("#"), !rest.contains("@") else { return nil }

        var host: Substring
        var port: Int?
        if rest.hasPrefix("[") {
            // IPv6 literal: [addr] or [addr]:port
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex)..<close]
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":"), let p = Self.port(after.dropFirst()) else { return nil }
                port = p
            }
        } else {
            let colons = rest.filter { $0 == ":" }.count
            if colons == 1, let colon = rest.firstIndex(of: ":") {
                host = rest[..<colon]
                guard let p = Self.port(rest[rest.index(after: colon)...]) else { return nil }
                port = p
            } else if colons > 1 {
                host = rest            // a bare IPv6 literal, no port
            } else {
                host = rest
            }
        }
        let name = host.lowercased()
        guard Self.isLocalName(name) else { return nil }
        rawValue = trimmed
        hostName = name
        self.port = port
    }

    /// Every host validated, or nil when ANY one is not local or the list is
    /// empty — the worst host decides, never the first.
    public static func parse(_ raws: [String]) -> [LocalHost]? {
        guard !raws.isEmpty else { return nil }
        var out: [LocalHost] = []
        out.reserveCapacity(raws.count)
        for raw in raws {
            guard let host = LocalHost(raw) else { return nil }
            out.append(host)
        }
        return out
    }

    private static func port(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let p = Int(text), (1...65_535).contains(p) else { return nil }
        return p
    }

    static func isLocalName(_ name: String) -> Bool {
        if name == "localhost" { return true }
        if name.hasSuffix(".local") {
            // One or more DNS labels of letters, digits and hyphens.
            let labels = name.dropLast(".local".count).split(separator: ".", omittingEmptySubsequences: false)
            return !labels.isEmpty && labels.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" } }
        }
        if let v4 = ipv4(name) { return isPrivateOrLoopbackV4(v4) }
        if name == "::1" { return true }
        if name.hasPrefix("fe8") || name.hasPrefix("fe9") || name.hasPrefix("fea") || name.hasPrefix("feb") {
            return name.contains(":")   // fe80::/10 link-local
        }
        return false
    }

    private static func ipv4(_ name: String) -> [Int]? {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var octets: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber), let n = Int(part), (0...255).contains(n) else { return nil }
            octets.append(n)
        }
        return octets
    }

    private static func isPrivateOrLoopbackV4(_ o: [Int]) -> Bool {
        if o[0] == 127 { return true }                              // loopback
        if o[0] == 10 { return true }                               // 10/8
        if o[0] == 172, (16...31).contains(o[1]) { return true }    // 172.16/12
        if o[0] == 192, o[1] == 168 { return true }                 // 192.168/16
        if o[0] == 169, o[1] == 254 { return true }                 // link-local
        return false
    }
}
