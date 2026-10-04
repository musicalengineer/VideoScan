// FootageSpectrumDetailView.swift
// The expanded Compare Footage row in Media File Operations: each chosen
// video with what the comparison said about it, then what was left out and
// why. Reads the job's small `detailLines` (≤ a dozen rows) — nothing else.

import SwiftUI

struct FootageSpectrumDetailView: View {
    @ObservedObject var job: FootageSpectrumJob

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(job.detailLines) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: line.isLeftOut ? "minus.circle" : "film")
                        .foregroundColor(line.isLeftOut ? .secondary : .accentColor)
                        .frame(width: 14)
                    Text(line.label)
                        .font(.system(size: 12, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(line.text)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
            }
            Text("Reads each video once and changes nothing. Stop ends it (it cannot pause); what was already read is kept, so comparing again is quick.")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
                .padding(.top, 4)
        }
        .accessibilityIdentifier("mfo.row.spectrumDetail")
    }
}
