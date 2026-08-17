// MasterArchiveInitSheet.swift
// "Initialize as Master Archive…" confirmation (design v2 §4). Shows the
// volume, its Safe-Archive assessment (RAID? trust? reachable?), the
// exact tree Initialize will create, and the "Also add as scan target"
// line, then performs the ONE gesture on Confirm. Driven by
// `model.pendingMasterArchiveInitOffer` (model-level so the Volumes
// window right-click, the File ▸ Archive menu, and the no-master alert's
// fix-it button all share this sheet — bound in ContentView).
//
// The "no master" alert lives here too (same feature, same file), plus
// the NSOpenPanel entry point the File menu uses for a never-seen volume.

import AppKit
import SwiftUI

struct MasterArchiveInitSheet: View {
    @EnvironmentObject private var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    let offer: MasterArchiveInitOffer

    @State private var errorText: String?
    @State private var busy = false

    private var target: CatalogScanTarget? {
        model.scanTargets.first {
            PathScope.normalize($0.searchPath) == PathScope.normalize(offer.targetPath)
        }
    }

    private var volumeLabel: String {
        VolumeReachability.displayLabel(forPath: offer.targetPath)
    }

    private var rootPath: String {
        MasterArchiveLayout.rootURL(forTargetPath: offer.targetPath).path
    }

    private var alreadyInitialized: Bool {
        FileManager.default.fileExists(atPath: MasterArchiveLayout.manifestURL(rootPath: rootPath).path)
    }

    private var replacingExisting: Bool {
        guard let current = model.masterArchive else { return false }
        return PathScope.normalize(current.targetPath) != PathScope.normalize(offer.targetPath)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "archivebox.fill")
                    .font(.system(size: 28))
                    .foregroundColor(.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Initialize \(volumeLabel) as the Master Archive?")
                        .font(.headline)
                    Text(offer.targetPath)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            assessment

            GroupBox("This will create") {
                VStack(alignment: .leading, spacing: 3) {
                    treeLine("\(MasterArchiveLayout.rootFolderName)/", indent: 0)
                    treeLine("\(MasterArchiveLayout.indexFolder)/", indent: 1)
                    treeLine(MasterArchiveLayout.manifestFilename + "   (header row; append-only)", indent: 2)
                    treeLine(MasterArchiveLayout.readmeFilename + "   (the rules, in plain English)", indent: 2)
                    treeLine("\(MasterArchiveLayout.photosBucket)/", indent: 1)
                    treeLine("\(MasterArchiveLayout.audioBucket)/", indent: 1)
                    treeLine("\(MasterArchiveLayout.videoBucket)/", indent: 1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Label(offer.isNewTarget
                      ? "Also add \(volumeLabel) as a scan target (role: Master Archive)"
                      : "Set \(volumeLabel)'s role to Master Archive",
                      systemImage: "checkmark.circle")
                    .font(.system(size: 12))
                if alreadyInitialized {
                    Label("An archive tree already exists here — nothing will be rewritten or truncated; the manifest keeps its rows.",
                          systemImage: "info.circle")
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                }
                if replacingExisting, let current = model.masterArchive {
                    Label("Replaces the current Master Archive designation (\(VolumeReachability.displayLabel(forPath: current.targetPath))). Files there are untouched.",
                          systemImage: "exclamationmark.triangle")
                        .font(.system(size: 12))
                        .foregroundColor(.orange)
                }
                if !offer.promoteAfterwards.isEmpty {
                    Label("Then promote the \(offer.promoteAfterwards.count) selected file(s).",
                          systemImage: "arrow.right.circle")
                        .font(.system(size: 12))
                }
            }

            if let errorText {
                Text(errorText)
                    .font(.system(size: 12))
                    .foregroundColor(.red)
                    .textSelection(.enabled)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(busy ? "Initializing…" : "Initialize") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy)
                    .accessibilityIdentifier("masterArchive.init.confirm")
            }
        }
        .padding(20)
        .frame(width: 560)
    }

