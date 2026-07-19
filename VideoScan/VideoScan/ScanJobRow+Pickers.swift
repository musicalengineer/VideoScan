// ScanJobRow+Pickers.swift
// The collapsed-row inline pickers (person / volume / engine) and the
// per-row engine settings popover — extracted verbatim from ScanJobRow's
// body in ScanJobRow.swift (refactor 2026-06-25). Also home to the
// LabeledControl helper view (used only by the settings popover) and the
// Float->Double Binding helper (used only by the engine settings sliders).
// A cross-file `extension` can't see `private` members; the ScanJobRow
// members this code shares (browsePath) were already internal.
// (Swift extension ≈ C++ partial class via free member functions: no new
// stored state allowed, methods share the same `self`; `private` here means
// file-private to THIS file.)

import SwiftUI

extension ScanJobRow {

    // MARK: - Inline pickers (collapsed row, idle state)

    var inlinePersonPicker: some View {
        Menu {
            ForEach(savedProfiles) { profile in
                Button {
                    job.assignedProfile = profile
                    if job.assignedEngine == nil,
                       let eng = RecognitionEngine(rawValue: profile.engine) {
                        job.assignedEngine = eng
                    }
                } label: {
                    Label(profile.name, systemImage: job.assignedProfile?.id == profile.id ? "checkmark.circle.fill" : "person.circle")
                }
            }
            if savedProfiles.isEmpty {
                Text("No people added yet")
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "person.fill")
                    .foregroundColor(job.assignedProfile != nil ? .accentColor : .secondary)
                Text(job.assignedProfile?.name ?? "Person…")
                    .fontWeight(job.assignedProfile != nil ? .medium : .regular)
                    .foregroundColor(job.assignedProfile != nil ? .primary : .secondary)
            }
            .font(.body)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    var inlineVolumePicker: some View {
        Menu {
            let vols = PersonFinderView.mountedVolumes
            if !vols.isEmpty {
                Section("Mounted Volumes") {
                    ForEach(vols, id: \.path) { vol in
                        Button(vol.lastPathComponent) {
                            job.searchPath = vol.path
                            PersonFinderView.recordRecentPath(vol.path)
                        }
                    }
                }
            }
            let recents = PersonFinderView.recentPaths
            if !recents.isEmpty {
                Section("Recent") {
                    ForEach(recents, id: \.self) { path in
                        Button((path as NSString).lastPathComponent) {
                            job.searchPath = path
                        }
                    }
                }
            }
            Divider()
            Button("Browse…") {
                browsePath()
                if !job.searchPath.isEmpty {
                    PersonFinderView.recordRecentPath(job.searchPath)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder.fill")
                    .foregroundColor(!job.searchPath.isEmpty ? .accentColor : .secondary)
                Text(!job.searchPath.isEmpty ? (job.searchPath as NSString).lastPathComponent : "Volume…")
                    .fontWeight(!job.searchPath.isEmpty ? .medium : .regular)
                    .foregroundColor(!job.searchPath.isEmpty ? .primary : .secondary)
                    .lineLimit(1)
            }
            .font(.body)
        }
        .menuStyle(.borderedButton)
        .fixedSize()
    }

    var inlineEnginePicker: some View {
        HStack(spacing: 4) {
            Picker("", selection: Binding(
                get: { job.effectiveEngine },
                set: { job.assignedEngine = $0 }
            )) {
                ForEach(RecognitionEngine.allCases) { eng in
                    Text(eng.rawValue).tag(eng)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()

            Button {
                showSettingsPopover.toggle()
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.body)
            }
            .buttonStyle(.bordered)
            .controlSize(.regular)
            .popover(isPresented: $showSettingsPopover, arrowEdge: .bottom) {
                engineSettingsPopover
            }
        }
    }

    // MARK: - Per-row engine settings popover

    var engineSettingsPopover: some View {
        let engine = job.effectiveEngine
        return VStack(alignment: .leading, spacing: 12) {
            Text("Settings — \(engine.rawValue)")
                .font(.headline)

            // Engine Options (experimental) — ArcFace only. Lives at the top of
            // the per-search settings so it sits with the engine it applies to.
            if engine == .arcface {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Engine Options")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Toggle("5-landmark alignment (norm_crop)",
                           isOn: model.settingsBinding.arcfaceLandmarkAlignment)
                        .help("Warps each face to ArcFace's canonical 112×112 before embedding (how the model was trained). May improve match accuracy across decades. Experimental — start a new search to see the effect.")
                }
                Divider()
            }

            // Common settings
            Group {
                LabeledControl("Match Threshold") {
                    Slider(value: model.settingsBinding.threshold, in: 0.3...0.9, step: 0.05)
                        .frame(width: 140)
                    Text(String(format: "%.2f", model.settings.threshold))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 38)
                }
                LabeledControl("Min Face Confidence") {
                    Slider(value: model.settingsBinding.minFaceConfidence.asDouble, in: 0.3...1.0, step: 0.05)
                        .frame(width: 140)
                    Text(String(format: "%.2f", model.settings.minFaceConfidence))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 38)
                }
                LabeledControl("Frame Step") {
                    TextField("", value: model.settingsBinding.frameStep, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 54)
                    Text("frames")
                }
                LabeledControl("Min Presence") {
                    TextField("", value: model.settingsBinding.minPresenceSecs, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 64)
                    Text("sec")
                }
                // Match Confidence Floor — the graded POI cycle-03 rule
                // (minimum matched moments across a whole video before we say
                // the person is in it). Default 7; 1 restores the old
                // any-single-match behavior. Persists via settingsBinding's
                // explicit save() (the @Observable-kills-didSet pattern).
                LabeledControl("Match Confidence Floor") {
                    TextField("", value: model.settingsBinding.matchConfidenceFloor, format: .number)
                        .textFieldStyle(.roundedBorder).frame(width: 54)
                    Stepper("", value: model.settingsBinding.matchConfidenceFloor, in: 1...99)
                        .labelsHidden()
                    Text("matches")
                }
                .help("How many matching moments a video needs before it counts as a find. Filters out one-frame look-alikes. Set to 1 to count any single match (the old behavior). Very short clips always count with any match.")
            }

            Divider()

            Toggle("Primary face only", isOn: model.settingsBinding.requirePrimary)
            Toggle("Skip background faces", isOn: model.settingsBinding.largestFaceOnly)
            Toggle("Skip media app bundles", isOn: model.settingsBinding.skipBundles)
                .help("When on, skips FCP, iMovie, Photos libraries and project bundles. Turn off to search every possible media file.")

            Divider()

            // Engine-specific settings
            if engine == .dlib || engine == .hybrid {
                LabeledControl("Python Path") {
                    TextField("", text: model.settingsBinding.pythonPath)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                LabeledControl("Recognition Script") {
                    TextField("", text: model.settingsBinding.recognitionScript)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                if engine == .dlib {
                    HStack(spacing: 4) {
                        Image(systemName: model.settings.dlibReady ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundColor(model.settings.dlibReady ? .green : .red)
                        Text(model.settings.dlibReady ? "dlib ready" : "dlib not configured")
                            .font(.callout)
                    }
                }
            }

            Divider()

            LabeledControl("Parallel Jobs") {
                TextField("", value: model.settingsBinding.concurrency, format: .number)
                    .textFieldStyle(.roundedBorder).frame(width: 54)
                Stepper("", value: model.settingsBinding.concurrency, in: 1...32)
                    .labelsHidden()
            }

            Text("Settings apply when scan starts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 340)
    }
}

// MARK: - Helper Views

struct LabeledControl<Content: View>: View {
    let label: String
    @ViewBuilder let content: () -> Content
    init(_ label: String, @ViewBuilder content: @escaping () -> Content) {
        self.label = label; self.content = content
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
            HStack(spacing: 4) { content() }
        }
    }
}

// MARK: - Binding helpers

extension Binding where Value == Float {
    var asDouble: Binding<Double> {
        Binding<Double>(
            get: { Double(wrappedValue) },
            set: { wrappedValue = Float($0) }
        )
    }
}
