// ArchiveAngelCatalogBadge.swift
// "Promote me" in the catalog (Rick 2026-09-11: "highlight in the catalog
// videos that are ready for promotion or should be looked at, basically if
// AA can tag it with something visible"). The Archive Angel Assessment
// already grades every record A–D in its evidence sidecar; this is that
// grade made visible on the row — a badge, not a workflow tag (workflow
// tags are on their way out), and an O(1) sidecar read per row, never a
// catalog-wide pass in a view body.

import SwiftUI

struct ArchiveAngelCatalogBadge: Equatable {
    let text: String
    let color: Color
    /// Full verdict for the tooltip ("AAA grade A (112) — ★★★ · Donna …").
    let help: String

    /// Grade A = ready to promote, B = nearly ready and worth a look.
    /// C, D and X (excluded) draw nothing: the to-do view must stay calm.
    static func make(for record: ArchiveAngelEvidenceRecord?) -> ArchiveAngelCatalogBadge? {
        guard let record else { return nil }
        switch record.grade {
        case .a: return .init(text: "Promote me", color: .green, help: record.summary())
        case .b: return .init(text: "Worth a look", color: .orange, help: record.summary())
        case .c, .d, .x: return nil
        }
    }
}

/// The row chip — same rounded-rect language as the workflow-tag chips
/// beside it, one size up so the eye lands on it.
struct ArchiveAngelCatalogBadgeView: View {
    let badge: ArchiveAngelCatalogBadge
    /// The evidence store revision this chip was drawn against (codex
    /// #1345). Not rendered — it is an INPUT so SwiftUI sees a changed
    /// view when a sweep regrades a row without changing the A+B set.
    var revision: Int = 0

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "sparkles")
                .font(.system(size: 8, weight: .semibold))
            Text(badge.text)
                .font(.system(size: 9, weight: .semibold))
        }
        .foregroundColor(badge.color)
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 4).fill(badge.color.opacity(0.14)))
        .lineLimit(1)
        .help(badge.help)
        .accessibilityLabel("Archive Angel: \(badge.text)")
    }
}
