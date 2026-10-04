// PeopleTabView.swift
// Sub-tab wrapper inside the People tab. Hosts the existing reference-photo
// person finder ("Find Person") alongside the new cluster-and-name flow
// ("Identify Family"). Both share the People tab so family/POI work stays
// in one place.

import SwiftUI

struct PeopleTabView: View {
    // TODO(env-object-cleanup): these subscribe just to forward to children
    // via .environmentObject(). Same antipattern as PersonFinderView's
    // dashboard cascade (fixed 2026-06-02). Untangling these is a separate
    // pass — see project_bug_prevention_strategy memory.
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var personFinderModel: PersonFinderModel
    // vs-lint:disable-next vs-env-object-unused
    @EnvironmentObject var identifyModel: IdentifyFamilyModel
    @AppStorage("peopleSubTab") private var subTab: Int = 0

    private let tabs: [(label: String, icon: String, tag: Int)] = [
        ("Find Person", "magnifyingglass", 0),
        ("Identify Family", "wand.and.stars", 1)
    ]

    var body: some View {
        VStack(spacing: 0) {
            // Same glass strip as the main tab bar, smaller (2026-10-04).
            HStack {
                GlassTabStrip(selection: $subTab, items: tabs, fontSize: 14)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.bottom, 6)

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
