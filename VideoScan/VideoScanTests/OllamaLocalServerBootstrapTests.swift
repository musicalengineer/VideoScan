import Foundation
import Testing
@testable import VideoScan

@Suite("Hallie local Ollama demand startup", .serialized)
struct OllamaLocalServerBootstrapTests {
    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var probeResults: [Bool]
        private(set) var probeHosts: [String] = []
        private(set) var spawnPorts: [Int] = []
        var onlineAfterSpawn = false

        init(probeResults: [Bool] = []) {
            self.probeResults = probeResults
        }

        func probe(_ host: String) -> Bool {
            lock.withLock {
                probeHosts.append(host)
                if !probeResults.isEmpty { return probeResults.removeFirst() }
                return onlineAfterSpawn && !spawnPorts.isEmpty
            }
        }

        func spawn(_ port: Int) {
            lock.withLock { spawnPorts.append(port) }
        }

        var probes: [String] { lock.withLock { probeHosts } }
        var spawns: [Int] { lock.withLock { spawnPorts } }
    }

    private func dependencies(
        _ fixture: Fixture,
        localNames: Set<String> = ["ricksm4.local", "ricksm4"],
        attempts: Int = 4
    ) -> OllamaLocalServerBootstrap.Dependencies {
        .init(
            localHostNames: { localNames },
            probe: { fixture.probe($0) },
            spawn: { fixture.spawn($0) },
            pause: { await Task.yield() },
            readinessAttempts: attempts)
    }

    @Test func alreadyRunningLocalServerIsNotSpawned() async throws {
        let fixture = Fixture(probeResults: [true])
        let bootstrap = OllamaLocalServerBootstrap(
            dependencies: dependencies(fixture))

        let outcome = try await bootstrap.ensureRunning(
            for: ["RicksM4.local", "ricksm5.local"])

        #expect(outcome == .alreadyRunning)
        #expect(fixture.spawns.isEmpty)
        #expect(fixture.probes == ["127.0.0.1:11434"])
    }

    @Test func firstQuestionStartsLocalServerAndWaitsForReadiness() async throws {
        let fixture = Fixture(probeResults: [false, false, true])
        let bootstrap = OllamaLocalServerBootstrap(
            dependencies: dependencies(fixture))

        let outcome = try await bootstrap.ensureRunning(
            for: ["RicksM4.local", "ricksm5.local"])

        #expect(outcome == .started)
        #expect(fixture.spawns == [11434])
        #expect(fixture.probes.count == 3)
    }

    @Test func remoteAndCloudEndpointsAreNeverStartedLocally() async throws {
        let fixture = Fixture(probeResults: [true])
        let bootstrap = OllamaLocalServerBootstrap(
            dependencies: dependencies(fixture))

        let outcome = try await bootstrap.ensureRunning(for: [
            "ricksm5.local",
            "https://ollama.example.com",
        ])

        #expect(outcome == .noLocalEndpoint)
        #expect(fixture.probes.isEmpty)
        #expect(fixture.spawns.isEmpty)
    }

    @Test func customLocalPortIsPreservedForSpawn() async throws {
        let fixture = Fixture(probeResults: [false, true])
        let bootstrap = OllamaLocalServerBootstrap(
            dependencies: dependencies(fixture))

        _ = try await bootstrap.ensureRunning(for: ["RicksM4.local:12345"])

        #expect(fixture.spawns == [12345])
        #expect(fixture.probes == [
            "127.0.0.1:12345", "127.0.0.1:12345",
        ])
    }

    @Test func simultaneousFirstQuestionsSpawnExactlyOneServer() async throws {
        let fixture = Fixture()
        fixture.onlineAfterSpawn = true
        let bootstrap = OllamaLocalServerBootstrap(
            dependencies: dependencies(fixture, attempts: 10))

        async let first = bootstrap.ensureRunning(for: ["RicksM4.local"])
        async let second = bootstrap.ensureRunning(for: ["RicksM4.local"])
        _ = try await (first, second)

        #expect(fixture.spawns == [11434])
    }

    @Test func startupTimeoutFailsInsteadOfSendingQuestionToDeadServer() async {
        let fixture = Fixture()
        let bootstrap = OllamaLocalServerBootstrap(
            dependencies: dependencies(fixture, attempts: 2))

        do {
            _ = try await bootstrap.ensureRunning(for: ["RicksM4.local"])
            Issue.record("dead Ollama unexpectedly became ready")
        } catch let error as OllamaLocalServerBootstrap.BootstrapError {
            #expect(error == .didNotBecomeReady("RicksM4.local"))
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(fixture.spawns == [11434])
    }

    @Test func localEndpointMatchingIsCasePortAndSchemeAware() {
        let local: Set<String> = ["ricksm4.local", "ricksm4"]
        #expect(OllamaLocalServerBootstrap.localEndpoint(
            in: ["RicksM4.local"], localHostNames: local) == "RicksM4.local")
        #expect(OllamaLocalServerBootstrap.localEndpoint(
            in: ["http://ricksm4.local:9000"], localHostNames: local)
            == "http://ricksm4.local:9000")
        #expect(OllamaLocalServerBootstrap.localEndpoint(
            in: ["ricksm5.local"], localHostNames: local) == nil)
        #expect(OllamaLocalServerBootstrap.localEndpoint(
            in: ["ricksm4.example.com"], localHostNames: local) == nil)
        #expect(OllamaLocalServerBootstrap.localEndpoint(
            in: ["https://ricksm4.local"], localHostNames: local) == nil)
        #expect(OllamaLocalServerBootstrap.localEndpoint(
            in: ["ricksm4.local:443"], localHostNames: local) == nil)
    }

    @Test func localRoutingUsesLoopbackAndPreservesRemoteOrderAndPorts() {
        let routed = OllamaLocalServerBootstrap.routeLocalEndpointsToLoopback(
            [
                "RicksM4.local",
                "ricksm5.local",
                "http://ricksm4.local:12345",
                "https://ollama.example.com",
            ],
            localHostNames: ["ricksm4.local", "ricksm4"])

        #expect(routed == [
            "127.0.0.1:11434",
            "ricksm5.local",
            "127.0.0.1:12345",
            "https://ollama.example.com",
        ])
    }

    @Test func currentHostNamesAlwaysIncludeLoopbackIdentities() {
        let names = OllamaLocalServerBootstrap.currentLocalHostNames()
        #expect(names.contains("localhost"))
        #expect(names.contains("127.0.0.1"))
        #expect(names.contains("::1"))
    }
}
