// ArchivistEndpointSettings.swift
// Where the Family Archivist's brain lives — an editable, ordered list.
//
// Rick, 2026-08-12: "I like the settings so I can select the ollama
// server which can be either local or in the cloud." Until now the fleet
// order was reachable only through `defaults write`, which is not a
// setting so much as a rumour.
//
// LOCAL AND CLOUD IN ONE LIST. A row is any of:
//     RicksM4.local                 → http://RicksM4.local:11434
//     RicksM4.local:1234            → that port instead
//     https://ollama.example.com    → left exactly as written
// `OllamaEndpoints.chatURLString` owns those rules; this view only
// collects strings and keeps them in order.
//
// ORDER IS THE FEATURE, not decoration: the list is tried top-down, so
// "which machine is primary" is expressed by dragging a row, and the
// first row is the answer to "where does my Archivist think?".

import SwiftUI

struct ArchivistEndpointSettings: View {

    /// Injected so tests and previews never touch the real plist.
    var defaultsStore: UserDefaults = .standard

    @State private var hosts: [String] = []
    @State private var newHost: String = ""
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Archivist Brain")
                .font(.headline)
            Text("Tried in order, top first. Use a name for a machine on "
                 + "your network, or a full https:// address for a cloud server.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if hosts.isEmpty {
                Text("No servers configured — using the built-in defaults.")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            ForEach(Array(hosts.enumerated()), id: \.offset) { index, host in
                HStack(spacing: 8) {
                    // The primary earns a word, not just position: "first
                    // row wins" is obvious once you know it and invisible
                    // until then.
                    Text(index == 0 ? "PRIMARY" : "\(index + 1)")
                        .font(.system(size: 9, weight: .heavy))
                        .foregroundColor(index == 0 ? .accentColor : .secondary)
                        .frame(width: 54, alignment: .leading)

                    Text(host)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(OllamaEndpoints.chatURLString(for: host, defaultPort: 11434))

                    Spacer()

                    Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                        .buttonStyle(.borderless)
                        .disabled(index == 0)
                        .help("Try this server earlier")
                    Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                        .buttonStyle(.borderless)
                        .disabled(index == hosts.count - 1)
                        .help("Try this server later")
                    Button { remove(index) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless)
                        .help("Remove this server")
                }
            }

            HStack(spacing: 8) {
                TextField("RicksM4.local  or  https://ollama.example.com", text: $newHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(OllamaEndpoints.normalize(newHost) == nil)
            }

            HStack {
                Button("Restore Defaults") {
                    hosts = OllamaEndpoints.defaultHosts
                    persist()
                }
                .controlSize(.small)
                Spacer()
            }
        }
        .onAppear {
            // Load once. Re-reading on every appearance would discard an
            // in-progress edit if the pane redrew.
            guard !loaded else { return }
            hosts = OllamaEndpoints.resolved(from: defaultsStore)
            loaded = true
        }
    }

    // MARK: Mutations — each persists immediately.
    //
    // Explicit save on every change, matching the project's settings
    // pattern: @Published/@State carry no didSet, so nothing writes
    // itself. A list that looked edited but silently reverted on relaunch
    // would be worse than no editor at all.

    private func add() {
        guard let h = OllamaEndpoints.normalize(newHost) else { return }
        guard !hosts.contains(where: { $0.lowercased() == h.lowercased() }) else {
            newHost = ""
            return
        }
        hosts.append(h)
        newHost = ""
        persist()
    }

    private func remove(_ index: Int) {
        guard hosts.indices.contains(index) else { return }
        hosts.remove(at: index)
        persist()
    }

    private func move(_ index: Int, by delta: Int) {
        let target = index + delta
        guard hosts.indices.contains(index), hosts.indices.contains(target) else { return }
        hosts.swapAt(index, target)
        persist()
    }

    private func persist() {
        OllamaEndpoints.save(hosts, to: defaultsStore)
    }
}
