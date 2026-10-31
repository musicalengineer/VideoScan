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
    static let eraID = ApproachID(model: "qwen2.5-vl-3b-4bit", promptFamily: "era-v1", sampler: "window-60s")

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

    @Test("ApproachHost: the three local hosts are local, the remote slot is not; labels are stable words for the run record")
    func hostLocality() {
        #expect(ApproachHost.mlxSwift.isLocal)
        #expect(ApproachHost.pythonWorker(venv: "venv-mlx", script: "scripts/vlm_worker.py").isLocal)
        #expect(ApproachHost.ollama(hosts: ["http://ricksm4.local:11434"]).isLocal)
        #expect(!ApproachHost.remoteTextOnly.isLocal)
        #expect(ApproachHost.mlxSwift.label == "mlxSwift")
        #expect(ApproachHost.pythonWorker(venv: "venv-mlx", script: "s.py").label == "pythonWorker(venv-mlx, s.py)")
        #expect(ApproachHost.remoteTextOnly.label == "remoteTextOnly")
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
