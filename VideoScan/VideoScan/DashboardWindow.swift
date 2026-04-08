import SwiftUI

/// Floating detachable dashboard window.
struct DashboardWindow: View {
    @EnvironmentObject var model: VideoScanModel
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
