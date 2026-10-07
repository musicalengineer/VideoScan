// ArchiveAngelCatalogBadge.swift
// "Promote me" in the catalog (Rick 2026-09-11: "highlight in the catalog
// videos that are ready for promotion or should be looked at, basically if
// AA can tag it with something visible"). The Archive Angel Assessment
// already grades every record A–D in its evidence sidecar; this is that
// grade made visible on the row — a badge, not a workflow tag (workflow
// tags are on their way out), and an O(1) sidecar read per row, never a
// catalog-wide pass in a view body.
//
// 2026-10-06: "Ready for archive" / "Angel pick" capsules
// (ArchiveAngelCatalogHint.swift) ride on the same type and view, so the
// Catalog still names only the façade and this one public view.

import AppKit
import SwiftUI

struct ArchiveAngelCatalogBadge: Equatable {
    /// How the chip is drawn.
    enum Style: Equatable {
        /// The original rounded-rect chip ("Promote me", "Needs a date", "Prepared").
        case chip
        /// Light-green capsule: "Ready for archive".
        case readyCapsule
        /// Neutral grey capsule: "Angel pick" (picked, not ready yet).
        case pickCapsule
    }

    let text: String
    let color: Color
    /// Full verdict for the tooltip ("AAA grade A (112) — ★★★ · Donna …").
    let help: String
    var style: Style = .chip

    /// The record's recommendation class (S3b — the same class the Archive
    /// tab counts): Ready = "Promote me", Needs a date, Worth a look, and
    /// Prepared while it waits in a batch. Not now, Excluded and Another
    /// copy draw nothing: the to-do view must stay calm. A record the
    /// classifier never saw falls back to its grade (A → Ready, B → Worth a
    /// look).
    static func make(for record: ArchiveAngelEvidenceRecord?, prepared: Bool = false) -> ArchiveAngelCatalogBadge? {
        if prepared { return make(kind: .prepared, record: record) }
        guard let record else { return nil }
        return make(kind: record.recommendationClass, record: record)
    }

    /// The chip for an EFFECTIVE class (codex #1643 A3 — the façade's
    /// `badge(for:)` passes the class the counts use; `record` only
    /// supplies the tooltip).
    static func make(kind: ArchiveAngelRecommendationClass, record: ArchiveAngelEvidenceRecord?) -> ArchiveAngelCatalogBadge? {
        let help = record?.summary() ?? ""
        switch kind {
        case .prepared:
            return .init(text: "Prepared", color: .blue,
                         help: "Archive Angel prepared this in a batch — review it in the Archive tab, then Promote.")
        case .ready: return .init(text: "Promote me", color: .green, help: help)
        case .needsDate: return .init(text: "Needs a date", color: .orange, help: help)
        case .worthALook: return .init(text: "Worth a look", color: .orange, help: help)
        case .notNow, .excluded, .anotherCopy, .promoted: return nil
        }
    }

    /// The Catalog capsule for a computed hint: "Ready for archive" (light
    /// green) or "Angel pick" (neutral), tooltip from the hint.
    static func make(hint: ArchiveAngelCatalogHint) -> ArchiveAngelCatalogBadge {
        hint.isReady
            ? .init(text: hint.text, color: .green, help: hint.help, style: .readyCapsule)
            : .init(text: hint.text, color: .secondary, help: hint.help, style: .pickCapsule)
    }
}

/// The row chip — same rounded-rect language as the workflow-tag chips
/// beside it, one size up so the eye lands on it. The capsule styles are
/// SOLID fills (content rows keep solid backing — never glass/material).
struct ArchiveAngelCatalogBadgeView: View {
    let badge: ArchiveAngelCatalogBadge
    /// The evidence store revision this chip was drawn against (codex
    /// #1345). Not rendered — it is an INPUT so SwiftUI sees a changed
    /// view when a sweep regrades a row without changing the A+B set.
    var revision: Int = 0

    var body: some View {
        switch badge.style {
        case .chip: chip
        case .readyCapsule: capsule(icon: "checkmark.circle.fill",
                                    ink: Self.readyInk, fill: Self.readyFill, stroke: Self.readyStroke)
        case .pickCapsule: capsule(icon: "sparkles",
                                   ink: .secondary, fill: Self.pickFill, stroke: Self.pickStroke)
        }
    }

    private var chip: some View {
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

    private func capsule(icon: String, ink: Color, fill: Color, stroke: Color) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .semibold))
            Text(badge.text)
                .font(.system(size: 10, weight: .semibold))
        }
        .foregroundColor(ink)
        .padding(.horizontal, 7)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(fill))
        .overlay(Capsule().strokeBorder(stroke, lineWidth: 0.5))
        .fixedSize()
        .lineLimit(1)
        .help(badge.help)
        .accessibilityLabel("Archive Angel: \(badge.text)")
    }

    // MARK: Light/dark-aware solid colours
    //
    // (For Rick: `NSColor(name:dynamicProvider:)` is a colour whose value is
    // a callback asked again whenever the appearance changes — like a
    // virtual getter keyed on the current theme, instead of a fixed RGB.)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }

    /// Dark green text on pale green (light); pale green text on deep green (dark).
    static let readyInk = dynamic(light: NSColor(srgbRed: 0.10, green: 0.42, blue: 0.18, alpha: 1),
                                  dark: NSColor(srgbRed: 0.62, green: 0.90, blue: 0.67, alpha: 1))
    static let readyFill = dynamic(light: NSColor(srgbRed: 0.86, green: 0.96, blue: 0.87, alpha: 1),
                                   dark: NSColor(srgbRed: 0.12, green: 0.26, blue: 0.15, alpha: 1))
    static let readyStroke = dynamic(light: NSColor(srgbRed: 0.55, green: 0.80, blue: 0.58, alpha: 1),
                                     dark: NSColor(srgbRed: 0.25, green: 0.48, blue: 0.30, alpha: 1))
    static let pickFill = dynamic(light: NSColor(white: 0.93, alpha: 1),
                                  dark: NSColor(white: 0.22, alpha: 1))
    static let pickStroke = dynamic(light: NSColor(white: 0.80, alpha: 1),
                                    dark: NSColor(white: 0.36, alpha: 1))
}
