// FamilyTreeCards.swift
// The row and card views the Family Tree tab renders: the person card on
// the canvas, its portrait, the note row, the sidebar row, and the
// FamilySearch match card.
//
// Split out of FamilyTreeDemoView.swift on 2026-08-30, which had reached
// 1,978 lines against SwiftLint's 1,000. A pure move: no view changed, no
// logic changed, nothing renamed. Each of these already reads its own
// palette from the environment, so they carry no dependency back on the
// parent beyond the data passed in.
//
// The larger violation is not addressed here — FamilyTreeDemoView's own
// body is ~1,300 lines against a 600 limit, and shrinking THAT means
// lifting the inspector out, which is a real change to how state is
// threaded rather than a move. Left deliberately for a session with
// someone reviewing.

import SwiftUI
import AppKit
import PhotosUI

// MARK: - Card

// `accent` lives in FamilyTreeLineChainView.swift (shared with the chain).
private extension FamilyTreeSex {
    var symbol: String {
        switch self {
        case .male, .female: return "person.fill"
        case .unknown: return "person.crop.circle.dashed"
        }
    }
}

struct FamilyTreePersonCard: View {
    /// Same palette as the enclosing tree. Read from the environment
    /// rather than passed in: the parent sets `.preferredColorScheme`, so
    /// the scheme here is already the resolved one.
    @Environment(\.colorScheme) private var colorScheme
    private var palette: FamilyTreePalette {
        FamilyTreePalette.palette(for: colorScheme == .dark ? .dark : .light)
    }

    let card: FamilyTreeCard
    let isSelected: Bool
    let onSelect: () -> Void
    /// Photo actions (Rick 2026-08-28): right-click menu or double-click on
    /// the card, so the inspector keeps its width for genealogy.
    let onPickPhoto: () -> Void
    let onApplePhoto: () -> Void
    let onAdjustPhoto: () -> Void
    let canAdjustPhoto: Bool
    /// The People-tab profile bridged to this person (its cover is the
    /// photo when no explicit choice exists) and the model's choice
    /// revision, so a fresh choice re-reads the store at once.
    let portraitProfile: POIProfile?
    let photoRevision: Int
    /// Marked to come back to (Rick, 2026-08-30). A bookmark, deliberately
    /// not a heart: in a family archive a favourites list ranks relatives.
    let isBookmarked: Bool
    let onToggleBookmark: () -> Void
    /// Family Tree → Hallie bridge (Rick 2026-08-24: right-click →
    /// "Tell me about this person").
    let onAskHallie: (String) -> Void
    let onShowInPeople: (String) -> Void
    /// Research Person… (2026-08-29): sourced dossier for a deceased
    /// tree person, told to Hallie once confirmed.
    let onResearch: () -> Void

    private var person: FamilyTreePersonSummary { card.person }
    private var accent: Color { person.sex.accent }

    var body: some View {
        VStack(spacing: 0) {
            // FamilySearch-style sex-stripe across the very top of the card.
            accent
                .frame(height: 4)

            VStack(spacing: 8) {
                HStack {
                    Text(person.sex.glyph)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(accent)
                    Spacer()
                    if card.isRoot {
                        Image(systemName: "scope")
                            .foregroundStyle(.cyan)
                    }
                }

                ZStack {
                    if let photo = card.photo {
                        Image(nsImage: photo)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 58, height: 58)
                            .clipShape(Circle())
                    } else if let assetPerson = card.assetPerson {
                        FamilyAssetPortrait(person: assetPerson, profile: portraitProfile,
                                            revision: photoRevision, accent: accent)
                    } else {
                        Circle()
                            .fill(accent.opacity(0.22))
                            .frame(width: 58, height: 58)
                        Image(systemName: person.sex.symbol)
                            .font(.system(size: 30, weight: .medium))
                            .foregroundStyle(accent)
                    }
                }
                .overlay(Circle().stroke(accent.opacity(0.7), lineWidth: 1.5))
                .contextMenu { photoMenuItems }

                Text(person.name)
                    .font(.system(size: 14, weight: .semibold))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity)

                Text(person.years ?? " ")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                Text(person.surname ?? person.reference)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(10)
        }
        .frame(width: 150, height: 194)
        .background(palette.card)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isSelected ? Color.cyan : accent.opacity(0.7), lineWidth: isSelected ? 2.5 : 1.5)
        )
        .overlay(alignment: .bottomTrailing) {
            // Lower-right per Rick's steer, so it never crowds the
            // portrait. Amber reads against both palettes; the tree's own
            // accents are per-sex and cyan means "selected", so neither
            // was free. Only drawn when marked — an always-visible hollow
            // outline on 39,250 cards is visual noise, and the context
            // menu is the discoverable way in.
            if isBookmarked {
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color(red: 0.98, green: 0.72, blue: 0.20))
                    .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    .padding(8)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggleBookmark() }
                    .help("Bookmarked — click to remove")
                    .accessibilityLabel("Bookmarked")
                    .accessibilityAddTraits(.isButton)
            }
        }
        .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        .contentShape(Rectangle())
        // Order matters: SwiftUI gives the earlier `count: 2` recognizer
        // first refusal, so a double-click opens the photo picker and a
        // lone click (after the double-click window lapses) still selects.
        .onTapGesture(count: 2) {
            onSelect()
            onPickPhoto()
        }
        .onTapGesture {
            onSelect()
        }
        .contextMenu {
            Button("Tell me about \(person.name)") {
                onAskHallie(person.name)
            }
            Button("Research \(person.name)…") {
                onResearch()
            }
            Button(isBookmarked ? "Remove bookmark" : "Bookmark \(person.name)",
                   systemImage: isBookmarked ? "bookmark.slash" : "bookmark") {
                onToggleBookmark()
            }
            Divider()
            Button("Center on \(person.name)") {
                onSelect()
            }
            Divider()
            photoMenuItems
            Divider()
            Button("Show \(person.name) in People tab") {
                onShowInPeople(person.name)
            }
        }
    }

    /// The three photo actions, shared by the portrait's and the card's
    /// context menus. `@ViewBuilder` on a computed property ≈ a function
    /// that returns a small view tree without needing an explicit container.
    @ViewBuilder
    private var photoMenuItems: some View {
        Button("Pick a photo…") {
            onSelect()
            onPickPhoto()
        }
        Button("Apple Photos…") {
            onApplePhoto()
        }
        Button("Adjust Photo…") {
            onAdjustPhoto()
        }
        .disabled(!canAdjustPhoto)
    }
}

