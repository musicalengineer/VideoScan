import SwiftUI

// MARK: - Family Tree (placeholder)
//
// Stub view for an upcoming feature. The vision: visualise the POI graph
// as a real family tree, with each person's archived media inline. Phase 1
// is local-only inside VideoScan; Phase 2 explores publishing to a static
// site (the long-arc Family Legacy idea).
//
// See GH issue for the full proposal — this view is just a placeholder so
// the tab bar can show the destination.

struct FamilyTreeView: View {
    var body: some View {
        VStack(spacing: 24) {
            Spacer()

            // Mini "tree" composed from system icons — placeholder until we
            // have a real graph renderer.
            VStack(spacing: 8) {
                HStack(spacing: 32) {
                    personNode(systemName: "person.crop.circle.fill", label: "Mom")
                    personNode(systemName: "person.crop.circle.fill", label: "Dad")
                }
                connectorTriple()
                HStack(spacing: 18) {
                    personNode(systemName: "person.crop.circle", label: "")
                    personNode(systemName: "person.crop.circle", label: "")
                    personNode(systemName: "person.crop.circle", label: "")
                    personNode(systemName: "person.crop.circle", label: "")
                }
            }
            .padding(.bottom, 8)

            VStack(spacing: 10) {
                Text("Family Tree")
                    .font(.system(size: 32, weight: .bold))
                Text("Not Yet Implemented")
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.orange)
            }

            VStack(alignment: .leading, spacing: 8) {
                planLine(icon: "1.circle.fill",
                         text: "Visualise the POI graph with each person's archived clips and photos inline.")
                planLine(icon: "2.circle.fill",
                         text: "Import your existing FamilySearch tree via GEDCOM — auto-create POI placeholders.")
                planLine(icon: "3.circle.fill",
                         text: "Later: publish a static site (\u{201C}Family Legacy\u{201D}) — tree + media, self-hosted.")
            }
            .frame(maxWidth: 520, alignment: .leading)
            .padding(.top, 8)

            Spacer()
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: helpers

    private func personNode(systemName: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: systemName)
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor.gradient)
            if !label.isEmpty {
                Text(label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func connectorTriple() -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.4))
            .frame(width: 140, height: 2)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 2, height: 14)
                    .offset(y: -14)
            }
            .padding(.bottom, 6)
    }

    private func planLine(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .font(.system(size: 14))
                .padding(.top, 1)
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

#Preview {
    FamilyTreeView()
        .frame(width: 900, height: 600)
}
