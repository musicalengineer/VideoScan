// ModelLabRegistryTests.swift — the Approach registry and the payload gate
// (video_llm_lab §3.3, §6 sensor 1, §7). Dimensions:
//   LOGIC  — ApproachID spelling; the registry refuses a duplicate
//            (id, revision) with a typed error and keeps both revisions;
//            PayloadGate refuses pixels/audio to a non-local host and a
//            class the approach does not accept, and passes derived text.
//   SENSOR — `ModelLabSensorTests`: a `.remoteTextOnly` approach handed
//            `.pixels` throws BEFORE the transport is touched (a fake
//            transport's byte counter stays at zero).

import Foundation
import Testing
@testable import VideoScanCore

enum ModelLabFixtures {
    // swiftlint:disable:next force_unwrapping
    static let eraID = ApproachID(model: "qwen2.5-vl-3b-4bit", promptFamily: "era-v1", sampler: "window-60s")!
    /// The fleet, as OllamaEndpoints spells it.
    // swiftlint:disable:next force_unwrapping
    static let fleet = LocalHost.parse(["RicksM4.local", "http://127.0.0.1:11434"])!

    static func descriptor(id: ApproachID = eraID, revision: Int = 1, host: ApproachHost = .mlxSwift,
                           accepts: PayloadClass = [.pixels, .derivedText], emits: Set<FieldFamily> = [.era],
                           promptHash: String = "sha256:0123", enabled: Bool = true) -> ApproachDescriptor {
        ApproachDescriptor(id: id, revision: revision, host: host, accepts: accepts, emits: emits,
                           resources: ResourceProfile(peakRAMGB: 6, needsResidentModel: true,
                                                      expectedSecondsPerWindowUltra: 1.2, expectedSecondsPerWindowM4: 2.9,
                                                      weightsLocation: "mlx-community/Qwen2.5-VL-3B-Instruct-4bit"),
                           promptHash: promptHash, enabled: enabled)
    }
}

@Suite("ModelLab — ApproachID")
struct ModelLabApproachIDTests {

    @Test("spelled model/promptFamily/sampler; parsed back from the string; anything else is nil")
    func spelling() {
        let id = ModelLabFixtures.eraID
        #expect(id.rawValue == "qwen2.5-vl-3b-4bit/era-v1/window-60s")
        #expect(ApproachID(rawValue: id.rawValue) == id)
        #expect(ApproachID(rawValue: "two/parts") == nil)
        #expect(ApproachID(rawValue: "a//c") == nil)
        #expect(ApproachID(rawValue: "a/b/c/d") == nil)
        #expect(ApproachID(rawValue: "") == nil)
        #expect(ApproachID(rawValue: " a/b/c") == nil, "no whitespace")
        #expect(id.model == "qwen2.5-vl-3b-4bit" && id.promptFamily == "era-v1" && id.sampler == "window-60s")
        #expect(ApproachID(model: "", promptFamily: "p", sampler: "s") == nil, "the component init is failable too, never a precondition")
        #expect(ApproachID(model: "a/b", promptFamily: "p", sampler: "s") == nil)
    }
}

@Suite("ModelLab — LocalHost (rule 13 by type)")
struct ModelLabLocalHostTests {

    @Test("accepted: localhost, loopback, .local names, RFC 1918 and link-local literals, with or without http:// and a port")
    func acceptedShapes() {
        for raw in ["localhost", "127.0.0.1", "127.9.9.9:11434", "http://localhost:11434", "RicksM4.local", "ricksm5.local:1234",
                    "http://RicksM4.local:11434", "10.0.0.7", "172.16.0.1", "172.31.255.254", "192.168.1.20:11434", "169.254.3.4",
                    "[::1]", "[::1]:11434", "::1", "fe80::1", "[fe80::1%en0]:11434", "  RicksM4.local  "] {
            #expect(LocalHost(raw) != nil, Comment(rawValue: raw))
        }
        let host = LocalHost("http://RicksM4.local:11434")
        #expect(host?.hostName == "ricksm4.local" && host?.port == 11434 && host?.rawValue == "http://RicksM4.local:11434")
    }

