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
import UniformTypeIdentifiers

struct FamilySearchPullSheet: View {
    @ObservedObject var coordinator: FamilySearchPullCoordinator
    /// Called after a successful install so the tab can reload the tree.
    var onInstalled: (URL) -> Void
    /// "Forget this download": the owner (FamilySearchPullCenter) drops the
    /// coordinator. Closing the sheet does NOT do this — the watcher keeps
    /// running behind the sheet (2026-08-25).
    var onForget: () -> Void = {}
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
                    case .parsing(let output):
                        parsingSection(output: output)
                    case .ready(let output, let new, let current, let unmatched):
                        readySection(output: output, new: new, current: current,
                                     unmatchedFolderIDs: unmatched)
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
                Text("Each generation is another round of requests; deep lines in the shared tree are thinly sourced, so start moderate and go deeper on a line that proves solid.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: Binding(
                    get: { coordinator.request.ascend },
                    set: { coordinator.request.ascend = $0; revalidate() }),
                        in: FamilySearchPullRequest.ascendRange) {
                    LabeledContent("Ancestor steps",
                                   value: "\(coordinator.request.ascend)")
                }
                HStack(spacing: 6) {
                    ForEach(FamilySearchPullRequest.ascendPresets, id: \.self) { preset in
                        Button("\(preset)") {
                            coordinator.request.ascend = preset
                            revalidate()
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .disabled(coordinator.request.ascend == preset)
                    }
                    Text("Each step is one generation of parents; the walk stops early when a line runs out. 40 is a safety cap, not a FamilySearch limit.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

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
            Text("Switch to the Terminal window, check the command, press Return, and enter your FamilySearch password. A deep pull can take most of a night (20 generations took 9½ hours); the file is written all at once at the end.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("You can close this window — the download keeps going and the Family Tree tab will show when it's ready.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            LabeledContent("Watching for", value: output.lastPathComponent)
                .font(.system(size: 12))
            if let quietSince = coordinator.quietSince {
                // `TimelineView` ≈ a timer-driven re-render: the closure is
                // re-evaluated once a minute so the "for N min" stays honest
                // without any state of our own.
                TimelineView(.periodic(from: quietSince, by: 60)) { context in
                    Label {
                        Text(FamilySearchPullCoordinator.quietMessage(
                            fileName: output.lastPathComponent,
                            since: quietSince, now: context.date))
                            .font(.system(size: 12))
                            .fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: "clock.badge.questionmark")
                    }
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("familyTree.pullQuiet")
                }
            }
            commandPreview
        }
    }

    private func parsingSection(output: URL) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Checking \(output.lastPathComponent)…")
                    .font(.system(size: 13, weight: .medium))
            }
            Text("Reading the file and comparing it with the tree Hallie uses now. A large export takes a few seconds.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func readySection(
        output: URL,
        new: FamilySearchPullCoordinator.TreeSummary,
        current: FamilySearchPullCoordinator.TreeSummary?,
        unmatchedFolderIDs: Int
    ) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(current == nil ? "Install this family tree?" : "Replace the family tree Hallie uses?",
                  systemImage: "arrow.triangle.2.circlepath")
                .font(.system(size: 14, weight: .semibold))
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    Text("").frame(width: 90)
                    Text("People").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Families").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Generations").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("File").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let current {
                    GridRow {
                        Text("Current").font(.system(size: 12, weight: .medium))
                        Text("\(current.people)")
                        Text("\(current.families)")
                        Text("\(current.generations)")
                        Text(current.fileName).font(.system(size: 11, design: .monospaced))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                GridRow {
                    Text("New").font(.system(size: 12, weight: .medium))
                    Text("\(new.people)").fontWeight(.semibold)
                    Text("\(new.families)").fontWeight(.semibold)
                    Text("\(new.generations)").fontWeight(.semibold)
                    Text(new.fileName).font(.system(size: 11, design: .monospaced))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 13))
            if unmatchedFolderIDs > 0 {
                Label("\(unmatchedFolderIDs) photo folder\(unmatchedFolderIDs == 1 ? " is" : "s are") keyed to person IDs from the current file that the new file doesn’t use. Names still match; ID-keyed folders won’t until renamed.",
                      systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Replace copies \(new.fileName) into the archive’s 40_Family_Tree/GEDCOM folder and reloads. The current file stays there untouched — the newest valid file is the one the app reads, so moving the new one out restores the old tree. Quality is your call; VideoScan checks only that it parses.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if current != nil {
                Text("Add to current tree joins the two by FamilySearch ID: a person in both files becomes one record with both sets of links (a spouse in one pull gains her parents from the other), families with the same couple become one, and both home people are kept as roots. The result is written as a new familysearch-merged-<date>.ged in the same folder; neither source file is changed. Records without a FamilySearch ID are added, never guessed as matches.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Reveal file") {
                NSWorkspace.shared.activateFileViewerSelecting([output])
            }
            .controlSize(.small)
        }
    }

    /// A .ged that already exists — a Terminal run this sheet was not
    /// watching, an Ancestry export, a MacFamilyTree save.
    private func chooseExistingGedcom() {
        let panel = NSOpenPanel()
        panel.title = "Choose a GEDCOM file"
        panel.allowedContentTypes = [UTType(filenameExtension: "ged") ?? .data]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        if panel.runModal() == .OK, let url = panel.url {
            coordinator.installFromFile(url)
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
                Button("Install from file…") { chooseExistingGedcom() }
                Button {
                    coordinator.launch()
                } label: {
                    Label("Open in Terminal…", systemImage: "terminal")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!coordinator.toolIsInstalled || validationMessage != nil)
            case .waiting:
                Button("Install from file…") { chooseExistingGedcom() }
                Button("Forget this download") {
                    coordinator.cancel()
                    onForget()
                }
                .help("Stops watching for the file. The Terminal download keeps running; use Install from file when it finishes.")
            case .parsing:
                Button("Forget this download") {
                    coordinator.cancel()
                    onForget()
                }
                .help("Stops checking the file. Nothing has been installed.")
            case .ready(_, _, let current, _):
                Button("Keep current") { coordinator.cancel() }
                if current != nil {
                    Button("Add to current tree") {
                        Task {
                            await coordinator.installMerged()
                            if case .installed(let url, _) = coordinator.phase {
                                onInstalled(url)
                            }
                        }
                    }
                    .help("Merge by FamilySearch ID into a new .ged next to the current one; both source files stay untouched.")
                }
                Button(current == nil ? "Install family tree" : "Replace family tree") {
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