struct FamilyAssetPortrait: View {
    let person: FamilyAssetPerson
    let profile: POIProfile?
    let revision: Int
    let accent: Color
    @State private var image: NSImage?

    /// What the `.task` keys on: the person, what the bridged profile
    /// says about its cover, and the choice revision.
    private struct Key: Equatable {
        let person: FamilyAssetPerson
        let profileID: String?
        let cover: String?
        let coverChosenAt: Date?
        let revision: Int
    }
    private var key: Key {
        Key(person: person, profileID: profile?.id, cover: profile?.coverImageFilename,
            coverChosenAt: profile?.photoChosenAt, revision: revision)
    }

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                Circle().fill(accent.opacity(0.22))
            }
        }
        .frame(width: 58, height: 58)
        .clipShape(Circle())
        .task(id: key) {
            let configuration = FamilyAssetConfigurationCenter.shared.snapshot()
            let bridged = profile
            let decoded = await Task.detached(priority: .utility) {
                let store = configuration.makeStore()
                // Explicit choice › bridged People-tab cover › a "-card"
                // crop › the person's own folder › a group folder.
                guard let url = PersonPhotoResolver(store: store)
                        .treePhoto(for: person, bridgedProfile: bridged)?.url,
                      let cg = store.makeThumbnail(for: url, maxPixelSize: 160)
                else { return nil as NSImage? }
                return NSImage(cgImage: cg, size: .zero)
            }.value
            if !Task.isCancelled { image = decoded }
        }
    }
}

/// One Archivist Notes row: the passage, then who/when + two small badges.
struct FamilyTreeNoteRow: View {
    /// Same palette as the enclosing tree. Read from the environment
    /// rather than passed in: the parent sets `.preferredColorScheme`, so
    /// the scheme here is already the resolved one.
    @Environment(\.colorScheme) private var colorScheme
    private var palette: FamilyTreePalette {
        FamilyTreePalette.palette(for: colorScheme == .dark ? .dark : .light)
    }

    let note: FamilyTreeNote

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(note.text)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Text(note.attribution)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                badge(note.confidence.rawValue, color: confidenceColor)
                badge(note.privacy.rawValue, color: .gray)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.overlayInk.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var confidenceColor: Color {
        switch note.confidence {
        case .confirmed: return .green
        case .probable: return .cyan
        case .uncertain: return .yellow
        case .disputed: return .orange
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.18))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

struct FamilyTreeSidebarRow: View {
    /// Same palette as the enclosing tree. Read from the environment
    /// rather than passed in: the parent sets `.preferredColorScheme`, so
    /// the scheme here is already the resolved one.
    @Environment(\.colorScheme) private var colorScheme
    private var palette: FamilyTreePalette {
        FamilyTreePalette.palette(for: colorScheme == .dark ? .dark : .light)
    }

    let person: FamilyTreePersonSummary
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: person.sex.symbol)
                .foregroundStyle(person.sex.accent)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(person.name)
                    .lineLimit(1)
                    .font(.system(size: 13, weight: .medium))
                if let years = person.years {
                    Text(years)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(isSelected ? Color.cyan.opacity(0.14) : palette.overlayInk.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: - FamilySearch card (placeholder until the API is wired)

/// Kept as a component so a real lookup result can fill it later. Tonight
/// the only instance is `.notConnected` — no score, no invented reason.
struct FamilySearchMatch: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    /// nil until real matches exist; the card hides the badge when nil.
    let score: Int?

    static let notConnected = FamilySearchMatch(
        id: "not-connected",
        title: "Not connected to FamilySearch yet",
        detail: "Your GEDCOM file stays the source of truth. FamilySearch matching will appear here once it is wired up.",
        score: nil)
}

struct FamilySearchMatchCard: View {
    /// Same palette as the enclosing tree. Read from the environment
    /// rather than passed in: the parent sets `.preferredColorScheme`, so
    /// the scheme here is already the resolved one.
    @Environment(\.colorScheme) private var colorScheme
    private var palette: FamilyTreePalette {
        FamilyTreePalette.palette(for: colorScheme == .dark ? .dark : .light)
    }

    let match: FamilySearchMatch

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(match.title)
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if let score = match.score {
                    Text("\(score)%")
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(score > 88 ? .green : .yellow)
                }
            }

            Text(match.detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label("read-only", systemImage: "eye")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding(10)
        .background(palette.overlayInk.opacity(0.055))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
