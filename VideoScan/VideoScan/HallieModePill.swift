// HallieModePill.swift
// The small capsule under "Family Archivist" that says which side of the
// archive Hallie is on right now — "Family tree" / "Catalog" / "Listening"
// (design §3.6). Reads ONE enum from conversation memory; a held (forced)
// mode is filled and pinned, an automatic one is outlined. Click = a menu:
// Family tree · Catalog · Automatic. The model is a plain value so the
// label, tint and wording are testable without SwiftUI.

import SwiftUI

/// C++ analogy: a POD view-model — the view is a pure function of it.
struct HallieModePillModel: Equatable {
    let mode: HallieMode
    /// The user held this mode (pill, ":mode", or "in the family tree,
    /// not videos"); shown filled + pinned.
    let forced: Bool

    init(mode: HallieMode, forced: Bool) {
        self.mode = mode
        self.forced = forced
    }

    /// "Family tree" / "Catalog" / "Listening".
    var label: String { mode.label }

    /// One colour per family; grey while listening.
    var tint: Color {
        switch mode {
        case .unknown: return .secondary
        case .catalog: return .blue
        case .tree: return .green
        }
    }

    /// A held mode is filled; an automatic one is outlined.
    var isFilled: Bool { forced }

    var accessibilityLabel: String {
        forced ? "Mode: \(label), held" : "Mode: \(label)"
    }

    var help: String {
        if forced {
            return "\(label) — held until you pick Automatic, or say “in the catalog” / “in the family tree”."
        }
        switch mode {
        case .unknown:
            return "Listening — the next question decides between the catalog and the family tree. Click to hold one."
        case .catalog, .tree:
            return "\(label) — chosen from the conversation. Click to hold a mode."
        }
    }

    /// The suffix the technical-details "answered by …" line appends.
    static func detailsSuffix(for mode: HallieMode) -> String {
        switch mode {
        case .tree: return " · family tree"
        case .catalog: return " · catalog"
        case .unknown: return ""
        }
    }
}

struct HallieModePill: View {
    let model: HallieModePillModel
    let onForce: (HallieMode) -> Void
    let onAutomatic: () -> Void

    var body: some View {
        Menu {
            choice("Family tree", selected: model.forced && model.mode == .tree) { onForce(.tree) }
            choice("Catalog", selected: model.forced && model.mode == .catalog) { onForce(.catalog) }
            Divider()
            choice("Automatic", selected: !model.forced) { onAutomatic() }
        } label: {
            HStack(spacing: 4) {
                if model.forced {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 9, weight: .semibold))
                }
                Text(model.label)
            }
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .foregroundStyle(model.isFilled ? Color.white : model.tint)
            .background(Capsule().fill(model.isFilled ? model.tint : model.tint.opacity(0.12)))
            .overlay(Capsule().stroke(model.tint.opacity(model.isFilled ? 0 : 0.5), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(model.help)
        .accessibilityLabel(model.accessibilityLabel)
    }

    @ViewBuilder
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}
