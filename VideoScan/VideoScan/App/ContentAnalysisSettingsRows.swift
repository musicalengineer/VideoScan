// ContentAnalysisSettingsRows.swift — the first rows of Settings ▸ Background
// (Rick 2026-11-02: one pane for every background helper, Content Analysis
// first): the checkbox that turns VideoScan Background on and off, the
// footnote about the two one-time macOS prompts, launchd's line and the
// helper's job line. The words come from BackgroundServicePresentation
// (pure, tested); the state from BackgroundServiceStore (the one setter).
//
// Samples only while on screen (startVisiblePolling / stopVisiblePolling),
// the way the Previews and Find People lines sample their helpers. No
// O(records) work here: `lines` is a handful of string joins.

import ServiceManagement
import SwiftUI

struct ContentAnalysisSettingsRows: View {
    /// A viewer Mac never runs content analysis (its committer refuses the
    /// journal), and only the Release build registers the helper (Rick
    /// 2026-11-03): either way the checkbox is disabled and the footnote
    /// says why (`store.registrationRefusal`). Turning it off stays possible
    /// in the store, but the disabled checkbox is the honest picture here.
    @ObservedObject var store: BackgroundServiceStore

    static let title = "Keep analyzing content in the background"
    static let footnote = "VideoScan Background keeps running the content analyzers — Machine era first — after VideoScan quits, "
        + "and backs off while you work. The first time you turn it on, macOS asks once to allow it under Login Items and "
        + "once for Full Disk Access for the helper so it can read your files. It never writes the catalog; only VideoScan "
        + "applies what it finds."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle(Self.title, isOn: Binding(
                get: { store.enabled },
                set: { store.setEnabled($0) }
            ))
            .toggleStyle(.checkbox)
            .disabled(store.registrationRefusal != nil)
            .accessibilityIdentifier("settings.backgroundService.enabled")
            Text(store.registrationRefusal ?? Self.footnote)
                .font(.footnote).foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            let lines = BackgroundServicePresentation.lines(
                enabled: store.enabled, launchd: store.launchdStatus, service: store.service,
                serviceProblem: store.serviceProblem, work: store.work, workProblem: store.workProblem,
                lastNote: store.lastNote)

            HStack(spacing: 6) {
                Image(systemName: lines.helperIsUp ? "circle.fill" : "circle")
                    .font(.system(size: 8))
                    .foregroundStyle(lines.helperIsUp ? Color.green : Color.secondary)
                Text(lines.helper)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 10)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.backgroundService.status")

            if lines.needsApproval {
                Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                    .controlSize(.small)
                    .padding(.horizontal, 10)
                    .accessibilityIdentifier("settings.backgroundService.openLoginItems")
            }

            HStack(spacing: 6) {
                Image(systemName: "clock.arrow.2.circlepath")
                    .font(.system(size: 10))
                Text(lines.job)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .foregroundColor(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("settings.backgroundService.job")
        }
        .onAppear { store.startVisiblePolling() }
        .onDisappear { store.stopVisiblePolling() }
    }
}
