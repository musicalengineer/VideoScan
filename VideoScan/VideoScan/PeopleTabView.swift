// PeopleTabView.swift
// Sub-tab wrapper inside the People tab. Hosts the existing reference-photo
// person finder ("Find Person") alongside the new cluster-and-name flow
// ("Identify Family"). Both share the People tab so family/POI work stays
// in one place.

import SwiftUI

struct PeopleTabView: View {
    @EnvironmentObject var personFinderModel: PersonFinderModel
    @EnvironmentObject var identifyModel: IdentifyFamilyModel
    @AppStorage("peopleSubTab") private var subTab: Int = 0

    private let tabs: [(label: String, icon: String, tag: Int)] = [
        ("Find Person", "magnifyingglass", 0),
        ("Identify Family", "wand.and.stars", 1)
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 18) {
                ForEach(tabs, id: \.tag) { tab in
                    Button {
                        subTab = tab.tag
                    } label: {
                        Label(tab.label, systemImage: tab.icon)
                            .font(.system(size: 14,
                                          weight: subTab == tab.tag ? .semibold : .regular))
                            .foregroundStyle(subTab == tab.tag ? .primary : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 5)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        subTab == tab.tag
                            ? Color.accentColor.opacity(0.10)
                            : Color.clear
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 4)
            Divider()

            Group {
                switch subTab {
                case 1:
                    IdentifyFamilyView()
                default:
                    PersonFinderView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
