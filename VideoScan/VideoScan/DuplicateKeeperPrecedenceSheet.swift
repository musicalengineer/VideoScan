import SwiftUI

// MARK: - DuplicateKeeperPrecedenceSheet (2026-08-18)
//
// "Which copy do we keep?" — the user-ordered volume list behind
// DuplicateKeeperPolicy. Opened from the Volumes window toolbar because
// this is a fact ABOUT volumes (LaCie holds the 2009 originals, the
// Crucials are scratch — Rick 8/17), not a per-file setting.
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
            footer
        }
        .padding(22)
        .frame(minWidth: 520, idealWidth: 560, minHeight: 460)
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
                Text("When the same video lives on more than one drive, the copy on the drive nearest the top is the one we keep. Drives that are unplugged or retired always come after the ones that are here now.")
                    .font(.callout)
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

    /// "not plugged in" / "retired" hint from the matching scan target.
    private func statusHint(for name: String) -> String? {
        let target = model.scanTargets.first { Self.listName(forPath: $0.searchPath) == name }
        guard let target else { return nil }
        if target.isRetired { return "retired" }
        if !target.isReachable { return "not plugged in" }
        return nil
    }
}