    @Test("refused: https anywhere, public names and literals, 172 outside /12, paths, userinfo, bad ports, empty")
    func refusedShapes() {
        for raw in ["https://ollama.example.com", "https://127.0.0.1", "ollama.example.com", "api.example.com:443", "8.8.8.8",
                    "172.32.0.1", "172.15.0.1", "192.169.0.1", "RicksM4.local/api", "user@RicksM4.local", "RicksM4.local:0",
                    "RicksM4.local:70000", "RicksM4.local:abc", ".local", "ricks m4.local", "", "   ", "2001:db8::1", "example.local.com"] {
            #expect(LocalHost(raw) == nil, Comment(rawValue: raw))
        }
    }

    @Test("parse: the worst host decides — one cloud entry or an empty list is nil, never a shortened list")
    func parseIsAllOrNothing() {
        #expect(LocalHost.parse(["RicksM4.local", "https://api.example.com"]) == nil)
        #expect(LocalHost.parse([]) == nil)
        #expect(LocalHost.parse(["RicksM4.local", "ricksm5.local"])?.count == 2)
    }
}

@Suite("ModelLab — ApproachRegistry")
struct ModelLabRegistryTests {

    @Test("register, look up by (id, revision), latest revision wins for `latest`")
    func registerAndLookUp() throws {
        var registry = ApproachRegistry()
        try registry.register(ModelLabFixtures.descriptor(revision: 1))
        try registry.register(ModelLabFixtures.descriptor(revision: 2, promptHash: "sha256:4567"))
        #expect(registry.count == 2)
        #expect(registry.descriptor(ModelLabFixtures.eraID, revision: 1)?.promptHash == "sha256:0123")
        #expect(registry.descriptor(ModelLabFixtures.eraID, revision: 2)?.promptHash == "sha256:4567")
        #expect(registry.latest(ModelLabFixtures.eraID)?.revision == 2)
        #expect(registry.descriptor(ModelLabFixtures.eraID, revision: 3) == nil)
        #expect(registry.all.map(\.revision) == [1, 2], "sorted by id then revision")
    }

    @Test("a duplicate (id, revision) is refused with a typed error and the first registration stands")
    func duplicateRefused() throws {
        var registry = ApproachRegistry()
        try registry.register(ModelLabFixtures.descriptor(revision: 3, promptHash: "sha256:first"))
        #expect(throws: ApproachRegistryError.duplicate(id: ModelLabFixtures.eraID, revision: 3)) {
            try registry.register(ModelLabFixtures.descriptor(revision: 3, promptHash: "sha256:second"))
        }
        #expect(registry.count == 1)
        #expect(registry.descriptor(ModelLabFixtures.eraID, revision: 3)?.promptHash == "sha256:first")
        #expect(ApproachRegistryError.duplicate(id: ModelLabFixtures.eraID, revision: 3).description.contains("@r3"))
    }

    @Test("a revision below 1 is refused — revisions count from 1 so `@r0` never names a run")
    func revisionMustBePositive() {
        var registry = ApproachRegistry()
        #expect(throws: ApproachRegistryError.revisionNotPositive(id: ModelLabFixtures.eraID, revision: 0)) {
            try registry.register(ModelLabFixtures.descriptor(revision: 0))
        }
        #expect(registry.all.isEmpty)
    }

    @Test("ApproachHost: in-process, child process and a validated ollama fleet are local; an empty ollama list and the remote slot are not; labels are stable words")
    func hostLocality() {
        #expect(ApproachHost.mlxSwift.isLocal)
        #expect(ApproachHost.pythonWorker(venv: "venv-mlx", script: "scripts/vlm_worker.py").isLocal)
        #expect(ApproachHost.ollama(hosts: ModelLabFixtures.fleet).isLocal)
        #expect(!ApproachHost.ollama(hosts: []).isLocal, "no validated host = not local")
        #expect(!ApproachHost.remoteTextOnly.isLocal)
        #expect(ApproachHost.mlxSwift.label == "mlxSwift")
        #expect(ApproachHost.pythonWorker(venv: "venv-mlx", script: "s.py").label == "pythonWorker(venv-mlx, s.py)")
        #expect(ApproachHost.ollama(hosts: ModelLabFixtures.fleet).label == "ollama(RicksM4.local,http://127.0.0.1:11434)")
        #expect(ApproachHost.remoteTextOnly.label == "remoteTextOnly")
    }

    @Test("R1 (registry): an .ollama descriptor with no validated host is refused by register with a typed error; the remote slot still registers")
    func registerRefusesNonLocalOllama() throws {
        var registry = ApproachRegistry()
        let cloud = ModelLabFixtures.descriptor(host: .ollama(hosts: LocalHost.parse(["https://ollama.example.com"]) ?? []))
        #expect(throws: ApproachRegistryError.hostNotLocal(id: cloud.id, host: "ollama()")) { try registry.register(cloud) }
        #expect(registry.all.isEmpty)
        try registry.register(ModelLabFixtures.descriptor(host: .ollama(hosts: ModelLabFixtures.fleet)))
        try registry.register(ModelLabFixtures.descriptor(revision: 2, host: .remoteTextOnly, accepts: [.derivedText], enabled: false))
        #expect(registry.count == 2)
    }
}

