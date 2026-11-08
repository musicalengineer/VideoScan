// HallieCloudStubSupport.swift — test support
//
// A URLProtocol stub standing in for api.anthropic.com, so no test ever
// reaches the network. Each test gets its own URLSession tagged with a
// unique token header; the ledger records every request that ACTUALLY
// reached the transport under that token, so parallel tests cannot see each
// other's traffic. (C++ analogy: a mock socket keyed by connection id.)

import Foundation
@testable import VideoScan

final class HallieCloudStubLedger: @unchecked Sendable {
    static let shared = HallieCloudStubLedger()
    private let lock = NSLock()
    private var requests: [String: [(request: URLRequest, body: Data)]] = [:]
    private var replies: [String: [(status: Int, body: Data)]] = [:]

    func record(_ token: String, _ request: URLRequest, _ body: Data) {
        lock.lock(); defer { lock.unlock() }
        requests[token, default: []].append((request, body))
    }

    func seen(_ token: String) -> [(request: URLRequest, body: Data)] {
        lock.lock(); defer { lock.unlock() }
        return requests[token] ?? []
    }

    func queue(_ token: String, status: Int, body: String) {
        lock.lock(); defer { lock.unlock() }
        replies[token, default: []].append((status, Data(body.utf8)))
    }

    /// The next queued reply, or the last one again, or a bare 200.
    func nextReply(_ token: String) -> (status: Int, body: Data) {
        lock.lock(); defer { lock.unlock() }
        guard var list = replies[token], !list.isEmpty else {
            return (200, Data(#"{"content":[]}"#.utf8))
        }
        let first = list.removeFirst()
        replies[token] = list.isEmpty ? [first] : list
        return first
    }
}

final class HallieCloudStubProtocol: URLProtocol, @unchecked Sendable {
    static let tokenHeader = "X-Hallie-Stub-Token"

    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let token = request.value(forHTTPHeaderField: Self.tokenHeader) ?? "untagged"
        let body = request.httpBody ?? Self.drain(request.httpBodyStream)
        HallieCloudStubLedger.shared.record(token, request, body)
        let reply = HallieCloudStubLedger.shared.nextReply(token)
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status,
                                             httpVersion: "HTTP/1.1", headerFields: nil) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func drain(_ stream: InputStream?) -> Data {
        guard let stream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }
}

/// A fresh stubbed session and its token.
func hallieCloudStubSession() -> (session: URLSession, token: String) {
    let token = UUID().uuidString
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HallieCloudStubProtocol.self]
    configuration.httpAdditionalHeaders = [HallieCloudStubProtocol.tokenHeader: token]
    return (URLSession(configuration: configuration), token)
}

/// A key that is obviously fake; tests assert it never leaks into text.
let hallieFakeCloudKey = AnthropicAPIKey(value: "sk-ant-test-FAKE-0123456789", source: "test")

func hallieStubbedCloudBrain(_ session: URLSession, model: String = "claude-sonnet-5-5") -> AnthropicBrain {
    var brain = AnthropicBrain(model: model, key: hallieFakeCloudKey, session: session)
    brain.transientRetryDelay = .milliseconds(1)
    return brain
}

/// A fake Keychain: (service, account?) → secret.
struct FakeHallieKeychain: HallieKeychainReading {
    var items: [String: String] = [:]
    /// Every lookup, in order, so tests can pin the search order.
    let lookups = HallieLookupLog()

    static func key(_ service: String, _ account: String?) -> String {
        "\(service)|\(account ?? "*")"
    }

    func password(service: String, account: String?) -> String? {
        lookups.append(Self.key(service, account))
        return items[Self.key(service, account)]
    }

    func hasItem(service: String, account: String?) -> Bool {
        items[Self.key(service, account)] != nil
    }
}

final class HallieLookupLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []
    func append(_ entry: String) { lock.lock(); entries.append(entry); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return entries }
}

/// An Anthropic structured-output reply: the JSON object is the text of one
/// text block (2026-11-08; replaced the forced-tool reply).
func hallieStructuredReply(_ answerJSON: String, stopReason: String = "end_turn") -> String {
    let root: [String: Any] = [
        "id": "msg_1", "type": "message", "role": "assistant",
        "content": [["type": "text", "text": answerJSON]],
        "stop_reason": stopReason,
    ]
    guard let data = try? JSONSerialization.data(withJSONObject: root, options: [.sortedKeys]) else {
        preconditionFailure("stub reply did not encode")
    }
    return String(bytes: data, encoding: .utf8) ?? ""
}
