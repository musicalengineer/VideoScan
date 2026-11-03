// BackgroundServiceRegistrar.swift — the app's side of VideoScan Background
// (docs/design/background_service.md §3.2, §3.3; step 0).
//
// Two small things, both OFF by default so Rick's normal launch changes
// nothing (the user-defaults key `background.service.enabled`, false until
// he sets it for a spot test):
//
//   • `BackgroundServiceRegistrar` — SMAppService.agent(plistName:) over the
//     launchd plist the app carries at Contents/Library/LaunchAgents/.
//     `register()` makes macOS show "VideoScan added items that can run in
//     the background" and lists the helper under Login Items; Rick can
//     switch it off there, and `status` says so instead of assuming.
//     The service is reached through the `BackgroundAgentService` seam so a
//     test can prove that a disabled launch makes NO ServiceManagement call.
//
//   • `BackgroundServiceClient` — an NSXPCConnection to the Mach service;
//     `status()` (step 0) and `enqueue()` (Settings ▸ Background, 11/02).
//     The MFO row that draws a service job is still to come; the Settings
//     pane is `BackgroundServiceStore` + `ContentAnalysisSettingsRows`.
//
// C++ reading: the client is a proxy object over an IPC channel; every
// call is async and comes back as a value or a refusal in words.

import Foundation
import ServiceManagement
import VideoScanCore

/// What the registrar needs from SMAppService — an interface so a test can
/// stand in for ServiceManagement.
protocol BackgroundAgentService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: BackgroundAgentService {}

enum BackgroundServiceRegistrar {
    /// `defaults write Rick-Breen.VideoScan background.service.enabled -bool true`
    static let enabledDefaultsKey = "background.service.enabled"

    static let appBundleIdentifier = Bundle.main.bundleIdentifier ?? "Rick-Breen.VideoScan"
    static var plistName: String { BackgroundServiceNames.launchdPlistName(appBundleIdentifier: appBundleIdentifier) }
    static var machServiceName: String { BackgroundServiceNames.machServiceName(appBundleIdentifier: appBundleIdentifier) }

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }

    private static var agent: any BackgroundAgentService { SMAppService.agent(plistName: plistName) }

    /// What launchd says — never assumed (design §2 caveat).
    static var status: SMAppService.Status { agent.status }

    static func statusWords(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval in System Settings ▸ General ▸ Login Items"
        case .notFound: return "plist not found in the app bundle"
        @unknown default: return "unknown (\(status.rawValue))"
        }
    }

    /// Called once at launch. Does nothing — not even make the service —
    /// unless `enabled` (the defaults key) is true.
    static func registerIfEnabled(enabled: Bool = isEnabled,
                                  service: () -> any BackgroundAgentService = { agent },
                                  log: (String) -> Void) {
        guard enabled else { return }
        let agent = service()
        do {
            try agent.register()
            log("background service: registered \(plistName) — \(statusWords(agent.status))")
        } catch {
            log("background service: register failed — \(error.localizedDescription) (status \(statusWords(agent.status)))")
        }
    }

    /// Returns the failure's words, nil on success (the Settings line shows them).
    @discardableResult
    static func unregister(service: () -> any BackgroundAgentService = { agent }, log: (String) -> Void) -> String? {
        do {
            try service().unregister()
            log("background service: unregistered \(plistName)")
            return nil
        } catch {
            let words = (error as? Refusal)?.words ?? error.localizedDescription
            log("background service: unregister failed — \(words)")
            return words
        }
    }
}

/// XPC client to the running service (launchd starts it on the first message).
/// Two verbs today: `status` (step 0) and `enqueue` (Settings ▸ Background,
/// 2026-11-02: the app queues the era job when work is left).
final class BackgroundServiceClient: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(machServiceName: String = BackgroundServiceRegistrar.machServiceName) {
        connection = NSXPCConnection(machServiceName: machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundServiceXPC.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    func status() async -> Result<ServiceStatus, Refusal> {
        await call { proxy, once in
            proxy.status { data in once.resume(Self.decode(ServiceStatus.self, data)) }
        }
    }

    /// `JobRequest` → accepted with its id, or refused in the helper's words.
    func enqueue(_ request: JobRequest) async -> Result<EnqueueReply, Refusal> {
        guard let data = try? BackgroundPayloadCodec.encode(request) else {
            return .failure(Refusal("could not encode the request"))
        }
        return await call { proxy, once in
            proxy.enqueue(data) { reply in once.resume(Self.decode(EnqueueReply.self, reply)) }
        }
    }

    private static func decode<T: Codable>(_ type: T.Type, _ data: Data) -> Result<T, Refusal> {
        do {
            return .success(try BackgroundPayloadCodec.decode(type, from: data))
        } catch {
            return .failure((error as? Refusal) ?? Refusal(String(describing: error)))
        }
    }

    /// One round trip: the proxy's reply or its error handler, whichever
    /// lands first; the other is dropped.
    private func call<T: Sendable>(_ body: (BackgroundServiceXPC, OnceResume<Result<T, Refusal>>) -> Void) async -> Result<T, Refusal> {
        await Self.awaitReply(within: Self.replyDeadline) { once in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(.failure(Refusal("VideoScan Background did not answer: \(error.localizedDescription)")))
            }) as? BackgroundServiceXPC else {
                once.resume(.failure(Refusal("could not make the XPC proxy")))
                return
            }
            body(proxy, once)
        }
    }

    /// A helper that takes the message and never answers fails the call
    /// after this (codex-1102 F7) instead of holding the refresh cycle
    /// forever. Generous: launchd may cold-start the helper on this message.
    static let replyDeadline: Duration = .seconds(30)

    /// The app's one-shot latch with a deadline (`OnceResume.race`,
    /// CatalogQuitRecovery.swift): the reply, the error handler or the timer,
    /// whichever lands first; the others are dropped.
    static func awaitReply<T: Sendable>(within deadline: Duration,
                                        _ start: (OnceResume<Result<T, Refusal>>) -> Void) async -> Result<T, Refusal> {
        let seconds = Double(deadline.components.seconds) + Double(deadline.components.attoseconds) / 1e18
        return await OnceResume<Result<T, Refusal>>.race(
            within: seconds,
            timeout: .failure(Refusal("VideoScan Background did not answer within \(deadline.components.seconds) s")),
            start)
    }
}