@Suite("ModelLab — PayloadGate (rule 13 in code)")
struct ModelLabPayloadGateTests {

    @Test("a non-local host handed pixels or audio is refused by name; derived text alone passes")
    func remoteRefusesPixelsAndAudio() throws {
        let remote = ModelLabFixtures.descriptor(host: .remoteTextOnly, accepts: [.derivedText], enabled: false)
        #expect(throws: PayloadRefused.hostNotLocal(approach: remote.id, host: "remoteTextOnly", refused: [.pixels])) {
            try PayloadGate.check(remote, payload: [.pixels, .derivedText])
        }
        #expect(throws: PayloadRefused.hostNotLocal(approach: remote.id, host: "remoteTextOnly", refused: [.audio])) {
            try PayloadGate.check(remote, payload: [.audio])
        }
        #expect(throws: PayloadRefused.hostNotLocal(approach: remote.id, host: "remoteTextOnly", refused: [.pixels, .audio])) {
            try PayloadGate.check(remote, payload: [.pixels, .audio, .derivedText])
        }
        try PayloadGate.check(remote, payload: [.derivedText])
        try PayloadGate.check(remote, payload: [])
    }

    @Test("a local host passes pixels and audio it accepts; a class the approach does not accept is refused even locally")
    func localHostsPassWhatTheyAccept() throws {
        let local = ModelLabFixtures.descriptor(host: .mlxSwift, accepts: [.pixels, .derivedText])
        try PayloadGate.check(local, payload: [.pixels, .derivedText])
        #expect(throws: PayloadRefused.notAccepted(approach: local.id, refused: [.audio])) {
            try PayloadGate.check(local, payload: [.pixels, .audio])
        }
        let worker = ModelLabFixtures.descriptor(host: .pythonWorker(venv: "venv-mlx", script: "w.py"), accepts: [.pixels, .audio, .derivedText])
        try PayloadGate.check(worker, payload: [.pixels, .audio, .derivedText])
    }

    @Test("R1 (gate): an .ollama approach whose host list names a cloud URL is refused pixels and audio; a validated fleet passes; a mixed list is judged by its worst host; preflight refuses the same")
    func ollamaCloudHostIsNotLocal() {
        let cloud = ModelLabFixtures.descriptor(host: .ollama(hosts: LocalHost.parse(["https://ollama.example.com"]) ?? []), accepts: [.pixels, .audio, .derivedText])
        #expect(throws: PayloadRefused.hostNotLocal(approach: cloud.id, host: "ollama()", refused: [.pixels])) {
            try PayloadGate.check(cloud, payload: [.pixels])
        }
        let fleet = ModelLabFixtures.descriptor(host: .ollama(hosts: ModelLabFixtures.fleet), accepts: [.pixels, .derivedText])
        #expect((try? PayloadGate.check(fleet, payload: [.pixels])) != nil)
        let mixed = ModelLabFixtures.descriptor(host: .ollama(hosts: LocalHost.parse(["RicksM4.local", "https://api.example.com"]) ?? []), accepts: [.pixels])
        #expect(throws: PayloadRefused.self) { try PayloadGate.check(mixed, payload: [.pixels]) }
        #expect(ModelLabStore.preflight(cloud, host: .init(availableRAMGB: 64, weightsPresent: true)) == .remoteHostNotEnabled(approach: cloud.id))
        #expect(ModelLabStore.preflight(fleet, host: .init(availableRAMGB: 64, weightsPresent: true)) == nil)
    }

    @Test("the gate's per-case switch and ApproachHost.isLocal agree for every host shape")
    func gateAgreesWithIsLocal() {
        let hosts: [ApproachHost] = [.mlxSwift, .pythonWorker(venv: "v", script: "s"), .ollama(hosts: ModelLabFixtures.fleet), .ollama(hosts: []), .remoteTextOnly]
        for host in hosts {
            let d = ModelLabFixtures.descriptor(host: host, accepts: [.pixels, .audio, .derivedText])
            let passed = (try? PayloadGate.check(d, payload: [.pixels, .audio])) != nil
            #expect(passed == host.isLocal, Comment(rawValue: host.label))
            #expect((try? PayloadGate.check(d, payload: [.derivedText])) != nil, "derived text passes every host: \(host.label)")
        }
    }

    @Test("the refusal's words name the approach, the host and the classes refused")
    func refusalWords() {
        let words = PayloadRefused.hostNotLocal(approach: ModelLabFixtures.eraID, host: "remoteTextOnly", refused: [.pixels, .audio]).description
        #expect(words.contains("pixels") && words.contains("audio") && words.contains("remoteTextOnly") && words.contains(ModelLabFixtures.eraID.rawValue))
        #expect(words.contains("rule 13"))
    }
}

