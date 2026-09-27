// ArchiveUpdateSheet.swift
// "Update this archived file?" (Rick's ruling 2026-09-27) — two editable
// things, Name and Date (year / month / day + known / estimated), and below
// them a live list of exactly what will change ("Name: A → B", "Date: 1884 →
// 1984 (known)", "Folder: 1880-1889/1884 → 1980-1989/1984"). The folder is
// never picked: it follows the date through Promote's placement function.
// Nothing on disk is touched until Update; afterwards the sheet stays up to
// say what happened. All logic lives in the model and ArchiveRefile.swift.

import SwiftUI

struct ArchiveUpdateSheet: View {
    @EnvironmentObject var model: VideoScanModel
    @Environment(\.dismiss) private var dismiss

    let preview: ArchiveUpdatePreview

    @State private var nameText = ""
    @State private var yearText = ""
    @State private var monthText = ""
    @State private var dayText = ""
    @State private var known = false
    @State private var working = false
    @State private var result: ArchiveUpdateResult?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Update this archived file?")
                .font(.title2.weight(.semibold))
            Text(preview.archiveFilename)
                .font(.system(size: 14, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            HStack(alignment: .bottom, spacing: 10) {
                field("Name", $nameText, width: 260, prompt: preview.currentName)
                field("Year", $yearText, width: 70, prompt: "1984")
                field("Month", $monthText, width: 50, prompt: "–")
                field("Day", $dayText, width: 50, prompt: "–")
                Picker("", selection: $known) {
                    Text("Estimated").tag(false)
                    Text("Known").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
            }
            .disabled(working || result != nil)

            VStack(alignment: .leading, spacing: 4) {
                ForEach(evaluation.changes, id: \.self) { line in
                    Text(line).font(.system(size: 13, design: .monospaced))
                }
                if evaluation.changes.isEmpty && evaluation.refusal == nil {
                    Text("Nothing changed yet.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("archiveUpdate.changes")

            Text("The archive's own record says \(ArchiveRefile.datedLabel(preview.currentHint)). You're the owner — if you know better, update it.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let refusal = evaluation.refusal {
                Label(refusal, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Updating — checking the file's fingerprint before and after (this reads the whole file)…")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                }
            }
            if let result {
                Label(result.message, systemImage: result.kind == .updated ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(result.kind == .updated ? .green : (result.kind == .mixedState || result.kind == .incompleteRecovery ? .red : .orange))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityIdentifier("archiveUpdate.result")
            }

            HStack {
                Spacer()
                if result == nil {
                    Button("Cancel") {
                        model.archiveUpdateNote("Update: \(preview.archiveFilename) — sheet cancelled; nothing was changed.")
                        dismiss()
                    }
                    .keyboardShortcut(.cancelAction)
                    .disabled(working)
                    Button("Update") { run() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(working || evaluation.hint == nil || evaluation.refusal != nil
                                  || evaluation.changes.isEmpty || model.isReadOnly)
                        .accessibilityIdentifier("archiveUpdate.confirm")
                } else {
                    Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 680)
        .onAppear(perform: seed)
    }

    private func field(_ label: String, _ text: Binding<String>, width: CGFloat, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 12)).foregroundStyle(.secondary)
            TextField(prompt, text: text).textFieldStyle(.roundedBorder).frame(width: width)
        }
    }

    private func seed() {
        nameText = preview.currentName
        known = preview.currentKnown
        switch preview.currentHint {
        case .day(let y, let m, let d): yearText = String(y); monthText = String(m); dayText = String(d)
        case .month(let y, let m): yearText = String(y); monthText = String(m)
        case .year(let y): yearText = String(y)
        case .decade, .unknown: break
        }
    }

    /// Typed fields → the preview's ONE evaluation (hint, refusal, plan).
    private var evaluation: (hint: ArchiveDateHint?, refusal: String?, changes: [String]) {
        let e = preview.evaluate(name: nameText, year: yearText, month: monthText, day: dayText, known: known)
        return (e.hint, e.refusal, e.plan?.lines ?? [])
    }

    private func run() {
        guard let hint = evaluation.hint, evaluation.refusal == nil else { return }
        working = true
        let (name, isKnown) = (nameText, known)
        Task {
            result = await model.updateArchivedFile(preview, name: name, hint: hint, known: isKnown)
            working = false
        }
    }
}
