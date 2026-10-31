// BackgroundServiceRegistrar.swift — the app's side of VideoScan Background
// (docs/design/background_service_2026_10_30.md §3.2, §3.3; step 0).
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
//     `status()` is the one call step 0 needs. The MFO row that draws a
//     service job, and Settings ▸ Background, are Rick's UI step and are
//     not here.
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

    static func unregister(service: () -> any BackgroundAgentService = { agent }, log: (String) -> Void) {
        do {
            try service().unregister()
            log("background service: unregistered \(plistName)")
        } catch {
            log("background service: unregister failed — \(error.localizedDescription)")
        }
    }
}

/// XPC client to the running service (launchd starts it on the first message).
final class BackgroundServiceClient: @unchecked Sendable {
    private let connection: NSXPCConnection

    init(machServiceName: String = BackgroundServiceRegistrar.machServiceName) {
        connection = NSXPCConnection(machServiceName: machServiceName)
        connection.remoteObjectInterface = NSXPCInterface(with: BackgroundServiceXPC.self)
        connection.resume()
    }

    deinit { connection.invalidate() }

    func status() async -> Result<ServiceStatus, Refusal> {
        await withCheckedContinuation { (continuation: CheckedContinuation<Result<ServiceStatus, Refusal>, Never>) in
            let once = OnceResume(continuation)
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ error in
                once.resume(.failure(Refusal("VideoScan Background did not answer: \(error.localizedDescription)")))
            }) as? BackgroundServiceXPC else {
                once.resume(.failure(Refusal("could not make the XPC proxy")))
                return
            }
            proxy.status { data in
                do {
                    once.resume(.success(try BackgroundPayloadCodec.decode(ServiceStatus.self, from: data)))
                } catch {
                    once.resume(.failure((error as? Refusal) ?? Refusal(String(describing: error))))
                }
            }
        }
    }

    /// The reply or the error handler, whichever lands first; the other is dropped.
    private final class OnceResume: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Result<ServiceStatus, Refusal>, Never>?
        init(_ c: CheckedContinuation<Result<ServiceStatus, Refusal>, Never>) { continuation = c }
        func resume(_ result: Result<ServiceStatus, Refusal>) {
            lock.lock()
            let c = continuation
            continuation = nil
            lock.unlock()
            c?.resume(returning: result)
        }
    }
}
