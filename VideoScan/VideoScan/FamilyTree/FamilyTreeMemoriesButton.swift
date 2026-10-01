// FamilyTreeMemoriesButton.swift
// The "Show me some memories…" button beside the Family Tree title (Rick,
// 2026-10-01) and its "Recently discovered" card. See FamilyTreeMemories
// .swift for the providers, the privacy rule and the bounds; GH #236
// (Story of the Day) is where this grows.
//
// THE BODY COMPUTES NOTHING. The button is inert until clicked; a click
// opens the popover and starts ONE gather off the main actor (the tree,
// today's Person of the Day and the archive configuration are captured as
// values first). The card shows "Looking…" until it lands, then up to five
// rows; a row click focuses that person in the tree and closes the card.
//
// (For Rick: `.popover(isPresented:)` ≈ a small borderless window anchored
// to the button, shown while the Bool is true.)

import SwiftUI
import VideoScanCore

struct FamilyTreeMemoriesButton: View {
    @ObservedObject var model: FamilyTreeLiveModel

    @State private var isPresented = false
    /// nil while a gather is running (or before the first click).
    @State private var items: [FamilyMemory]?
    /// Bumps on each open so a slow gather from an earlier open never lands.
    @State private var generation = 0

    var body: some View {
        if model.isLive {
            Button {
                isPresented.toggle()
            } label: {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Show me some memories…")
            .accessibilityLabel("Show me some memories")
            .accessibilityIdentifier("ft.memories")
            .popover(isPresented: $isPresented, arrowEdge: .bottom) { card }
            .onChange(of: isPresented) { _, open in
                if open { gather() }
            }
        }
    }

    // MARK: The card

    private var card: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Recently discovered")
                .font(.headline)
            if let items {
                if items.isEmpty {
                    Text(FamilyMemories.emptyMessage)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ft.memories.empty")
                } else {
                    ForEach(items) { item in
                        row(item)
                    }
                }
            } else {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Looking…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(width: 340, alignment: .leading)
    }

    private func row(_ item: FamilyMemory) -> some View {
        Button {
            _ = model.focus(onID: item.personID)
            appLog.write("Family Tree: memories — focused \(item.personID) (\(item.kind.rawValue))")
            isPresented = false
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: item.kind.symbolName)
                    .frame(width: 18)
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                    if let detail = item.detail, !detail.isEmpty {
                        Text(detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Text(item.date, format: .relative(presentation: .named))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show this person in the tree")
        .accessibilityIdentifier("ft.memories.row")
    }

    // MARK: Gathering (off the main actor)

    private func gather() {
        guard let graph = model.walkGraph else {
            items = []
            return
        }
        items = nil
        generation &+= 1
        let mine = generation
        let owner = HallieTurnExecutor.Speakers.fromDefaults().ownerFamilySearchID
        let configuration = TestEnvironment.isTestHost ? nil : FamilyAssetConfigurationCenter.shared.snapshot()
        let featured = PersonOfTheDayCenter.shared.pick.map {
            FamilyMemoryContext.Featured(personID: $0.personID, name: $0.name, whyToday: $0.whyToday)
        }
        Task {
            // `Task.detached` ≈ std::async on a worker; the await hops back.
            let found = await Task.detached(priority: .userInitiated) {
                FamilyMemories.gatherForTree(graph: graph, ownerFamilySearchID: owner,
                                             configuration: configuration, featured: featured)
            }.value
            guard mine == generation else { return }
            items = found
        }
    }
}
