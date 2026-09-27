// ArchiveRefileSheet.swift
// The Refile sheet (Rick's approved workflow, 2026-09-27) — ONE file at a
// time: From → To, the Why line, the date (year / month / day) and the name
// editable before confirming, the target recomputed by Promote's own rule
// on every keystroke, and Refile / Cancel. Nothing on disk is touched until
// Refile is clicked; afterwards the sheet stays up to say what happened.
//
// All the logic is in the model (VideoScanModel+ArchiveRefile.swift) and
// the pure layer (ArchiveRefile.swift); this view only holds the text the
// user is typing. (For Rick: `@State` ≈ a member variable SwiftUI keeps
// alive across redraws of this one view.)

import SwiftUI

struct ArchiveRefileSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    let preview: ArchiveRefilePreview

    @State private var yearText = ""
    @State private var monthText = ""
    @State private var dayText = ""
    @State private var nameText = ""
    @State private var working = false
    @State private var result: ArchiveRefileResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Refile in the Archive")
                .font(.title2.weight(.semibold))
            Text(preview.archiveFilename)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    pathRow("From", preview.fromRelPath, color: .secondary)
                    pathRow("To", targetText, color: evaluation.refusal == nil ? .purple : .red)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Why").font(.headline)
                Text(preview.why)
                    .font(.system(size: 14))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("refile.why")
            }

            // Editable date + name — the target follows them live.
            HStack(spacing: 10) {
                labeledField("Year", text: $yearText, width: 70, prompt: "1984")
                labeledField("Month", text: $monthText, width: 50, prompt: "–")
                labeledField("Day", text: $dayText, width: 50, prompt: "–")
                labeledField("Name", text: $nameText, width: 260, prompt: preview.initialName)
            }
            .disabled(working || result != nil)

            if let refusal = evaluation.refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("refile.refusal")
            }

            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Refiling — checking the file's fingerprint before and after the move (this reads the whole file twice)…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            }

            if let result {
                Label(result.message, systemImage: resultIcon(result.kind))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(resultColor(result.kind))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("refile.result")
            }

            HStack {
                Spacer()
                if result == nil {
                    Button("Cancel") {
                        model.refileNote("Refile: \(preview.archiveFilename) — sheet cancelled; nothing was changed.")
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                    Button("Refile") { runRefile() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || evaluation.hint == nil || evaluation.refusal != nil || model.isReadOnly)
                        .accessibilityIdentifier("refile.confirm")
                } else {
                    Button("Done") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 640)
        .onAppear(perform: seedFields)
    }

    // MARK: Pieces

    private func pathRow(_ label: String, _ path: String, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 44, alignment: .leading)
            Text(path)
                .font(.system(size: 13, design: .monospaced))
                .foregroundStyle(color)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    private func labeledField(_ label: String, text: Binding<String>, width: CGFloat, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: text)
                .textFieldStyle(.roundedBorder)
                .frame(width: width)
        }
    }

    private func resultIcon(_ k: ArchiveRefileResult.Kind) -> String {
        switch k {
        case .refiled: return "checkmark.seal.fill"
        case .refused: return "hand.raised.fill"
        case .rolledBack: return "arrow.uturn.backward.circle.fill"
        case .mixedState, .incompleteRecovery: return "exclamationmark.octagon.fill"
        }
    }

    private func resultColor(_ k: ArchiveRefileResult.Kind) -> Color {
        switch k {
        case .refiled: return .green
        case .refused, .rolledBack: return .orange
        case .mixedState, .incompleteRecovery: return .red
        }
    }

    // MARK: State

    private func seedFields() {
        switch preview.initialHint {
        case .day(let y, let m, let d):
            yearText = String(y); monthText = String(m); dayText = String(d)
        case .month(let y, let m):
            yearText = String(y); monthText = String(m)
        case .year(let y):
            yearText = String(y)
        case .decade, .unknown:
            break
        }
        nameText = preview.initialName
    }

    /// The typed fields → a hint (or why not) and the guard. Cheap: string
    /// parsing and one path computation per keystroke.
    private var evaluation: (hint: ArchiveDateHint?, refusal: String?) {
        let y = yearText.trimmingCharacters(in: .whitespaces)
        let m = monthText.trimmingCharacters(in: .whitespaces)
        let d = dayText.trimmingCharacters(in: .whitespaces)
        guard let year = Int(y), y.count == 4 else {
            return (nil, y.isEmpty ? "Type the year it was filmed." : "The year must be four digits.")
        }
        let month = m.isEmpty ? nil : Int(m)
        let day = d.isEmpty ? nil : Int(d)
        if (!m.isEmpty && month == nil) || (!d.isEmpty && day == nil) {
            return (nil, "Month and day must be numbers (or left empty).")
        }
        guard let hint = ArchiveRefile.hint(year: year, month: month, day: day) else {
            return (nil, "That isn't a real date.")
        }
        if let g = preview.guardRefusal(hint: hint) {
            return (hint, "Refused: this video \(g).")
        }
        if preview.target(hint: hint, name: nameText) == preview.fromRelPath {
            return (hint, "That is where it already is — change the date or the name.")
        }
        return (hint, nil)
    }

    private var targetText: String {
        guard let hint = evaluation.hint else { return "—" }
        return preview.target(hint: hint, name: nameText)
    }

    private func runRefile() {
        guard let hint = evaluation.hint, evaluation.refusal == nil else { return }
        working = true
        let name = nameText
        Task {
            let r = await model.refileArchiveCopy(preview, hint: hint, name: name)
            working = false
            result = r
        }
    }
}
