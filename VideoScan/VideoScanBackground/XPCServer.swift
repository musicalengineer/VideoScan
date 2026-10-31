// XPCServer.swift — VideoScan Background
//
// The service side of `BackgroundServiceXPC` (design §3.3): an
// NSXPCListener on the launchd Mach service, one exported object per
// connection, every payload through BackgroundPayloadCodec. Before a
// connection is accepted the peer's code signature is read with the
// Security framework and judged by `PeerTrustPolicy` (Core, tested): the
// peer must be the app or this helper, signed by the same leaf certificate
// as this process. A refusal is logged with the pid and the reason.
//
// Peer identity, two tiers (review 2026-10-30, fix 4):
//   • A certificate-signed helper ("VideoScan Local") puts a code-signing
//     REQUIREMENT on every connection (`setCodeSigningRequirement`, built by
//     `PeerRequirement` from the helper's own designated requirement with the
//     identifier widened to the app or this helper). XPC enforces it on the
//     peer's audit token for every message — no pid, no race.
//   • An ad-hoc helper (the sensor lane's build) has no certificate to
//     require; it falls back to `PeerTrustPolicy` by identifier, read through
//     SecCodeCopyGuestWithAttributes(pid), and logs that it did.
//
// C++ reading: `shouldAcceptNewConnection` is the accept() hook; the
// exported object is the servant the proxy's calls land on.

import CommonCrypto
import Foundation
import Security
import VideoScanCore

/// `@unchecked Sendable`: every stored property is a `let` holding something
/// already safe to share (an actor, the listener, immutable strings, and
/// `ProgressFanOut`, which locks); the compiler cannot check an NSObject
/// subclass's conformance, so the promise is made here and kept by having no
/// `var`.
final class XPCServer: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let listener: NSXPCListener
    private let supervisor: JobSupervisor
    private let log: any BackgroundLogSink
    private let allowedPeers: Set<String>
    private let startedAt: Date
    private let selfLeafSHA1: String?
    /// The requirement every peer must satisfy, or nil for an ad-hoc build.
    private let peerRequirement: String?
    private let progress = ProgressFanOut()

    init(machServiceName: String, supervisor: JobSupervisor, log: any BackgroundLogSink, allowedPeers: Set<String>, startedAt: Date) {
        self.listener = NSXPCListener(machServiceName: machServiceName)
        self.supervisor = supervisor
        self.log = log
        self.allowedPeers = allowedPeers
        self.startedAt = startedAt
        self.selfLeafSHA1 = CodeSignatureReader.selfLeafSHA1()
        let helperID = allowedPeers.first { $0.hasSuffix(BackgroundServiceNames.suffix) } ?? ""
        let appID = allowedPeers.first { !$0.hasSuffix(BackgroundServiceNames.suffix) } ?? helperID
        self.peerRequirement = CodeSignatureReader.selfDesignatedRequirement().flatMap {
            PeerRequirement.forPeers(helperDesignatedRequirement: $0, helperIdentifier: helperID, appIdentifier: appID)
        }
        super.init()
        listener.delegate = self
    }

    func resume() {
        if let peerRequirement {
            log.write("XPC: peers must satisfy the code-signing requirement \(peerRequirement)")
        } else {
            log.write("XPC: ad-hoc build: identifier-only peer check (no certificate to require)")
        }
        listener.resume()
        let log = self.log
        let progress = self.progress
        Task {
            await supervisor.setProgressSink { snapshot in progress.push(snapshot, log: log) }
        }
        log.write("XPC listening on \(listener.endpoint.description)")
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        if let peerRequirement {
            // XPC checks the peer's audit token against this on every message;
            // a peer that fails it never reaches the exported object.
            connection.setCodeSigningRequirement(peerRequirement)
            log.write("XPC connection from pid \(pid) accepted under the code-signing requirement")
        } else {
            let peer = CodeSignatureReader.peer(pid: pid)
            let decision = PeerTrustPolicy.decide(selfLeafSHA1: selfLeafSHA1, allowedIdentifiers: allowedPeers,
                                                  peerIdentifier: peer.identifier, peerLeafSHA1: peer.leafSHA1, peerPID: pid)
            switch decision {
            case .refuse(let words):
                log.write("XPC refused: \(words)")
                return false
            case .accept(let note):
                if let note { log.write("XPC: \(note)") }
                log.write("XPC connection accepted from \(peer.identifier ?? "?") pid \(pid)")
            }
        }
        connection.exportedInterface = NSXPCInterface(with: BackgroundServiceXPC.self)
        connection.exportedObject = Servant(supervisor: supervisor, log: log, startedAt: startedAt, progress: progress)
        let log = self.log
        connection.invalidationHandler = { log.write("XPC connection from pid \(pid) closed") }
        connection.resume()
        return true
    }

    // MARK: - The exported object

    private final class Servant: NSObject, BackgroundServiceXPC, @unchecked Sendable {
        private let supervisor: JobSupervisor
        private let log: any BackgroundLogSink
        private let startedAt: Date
        private let progress: ProgressFanOut

        init(supervisor: JobSupervisor, log: any BackgroundLogSink, startedAt: Date, progress: ProgressFanOut) {
            self.supervisor = supervisor
            self.log = log
            self.startedAt = startedAt
            self.progress = progress
        }

        func status(reply: @escaping @Sendable (Data) -> Void) {
            let supervisor = self.supervisor
            let startedAt = self.startedAt
            Task {
                let status = await supervisor.status(processIdentifier: ProcessInfo.processInfo.processIdentifier, startedAt: startedAt)
                reply((try? BackgroundPayloadCodec.encode(status)) ?? Data())
            }
        }

        func enqueue(_ request: Data, reply: @escaping @Sendable (Data) -> Void) {
            let supervisor = self.supervisor
            Task {
                let outcome: EnqueueReply
                do {
                    outcome = await supervisor.enqueue(try BackgroundPayloadCodec.decode(JobRequest.self, from: request))
                } catch {
                    outcome = .refused((error as? Refusal) ?? Refusal(String(describing: error)))
                }
                reply((try? BackgroundPayloadCodec.encode(outcome)) ?? Data())
            }
        }

        func pause(_ id: Data, reply: @escaping @Sendable (Bool) -> Void) {
            verb(id, reply) { await $0.pause($1) }
        }

        func resume(_ id: Data, reply: @escaping @Sendable (Bool) -> Void) {
            verb(id, reply) { await $0.resume($1) }
        }

        func stop(_ id: Data, reply: @escaping @Sendable (Bool) -> Void) {
            verb(id, reply) { await $0.stop($1) }
        }

        func subscribe(progress endpoint: NSXPCListenerEndpoint) {
            progress.add(endpoint)
            log.write("XPC: progress subscriber added (\(progress.count) total)")
        }

        private func verb(_ id: Data, _ reply: @escaping @Sendable (Bool) -> Void,
                          _ body: @escaping @Sendable (JobSupervisor, JobID) async -> Bool) {
            guard let jobID = try? BackgroundPayloadCodec.decode(JobID.self, from: id) else {
                log.write("XPC: a verb arrived with an unreadable job id — refused")
                reply(false)
                return
            }
            let supervisor = self.supervisor
            Task { reply(await body(supervisor, jobID)) }
        }
    }
}

