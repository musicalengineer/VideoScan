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
        .frame(minWidth: 440, idealWidth: 440, minHeight: 300, maxHeight: 600)
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
