// BackoffPolicyTests.swift — the Mac's pause (thermal, memory), its
// precedence and hysteresis, and the peer-trust decision. The keyboard rows
// and the idle-exit rule went on 2026-11-04 (the helper owns its schedule).
//
// Dimensions: LOGIC. The sources are fakes; no Mac state is read.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Backoff — thermal and memory only")
struct BackoffPolicyTests {

    @Test("no keyboard backoff (2026-11-04): a normal Mac is full")
    func normalIsFull() {
        #expect(BackoffPolicy.state(for: ActivitySample()) == .full)
    }

    @Test("thermal ≥ serious → paused(thermal); fair alone is not a pause")
    func thermal() {
        #expect(BackoffPolicy.state(for: ActivitySample(thermalState: .serious)) == .paused(reason: "thermal"))
        #expect(BackoffPolicy.state(for: ActivitySample(thermalState: .critical)) == .paused(reason: "thermal"))
        #expect(BackoffPolicy.state(for: ActivitySample(thermalState: .fair)) == .full)
    }

    @Test("memory warning or critical → paused(memory)")
    func memory() {
        #expect(BackoffPolicy.state(for: ActivitySample(memoryPressure: .warning)) == .paused(reason: "memory"))
        #expect(BackoffPolicy.state(for: ActivitySample(memoryPressure: .critical)) == .paused(reason: "memory"))
    }

    @Test("the Mac comes first: thermal beats memory")
    func precedence() {
        #expect(BackoffPolicy.state(for: ActivitySample(thermalState: .serious, memoryPressure: .warning)) == .paused(reason: "thermal"))
    }

    @Test("the actor holds a thermal pause until nominal, and publishes each change once")
    func hysteresis() async {
        let source = FakeActivitySource(ActivitySample(thermalState: .serious))
        let backoff = Backoff(source: source)
        let seen = InMemoryBackgroundLog()
        await backoff.onChange { seen.write($0.words) }

        #expect(await backoff.refresh() == .paused(reason: "thermal"))
        source.set(ActivitySample(thermalState: .fair))
        #expect(await backoff.refresh() == .paused(reason: "thermal"), "fair after serious is still too hot")
        source.set(ActivitySample(thermalState: .nominal))
        #expect(await backoff.refresh() == .full)
        source.set(ActivitySample(thermalState: .fair))
        #expect(await backoff.refresh() == .full, "fair on its own never pauses")
        #expect(seen.lines == ["paused (thermal)", "full"])
    }
}

@Suite("PeerTrustPolicy — who may talk to the service")
struct PeerTrustPolicyTests {
    let allowed: Set<String> = ["Rick-Breen.VideoScan", "Rick-Breen.VideoScan.Background"]

    @Test("the app signed by the same certificate is accepted")
    func sameCertificate() {
        let d = PeerTrustPolicy.decide(selfLeafSHA1: "AB12", allowedIdentifiers: allowed,
                                       peerIdentifier: "Rick-Breen.VideoScan", peerLeafSHA1: "ab12", peerPID: 7)
        #expect(d == .accept(note: nil))
    }

    @Test("a different certificate, an unknown identifier, or no signature is refused in words")
    func refusals() {
        #expect(!PeerTrustPolicy.decide(selfLeafSHA1: "AB12", allowedIdentifiers: allowed,
                                        peerIdentifier: "Rick-Breen.VideoScan", peerLeafSHA1: "ff00", peerPID: 7).isAccepted)
        #expect(!PeerTrustPolicy.decide(selfLeafSHA1: "AB12", allowedIdentifiers: allowed,
                                        peerIdentifier: "com.example.other", peerLeafSHA1: "AB12", peerPID: 7).isAccepted)
        #expect(!PeerTrustPolicy.decide(selfLeafSHA1: "AB12", allowedIdentifiers: allowed,
                                        peerIdentifier: nil, peerLeafSHA1: nil, peerPID: 7).isAccepted)
        if case .refuse(let words) = PeerTrustPolicy.decide(selfLeafSHA1: "AB12", allowedIdentifiers: allowed,
                                                            peerIdentifier: "Rick-Breen.VideoScan", peerLeafSHA1: nil, peerPID: 7) {
            #expect(words.contains("carries no certificate"))
        } else { Issue.record("a signed build must refuse an uncertified peer") }
    }

    @Test("an ad-hoc build accepts on identifier alone and says so")
    func adHoc() {
        let d = PeerTrustPolicy.decide(selfLeafSHA1: nil, allowedIdentifiers: allowed,
                                       peerIdentifier: "Rick-Breen.VideoScan.Background", peerLeafSHA1: nil, peerPID: 7)
        guard case .accept(let note) = d else { Issue.record("expected accept, got \(d)"); return }
        #expect(note?.contains("ad-hoc") == true)
    }
}

@Suite("PeerRequirement — the connection requirement from the helper's own designated requirement")
struct PeerRequirementTests {
    @Test("the identifier clause is widened to the app or the helper; the certificate clause is kept verbatim")
    func widensIdentifier() {
        let helperDR = "identifier \"Rick-Breen.VideoScan.Background\" and certificate leaf = H\"0123abcd\""
        let req = PeerRequirement.forPeers(helperDesignatedRequirement: helperDR,
                                           helperIdentifier: "Rick-Breen.VideoScan.Background", appIdentifier: "Rick-Breen.VideoScan")
        #expect(req == "(identifier \"Rick-Breen.VideoScan\" or identifier \"Rick-Breen.VideoScan.Background\") and certificate leaf = H\"0123abcd\"")
    }

    @Test("an ad-hoc requirement (cdhash) or one without the helper's identifier yields nil — the caller falls back and says so")
    func adHocOrForeign() {
        #expect(PeerRequirement.forPeers(helperDesignatedRequirement: "cdhash H\"ab\"",
                                         helperIdentifier: "Rick-Breen.VideoScan.Background", appIdentifier: "Rick-Breen.VideoScan") == nil)
        #expect(PeerRequirement.forPeers(helperDesignatedRequirement: "identifier \"com.example.other\" and certificate leaf = H\"ab\"",
                                         helperIdentifier: "Rick-Breen.VideoScan.Background", appIdentifier: "Rick-Breen.VideoScan") == nil)
    }
}