/// A transport that counts what it was asked to send. The sensor asserts it
/// was never asked.
final class CountingFakeTransport: @unchecked Sendable {
    private(set) var bytesSent = 0
    private(set) var calls = 0
    func send(_ payload: Data) { calls += 1; bytesSent += payload.count }
}

/// How a runner must use the gate: check, THEN transport. The sensor pins the
/// order with a fake transport.
private func sendThroughGate(_ descriptor: ApproachDescriptor, payload: PayloadClass, bytes: Data,
                             transport: CountingFakeTransport) throws(PayloadRefused) {
    try PayloadGate.check(descriptor, payload: payload)
    transport.send(bytes)
}

@Suite("ModelLab — sensors (cheap; wired into the lane by run_sensors)")
struct ModelLabSensorTests {

    @Test("sensor 1: a .remoteTextOnly approach handed .pixels throws PayloadRefused and the fake transport counter stays at zero")
    func remoteRefusalBeforeTransport() {
        let transport = CountingFakeTransport()
        let remote = ModelLabFixtures.descriptor(host: .remoteTextOnly, accepts: [.derivedText], enabled: false)
        let frame = Data(repeating: 0xAB, count: 600 * 1024)   // one 448×448 frame's worth
        #expect(throws: PayloadRefused.hostNotLocal(approach: remote.id, host: "remoteTextOnly", refused: [.pixels])) {
            try sendThroughGate(remote, payload: [.pixels], bytes: frame, transport: transport)
        }
        #expect(transport.bytesSent == 0 && transport.calls == 0, "nothing left the process")
        // The same door passes derived text, so the sensor is not a stub that refuses everything.
        try? sendThroughGate(remote, payload: [.derivedText], bytes: Data("caption".utf8), transport: transport)
        #expect(transport.calls == 1 && transport.bytesSent == 7)
    }

    @Test("sensor 3: a near-miss JSON (year 19910) yields zero assertions and one schemaInvalid")
    func nearMissJSONFailsClosed() {
        let json = Data("""
        {"family":"era","window":[0,60],"yearRange":[19910,1995],"rationale":"4:3, OSD","cues":[],"selfConfidence":0.7}
        """.utf8)
        let window = SampleWindow(startS: 0, endS: 60, frameTimesS: [0, 30], audioRange: nil)
        let result = ContractDecoder.decode(family: .era, json: json, window: window)
        var invalid = 0
        var assertions: [EvidenceAssertion] = []
        switch result {
        case .output(let output):
            assertions = EvidenceAssertionMapper.assertions(from: output, subjectDigest: "sha256:ab", approach: ModelLabFixtures.descriptor(), elapsedS: 1)
        case .schemaInvalid(let reason):
            invalid += 1
            #expect(reason.contains("19910") || reason.lowercased().contains("year"), Comment(rawValue: reason))
        }
        #expect(assertions.isEmpty && invalid == 1)
    }
}
