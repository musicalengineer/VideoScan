// ArchiveAngelReadinessSheet.swift
// "Archive Readiness" (Rick 2026-09-24): an informational sheet, in plain
// language and large type, for one recommended file — is it worth
// archiving, what it still needs and what to do about each, why Archive
// Angel chose it, and the facts (length, date and era, people, copies,
// where it lives). The internal score is one small grey footer line.
//
// Read-only: no buttons that change anything, just Close. Presented with
// `.sheet(item:)` from the recommendations list (the project's
// chained-sheet rule); the payload is the finished explanation, built when
// the button was pressed — the body only lays it out.

import SwiftUI

struct ArchiveAngelReadinessSheet: View {
    let explanation: ArchiveAngelReadinessExplanation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    header
                    section("Is it worth archiving?") {
                        Text(explanation.worthIt).font(.system(size: 17))
                    }
                    if !explanation.missing.isEmpty {
                        section("What it still needs") { missingList }
                    }
                    if !explanation.whyChosen.isEmpty {
                        section("Why Archive Angel chose it") { bulletList(explanation.whyChosen) }
                    }
                    section("About this file") { factsGrid }
                    Text(explanation.footer)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("archiveAngel.readiness.footer")
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            HStack {
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.defaultAction)
                    .controlSize(.large)
                    .font(.system(size: 16))
            }
            .padding(16)
        }
        .frame(minWidth: 620, idealWidth: 700, minHeight: 520, idealHeight: 640)
        .accessibilityIdentifier("archiveAngel.readinessSheet")
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Archive Readiness")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            Text(explanation.filename)
                .font(.system(size: 22, weight: .semibold))
                .textSelection(.enabled)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Image(systemName: explanation.isReady ? "checkmark.seal.fill" : "exclamationmark.circle")
                Text(explanation.statusWords)
            }
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(explanation.isReady ? ColorActionButton.Palette.archive : Color.orange)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 19, weight: .semibold))
            content()
        }
    }

    private var missingList: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(explanation.missing, id: \.self) { step in
                VStack(alignment: .leading, spacing: 4) {
                    Label(step.what, systemImage: "circle")
                        .font(.system(size: 17, weight: .medium))
                    Text(step.todo)
                        .font(.system(size: 16))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 28)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func bulletList(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("•")
                    Text(line).fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 17))
            }
        }
    }

    private var factsGrid: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            ForEach(explanation.facts, id: \.self) { fact in
                GridRow {
                    Text(fact.label + ":")
                        .foregroundStyle(.secondary)
                        .gridColumnAlignment(.trailing)
                    Text(fact.value)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 17))
            }
        }
    }
}
