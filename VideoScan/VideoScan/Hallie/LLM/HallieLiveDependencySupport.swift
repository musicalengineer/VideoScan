// HallieLiveDependencySupport.swift
// Small dependency-only values used to keep Hallie's injectable live
// wiring out of the coordinator's already-large implementation file.

import Foundation

struct HallieLiveDependencyRoots: Sendable {
    let cyberBrain: URL?
    let pronunciationFile: URL?
    let drillFile: URL?

    init(applicationSupportRoot: URL?) {
        cyberBrain = applicationSupportRoot?.appendingPathComponent(
            "VideoScan/cyberbrain", isDirectory: true)
        let hallie = applicationSupportRoot?.appendingPathComponent(
            "VideoScan/Hallie", isDirectory: true)
        pronunciationFile = hallie?.appendingPathComponent(
            HalliePronunciationLexicon.fileName)
        drillFile = hallie?.appendingPathComponent(
            PronunciationDrillStore.fileName)
    }
}

struct HallieLiveAssetStoreFactory: Sendable {
    private let build: @Sendable () -> FamilyAssetStore

    init(_ build: @escaping @Sendable () -> FamilyAssetStore) {
        self.build = build
    }

    func callAsFunction() -> FamilyAssetStore { build() }
}

/// `NSLock` here is the C++ equivalent of a tiny mutex-protected string.
/// Ollama failover may report its responder from a non-main callback.
final class HallieLiveResponderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String?

    func set(_ value: String) {
        lock.withLock { storage = value }
    }

    var value: String? { lock.withLock { storage } }
}
