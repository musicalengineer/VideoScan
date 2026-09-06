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
    /// "Let Hallie phrase answers in her own words (facts stay locked)".
    /// Persisted explicitly on toggle, like every other setting here.
    @State private var composeWithModel = true
    /// The model tag Hallie asks with. Stored under the same key the chat
    /// window and the web bridge read, so this pane and every asking path
    /// agree by construction rather than by convention.
    @State private var model = HallieBrain.defaultModel
    /// Tags installed on the first REACHABLE host — the machine that will
    /// actually answer. Empty when nothing answered, which switches the
    /// control to a free-text field.
    @State private var installed: [String] = []
    @State private var loadingModels = false
    /// Which host the menu is describing, named in the caption so the
    /// reader knows whose model list they are looking at.
    @State private var modelSourceHost: String?
    /// Restart-the-brain state (Rick, 2026-09-06).
    @State private var restarting = false
    @State private var restartReport: String?
    @State private var restartReportIsGood = false
    /// Is the CONFIGURED model loaded on each host (2026-09-06)? A separate
    /// question from host liveness, and Rick hit the gap: RicksM4.local
    /// showed a green "online" light while the restart report said no
    /// answer — both true, because the host was up and the model was not
    /// loaded. Keyed by host.
    @State private var readiness: [String: ModelReadiness] = [:]
    /// Resident size of the configured model on the host that answered,
    /// in bytes, and the machine's own RAM.
    @State private var residentBytes: Int64?
    @State private var installedBytes: Int64?
    /// Short digests of the configured tag per host — shown ONLY when two
    /// hosts disagree, which is the case worth interrupting anyone about.
    @State private var digestsByHost: [String: String] = [:]

    /// Whether the configured model is ready to answer ON THIS HOST.
    ///
    /// Deliberately NOT folded into `Liveness`. Rick ruled that an offline
    /// host is yellow rather than red — a sleeping laptop is normal, not an
    /// error — and that ruling is about the MACHINE. This is about the
    /// model, where red really does mean "asking here will fail", so it
    /// gets its own light rather than overloading his.
    enum ModelReadiness: Equatable {
        /// Loaded and warm: the next question is fast.
        case resident
        /// The host answers, but this model is not in memory. The next
        /// question pays a cold load — about six seconds for a 27B on the
        /// M4, measured 2026-09-06.
        case cold
        /// The host answers and does not have this model AT ALL. Asking
        /// here fails, or silently pulls, depending on the server.
        case missing
        /// No answer, or not asked yet.
        case unknown

        var color: Color {
            switch self {
            case .resident: return .green
            case .cold:     return .yellow
            case .missing:  return .red
            case .unknown:  return .secondary
            }
        }
        var label: String {
            switch self {
            case .resident: return "loaded"
            case .cold:     return "cold"
            case .missing:  return "absent"
            case .unknown:  return ""
            }
        }
        var detail: String {
            switch self {
            case .resident: return "The model is in memory here — answers are fast."
            case .cold:     return "This server has the model but hasn't loaded it. "
                                 + "The next question waits for it (about six seconds for a 27B)."
            case .missing:  return "This server doesn't have this model installed."
            case .unknown:  return "Not asked yet."
            }
        }
    }

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

                    // Second light: the MODEL, not the machine. Rick,
                    // 2026-09-06 — a green host light beside "no answer
                    // from RicksM4.local" was not a contradiction, it was
                    // two facts sharing one indicator.
                    let ready = readiness[host] ?? .unknown
                    if ready != .unknown {
                        Circle()
                            .fill(ready.color)
                            .frame(width: 8, height: 8)
                            .help(ready.detail)
                        Text(ready.label)
                            .font(.system(size: 10))
                            .foregroundColor(.secondary)
                            .frame(width: 42, alignment: .leading)
                            .help(ready.detail)
                            .accessibilityIdentifier("archivist.modelReadiness.\(host)")
                    }

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

            Divider()
                .padding(.vertical, 2)

            // MARK: Which model
            //
            // Rick, 2026-09-01: "we already have settings for Archivist
            // Brain so let's put the selector in there". Until now the tag
            // lived in five source files and a `defaults write` — which is
            // not a setting so much as a rumour, the same complaint that
            // produced the host list above.
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text("Model")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 54, alignment: .leading)

                    if installed.isEmpty {
                        // No answer from any host: never show an empty menu
                        // you cannot escape. Type the tag.
                        TextField("qwen3.8:27b-mlx", text: $model)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(persistModel)
                    } else {
                        Picker("", selection: $model) {
                            // A tag configured but not installed still shows,
                            // so the pane never silently reassigns the brain.
                            if !installed.contains(model) {
                                Text("\(model)  (not installed)").tag(model)
                            }
                            ForEach(installed, id: \.self) { tag in
                                Text(tag).tag(tag)
                            }
                        }
                        .labelsHidden()
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: model) { _, _ in
                            persistModel()
                            Task { await refreshModelFacts() }
                        }
                        .accessibilityIdentifier("archivist.ollamaModel")
                    }

                    Button(loadingModels ? "…" : "Refresh") {
                        Task { await refreshModels(); await refreshModelFacts() }
                    }
                    .controlSize(.small)
                    .disabled(loadingModels || hosts.isEmpty)
                    .help("Re-read the installed models from the first server that answers")

                    Button(restarting ? "…" : "Restart") {
                        Task { await restartBrain() }
                    }
                    .controlSize(.small)
                    .disabled(restarting || hosts.isEmpty)
                    .help("Unload and reload the model, and forget anything this "
                          + "run has decided the server can't do")
                    .accessibilityIdentifier("archivist.restartBrain")
                }
                Text(installed.isEmpty
                     ? "No server answered, so type the tag exactly as `ollama list` shows it."
                     : "Installed on \(modelSourceHost ?? "the first server that answered"). "
                       + "A bigger model reasons further; a smaller one replies sooner.")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let memoryLine {
                    Text(memoryLine)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("archivist.modelMemory")
                }
                if let digestWarning {
                    Text(digestWarning)
                        .font(.caption)
                        .foregroundColor(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("archivist.modelDigestWarning")
                }
                if let restartReport {
                    Text(restartReport)
                        .font(.caption)
                        .foregroundColor(restartReportIsGood ? .green : .orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("archivist.restartBrain.report")
                }
            }

            Divider()
                .padding(.vertical, 2)

            Toggle(isOn: $composeWithModel) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Let Hallie phrase answers in her own words (facts stay locked)")
                        .font(.system(size: 12))
                    Text("One extra local-model call rewrites only the approved facts; "
                         + "anything it adds is dropped before you see it. Off = "
                         + "the plain templated wording.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.checkbox)
            .accessibilityIdentifier("archivist.composeWithModel")
            .onChange(of: composeWithModel) { _, enabled in
                HallieCompositionSettings.setEnabled(enabled, defaultsStore)
            }

            HStack(spacing: 10) {
                Button("Restore Defaults") {
                    hosts = OllamaEndpoints.defaultHosts
                    persist()
                    Task { await refreshLiveness(); await refreshModelFacts() }
                }
                .controlSize(.small)

                Button(checking ? "Checking…" : "Check Servers") {
                    Task { await refreshLiveness(); await refreshModelFacts() }
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
                composeWithModel = HallieCompositionSettings.isEnabled(defaultsStore)
                model = defaultsStore.string(forKey: Self.modelKey) ?? HallieBrain.defaultModel
                loaded = true
            }
            Task { await refreshModels() }
            // Lights refresh every time the pane appears — a stale green
            // is worse than no light at all.
            Task { await refreshLiveness(); await refreshModelFacts() }
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

    /// The one key every asking path reads (ArchivistChatWindow,
    /// ArchivistAskField, HallieWebAccess).
    static let modelKey = "archivist.ollamaModel"

    /// Explicit save, like every other setting here — @State carries no
    /// didSet, so nothing writes itself.
    private func persistModel() {
        let tag = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { return }
        model = tag
        defaultsStore.set(tag, forKey: Self.modelKey)
    }

    /// Ask the first host that answers what it has installed. First
    /// REACHABLE, not merely first: the menu must describe the machine that
    /// will actually take the question, or it is offering models to a
    /// server that is asleep.
    @MainActor
    private func refreshModels() async {
        guard !loadingModels, !hosts.isEmpty else { return }
        loadingModels = true
        defer { loadingModels = false }
        for host in hosts {
            var probe = OllamaQueryTranslator()
            probe.host = host
            let tags = await probe.installedModels()
            if !tags.isEmpty {
                installed = tags
                modelSourceHost = host
                // WHICH server's shelf this menu is. Rick had a picker full
                // of models that were not on the server answering his
                // questions, and no way to tell from the log.
                appLog.write("[hallie-brain] model menu read from \(host) — "
                             + "\(tags.count) installed: \(tags.joined(separator: ", "))")
                return
            }
        }
        installed = []
        modelSourceHost = nil
    }

    // MARK: What the model costs, and whether it is the model you think

    /// Total physical RAM, so the figure below is a fraction of something
    /// rather than a number floating in space.
    private static let machineRAMBytes: Int64 = Int64(ProcessInfo.processInfo.physicalMemory)

    static func roundedGB(_ bytes: Int64) -> Int {
        // Round UP. This number answers "will it fit", and a figure that
        // rounds 22.7 down to 22 answers it wrong in the one direction that
        // matters.
        let gb = Double(bytes) / 1_073_741_824
        return max(1, Int(gb.rounded(.up)))
    }

    /// "≈23 GB in memory of 64 GB" — the honest figure.
    ///
    /// RESIDENT size, not the on-disk size `ollama list` prints. For
    /// qwen3.8:27b-mlx those are 22.7 GB and 18.2 GB; the difference is the
    /// KV cache at our 32K context. Showing the smaller number would
    /// understate what the machine actually gives up, which is the whole
    /// question anyone reads this line to answer. Falls back to the on-disk
    /// size, clearly labelled, when nothing has loaded it yet.
    private var memoryLine: String? {
        let total = Self.roundedGB(Self.machineRAMBytes)
        if let residentBytes, residentBytes > 0 {
            return "≈\(Self.roundedGB(residentBytes)) GB in memory, of \(total) GB on this Mac."
        }
        if let installedBytes, installedBytes > 0 {
            return "≈\(Self.roundedGB(installedBytes)) GB on disk, of \(total) GB on this Mac "
                 + "— it needs somewhat more than that once loaded."
        }
        return nil
    }

    /// Silent when every host agrees, loud when they do not.
    ///
    /// A tag is a NAME and names are not identity: two servers can serve
    /// "qwen3.8:27b-mlx" over different bytes. The digest is the content,
    /// which is why this shows a digest rather than a file path — ollama
    /// stores blobs content-addressed, so a path would look authoritative
    /// without being it.
    private var digestWarning: String? {
        let distinct = Set(digestsByHost.values.filter { !$0.isEmpty })
        guard distinct.count > 1 else { return nil }
        let detail = digestsByHost
            .filter { !$0.value.isEmpty }
            .sorted { $0.key < $1.key }
            .map { "\($0.key) \($0.value.prefix(12))" }
            .joined(separator: ", ")
        return "Two servers have different builds of “\(model)”: \(detail). "
             + "Same name, different bytes — answers may differ depending on which one replies."
    }

    /// Ask every host what it holds. One pass fills the readiness lights,
    /// the memory line and the digest comparison, because all three come
    /// from the same two cheap GETs.
    @MainActor
    private func refreshModelFacts() async {
        guard !hosts.isEmpty else {
            readiness = [:]; digestsByHost = [:]
            residentBytes = nil; installedBytes = nil
            return
        }
        let tag = model
        var nextReadiness: [String: ModelReadiness] = [:]
        var nextDigests: [String: String] = [:]
        var firstResident: Int64?
        var firstInstalled: Int64?

        for host in hosts {
            var probe = OllamaQueryTranslator()
            probe.host = host
            let installed = await probe.installedModelFacts()
            guard !installed.isEmpty else {
                nextReadiness[host] = .unknown   // no answer: the host light already says so
                continue
            }
            if let match = installed.first(where: { $0.name == tag }) {
                nextDigests[host] = match.digest
                if firstInstalled == nil, match.bytes > 0 { firstInstalled = match.bytes }
                let resident = await probe.residentModelFacts()
                if let live = resident.first(where: { $0.name == tag }) {
                    nextReadiness[host] = .resident
                    if firstResident == nil, live.bytes > 0 { firstResident = live.bytes }
                } else {
                    nextReadiness[host] = .cold
                }
            } else {
                nextReadiness[host] = .missing
            }
        }
        readiness = nextReadiness
        digestsByHost = nextDigests
        residentBytes = firstResident
        installedBytes = firstInstalled

        // Put in the log exactly what the pane is showing (Rick,
        // 2026-09-06: "how is the logging around which model is loaded and
        // running, so you can see what I see in the log?").
        //
        // The line that prompted it was a picker listing granite4.2:30b and
        // qwen-videoscan:64k while the warm-up line two inches away said
        // qwen3.8:27b-mlx @ 127.0.0.1 — two Ollama servers on one Mac, the
        // picker reading one and Hallie asking the other. Nothing in the
        // log said WHICH server the menu came from, so there was no way to
        // see that from the outside. Now there is: one line per host, host
        // first, naming the configured tag and what that host has to say
        // about it.
        for host in hosts {
            let state = nextReadiness[host] ?? .unknown
            var line = "[hallie-brain] \(host): model “\(tag)” \(state.label.isEmpty ? "no answer" : state.label)"
            if let digest = nextDigests[host], !digest.isEmpty {
                line += " (\(digest.prefix(19)))"
            }
            appLog.write(line)
        }
        if let residentBytes, residentBytes > 0 {
            appLog.write("[hallie-brain] “\(tag)” resident size "
                         + "\(Self.roundedGB(residentBytes)) GB of "
                         + "\(Self.roundedGB(Self.machineRAMBytes)) GB")
        }
        if let warning = digestWarning { appLog.write("[hallie-brain] \(warning)") }
    }

    /// Restart the brain (Rick, 2026-09-06).
    ///
    /// The motivating failure is worth stating, because "restart the model"
    /// is not what actually goes wrong most often. On 2026-09-06 the ollama
    /// SERVER on this machine was 0.33.2 while the client binary was 0.33.3,
    /// and the old server answered every schema-bearing request with HTTP
    /// 501 "structured output is unavailable". Hallie handled that
    /// correctly — she dropped the schema and kept going — but
    /// `OllamaStructuredOutputCapability` memoizes the refusal PER PROCESS,
    /// deliberately, so one bad host cannot cost a doomed round trip on
    /// every turn. The consequence is the thing this button exists for:
    /// restarting ollama did not help, because VideoScan had already
    /// decided, for the rest of its run, not to ask again. The only cure
    /// was relaunching the app.
    ///
    /// So the order here is: FORGET first, then reload the model, then
    /// re-probe and say plainly whether the server can constrain output
    /// now. Forgetting without re-probing would just move the discovery to
    /// Rick's next question; re-probing without forgetting would report a
    /// capability the translator has already stopped using.
    ///
    /// What it does NOT do is restart the ollama server process. That is a
    /// bigger hammer than an app should swing at something it does not
    /// own, and the report below names the version mismatch when it sees
    /// one so the person reading it knows to go do that themselves.
    @MainActor
    private func restartBrain() async {
        guard !restarting, !hosts.isEmpty else { return }
        restarting = true
        restartReport = nil
        defer { restarting = false }

        let tag = model
        var reloaded: [String] = []
        var constrained: [String] = []
        var refused: [String] = []
        var unverified: [String] = []
        var silent: [String] = []

        for host in hosts {
            let endpoint = OllamaEndpoints.chatURLString(for: host, defaultPort: 11434)
            // 1. Forget, so the very next turn is willing to send a schema.
            await OllamaStructuredOutputCapability.shared.forget(endpoint)

            // 2. Unload and reload. `keep_alive: 0` evicts the weights; the
            //    warm-up that follows pulls them back in, which is what
            //    clears a model that has wedged rather than a server that
            //    has.
            var probe = OllamaQueryTranslator()
            probe.host = host
            probe.model = tag
            await probe.unloadModel()
            do {
                try await probe.warmUp()
                reloaded.append(host)
            } catch {
                silent.append(host)
                continue
            }

            // 3. Ask the question the button is really about.
            switch await probe.structuredOutputProbe() {
            case .available:   constrained.append(host)
            case .unverified:  unverified.append(host)
            case .refused:     refused.append(host)
            case .unreachable: silent.append(host)
            }
        }

        restartReportIsGood = !constrained.isEmpty
            && refused.isEmpty && silent.isEmpty && unverified.isEmpty
        var lines: [String] = []
        if !reloaded.isEmpty {
            lines.append("Reloaded \(tag) on \(reloaded.joined(separator: ", ")).")
        }
        if !constrained.isEmpty {
            lines.append("Structured output is working again — Hallie will ask with a schema.")
        }
        if !unverified.isEmpty {
            lines.append("\(unverified.joined(separator: ", ")) accepted the schema but "
                         + "didn't obey it, so I can't say enforcement is working. "
                         + "Hallie will still ask with a schema.")
        }
        if !refused.isEmpty {
            lines.append("\(refused.joined(separator: ", ")) still refuses structured output. "
                         + "That is the ollama SERVER build, not the model: restart the ollama "
                         + "server itself (a client upgrade doesn't restart it), then press "
                         + "Restart again.")
        }
        if !silent.isEmpty {
            lines.append("No answer from \(silent.joined(separator: ", ")).")
        }
        restartReport = lines.isEmpty ? "Nothing to restart." : lines.joined(separator: " ")
        await refreshModelFacts()
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
