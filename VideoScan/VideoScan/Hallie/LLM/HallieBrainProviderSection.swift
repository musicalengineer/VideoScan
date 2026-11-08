// HallieBrainProviderSection.swift
// Settings ▸ Hallie: which brain answers — Local (Ollama), the default, or
// Cloud (Anthropic), opt-in (Rick, 2026-11-07). Sits above the host list.
//
// The pane never shows the key. It says whether one is FOUND, reading the
// Keychain item's attributes only (no secret, no access prompt).

import SwiftUI

struct HallieBrainProviderSection: View {
    var defaultsStore: UserDefaults = .standard
    var keychain: any HallieKeychainReading = SystemKeychain()

    @State private var provider: HallieBrainProvider = .local
    @State private var cloudModel = HallieBrainSettings.defaultCloudModel
    @State private var keySource: String?
    @State private var loaded = false

    static let cloudCaption = "Questions and the facts Hallie looks up are sent to Anthropic. "
        + "Never photos, video, audio or face data."

    static func keyStatus(source: String?) -> String {
        guard let source else {
            return "No key found. Add one to the Keychain as \"\(AnthropicKeyLocator.primaryService)\"; "
                + "until then, questions fail with a plain message and nothing is sent."
        }
        return "Key found in the Keychain (\(source))."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Brain")
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 54, alignment: .leading)
                Picker("", selection: $provider) {
                    ForEach(HallieBrainProvider.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .fixedSize()
                .accessibilityIdentifier("archivist.brainProvider")
                .onChange(of: provider) { _, chosen in
                    HallieBrainSettings.setProvider(chosen, defaultsStore)
                    appLog.write("[hallie] brain provider set to \(chosen.rawValue)")
                    refreshKey()
                }
                Spacer()
            }
            if provider == .cloud {
                cloudDetails
            }
        }
        .onAppear {
            if !loaded {
                provider = HallieBrainSettings.provider(defaultsStore)
                cloudModel = HallieBrainSettings.cloudModel(defaultsStore)
                loaded = true
            }
            refreshKey()
        }
    }

    @ViewBuilder private var cloudDetails: some View {
        HStack(spacing: 8) {
            Text("Model")
                .font(.system(size: 12, weight: .medium))
                .frame(width: 54, alignment: .leading)
            Picker("", selection: $cloudModel) {
                if !HallieBrainSettings.cloudModels.contains(cloudModel) {
                    Text(cloudModel).tag(cloudModel)
                }
                ForEach(HallieBrainSettings.cloudModels, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .font(.system(size: 12, design: .monospaced))
            .fixedSize()
            .accessibilityIdentifier("archivist.cloudModel")
            .onChange(of: cloudModel) { _, chosen in
                HallieBrainSettings.setCloudModel(chosen, defaultsStore)
            }
            Spacer()
        }
        Text(Self.cloudCaption)
            .font(.caption)
            .foregroundColor(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        Text(Self.keyStatus(source: keySource))
            .font(.caption)
            .foregroundColor(keySource == nil ? .orange : .secondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("archivist.cloudKeyStatus")
    }

    private func refreshKey() {
        keySource = AnthropicKeyLocator.presentSource(in: keychain)
    }
}
