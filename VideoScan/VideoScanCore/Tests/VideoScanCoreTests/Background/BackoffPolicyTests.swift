// BackoffPolicyTests.swift — every row of the design §3.5 table, the
// precedence where rows meet, the thermal hysteresis, the idle-exit rule
// and the peer-trust decision.
//
// Dimensions: LOGIC. The sources are fakes; no Mac state is read.

import Foundation
import Testing
@testable import VideoScanCore

@Suite("Backoff — the §3.5 table")
struct BackoffPolicyTests {

    @Test("nobody at the keyboard → full")
    func idleIsFull() {
        #expect(BackoffPolicy.state(for: ActivitySample(secondsSinceLastInput: 3600)) == .full)
    }

    @Test("Rick is at the keyboard (input < 300 s) → trickle")
    func recentInputTrickles() {
        #expect(BackoffPolicy.state(for: ActivitySample(secondsSinceLastInput: 12)) == .trickle)
        #expect(BackoffPolicy.state(for: ActivitySample(secondsSinceLastInput: 299.9)) == .trickle)
        #expect(BackoffPolicy.state(for: ActivitySample(secondsSinceLastInput: 300)) == .full)
    }

    @Test("the app is frontmost on an attended job → trickle, even when idle")
    func attendedTrickles() {
        #expect(BackoffPolicy.state(for: ActivitySample(secondsSinceLastInput: 3600, appForegroundAttended: true)) == .trickle)
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

    @Test("the night window → full regardless of idle or the attended app")
    func night() {
        #expect(BackoffPolicy.state(for: ActivitySample(secondsSinceLastInput: 1, appForegroundAttended: true, nightWindow: true)) == .full)
    }

    @Test("screen locked → full (Rick is away) even with recent input")
    func locked() {
        #expect(BackoffPolicy.state(for: ActivitySample(secondsSinceLastInput: 1, isScreenLocked: true)) == .full)
    }

    @Test("the Mac comes first: thermal beats night, memory beats locked")
    func precedence() {
        #expect(BackoffPolicy.state(for: ActivitySample(thermalState: .serious, nightWindow: true)) == .paused(reason: "thermal"))
        #expect(BackoffPolicy.state(for: ActivitySample(isScreenLocked: true, memoryPressure: .warning)) == .paused(reason: "memory"))
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

@Suite("IdleExitPolicy — exit after 10 idle minutes with nothing queued")
struct IdleExitPolicyTests {
    @Test("exits only when the queue is empty, no job is active and the idle time has passed")
    func rule() {
        #expect(IdleExitPolicy.shouldExit(idleSeconds: 600, queueEmpty: true, activeJobs: 0))
        #expect(!IdleExitPolicy.shouldExit(idleSeconds: 599, queueEmpty: true, activeJobs: 0))
        #expect(!IdleExitPolicy.shouldExit(idleSeconds: 6000, queueEmpty: false, activeJobs: 0))
        #expect(!IdleExitPolicy.shouldExit(idleSeconds: 6000, queueEmpty: true, activeJobs: 1), "a paused job is work waiting")
        #expect(IdleExitPolicy.defaultIdleSeconds == 600)
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
