import SwiftUI

struct TriageView: View {
    @EnvironmentObject var model: VideoScanModel

    var body: some View {
        VStack(spacing: 16) {
            Spacer()
            Image(systemName: "checklist")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Triage")
                .font(.title2)
                .foregroundStyle(.primary)
            Text("Curation workspace — coming soon")
                .foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
