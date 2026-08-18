import SwiftUI

// MARK: - DuplicateKeeperPrecedenceSheet (2026-08-18)
//
// "Which copy do we keep?" — the user-ordered volume list behind
// DuplicateKeeperPolicy. Opened from the Volumes window toolbar because
// this is a fact ABOUT volumes — Rick's 8/18 decision: order by
// estimated reliability, RAID › HDD › SSD (SSDs are the working tier,
// never the master copy) — not a per-file setting.
//
// Deliberately small: a reorderable list, an "Add" menu of mounted /
// known volumes, per-row remove, and a reset. Every mutation writes
// through `model.saveDuplicateKeeperSettings()` (explicit-save pattern —
// @Published kills didSet). Family language per
// feedback_friendly_language.md.

struct DuplicateKeeperPrecedenceSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<String> = []

    private var precedence: [String] { model.duplicateKeeperSettings.volumePrecedence }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            list
            addAndResetBar
            crossVolumeToggle
            footer
        }
        .padding(22)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "list.number")
                .font(.system(size: 30))
                .foregroundColor(.accentColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Which copy do we keep?")
                    .font(.title2.bold())
                    .accessibilityIdentifier("dupKeeper.title")
                Text("Drives higher in the list are the more reliable homes — RAID, then hard drives, then fast SSDs used for working copies. The copy on the highest drive is the one we keep.")
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Drives that are unplugged or retired always come after the ones that are here now.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
    }

    // MARK: List

    private var list: some View {
        List(selection: $selection) {
            ForEach(Array(precedence.enumerated()), id: \.element) { index, name in
                HStack(spacing: 10) {
                    Text("\(index + 1).")
                        .font(.body.monospacedDigit())
                        .foregroundColor(.secondary)
                        .frame(width: 28, alignment: .trailing)
                    Image(systemName: name.hasPrefix("/") ? "folder" : "externaldrive")
                        .foregroundColor(.secondary)
                    Text(name)
                    if let tier = tierHint(for: name) {
                        Text(tier)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                            .foregroundColor(.secondary)
                            .help("From this drive's Media type in the Volumes editor")
                    }
                    Spacer()
                    if let hint = statusHint(for: name) {
                        Text(hint)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Button {
                        remove(name)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove \(name) from the list")
                    .accessibilityIdentifier("dupKeeper.remove.\(name)")
                }
                .tag(name)
            }
            .onMove(perform: move)
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
        .frame(minHeight: 220)
        .overlay {
            if precedence.isEmpty {
                Text("No drives listed — copies are ranked by role only.")
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: Add / reset

    private var addAndResetBar: some View {
        HStack {
            Menu {
                let choices = addableNames()
                if choices.isEmpty {
                    Text("Every known drive is already listed").disabled(true)
                }
                ForEach(choices, id: \.self) { name in
                    Button(name) { add(name) }
                }
            } label: {
                Label("Add a drive", systemImage: "plus")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityIdentifier("dupKeeper.add")

            Spacer()

            Button("Reset to Rick's order") {
                model.duplicateKeeperSettings.volumePrecedence = DuplicateKeeperSettings.defaultPrecedence
                model.saveDuplicateKeeperSettings()
            }
            .accessibilityIdentifier("dupKeeper.reset")
        }
    }

    // MARK: Working-copy cleanup toggle ("Also clean up working copies")

    private var crossVolumeToggle: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                get: { model.duplicateKeeperSettings.alsoCleanUpWorkingCopies },
                set: { on in
                    model.duplicateKeeperSettings.alsoCleanUpWorkingCopies = on
                    model.saveDuplicateKeeperSettings()
                    // The Duplicates menu counts depend on the mode.
                    model.refreshDossierCountsNow()
                })) {
                Text(WorkingCopyCleanupText.toggleLabel)
            }
            .accessibilityIdentifier("dupKeeper.workingCopyCleanupToggle")
            Text(WorkingCopyCleanupText.caption(volume: "the drive you pick"))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ties between drives at the same level go to the copy that carries more of your work — stars, people you've confirmed, notes — then to the technically better file. Takes effect the next time duplicates are analyzed.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("dupKeeper.done")
            }
        }
    }

    // MARK: Actions

    private func move(from source: IndexSet, to destination: Int) {
        var list = precedence
        list.move(fromOffsets: source, toOffset: destination)
        model.duplicateKeeperSettings.volumePrecedence = list
        model.saveDuplicateKeeperSettings()
    }

    private func remove(_ name: String) {
        model.duplicateKeeperSettings.volumePrecedence.removeAll { $0 == name }
        selection.remove(name)
        model.saveDuplicateKeeperSettings()
    }

    private func add(_ name: String) {
        guard !precedence.contains(name) else { return }
        model.duplicateKeeperSettings.volumePrecedence.append(name)
        model.saveDuplicateKeeperSettings()
    }

    /// Volumes worth offering: every scan target (as a /Volumes name, or
    /// the full path for home-folder targets) plus whatever is mounted
    /// right now, minus what's already listed. Sorted for a stable menu.
    private func addableNames() -> [String] {
        var names = Set<String>()
        for target in model.scanTargets {
            names.insert(Self.listName(forPath: target.searchPath))
        }
        let keys: [URLResourceKey] = [.volumeNameKey]
        for url in FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: keys,
                                                          options: [.skipHiddenVolumes]) ?? [] {
            if let name = DuplicateKeeperPolicy.volumeName(forPath: url.path) {
                names.insert(name)
            }
        }
        let listed = Set(precedence)
        return names.subtracting(listed).sorted()
    }

    /// The precedence-list spelling of a scan target path.
    static func listName(forPath path: String) -> String {
        DuplicateKeeperPolicy.volumeName(forPath: path) ?? PathScope.normalize(path)
    }

    private func target(named name: String) -> CatalogScanTarget? {
        model.scanTargets.first { Self.listName(forPath: $0.searchPath) == name }
    }

    /// RAID / HDD / SSD chip from the target's user-entered `mediaTech`
    /// (Volumes editor). Nil when unknown or not a scan target — the
    /// list is Rick's judgment; the chip is only a reminder of why.
    private func tierHint(for name: String) -> String? {
        guard let tech = target(named: name)?.mediaTech else { return nil }
        switch tech {
        case .raid0, .raid1, .raid5, .raid10: return "RAID"
        case .hdd: return "HDD"
        case .ssd: return "SSD"
        case .cloud: return "Cloud"
        case .network: return "Network"
        case .unknown: return nil
        }
    }

    /// "not plugged in" / "retired" hint from the matching scan target.
    private func statusHint(for name: String) -> String? {
        guard let target = target(named: name) else { return nil }
        if target.isRetired { return "retired" }
        if !target.isReachable { return "not plugged in" }
        return nil
    }
}
