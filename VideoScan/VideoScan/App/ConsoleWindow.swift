import SwiftUI

/// Floating detachable console window.
struct ConsoleWindow: View {
    @EnvironmentObject var dashboard: DashboardState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "terminal.fill")
                    .foregroundColor(.green)
                Text("Console")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(dashboard.consoleLines.count) lines")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Button("Clear") {
                    dashboard.clearConsole()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(NSColor.windowBackgroundColor))
            Divider()
            ConsoleView(lines: dashboard.consoleLines)
        }
        .frame(minWidth: 500, idealWidth: 700, minHeight: 250, idealHeight: 400)
    }
}
