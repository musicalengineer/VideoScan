// HallieWebServer.swift
// Hallie on the home network (Rick 2026-08-21: "talk to Hallie from my MBP
// downstairs… a mini app my wife can use on her iPad").
//
// The smallest thing that works: VideoScan listens on one port, serves one
// page, and answers `POST /api/ask` with the SAME coordinator the chat
// window uses — same routing, same verifier, same citations. No framework,
// no cloud, no app store. Safari's "Add to Home Screen" is the iPad app.
//
// Boundaries, on purpose:
// - Only private (RFC 1918 / link-local / loopback) peers are answered;
//   anyone else gets 403 before a byte of family data moves.
// - A passphrase (X-Hallie-Key) gates every API call.
// - Media streams only for files Safari can play, with HTTP Range support;
//   nothing is transcoded, nothing is written.
// - HTTP/1.1 parsing is deliberately minimal: one request per connection,
//   bounded headers and body, no keep-alive, no chunked bodies.

import Foundation
import Network

/// One parsed HTTP request. Pure value; `HTTPRequest.parse` is unit-tested
/// without a socket.
struct HallieHTTPRequest: Equatable, Sendable {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // lowercased keys
    let body: Data

    static let maximumHeaderBytes = 16 * 1024
    static let maximumBodyBytes = 64 * 1024

    enum ParseState: Equatable, Sendable {
        case needMore
        case complete(HallieHTTPRequest, consumed: Int)
        case invalid(String)
    }

    /// Parse from the bytes received so far.
    static func parse(_ data: Data) -> ParseState {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else {
            return data.count > maximumHeaderBytes ? .invalid("headers too large") : .needMore
        }
        guard headerEnd.lowerBound <= maximumHeaderBytes else { return .invalid("headers too large") }
        guard let head = String(data: data[..<headerEnd.lowerBound], encoding: .utf8) else {
            return .invalid("non-UTF-8 headers")
        }
        var lines = head.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return .invalid("empty request") }
        let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
        guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
            return .invalid("bad request line")
        }
        let method = String(requestLine[0]).uppercased()
        var headers: [String: String] = [:]
        for line in lines where !line.isEmpty {
            guard let colon = line.firstIndex(of: ":") else { return .invalid("bad header") }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[key] = value
        }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0 else { return .invalid("bad content-length") }
        guard contentLength <= maximumBodyBytes else { return .invalid("body too large") }
        let bodyStart = headerEnd.upperBound
        guard data.count - bodyStart >= contentLength else { return .needMore }
        let body = data[bodyStart..<(bodyStart + contentLength)]

        let target = String(requestLine[1])
        let pathAndQuery = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pathAndQuery[0]).removingPercentEncoding ?? String(pathAndQuery[0])
        var query: [String: String] = [:]
        if pathAndQuery.count == 2 {
            for pair in pathAndQuery[1].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
                let value = kv.count == 2 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
                query[key] = value
            }
        }
        return .complete(
            HallieHTTPRequest(method: method, path: path, query: query,
                              headers: headers, body: Data(body)),
            consumed: bodyStart + contentLength)
    }
}

/// One response. `body` may be a file range so large media never sits in
/// memory.
struct HallieHTTPResponse: Sendable {
    enum Body: Sendable {
        case data(Data)
        case file(URL, range: Range<Int64>, totalLength: Int64)
    }
    var status: Int
    var reason: String
    var headers: [(String, String)]
    var body: Body

    static func text(_ status: Int, _ text: String) -> HallieHTTPResponse {
        .init(status: status, reason: reasonPhrase(status),
              headers: [("Content-Type", "text/plain; charset=utf-8")],
              body: .data(Data(text.utf8)))
    }

    static func html(_ html: String) -> HallieHTTPResponse {
        .init(status: 200, reason: "OK",
              headers: [("Content-Type", "text/html; charset=utf-8"),
                        ("Cache-Control", "no-store")],
              body: .data(Data(html.utf8)))
    }

    static func json(_ object: Any, status: Int = 200) -> HallieHTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        return .init(status: status, reason: reasonPhrase(status),
                     headers: [("Content-Type", "application/json; charset=utf-8"),
                               ("Cache-Control", "no-store")],
                     body: .data(data))
    }

    static func reasonPhrase(_ status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 206: return "Partial Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 500: return "Internal Server Error"
        default: return "Status \(status)"
        }
    }

    var headBytes: Data {
        var lines = ["HTTP/1.1 \(status) \(reason)"]
        var all = headers
        switch body {
        case .data(let data):
            all.append(("Content-Length", String(data.count)))
        case .file(_, let range, _):
            all.append(("Content-Length", String(range.upperBound - range.lowerBound)))
        }
        all.append(("Connection", "close"))
        for (name, value) in all { lines.append("\(name): \(value)") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }
}

