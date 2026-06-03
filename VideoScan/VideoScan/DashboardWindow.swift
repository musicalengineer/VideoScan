import SwiftUI

/// Floating detachable dashboard window.
struct DashboardWindow: View {
    @EnvironmentObject var model: VideoScanModel
    // TODO(env-object-cleanup): only forwarded as parameter to
    // ExpandedDashboard(dashboard:). See project_bug_prevention_strategy
    // memory; can be removed once ExpandedDashboard takes the ref via
    // a model or env-key indirection.
    // swiftlint:disable-next-line vs-env-object-unused
    @EnvironmentObject var dashboard: DashboardState

    var body: some View {
        ScrollView {
            ExpandedDashboard(
                dashboard: dashboard,
                isScanning: model.isScanning,
                isCombining: model.isCombining
            )
        }
        .frame(minWidth: 600, idealWidth: 600, minHeight: 380, idealHeight: 560, maxHeight: 800)
        .onAppear {
            // Set window to float above other windows
            DispatchQueue.main.async {
                for window in NSApp.windows where window.title.contains("Dashboard") {
                    window.level = .floating
                    window.isMovableByWindowBackground = true
                }
            }
        }
    }
}