/// Progress subscribers (the app's endpoints). Bounded at 8 — one app, the
/// nightly, a few CLIs; the 9th replaces the oldest.
final class ProgressFanOut: @unchecked Sendable {
    private let lock = NSLock()
    private var connections: [NSXPCConnection] = []
    private static let limit = 8

    func add(_ endpoint: NSXPCListenerEndpoint) {
        let connection = NSXPCConnection(listenerEndpoint: endpoint)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundProgressXPC.self)
        connection.invalidationHandler = { [weak self, weak connection] in
            guard let self, let connection else { return }
            self.lock.lock()
            self.connections.removeAll { $0 === connection }
            self.lock.unlock()
        }
        connection.resume()
        lock.lock()
        connections.append(connection)
        if connections.count > Self.limit { connections.removeFirst().invalidate() }
        lock.unlock()
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return connections.count
    }

    func push(_ snapshot: JobProgressSnapshot, log: any BackgroundLogSink) {
        guard let data = try? BackgroundPayloadCodec.encode(snapshot) else { return }
        lock.lock()
        let targets = connections
        lock.unlock()
        for connection in targets {
            (connection.remoteObjectProxy as? BackgroundProgressXPC)?.progress(data)
        }
    }
}

/// Security-framework reads behind `PeerTrustPolicy`.
enum CodeSignatureReader {
    struct Peer {
        var identifier: String?
        var leafSHA1: String?
    }

    static func selfLeafSHA1() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        return signingInfo(code).leafSHA1
    }

    /// This process's designated requirement as text, e.g.
    /// `identifier "Rick-Breen.VideoScan.Background" and certificate leaf = H"…"`;
    /// an ad-hoc build reads `cdhash H"…"`.
    static func selfDesignatedRequirement() -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var requirement: SecRequirement?
        guard SecCodeCopyDesignatedRequirement(staticCode, [], &requirement) == errSecSuccess, let requirement else { return nil }
        var text: CFString?
        guard SecRequirementCopyString(requirement, [], &text) == errSecSuccess, let text else { return nil }
        return text as String
    }

    static func peer(pid: Int32) -> Peer {
        var code: SecCode?
        let attributes = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return Peer() }
        // The signature must be VALID (not just present) before its claims count.
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return Peer() }
        return signingInfo(code)
    }

    private static func signingInfo(_ code: SecCode) -> Peer {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return Peer() }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dictionary = info as? [String: Any] else { return Peer() }
        let identifier = dictionary[kSecCodeInfoIdentifier as String] as? String
        var leaf: String?
        if let certificates = dictionary[kSecCodeInfoCertificates as String] as? [SecCertificate], let first = certificates.first {
            leaf = sha1Hex(SecCertificateCopyData(first) as Data)
        }
        return Peer(identifier: identifier, leafSHA1: leaf)
    }

    private static func sha1Hex(_ data: Data) -> String {
        // SHA-1 is the fingerprint `codesign -dvv` prints for a leaf; it is an
        // identity label here, not an integrity hash (the signature itself
        // was validated above).
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA1_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA1($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
