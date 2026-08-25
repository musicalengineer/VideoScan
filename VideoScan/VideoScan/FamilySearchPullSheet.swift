// FamilySearchPullSheet.swift
// The "Get Family Tree" sheet: pick how deep to go, read the exact command,
// hand it to Terminal, then install what comes back.
//
// The command preview is not decoration. The user explicitly asked to see
// and approve the line before it runs (Rick 2026-08-25), and the Terminal
// window asks a second time before executing. Nothing here ever takes,
// displays, or stores a password.

import AppKit
import SwiftUI

struct FamilySearchPullSheet: View {
    @ObservedObject var coordinator: FamilySearchPullCoordinator
    /// Called after a successful install so the tab can reload the tree.
    var onInstalled: (URL) -> Void
    @Environment(\.dismiss) private var dismiss

    @State private var validationMessage: String?
    @State private var showAdvanced = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    switch coordinator.phase {
                    case .idle, .failed:
                        optionsForm
                    case .waiting(let output):
                        waitingSection(output: output)
                    case .ready(let output, let people, let generations):
                        readySection(output: output, people: people,
                                     generations: generations)
                    case .installed(let installed, let people):
                        installedSection(installed: installed, people: people)
                    }
                    if case .failed(let message) = coordinator.phase {
                        errorBox(message)
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 620, height: 560)
        .onAppear { revalidate() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.down.circle")
                .font(.title2)
                .foregroundStyle(.teal)
            VStack(alignment: .leading, spacing: 2) {
                Text("Get Family Tree")
                    .font(.title3.weight(.semibold))
                Text("Download your tree from FamilySearch as a GEDCOM file")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Options

    @ViewBuilder
    private var optionsForm: some View {
        if !coordinator.toolIsInstalled {
            toolMissingBox
        }

        explainer

        Form {
            Section {
                TextField("FamilySearch username",
                          text: Binding(
                            get: { coordinator.request.username },
                            set: { coordinator.request.username = $0; revalidate() }))
                    .textContentType(.username)
                Text("The email address you sign in to FamilySearch with. Your password is typed into Terminal, never here.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("Start from person ID (optional)",
                          text: Binding(
                            get: { coordinator.request.startPersonID },
                            set: { coordinator.request.startPersonID = $0; revalidate() }),
                          prompt: Text("LF7T-Y4C — leave blank to start from you"))
                Text("To go deeper than eight generations, run this again starting from an end-of-line ancestor.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: Binding(
                    get: { coordinator.request.ascend },
                    set: { coordinator.request.ascend = $0; revalidate() }),
                        in: FamilySearchPullRequest.ascendRange) {
                    LabeledContent("Generations back",
                                   value: "\(coordinator.request.ascend)")
                }
                Text("FamilySearch allows at most eight per run.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Stepper(value: Binding(
                    get: { coordinator.request.descend },
                    set: { coordinator.request.descend = $0; revalidate() }),
                        in: FamilySearchPullRequest.descendRange) {
                    LabeledContent("Generations forward",
                                   value: coordinator.request.descend == 0
                                        ? "none"
                                        : "\(coordinator.request.descend)")
                }

                Toggle("Include spouses and marriages", isOn: Binding(
                    get: { coordinator.request.includeMarriage },
                    set: { coordinator.request.includeMarriage = $0; revalidate() }))
            }

            Section {
                LabeledContent("Save to") {
                    HStack(spacing: 8) {
                        Text(coordinator.request.outputURL.lastPathComponent)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Button("Choose…") { chooseOutput() }
                            .controlSize(.small)
                    }
                }
                Text(coordinator.request.outputURL.deletingLastPathComponent().path)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            DisclosureGroup("Politeness settings", isExpanded: $showAdvanced) {
                Stepper(value: Binding(
                    get: { coordinator.request.rateLimit },
                    set: { coordinator.request.rateLimit = $0; revalidate() }),
                        in: FamilySearchPullRequest.rateLimitRange) {
                    LabeledContent("Requests per second",
                                   value: "\(coordinator.request.rateLimit)")
                }
                Stepper(value: Binding(
                    get: { coordinator.request.concurrency },
                    set: { coordinator.request.concurrency = $0; revalidate() }),
                        in: FamilySearchPullRequest.concurrencyRange) {
                    LabeledContent("Parallel downloads",
                                   value: "\(coordinator.request.concurrency)")
                }
                Text("FamilySearch throttles per account and publishes no fixed budget. These defaults stay well under the tool's own, which matters because it runs on a shared third-party app key.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)

        if let validationMessage {
            Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        }

        commandPreview
    }

    private var explainer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("How this works")
                .font(.system(size: 12, weight: .semibold))
            Text("VideoScan writes the command below and opens it in Terminal. You read it, press Return, and type your FamilySearch password at the tool's own prompt. VideoScan never sees or stores that password — which is why this step isn't automatic.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.teal.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var toolMissingBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("getmyancestors is not installed", systemImage: "shippingbox")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.orange)
            Text("Install it once, then reopen this sheet:")
                .font(.system(size: 12))
            Text("python3 -m venv ~/dev/VideoScan/venv-genealogy\n~/dev/VideoScan/venv-genealogy/bin/pip install getmyancestors")
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private var commandPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Command")
                .font(.system(size: 12, weight: .semibold))
            Text(coordinator.previewLine.isEmpty
                 ? "—"
                 : coordinator.previewLine)
                .font(.system(size: 11, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.black.opacity(0.25))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            Text("No password appears in this command, in your shell history, or on disk.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Phases

    private func waitingSection(output: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Waiting for Terminal to finish…")
                    .font(.system(size: 13, weight: .medium))
            }
            Text("Switch to the Terminal window, check the command, press Return, and enter your FamilySearch password. A deep pull can take tens of minutes — you can leave this sheet open.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Watching for", value: output.lastPathComponent)
                .font(.system(size: 12))
            commandPreview
        }
    }

    private func readySection(output: URL, people: Int, generations: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Download finished", systemImage: "checkmark.circle.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            HStack(spacing: 24) {
                stat("People", "\(people)")
                stat("Generations deep", "\(generations)")
            }
            Text("\(output.lastPathComponent) parsed cleanly. Installing copies it into the archive's 40_Family_Tree/GEDCOM folder; the previous tree is kept alongside it, and the newest valid file is the one the app reads.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Reveal downloaded file") {
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
            .controlSize(.small)
        }
    }

    private func installedSection(installed: URL, people: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Installed", systemImage: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.green)
            Text("\(people) people are now in your family tree.")
                .font(.system(size: 13))
            Text(installed.path)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            Text("Long ancestral lines from the shared tree are user-submitted and thinly sourced the further back they go. Worth a look before treating the deep end as fact.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .semibold))
            Text(label).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func errorBox(_ message: String) -> some View {
        Label(message, systemImage: "xmark.octagon.fill")
            .font(.system(size: 12))
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Close") { dismiss() }
            Spacer()
            switch coordinator.phase {
            case .idle, .failed:
                Button {
                    coordinator.launch()
                } label: {
                    Label("Open in Terminal…", systemImage: "terminal")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.toolIsInstalled || validationMessage != nil)
            case .waiting:
                Button("Stop waiting") { coordinator.cancel() }
            case .ready:
                Button("Install family tree") {
                    coordinator.install()
                    if case .installed(let url, _) = coordinator.phase {
                        onInstalled(url)
                    }
                }
                .keyboardShortcut(.defaultAction)
            case .installed:
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Actions

    private func revalidate() {
        validationMessage = coordinator.refreshPreview()?.localizedDescription
    }

    private func chooseOutput() {
        let panel = NSSavePanel()
        panel.title = "Save the downloaded family tree"
        panel.allowedContentTypes = []
        panel.nameFieldStringValue = coordinator.request.outputURL.lastPathComponent
        panel.directoryURL = coordinator.request.outputURL.deletingLastPathComponent()
        guard panel.runModal() == .OK, var url = panel.url else { return }
        if url.pathExtension.lowercased() != "ged" {
            url.appendPathExtension("ged")
        }
        coordinator.request.outputURL = url
        revalidate()
    }
}
