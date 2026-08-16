// OllamaLocalServerBootstrap.swift
// Demand-start the LOCAL Hallie brain on the first submitted question.
//
// This is deliberately not an app-launch service. Hallie pays no process or
// memory cost until somebody talks to her. The first turn probes the local
// endpoint, starts `ollama serve` when needed, waits a bounded five seconds
// for /api/tags, and only then sends the translation request. Remote laptops
// and cloud endpoints are never launched by this machine.

import Foundation
import VideoScanCore

actor OllamaLocalServerBootstrap {
    enum Outcome: Equatable, Sendable {
        case noLocalEndpoint
        case alreadyRunning
        case started
    }

    enum BootstrapError: LocalizedError, Equatable {
        case executableNotFound([String])
        case didNotBecomeReady(String)

        var errorDescription: String? {
            switch self {
            case .executableNotFound(let paths):
                return "Ollama is not installed in " + paths.joined(separator: " or ")
            case .didNotBecomeReady(let endpoint):
                return "Ollama was started for \(endpoint), but did not become ready"
            }
        }
    }

    struct Dependencies: Sendable {
        var localHostNames: @Sendable () -> Set<String>
        var probe: @Sendable (String) async -> Bool
        var spawn: @Sendable (Int) throws -> Void
        var pause: @Sendable () async -> Void
        var readinessAttempts: Int

        static let live = Dependencies(
            localHostNames: { OllamaLocalServerBootstrap.currentLocalHostNames() },
            probe: { endpoint in
                var probe = OllamaQueryTranslator()
                probe.host = endpoint
                probe.probeTimeoutSeconds = 0.5
                return await probe.probeLiveness() == nil
            },
            spawn: { port in
                let searched = ["/opt/homebrew/bin/ollama", "/usr/local/bin/ollama"]
                guard let path = searched.first(where: {
                    FileManager.default.isExecutableFile(atPath: $0)
                }) else {
                    throw BootstrapError.executableNotFound(searched)
                }
                let logs = FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Library/Logs/VideoScan", isDirectory: true)
                let launcher = PosixSpawnHelperLauncher()
                _ = try launcher.spawnDetached(
                    executableURL: URL(fileURLWithPath: "/usr/bin/env"),
                    arguments: [
                        "OLLAMA_HOST=0.0.0.0:\(port)",
                        path,
                        "serve",
                    ],
                    logFileURL: logs.appendingPathComponent("ollama.log"))
                appLog.write("Hallie: demand-started local Ollama on port \(port)")
            },
            pause: {
                try? await Task.sleep(nanoseconds: 100_000_000)
            },
            readinessAttempts: 50)
    }

    static let shared = OllamaLocalServerBootstrap()

    private let dependencies: Dependencies
    private var startupTask: Task<Void, Error>?

    init(dependencies: Dependencies = .live) {
        self.dependencies = dependencies
    }

    /// Ensure the first endpoint that names THIS Mac is serving. A fleet with
    /// only remote/cloud endpoints passes through untouched.
    @discardableResult
    func ensureRunning(for hosts: [String]) async throws -> Outcome {
        guard let endpoint = Self.localEndpoint(
            in: hosts, localHostNames: dependencies.localHostNames()) else {
            return .noLocalEndpoint
        }

        if let current = startupTask {
            try await current.value
            return .started
        }
        if await dependencies.probe(endpoint) { return .alreadyRunning }

        // Actor reentrancy: another ask may have created the task while this
        // one awaited its probe. Join it instead of spawning a second server.
        if let current = startupTask {
            try await current.value
            return .started
        }

        let port = Self.port(for: endpoint)
        let deps = dependencies
        let task = Task {
            try deps.spawn(port)
            for _ in 0..<max(1, deps.readinessAttempts) {
                if await deps.probe(endpoint) { return }
                await deps.pause()
            }
            throw BootstrapError.didNotBecomeReady(endpoint)
        }
        startupTask = task
        do {
            try await task.value
            startupTask = nil
            return .started
        } catch {
            startupTask = nil
            throw error
        }
    }

    static func localEndpoint(
        in hosts: [String],
        localHostNames: Set<String>
    ) -> String? {
        let local = Set(localHostNames.map(normalizedHost))
        return hosts.first { endpoint in
            guard let url = endpointURL(endpoint),
                  url.scheme == "http",
                  (url.port ?? 11434) >= 1024,
                  let host = url.host else { return false }
            return local.contains(normalizedHost(host))
        }
    }

    static func isLocalEndpoint(_ endpoint: String) -> Bool {
        localEndpoint(in: [endpoint], localHostNames: currentLocalHostNames()) != nil
    }

    static func currentLocalHostNames() -> Set<String> {
        var names: Set<String> = ["localhost", "127.0.0.1", "::1"]
        let hostName = ProcessInfo.processInfo.hostName
        names.insert(normalizedHost(hostName))
        if let short = hostName.split(separator: ".").first {
            let shortName = normalizedHost(String(short))
            names.insert(shortName)
            names.insert(shortName + ".local")
        }
        return names
    }

    static func port(for endpoint: String) -> Int {
        guard let url = URL(string: OllamaEndpoints.tagsURLString(
            for: endpoint, defaultPort: 11434)) else { return 11434 }
        return url.port ?? (url.scheme == "https" ? 443 : 11434)
    }

    private static func endpointURL(_ endpoint: String) -> URL? {
        URL(string: OllamaEndpoints.tagsURLString(
            for: endpoint, defaultPort: 11434))
    }

    fileprivate static func normalizedHost(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
    }
}