    /// Destination assessment — what the catalog KNOWS about this volume
    /// (role / media type / trust / reachability, all user-entered or
    /// observed). It is NOT a drive-health check and never claims the
    /// RAID is healthy (codex QA major d): SMART lives in Drive Health.
    @ViewBuilder
    private var assessment: some View {
        let reachable = FileManager.default.fileExists(atPath: offer.targetPath)
        let tech = target?.mediaTech ?? .unknown
        let trust = target?.trust ?? .unknown
        GroupBox("Destination assessment (from your volume settings — not a health check)") {
            VStack(alignment: .leading, spacing: 3) {
                if let t = target, t.isRetired {
                    Label("This volume is marked retired — Initialize will be refused until you reinstate it.",
                          systemImage: "xmark.octagon")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
                assessLine(reachable, ok: "Reachable now", bad: "Not reachable — connect it before promoting")
                assessLine(tech.isRedundant,
                           ok: "Redundant media (\(tech.rawValue))",
                           bad: tech == .unknown
                               ? "Media type unknown — set it in the Volumes editor (RAID-5 = redundant)"
                               : "Not redundant (\(tech.rawValue)) — a single-disk failure loses the archive")
                assessLine(trust == .reliable,
                           ok: "Trust: Reliable",
                           bad: "Trust: \(trust.rawValue) — set to Reliable once you are confident in the drive")
                if tech.isFragile || trust == .unreliable {
                    Label("This volume's destination policy is FORBIDDEN (RAID-0 or trust Unreliable). You can still initialize it, but the archive would live on a volume your own settings say not to trust.",
                          systemImage: "xmark.octagon")
                        .font(.system(size: 12))
                        .foregroundColor(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private func assessLine(_ ok: Bool, ok okText: String, bad: String) -> some View {
        Label(ok ? okText : bad, systemImage: ok ? "checkmark.circle.fill" : "exclamationmark.triangle")
            .font(.system(size: 12))
            .foregroundColor(ok ? .green : .orange)
    }

    private func treeLine(_ text: String, indent: Int) -> some View {
        Text(String(repeating: "    ", count: indent) + (indent > 0 ? "└ " : "") + text)
            .font(.system(size: 11, design: .monospaced))
    }

    private func confirm() {
        busy = true
        do {
            try model.initializeMasterArchive(at: URL(fileURLWithPath: offer.targetPath, isDirectory: true))
            let followUp = offer.promoteAfterwards
            dismiss()
            if !followUp.isEmpty {
                // Chained-sheet antipattern: never present the next sheet in
                // the same turn as this dismiss — hop one main-actor turn.
                Task { @MainActor in
                    model.requestPromote(recordIDs: followUp)
                }
            }
        } catch {
            errorText = "Could not initialize: \(error.localizedDescription)"
            busy = false
        }
    }
}

// MARK: - Entry points shared by menu / alert / context menus

extension VideoScanModel {

    /// Offer Initialize for a specific path (Volumes-window right-click).
    func offerInitializeMasterArchive(atPath path: String, promoteAfterwards: [UUID] = []) {
        let known = scanTargets.contains {
            PathScope.normalize($0.searchPath) == PathScope.normalize(path)
        }
        pendingMasterArchiveInitOffer = MasterArchiveInitOffer(
            targetPath: path, isNewTarget: !known, promoteAfterwards: promoteAfterwards)
    }

    /// File ▸ Archive ▸ Initialize Master Archive… — NSOpenPanel for a
    /// volume or folder (never-seen volumes welcome), then the same sheet.
    func chooseAndOfferInitializeMasterArchive(promoteAfterwards: [UUID] = []) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose the volume (or folder) that will hold the Master Archive"
        panel.prompt = "Choose"
        if let current = masterArchive {
            panel.directoryURL = URL(fileURLWithPath: current.targetPath)
        } else {
            panel.directoryURL = URL(fileURLWithPath: "/Volumes")
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard !CatalogScanTarget.isScratchVolumePath(url.path) else {
            log("That's VideoScan's own RAM-disk scratch volume — not a place for the archive.")
            return
        }
        offerInitializeMasterArchive(atPath: url.path, promoteAfterwards: promoteAfterwards)
    }

    /// File ▸ Archive ▸ Reveal Master Archive in Finder.
    func revealMasterArchiveInFinder() {
        guard let root = masterArchiveRootPath else { return }
        if FileManager.default.fileExists(atPath: root) {
            NSWorkspace.shared.selectFile(root, inFileViewerRootedAtPath: (root as NSString).deletingLastPathComponent)
        } else {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: (root as NSString).deletingLastPathComponent)
        }
    }

    /// File ▸ Archive ▸ Open Manifest — the CSV in its default app.
    func openMasterArchiveManifest() {
        guard let root = masterArchiveRootPath else { return }
        let url = MasterArchiveLayout.manifestURL(rootPath: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            log("The manifest is not reachable at \(url.path) — is the archive volume connected?")
            return
        }
        NSWorkspace.shared.open(url)
    }
}
