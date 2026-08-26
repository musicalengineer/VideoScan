// FamilyTreeLineChainView.swift
// "Line to Rick / Line to Donna" (Rick 2026-08-26): the inspector row of
// anchor buttons and the vertical chain the canvas draws in place of the
// tree — ancestor at the top, anchor at the bottom, one card per
// generation, spouse names as a caption. Rendering is O(path length);
// all the graph work happened in the model (`lineOptions`, `lineChain`).

import SwiftUI

/// Inspector row: one button per anchor. Disabled, with a tooltip, when
/// the selected person is not on that anchor's parent line.
struct FamilyTreeLineToRow: View {
    let options: [FamilyTreeLineOption]
    let onShow: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Line to…")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 8) {
                ForEach(options) { option in
                    Button {
                        onShow(option.anchor.id)
                    } label: {
                        Label("Line to \(option.anchor.label)", systemImage: "arrow.down.to.line")
                    }
                    .buttonStyle(.bordered)
                    .disabled(!option.isAvailable)
                    .help(option.relation.map { "\($0) — show the chain" }
                          ?? "not an ancestor of \(option.anchor.label)")
                }
                Spacer()
            }
            .controlSize(.small)
        }
    }
}

/// The chain itself: cards stacked top → bottom joined by a vertical line.
struct FamilyTreeLineChainView: View {
    let chain: FamilyTreeLineChain
    let selectedID: String?
    let onSelect: (String) -> Void

    private let cardWidth: CGFloat = 260

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(chain.cards) { card in
                    if card.generation > 0 {
                        Rectangle()
                            .fill(Color.white.opacity(0.28))
                            .frame(width: 2.5, height: 34)
                    }
                    chainCard(card)
                }
            }
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
    }

    private func chainCard(_ card: FamilyTreeLineChain.Card) -> some View {
        let person = card.person
        let accent = person.sex.accent
        let isSelected = person.id == selectedID
        let isAnchor = person.id == chain.anchor.id
        return VStack(spacing: 0) {
            accent.frame(height: 4)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(person.sex.glyph)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(accent)
                    Text(person.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    Spacer()
                    if isAnchor {
                        Image(systemName: "scope").foregroundStyle(.cyan)
                    }
                }
                if let years = person.years {
                    Text(years)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                if !card.spouseNames.isEmpty {
                    Text("⚭ " + card.spouseNames.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text(card.generation == 0
                     ? "top of this line"
                     : "\(card.generation) generation\(card.generation == 1 ? "" : "s") down")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .padding(10)
        }
        .frame(width: cardWidth)
        .background(Color(red: 0.12, green: 0.13, blue: 0.145))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.cyan : accent.opacity(0.7),
                        lineWidth: isSelected ? 2.5 : 1.5))
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(person.id) }
    }
}

extension FamilyTreeSex {
    /// Shared with the tree card (kept here so the chain file is self-contained).
    var accent: Color {
        switch self {
        case .male: return .cyan
        case .female: return .pink
        case .unknown: return .mint
        }
    }
}
