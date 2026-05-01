import SwiftUI

/// Modal sheet for reviewing and executing batch combine of correlated MXF pairs.
private let combineOutputFolderKey = "combineOutputFolder"

struct CombineSheet: View {
    @EnvironmentObject var model: VideoScanModel
    let selectedIDs: Set<UUID>
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) var openWindow

    @State private var outputFolder: URL? = {
        guard let path = UserDefaults.standard.string(forKey: combineOutputFolderKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }()
    @State private var checkedPairs: Set<Int> = []
    @State private var technique: CombineJobStatus.CombineTechnique = .streamCopy
    @State private var substitutions: [UUID: VideoRecord] = [:]
    @State private var subsSearched = false

    var pairs: [(video: VideoRecord, audio: VideoRecord)] {
        let all = model.correlatedPairs
        if selectedIDs.isEmpty { return all }
        let filtered = all.filter { selectedIDs.contains($0.video.id) || selectedIDs.contains($0.audio.id) }
        return filtered.isEmpty ? all : filtered
    }

    private func effectivePair(_ pair: (video: VideoRecord, audio: VideoRecord)) -> (video: VideoRecord, audio: VideoRecord) {
        let v = substitutions[pair.video.id] ?? pair.video
        let a = substitutions[pair.audio.id] ?? pair.audio
        return (v, a)
    }

    private var onlinePairs: [(index: Int, pair: (video: VideoRecord, audio: VideoRecord))] {
        pairs.enumerated().compactMap { i, pair in
            let eff = effectivePair(pair)
            if VolumeReachability.isReachable(path: eff.video.fullPath) &&
               VolumeReachability.isReachable(path: eff.audio.fullPath) {
                return (i, pair)
            }
            return nil
        }
    }

    private var offlineCount: Int { pairs.count - onlinePairs.count }
    private var allChecked: Bool { checkedPairs.count == onlinePairs.count }

    private var estimatedOutputBytes: Int64 {
        checkedPairs.reduce(Int64(0)) { total, i in
            guard i < pairs.count else { return total }
            let eff = effectivePair(pairs[i])
            return total + eff.video.sizeBytes + eff.audio.sizeBytes
        }
    }

    private var freeSpaceBytes: Int64? {
        guard let folder = outputFolder else { return nil }
        let values = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let free = values?.volumeAvailableCapacityForImportantUsage { return free }
        let vals2 = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey])
        return vals2?.volumeAvailableCapacity.map { Int64($0) }
    }

    private var insufficientSpace: Bool {
        guard let free = freeSpaceBytes else { return false }
        return estimatedOutputBytes > free
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Combine Correlated Pairs")
                .font(.headline)

            pairSelectionSection
            techniqueSection
            outputFolderSection
            storageEstimateSection
            buttonBar
        }
        .padding(20)
        .frame(width: 720)
        .onAppear {
            checkedPairs = Set(onlinePairs.map(\.index))
        }
    }

    // MARK: - Pair Selection

    private var pairSelectionSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Correlated Pairs (\(pairs.count))")
                        .font(.subheadline.weight(.semibold))

                    if offlineCount > 0 {
                        HStack(spacing: 5) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.yellow)
                                .font(.system(size: 14))
                            Text("\(offlineCount) MEDIA OFFLINE")
                                .font(.system(size: 13, weight: .bold))
                                .foregroundColor(.yellow)
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(
                            RoundedRectangle(cornerRadius: 5)
                                .fill(Color.yellow.opacity(0.15))
                        )
                    }

                    Spacer()

                    Button("Select All Online") {
                        checkedPairs = Set(onlinePairs.map(\.index))
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    Button("Deselect All") {
                        checkedPairs.removeAll()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)

                    if !checkedPairs.isEmpty {
                        Text("\(checkedPairs.count) selected")
                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                            .foregroundColor(.green)
                    }
                }

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(pairs.enumerated()), id: \.offset) { i, pair in
                            pairRow(index: i, pair: pair)
                        }
                    }
                    .padding(4)
                }
                .frame(maxHeight: 280)

                if offlineCount > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "externaldrive.trianglebadge.exclamationmark")
                            .foregroundColor(.yellow)
                            .font(.system(size: 12))
                        Text("Yellow rows = media offline — mount the volume to enable combine")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.yellow.opacity(0.85))
                        Spacer()
                        if !subsSearched {
                            Button("Find Online Copies") {
                                findSubstitutesForOfflinePairs()
                            }
                            .font(.system(size: 11, weight: .semibold))
                            .buttonStyle(.bordered)
                        }
                    }
                    .padding(.top, 4)

                    if !substitutions.isEmpty {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.triangle.swap")
                                .foregroundColor(.green)
                            Text("\(substitutions.count) online \(substitutions.count == 1 ? "copy" : "copies") found (MD5 verified) — swapped automatically")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.green)
                            Spacer()
                            Button("Reset") {
                                substitutions.removeAll()
                                subsSearched = false
                                checkedPairs = Set(onlinePairs.map(\.index))
                            }
                            .font(.caption)
                            .buttonStyle(.borderless)
                        }
                        .padding(.top, 2)
                    } else if subsSearched {
                        HStack(spacing: 4) {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.secondary)
                            Text("No online copies found for offline media")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                        .padding(.top, 2)
                    }
                }
            }
        }
    }

    private func pairRow(index i: Int, pair: (video: VideoRecord, audio: VideoRecord)) -> some View {
        let eff = effectivePair(pair)
        let vOnline = VolumeReachability.isReachable(path: eff.video.fullPath)
        let aOnline = VolumeReachability.isReachable(path: eff.audio.fullPath)
        let bothOnline = vOnline && aOnline
        let vSwapped = substitutions[pair.video.id] != nil
        let aSwapped = substitutions[pair.audio.id] != nil
        let estSize = eff.video.sizeBytes + eff.audio.sizeBytes

        return HStack(spacing: 4) {
            Toggle("", isOn: Binding(
                get: { checkedPairs.contains(i) },
                set: { on in
                    if on && bothOnline { checkedPairs.insert(i) } else { checkedPairs.remove(i) }
                }
            ))
            .toggleStyle(.checkbox)
            .labelsHidden()
            .disabled(!bothOnline)

            Text("\(i + 1).")
                .foregroundColor(.secondary)
                .frame(width: 28, alignment: .trailing)
                .font(.system(size: 11, design: .monospaced))

            Image(systemName: vSwapped ? "arrow.triangle.swap" : "film")
                .font(.system(size: 9))
                .foregroundColor(vSwapped ? .green : (vOnline ? .blue : .yellow))
            Text(eff.video.filename)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Text("+")
                .font(.system(size: 9))
                .foregroundColor(.secondary)

            Image(systemName: aSwapped ? "arrow.triangle.swap" : "waveform")
                .font(.system(size: 9))
                .foregroundColor(aSwapped ? .green : (aOnline ? .orange : .yellow))
            Text(eff.audio.filename)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()

            Text(Formatting.humanSize(estSize))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 3)
                .fill(!bothOnline ? Color.yellow.opacity(0.15) : Color.clear)
        )
    }

    // MARK: - Technique

    private var techniqueSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                Text("Output Mode")
                    .font(.subheadline.weight(.semibold))
                Picker("", selection: $technique) {
                    Text("Stream Copy (fast, lossless)").tag(CombineJobStatus.CombineTechnique.streamCopy)
                    Text("Re-encode → ProRes (highest quality)").tag(CombineJobStatus.CombineTechnique.reencodeProRes)
                    Text("Re-encode → H.264 (smaller files)").tag(CombineJobStatus.CombineTechnique.reencodeH264)
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)

                switch technique {
                case .streamCopy:
                    Text("Fastest — copies streams without re-encoding. Use when codecs are compatible.")
                        .font(.caption).foregroundColor(.secondary)
                case .reencodeProRes:
                    Text("Re-encodes to ProRes 422 HQ + PCM audio. Best for editing. Larger files.")
                        .font(.caption).foregroundColor(.secondary)
                case .reencodeH264:
                    Text("Re-encodes to H.264 CRF 18 + AAC 256k. Good for sharing. Slower.")
                        .font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Output Folder

    private var outputFolderSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "folder.fill")
                        .foregroundColor(.orange)
                    Text("Output Folder")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Choose…") { chooseOutputFolder() }
                }
                if let folder = outputFolder {
                    Text(folder.path)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else {
                    Text("No folder selected — click Choose to set output destination")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .padding(4)
        }
    }

    // MARK: - Storage Estimate

    private var storageEstimateSection: some View {
        Group {
            if !checkedPairs.isEmpty {
                HStack(spacing: 12) {
                    HStack(spacing: 4) {
                        Image(systemName: "externaldrive")
                            .foregroundColor(.secondary)
                            .font(.system(size: 11))
                        Text("Est. output:")
                            .font(.system(size: 11))
                            .foregroundColor(.secondary)
                        Text(Formatting.humanSize(estimatedOutputBytes))
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    }

                    if let free = freeSpaceBytes {
                        HStack(spacing: 4) {
                            Text("Free:")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                            Text(Formatting.humanSize(free))
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundColor(insufficientSpace ? .red : .green)
                        }
                    }

                    if insufficientSpace {
                        HStack(spacing: 3) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 10))
                            Text("Not enough space!")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundColor(.red)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Button Bar

    private var buttonBar: some View {
        HStack {
            Spacer()

            Button("Cancel") { dismiss() }
                .keyboardShortcut(.escape)

            let label = checkedPairs.count == onlinePairs.count
                ? "Combine All \(checkedPairs.count) Pairs"
                : "Combine \(checkedPairs.count) Pair\(checkedPairs.count == 1 ? "" : "s")"
            Button(label) {
                guard let folder = outputFolder else { return }
                let selectedPairs: [(video: VideoRecord, audio: VideoRecord)] = checkedPairs.sorted().compactMap { i in
                    guard i < pairs.count else { return nil }
                    return effectivePair(pairs[i])
                }
                model.combineSelectedPairs(selectedPairs, outputFolder: folder, technique: technique)
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    openWindow(id: "combine")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(checkedPairs.isEmpty || outputFolder == nil || insufficientSpace)
            .keyboardShortcut(.return)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder for combined files"
        panel.prompt = "Select"
        if let current = outputFolder { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            UserDefaults.standard.set(url.path, forKey: combineOutputFolderKey)
        }
    }

    private func findSubstitutesForOfflinePairs() {
        var newSubs: [UUID: VideoRecord] = [:]
        for pair in pairs {
            if !VolumeReachability.isReachable(path: pair.video.fullPath) {
                if let best = VideoScanModel.findOnlineSubstitutes(for: pair.video, in: model.records).first {
                    newSubs[pair.video.id] = best.substitute
                }
            }
            if !VolumeReachability.isReachable(path: pair.audio.fullPath) {
                if let best = VideoScanModel.findOnlineSubstitutes(for: pair.audio, in: model.records).first {
                    newSubs[pair.audio.id] = best.substitute
                }
            }
        }
        substitutions = newSubs
        subsSearched = true
        checkedPairs = Set(onlinePairs.map(\.index))
    }
}

// MARK: - Combine Single Pair Sheet

/// Streamlined setup dialog for combining one A/V pair.
/// Picks output folder + technique, then launches to Combine & Render window.
struct CombinePairSheet: View {
    @EnvironmentObject var model: VideoScanModel
    let originalVideo: VideoRecord
    let originalAudio: VideoRecord
    @Environment(\.dismiss) var dismiss
    @Environment(\.openWindow) var openWindow

    @State private var activeVideo: VideoRecord?
    @State private var activeAudio: VideoRecord?
    @State private var videoSubs: [VideoScanModel.OnlineSubstitute] = []
    @State private var audioSubs: [VideoScanModel.OnlineSubstitute] = []

    @State private var outputFolder: URL? = {
        guard let path = UserDefaults.standard.string(forKey: combineOutputFolderKey),
              FileManager.default.fileExists(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }()
    @State private var technique: CombineJobStatus.CombineTechnique = .streamCopy

    private var video: VideoRecord { activeVideo ?? originalVideo }
    private var audio: VideoRecord { activeAudio ?? originalAudio }

    private var outputFilename: String {
        let stem = (video.filename as NSString).deletingPathExtension
        return "\(stem)_combined.mov"
    }

    private var estimatedBytes: Int64 { video.sizeBytes + audio.sizeBytes }

    private var videoOnline: Bool { VolumeReachability.isReachable(path: video.fullPath) }
    private var audioOnline: Bool { VolumeReachability.isReachable(path: audio.fullPath) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Combine Pair")
                .font(.headline)

            GroupBox("Source Files") {
                VStack(alignment: .leading, spacing: 6) {
                    fileRow(icon: "film", label: "Video", color: .blue,
                            filename: video.filename, path: video.fullPath,
                            size: video.sizeBytes, online: videoOnline)
                    fileRow(icon: "waveform", label: "Audio", color: .orange,
                            filename: audio.filename, path: audio.fullPath,
                            size: audio.sizeBytes, online: audioOnline)
                }
                .padding(4)
            }

            if !videoOnline || !audioOnline {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.yellow)
                        Text("Media offline — volume not mounted")
                            .font(.caption)
                            .foregroundColor(.yellow)
                    }

                    if !videoOnline && !videoSubs.isEmpty {
                        substituteSection(label: "Video", subs: videoSubs) { sub in
                            activeVideo = sub.substitute
                        }
                    }
                    if !audioOnline && !audioSubs.isEmpty {
                        substituteSection(label: "Audio", subs: audioSubs) { sub in
                            activeAudio = sub.substitute
                        }
                    }
                }
            }

            if activeVideo != nil || activeAudio != nil {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.swap")
                        .foregroundColor(.green)
                    Text("Using online copy — content-identical (MD5 verified)")
                        .font(.caption)
                        .foregroundColor(.green)
                    Spacer()
                    Button("Reset to Original") {
                        activeVideo = nil
                        activeAudio = nil
                    }
                    .font(.caption)
                    .buttonStyle(.borderless)
                }
            }

            // Technique picker
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Output Mode")
                        .font(.subheadline.weight(.semibold))
                    Picker("", selection: $technique) {
                        Text("Stream Copy (fast, lossless)").tag(CombineJobStatus.CombineTechnique.streamCopy)
                        Text("Re-encode → ProRes (highest quality)").tag(CombineJobStatus.CombineTechnique.reencodeProRes)
                        Text("Re-encode → H.264 (smaller files)").tag(CombineJobStatus.CombineTechnique.reencodeH264)
                    }
                    .labelsHidden()
                    .pickerStyle(.radioGroup)
                }
                .padding(4)
            }

            // Output folder
            GroupBox {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundColor(.orange)
                        Text("Output Folder")
                            .font(.subheadline.weight(.semibold))
                        Spacer()
                        Button("Choose…") { chooseOutputFolder() }
                    }
                    if let folder = outputFolder {
                        Text(folder.path)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("No folder selected")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    HStack(spacing: 8) {
                        Text("→ \(outputFilename)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                        Spacer()
                        Text("Est. \(Formatting.humanSize(estimatedBytes))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.escape)
                Button("Combine") {
                    guard let folder = outputFolder else { return }
                    model.combineSelectedPairs([(video: video, audio: audio)], outputFolder: folder, technique: technique)
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        openWindow(id: "combine")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(outputFolder == nil || !videoOnline || !audioOnline)
                .keyboardShortcut(.return)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if !VolumeReachability.isReachable(path: originalVideo.fullPath) {
                videoSubs = VideoScanModel.findOnlineSubstitutes(for: originalVideo, in: model.records)
            }
            if !VolumeReachability.isReachable(path: originalAudio.fullPath) {
                audioSubs = VideoScanModel.findOnlineSubstitutes(for: originalAudio, in: model.records)
            }
        }
    }

    private func substituteSection(
        label: String,
        subs: [VideoScanModel.OnlineSubstitute],
        onSelect: @escaping (VideoScanModel.OnlineSubstitute) -> Void
    ) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 4) {
                    Image(systemName: "doc.on.doc")
                        .foregroundColor(.green)
                        .font(.system(size: 11))
                    Text("\(subs.count) online \(label.lowercased()) copy\(subs.count == 1 ? "" : " copies") found")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.green)
                }
                ForEach(subs, id: \.substitute.id) { sub in
                    HStack(spacing: 6) {
                        Button("Use This") { onSelect(sub) }
                            .font(.system(size: 11))
                            .buttonStyle(.bordered)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(sub.substitute.filename)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Text("on \(sub.volumeName)  •  \(Formatting.humanSize(sub.substitute.sizeBytes))  •  MD5 match")
                                .font(.system(size: 10))
                                .foregroundColor(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 2)
                }
            }
            .padding(4)
        }
    }

    private func fileRow(icon: String, label: String, color: Color,
                         filename: String, path: String, size: Int64, online: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .foregroundColor(online ? color : .yellow)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 40, alignment: .trailing)
                Text(filename)
                    .font(.system(size: 12, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(Formatting.humanSize(size))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            Text(path)
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.head)
                .padding(.leading, 62)
        }
    }

    private func chooseOutputFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose output folder for combined file"
        panel.prompt = "Select"
        if let current = outputFolder { panel.directoryURL = current }
        if panel.runModal() == .OK, let url = panel.url {
            outputFolder = url
            UserDefaults.standard.set(url.path, forKey: combineOutputFolderKey)
        }
    }
}