enum HallieWebRange {
    /// "bytes=START-END" / "bytes=START-" / "bytes=-SUFFIX" → a half-open
    /// byte range within `length`, or nil when absent/unsatisfiable.
    static func parse(_ header: String?, length: Int64) -> Range<Int64>? {
        guard let header, header.hasPrefix("bytes=") else { return nil }
        let spec = header.dropFirst("bytes=".count).split(separator: ",", maxSplits: 1)[0]
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let startText = parts[0].trimmingCharacters(in: .whitespaces)
        let endText = parts[1].trimmingCharacters(in: .whitespaces)
        if startText.isEmpty {
            guard let suffix = Int64(endText), suffix > 0 else { return nil }
            let start = max(0, length - suffix)
            return start..<length
        }
        guard let start = Int64(startText), start >= 0, start < length else { return nil }
        let end = endText.isEmpty ? length - 1 : min(Int64(endText) ?? (length - 1), length - 1)
        guard end >= start else { return nil }
        return start..<(end + 1)
    }
}

enum HallieWebPeer {
    /// Only the home network: loopback, RFC 1918, link-local, ULA.
    static func isPrivate(_ host: String) -> Bool {
        var address = host
        if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
        if address == "::1" || address.hasPrefix("fe80:") || address.hasPrefix("fd") || address.hasPrefix("fc") {
            return true
        }
        if address.hasPrefix("::ffff:") { address = String(address.dropFirst("::ffff:".count)) }
        let octets = address.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (127, _), (10, _), (192, 168), (169, 254): return true
        case (172, let second) where (16...31).contains(second): return true
        default: return false
        }
    }
}

/// The listener. Each connection: read one request, hand it to `handle`,
/// write the response, close. `handle` runs on the main actor because the
/// coordinator does; media streaming reads the file on a background queue.
final class HallieWebServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (HallieHTTPRequest, _ peer: String) async -> HallieHTTPResponse

    private let queue = DispatchQueue(label: "Rick-Breen.VideoScan.HallieWeb")
    private var listener: NWListener?
    private let handler: Handler
    private(set) var port: UInt16 = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Start on `port` (0 = ephemeral, for tests). Throws if the port is busy.
    func start(port requested: UInt16) throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(
            using: parameters,
            on: requested == 0 ? .any : NWEndpoint.Port(rawValue: requested)!)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        let ready = DispatchSemaphore(value: 0)
        var failure: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue ?? requested
                ready.signal()
            case .failed(let error):
                failure = error
                ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 5)
        if let failure { throw failure }
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let peer: String
        if case .hostPort(let host, _) = connection.endpoint {
            peer = "\(host)"
        } else {
            peer = "unknown"
        }
        connection.start(queue: queue)
        var buffer = Data()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
                guard let self else { connection.cancel(); return }
                if let data { buffer.append(data) }
                switch HallieHTTPRequest.parse(buffer) {
                case .needMore:
                    if isComplete || error != nil { connection.cancel() } else { receive() }
                case .invalid(let why):
                    self.send(.text(400, why), on: connection)
                case .complete(let request, _):
                    guard HallieWebPeer.isPrivate(peer) else {
                        self.send(.text(403, "Hallie only answers on the home network."), on: connection)
                        return
                    }
                    Task { @MainActor in
                        let response = await self.handler(request, peer)
                        self.send(response, on: connection)
                    }
                }
            }
        }
        receive()
    }

    private func send(_ response: HallieHTTPResponse, on connection: NWConnection) {
        queue.async {
            connection.send(content: response.headBytes, completion: .contentProcessed { _ in })
            switch response.body {
            case .data(let data):
                connection.send(content: data, completion: .contentProcessed { _ in
                    connection.cancel()
                })
            case .file(let url, let range, _):
                Self.stream(url: url, range: range, on: connection)
            }
        }
    }

    /// 1 MiB chunks read lazily, so a 4 GB file costs 1 MiB of memory.
    private static func stream(url: URL, range: Range<Int64>, on connection: NWConnection) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            connection.cancel(); return
        }
        let chunk = 1 << 20
        var offset = range.lowerBound
        func next() {
            guard offset < range.upperBound else {
                try? handle.close()
                connection.cancel()
                return
            }
            let count = Int(min(Int64(chunk), range.upperBound - offset))
            do {
                try handle.seek(toOffset: UInt64(offset))
                let data = try handle.read(upToCount: count) ?? Data()
                guard !data.isEmpty else { try? handle.close(); connection.cancel(); return }
                offset += Int64(data.count)
                connection.send(content: data, completion: .contentProcessed { error in
                    if error != nil { try? handle.close(); connection.cancel() } else { next() }
                })
            } catch {
                try? handle.close()
                connection.cancel()
            }
        }
        next()
    }
}
