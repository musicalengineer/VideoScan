// HallieBrainResolver.swift
// Which brain answers this question — read fresh on every question, from
// the settings Rick sets in Settings ▸ Hallie (2026-11-07).
//
//   archivist.brainProvider  "local" (default) | "cloud"
//   archivist.cloudModel     default "claude-sonnet-5-5"
//   archivist.ollamaModel    the local model (default HallieBrain.defaultModel)
//
// Rules this type owns:
//   * anything but "cloud" — missing, garbage, a typo — is Local;
//   * Cloud is used ONLY when chosen; nothing here falls over to it;
//   * Cloud with no Keychain key throws `.noCloudKey` before any network;
//   * a test host never resolves Cloud through `.live` (Rick's real setting
//     must not send a test's question to Anthropic), and never touches the
//     real Keychain.

import Foundation
import VideoScanCore

enum HallieBrainSettings {
    static let providerKey = "archivist.brainProvider"
    static let cloudModelKey = "archivist.cloudModel"
    static let defaultCloudModel = "claude-sonnet-5-5"
    /// The menu in Settings. A stored model outside this list still shows.
    static let cloudModels = ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-5-5"]

    static func provider(_ defaults: UserDefaults) -> HallieBrainProvider {
        defaults.string(forKey: providerKey) == HallieBrainProvider.cloud.rawValue ? .cloud : .local
    }

    static func setProvider(_ provider: HallieBrainProvider, _ defaults: UserDefaults) {
        defaults.set(provider.rawValue, forKey: providerKey)
    }

    static func cloudModel(_ defaults: UserDefaults) -> String {
        let stored = defaults.string(forKey: cloudModelKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return stored.isEmpty ? defaultCloudModel : stored
    }

    static func setCloudModel(_ model: String, _ defaults: UserDefaults) {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        defaults.set(trimmed, forKey: cloudModelKey)
    }

    static func localModel(_ defaults: UserDefaults) -> String {
        defaults.string(forKey: ArchivistEndpointSettings.modelKey) ?? HallieBrain.defaultModel
    }
}

/// Built per question and used on the spot (not Sendable: it holds a
/// UserDefaults, which Foundation does not mark Sendable).
struct HallieBrainResolver {
    var defaults: UserDefaults
    var keychain: any HallieKeychainReading
    /// The cloud brain's URLSession (tests inject a URLProtocol stub).
    var cloudSession: URLSession = .shared
    /// False in a test host for `.live`; true when a test injects its own
    /// defaults and keychain on purpose.
    var allowCloud: Bool = true
    /// The shell's explicit `--cloud` (an explicit choice, like the setting);
    /// nil = read the setting.
    var providerOverride: HallieBrainProvider?
    /// Where START/OUTCOME lines go.
    var log: @Sendable (String) -> Void = { appLog.write($0) }

    /// Production: the app's defaults and the login keychain. In a test host
    /// the provider is pinned to Local and the keychain is never read.
    static var live: HallieBrainResolver {
        HallieBrainResolver(defaults: .standard, keychain: SystemKeychain(),
                            allowCloud: !TestHostDetection.isTestHost)
    }

    /// The headless shell: Local unless `--cloud` was passed — the shell is
    /// a diagnostic surface whose reference output is the local brain.
    static func shell(_ provider: HallieBrainProvider) -> HallieBrainResolver {
        var resolver = live
        resolver.providerOverride = provider
        return resolver
    }

    var provider: HallieBrainProvider {
        guard allowCloud else { return .local }
        return providerOverride ?? HallieBrainSettings.provider(defaults)
    }

    /// The brain for one question. `hosts` and `localModel` are what the
    /// caller already resolved for Local; Cloud ignores them.
    func backend(
        hosts: [String],
        localModel: String,
        onResponder: (@Sendable (String) -> Void)? = nil
    ) throws -> any HallieBrainBackend {
        let inner: any HallieBrainBackend
        switch provider {
        case .local:
            var template = OllamaQueryTranslator()
            template.model = localModel
            inner = OllamaFailoverTranslator(hosts: hosts, template: template,
                                             onResponder: onResponder)
        case .cloud:
            guard let key = AnthropicKeyLocator.locate(in: keychain) else {
                log("[hallie] brain OUTCOME op=resolve brain=Cloud · "
                    + "\(HallieBrainSettings.cloudModel(defaults)) failed reason=no-key")
                throw HallieBrainError.noCloudKey
            }
            inner = AnthropicBrain(model: HallieBrainSettings.cloudModel(defaults),
                                   key: key, session: cloudSession,
                                   onResponder: onResponder)
        }
        return HallieLoggedBrain(inner: inner, write: log)
    }
}
