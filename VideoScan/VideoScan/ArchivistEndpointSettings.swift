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
    /// Liveness per host, keyed by host string. Same probe the failover
    /// walker uses, so the light cannot disagree with routing: if it is
    /// green here, that host is the one that will answer.
    @State private var status: [String: Liveness] = [:]
    @State private var checking = false

    enum Liveness: Equatable {
        case unknown, online, idle(String), offline(String)

        var color: Color {
            switch self {
            case .online:  return .green
            case .idle:    return .secondary
            case .offline: return .yellow   // Rick: yellow, not red — a
                                            // sleeping laptop is normal,
                                            // not an error state.
            case .unknown: return .secondary
            }
        }
        var label: String {
            switch self {
            case .online:  return "online"
            case .idle:    return "idle"
            case .offline: return "offline"
            case .unknown: return "—"
            }
        }
        var detail: String {
            if case .idle(let why) = self { return why }
            if case .offline(let why) = self { return why }
            return ""
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Archivist Brain")
                .font(.headline)
            Text("Tried in order, top first. Use a name for a machine on "
                 + "your network, or a full https:// address for a cloud server.")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("A local Ollama server starts automatically when you send Hallie her first question.")
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

                    // Liveness light. Answers "is my Archivist's brain
                    // awake?" without asking it a question and waiting.
                    let state = status[host] ?? .unknown
                    Circle()
                        .fill(state.color)
                        .frame(width: 8, height: 8)
                    Text(state.label)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .frame(width: 46, alignment: .leading)
                        .help(state.detail.isEmpty ? state.label : state.detail)

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

            HStack(spacing: 10) {
                Button("Restore Defaults") {
                    hosts = OllamaEndpoints.defaultHosts
                    persist()
                    Task { await refreshLiveness() }
                }
                .controlSize(.small)

                Button(checking ? "Checking…" : "Check Servers") {
                    Task { await refreshLiveness() }
                }
                .controlSize(.small)
                .disabled(checking || hosts.isEmpty)

                Spacer()
            }
        }
        .onAppear {
            // Load once. Re-reading on every appearance would discard an
            // in-progress edit if the pane redrew.
            if !loaded {
                hosts = OllamaEndpoints.resolved(from: defaultsStore)
                loaded = true
            }
            // Lights refresh every time the pane appears — a stale green
            // is worse than no light at all.
            Task { await refreshLiveness() }
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

    /// Probe every host concurrently. Uses the SAME `probeLiveness` the
    /// failover walker uses, so a green light is a promise about routing
    /// rather than a second, separately-drifting opinion.
    ///
    /// Concurrent, not sequential: with three hosts and a 3s timeout,
    /// checking them one at a time would leave the pane sitting on
    /// "Checking…" for nine seconds.
    @MainActor
    private func refreshLiveness() async {
        guard !checking, !hosts.isEmpty else { return }
        checking = true
        defer { checking = false }

        let snapshot = hosts
        let results = await withTaskGroup(of: (String, Liveness).self) { group in
            for host in snapshot {
                group.addTask {
                    var probe = OllamaQueryTranslator()
                    probe.host = host
                    if let down = await probe.probeLiveness() {
                        if OllamaLocalServerBootstrap.isLocalEndpoint(host) {
                            return (host, .idle(
                                "Starts automatically when you ask Hallie"))
                        }
                        return (host, .offline(down.errorDescription ?? "offline"))
                    }
                    return (host, .online)
                }
            }
            var out: [String: Liveness] = [:]
            for await (host, state) in group { out[host] = state }
            return out
        }
        status = results
    }
}
