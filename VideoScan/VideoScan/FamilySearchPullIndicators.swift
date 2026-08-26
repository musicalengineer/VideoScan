// FamilySearchPullIndicators.swift
// Small status views for an in-flight "Get Family Tree" download: the
// sidebar button row in the Family Tree tab and the dot on the tab label.
// Both read FamilySearchPullCenter.shared.status.

import SwiftUI

/// Text that breathes (opacity 1.0 ↔ 0.4) for as long as it is on screen.
/// macOS SwiftUI only animates reliably when driven by explicit state that
/// changes after the view appears — hence the `@State` flag flipped in
/// `.onAppear` rather than an implicit `.animation` modifier.
struct PulsingText: View {
    let text: String
    let color: Color
    @State private var dimmed = false

    var body: some View {
        Text(text)
            .foregroundStyle(color)
            .opacity(dimmed ? 0.4 : 1.0)
            .onAppear {
                dimmed = false
                withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                    dimmed = true
                }
            }
    }
}

/// 7pt dot for the tab label's top-trailing corner. Nothing when idle.
struct FamilySearchPullStatusDot: View {
    let status: FamilySearchPullCenter.Status
    @State private var dimmed = false

    var body: some View {
        switch status {
        case .none:
            EmptyView()
        case .downloading:
            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .opacity(dimmed ? 0.3 : 1.0)
                .onAppear {
                    dimmed = false
                    withAnimation(.easeInOut(duration: 1.2).repeatForever(autoreverses: true)) {
                        dimmed = true
                    }
                }
        case .readyToInstall:
            Circle().fill(Color.green).frame(width: 7, height: 7)
        case .failed:
            Circle().fill(Color.orange).frame(width: 7, height: 7)
        }
    }
}

/// The "Get Family Tree" row under the sidebar title. One button whose
/// label changes shape with the download's status; clicking always opens
/// the sheet (which shows options / waiting / Install-Replace / error).
struct FamilySearchPullButtonRow: View {
    let status: FamilySearchPullCenter.Status
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Button(action: action) {
                HStack(spacing: 6) {
                    switch status {
                    case .none:
                        Label("Get Family Tree", systemImage: "arrow.down.circle")
                    case .downloading:
                        SpinningRing(color: .accentColor, size: 16)
                        PulsingText(text: "Downloading…", color: .accentColor)
                    case .readyToInstall:
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                        Text("Ready to install")
                            .foregroundStyle(.green)
                    case .failed:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Download problem")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .controlSize(.regular)
            .help(helpText)
            .accessibilityIdentifier("familyTree.getFamilyTree")

            if case .downloading(let since) = status {
                Text("since \(since, format: .dateTime.hour().minute())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("familyTree.pullStatus")
            }
        }
    }

    private var helpText: String {
        switch status {
        case .none: return "Download your tree from FamilySearch as a GEDCOM file"
        case .downloading: return "The Terminal download is still running. Click to see its progress."
        case .readyToInstall: return "The download finished. Click to install it."
        case .failed: return "Something went wrong with the download. Click for details."
        }
    }
}
